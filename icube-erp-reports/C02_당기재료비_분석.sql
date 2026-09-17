/*==============================================================================================
  [ iCUBE ] C-02  당기 재료비 분석                                                   (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 재료비를 **자재 쪽에서** 본다. C-03 이 "이 제품의 원가 구성"이라면,
         이 파일은 "**어느 자재가 재료비를 가장 많이 먹는가**"다. 원가절감 과제 도출의 출발점.

  DBMS : MS-SQL Server (T-SQL)
  ERP 대응 : `USP_COT0020_SELECT` (당기 재료비 분석)

  ----------------------------------------------------------------------------------------------
  [ 소스 ]
  ----------------------------------------------------------------------------------------------
     CIV_PRD_TAV     제조원가 (모품목별 MTL_AM 재료비 총액)
     CIV_PRD_TAV_D   재료비 상세 (PITEM_CD 모품 × CITEM_CD 자품 × USE_QT × REAL_QT 원단위 × USE_AM)
     CIV_CHASU       원가차수

  ----------------------------------------------------------------------------------------------
  [ 산식 ]
  ----------------------------------------------------------------------------------------------
     자재별 재료비 = Σ USE_AM  (모품목 전체 합산)
     원단위 REAL_QT = 자재 사용량 / 모품목 생산량
     자재 기여도 = 자재별 재료비 / 전체 재료비 * 100
     전차수 대비 = 당차수 / 전차수 - 1

  ----------------------------------------------------------------------------------------------
  [ 주의 ]
  ----------------------------------------------------------------------------------------------
     `CIV_CHASU.CLS_YN='1'`(마감) 차수만 신뢰할 수 있다. 미마감이면 값이 불완전하다.
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@P_YR     NVARCHAR(4)  = N'2026'
    ,@CHASU    INT          = NULL            -- 당차수 (NULL = 최신 마감)
    ,@PREV     INT          = NULL            -- 전차수 (NULL = 직전 마감)
    ,@PITEM_CD NVARCHAR(25) = NULL            -- 모품목
    ,@CITEM_CD NVARCHAR(25) = NULL            -- 자품목
    ,@PARETO   DECIMAL(5,1) = 80.0            -- 파레토 기준 누적구성비
    ,@TH_CHG   DECIMAL(5,1) = 10.0            -- 전차수 대비 변동 경고 (%)
;

DECLARE @SQL NVARCHAR(MAX);
DECLARE @CH_ST NVARCHAR(20) = N'없음', @PV_ST NVARCHAR(20) = N'없음';

IF OBJECT_ID('tempdb..#MTL') IS NOT NULL DROP TABLE #MTL;
IF OBJECT_ID('tempdb..#PRD') IS NOT NULL DROP TABLE #PRD;

CREATE TABLE #MTL (
     TAG      NCHAR(1)            -- C 당차수 / P 전차수
    ,PITEM_CD NVARCHAR(25)
    ,CITEM_CD NVARCHAR(25)
    ,USE_QT   DECIMAL(19,6)
    ,REAL_QT  DECIMAL(19,6)
    ,MTL_UM   DECIMAL(19,6)
    ,USE_AM   DECIMAL(19,4)
);
CREATE TABLE #PRD (
     TAG      NCHAR(1)
    ,ITEM_CD  NVARCHAR(25)
    ,PRD_QT   DECIMAL(19,6)
    ,MTL_AM   DECIMAL(19,4)
    ,PRD_AM   DECIMAL(19,4)
);


/*==============================================================================================
  1. 차수 결정
==============================================================================================*/
IF OBJECT_ID(N'dbo.CIV_CHASU', N'U') IS NOT NULL
BEGIN
    IF @CHASU IS NULL
        SELECT TOP 1 @CHASU = CHASU FROM CIV_CHASU WITH (NOLOCK)
        WHERE CO_CD=@CO_CD AND P_YR=@P_YR AND ISNULL(CLS_YN,N'0')=N'1' ORDER BY CHASU DESC;
    IF @CHASU IS NULL
        SELECT TOP 1 @CHASU = CHASU FROM CIV_CHASU WITH (NOLOCK)
        WHERE CO_CD=@CO_CD AND P_YR=@P_YR ORDER BY CHASU DESC;

    SELECT @CH_ST = CASE WHEN ISNULL(CLS_YN,N'0')=N'1' THEN N'마감' ELSE N'★미마감' END
    FROM   CIV_CHASU WITH (NOLOCK) WHERE CO_CD=@CO_CD AND P_YR=@P_YR AND CHASU=@CHASU;

    IF @PREV IS NULL AND @CHASU IS NOT NULL
        SELECT TOP 1 @PREV = CHASU FROM CIV_CHASU WITH (NOLOCK)
        WHERE CO_CD=@CO_CD AND P_YR=@P_YR AND CHASU < @CHASU ORDER BY CHASU DESC;

    SELECT @PV_ST = CASE WHEN ISNULL(CLS_YN,N'0')=N'1' THEN N'마감' ELSE N'★미마감' END
    FROM   CIV_CHASU WITH (NOLOCK) WHERE CO_CD=@CO_CD AND P_YR=@P_YR AND CHASU=@PREV;
END
PRINT N'[1] 당차수 ' + ISNULL(CAST(@CHASU AS NVARCHAR(10)),N'없음') + N'(' + @CH_ST + N')'
    + N' / 전차수 ' + ISNULL(CAST(@PREV AS NVARCHAR(10)),N'없음') + N'(' + @PV_ST + N')';


/*==============================================================================================
  2. 적재
==============================================================================================*/
IF OBJECT_ID(N'dbo.CIV_PRD_TAV_D', N'U') IS NOT NULL AND @CHASU IS NOT NULL
BEGIN
    SET @SQL = N'
        INSERT INTO #MTL (TAG, PITEM_CD, CITEM_CD, USE_QT, REAL_QT, MTL_UM, USE_AM)
        SELECT CASE WHEN D.CHASU = @p_CH THEN N''C'' ELSE N''P'' END
              ,D.PITEM_CD, D.CITEM_CD
              ,SUM(CAST(ISNULL(D.USE_QT ,0) AS DECIMAL(19,6)))
              ,CAST(AVG(CAST(ISNULL(D.REAL_QT,0) AS DECIMAL(19,6))) AS DECIMAL(19,6))
              ,CAST(AVG(CAST(NULLIF(D.MTL_UM,0) AS DECIMAL(19,6))) AS DECIMAL(19,6))
              ,SUM(CAST(ISNULL(D.USE_AM ,0) AS DECIMAL(19,4)))
        FROM   dbo.CIV_PRD_TAV_D D WITH (NOLOCK)
        WHERE  D.CO_CD = @p_CO AND D.P_YR = @p_YR AND D.CHASU IN (@p_CH, @p_PV)
          AND  (@p_DIV IS NULL OR D.DIV_CD = @p_DIV)
          AND  (@p_PI  IS NULL OR D.PITEM_CD = @p_PI)
          AND  (@p_CI  IS NULL OR D.CITEM_CD = @p_CI)
        GROUP BY CASE WHEN D.CHASU = @p_CH THEN N''C'' ELSE N''P'' END, D.PITEM_CD, D.CITEM_CD';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YR NVARCHAR(4), @p_CH INT, @p_PV INT
              ,@p_PI NVARCHAR(25), @p_CI NVARCHAR(25)'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_YR=@P_YR, @p_CH=@CHASU, @p_PV=@PREV
            ,@p_PI=@PITEM_CD, @p_CI=@CITEM_CD;
        PRINT N'[2] CIV_PRD_TAV_D : ' + CAST((SELECT COUNT(*) FROM #MTL) AS NVARCHAR(20)) + N' 행';
    END TRY BEGIN CATCH PRINT N'[2] ★ CIV_PRD_TAV_D 조회 실패 : ' + ERROR_MESSAGE(); END CATCH
END

IF OBJECT_ID(N'dbo.CIV_PRD_TAV', N'U') IS NOT NULL AND @CHASU IS NOT NULL
BEGIN
    SET @SQL = N'
        INSERT INTO #PRD (TAG, ITEM_CD, PRD_QT, MTL_AM, PRD_AM)
        SELECT CASE WHEN P.CHASU = @p_CH THEN N''C'' ELSE N''P'' END
              ,P.ITEM_CD
              ,SUM(CAST(ISNULL(P.PRD_QT,0) AS DECIMAL(19,6)))
              ,SUM(CAST(ISNULL(P.MTL_AM,0) AS DECIMAL(19,4)))
              ,SUM(CAST(ISNULL(P.PRD_AM,0) AS DECIMAL(19,4)))
        FROM   dbo.CIV_PRD_TAV P WITH (NOLOCK)
        WHERE  P.CO_CD = @p_CO AND P.P_YR = @p_YR AND P.CHASU IN (@p_CH, @p_PV)
          AND  (@p_DIV IS NULL OR P.DIV_CD = @p_DIV)
          AND  (@p_PI  IS NULL OR P.ITEM_CD = @p_PI)
        GROUP BY CASE WHEN P.CHASU = @p_CH THEN N''C'' ELSE N''P'' END, P.ITEM_CD';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YR NVARCHAR(4), @p_CH INT, @p_PV INT
              ,@p_PI NVARCHAR(25)'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_YR=@P_YR, @p_CH=@CHASU, @p_PV=@PREV, @p_PI=@PITEM_CD;
    END TRY BEGIN CATCH END CATCH
END

CREATE CLUSTERED INDEX IX_MTL ON #MTL (TAG, CITEM_CD, PITEM_CD);
CREATE CLUSTERED INDEX IX_PRD ON #PRD (TAG, ITEM_CD);


/*==============================================================================================
  ** 쿼리 A : 자재별 재료비 파레토  ★ 이 파일의 핵심 — 무엇부터 줄일 것인가
==============================================================================================*/
;WITH X AS (
    SELECT
         M.CITEM_CD
        ,AM = SUM(M.USE_AM)
        ,QT = SUM(M.USE_QT)
        ,PI_CNT = COUNT(DISTINCT M.PITEM_CD)
        ,UM = CAST(AVG(M.MTL_UM) AS DECIMAL(19,6))
    FROM   #MTL M WHERE M.TAG = N'C'
    GROUP BY M.CITEM_CD
), Y AS (
    SELECT X.*
          ,CUM = SUM(X.AM) OVER (ORDER BY X.AM DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
          ,TOT = SUM(X.AM) OVER ()
          ,RNK = ROW_NUMBER() OVER (ORDER BY X.AM DESC)
    FROM X
)
SELECT
     N'[A] 자재별 재료비 파레토'                    AS REPORT_NM
    ,Y.RNK                                          AS 순위
    ,Y.CITEM_CD                                     AS 자재품번
    ,I.ITEM_NM                                      AS 자재품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'4' THEN N'반제품' ELSE I.ACCT_FG END
    ,Y.QT                                           AS 사용수량
    ,Y.UM                                           AS 평균단가
    ,Y.AM                                           AS 재료비
    ,Y.PI_CNT                                       AS 투입제품수
    ,구성비_PCT   = CAST(Y.AM * 100.0 / NULLIF(Y.TOT, 0) AS DECIMAL(5,1))
    ,누적구성비_PCT = CAST(Y.CUM * 100.0 / NULLIF(Y.TOT, 0) AS DECIMAL(5,1))
    ,구분 = CASE WHEN Y.CUM * 100.0 / NULLIF(Y.TOT, 0) <= @PARETO
                 THEN N'1.★핵심 소수 (우선 절감 대상)' ELSE N'2.기타 다수' END
    -- 전차수 대비
    ,전차수_재료비 = P.AM
    ,증감액 = Y.AM - ISNULL(P.AM, 0)
    ,증감률_PCT = CAST(CASE WHEN ISNULL(P.AM, 0) <> 0
                            THEN (Y.AM / P.AM - 1) * 100 END AS DECIMAL(9,1))
    ,전차수_수량 = P.QT
    ,전차수_단가 = P.UM
    ,단가증감률_PCT = CAST(CASE WHEN ISNULL(P.UM, 0) <> 0
                                THEN (Y.UM / P.UM - 1) * 100 END AS DECIMAL(9,1))
    ,수량증감률_PCT = CAST(CASE WHEN ISNULL(P.QT, 0) <> 0
                                THEN (Y.QT / P.QT - 1) * 100 END AS DECIMAL(9,1))
    ,증감요인 = CASE
         WHEN P.AM IS NULL                                        THEN N'신규'
         WHEN ABS(Y.AM / NULLIF(P.AM,0) - 1) * 100 <= @TH_CHG      THEN N'안정'
         WHEN ISNULL(P.UM,0) <> 0 AND ISNULL(P.QT,0) <> 0
          AND ABS(Y.UM/P.UM - 1) > ABS(Y.QT/P.QT - 1)              THEN N'★단가 변동 주도 (P-07 확인)'
         ELSE N'★사용량 변동 주도 (M-10 BOM 확인)' END
FROM       Y
LEFT  JOIN ( SELECT CITEM_CD, AM = SUM(USE_AM), QT = SUM(USE_QT)
                   ,UM = CAST(AVG(MTL_UM) AS DECIMAL(19,6))
             FROM #MTL WHERE TAG = N'P' GROUP BY CITEM_CD ) P ON P.CITEM_CD = Y.CITEM_CD
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = Y.CITEM_CD
ORDER BY Y.RNK
;


/*==============================================================================================
  ** 쿼리 B : 제품별 재료비 구성  (모품목 관점)
==============================================================================================*/
SELECT
     N'[B] 제품별 재료비 구성'                      AS REPORT_NM
    ,M.PITEM_CD                                     AS 제품품번
    ,PI.ITEM_NM                                     AS 제품품명
    ,PI.UNIT_CD                                     AS 단위
    ,D.PRD_QT                                       AS 생산수량
    ,자재종류수 = COUNT(DISTINCT M.CITEM_CD)
    ,재료비계 = SUM(M.USE_AM)
    ,제품_재료비 = D.MTL_AM
    ,차이 = SUM(M.USE_AM) - ISNULL(D.MTL_AM, 0)
    ,단위재료비 = CAST(SUM(M.USE_AM) / NULLIF(D.PRD_QT, 0) AS DECIMAL(19,4))
    ,제조원가 = D.PRD_AM
    ,재료비율_PCT = CAST(SUM(M.USE_AM) / NULLIF(D.PRD_AM, 0) * 100 AS DECIMAL(5,1))
    ,재료비기여도_PCT = CAST(SUM(M.USE_AM) * 100.0
                             / NULLIF(SUM(SUM(M.USE_AM)) OVER (), 0) AS DECIMAL(5,1))
    ,판정 = CASE
         WHEN ABS(SUM(M.USE_AM) - ISNULL(D.MTL_AM, 0)) > 1
              THEN N'1.★상세 합계 ≠ 제품 재료비 - 원가계산 재실행 확인'
         WHEN SUM(M.USE_AM) / NULLIF(D.PRD_AM, 0) * 100 > 80
              THEN N'2.재료비 비중 80% 초과 - 재료비 절감이 원가절감의 핵심'
         ELSE N'0.정상' END
FROM       #MTL  M
LEFT  JOIN #PRD  D  ON D.ITEM_CD = M.PITEM_CD AND D.TAG = N'C'
LEFT  JOIN SITEM PI WITH (NOLOCK) ON PI.CO_CD = @CO_CD AND PI.ITEM_CD = M.PITEM_CD
WHERE  M.TAG = N'C'
GROUP BY M.PITEM_CD, PI.ITEM_NM, PI.UNIT_CD, D.PRD_QT, D.MTL_AM, D.PRD_AM
ORDER BY 재료비계 DESC
;


/*==============================================================================================
  ** 쿼리 C : 제품 × 자재 원단위  ★ 전차수 대비 원단위 변화 = 낭비 발생 신호
==============================================================================================*/
SELECT
     N'[C] 제품 × 자재 원단위'                      AS REPORT_NM
    ,C.PITEM_CD                                     AS 제품품번
    ,PI.ITEM_NM                                     AS 제품품명
    ,C.CITEM_CD                                     AS 자재품번
    ,CI.ITEM_NM                                     AS 자재품명
    ,CI.UNIT_CD                                     AS 자재단위
    ,C.USE_QT                                       AS 사용수량
    ,C.REAL_QT                                      AS 원단위
    ,C.MTL_UM                                       AS 단가
    ,C.USE_AM                                       AS 재료비
    ,전차수_원단위 = P.REAL_QT
    ,전차수_단가   = P.MTL_UM
    ,전차수_재료비 = P.USE_AM
    ,원단위증감_PCT = CAST(CASE WHEN ISNULL(P.REAL_QT, 0) <> 0
                                THEN (C.REAL_QT / P.REAL_QT - 1) * 100 END AS DECIMAL(9,1))
    ,단가증감_PCT = CAST(CASE WHEN ISNULL(P.MTL_UM, 0) <> 0
                              THEN (C.MTL_UM / P.MTL_UM - 1) * 100 END AS DECIMAL(9,1))
    ,재료비증감액 = C.USE_AM - ISNULL(P.USE_AM, 0)
    ,판정 = CASE
         WHEN P.CITEM_CD IS NULL                                            THEN N'9.신규 자재'
         WHEN ISNULL(P.REAL_QT, 0) = 0                                      THEN N'8.전차수 원단위 0'
         WHEN (C.REAL_QT / P.REAL_QT - 1) * 100 > @TH_CHG
              THEN N'1.★원단위 증가 - 낭비 또는 불량 증가 의심'
         WHEN (C.REAL_QT / P.REAL_QT - 1) * 100 < -@TH_CHG
              THEN N'2.원단위 감소 - 개선 성과 또는 BOM 변경'
         WHEN ISNULL(P.MTL_UM,0) <> 0 AND ABS(C.MTL_UM / P.MTL_UM - 1) * 100 > @TH_CHG
              THEN N'3.★단가 변동 - 매입단가 확인 (P-07)'
         ELSE N'0.안정' END
FROM       #MTL  C
LEFT  JOIN #MTL  P  ON P.TAG = N'P' AND P.PITEM_CD = C.PITEM_CD AND P.CITEM_CD = C.CITEM_CD
LEFT  JOIN SITEM PI WITH (NOLOCK) ON PI.CO_CD = @CO_CD AND PI.ITEM_CD = C.PITEM_CD
LEFT  JOIN SITEM CI WITH (NOLOCK) ON CI.CO_CD = @CO_CD AND CI.ITEM_CD = C.CITEM_CD
WHERE  C.TAG = N'C'
ORDER BY 판정, ABS(재료비증감액) DESC
;


/*==============================================================================================
  ** 쿼리 D : 자재 → 제품 역전개  (이 자재가 어느 제품에 얼마나 들어가나)
==============================================================================================*/
SELECT
     N'[D] 자재 → 제품 역전개'                      AS REPORT_NM
    ,M.CITEM_CD                                     AS 자재품번
    ,CI.ITEM_NM                                     AS 자재품명
    ,CI.UNIT_CD                                     AS 단위
    ,M.PITEM_CD                                     AS 제품품번
    ,PI.ITEM_NM                                     AS 제품품명
    ,M.USE_QT                                       AS 사용수량
    ,M.REAL_QT                                      AS 원단위
    ,M.USE_AM                                       AS 재료비
    ,자재내_비중_PCT = CAST(M.USE_AM * 100.0
                            / NULLIF(SUM(M.USE_AM) OVER (PARTITION BY M.CITEM_CD), 0) AS DECIMAL(5,1))
    ,자재_총재료비 = SUM(M.USE_AM) OVER (PARTITION BY M.CITEM_CD)
    ,투입제품수 = COUNT(*) OVER (PARTITION BY M.CITEM_CD)
    ,비고 = CASE
         WHEN COUNT(*) OVER (PARTITION BY M.CITEM_CD) = 1
              THEN N'단일 제품 전용 자재 - 그 제품 원가에 직결'
         WHEN M.USE_AM * 100.0 / NULLIF(SUM(M.USE_AM) OVER (PARTITION BY M.CITEM_CD), 0) > 50
              THEN N'이 제품이 해당 자재의 절반 이상 소비'
         ELSE N'-' END
FROM       #MTL  M
LEFT  JOIN SITEM CI WITH (NOLOCK) ON CI.CO_CD = @CO_CD AND CI.ITEM_CD = M.CITEM_CD
LEFT  JOIN SITEM PI WITH (NOLOCK) ON PI.CO_CD = @CO_CD AND PI.ITEM_CD = M.PITEM_CD
WHERE  M.TAG = N'C'
  AND  (@CITEM_CD IS NULL OR M.CITEM_CD = @CITEM_CD)
ORDER BY 자재_총재료비 DESC, M.CITEM_CD, M.USE_AM DESC
;


/*==============================================================================================
  ** 쿼리 E : 요약 + 데이터 점검
==============================================================================================*/
SELECT
     N'[E] 당기 재료비 요약'                        AS REPORT_NM
    ,@P_YR                                          AS 회계연도
    ,@CHASU                                         AS 당차수
    ,@CH_ST                                         AS 당차수상태
    ,@PREV                                          AS 전차수
    ,@PV_ST                                         AS 전차수상태
    ,제품수   = COUNT(DISTINCT M.PITEM_CD)
    ,자재종류수 = COUNT(DISTINCT M.CITEM_CD)
    ,재료비계 = SUM(M.USE_AM)
    ,전차수_재료비계 = (SELECT SUM(USE_AM) FROM #MTL WHERE TAG = N'P')
    ,증감률_PCT = CAST(CASE WHEN (SELECT SUM(USE_AM) FROM #MTL WHERE TAG=N'P') <> 0
                            THEN (SUM(M.USE_AM) / (SELECT SUM(USE_AM) FROM #MTL WHERE TAG=N'P') - 1) * 100
                            END AS DECIMAL(9,1))
    ,파레토_핵심자재수 = (SELECT COUNT(*) FROM (
         SELECT CITEM_CD
               ,CUM = SUM(SUM(USE_AM)) OVER (ORDER BY SUM(USE_AM) DESC
                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
               ,TOT = SUM(SUM(USE_AM)) OVER ()
         FROM #MTL WHERE TAG = N'C' GROUP BY CITEM_CD) Z
         WHERE Z.CUM * 100.0 / NULLIF(Z.TOT, 0) <= @PARETO)
    ,제조원가계 = (SELECT SUM(PRD_AM) FROM #PRD WHERE TAG = N'C')
    ,재료비율_PCT = CAST(SUM(M.USE_AM)
                         / NULLIF((SELECT SUM(PRD_AM) FROM #PRD WHERE TAG=N'C'), 0)
                         * 100 AS DECIMAL(5,1))
    ,CIV_PRD_TAV_D = CASE WHEN OBJECT_ID(N'dbo.CIV_PRD_TAV_D',N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,판정 = CASE
         WHEN OBJECT_ID(N'dbo.CIV_PRD_TAV_D', N'U') IS NULL
              THEN N'1.★CIV_PRD_TAV_D 없음 - 재료비 상세 분석 불가'
         WHEN @CHASU IS NULL
              THEN N'2.★원가차수 없음 - 원가계산 SP 실행 필요'
         WHEN COUNT(*) = 0
              THEN N'3.★당차수에 재료비 데이터 없음'
         WHEN @CH_ST <> N'마감'
              THEN N'4.★미마감 차수 - 값이 불완전하다'
         WHEN @PREV IS NULL
              THEN N'5.전차수 없음 - 증감 비교 불가 (정상)'
         ELSE N'0.정상' END
FROM   #MTL M
WHERE  M.TAG = N'C'
;


DROP TABLE #MTL, #PRD;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) CIV_PRD_TAV_D 컬럼  ★ 본 쿼리의 전제
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('CIV_PRD_TAV_D') ORDER BY column_id;
     --> 전제 : PITEM_CD, CITEM_CD, USE_QT, REAL_QT, MTL_UM, USE_AM, CHASU, P_YR, DIV_CD

  -- (2) 원가차수 마감 상태
     SELECT P_YR, CHASU, CLS_YN FROM CIV_CHASU WHERE CO_CD='1000' ORDER BY CHASU DESC;

  -- (3) 상세 합계 vs 제품 재료비 대사  ★ 쿼리 B 의 '차이' 컬럼과 같은 목적
     SELECT (SELECT SUM(USE_AM) FROM CIV_PRD_TAV_D WHERE CO_CD='1000' AND P_YR='2026' AND CHASU=1) 상세합계
           ,(SELECT SUM(MTL_AM) FROM CIV_PRD_TAV   WHERE CO_CD='1000' AND P_YR='2026' AND CHASU=1) 제품합계;
     --> 크게 다르면 원가계산이 완결되지 않았다.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **원단위(REAL_QT)를 평균으로 집계**한다. 같은 제품·자재 조합이 여러 행이면 단순 평균이라
     가중평균과 다르다. 정확한 원단위는 `사용수량 / 생산수량` 으로 직접 계산할 것 (쿼리 B 참조).

  2) **다단 구조에서 반제품이 자재로 잡힌다.** 반제품(`ACCT_FG='4'`)이 자재 목록에 나오면
     그 안의 원재료는 다시 전개해야 최종 원재료 기준 파레토가 된다.
     쿼리 A 에서 `계정구분` 이 '반제품'인 항목은 한 단계 더 파고들 것.

  3) `증감요인` 판정(쿼리 A)은 단가·수량 변동률의 절대값 비교다. 둘 다 크면 주도 요인 판별이
     부정확하므로, 그때는 쿼리 C 로 제품별 원단위를 직접 볼 것.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   C03_제품별_원가구성.sql    : 제품 관점 원가 구성 (재료/외주/가공)
   C04_표준원가_차이분석.sql  : 표준 대비 수량/단가 차이 분해
   P07_매입단가_추이분석.sql  : 단가 변동의 원인 (구매 관점)
   M10_생산마스터_점검.sql    : 원단위 증가의 원인 (BOM vs 실사용)
==============================================================================================*/
