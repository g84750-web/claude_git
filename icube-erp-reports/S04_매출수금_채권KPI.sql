/*==============================================================================================
  [ iCUBE ] S-04 매출·수금 KPI  +  S-07 채권 연령분석 (AR Aging)                     (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 얼마를 팔았고 얼마를 받았는가(회수율), 남은 채권은 얼마나 오래됐는가(연령),
         그리고 **얼마를 못 받을 것 같은가(대손 예상)**.

  DBMS : MS-SQL Server 2012 이상 (T-SQL)   ★ 2008 R2 불가 : OVER 프레임 (ROWS/RANGE BETWEEN), 집계 SUM() OVER(ORDER BY …)

  ----------------------------------------------------------------------------------------------
  [ S-06 과의 차이 ]
  ----------------------------------------------------------------------------------------------
     `S06_채권여신_관리현황.sql` 은 **여신 통제** 관점이다 (한도 초과 거래처 적출).
     이 파일은 **회수 성과** 관점이다.
       · 수금 KPI  — 당월/누계 회수율, 수금 유형(현금/어음/상계) 구성
       · 연령분석  — 마감건별 잔액을 배분해 구간을 나눈다 (S-06 쿼리 E 보다 정밀)
       · 대손 예상 — 연령 구간별 대손율을 적용한 충당금 추정

  ----------------------------------------------------------------------------------------------
  [ 산식 ]
  ----------------------------------------------------------------------------------------------
     회수율 = 수금액 / (기초채권 + 당기매출) * 100
     채권회전일수(DSO) = 채권잔액 / (당기매출 / 경과일수)
     대손예상 = Σ(연령구간 잔액 × 구간별 대손율)

  ----------------------------------------------------------------------------------------------
  [ ★ 연령분석 방식 ]
  ----------------------------------------------------------------------------------------------
     건별 수금 소거 데이터가 없는 사이트가 많으므로 **선입선출 배분**을 쓴다.
     거래처 잔액을 마감건에 **최신순으로** 배분한다 = 오래된 것부터 회수됐다고 본다.
     실제 소거 데이터(`LRCP_D.CLS_NB`)가 충분하면 쿼리 F 가 그 매칭률을 알려준다.
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@BASE_DT  NVARCHAR(8)  = N'20260916'
    ,@TR_CD    NVARCHAR(10) = NULL
    ,@EMP_CD   NVARCHAR(10) = NULL
    ,@A1 INT = 30, @A2 INT = 60, @A3 INT = 90      -- 연령 구간
    -- 구간별 대손율 (%)  ★ 회사 정책/과거 실적으로 교체할 것
    ,@R0 DECIMAL(5,2) = 0.0      -- 30일 이내
    ,@R1 DECIMAL(5,2) = 1.0      -- 31~60
    ,@R2 DECIMAL(5,2) = 5.0      -- 61~90
    ,@R3 DECIMAL(5,2) = 20.0     -- 91~180
    ,@R4 DECIMAL(5,2) = 50.0     -- 180일 초과
    ,@TGT_COL DECIMAL(5,1) = 90.0 -- 목표 회수율 (%)
;

DECLARE @P_YR NVARCHAR(4) = LEFT(@BASE_DT, 4);
DECLARE @YR_FR NVARCHAR(8) = LEFT(@BASE_DT,4) + N'0101';
DECLARE @MM_FR NVARCHAR(8) = LEFT(@BASE_DT,6) + N'01';
DECLARE @DAYS  INT = DATEDIFF(DAY, CONVERT(DATE,@YR_FR), CONVERT(DATE,@BASE_DT)) + 1;

IF OBJECT_ID('tempdb..#CLS') IS NOT NULL DROP TABLE #CLS;
IF OBJECT_ID('tempdb..#TR')  IS NOT NULL DROP TABLE #TR;
IF OBJECT_ID('tempdb..#AGE') IS NOT NULL DROP TABLE #AGE;


/*==============================================================================================
  1. #CLS : 마감건별 매출 + #TR : 거래처별 집계
==============================================================================================*/
SELECT
     H.TR_CD
    ,H.CLS_DT
    ,EMP_CD = ISNULL(NULLIF(H.EMP_CD, N''), N'')
    ,AM = SUM(CAST(ISNULL(D.CLSH_AM, 0) AS DECIMAL(19,4)))
INTO #CLS
FROM       LSALECLS   H WITH (NOLOCK)
INNER JOIN LSALECLS_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.CLS_NB = H.CLS_NB
WHERE  H.CO_CD = @CO_CD
  AND  H.CLS_DT BETWEEN @YR_FR AND @BASE_DT
  AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
  AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
  AND  (@TR_CD  IS NULL OR H.TR_CD  = @TR_CD)
GROUP BY H.TR_CD, H.CLS_DT, H.EMP_CD;
CREATE CLUSTERED INDEX IX_CLS ON #CLS (TR_CD, CLS_DT);

SELECT
     T.TR_CD
    ,OPN_AM = ISNULL(O.AM, 0)
    ,ADJ_AM = ISNULL(J.AM, 0)
    ,CLS_MM = ISNULL(C.MM, 0)
    ,CLS_YR = ISNULL(C.YR, 0)
    ,RCP_MM = ISNULL(R.MM, 0)
    ,RCP_YR = ISNULL(R.YR, 0)
    ,CASH_AM = ISNULL(R.CASH, 0)
    ,BILL_AM = ISNULL(R.BILL, 0)
    ,LAST_RCP = R.LAST_DT
    ,BAL_AM = ISNULL(O.AM,0) + ISNULL(C.YR,0) - ISNULL(R.YR,0) + ISNULL(J.AM,0)
INTO #TR
FROM ( SELECT DISTINCT TR_CD FROM #CLS
       UNION SELECT TR_CD FROM LOPN_CRISU WITH (NOLOCK)
             WHERE CO_CD = @CO_CD AND P_YR = @P_YR ) T
OUTER APPLY ( SELECT AM = SUM(CAST(ISNULL(X.OPEN_AM,0) AS DECIMAL(19,4)))
              FROM LOPN_CRISU X WITH (NOLOCK)
              WHERE X.CO_CD=@CO_CD AND X.P_YR=@P_YR AND X.TR_CD=T.TR_CD
                AND (@DIV_CD IS NULL OR X.DIV_CD=@DIV_CD) ) O
OUTER APPLY ( SELECT AM = SUM(CAST(ISNULL(X.ADJUST_AM,0) AS DECIMAL(19,4)))
              FROM LCR_ADJUST X WITH (NOLOCK)
              WHERE X.CO_CD=@CO_CD AND X.P_YR=@P_YR AND X.TR_CD=T.TR_CD
                AND (@DIV_CD IS NULL OR X.DIV_CD=@DIV_CD) ) J
OUTER APPLY ( SELECT MM = SUM(CASE WHEN X.CLS_DT >= @MM_FR THEN X.AM ELSE 0 END)
                    ,YR = SUM(X.AM)
              FROM #CLS X WHERE X.TR_CD = T.TR_CD ) C
OUTER APPLY ( SELECT
                   MM = SUM(CASE WHEN H.RCP_DT >= @MM_FR
                                 THEN CAST(ISNULL(D.NORMAL_AM,0)+ISNULL(D.BEFORE_AM,0) AS DECIMAL(19,4))
                                 ELSE 0 END)
                  ,YR = SUM(CAST(ISNULL(D.NORMAL_AM,0)+ISNULL(D.BEFORE_AM,0) AS DECIMAL(19,4)))
                  ,CASH = SUM(CASE WHEN ISNULL(D.RCP_FG, N'') IN (N'0', N'1')
                                   THEN CAST(ISNULL(D.NORMAL_AM,0) AS DECIMAL(19,4)) ELSE 0 END)
                  ,BILL = SUM(CASE WHEN ISNULL(D.RCP_FG, N'') IN (N'2', N'3')
                                   THEN CAST(ISNULL(D.NORMAL_AM,0) AS DECIMAL(19,4)) ELSE 0 END)
                  ,LAST_DT = MAX(H.RCP_DT)
              FROM       LRCP   H WITH (NOLOCK)
              INNER JOIN LRCP_D D WITH (NOLOCK) ON D.CO_CD=H.CO_CD AND D.RCP_NB=H.RCP_NB
              WHERE  H.CO_CD=@CO_CD AND H.TR_CD=T.TR_CD
                AND  H.RCP_DT BETWEEN @YR_FR AND @BASE_DT
                AND  ISNULL(D.USE_YN,N'1')=N'1' AND ISNULL(D.EXPIRE_YN,N'1')=N'1'
                AND  ISNULL(D.RCPAM_FG,N'0')=N'0'
                AND  (@DIV_CD IS NULL OR H.DIV_CD=@DIV_CD) ) R;
CREATE CLUSTERED INDEX IX_TR ON #TR (TR_CD);


/*==============================================================================================
  2. #AGE : 연령분석  ★ 잔액을 마감건에 최신순 배분 (오래된 것부터 회수됐다고 본다)
==============================================================================================*/
;WITH A AS (
    SELECT
         C.TR_CD, C.CLS_DT, C.AM
        ,B.BAL_AM
        ,RUNNING = SUM(C.AM) OVER (PARTITION BY C.TR_CD ORDER BY C.CLS_DT DESC
                                   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
    FROM       #CLS C
    INNER JOIN #TR  B ON B.TR_CD = C.TR_CD AND B.BAL_AM > 0
), B AS (
    SELECT
         A.TR_CD, A.CLS_DT
        ,OPEN_AM = CASE WHEN A.RUNNING <= A.BAL_AM THEN A.AM
                        ELSE A.AM - (A.RUNNING - A.BAL_AM) END
        ,DAYS = DATEDIFF(DAY, CONVERT(DATE, A.CLS_DT), CONVERT(DATE, @BASE_DT))
    FROM   A
    WHERE  A.RUNNING - A.AM < A.BAL_AM
)
SELECT
     B.TR_CD
    ,AGE0 = SUM(CASE WHEN B.DAYS <= @A1                        THEN B.OPEN_AM ELSE 0 END)
    ,AGE1 = SUM(CASE WHEN B.DAYS >  @A1 AND B.DAYS <= @A2      THEN B.OPEN_AM ELSE 0 END)
    ,AGE2 = SUM(CASE WHEN B.DAYS >  @A2 AND B.DAYS <= @A3      THEN B.OPEN_AM ELSE 0 END)
    ,AGE3 = SUM(CASE WHEN B.DAYS >  @A3 AND B.DAYS <= 180      THEN B.OPEN_AM ELSE 0 END)
    ,AGE4 = SUM(CASE WHEN B.DAYS >  180                        THEN B.OPEN_AM ELSE 0 END)
    ,OLDEST = MAX(B.DAYS)
    ,ALLOC  = SUM(B.OPEN_AM)
INTO #AGE
FROM   B
WHERE  B.OPEN_AM > 0
GROUP BY B.TR_CD;
CREATE CLUSTERED INDEX IX_AGE ON #AGE (TR_CD);


/*==============================================================================================
  ** 쿼리 A : 매출·수금 KPI 요약  (S-04)
==============================================================================================*/
SELECT
     N'[A] 매출·수금 KPI'                           AS REPORT_NM
    ,@BASE_DT                                       AS 기준일
    ,@TGT_COL                                       AS 목표회수율_PCT
    ,거래처수 = COUNT(*)
    ,기초채권 = SUM(T.OPN_AM)
    ,당월매출 = SUM(T.CLS_MM)
    ,누계매출 = SUM(T.CLS_YR)
    ,당월수금 = SUM(T.RCP_MM)
    ,누계수금 = SUM(T.RCP_YR)
    ,채권조정 = SUM(T.ADJ_AM)
    ,채권잔액 = SUM(T.BAL_AM)
    ,당월회수율_PCT = CAST(SUM(T.RCP_MM) / NULLIF(SUM(T.CLS_MM), 0) * 100 AS DECIMAL(5,1))
    ,누계회수율_PCT = CAST(SUM(T.RCP_YR)
                           / NULLIF(SUM(T.OPN_AM) + SUM(T.CLS_YR), 0) * 100 AS DECIMAL(5,1))
    ,현금수금 = SUM(T.CASH_AM)
    ,어음수금 = SUM(T.BILL_AM)
    ,어음비율_PCT = CAST(SUM(T.BILL_AM)
                         / NULLIF(SUM(T.CASH_AM) + SUM(T.BILL_AM), 0) * 100 AS DECIMAL(5,1))
    ,DSO_채권회전일수 = CAST(SUM(T.BAL_AM)
                             / NULLIF(SUM(T.CLS_YR) / NULLIF(@DAYS, 0), 0) AS DECIMAL(9,1))
    ,판정 = CASE
         WHEN SUM(T.RCP_YR) / NULLIF(SUM(T.OPN_AM)+SUM(T.CLS_YR), 0) * 100 >= @TGT_COL
              THEN N'0.목표 달성'
         WHEN SUM(T.RCP_YR) / NULLIF(SUM(T.OPN_AM)+SUM(T.CLS_YR), 0) * 100 >= @TGT_COL - 10
              THEN N'1.주의'
         ELSE N'2.★회수 부진' END
FROM   #TR T
WHERE  T.OPN_AM <> 0 OR T.CLS_YR <> 0 OR T.RCP_YR <> 0
;


/*==============================================================================================
  ** 쿼리 B : 월별 매출·수금 추이
==============================================================================================*/
;WITH M AS (
    SELECT TOP 12 YM = LEFT(CONVERT(NVARCHAR(8), DATEADD(MONTH, -N.n, CONVERT(DATE,@BASE_DT)), 112), 6)
    FROM  (SELECT TOP 12 n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 FROM sys.objects) N
)
SELECT
     N'[B] 월별 매출·수금 추이'                     AS REPORT_NM
    ,M.YM                                           AS 기간월
    ,매출액 = (SELECT SUM(AM) FROM #CLS WHERE LEFT(CLS_DT,6) = M.YM)
    ,수금액 = (SELECT SUM(CAST(ISNULL(D.NORMAL_AM,0)+ISNULL(D.BEFORE_AM,0) AS DECIMAL(19,4)))
               FROM LRCP H WITH (NOLOCK)
               INNER JOIN LRCP_D D WITH (NOLOCK) ON D.CO_CD=H.CO_CD AND D.RCP_NB=H.RCP_NB
               WHERE H.CO_CD=@CO_CD AND LEFT(H.RCP_DT,6)=M.YM
                 AND ISNULL(D.USE_YN,N'1')=N'1' AND ISNULL(D.EXPIRE_YN,N'1')=N'1'
                 AND ISNULL(D.RCPAM_FG,N'0')=N'0'
                 AND (@DIV_CD IS NULL OR H.DIV_CD=@DIV_CD))
    ,회수율_PCT = CAST((SELECT SUM(CAST(ISNULL(D.NORMAL_AM,0)+ISNULL(D.BEFORE_AM,0) AS DECIMAL(19,4)))
                        FROM LRCP H WITH (NOLOCK)
                        INNER JOIN LRCP_D D WITH (NOLOCK) ON D.CO_CD=H.CO_CD AND D.RCP_NB=H.RCP_NB
                        WHERE H.CO_CD=@CO_CD AND LEFT(H.RCP_DT,6)=M.YM
                          AND ISNULL(D.USE_YN,N'1')=N'1' AND ISNULL(D.RCPAM_FG,N'0')=N'0'
                          AND (@DIV_CD IS NULL OR H.DIV_CD=@DIV_CD))
                       / NULLIF((SELECT SUM(AM) FROM #CLS WHERE LEFT(CLS_DT,6)=M.YM), 0)
                       * 100 AS DECIMAL(5,1))
    ,@TGT_COL                                       AS 목표_PCT
FROM   M
ORDER BY M.YM
;


/*==============================================================================================
  ** 쿼리 C : 채권 연령분석 + 대손 예상  (S-07)  ★ 이 파일의 핵심
==============================================================================================*/
SELECT
     N'[C] 채권 연령분석 · 대손 예상'               AS REPORT_NM
    ,T.TR_CD                                        AS 거래처코드
    ,R.TR_NM                                        AS 거래처명
    ,T.BAL_AM                                       AS 채권잔액
    ,ISNULL(G.AGE0, 0)                              AS [30일이내]
    ,ISNULL(G.AGE1, 0)                              AS [31_60일]
    ,ISNULL(G.AGE2, 0)                              AS [61_90일]
    ,ISNULL(G.AGE3, 0)                              AS [91_180일]
    ,ISNULL(G.AGE4, 0)                              AS [180일초과]
    ,배분합계 = ISNULL(G.ALLOC, 0)
    ,미배분   = T.BAL_AM - ISNULL(G.ALLOC, 0)
    ,G.OLDEST                                       AS 최장경과일
    -- 대손 예상
    ,대손예상액 = CAST( ISNULL(G.AGE0,0)*@R0/100 + ISNULL(G.AGE1,0)*@R1/100
                      + ISNULL(G.AGE2,0)*@R2/100 + ISNULL(G.AGE3,0)*@R3/100
                      + ISNULL(G.AGE4,0)*@R4/100 AS DECIMAL(19,4))
    ,대손율_PCT = CAST(( ISNULL(G.AGE0,0)*@R0/100 + ISNULL(G.AGE1,0)*@R1/100
                       + ISNULL(G.AGE2,0)*@R2/100 + ISNULL(G.AGE3,0)*@R3/100
                       + ISNULL(G.AGE4,0)*@R4/100 )
                       / NULLIF(T.BAL_AM, 0) * 100 AS DECIMAL(5,1))
    ,장기채권비율_PCT = CAST((ISNULL(G.AGE3,0)+ISNULL(G.AGE4,0))
                             / NULLIF(T.BAL_AM, 0) * 100 AS DECIMAL(5,1))
    ,T.LAST_RCP                                     AS 최종수금일
    ,무수금일수 = CASE WHEN T.LAST_RCP IS NOT NULL
                       THEN DATEDIFF(DAY, CONVERT(DATE,T.LAST_RCP), CONVERT(DATE,@BASE_DT)) END
    ,회수위험 = CASE
         WHEN T.BAL_AM <= 0                                                    THEN N'0.없음'
         WHEN ISNULL(G.AGE4,0) > 0                                             THEN N'1.★180일 초과 채권 존재'
         WHEN ISNULL(G.AGE3,0) + ISNULL(G.AGE4,0) > T.BAL_AM * 0.3             THEN N'2.★장기채권 30% 초과'
         WHEN T.LAST_RCP IS NULL                                               THEN N'3.수금 이력 없음'
         WHEN DATEDIFF(DAY, CONVERT(DATE,T.LAST_RCP), CONVERT(DATE,@BASE_DT)) > 90
                                                                               THEN N'4.90일 무수금'
         ELSE N'5.정상' END
FROM       #TR    T
LEFT  JOIN #AGE   G ON G.TR_CD = T.TR_CD
LEFT  JOIN STRADE R WITH (NOLOCK) ON R.CO_CD = @CO_CD AND R.TR_CD = T.TR_CD
WHERE  T.BAL_AM <> 0
ORDER BY 회수위험, 대손예상액 DESC
;


/*==============================================================================================
  ** 쿼리 D : 연령 구간 요약 + 대손충당금 추정  (경영 보고)
==============================================================================================*/
SELECT
     N'[D] 연령구간별 대손 추정'                    AS REPORT_NM
    ,구간, 대손율_PCT, 채권잔액, 대손예상액, 거래처수, 구성비_PCT
FROM (
    SELECT 순서=1, 구간=N'1.30일 이내'  , 대손율_PCT=@R0
          ,채권잔액=SUM(AGE0), 대손예상액=CAST(SUM(AGE0)*@R0/100 AS DECIMAL(19,4))
          ,거래처수=SUM(CASE WHEN AGE0>0 THEN 1 ELSE 0 END) FROM #AGE
    UNION ALL
    SELECT 2, N'2.31~60일' , @R1, SUM(AGE1), CAST(SUM(AGE1)*@R1/100 AS DECIMAL(19,4))
          ,SUM(CASE WHEN AGE1>0 THEN 1 ELSE 0 END) FROM #AGE
    UNION ALL
    SELECT 3, N'3.61~90일' , @R2, SUM(AGE2), CAST(SUM(AGE2)*@R2/100 AS DECIMAL(19,4))
          ,SUM(CASE WHEN AGE2>0 THEN 1 ELSE 0 END) FROM #AGE
    UNION ALL
    SELECT 4, N'4.91~180일', @R3, SUM(AGE3), CAST(SUM(AGE3)*@R3/100 AS DECIMAL(19,4))
          ,SUM(CASE WHEN AGE3>0 THEN 1 ELSE 0 END) FROM #AGE
    UNION ALL
    SELECT 5, N'5.★180일 초과', @R4, SUM(AGE4), CAST(SUM(AGE4)*@R4/100 AS DECIMAL(19,4))
          ,SUM(CASE WHEN AGE4>0 THEN 1 ELSE 0 END) FROM #AGE
) X
CROSS APPLY (SELECT 구성비_PCT = CAST(X.채권잔액 * 100.0
                     / NULLIF((SELECT SUM(AGE0+AGE1+AGE2+AGE3+AGE4) FROM #AGE), 0) AS DECIMAL(5,1))) C
ORDER BY X.순서
;


/*==============================================================================================
  ** 쿼리 E : 영업담당별 매출·수금
==============================================================================================*/
SELECT
     N'[E] 담당자별 매출·수금'                      AS REPORT_NM
    ,C.EMP_CD                                       AS 담당자코드
    ,E.EMP_NM                                       AS 담당자명
    ,P.DEPT_NM                                      AS 부서명
    ,거래처수 = COUNT(DISTINCT C.TR_CD)
    ,누계매출 = SUM(C.AM)
    ,담당채권 = (SELECT SUM(T2.BAL_AM) FROM #TR T2
                 WHERE T2.TR_CD IN (SELECT DISTINCT TR_CD FROM #CLS X WHERE X.EMP_CD = C.EMP_CD))
    ,장기채권 = (SELECT SUM(ISNULL(G2.AGE3,0)+ISNULL(G2.AGE4,0)) FROM #AGE G2
                 WHERE G2.TR_CD IN (SELECT DISTINCT TR_CD FROM #CLS X WHERE X.EMP_CD = C.EMP_CD))
    ,매출기여도_PCT = CAST(SUM(C.AM) * 100.0
                           / NULLIF(SUM(SUM(C.AM)) OVER (), 0) AS DECIMAL(5,1))
    ,판정 = CASE WHEN (SELECT SUM(ISNULL(G2.AGE3,0)+ISNULL(G2.AGE4,0)) FROM #AGE G2
                       WHERE G2.TR_CD IN (SELECT DISTINCT TR_CD FROM #CLS X WHERE X.EMP_CD=C.EMP_CD)) > 0
                  THEN N'★장기채권 보유 - 회수 관리 필요' ELSE N'정상' END
FROM       #CLS  C
LEFT  JOIN SEMP  E WITH (NOLOCK) ON E.CO_CD = @CO_CD AND E.EMP_CD  = C.EMP_CD
LEFT  JOIN SDEPT P WITH (NOLOCK) ON P.CO_CD = @CO_CD AND P.DEPT_CD = E.DEPT_CD
WHERE  (@EMP_CD IS NULL OR C.EMP_CD = @EMP_CD)
GROUP BY C.EMP_CD, E.EMP_NM, P.DEPT_NM
ORDER BY 누계매출 DESC
;


/*==============================================================================================
  ** 쿼리 F : 수금 소거(매칭) 품질 점검  ★ 연령분석 방식 선택의 근거
     ─ LRCP_D.CLS_NB 채움률이 높으면 배분 대신 건별 소거로 바꾸는 편이 정확하다.
==============================================================================================*/
SELECT
     N'[F] 수금 소거 매칭률'                        AS REPORT_NM
    ,전체수금건수 = COUNT(*)
    ,마감연결건수 = SUM(CASE WHEN ISNULL(D.CLS_NB, N'') <> N'' THEN 1 ELSE 0 END)
    ,출고연결건수 = SUM(CASE WHEN ISNULL(D.ISU_NB, N'') <> N'' THEN 1 ELSE 0 END)
    ,마감매칭률_PCT = CAST(SUM(CASE WHEN ISNULL(D.CLS_NB,N'')<>N'' THEN 1.0 ELSE 0 END)
                           / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
    ,판정 = CASE
         WHEN SUM(CASE WHEN ISNULL(D.CLS_NB,N'')<>N'' THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0) >= 0.8
              THEN N'0.매칭률 80% 이상 - 건별 소거로 전환하면 연령분석이 더 정확해진다'
         WHEN SUM(CASE WHEN ISNULL(D.CLS_NB,N'')<>N'' THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0) >= 0.3
              THEN N'1.매칭률 중간 - 현재의 선입선출 배분 방식이 타당'
         ELSE N'2.매칭 거의 없음 - 배분 방식 외 대안 없음. 연령은 경향치로만 볼 것' END
FROM       LRCP   H WITH (NOLOCK)
INNER JOIN LRCP_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.RCP_NB = H.RCP_NB
WHERE  H.CO_CD = @CO_CD AND H.RCP_DT BETWEEN @YR_FR AND @BASE_DT
  AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.RCPAM_FG, N'0') = N'0'
;


DROP TABLE #CLS, #TR, #AGE;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 수금유형 코드  ★ 쿼리 A 의 현금/어음 구분
     SELECT RCP_FG, COUNT(*) FROM LRCP_D WHERE CO_CD='1000' GROUP BY RCP_FG;
     SELECT * FROM LRCPFG WHERE CO_CD='1000';
     --> 본 쿼리는 0/1=현금성, 2/3=어음으로 가정한다. LRCPFG 의 실제 정의로 교체할 것.

  -- (2) 대손율 기준  ★ 기본값(0/1/5/20/50%)은 일반적인 예시일 뿐이다
     --> 과거 실제 대손 실적 또는 회사 회계정책의 충당금 설정률로 교체해야 한다.
        이 값을 바꾸지 않으면 쿼리 C·D 의 대손예상액은 참고치에 불과하다.

  -- (3) 수금 소거 매칭률  ★ 쿼리 F 와 같은 목적
     SELECT COUNT(*) 전체, SUM(CASE WHEN ISNULL(CLS_NB,'')='' THEN 1 ELSE 0 END) 미연결
     FROM   LRCP_D WHERE CO_CD='1000';

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **연령분석은 선입선출 배분 근사치다.** 실제로 최근 건부터 회수하는 거래처가 있으면
     연령이 실제보다 길게 나온다. 쿼리 C 의 `미배분` 이 크면 기초채권이 배분 대상에서
     빠진 것이므로(마감 이력 없는 기초분) 그만큼 연령 정보가 없다는 뜻이다.

  2) **대손예상은 추정이다.** 구간별 일률 적용이므로 특정 거래처의 신용 상태를 반영하지
     않는다. 회계상 충당금 설정에 그대로 쓰면 안 되고, 회수 우선순위 판단에 쓸 것.

  3) 선수금(`BEFORE_AM`)을 수금에 합산한다. 부채로 보는 정책이면 제외하도록 수정할 것.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   S06_채권여신_관리현황.sql : 여신 통제 관점 (한도 초과 적출)
   A05_자금수지_전망.sql     : 이 채권이 언제 현금이 되는가
   C05_매출이익_분석.sql     : 이익이 나도 회수가 안 되면 의미 없다
==============================================================================================*/
