/*==============================================================================================
  [ iCUBE ] C-08  가공비 배부 검증                                                   (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : **상시 점검.** 가공비 총액이 품목에 제대로 배부되었는가.
         배부는 원가계산에서 가장 논쟁이 많은 부분이다. 배부기준이 바뀌면 품목별 단위원가가
         통째로 달라지는데, 그 사실이 드러나지 않으면 현업이 숫자를 믿지 않는다.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 소스 ]
  ----------------------------------------------------------------------------------------------
     CIV_OE          가공비 총액 (배부 전)
     CIV_CONVCST     가공비 배부 (METHOD_FG 배부기준)
     CIV_DIST_ITEM   품목별 배부 결과
     CIV_PRD_TAV     제조원가 (CONV_AM 가공비)

  ----------------------------------------------------------------------------------------------
  [ 검증 3가지 ]
  ----------------------------------------------------------------------------------------------
     ① **총액 일치**   가공비 총액(CIV_OE) = 배부액 합계(CIV_CONVCST) = 원가 반영액(CIV_PRD_TAV)
                       하나라도 어긋나면 가공비가 새거나 중복 반영된 것이다.
     ② **배부기준 일관성**  전차수와 같은 `METHOD_FG` 를 썼는가. 바뀌었으면 증감 비교가 무의미하다.
     ③ **배부 결과 합리성**  생산 없는 품목에 가공비가 붙었는가, 특정 품목에 쏠렸는가.
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
    ,@PREV     INT          = NULL            -- 전차수 (NULL = 직전)
    ,@TH_AM    DECIMAL(19,4) = 1.0            -- 총액 차이 임계 (원)
    ,@TH_SKEW  DECIMAL(5,1) = 50.0            -- 단일 품목 쏠림 경고 (%)
;

DECLARE @SQL NVARCHAR(MAX);
DECLARE @CH_ST NVARCHAR(20) = N'없음';
DECLARE @OE_AM DECIMAL(19,4) = NULL, @CV_AM DECIMAL(19,4) = NULL, @PD_AM DECIMAL(19,4) = NULL;
DECLARE @HAS_OE BIT = 0, @HAS_CV BIT = 0, @HAS_DI BIT = 0;

IF OBJECT_ID(N'dbo.CIV_OE'       , N'U') IS NOT NULL SET @HAS_OE = 1;
IF OBJECT_ID(N'dbo.CIV_CONVCST'  , N'U') IS NOT NULL SET @HAS_CV = 1;
IF OBJECT_ID(N'dbo.CIV_DIST_ITEM', N'U') IS NOT NULL SET @HAS_DI = 1;


/*==============================================================================================
  1. 차수 결정 + 총액 3종 수집
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
END

-- ① 가공비 총액 (CIV_OE)
IF @HAS_OE = 1 AND @CHASU IS NOT NULL
BEGIN
    SET @SQL = N'SELECT @o = SUM(CAST(ISNULL(OE_AM, 0) AS DECIMAL(19,4)))
                 FROM dbo.CIV_OE WITH (NOLOCK)
                 WHERE CO_CD=@p_CO AND P_YR=@p_YR AND CHASU=@p_CH
                   AND (@p_DIV IS NULL OR DIV_CD=@p_DIV)';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4),@p_DIV NVARCHAR(4),@p_YR NVARCHAR(4),@p_CH INT,@o DECIMAL(19,4) OUTPUT'
            ,@p_CO=@CO_CD,@p_DIV=@DIV_CD,@p_YR=@P_YR,@p_CH=@CHASU,@o=@OE_AM OUTPUT;
    END TRY BEGIN CATCH SET @HAS_OE = 0; PRINT N'[1] CIV_OE 조회 실패 (OE_AM 컬럼 확인)'; END CATCH
END

-- ② 배부액 합계 (CIV_CONVCST)
IF @HAS_CV = 1 AND @CHASU IS NOT NULL
BEGIN
    SET @SQL = N'SELECT @o = SUM(CAST(ISNULL(CONV_AM, 0) AS DECIMAL(19,4)))
                 FROM dbo.CIV_CONVCST WITH (NOLOCK)
                 WHERE CO_CD=@p_CO AND P_YR=@p_YR AND CHASU=@p_CH
                   AND (@p_DIV IS NULL OR DIV_CD=@p_DIV)';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4),@p_DIV NVARCHAR(4),@p_YR NVARCHAR(4),@p_CH INT,@o DECIMAL(19,4) OUTPUT'
            ,@p_CO=@CO_CD,@p_DIV=@DIV_CD,@p_YR=@P_YR,@p_CH=@CHASU,@o=@CV_AM OUTPUT;
    END TRY BEGIN CATCH SET @HAS_CV = 0; PRINT N'[1] CIV_CONVCST 조회 실패'; END CATCH
END

-- ③ 원가 반영액 (CIV_PRD_TAV)
IF OBJECT_ID(N'dbo.CIV_PRD_TAV', N'U') IS NOT NULL AND @CHASU IS NOT NULL
BEGIN
    SET @SQL = N'SELECT @o = SUM(CAST(ISNULL(CONV_AM, 0) AS DECIMAL(19,4)))
                 FROM dbo.CIV_PRD_TAV WITH (NOLOCK)
                 WHERE CO_CD=@p_CO AND P_YR=@p_YR AND CHASU=@p_CH
                   AND (@p_DIV IS NULL OR DIV_CD=@p_DIV)';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4),@p_DIV NVARCHAR(4),@p_YR NVARCHAR(4),@p_CH INT,@o DECIMAL(19,4) OUTPUT'
            ,@p_CO=@CO_CD,@p_DIV=@DIV_CD,@p_YR=@P_YR,@p_CH=@CHASU,@o=@PD_AM OUTPUT;
    END TRY BEGIN CATCH END CATCH
END

PRINT N'[1] 차수 ' + ISNULL(CAST(@CHASU AS NVARCHAR(10)),N'없음') + N'(' + @CH_ST + N')'
    + N' / OE=' + ISNULL(CAST(@OE_AM AS NVARCHAR(30)),N'?')
    + N' / 배부=' + ISNULL(CAST(@CV_AM AS NVARCHAR(30)),N'?')
    + N' / 원가=' + ISNULL(CAST(@PD_AM AS NVARCHAR(30)),N'?');


/*==============================================================================================
  ** 쿼리 A : 총액 3종 대사  ★ 검증 ① — 가공비가 새지 않았는가
==============================================================================================*/
SELECT
     N'[A] 가공비 총액 대사'                        AS REPORT_NM
    ,@P_YR                                          AS 회계연도
    ,@CHASU                                         AS 차수
    ,@CH_ST                                         AS 차수상태
    ,가공비총액_CIV_OE      = @OE_AM
    ,배부액합계_CIV_CONVCST = @CV_AM
    ,원가반영_CIV_PRD_TAV   = @PD_AM
    ,차이_총액대배부 = @OE_AM - @CV_AM
    ,차이_배부대원가 = @CV_AM - @PD_AM
    ,차이_총액대원가 = @OE_AM - @PD_AM
    ,배부율_PCT = CAST(@CV_AM / NULLIF(@OE_AM, 0) * 100 AS DECIMAL(9,2))
    ,반영률_PCT = CAST(@PD_AM / NULLIF(@CV_AM, 0) * 100 AS DECIMAL(9,2))
    ,판정 = CASE
         WHEN @CHASU IS NULL
              THEN N'9.★원가차수 없음'
         WHEN @HAS_OE = 0 AND @HAS_CV = 0
              THEN N'8.★가공비 테이블 없음 (CIV_OE / CIV_CONVCST) - 검증 불가'
         WHEN @OE_AM IS NULL OR @CV_AM IS NULL
              THEN N'7.★총액 조회 실패 - 컬럼명 확인 (아래 확인 쿼리)'
         WHEN ABS(ISNULL(@OE_AM,0) - ISNULL(@CV_AM,0)) > @TH_AM
              THEN N'1.★총액 ≠ 배부액 - 가공비 일부가 배부되지 않았다'
         WHEN ABS(ISNULL(@CV_AM,0) - ISNULL(@PD_AM,0)) > @TH_AM
              THEN N'2.★배부액 ≠ 원가반영액 - 배부 결과가 원가에 안 실렸다'
         ELSE N'0.정상 - 3종 일치' END
    ,조치 = CASE
         WHEN ABS(ISNULL(@OE_AM,0) - ISNULL(@CV_AM,0)) > @TH_AM
              THEN N'배부 기준에서 제외된 부문·항목이 있는지 확인 → 원가계산 재실행'
         WHEN ABS(ISNULL(@CV_AM,0) - ISNULL(@PD_AM,0)) > @TH_AM
              THEN N'배부 대상 품목이 CIV_PRD_TAV 에 없는지 확인 (쿼리 D)'
         ELSE N'-' END
;


/*==============================================================================================
  ** 쿼리 B : 배부기준별 배부액  ★ 검증 ② — 기준이 바뀌지 않았는가
==============================================================================================*/
IF @HAS_CV = 1
BEGIN
    SET @SQL = N'
    ;WITH X AS (
        SELECT
             TAG = CASE WHEN V.CHASU = @p_CH THEN N''C'' ELSE N''P'' END
            ,V.METHOD_FG
            ,AM  = SUM(CAST(ISNULL(V.CONV_AM, 0) AS DECIMAL(19,4)))
            ,CNT = COUNT(*)
            ,ITEM_N = COUNT(DISTINCT V.ITEM_CD)
        FROM   dbo.CIV_CONVCST V WITH (NOLOCK)
        WHERE  V.CO_CD = @p_CO AND V.P_YR = @p_YR AND V.CHASU IN (@p_CH, @p_PV)
          AND  (@p_DIV IS NULL OR V.DIV_CD = @p_DIV)
        GROUP BY CASE WHEN V.CHASU = @p_CH THEN N''C'' ELSE N''P'' END, V.METHOD_FG
    )
    SELECT
         N''[B] 배부기준별 배부액'' AS REPORT_NM
        ,ISNULL(C.METHOD_FG, P.METHOD_FG) AS 배부기준코드
        ,배부기준 = CASE ISNULL(C.METHOD_FG, P.METHOD_FG)
             WHEN N''0'' THEN N''0.수량기준''   WHEN N''1'' THEN N''1.금액기준''
             WHEN N''2'' THEN N''2.시간기준''   WHEN N''3'' THEN N''3.중량기준''
             WHEN N''4'' THEN N''4.직접노무비'' WHEN N''5'' THEN N''5.기계시간''
             WHEN N''6'' THEN N''6.직접재료비''
             ELSE N''9.'' + ISNULL(ISNULL(C.METHOD_FG, P.METHOD_FG), N''?'') END
        ,당차수_배부액 = ISNULL(C.AM, 0)
        ,당차수_품목수 = ISNULL(C.ITEM_N, 0)
        ,전차수_배부액 = P.AM
        ,전차수_품목수 = P.ITEM_N
        ,증감액 = ISNULL(C.AM, 0) - ISNULL(P.AM, 0)
        ,증감률_PCT = CAST(CASE WHEN ISNULL(P.AM, 0) <> 0
                                THEN (C.AM / P.AM - 1) * 100 END AS DECIMAL(9,1))
        ,구성비_PCT = CAST(ISNULL(C.AM,0) * 100.0
                           / NULLIF(SUM(ISNULL(C.AM,0)) OVER (), 0) AS DECIMAL(5,1))
        ,판정 = CASE
             WHEN C.METHOD_FG IS NULL
                  THEN N''1.★★전차수에만 있던 배부기준 - 기준이 바뀌었다''
             WHEN P.METHOD_FG IS NULL AND @p_PV IS NOT NULL
                  THEN N''2.★★당차수에만 있는 배부기준 - 기준이 바뀌었다''
             ELSE N''0.동일 기준 유지'' END
        ,비고 = CASE
             WHEN C.METHOD_FG IS NULL OR (P.METHOD_FG IS NULL AND @p_PV IS NOT NULL)
                  THEN N''★ 배부기준이 바뀌면 품목별 단위원가가 통째로 달라진다. 전차수 대비 비교 무의미''
             ELSE N''-'' END
    FROM      (SELECT * FROM X WHERE TAG = N''C'') C
    FULL JOIN (SELECT * FROM X WHERE TAG = N''P'') P ON P.METHOD_FG = C.METHOD_FG
    ORDER BY 판정 DESC, 당차수_배부액 DESC';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4),@p_DIV NVARCHAR(4),@p_YR NVARCHAR(4),@p_CH INT,@p_PV INT'
            ,@p_CO=@CO_CD,@p_DIV=@DIV_CD,@p_YR=@P_YR,@p_CH=@CHASU,@p_PV=@PREV;
    END TRY
    BEGIN CATCH
        SELECT N'[B] 배부기준별 배부액' AS REPORT_NM
              ,N'조회 실패 : ' + ERROR_MESSAGE() AS 결과
              ,N'METHOD_FG / CONV_AM 컬럼명을 확인할 것' AS 비고;
    END CATCH
END
ELSE
    SELECT N'[B] 배부기준별 배부액' AS REPORT_NM, N'CIV_CONVCST 없음 - 생략' AS 결과;


/*==============================================================================================
  ** 쿼리 C : 품목별 가공비 배부 결과  ★ 검증 ③ — 배부가 합리적인가
==============================================================================================*/
IF OBJECT_ID(N'dbo.CIV_PRD_TAV', N'U') IS NOT NULL AND @CHASU IS NOT NULL
BEGIN
    SET @SQL = N'
    ;WITH X AS (
        SELECT
             P.ITEM_CD
            ,PRD_QT  = SUM(CAST(ISNULL(P.PRD_QT ,0) AS DECIMAL(19,6)))
            ,MTL_AM  = SUM(CAST(ISNULL(P.MTL_AM ,0) AS DECIMAL(19,4)))
            ,LBR_AM  = SUM(CAST(ISNULL(P.LBR_AM ,0) AS DECIMAL(19,4)))
            ,CONV_AM = SUM(CAST(ISNULL(P.CONV_AM,0) AS DECIMAL(19,4)))
            ,PRD_AM  = SUM(CAST(ISNULL(P.PRD_AM ,0) AS DECIMAL(19,4)))
        FROM   dbo.CIV_PRD_TAV P WITH (NOLOCK)
        WHERE  P.CO_CD = @p_CO AND P.P_YR = @p_YR AND P.CHASU = @p_CH
          AND  (@p_DIV IS NULL OR P.DIV_CD = @p_DIV)
        GROUP BY P.ITEM_CD
    )
    SELECT
         N''[C] 품목별 가공비 배부'' AS REPORT_NM
        ,X.ITEM_CD                  AS 품번
        ,I.ITEM_NM                  AS 품명
        ,I.UNIT_CD                  AS 단위
        ,계정구분 = CASE I.ACCT_FG WHEN N''2'' THEN N''제품'' WHEN N''4'' THEN N''반제품''
                                   ELSE I.ACCT_FG END
        ,X.PRD_QT                   AS 생산수량
        ,X.MTL_AM                   AS 재료비
        ,X.LBR_AM                   AS 외주비
        ,X.CONV_AM                  AS 가공비
        ,X.PRD_AM                   AS 제조원가
        ,단위가공비 = CAST(X.CONV_AM / NULLIF(X.PRD_QT, 0) AS DECIMAL(19,4))
        ,가공비율_PCT = CAST(X.CONV_AM / NULLIF(X.PRD_AM, 0) * 100 AS DECIMAL(5,1))
        ,배부비중_PCT = CAST(X.CONV_AM * 100.0
                             / NULLIF(SUM(X.CONV_AM) OVER (), 0) AS DECIMAL(5,1))
        ,생산량비중_PCT = CAST(X.PRD_QT * 100.0
                               / NULLIF(SUM(X.PRD_QT) OVER (), 0) AS DECIMAL(5,1))
        ,배부_생산량_격차 = CAST(X.CONV_AM * 100.0 / NULLIF(SUM(X.CONV_AM) OVER (), 0)
                                - X.PRD_QT * 100.0 / NULLIF(SUM(X.PRD_QT) OVER (), 0)
                                AS DECIMAL(5,1))
        ,판정 = CASE
             WHEN X.PRD_QT = 0 AND X.CONV_AM <> 0
                  THEN N''1.★생산 없는데 가공비 배부됨''
             WHEN X.PRD_QT <> 0 AND X.CONV_AM = 0
                  THEN N''2.★생산했는데 가공비 0''
             WHEN X.CONV_AM < 0
                  THEN N''3.★가공비 음수''
             WHEN X.CONV_AM * 100.0 / NULLIF(SUM(X.CONV_AM) OVER (), 0) > @p_SKEW
                  THEN N''4.★단일 품목에 가공비 쏠림''
             WHEN X.CONV_AM / NULLIF(X.PRD_AM, 0) * 100 > 70
                  THEN N''5.가공비 비중 70% 초과 - 배부기준 타당성 확인''
             ELSE N''0.정상'' END
    FROM       X
    LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @p_CO AND I.ITEM_CD = X.ITEM_CD
    ORDER BY 판정, X.CONV_AM DESC';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4),@p_DIV NVARCHAR(4),@p_YR NVARCHAR(4),@p_CH INT,@p_SKEW DECIMAL(5,1)'
            ,@p_CO=@CO_CD,@p_DIV=@DIV_CD,@p_YR=@P_YR,@p_CH=@CHASU,@p_SKEW=@TH_SKEW;
    END TRY
    BEGIN CATCH
        SELECT N'[C] 품목별 가공비 배부' AS REPORT_NM, N'조회 실패 : ' + ERROR_MESSAGE() AS 결과;
    END CATCH
END


/*==============================================================================================
  ** 쿼리 D : 배부 대상 vs 원가 반영 대사  (CIV_DIST_ITEM ↔ CIV_PRD_TAV)
==============================================================================================*/
IF @HAS_DI = 1 AND @CHASU IS NOT NULL
BEGIN
    SET @SQL = N'
    SELECT
         N''[D] 배부 대상 vs 원가 반영'' AS REPORT_NM
        ,품번 = ISNULL(D.ITEM_CD, P.ITEM_CD)
        ,I.ITEM_NM                  AS 품명
        ,배부테이블_금액 = ISNULL(D.AM, 0)
        ,원가테이블_금액 = ISNULL(P.AM, 0)
        ,차이 = ISNULL(D.AM, 0) - ISNULL(P.AM, 0)
        ,판정 = CASE
             WHEN D.ITEM_CD IS NULL THEN N''1.★원가에만 가공비 존재 - 배부 근거 불명''
             WHEN P.ITEM_CD IS NULL THEN N''2.★배부했으나 원가에 미반영''
             WHEN ABS(ISNULL(D.AM,0) - ISNULL(P.AM,0)) < @p_TH THEN N''0.일치''
             ELSE N''3.★금액 불일치'' END
    FROM      ( SELECT X.ITEM_CD, AM = SUM(CAST(ISNULL(X.CONV_AM,0) AS DECIMAL(19,4)))
                FROM dbo.CIV_DIST_ITEM X WITH (NOLOCK)
                WHERE X.CO_CD=@p_CO AND X.P_YR=@p_YR AND X.CHASU=@p_CH
                  AND (@p_DIV IS NULL OR X.DIV_CD=@p_DIV)
                GROUP BY X.ITEM_CD ) D
    FULL JOIN ( SELECT X.ITEM_CD, AM = SUM(CAST(ISNULL(X.CONV_AM,0) AS DECIMAL(19,4)))
                FROM dbo.CIV_PRD_TAV X WITH (NOLOCK)
                WHERE X.CO_CD=@p_CO AND X.P_YR=@p_YR AND X.CHASU=@p_CH
                  AND (@p_DIV IS NULL OR X.DIV_CD=@p_DIV)
                  AND ISNULL(X.CONV_AM,0) <> 0
                GROUP BY X.ITEM_CD ) P ON P.ITEM_CD = D.ITEM_CD
    LEFT JOIN SITEM I WITH (NOLOCK) ON I.CO_CD=@p_CO AND I.ITEM_CD=ISNULL(D.ITEM_CD,P.ITEM_CD)
    WHERE  D.ITEM_CD IS NULL OR P.ITEM_CD IS NULL
       OR  ABS(ISNULL(D.AM,0) - ISNULL(P.AM,0)) >= @p_TH
    ORDER BY 판정, ABS(ISNULL(D.AM,0) - ISNULL(P.AM,0)) DESC';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4),@p_DIV NVARCHAR(4),@p_YR NVARCHAR(4),@p_CH INT,@p_TH DECIMAL(19,4)'
            ,@p_CO=@CO_CD,@p_DIV=@DIV_CD,@p_YR=@P_YR,@p_CH=@CHASU,@p_TH=@TH_AM;
    END TRY
    BEGIN CATCH
        SELECT N'[D] 배부 대상 대사' AS REPORT_NM, N'조회 실패 : ' + ERROR_MESSAGE() AS 결과;
    END CATCH
END
ELSE
    SELECT N'[D] 배부 대상 대사' AS REPORT_NM
          ,N'CIV_DIST_ITEM 없음 - 배부 상세 대사 생략 (쿼리 A 의 총액 대사로 갈음)' AS 결과;


/*==============================================================================================
  ** 쿼리 E : 검증 종합
==============================================================================================*/
SELECT
     N'[E] 가공비 배부 검증 종합'                   AS REPORT_NM
    ,@P_YR                                          AS 회계연도
    ,@CHASU                                         AS 차수
    ,@CH_ST                                         AS 차수상태
    ,CIV_OE        = CASE WHEN @HAS_OE = 1 THEN N'O' ELSE N'X' END
    ,CIV_CONVCST   = CASE WHEN @HAS_CV = 1 THEN N'O' ELSE N'X' END
    ,CIV_DIST_ITEM = CASE WHEN @HAS_DI = 1 THEN N'O' ELSE N'X' END
    ,검증1_총액일치 = CASE
         WHEN @OE_AM IS NULL OR @CV_AM IS NULL                     THEN N'확인 불가'
         WHEN ABS(@OE_AM - @CV_AM) <= @TH_AM                       THEN N'O 통과'
         ELSE N'★ 실패 (차이 ' + CAST(CAST(@OE_AM-@CV_AM AS DECIMAL(19,0)) AS NVARCHAR(30)) + N')' END
    ,검증2_원가반영 = CASE
         WHEN @CV_AM IS NULL OR @PD_AM IS NULL                     THEN N'확인 불가'
         WHEN ABS(@CV_AM - @PD_AM) <= @TH_AM                       THEN N'O 통과'
         ELSE N'★ 실패 (차이 ' + CAST(CAST(@CV_AM-@PD_AM AS DECIMAL(19,0)) AS NVARCHAR(30)) + N')' END
    ,검증3_기준일관성 = CASE
         WHEN @PREV IS NULL THEN N'전차수 없음 - 비교 불가'
         ELSE N'쿼리 B 확인' END
    ,판정 = CASE
         WHEN @CHASU IS NULL
              THEN N'9.★원가차수 없음'
         WHEN @HAS_OE = 0 AND @HAS_CV = 0
              THEN N'8.★가공비 테이블 없음 - 가공비를 배부하지 않는 사이트일 수 있다'
         WHEN @OE_AM IS NOT NULL AND @CV_AM IS NOT NULL
          AND ABS(@OE_AM - @CV_AM) > @TH_AM
              THEN N'1.★총액 불일치 - 원가 마감 금지. 배부 재실행'
         WHEN @CV_AM IS NOT NULL AND @PD_AM IS NOT NULL
          AND ABS(@CV_AM - @PD_AM) > @TH_AM
              THEN N'2.★원가 미반영 - 배부 결과가 제조원가에 실리지 않았다'
         WHEN @CH_ST <> N'마감'
              THEN N'3.미마감 차수 - 값이 불완전하다'
         ELSE N'0.정상 - 가공비 배부 검증 통과' END
;


GO


/*==============================================================================================
  [ 상시 점검 운영 ]
  ----------------------------------------------------------------------------------------------
  실행 시점 : 원가계산 SP 실행 직후, 차수 마감 직전
  실행 순서 : ① 원가계산 SP 실행 → ② 이 파일 실행 → ③ 쿼리 E 가 '0.정상' 이어야 마감
              ④ 전차수 대비 원가를 비교하기 전에 **쿼리 B 로 배부기준이 같은지 먼저 확인**

  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 가공비 테이블 실존 / 컬럼  ★ 전부 명세서 미등재
     SELECT name FROM sys.tables WHERE name IN ('CIV_OE','CIV_CONVCST','CIV_DIST_ITEM');
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('CIV_OE')      ORDER BY column_id;
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('CIV_CONVCST') ORDER BY column_id;
     --> 본 쿼리 전제 : CIV_OE.OE_AM, CIV_CONVCST.CONV_AM + METHOD_FG,
        CIV_DIST_ITEM.CONV_AM. 컬럼명이 다르면 1번 블록을 수정할 것.

  -- (2) 배부기준 코드 체계  ★ 쿼리 B 의 라벨
     SELECT METHOD_FG, COUNT(*), SUM(CONV_AM) FROM CIV_CONVCST
     WHERE CO_CD='1000' GROUP BY METHOD_FG;
     --> 코드값이 0~6 이 아니면 쿼리 B 의 CASE 를 실제 체계로 바꿀 것.

  -- (3) 차수별 배부기준 변경 이력  ★ 전차수 대비 분석의 전제
     SELECT CHASU, METHOD_FG, COUNT(*), SUM(CONV_AM) FROM CIV_CONVCST
     WHERE CO_CD='1000' AND P_YR='2026' GROUP BY CHASU, METHOD_FG ORDER BY CHASU, METHOD_FG;
     --> 차수마다 METHOD_FG 가 달라지면 C-03 의 전차수 대비 증감은 해석할 수 없다.

  -- (4) 가공비 운영 여부
     SELECT SUM(CONV_AM) FROM CIV_PRD_TAV WHERE CO_CD='1000' AND P_YR='2026';
     --> 0 이면 가공비를 배부하지 않는 사이트다 (재료비+외주비만으로 원가 산정).
        그 경우 이 파일은 사용하지 않는다.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **배부기준의 타당성 자체는 판단하지 않는다.** 수량기준이 맞는지 시간기준이 맞는지는
     회사의 원가 정책이다. 이 파일은 **선택한 기준대로 계산이 됐는지**만 검증한다.

  2) **부문별 배부(1차 배부)를 보지 않는다.** 제조부문 → 보조부문 → 품목의 다단 배부 구조를
     쓰는 사이트는 중간 단계 검증이 별도로 필요하다. 여기서는 총액 ↔ 품목만 본다.

  3) 쿼리 C 의 `배부_생산량_격차` 는 **수량기준 배부를 가정한 참고치**다. 금액·시간 기준으로
     배부하면 생산량 비중과 다른 것이 정상이므로, 이 값이 크다고 오류는 아니다.
     배부기준(쿼리 B)을 먼저 확인하고 해석할 것.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   C03_제품별_원가구성.sql    : 가공비 배부 결과가 반영된 원가 (쿼리 E 에 배부기준 표시)
   C07_원가차수_마감점검.sql  : 마감 전 선행 점검
   C02_당기재료비_분석.sql    : 재료비 쪽 분석
==============================================================================================*/
