/*==============================================================================================
  [ iCUBE ] C-05  매출이익 분석 (품목 · 거래처 · 담당)                               (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 무엇을 팔아서 얼마를 남겼는가. **역마진 거래를 찾아내는 것이 첫째 목적**이다.
         매출은 마감 기준(회계 확정), 원가는 원가모듈 결과를 붙인다.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 산식 ]
  ----------------------------------------------------------------------------------------------
     매출액    = LSALECLS_D.CLSG_AM        (공급가액. 부가세 제외)     ★ 마감 기준 = 회계 확정
     매출원가  = 판매수량 × 단위원가
     매출이익  = 매출액 - 매출원가
     이익률    = 매출이익 / NULLIF(매출액, 0) * 100

  ----------------------------------------------------------------------------------------------
  [ ★ 단위원가 소스 — @UM_SRC 로 선택. 없으면 자동 강등 ]
  ----------------------------------------------------------------------------------------------
     'PRD'   CIV_PRD_TAV.PRD_UM     제조원가 (마감 차수)   ← 자사 생산품에 가장 정확
     'FIFO'  LINV_MVFIFO            평가 후 출고단가       ← 선입선출 평가 사이트의 정답
     'TAV'   LINV_TAV.ISU_UM        기간 평가단가          ← 이동/총평균 사이트
     'STD'   SITEM.STD_UM / PUR_UM  마스터 표준단가        ← 최후 수단 (실제와 괴리 큼)

     기본값 'AUTO' 는 PRD → FIFO → TAV → STD 순으로 품목마다 있는 것을 쓴다.
     **어느 소스를 썼는지 행마다 `원가출처` 로 표시**한다. 소스가 섞이면 이익률 비교가
     왜곡되므로, 쿼리 G 에서 소스별 커버리지를 반드시 확인할 것.

  ----------------------------------------------------------------------------------------------
  [ 주의 ]
  ----------------------------------------------------------------------------------------------
   · **상품(ACCT_FG='5') 은 제조원가가 없다.** 매입원가(FIFO/TAV)를 써야 한다.
     'PRD' 로 고정하면 상품 전체가 원가 0 이 되어 이익이 폭증한다. AUTO 를 권장하는 이유다.
   · 원가차수가 마감되지 않았으면 'PRD' 값이 불완전하다 → 쿼리 G 에서 차수 상태 표시.
   · 판관비는 반영하지 않는다. 여기서 말하는 이익은 **매출총이익(Gross Margin)** 이다.
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@FR_DT    NVARCHAR(8)  = N'20260101'     -- 마감일 FROM
    ,@TO_DT    NVARCHAR(8)  = N'20261231'
    ,@TR_CD    NVARCHAR(10) = NULL
    ,@ITEM_CD  NVARCHAR(25) = NULL
    ,@EMP_CD   NVARCHAR(10) = NULL            -- 영업담당
    ,@UM_SRC   NVARCHAR(6)  = N'AUTO'         -- AUTO / PRD / FIFO / TAV / STD
    ,@CHASU    INT          = NULL            -- 원가차수 (NULL = 최신 마감차수)

    ,@TH_LOW   DECIMAL(5,1) = 10.0            -- 저마진 경고 기준 이익률 (%)
    ,@TH_TGT   DECIMAL(5,1) = 25.0            -- 목표 이익률 (%)  ※ 사이트 기준으로 교체
;

DECLARE @P_YR NVARCHAR(4) = LEFT(@FR_DT, 4);
DECLARE @SQL NVARCHAR(MAX);
DECLARE @CH_ST NVARCHAR(20) = N'없음';

IF OBJECT_ID('tempdb..#UM')  IS NOT NULL DROP TABLE #UM;
IF OBJECT_ID('tempdb..#SAL') IS NOT NULL DROP TABLE #SAL;


/*==============================================================================================
  1. #UM : 품목별 단위원가  (우선순위대로 채우고, 이미 있으면 건너뜀)
==============================================================================================*/
CREATE TABLE #UM (ITEM_CD NVARCHAR(25) PRIMARY KEY, UM DECIMAL(19,6), UM_SRC NVARCHAR(10));

-- (1) 제조원가 CIV_PRD_TAV
IF @UM_SRC IN (N'AUTO', N'PRD') AND OBJECT_ID(N'dbo.CIV_PRD_TAV', N'U') IS NOT NULL
BEGIN
    IF @CHASU IS NULL AND OBJECT_ID(N'dbo.CIV_CHASU', N'U') IS NOT NULL
    BEGIN
        SELECT TOP 1 @CHASU = CHASU, @CH_ST = N'마감'
        FROM   CIV_CHASU WITH (NOLOCK)
        WHERE  CO_CD = @CO_CD AND P_YR = @P_YR AND ISNULL(CLS_YN, N'0') = N'1'
        ORDER BY CHASU DESC;
        IF @CHASU IS NULL
            SELECT TOP 1 @CHASU = CHASU, @CH_ST = N'★미마감'
            FROM   CIV_CHASU WITH (NOLOCK)
            WHERE  CO_CD = @CO_CD AND P_YR = @P_YR
            ORDER BY CHASU DESC;
    END

    IF @CHASU IS NOT NULL
    BEGIN
        SET @SQL = N'
            INSERT INTO #UM (ITEM_CD, UM, UM_SRC)
            SELECT P.ITEM_CD
                  ,CAST(SUM(CAST(ISNULL(P.PRD_AM,0) AS DECIMAL(19,4)))
                        / NULLIF(SUM(CAST(ISNULL(P.PRD_QT,0) AS DECIMAL(19,6))), 0) AS DECIMAL(19,6))
                  ,N''PRD''
            FROM   dbo.CIV_PRD_TAV P WITH (NOLOCK)
            WHERE  P.CO_CD = @p_CO AND P.P_YR = @p_YR AND P.CHASU = @p_CH
              AND  (@p_DIV IS NULL OR P.DIV_CD = @p_DIV)
            GROUP BY P.ITEM_CD
            HAVING SUM(CAST(ISNULL(P.PRD_QT,0) AS DECIMAL(19,6))) > 0';
        BEGIN TRY
            EXEC sp_executesql @SQL
                ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YR NVARCHAR(4), @p_CH INT'
                ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_YR=@P_YR, @p_CH=@CHASU;
            PRINT N'[1-1] PRD (차수 ' + CAST(@CHASU AS NVARCHAR(10)) + N'/' + @CH_ST + N') : '
                  + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 품목';
        END TRY BEGIN CATCH PRINT N'[1-1] CIV_PRD_TAV 조회 실패'; END CATCH
    END
END

-- (2) 선입선출 평가 후 출고단가 LINV_MVFIFO
IF @UM_SRC IN (N'AUTO', N'FIFO') AND OBJECT_ID(N'dbo.LINV_MVFIFO', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
        INSERT INTO #UM (ITEM_CD, UM, UM_SRC)
        SELECT F.ITEM_CD
              ,CAST(AVG(CAST(NULLIF(F.ISU_UM,0) AS DECIMAL(19,6))) AS DECIMAL(19,6))
              ,N''FIFO''
        FROM   dbo.LINV_MVFIFO F WITH (NOLOCK)
        WHERE  F.CO_CD = @p_CO AND F.P_YR = @p_YR
          AND  ISNULL(F.ISU_UM, 0) <> 0
          AND  (@p_DIV IS NULL OR F.DIV_CD = @p_DIV)
          AND  NOT EXISTS (SELECT 1 FROM #UM U WHERE U.ITEM_CD = F.ITEM_CD)
        GROUP BY F.ITEM_CD';
    BEGIN TRY
        EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YR NVARCHAR(4)'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_YR=@P_YR;
        PRINT N'[1-2] FIFO : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 품목';
    END TRY BEGIN CATCH PRINT N'[1-2] LINV_MVFIFO 조회 실패'; END CATCH
END

-- (3) 기간 평가단가 LINV_TAV
IF @UM_SRC IN (N'AUTO', N'TAV') AND OBJECT_ID(N'dbo.LINV_TAV', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
        INSERT INTO #UM (ITEM_CD, UM, UM_SRC)
        SELECT T.ITEM_CD
              ,CAST(AVG(CAST(NULLIF(T.ISU_UM,0) AS DECIMAL(19,6))) AS DECIMAL(19,6))
              ,N''TAV''
        FROM   dbo.LINV_TAV T WITH (NOLOCK)
        WHERE  T.CO_CD = @p_CO AND ISNULL(T.ISU_UM, 0) <> 0
          AND  (@p_DIV IS NULL OR T.DIV_CD = @p_DIV)
          AND  NOT EXISTS (SELECT 1 FROM #UM U WHERE U.ITEM_CD = T.ITEM_CD)
        GROUP BY T.ITEM_CD';
    BEGIN TRY
        EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4)'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD;
        PRINT N'[1-3] TAV : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 품목';
    END TRY BEGIN CATCH PRINT N'[1-3] LINV_TAV 조회 실패'; END CATCH
END

-- (4) 마스터 표준단가 (최후 수단)
IF @UM_SRC IN (N'AUTO', N'STD')
BEGIN
    INSERT INTO #UM (ITEM_CD, UM, UM_SRC)
    SELECT I.ITEM_CD, CAST(ISNULL(NULLIF(I.STD_UM,0), I.PUR_UM) AS DECIMAL(19,6)), N'STD'
    FROM   SITEM I WITH (NOLOCK)
    WHERE  I.CO_CD = @CO_CD
      AND  ISNULL(NULLIF(I.STD_UM,0), I.PUR_UM) IS NOT NULL
      AND  NOT EXISTS (SELECT 1 FROM #UM U WHERE U.ITEM_CD = I.ITEM_CD);
    PRINT N'[1-4] STD : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 품목';
END


/*==============================================================================================
  2. #SAL : 매출마감 라인 + 원가 결합
==============================================================================================*/
SELECT
     H.CLS_NB
    ,D.CLS_SQ
    ,H.CLS_DT
    ,H.TR_CD
    ,EMP_CD = ISNULL(NULLIF(D.EMP_CD, N''), H.EMP_CD)
    ,PJT_CD = ISNULL(NULLIF(D.PJT_CD, N''), H.PJT_CD)
    ,D.ITEM_CD
    ,CLS_QT  = CAST(ISNULL(D.CLS_QT, 0) AS DECIMAL(19,6))
    ,SALE_AM = CAST(ISNULL(D.CLSG_AM, D.CLSH_AM) AS DECIMAL(19,4))   -- 공급가액 우선
    ,SALE_UM = CAST(ISNULL(D.UM, 0) AS DECIMAL(19,6))
    ,COST_UM = ISNULL(U.UM, 0)
    ,COST_AM = CAST(ISNULL(D.CLS_QT,0) * ISNULL(U.UM,0) AS DECIMAL(19,4))
    ,UM_SRC  = ISNULL(U.UM_SRC, N'없음')
INTO #SAL
FROM       LSALECLS   H WITH (NOLOCK)
INNER JOIN LSALECLS_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.CLS_NB = H.CLS_NB
LEFT  JOIN #UM        U ON U.ITEM_CD = D.ITEM_CD
LEFT  JOIN SITEM      I WITH (NOLOCK) ON I.CO_CD = D.CO_CD AND I.ITEM_CD = D.ITEM_CD
WHERE  H.CO_CD  = @CO_CD
  AND  H.CLS_DT BETWEEN @FR_DT AND @TO_DT
  AND  ISNULL(D.USE_YN, N'1') = N'1'
  AND  ISNULL(D.EXPIRE_YN, N'1') = N'1'
  AND  (@DIV_CD  IS NULL OR H.DIV_CD  = @DIV_CD)
  AND  (@TR_CD   IS NULL OR H.TR_CD   = @TR_CD)
  AND  (@ITEM_CD IS NULL OR D.ITEM_CD = @ITEM_CD)
  AND  (@EMP_CD  IS NULL OR ISNULL(NULLIF(D.EMP_CD,N''), H.EMP_CD) = @EMP_CD)
  AND  ISNULL(I.S_CD, N'') <> N'Z00'
;
CREATE CLUSTERED INDEX IX_SAL ON #SAL (ITEM_CD, TR_CD);
PRINT N'[2] 매출마감 라인 : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 건';


/*==============================================================================================
  ** 쿼리 A : 품목별 매출이익  (메인)
==============================================================================================*/
SELECT
     N'[A] 품목별 매출이익'                         AS REPORT_NM
    ,S.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
    ,COUNT(*)                                       AS 마감건수
    ,COUNT(DISTINCT S.TR_CD)                        AS 거래처수
    ,SUM(S.CLS_QT)                                  AS 판매수량
    ,SUM(S.SALE_AM)                                 AS 매출액
    ,SUM(S.COST_AM)                                 AS 매출원가
    ,매출이익 = SUM(S.SALE_AM) - SUM(S.COST_AM)
    ,이익률_PCT = CAST((SUM(S.SALE_AM) - SUM(S.COST_AM))
                       / NULLIF(SUM(S.SALE_AM), 0) * 100 AS DECIMAL(5,1))
    ,평균판매단가 = CAST(SUM(S.SALE_AM) / NULLIF(SUM(S.CLS_QT), 0) AS DECIMAL(19,4))
    ,단위원가     = CAST(MAX(S.COST_UM) AS DECIMAL(19,4))
    ,단위이익     = CAST(SUM(S.SALE_AM) / NULLIF(SUM(S.CLS_QT),0) - MAX(S.COST_UM) AS DECIMAL(19,4))
    ,원가출처 = MAX(S.UM_SRC)
    ,매출기여도_PCT = CAST(SUM(S.SALE_AM) * 100.0
                           / NULLIF(SUM(SUM(S.SALE_AM)) OVER (), 0) AS DECIMAL(5,1))
    ,이익기여도_PCT = CAST((SUM(S.SALE_AM)-SUM(S.COST_AM)) * 100.0
                           / NULLIF(SUM(SUM(S.SALE_AM)-SUM(S.COST_AM)) OVER (), 0) AS DECIMAL(5,1))
    ,판정 = CASE
         WHEN MAX(S.UM_SRC) = N'없음'                                          THEN N'9.★원가 없음 - 이익 산출 불가'
         WHEN SUM(S.SALE_AM) - SUM(S.COST_AM) < 0                              THEN N'1.★역마진'
         WHEN (SUM(S.SALE_AM)-SUM(S.COST_AM))/NULLIF(SUM(S.SALE_AM),0)*100 < @TH_LOW
                                                                               THEN N'2.★저마진'
         WHEN (SUM(S.SALE_AM)-SUM(S.COST_AM))/NULLIF(SUM(S.SALE_AM),0)*100 >= @TH_TGT
                                                                               THEN N'0.목표 달성'
         ELSE N'3.보통' END
FROM       #SAL  S
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = S.ITEM_CD
GROUP BY S.ITEM_CD, I.ITEM_NM, I.SPEC, I.UNIT_CD, I.ACCT_FG
ORDER BY 판정, 매출이익
;


/*==============================================================================================
  ** 쿼리 B : 거래처별 매출이익
==============================================================================================*/
SELECT
     N'[B] 거래처별 매출이익'                       AS REPORT_NM
    ,S.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,COUNT(*)                                       AS 마감건수
    ,COUNT(DISTINCT S.ITEM_CD)                      AS 품목수
    ,SUM(S.CLS_QT)                                  AS 판매수량
    ,SUM(S.SALE_AM)                                 AS 매출액
    ,SUM(S.COST_AM)                                 AS 매출원가
    ,매출이익 = SUM(S.SALE_AM) - SUM(S.COST_AM)
    ,이익률_PCT = CAST((SUM(S.SALE_AM) - SUM(S.COST_AM))
                       / NULLIF(SUM(S.SALE_AM), 0) * 100 AS DECIMAL(5,1))
    ,매출기여도_PCT = CAST(SUM(S.SALE_AM) * 100.0
                           / NULLIF(SUM(SUM(S.SALE_AM)) OVER (), 0) AS DECIMAL(5,1))
    ,이익기여도_PCT = CAST((SUM(S.SALE_AM)-SUM(S.COST_AM)) * 100.0
                           / NULLIF(SUM(SUM(S.SALE_AM)-SUM(S.COST_AM)) OVER (), 0) AS DECIMAL(5,1))
    ,역마진품목수 = COUNT(DISTINCT CASE WHEN S.SALE_AM < S.COST_AM THEN S.ITEM_CD END)
    ,판정 = CASE
         WHEN SUM(S.SALE_AM) - SUM(S.COST_AM) < 0                              THEN N'1.★역마진 거래처'
         WHEN (SUM(S.SALE_AM)-SUM(S.COST_AM))/NULLIF(SUM(S.SALE_AM),0)*100 < @TH_LOW
                                                                               THEN N'2.★저마진 거래처'
         WHEN (SUM(S.SALE_AM)-SUM(S.COST_AM))/NULLIF(SUM(S.SALE_AM),0)*100 >= @TH_TGT
                                                                               THEN N'0.우량'
         ELSE N'3.보통' END
    ,비고 = CASE
         WHEN SUM(S.SALE_AM) * 100.0 / NULLIF(SUM(SUM(S.SALE_AM)) OVER (), 0) > 10
          AND (SUM(S.SALE_AM)-SUM(S.COST_AM))/NULLIF(SUM(S.SALE_AM),0)*100 < @TH_LOW
              THEN N'★ 매출 비중 10% 초과인데 저마진 - 단가 재협상 우선 대상'
         ELSE N'-' END
FROM       #SAL   S
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD = S.TR_CD
GROUP BY S.TR_CD, T.TR_NM
ORDER BY 판정, 매출이익
;


/*==============================================================================================
  ** 쿼리 C : 영업담당별 매출이익
==============================================================================================*/
SELECT
     N'[C] 영업담당별 매출이익'                     AS REPORT_NM
    ,S.EMP_CD                                       AS 담당자코드
    ,E.EMP_NM                                       AS 담당자명
    ,P.DEPT_NM                                      AS 부서명
    ,COUNT(*)                                       AS 마감건수
    ,COUNT(DISTINCT S.TR_CD)                        AS 담당거래처수
    ,COUNT(DISTINCT S.ITEM_CD)                      AS 품목수
    ,SUM(S.SALE_AM)                                 AS 매출액
    ,SUM(S.COST_AM)                                 AS 매출원가
    ,매출이익 = SUM(S.SALE_AM) - SUM(S.COST_AM)
    ,이익률_PCT = CAST((SUM(S.SALE_AM) - SUM(S.COST_AM))
                       / NULLIF(SUM(S.SALE_AM), 0) * 100 AS DECIMAL(5,1))
    ,매출기여도_PCT = CAST(SUM(S.SALE_AM) * 100.0
                           / NULLIF(SUM(SUM(S.SALE_AM)) OVER (), 0) AS DECIMAL(5,1))
    ,이익기여도_PCT = CAST((SUM(S.SALE_AM)-SUM(S.COST_AM)) * 100.0
                           / NULLIF(SUM(SUM(S.SALE_AM)-SUM(S.COST_AM)) OVER (), 0) AS DECIMAL(5,1))
    ,역마진건수 = SUM(CASE WHEN S.SALE_AM < S.COST_AM THEN 1 ELSE 0 END)
    ,판정 = CASE
         WHEN (SUM(S.SALE_AM)-SUM(S.COST_AM))/NULLIF(SUM(S.SALE_AM),0)*100 >= @TH_TGT
              THEN N'0.목표 달성'
         WHEN (SUM(S.SALE_AM)-SUM(S.COST_AM))/NULLIF(SUM(S.SALE_AM),0)*100 < @TH_LOW
              THEN N'1.★저마진 - 수주 단가 관리 필요'
         ELSE N'2.보통' END
    ,비고 = CASE
         WHEN SUM(S.SALE_AM) * 100.0 / NULLIF(SUM(SUM(S.SALE_AM)) OVER (), 0)
              > (SUM(S.SALE_AM)-SUM(S.COST_AM)) * 100.0
                / NULLIF(SUM(SUM(S.SALE_AM)-SUM(S.COST_AM)) OVER (), 0) * 1.3
              THEN N'★ 매출 비중보다 이익 비중이 낮음 - 저마진 품목 편중'
         ELSE N'-' END
FROM       #SAL  S
LEFT  JOIN SEMP  E WITH (NOLOCK) ON E.CO_CD = @CO_CD AND E.EMP_CD  = S.EMP_CD
LEFT  JOIN SDEPT P WITH (NOLOCK) ON P.CO_CD = @CO_CD AND P.DEPT_CD = E.DEPT_CD
GROUP BY S.EMP_CD, E.EMP_NM, P.DEPT_NM
ORDER BY 판정, 이익률_PCT
;


/*==============================================================================================
  ** 쿼리 D : 역마진 · 저마진 상세  ★ 이 리포트의 첫째 목적
==============================================================================================*/
SELECT
     N'[D] 역마진 · 저마진 상세'                    AS REPORT_NM
    ,구분 = CASE WHEN S.SALE_AM < S.COST_AM THEN N'1.★역마진'
                 ELSE N'2.★저마진(' + CAST(@TH_LOW AS NVARCHAR(10)) + N'% 미만)' END
    ,S.CLS_NB                                       AS 마감번호
    ,S.CLS_SQ                                       AS 마감순번
    ,S.CLS_DT                                       AS 마감일
    ,S.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,S.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,계정구분 = CASE I.ACCT_FG WHEN N'2' THEN N'제품' WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품' ELSE I.ACCT_FG END
    ,S.CLS_QT                                       AS 판매수량
    ,S.SALE_UM                                      AS 판매단가
    ,S.COST_UM                                      AS 단위원가
    ,단위손익 = CAST(S.SALE_UM - S.COST_UM AS DECIMAL(19,4))
    ,S.SALE_AM                                      AS 매출액
    ,S.COST_AM                                      AS 매출원가
    ,매출이익 = S.SALE_AM - S.COST_AM
    ,이익률_PCT = CAST((S.SALE_AM - S.COST_AM) / NULLIF(S.SALE_AM, 0) * 100 AS DECIMAL(5,1))
    ,S.UM_SRC                                       AS 원가출처
    ,S.EMP_CD                                       AS 영업담당
    ,E.EMP_NM                                       AS 담당자명
    ,S.PJT_CD                                       AS 프로젝트
    ,확인사항 = CASE
         WHEN S.UM_SRC = N'STD'
              THEN N'★ 마스터 표준단가 기준 - 실제 원가와 괴리 가능. 원가차수 마감 후 재확인'
         WHEN S.UM_SRC = N'PRD' AND I.ACCT_FG = N'5'
              THEN N'★ 상품에 제조원가 적용 - 매입원가로 재산출 필요'
         WHEN S.SALE_UM < S.COST_UM * 0.5
              THEN N'★ 판매단가가 원가의 절반 미만 - 단가 등록 오류 의심'
         ELSE N'단가 재협상 또는 원가절감 대상' END
FROM       #SAL   S
LEFT  JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = S.ITEM_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = S.TR_CD
LEFT  JOIN SEMP   E WITH (NOLOCK) ON E.CO_CD = @CO_CD AND E.EMP_CD  = S.EMP_CD
WHERE  S.UM_SRC <> N'없음'
  AND  S.SALE_AM <> 0
  AND  (S.SALE_AM < S.COST_AM
     OR (S.SALE_AM - S.COST_AM) / NULLIF(S.SALE_AM, 0) * 100 < @TH_LOW)
ORDER BY 구분, 매출이익
;


/*==============================================================================================
  ** 쿼리 E : 월별 매출이익 추이
==============================================================================================*/
SELECT
     N'[E] 월별 매출이익 추이'                      AS REPORT_NM
    ,LEFT(S.CLS_DT, 6)                              AS 마감월
    ,COUNT(*)                                       AS 마감건수
    ,COUNT(DISTINCT S.TR_CD)                        AS 거래처수
    ,COUNT(DISTINCT S.ITEM_CD)                      AS 품목수
    ,SUM(S.SALE_AM)                                 AS 매출액
    ,SUM(S.COST_AM)                                 AS 매출원가
    ,매출이익 = SUM(S.SALE_AM) - SUM(S.COST_AM)
    ,이익률_PCT = CAST((SUM(S.SALE_AM) - SUM(S.COST_AM))
                       / NULLIF(SUM(S.SALE_AM), 0) * 100 AS DECIMAL(5,1))
    ,역마진건수 = SUM(CASE WHEN S.SALE_AM < S.COST_AM THEN 1 ELSE 0 END)
    ,역마진금액 = SUM(CASE WHEN S.SALE_AM < S.COST_AM THEN S.SALE_AM - S.COST_AM ELSE 0 END)
    ,전월대비_이익률_PCTP = CAST(
         (SUM(S.SALE_AM)-SUM(S.COST_AM)) / NULLIF(SUM(S.SALE_AM),0) * 100
       - LAG((SUM(S.SALE_AM)-SUM(S.COST_AM)) / NULLIF(SUM(S.SALE_AM),0) * 100)
             OVER (ORDER BY LEFT(S.CLS_DT, 6)) AS DECIMAL(5,1))
    ,@TH_TGT                                        AS 목표이익률_PCT
    ,목표달성 = CASE WHEN (SUM(S.SALE_AM)-SUM(S.COST_AM))/NULLIF(SUM(S.SALE_AM),0)*100 >= @TH_TGT
                     THEN N'O' ELSE N'X' END
FROM   #SAL S
GROUP BY LEFT(S.CLS_DT, 6)
ORDER BY 마감월
;


/*==============================================================================================
  ** 쿼리 F : 전사 요약 (경영 보고 1행)
==============================================================================================*/
SELECT
     N'[F] 매출이익 요약'                           AS REPORT_NM
    ,@FR_DT + N' ~ ' + @TO_DT                       AS 기간
    ,원가기준 = @UM_SRC + CASE WHEN @CHASU IS NOT NULL
                               THEN N' (차수 ' + CAST(@CHASU AS NVARCHAR(10)) + N'/' + @CH_ST + N')'
                               ELSE N'' END
    ,COUNT(*)                                       AS 마감건수
    ,COUNT(DISTINCT S.TR_CD)                        AS 거래처수
    ,COUNT(DISTINCT S.ITEM_CD)                      AS 품목수
    ,SUM(S.SALE_AM)                                 AS 매출액계
    ,SUM(S.COST_AM)                                 AS 매출원가계
    ,매출이익계 = SUM(S.SALE_AM) - SUM(S.COST_AM)
    ,전사이익률_PCT = CAST((SUM(S.SALE_AM) - SUM(S.COST_AM))
                           / NULLIF(SUM(S.SALE_AM), 0) * 100 AS DECIMAL(5,1))
    ,@TH_TGT                                        AS 목표이익률_PCT
    ,역마진건수 = SUM(CASE WHEN S.SALE_AM < S.COST_AM THEN 1 ELSE 0 END)
    ,역마진금액 = SUM(CASE WHEN S.SALE_AM < S.COST_AM THEN S.SALE_AM - S.COST_AM ELSE 0 END)
    ,원가없음건수 = SUM(CASE WHEN S.UM_SRC = N'없음' THEN 1 ELSE 0 END)
    ,원가없음매출 = SUM(CASE WHEN S.UM_SRC = N'없음' THEN S.SALE_AM ELSE 0 END)
    ,원가커버리지_PCT = CAST(SUM(CASE WHEN S.UM_SRC <> N'없음' THEN S.SALE_AM ELSE 0 END) * 100.0
                             / NULLIF(SUM(S.SALE_AM), 0) AS DECIMAL(5,1))
    ,판정 = CASE
         WHEN SUM(CASE WHEN S.UM_SRC <> N'없음' THEN S.SALE_AM ELSE 0 END)
              / NULLIF(SUM(S.SALE_AM), 0) < 0.8
              THEN N'1.★원가 커버리지 80% 미만 - 이익 수치 신뢰 불가. 쿼리 G 확인'
         WHEN SUM(CASE WHEN S.SALE_AM < S.COST_AM THEN 1 ELSE 0 END) > 0
              THEN N'2.★역마진 거래 존재'
         WHEN (SUM(S.SALE_AM)-SUM(S.COST_AM))/NULLIF(SUM(S.SALE_AM),0)*100 < @TH_TGT
              THEN N'3.목표 이익률 미달'
         ELSE N'0.정상' END
FROM   #SAL S
;


/*==============================================================================================
  ** 쿼리 G : 원가 소스 커버리지  ★ 이익 수치를 믿어도 되는지 판단하는 선행 지표
     ─ 소스가 섞이면 이익률 비교가 왜곡된다. 어느 소스가 얼마나 쓰였는지 반드시 확인할 것.
==============================================================================================*/
SELECT
     N'[G] 원가 소스 커버리지'                      AS REPORT_NM
    ,원가출처 = CASE S.UM_SRC
         WHEN N'PRD'  THEN N'1.제조원가 (CIV_PRD_TAV)'
         WHEN N'FIFO' THEN N'2.평가 후 출고단가 (LINV_MVFIFO)'
         WHEN N'TAV'  THEN N'3.기간 평가단가 (LINV_TAV)'
         WHEN N'STD'  THEN N'4.마스터 표준단가 (SITEM) ★실제와 괴리 가능'
         ELSE              N'9.★원가 없음 - 이익 산출 불가' END
    ,COUNT(*)                                       AS 마감건수
    ,COUNT(DISTINCT S.ITEM_CD)                      AS 품목수
    ,SUM(S.SALE_AM)                                 AS 매출액
    ,SUM(S.COST_AM)                                 AS 매출원가
    ,매출이익 = SUM(S.SALE_AM) - SUM(S.COST_AM)
    ,이익률_PCT = CAST((SUM(S.SALE_AM) - SUM(S.COST_AM))
                       / NULLIF(SUM(S.SALE_AM), 0) * 100 AS DECIMAL(5,1))
    ,매출비중_PCT = CAST(SUM(S.SALE_AM) * 100.0
                         / NULLIF(SUM(SUM(S.SALE_AM)) OVER (), 0) AS DECIMAL(5,1))
    ,신뢰도 = CASE S.UM_SRC
         WHEN N'PRD'  THEN N'높음 (원가계산 결과)'
         WHEN N'FIFO' THEN N'높음 (평가 확정)'
         WHEN N'TAV'  THEN N'보통 (기간 평균)'
         WHEN N'STD'  THEN N'★낮음 - 이 비중이 크면 이익률을 대외 보고에 쓰지 말 것'
         ELSE              N'★산출 불가' END
FROM   #SAL S
GROUP BY S.UM_SRC
ORDER BY 원가출처
;

-- 원가 없는 품목 목록
SELECT TOP 50
     N'[G-2] 원가 미확보 품목'                      AS REPORT_NM
    ,S.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
    ,SUM(S.CLS_QT)                                  AS 판매수량
    ,SUM(S.SALE_AM)                                 AS 매출액
    ,조치 = CASE
         WHEN I.ACCT_FG IN (N'2', N'4') THEN N'원가계산 대상인데 CIV_PRD_TAV 에 없음 - 원가계산 SP 확인'
         WHEN I.ACCT_FG = N'5'          THEN N'상품 - 매입단가(LINV_TAV/FIFO) 또는 SITEM.PUR_UM 등록 필요'
         ELSE N'마스터 단가 등록 필요' END
FROM       #SAL  S
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = S.ITEM_CD
WHERE  S.UM_SRC = N'없음'
GROUP BY S.ITEM_CD, I.ITEM_NM, I.ACCT_FG
ORDER BY 매출액 DESC
;


DROP TABLE #UM, #SAL;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 매출 금액 컬럼 확인  ★ 공급가액(부가세 제외)을 써야 이익이 맞다
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('LSALECLS_D') AND name LIKE '%AM';
     --> 본 쿼리는 CLSG_AM(공급가) 우선, 없으면 CLSH_AM(합계) 을 쓴다.
        CLSH_AM 을 쓰면 부가세가 매출에 섞여 이익률이 부풀려진다. 반드시 확인할 것.

  -- (2) 재고평가 방법  ★ 원가 소스 선택의 근거
     SELECT name FROM sys.tables WHERE name IN ('LINV_MVFIFO','LINV_TAV','CIV_PRD_TAV');
     --> 선입선출 사이트면 @UM_SRC='FIFO', 이동/총평균이면 'TAV' 로 고정하는 편이
        AUTO 보다 일관성이 높다. 소스가 섞이면 품목 간 이익률 비교가 왜곡된다.

  -- (3) 원가차수 마감 상태
     SELECT P_YR, CHASU, CLS_YN FROM CIV_CHASU WHERE CO_CD='1000' ORDER BY CHASU DESC;
     --> 마감 차수가 없으면 'PRD' 는 쓰지 말 것.

  -- (4) 상품(ACCT_FG='5') 비중  ★ 제조원가로 커버되지 않는 영역
     SELECT I.ACCT_FG, COUNT(*) 건수, SUM(D.CLSG_AM) 매출
     FROM   LSALECLS_D D LEFT JOIN SITEM I ON I.CO_CD=D.CO_CD AND I.ITEM_CD=D.ITEM_CD
     WHERE  D.CO_CD='1000' GROUP BY I.ACCT_FG;
     --> 상품 비중이 크면 @UM_SRC='PRD' 고정은 금물이다 (원가 0 → 이익 폭증).

  -- (5) 목표 이익률 실측  ★ @TH_TGT(25%)가 현실적인지 판단
     --> 쿼리 F 를 먼저 돌려 전사 이익률을 본 뒤 @TH_TGT 를 조정할 것.
        기본값 25% 는 일반적인 제조업 총이익률 가정이며, 업종별로 크게 다르다.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **여기서 말하는 이익은 매출총이익(Gross Margin)이다.** 판관비·물류비·영업비용을 반영하지
     않았으므로 **영업이익이 아니다.** 거래처별 실제 수익성을 보려면 배송비·판촉비 등을
     배부해야 하며, 그건 별도 설계가 필요하다.

  2) **원가 소스가 섞이면 품목 간 이익률 비교가 왜곡된다.** 제조원가(PRD)와 마스터 표준단가
     (STD)는 성격이 완전히 다르다. 쿼리 G 의 매출비중을 보고, STD 비중이 크면 @UM_SRC 를
     하나로 고정하거나 마스터 단가를 먼저 정비할 것.

  3) **단위원가를 기간 단일값으로 쓴다.** 원가는 차수마다 달라지는데 본 쿼리는 한 차수의
     단가를 기간 전체 판매에 적용한다. 월별 원가 변동이 큰 사이트에서는 월별로 차수를 나눠
     돌리는 편이 정확하다.

  4) 반품(음수 마감)을 별도 처리하지 않는다. 마감 데이터에 음수가 있으면 그대로 상계된다.
     반품을 분리해 보려면 `CLS_QT < 0` 조건으로 나눠 조회할 것.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   C03_제품별_원가구성.sql      : 원가가 무엇으로 구성되는가 (본 리포트의 원가 소스)
   C04_표준원가_차이분석.sql    : 원가가 왜 표준과 벌어졌는가
   S06_채권여신_관리현황.sql    : 이익이 나도 회수가 안 되면 의미 없다
   E01_경영KPI_대시보드.sql     : 매출액 타일의 드릴다운 대상
==============================================================================================*/
