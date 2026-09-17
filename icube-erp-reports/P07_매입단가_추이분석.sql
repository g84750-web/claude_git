/*==============================================================================================
  [ iCUBE ] P-07  매입단가 추이 · 거래처 비교                                        (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 같은 자재를 **언제 얼마에, 누구에게서** 샀는가. 단가가 오르고 있는가, 거래처별로
         얼마나 차이가 나는가. 구매 협상과 원가 절감의 직접 근거.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 소스 ]
  ----------------------------------------------------------------------------------------------
     LSTOCK / LSTOCK_D     입고 (실제 매입 단가)   ← 기본 소스
     LPURCLS / LPURCLS_D   매입마감 (확정 단가)    ← @SRC='CLS' 로 선택
     LCUSTM_UM             등록 단가 (NO_SQ=999 가 현재단가)

     ※ 입고 단가와 마감 단가가 다를 수 있다(단가 조정, 부대비용 반영).
       **회계 확정 단가는 마감**이므로, 원가와 대사할 때는 @SRC='CLS' 를 쓸 것.

  ----------------------------------------------------------------------------------------------
  [ 산식 ]
  ----------------------------------------------------------------------------------------------
     가중평균단가 = Σ(금액) / Σ(수량)          ← 단순평균이 아니라 반드시 가중평균
     전월대비 = 당월 가중평균 / 전월 가중평균 - 1
     거래처간 격차 = (최고단가 - 최저단가) / 최저단가 * 100
     절감가능액 = (현재 가중평균 - 최저 거래처 단가) × 기간 매입수량
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@FR_DT    NVARCHAR(8)  = N'20260101'
    ,@TO_DT    NVARCHAR(8)  = N'20261231'
    ,@ITEM_CD  NVARCHAR(25) = NULL
    ,@TR_CD    NVARCHAR(10) = NULL
    ,@SRC      NVARCHAR(3)  = N'RCV'          -- RCV 입고 / CLS 매입마감
    ,@MIN_TR   INT          = 2               -- 거래처 비교 최소 거래처수
    ,@TH_CHG   DECIMAL(5,1) = 10.0            -- 단가 변동 경고 (%)
    ,@TH_GAP   DECIMAL(5,1) = 10.0            -- 거래처간 격차 경고 (%)
;

IF OBJECT_ID('tempdb..#PUR') IS NOT NULL DROP TABLE #PUR;
IF OBJECT_ID('tempdb..#REG') IS NOT NULL DROP TABLE #REG;


/*==============================================================================================
  1. #PUR : 매입 실적 (입고 또는 마감)
==============================================================================================*/
IF @SRC = N'CLS'
    SELECT
         YM      = LEFT(H.CLS_DT, 6)
        ,DT      = H.CLS_DT
        ,H.TR_CD
        ,D.ITEM_CD
        ,QT      = CAST(ISNULL(D.CLS_QT, 0) AS DECIMAL(19,6))
        ,AM      = CAST(ISNULL(D.CLSG_AM, D.CLSH_AM) AS DECIMAL(19,4))
        ,UM      = CAST(ISNULL(D.UM, 0) AS DECIMAL(19,6))
        ,DOC_NB  = H.CLS_NB
    INTO #PUR
    FROM       LPURCLS   H WITH (NOLOCK)
    INNER JOIN LPURCLS_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.CLS_NB = H.CLS_NB
    LEFT  JOIN SITEM     I WITH (NOLOCK) ON I.CO_CD = D.CO_CD AND I.ITEM_CD = D.ITEM_CD
    WHERE  H.CO_CD  = @CO_CD
      AND  H.CLS_DT BETWEEN @FR_DT AND @TO_DT
      AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
      AND  ISNULL(D.CLS_QT, 0) > 0
      AND  (@DIV_CD  IS NULL OR H.DIV_CD  = @DIV_CD)
      AND  (@TR_CD   IS NULL OR H.TR_CD   = @TR_CD)
      AND  (@ITEM_CD IS NULL OR D.ITEM_CD = @ITEM_CD)
      AND  ISNULL(I.S_CD, N'') <> N'Z00';
ELSE
    SELECT
         YM      = LEFT(H.RCV_DT, 6)
        ,DT      = H.RCV_DT
        ,H.TR_CD
        ,D.ITEM_CD
        ,QT      = CAST(ISNULL(D.RCV_QT, 0) AS DECIMAL(19,6))
        ,AM      = CAST(ISNULL(D.RCV_AM, 0) AS DECIMAL(19,4))
        ,UM      = CAST(ISNULL(D.UM, 0) AS DECIMAL(19,6))
        ,DOC_NB  = H.RCV_NB
    INTO #PUR
    FROM       LSTOCK   H WITH (NOLOCK)
    INNER JOIN LSTOCK_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.RCV_NB = H.RCV_NB
    LEFT  JOIN SITEM    I WITH (NOLOCK) ON I.CO_CD = D.CO_CD AND I.ITEM_CD = D.ITEM_CD
    WHERE  H.CO_CD  = @CO_CD
      AND  H.RCV_DT BETWEEN @FR_DT AND @TO_DT
      AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
      AND  ISNULL(D.RCV_QT, 0) > 0
      AND  (@DIV_CD  IS NULL OR H.DIV_CD  = @DIV_CD)
      AND  (@TR_CD   IS NULL OR H.TR_CD   = @TR_CD)
      AND  (@ITEM_CD IS NULL OR D.ITEM_CD = @ITEM_CD)
      AND  ISNULL(I.S_CD, N'') <> N'Z00';

CREATE CLUSTERED INDEX IX_PUR ON #PUR (ITEM_CD, TR_CD, YM);
PRINT N'[1] 매입 라인 (' + @SRC + N') : ' + CAST((SELECT COUNT(*) FROM #PUR) AS NVARCHAR(20));


/*==============================================================================================
  2. #REG : 등록 매입단가 (LCUSTM_UM, NO_SQ=999)
==============================================================================================*/
CREATE TABLE #REG (TR_CD NVARCHAR(10), ITEM_CD NVARCHAR(25), UM DECIMAL(19,6));

IF OBJECT_ID(N'dbo.LCUSTM_UM', N'U') IS NOT NULL
BEGIN
    DECLARE @SQL NVARCHAR(MAX) = N'
        INSERT INTO #REG (TR_CD, ITEM_CD, UM)
        SELECT U.TR_CD, U.ITEM_CD, CAST(ISNULL(U.UM,0) AS DECIMAL(19,6))
        FROM   dbo.LCUSTM_UM U WITH (NOLOCK)
        WHERE  U.CO_CD = @p_CO AND ISNULL(U.NO_SQ, 0) = 999
          AND  ISNULL(U.USE_YN, N''1'') = N''1''';
    BEGIN TRY
        EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4)', @p_CO=@CO_CD;
        PRINT N'[2] 등록단가 : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 건';
    END TRY BEGIN CATCH PRINT N'[2] LCUSTM_UM 조회 실패'; END CATCH
END
CREATE CLUSTERED INDEX IX_REG ON #REG (TR_CD, ITEM_CD);


/*==============================================================================================
  ** 쿼리 A : 품목별 월별 매입단가 추이  ★ 가중평균
==============================================================================================*/
;WITH M AS (
    SELECT
         P.ITEM_CD, P.YM
        ,QT = SUM(P.QT), AM = SUM(P.AM)
        ,WAVG = CAST(SUM(P.AM) / NULLIF(SUM(P.QT), 0) AS DECIMAL(19,6))
        ,MIN_UM = MIN(NULLIF(P.UM, 0)), MAX_UM = MAX(NULLIF(P.UM, 0))
        ,TR_CNT = COUNT(DISTINCT P.TR_CD)
        ,CNT = COUNT(*)
    FROM   #PUR P
    GROUP BY P.ITEM_CD, P.YM
)
SELECT
     N'[A] 품목별 매입단가 추이'                    AS REPORT_NM
    ,M.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,M.YM                                           AS 매입월
    ,M.QT                                           AS 매입수량
    ,M.AM                                           AS 매입금액
    ,M.WAVG                                         AS 가중평균단가
    ,M.MIN_UM                                       AS 최저단가
    ,M.MAX_UM                                       AS 최고단가
    ,M.TR_CNT                                       AS 거래처수
    ,M.CNT                                          AS 매입건수
    ,전월단가 = LAG(M.WAVG) OVER (PARTITION BY M.ITEM_CD ORDER BY M.YM)
    ,전월대비_PCT = CAST(CASE WHEN LAG(M.WAVG) OVER (PARTITION BY M.ITEM_CD ORDER BY M.YM) > 0
                              THEN (M.WAVG / LAG(M.WAVG) OVER (PARTITION BY M.ITEM_CD ORDER BY M.YM) - 1) * 100
                              END AS DECIMAL(9,1))
    ,기간최저단가 = MIN(M.WAVG) OVER (PARTITION BY M.ITEM_CD)
    ,기간최고단가 = MAX(M.WAVG) OVER (PARTITION BY M.ITEM_CD)
    ,월내격차_PCT = CAST(CASE WHEN M.MIN_UM <> 0
                              THEN (M.MAX_UM / M.MIN_UM - 1) * 100 END AS DECIMAL(9,1))
    ,판정 = CASE
         WHEN LAG(M.WAVG) OVER (PARTITION BY M.ITEM_CD ORDER BY M.YM) > 0
          AND ABS(M.WAVG / LAG(M.WAVG) OVER (PARTITION BY M.ITEM_CD ORDER BY M.YM) - 1) * 100 > @TH_CHG
              THEN N'1.★단가 급변'
         WHEN M.MIN_UM <> 0 AND (M.MAX_UM / M.MIN_UM - 1) * 100 > @TH_GAP
              THEN N'2.★같은 달 내 단가 편차 큼'
         ELSE N'0.안정' END
FROM       M
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = M.ITEM_CD
ORDER BY M.ITEM_CD, M.YM
;


/*==============================================================================================
  ** 쿼리 B : 거래처별 단가 비교  ★ 협상 근거 — 같은 품목을 어디서 싸게 사는가
==============================================================================================*/
;WITH T AS (
    SELECT
         P.ITEM_CD, P.TR_CD
        ,QT = SUM(P.QT), AM = SUM(P.AM)
        ,WAVG = CAST(SUM(P.AM) / NULLIF(SUM(P.QT), 0) AS DECIMAL(19,6))
        ,CNT = COUNT(*)
        ,LAST_DT = MAX(P.DT)
    FROM   #PUR P
    GROUP BY P.ITEM_CD, P.TR_CD
), X AS (
    SELECT
         T.*
        ,MIN_W = MIN(T.WAVG) OVER (PARTITION BY T.ITEM_CD)
        ,MAX_W = MAX(T.WAVG) OVER (PARTITION BY T.ITEM_CD)
        ,TOT_Q = SUM(T.QT)   OVER (PARTITION BY T.ITEM_CD)
        ,TR_N  = COUNT(*)    OVER (PARTITION BY T.ITEM_CD)
        ,RNK   = RANK() OVER (PARTITION BY T.ITEM_CD ORDER BY T.WAVG)
    FROM T
)
SELECT
     N'[B] 거래처별 단가 비교'                      AS REPORT_NM
    ,순위 = X.RNK
    ,X.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.UNIT_CD                                      AS 단위
    ,X.TR_CD                                        AS 거래처코드
    ,TR.TR_NM                                       AS 거래처명
    ,X.QT                                           AS 매입수량
    ,X.AM                                           AS 매입금액
    ,X.WAVG                                         AS 가중평균단가
    ,X.CNT                                          AS 매입건수
    ,X.LAST_DT                                      AS 최종매입일
    ,최저단가_거래처 = X.MIN_W
    ,최저대비_PCT = CAST(CASE WHEN X.MIN_W <> 0
                              THEN (X.WAVG / X.MIN_W - 1) * 100 END AS DECIMAL(9,1))
    ,X.TR_N                                         AS 공급처수
    ,물량비중_PCT = CAST(X.QT * 100.0 / NULLIF(X.TOT_Q, 0) AS DECIMAL(5,1))
    ,절감가능액 = CAST((X.WAVG - X.MIN_W) * X.QT AS DECIMAL(19,4))
    ,R.UM                                           AS 등록단가
    ,등록대비_PCT = CAST(CASE WHEN ISNULL(R.UM, 0) <> 0
                              THEN (X.WAVG / R.UM - 1) * 100 END AS DECIMAL(9,1))
    ,판정 = CASE
         WHEN X.TR_N < @MIN_TR                                     THEN N'9.단독 공급 (비교 불가)'
         WHEN X.RNK = 1                                            THEN N'0.최저가 공급처'
         WHEN X.MIN_W <> 0 AND (X.WAVG / X.MIN_W - 1) * 100 > @TH_GAP
                                                                   THEN N'1.★최저가 대비 격차 큼 - 협상 대상'
         ELSE N'2.보통' END
FROM       X
LEFT  JOIN #REG   R  ON R.TR_CD = X.TR_CD AND R.ITEM_CD = X.ITEM_CD
LEFT  JOIN SITEM  I  WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = X.ITEM_CD
LEFT  JOIN STRADE TR WITH (NOLOCK) ON TR.CO_CD = @CO_CD AND TR.TR_CD = X.TR_CD
WHERE  X.TR_N >= @MIN_TR
ORDER BY 절감가능액 DESC, X.ITEM_CD, X.RNK
;


/*==============================================================================================
  ** 쿼리 C : 단가 상승 품목  (원가 압박 요인)
==============================================================================================*/
;WITH M AS (
    SELECT
         P.ITEM_CD, P.YM
        ,WAVG = CAST(SUM(P.AM) / NULLIF(SUM(P.QT), 0) AS DECIMAL(19,6))
        ,QT = SUM(P.QT), AM = SUM(P.AM)
    FROM   #PUR P GROUP BY P.ITEM_CD, P.YM
), F AS (
    SELECT
         M.ITEM_CD
        ,FIRST_YM = MIN(M.YM), LAST_YM = MAX(M.YM)
        ,FIRST_UM = MAX(CASE WHEN M.YM = (SELECT MIN(YM) FROM M X WHERE X.ITEM_CD=M.ITEM_CD) THEN M.WAVG END)
        ,LAST_UM  = MAX(CASE WHEN M.YM = (SELECT MAX(YM) FROM M X WHERE X.ITEM_CD=M.ITEM_CD) THEN M.WAVG END)
        ,MIN_UM = MIN(M.WAVG), MAX_UM = MAX(M.WAVG)
        ,TOT_QT = SUM(M.QT), TOT_AM = SUM(M.AM)
        ,MM_CNT = COUNT(*)
    FROM   M GROUP BY M.ITEM_CD
)
SELECT
     N'[C] 단가 변동 품목'                          AS REPORT_NM
    ,방향 = CASE WHEN F.LAST_UM > F.FIRST_UM THEN N'1.★상승' ELSE N'2.하락' END
    ,F.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'5' THEN N'상품' ELSE I.ACCT_FG END
    ,F.FIRST_YM                                     AS 최초월
    ,F.FIRST_UM                                     AS 최초단가
    ,F.LAST_YM                                      AS 최종월
    ,F.LAST_UM                                      AS 최종단가
    ,변동률_PCT = CAST(CASE WHEN F.FIRST_UM <> 0
                            THEN (F.LAST_UM / F.FIRST_UM - 1) * 100 END AS DECIMAL(9,1))
    ,F.MIN_UM                                       AS 기간최저
    ,F.MAX_UM                                       AS 기간최고
    ,변동폭_PCT = CAST(CASE WHEN F.MIN_UM <> 0
                            THEN (F.MAX_UM / F.MIN_UM - 1) * 100 END AS DECIMAL(9,1))
    ,F.TOT_QT                                       AS 총매입수량
    ,F.TOT_AM                                       AS 총매입금액
    ,F.MM_CNT                                       AS 매입월수
    ,원가영향액 = CAST((F.LAST_UM - F.FIRST_UM) * F.TOT_QT AS DECIMAL(19,4))
    ,비고 = CASE
         WHEN F.FIRST_UM <> 0 AND (F.LAST_UM / F.FIRST_UM - 1) * 100 > @TH_CHG * 3
              THEN N'★ 30% 초과 상승 - 대체품/대체공급처 검토 (C-04 단가차이 확인)'
         WHEN F.FIRST_UM <> 0 AND (F.LAST_UM / F.FIRST_UM - 1) * 100 > @TH_CHG
              THEN N'원가 상승 요인 - 판가 반영 검토'
         ELSE N'-' END
FROM       F
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = F.ITEM_CD
WHERE  F.MM_CNT > 1
  AND  F.FIRST_UM <> 0
  AND  ABS(F.LAST_UM / F.FIRST_UM - 1) * 100 > @TH_CHG
ORDER BY ABS(원가영향액) DESC
;


/*==============================================================================================
  ** 쿼리 D : 등록단가 대비 실매입 괴리
==============================================================================================*/
SELECT
     N'[D] 등록단가 대비 괴리'                      AS REPORT_NM
    ,구분 = CASE WHEN R.UM IS NULL                            THEN N'1.★단가 미등록'
                 WHEN X.WAVG > R.UM * (1 + @TH_GAP/100)       THEN N'2.★등록단가보다 비싸게 매입'
                 WHEN X.WAVG < R.UM * (1 - @TH_GAP/100)       THEN N'3.등록단가보다 싸게 매입'
                 ELSE N'0.일치' END
    ,X.TR_CD                                        AS 거래처코드
    ,TR.TR_NM                                       AS 거래처명
    ,X.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.UNIT_CD                                      AS 단위
    ,R.UM                                           AS 등록단가
    ,X.WAVG                                         AS 실매입_가중평균
    ,괴리액 = CAST(X.WAVG - ISNULL(R.UM, 0) AS DECIMAL(19,4))
    ,괴리율_PCT = CAST(CASE WHEN ISNULL(R.UM, 0) <> 0
                            THEN (X.WAVG / R.UM - 1) * 100 END AS DECIMAL(9,1))
    ,X.QT                                           AS 매입수량
    ,X.AM                                           AS 매입금액
    ,X.CNT                                          AS 매입건수
    ,원가영향 = CAST((X.WAVG - ISNULL(R.UM, X.WAVG)) * X.QT AS DECIMAL(19,4))
    ,조치 = CASE
         WHEN R.UM IS NULL
              THEN N'★ 단가 마스터 등록 - 실매입 평균 '
                   + CAST(CAST(X.WAVG AS DECIMAL(19,0)) AS NVARCHAR(30)) + N' 참고'
         WHEN X.WAVG > R.UM * (1 + @TH_GAP/100)
              THEN N'★ 계약단가 초과 매입 - 발주 단가 통제 확인'
         ELSE N'-' END
FROM ( SELECT P.ITEM_CD, P.TR_CD
             ,QT = SUM(P.QT), AM = SUM(P.AM), CNT = COUNT(*)
             ,WAVG = CAST(SUM(P.AM) / NULLIF(SUM(P.QT), 0) AS DECIMAL(19,6))
       FROM   #PUR P GROUP BY P.ITEM_CD, P.TR_CD ) X
LEFT  JOIN #REG   R  ON R.TR_CD = X.TR_CD AND R.ITEM_CD = X.ITEM_CD
LEFT  JOIN SITEM  I  WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = X.ITEM_CD
LEFT  JOIN STRADE TR WITH (NOLOCK) ON TR.CO_CD = @CO_CD AND TR.TR_CD = X.TR_CD
WHERE  R.UM IS NULL OR ABS(X.WAVG / NULLIF(R.UM, 0) - 1) * 100 > @TH_GAP
ORDER BY 구분, ABS(원가영향) DESC
;


/*==============================================================================================
  ** 쿼리 E : 요약
==============================================================================================*/
SELECT
     N'[E] 매입단가 요약'                           AS REPORT_NM
    ,@FR_DT + N' ~ ' + @TO_DT                       AS 기간
    ,소스 = CASE @SRC WHEN N'CLS' THEN N'매입마감(확정)' ELSE N'입고' END
    ,품목수 = COUNT(DISTINCT P.ITEM_CD)
    ,거래처수 = COUNT(DISTINCT P.TR_CD)
    ,매입건수 = COUNT(*)
    ,매입수량계 = SUM(P.QT)
    ,매입금액계 = SUM(P.AM)
    ,복수공급품목수 = (SELECT COUNT(*) FROM (
         SELECT ITEM_CD FROM #PUR GROUP BY ITEM_CD HAVING COUNT(DISTINCT TR_CD) >= @MIN_TR) Z)
    ,총절감가능액 = (
         SELECT SUM((T.WAVG - N.MIN_W) * T.QT)
         FROM ( SELECT ITEM_CD, TR_CD, QT = SUM(QT)
                      ,WAVG = CAST(SUM(AM)/NULLIF(SUM(QT),0) AS DECIMAL(19,6))
                FROM #PUR GROUP BY ITEM_CD, TR_CD ) T
         INNER JOIN ( SELECT ITEM_CD, MIN_W = MIN(WAVG), TR_N = COUNT(*)
                      FROM ( SELECT ITEM_CD, TR_CD
                                   ,WAVG = CAST(SUM(AM)/NULLIF(SUM(QT),0) AS DECIMAL(19,6))
                             FROM #PUR GROUP BY ITEM_CD, TR_CD ) Y
                      GROUP BY ITEM_CD ) N ON N.ITEM_CD = T.ITEM_CD
         WHERE N.TR_N >= @MIN_TR )
    ,단가등록률_PCT = CAST((SELECT COUNT(*) FROM (
         SELECT DISTINCT P2.TR_CD, P2.ITEM_CD FROM #PUR P2
         WHERE EXISTS (SELECT 1 FROM #REG R WHERE R.TR_CD=P2.TR_CD AND R.ITEM_CD=P2.ITEM_CD)) Z)
         * 100.0 / NULLIF((SELECT COUNT(*) FROM (
             SELECT DISTINCT TR_CD, ITEM_CD FROM #PUR) Z2), 0) AS DECIMAL(5,1))
    ,판정 = CASE
         WHEN COUNT(*) = 0 THEN N'1.★매입 데이터 없음'
         WHEN (SELECT COUNT(*) FROM (SELECT DISTINCT P2.TR_CD, P2.ITEM_CD FROM #PUR P2
               WHERE EXISTS (SELECT 1 FROM #REG R WHERE R.TR_CD=P2.TR_CD AND R.ITEM_CD=P2.ITEM_CD)) Z)
              * 100.0 / NULLIF((SELECT COUNT(*) FROM (SELECT DISTINCT TR_CD, ITEM_CD FROM #PUR) Z2), 0) < 50
              THEN N'2.★매입 단가 등록률 50% 미만 - 단가 통제 미흡'
         ELSE N'0.정상' END
FROM   #PUR P
;
-- ※ `총절감가능액` = 복수 공급처 품목에 한해, 각 거래처 가중평균단가와 그 품목 최저단가의
--   차액 × 매입수량의 합계. 건별 내역은 쿼리 B 의 `절감가능액` 을 볼 것.


DROP TABLE #PUR, #REG;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 입고 단가 vs 마감 단가 차이  ★ @SRC 선택의 근거
     SELECT TOP 20 S.ITEM_CD, S.UM 입고단가, C.UM 마감단가
     FROM   LSTOCK_D S
     INNER JOIN LPURCLS_D C ON C.CO_CD=S.CO_CD AND C.RCV_NB=S.RCV_NB AND C.RCV_SQ=S.RCV_SQ
     WHERE  S.CO_CD='1000' AND ISNULL(S.UM,0) <> ISNULL(C.UM,0);
     --> 차이가 많으면 원가 대사에는 @SRC='CLS'(마감)를 쓸 것. 회계 확정 단가는 마감이다.

  -- (2) 금액 컬럼 확인
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('LSTOCK_D')  AND name LIKE '%AM';
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('LPURCLS_D') AND name LIKE '%AM';
     --> 본 쿼리는 입고 RCV_AM, 마감 CLSG_AM(없으면 CLSH_AM)을 쓴다.
        마감에서 CLSH_AM(부가세 포함)을 쓰면 단가가 10% 부풀려진다. 반드시 확인할 것.

  -- (3) 복수 공급처 운영  ★ 쿼리 B 의 대상 규모
     SELECT COUNT(*) FROM (SELECT ITEM_CD FROM LSTOCK_D D
       INNER JOIN LSTOCK H ON H.CO_CD=D.CO_CD AND H.RCV_NB=D.RCV_NB
       WHERE D.CO_CD='1000' GROUP BY ITEM_CD HAVING COUNT(DISTINCT H.TR_CD) > 1) X;
     --> 0 에 가까우면 단독 공급 구조라 쿼리 B 가 의미 없다.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **부대비용(운임·관세)을 구분하지 않는다.** 입고 금액에 부대비용이 포함된 사이트와
     아닌 사이트의 단가가 다르게 나온다. 수입 건은 특히 차이가 크므로
     `LSTOCK.LC_YN='1'` 건을 따로 보는 편이 낫다 (P-01 쿼리 F 참조).

  2) **거래처별 단가 비교(쿼리 B)에 품질·납기를 반영하지 않는다.** 최저가 공급처가 항상
     최선은 아니다. `P02_발주납기준수_KPI.sql` 의 공급사 등급과 함께 봐야 한다.

  3) 규격·사양이 다른데 같은 품번을 쓰는 경우 단가 비교가 왜곡된다. 쿼리 B 에서
     `최저대비_PCT` 가 비정상적으로 크면 실제로 같은 물건인지 먼저 확인할 것.

  4) `총절감가능액`(쿼리 E)은 **최저가 공급처로 전량 전환했을 때의 이론적 최대치**다.
     최저가 공급처의 생산능력·품질·납기를 고려하지 않았으므로 실제 절감액은 이보다 작다.
     협상 목표를 세울 때의 상한선으로만 쓸 것.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   P02_발주납기준수_KPI.sql : 공급사 납기 평가 (단가와 함께 봐야 한다)
   C04_표준원가_차이분석.sql : 매입단가 변동이 원가에 미친 영향 (단가차이)
   S12_거래처단가_이력.sql   : 반대 방향 (판매단가)
   P01_청구발주입고_진행현황.sql : 발주 단가 통제
==============================================================================================*/
