/*==============================================================================================
  [ iCUBE ] C-04  표준원가 대비 실제원가 차이분석                                    (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 계획(표준) 대비 실제 재료비가 왜 벌어졌는지를 **수량차이 / 단가차이**로 분해한다.
         책임 부서가 갈리므로 분해하지 않으면 개선 주체가 정해지지 않는다.

             수량차이 -> 생산 책임 (과투입, LOSS, BOM 부정확)
             단가차이 -> 구매 책임 (매입단가 상승, 대체품 고가 구매)

  * `PJT_생산원가_보고서.sql` 에서 프로젝트 축을 제거한 **전사/사업장 기준** 버전.
    프로젝트별 분석이 필요하면 원본을 쓰십시오.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 산출 로직 ]
  ----------------------------------------------------------------------------------------------
     표준사용량 = SUM( 생산실적수량 x BOM 누적소요량 )
     실제사용량 = SUM( LMTL_USE.USE_QT [+ LMTL_USEWO] )
     표준단가   = SITEM.PURCH_UM (구매단가)
     실제단가   = @UM_BASE_FG :  'TAV' CIV_PUR_TAV.ISU_UM   (원가확정 출고단가)
                                 'INV' LINV_TAV.ISU_UM      (재고평가 출고단가)
                                 'PUR' 매입 가중평균
                                 'STD' SITEM.STANDARD_UM    (생산표준원가)

     표준원가     = 표준사용량 x 표준단가
     실제원가     = 실제사용량 x 실제단가
     ------------------------------------------------------------------
     수량차이금액 = (실제사용량 - 표준사용량) x 표준단가      Quantity Variance
     단가차이금액 = (실제단가   - 표준단가  ) x 실제사용량    Price Variance
     총차이금액   = 실제원가 - 표준원가  ( = 수량차이 + 단가차이 )

     (+) 불리(원가상승)  /  (-) 유리(원가절감)

  ----------------------------------------------------------------------------------------------
  [ 코드값 ]  EXPIRE_YN '1'=유효 / USE_YN '1'=사용 / BAD_YN '0'=적합 / SUB_TP '0'=주산물
              ACCT_FG 0원재료 1부재료 2제품 4반제품 5상품 / ODR_FG 0구매 1생산
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD        NVARCHAR(4)   = N'1000'
    ,@DIV_CD       NVARCHAR(4)   = NULL           -- 사업장 (NULL = 전체)
    ,@FR_DT        NVARCHAR(8)   = N'20260101'    -- 생산실적일 FROM
    ,@TO_DT        NVARCHAR(8)   = N'20261231'
    ,@ITEM_CD      NVARCHAR(30)  = NULL           -- 특정 생산품목
    ,@ITEMGRP_CD   NVARCHAR(10)  = NULL           -- 생산품목군
    ,@MTL_ITEM_CD  NVARCHAR(30)  = NULL           -- 특정 자재

    ,@BOM_BASE_DT  NVARCHAR(8)   = NULL           -- BOM 기준일 (NULL = @TO_DT)
    ,@BOM_LEVEL_FG NVARCHAR(1)   = N'S'           -- 'S'=1레벨 / 'A'=총전개(최하위)
    ,@BOM_MAX_LVL  INT           = 10

    ,@MTL_SRC_FG   NVARCHAR(3)   = N'USE'         -- 'USE'=실적별 / 'ALL'=실적별+지시별
    ,@ACCT_FG_ONLY NVARCHAR(1)   = N'Y'           -- 원가대상 계정만

    ,@UM_BASE_FG   NVARCHAR(3)   = N'TAV'         -- 'TAV'/'INV'/'PUR'/'STD'
    ,@COST_YR      NVARCHAR(4)   = NULL           -- ('TAV') NULL=LEFT(@TO_DT,4)
    ,@COST_CHASU   NUMERIC(3,0)  = NULL           -- ('TAV') NULL=최종차수
    ,@TAV_YM       NVARCHAR(6)   = NULL           -- ('INV') NULL=@TO_DT 의 월
    ,@GISU         INT           = NULL           -- ('INV') 재고평가 기수. NULL = 자동 판정
    ,@PUR_FR_DT    NVARCHAR(8)   = NULL           -- ('PUR') NULL=@FR_DT-1년

    ,@INC_BAD_YN   NVARCHAR(1)   = N'N'
    ,@INC_SUB_YN   NVARCHAR(1)   = N'N'

    ,@TH_VAR_RT    DECIMAL(9,2)  = 5.0            -- 이상 판정 : 총차이율 % 임계치
;

SET @BOM_BASE_DT = ISNULL(@BOM_BASE_DT, @TO_DT);
SET @COST_YR     = ISNULL(@COST_YR, LEFT(@TO_DT, 4));
SET @TAV_YM      = ISNULL(@TAV_YM, LEFT(@TO_DT, 6));
SET @PUR_FR_DT   = ISNULL(@PUR_FR_DT, CONVERT(NVARCHAR(8), DATEADD(YEAR,-1,CONVERT(DATE,@FR_DT)), 112));

DECLARE @SQL NVARCHAR(MAX);
-- LINV_TAV 기수 필터 조각. GISU 컬럼이 없는 사이트에서는 빈 문자열로 남는다
DECLARE @GI_FLT NVARCHAR(100) = N'';

IF OBJECT_ID('tempdb..#PRD')     IS NOT NULL DROP TABLE #PRD;
IF OBJECT_ID('tempdb..#BOM_SRC') IS NOT NULL DROP TABLE #BOM_SRC;
IF OBJECT_ID('tempdb..#BOM_EXP') IS NOT NULL DROP TABLE #BOM_EXP;
IF OBJECT_ID('tempdb..#STD')     IS NOT NULL DROP TABLE #STD;
IF OBJECT_ID('tempdb..#ACT')     IS NOT NULL DROP TABLE #ACT;
IF OBJECT_ID('tempdb..#UM')      IS NOT NULL DROP TABLE #UM;
IF OBJECT_ID('tempdb..#VAR')     IS NOT NULL DROP TABLE #VAR;


/*==============================================================================================
  1. #PRD : 생산실적 (프로젝트 축 없음)
==============================================================================================*/
SELECT
     H.CO_CD
    ,DIV_CD       = H.DIV_CD
    ,DOC_CD       = H.DOC_CD
    ,DOC_DT       = H.DOC_DT
    ,DOC_YM       = LEFT(H.DOC_DT, 6)
    ,WO_CD        = H.WO_CD
    ,PROD_ITEM_CD = ISNULL(NULLIF(H.ITEM_CD, N''), W.ITEM_CD)
    ,PRD_QT       = CAST(H.ITEM_QT AS DECIMAL(19,6))
INTO #PRD
FROM        LORCV_H H WITH (NOLOCK)
LEFT  JOIN  LWO_WF  W WITH (NOLOCK) ON W.CO_CD = H.CO_CD AND W.WO_CD = H.WO_CD
WHERE   H.CO_CD    = @CO_CD
  AND   H.DOC_DT BETWEEN @FR_DT AND @TO_DT
  AND   H.USE_YN   = N'1'
  AND   H.EXPIRE_YN= N'1'
  AND   (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
  AND   (@INC_BAD_YN = N'Y' OR ISNULL(H.BAD_YN, N'0') = N'0')
  AND   (@INC_SUB_YN = N'Y' OR ISNULL(H.SUB_TP, N'0') = N'0')
  AND   (@ITEM_CD IS NULL OR ISNULL(NULLIF(H.ITEM_CD,N''), W.ITEM_CD) = @ITEM_CD)
;
CREATE CLUSTERED INDEX IX_PRD ON #PRD (CO_CD, DOC_CD);
CREATE NONCLUSTERED INDEX IX_PRD2 ON #PRD (CO_CD, PROD_ITEM_CD);

-- 생산품목군 필터
IF @ITEMGRP_CD IS NOT NULL
    DELETE P FROM #PRD P
    LEFT JOIN SITEM I WITH (NOLOCK) ON I.CO_CD=P.CO_CD AND I.ITEM_CD=P.PROD_ITEM_CD
    WHERE ISNULL(I.ITEMGRP_CD, N'') <> @ITEMGRP_CD;

PRINT N'[1] 생산실적 : ' + CAST((SELECT COUNT(*) FROM #PRD) AS NVARCHAR(20)) + N' 건';


/*==============================================================================================
  2. #BOM_SRC / #BOM_EXP : BOM 전개 (SBOM_WF 우선, 순환참조 차단)
==============================================================================================*/
CREATE TABLE #BOM_SRC (
     CO_CD NVARCHAR(4), ITEMPARENT_CD NVARCHAR(30), ITEMCHILD_CD NVARCHAR(30)
    ,JUST_QT DECIMAL(19,6), LOSS_RT DECIMAL(19,6), REAL_QT DECIMAL(19,6)
);

DECLARE @BOM_TB SYSNAME =
        CASE WHEN OBJECT_ID(N'dbo.SBOM_WF', N'U') IS NOT NULL THEN N'SBOM_WF'
             WHEN OBJECT_ID(N'dbo.SBOM'   , N'U') IS NOT NULL THEN N'SBOM'
             ELSE NULL END;
IF @BOM_TB IS NULL BEGIN RAISERROR(N'BOM 테이블을 찾을 수 없습니다.',16,1); RETURN; END

SET @SQL = N'
    INSERT INTO #BOM_SRC (CO_CD, ITEMPARENT_CD, ITEMCHILD_CD, JUST_QT, LOSS_RT, REAL_QT)
    SELECT B.CO_CD, B.ITEMPARENT_CD, B.ITEMCHILD_CD
          ,CAST(ISNULL(B.JUST_QT,0) AS DECIMAL(19,6))
          ,CAST(ISNULL(B.LOSS_RT,0) AS DECIMAL(19,6))
          ,CAST(ISNULL(B.REAL_QT,0) AS DECIMAL(19,6))
    FROM   dbo.' + QUOTENAME(@BOM_TB) + N' B WITH (NOLOCK)
    WHERE  B.CO_CD = @p_CO AND B.USE_YN = N''1''
      AND  B.ITEMPARENT_CD <> B.ITEMCHILD_CD
      AND  @p_DT >= B.START_DT
      AND  @p_DT <= ISNULL(NULLIF(B.END_DT, N''''), N''99991231'')';
EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_DT NVARCHAR(8)', @p_CO=@CO_CD, @p_DT=@BOM_BASE_DT;
CREATE CLUSTERED INDEX IX_BOM_SRC ON #BOM_SRC (CO_CD, ITEMPARENT_CD);

;WITH ROOTS AS (SELECT DISTINCT CO_CD, PROD_ITEM_CD FROM #PRD)
,EXP AS
(
    SELECT R.CO_CD, ROOT_ITEM_CD = R.PROD_ITEM_CD, LVL = 1
          ,CHILD_CD = B.ITEMCHILD_CD, QTY_PER = B.REAL_QT
          ,JUST_QT = B.JUST_QT, LOSS_RT = B.LOSS_RT, REAL_QT = B.REAL_QT
          ,NODE_PATH = CAST(N'|'+B.ITEMPARENT_CD+N'|'+B.ITEMCHILD_CD+N'|' AS NVARCHAR(4000))
    FROM       ROOTS    R
    INNER JOIN #BOM_SRC B ON B.CO_CD = R.CO_CD AND B.ITEMPARENT_CD = R.PROD_ITEM_CD
    UNION ALL
    SELECT E.CO_CD, E.ROOT_ITEM_CD, E.LVL + 1
          ,B.ITEMCHILD_CD, E.QTY_PER * B.REAL_QT
          ,B.JUST_QT, B.LOSS_RT, B.REAL_QT
          ,CAST(E.NODE_PATH + B.ITEMCHILD_CD + N'|' AS NVARCHAR(4000))
    FROM       EXP      E
    INNER JOIN #BOM_SRC B ON B.CO_CD = E.CO_CD AND B.ITEMPARENT_CD = E.CHILD_CD
    WHERE  @BOM_LEVEL_FG = N'A'
      AND  E.LVL < @BOM_MAX_LVL
      AND  E.NODE_PATH NOT LIKE N'%|' + B.ITEMCHILD_CD + N'|%'
)
SELECT CO_CD, ROOT_ITEM_CD, LVL, CHILD_CD, QTY_PER, JUST_QT, LOSS_RT, REAL_QT
      ,LEAF_YN = CASE WHEN NOT EXISTS (SELECT 1 FROM #BOM_SRC C
                                       WHERE C.CO_CD=EXP.CO_CD AND C.ITEMPARENT_CD=EXP.CHILD_CD)
                      THEN N'Y' ELSE N'N' END
INTO #BOM_EXP
FROM EXP
OPTION (MAXRECURSION 0);
CREATE CLUSTERED INDEX IX_BOM_EXP ON #BOM_EXP (CO_CD, ROOT_ITEM_CD, CHILD_CD);


/*==============================================================================================
  3. #STD : 표준 소요량
==============================================================================================*/
SELECT
     P.CO_CD, P.DIV_CD, P.DOC_YM, P.PROD_ITEM_CD
    ,MTL_ITEM_CD = E.CHILD_CD
    ,BOM_LVL     = E.LVL
    ,BOM_QTY_PER = E.QTY_PER
    ,BOM_JUST_QT = E.JUST_QT
    ,BOM_LOSS_RT = E.LOSS_RT
    ,PRD_QT      = P.PRD_QT
    ,STD_QT      = CAST(P.PRD_QT * E.QTY_PER AS DECIMAL(19,6))
INTO #STD
FROM       #PRD     P
INNER JOIN #BOM_EXP E ON E.CO_CD = P.CO_CD AND E.ROOT_ITEM_CD = P.PROD_ITEM_CD
WHERE  ( @BOM_LEVEL_FG = N'S' AND E.LVL = 1 )
    OR ( @BOM_LEVEL_FG = N'A' AND E.LEAF_YN = N'Y' )
;
CREATE CLUSTERED INDEX IX_STD ON #STD (CO_CD, DIV_CD, PROD_ITEM_CD, MTL_ITEM_CD);


/*==============================================================================================
  4. #ACT : 실제 자재사용   [원가 SP 5-2 준용 : 모품목=자품목 제외]
==============================================================================================*/
CREATE TABLE #ACT (
     CO_CD NVARCHAR(4), DIV_CD NVARCHAR(4), DOC_YM NVARCHAR(6)
    ,PROD_ITEM_CD NVARCHAR(30), MTL_ITEM_CD NVARCHAR(30)
    ,SRC_FG NVARCHAR(10), USE_QT DECIMAL(19,6)
);

INSERT INTO #ACT
SELECT P.CO_CD, P.DIV_CD, P.DOC_YM, P.PROD_ITEM_CD, U.ITEM_CD, N'실적별'
      ,CAST(ISNULL(U.USE_QT,0) AS DECIMAL(19,6))
FROM       #PRD     P
INNER JOIN LMTL_USE U WITH (NOLOCK) ON U.CO_CD = P.CO_CD AND U.WR_CD = P.DOC_CD
WHERE  U.USE_YN = N'1' AND U.EXPIRE_YN = N'1'
  AND  U.ITEM_CD <> P.PROD_ITEM_CD;

IF @MTL_SRC_FG = N'ALL'
INSERT INTO #ACT
SELECT W.CO_CD, W.DIV_CD, LEFT(U.USE_DT,6), W.ITEM_CD, U.ITEM_CD, N'지시별'
      ,CAST(ISNULL(U.USE_QT,0) AS DECIMAL(19,6))
FROM       LMTL_USEWO U WITH (NOLOCK)
INNER JOIN LWO_WF     W WITH (NOLOCK) ON W.CO_CD = U.CO_CD AND W.WO_CD = U.WO_CD
WHERE  U.CO_CD = @CO_CD AND U.USE_YN = N'1' AND U.EXPIRE_YN = N'1'
  AND  U.USE_DT BETWEEN @FR_DT AND @TO_DT
  AND  U.ITEM_CD <> W.ITEM_CD
  AND  (@DIV_CD IS NULL OR W.DIV_CD = @DIV_CD)
  AND  NOT EXISTS (SELECT 1 FROM #ACT A
                   WHERE A.CO_CD=W.CO_CD AND A.PROD_ITEM_CD=W.ITEM_CD AND A.MTL_ITEM_CD=U.ITEM_CD);

-- 원가대상 계정 + 자재 필터
IF @ACCT_FG_ONLY = N'Y' OR @MTL_ITEM_CD IS NOT NULL
BEGIN
    DELETE A FROM #ACT A
    INNER JOIN SITEM I WITH (NOLOCK) ON I.CO_CD=A.CO_CD AND I.ITEM_CD=A.MTL_ITEM_CD
    WHERE (@ACCT_FG_ONLY = N'Y' AND I.ACCT_FG NOT IN (N'0',N'1',N'2',N'4',N'5',N'6'))
       OR (@MTL_ITEM_CD IS NOT NULL AND A.MTL_ITEM_CD <> @MTL_ITEM_CD);

    DELETE S FROM #STD S
    INNER JOIN SITEM I WITH (NOLOCK) ON I.CO_CD=S.CO_CD AND I.ITEM_CD=S.MTL_ITEM_CD
    WHERE (@ACCT_FG_ONLY = N'Y' AND I.ACCT_FG NOT IN (N'0',N'1',N'2',N'4',N'5',N'6'))
       OR (@MTL_ITEM_CD IS NOT NULL AND S.MTL_ITEM_CD <> @MTL_ITEM_CD);
END
CREATE CLUSTERED INDEX IX_ACT ON #ACT (CO_CD, DIV_CD, PROD_ITEM_CD, MTL_ITEM_CD);


/*==============================================================================================
  5. #UM : 표준단가 / 실제단가
==============================================================================================*/
CREATE TABLE #UM (
     CO_CD NVARCHAR(4), ITEM_CD NVARCHAR(30)
    ,STD_UM DECIMAL(19,6), ACT_UM DECIMAL(19,6), UM_SRC NVARCHAR(40)
);

-- 표준단가 = SITEM.PURCH_UM (전 품목 기본 적재)
INSERT INTO #UM (CO_CD, ITEM_CD, STD_UM, ACT_UM, UM_SRC)
SELECT I.CO_CD, I.ITEM_CD
      ,CAST(ISNULL(I.PURCH_UM, 0) AS DECIMAL(19,6))
      ,NULL, NULL
FROM   SITEM I WITH (NOLOCK)
WHERE  I.CO_CD = @CO_CD;
CREATE CLUSTERED INDEX IX_UM ON #UM (CO_CD, ITEM_CD);

-- 실제단가
IF @UM_BASE_FG = N'TAV' AND OBJECT_ID(N'dbo.CIV_PUR_TAV', N'U') IS NOT NULL
BEGIN
    IF @COST_CHASU IS NULL
    BEGIN
        SET @SQL = N'SELECT @o = MAX(CHASU) FROM dbo.CIV_PUR_TAV WITH (NOLOCK)
                      WHERE CO_CD=@p_CO AND P_YR=@p_YR AND (@p_DIV IS NULL OR DIV_CD=@p_DIV)';
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YR NVARCHAR(4), @o NUMERIC(3,0) OUTPUT'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_YR=@COST_YR, @o=@COST_CHASU OUTPUT;
    END
    SET @SQL = N'
        UPDATE U SET ACT_UM = X.UM, UM_SRC = N''원가확정출고단가(CIV_PUR_TAV)''
        FROM   #UM U
        INNER JOIN ( SELECT CO_CD, ITEM_CD
                           ,UM = CAST(AVG(CAST(ISNULL(ISU_UM,0) AS DECIMAL(19,6))) AS DECIMAL(19,6))
                     FROM   dbo.CIV_PUR_TAV WITH (NOLOCK)
                     WHERE  CO_CD=@p_CO AND P_YR=@p_YR AND CHASU=@p_CH
                       AND  (@p_DIV IS NULL OR DIV_CD=@p_DIV)
                     GROUP BY CO_CD, ITEM_CD ) X
               ON X.CO_CD=U.CO_CD AND X.ITEM_CD=U.ITEM_CD';
    EXEC sp_executesql @SQL
        ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YR NVARCHAR(4), @p_CH NUMERIC(3,0)'
        ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_YR=@COST_YR, @p_CH=@COST_CHASU;
    PRINT N'[5] 실제단가 = 원가확정 (P_YR=' + @COST_YR + N' CHASU='
        + ISNULL(CAST(@COST_CHASU AS NVARCHAR(10)), N'-') + N')';
END

IF @UM_BASE_FG = N'INV' AND OBJECT_ID(N'dbo.LINV_TAV', N'U') IS NOT NULL
BEGIN
    -- 기수(GISU) 확정 : 빠뜨리면 과거 기수의 평가단가까지 함께 평균된다 (CLAUDE.md 2장)
    -- GISU 컬럼이 없는 사이트에서는 필터를 붙이지 않아 종전과 동일하게 동작한다
    SET @GI_FLT = N'';
    IF COL_LENGTH(N'dbo.LINV_TAV', N'GISU') IS NOT NULL
    BEGIN
        IF @GISU IS NULL
        BEGIN
            SET @SQL = N'SELECT @o = MAX(GISU) FROM dbo.LINV_TAV WITH (NOLOCK)
                         WHERE CO_CD = @p_CO AND @p_YM BETWEEN SMM AND FMM';
            BEGIN TRY
                EXEC sp_executesql @SQL
                    ,N'@p_CO NVARCHAR(4), @p_YM NVARCHAR(6), @o INT OUTPUT'
                    ,@p_CO=@CO_CD, @p_YM=@TAV_YM, @o=@GISU OUTPUT;
            END TRY BEGIN CATCH END CATCH
        END
        SET @GI_FLT = N' AND (@p_GI IS NULL OR GISU = @p_GI)';
    END
    SET @SQL = N'
        UPDATE U SET ACT_UM = X.UM, UM_SRC = N''재고평가출고단가(LINV_TAV)''
        FROM   #UM U
        INNER JOIN ( SELECT CO_CD, ITEM_CD
                           ,UM = CAST(AVG(CAST(ISNULL(ISU_UM,0) AS DECIMAL(19,6))) AS DECIMAL(19,6))
                     FROM   dbo.LINV_TAV WITH (NOLOCK)
                     WHERE  CO_CD=@p_CO AND @p_YM BETWEEN SMM AND FMM
                       AND  (@p_DIV IS NULL OR DIV_CD=@p_DIV)' + @GI_FLT + N'
                     GROUP BY CO_CD, ITEM_CD ) X
               ON X.CO_CD=U.CO_CD AND X.ITEM_CD=U.ITEM_CD';
    EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YM NVARCHAR(6), @p_GI INT'
        ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_YM=@TAV_YM, @p_GI=@GISU;
    PRINT N'[5] 실제단가 = 재고평가 (' + @TAV_YM + N' / 기수 ' + ISNULL(CAST(@GISU AS NVARCHAR(10)), N'전체') + N')';
END

IF @UM_BASE_FG = N'PUR'
BEGIN
    UPDATE U SET ACT_UM = X.UM, UM_SRC = N'구매가중평균매입단가'
    FROM   #UM U
    INNER JOIN ( SELECT D.CO_CD, D.ITEM_CD
                       ,UM = CAST(SUM(CAST(ISNULL(D.RCVG_AM,0) AS DECIMAL(19,6)))
                                / NULLIF(SUM(CAST(ISNULL(D.RCV_QT,0) AS DECIMAL(19,6))),0) AS DECIMAL(19,6))
                 FROM   LSTOCK   S WITH (NOLOCK)
                 INNER JOIN LSTOCK_D D WITH (NOLOCK) ON D.CO_CD=S.CO_CD AND D.RCV_NB=S.RCV_NB
                 WHERE  S.CO_CD=@CO_CD AND S.RCV_DT BETWEEN @PUR_FR_DT AND @TO_DT
                   AND  D.EXPIRE_YN=N'1' AND ISNULL(D.RCV_QT,0) > 0
                   AND  (@DIV_CD IS NULL OR S.DIV_CD=@DIV_CD)
                 GROUP BY D.CO_CD, D.ITEM_CD
                 HAVING SUM(CAST(ISNULL(D.RCV_QT,0) AS DECIMAL(19,6))) > 0 ) X
           ON X.CO_CD=U.CO_CD AND X.ITEM_CD=U.ITEM_CD;
    PRINT N'[5] 실제단가 = 구매 가중평균 (' + @PUR_FR_DT + N'~' + @TO_DT + N')';
END

IF @UM_BASE_FG = N'STD'
BEGIN
    UPDATE U SET ACT_UM = CAST(ROUND(ISNULL(I.STANDARD_UM,0)
                              * ISNULL(NULLIF(I.UNITCHNG_NB,0),1), 0, 1) AS DECIMAL(19,6))
                ,UM_SRC = N'생산표준원가(SITEM.STANDARD_UM)'
    FROM   #UM U INNER JOIN SITEM I WITH (NOLOCK) ON I.CO_CD=U.CO_CD AND I.ITEM_CD=U.ITEM_CD;
END

-- 실제단가 없으면 표준단가로 보완
UPDATE #UM SET ACT_UM = STD_UM, UM_SRC = N'표준단가 대체(실제단가 없음)'
WHERE  ISNULL(ACT_UM, 0) = 0 AND ISNULL(STD_UM, 0) > 0;


/*==============================================================================================
  6. #VAR : 차이분석 (사업장 x 생산품목 x 자재)
==============================================================================================*/
;WITH S AS (
    SELECT CO_CD, DIV_CD, PROD_ITEM_CD, MTL_ITEM_CD
          ,STD_QT = SUM(STD_QT), BOM_LVL = MIN(BOM_LVL)
          ,BOM_QTY_PER = MAX(BOM_QTY_PER), BOM_JUST_QT = MAX(BOM_JUST_QT), BOM_LOSS_RT = MAX(BOM_LOSS_RT)
    FROM #STD GROUP BY CO_CD, DIV_CD, PROD_ITEM_CD, MTL_ITEM_CD
)
,A AS (
    SELECT CO_CD, DIV_CD, PROD_ITEM_CD, MTL_ITEM_CD, ACT_QT = SUM(USE_QT)
    FROM #ACT GROUP BY CO_CD, DIV_CD, PROD_ITEM_CD, MTL_ITEM_CD
)
,Q AS (
    SELECT CO_CD, DIV_CD, PROD_ITEM_CD, PRD_QT = SUM(PRD_QT), PRD_CNT = COUNT(DISTINCT DOC_CD)
    FROM #PRD GROUP BY CO_CD, DIV_CD, PROD_ITEM_CD
)
SELECT
     CO_CD        = ISNULL(S.CO_CD       , A.CO_CD)
    ,DIV_CD       = ISNULL(S.DIV_CD      , A.DIV_CD)
    ,PROD_ITEM_CD = ISNULL(S.PROD_ITEM_CD, A.PROD_ITEM_CD)
    ,MTL_ITEM_CD  = ISNULL(S.MTL_ITEM_CD , A.MTL_ITEM_CD)
    ,MATCH_FG     = CASE WHEN S.MTL_ITEM_CD IS NULL THEN N'BOM외투입'
                         WHEN A.MTL_ITEM_CD IS NULL THEN N'미투입(BOM만)'
                         ELSE N'정상' END
    ,BOM_LVL      = S.BOM_LVL
    ,BOM_QTY_PER  = S.BOM_QTY_PER
    ,BOM_JUST_QT  = S.BOM_JUST_QT
    ,BOM_LOSS_RT  = S.BOM_LOSS_RT
    ,PRD_QT       = ISNULL(Q.PRD_QT, 0)
    ,PRD_CNT      = ISNULL(Q.PRD_CNT, 0)
    ,STD_QT       = CAST(ISNULL(S.STD_QT, 0) AS DECIMAL(19,6))
    ,ACT_QT       = CAST(ISNULL(A.ACT_QT, 0) AS DECIMAL(19,6))
    ,DIFF_QT      = CAST(ISNULL(A.ACT_QT,0) - ISNULL(S.STD_QT,0) AS DECIMAL(19,6))
    ,STD_UM       = CAST(ISNULL(M.STD_UM, 0) AS DECIMAL(19,6))
    ,ACT_UM       = CAST(ISNULL(M.ACT_UM, 0) AS DECIMAL(19,6))
    ,UM_SRC       = M.UM_SRC
    -- 금액
    ,STD_AM       = CAST(ISNULL(S.STD_QT,0) * ISNULL(M.STD_UM,0) AS DECIMAL(19,4))
    ,ACT_AM       = CAST(ISNULL(A.ACT_QT,0) * ISNULL(M.ACT_UM,0) AS DECIMAL(19,4))
    -- ★ 차이 분해
    ,QTY_VAR      = CAST((ISNULL(A.ACT_QT,0) - ISNULL(S.STD_QT,0)) * ISNULL(M.STD_UM,0) AS DECIMAL(19,4))
    ,PRC_VAR      = CAST((ISNULL(M.ACT_UM,0) - ISNULL(M.STD_UM,0)) * ISNULL(A.ACT_QT,0) AS DECIMAL(19,4))
    ,TOT_VAR      = CAST(ISNULL(A.ACT_QT,0)*ISNULL(M.ACT_UM,0)
                       - ISNULL(S.STD_QT,0)*ISNULL(M.STD_UM,0) AS DECIMAL(19,4))
INTO #VAR
FROM       S
FULL OUTER JOIN A
       ON A.CO_CD=S.CO_CD AND A.DIV_CD=S.DIV_CD
      AND A.PROD_ITEM_CD=S.PROD_ITEM_CD AND A.MTL_ITEM_CD=S.MTL_ITEM_CD
LEFT  JOIN Q   ON Q.CO_CD=ISNULL(S.CO_CD,A.CO_CD) AND Q.DIV_CD=ISNULL(S.DIV_CD,A.DIV_CD)
              AND Q.PROD_ITEM_CD=ISNULL(S.PROD_ITEM_CD,A.PROD_ITEM_CD)
LEFT  JOIN #UM M ON M.CO_CD=ISNULL(S.CO_CD,A.CO_CD)
              AND M.ITEM_CD=ISNULL(S.MTL_ITEM_CD,A.MTL_ITEM_CD)
;
CREATE CLUSTERED INDEX IX_VAR ON #VAR (CO_CD, PROD_ITEM_CD, MTL_ITEM_CD);


/*==============================================================================================
  ** 쿼리 A : 전사 차이분석 요약  (경영 보고 1행)
==============================================================================================*/
SELECT
     N'[A] 표준원가 차이분석 요약'                  AS REPORT_NM
    ,@FR_DT + N' ~ ' + @TO_DT                       AS 기간
    ,MAX(V.UM_SRC)                                  AS 실제단가기준
    ,COUNT(DISTINCT V.PROD_ITEM_CD)                 AS 생산품목수
    ,COUNT(DISTINCT V.MTL_ITEM_CD)                  AS 자재품목수
    ,SUM(V.STD_AM)                                  AS 표준재료비
    ,SUM(V.ACT_AM)                                  AS 실제재료비
    ,SUM(V.TOT_VAR)                                 AS 총차이금액
    ,SUM(V.QTY_VAR)                                 AS 수량차이금액
    ,SUM(V.PRC_VAR)                                 AS 단가차이금액
    ,CAST(CASE WHEN SUM(V.STD_AM) <> 0
               THEN SUM(V.TOT_VAR)/SUM(V.STD_AM)*100 END AS DECIMAL(19,2)) AS 총차이율_PCT
    ,CAST(CASE WHEN SUM(V.TOT_VAR) <> 0
               THEN SUM(V.QTY_VAR)/SUM(V.TOT_VAR)*100 END AS DECIMAL(19,2)) AS 수량차이_기여도_PCT
    ,CAST(CASE WHEN SUM(V.TOT_VAR) <> 0
               THEN SUM(V.PRC_VAR)/SUM(V.TOT_VAR)*100 END AS DECIMAL(19,2)) AS 단가차이_기여도_PCT
    ,주책임 = CASE WHEN ABS(SUM(V.QTY_VAR)) > ABS(SUM(V.PRC_VAR)) THEN N'생산 (수량차이 우세)'
                   WHEN ABS(SUM(V.PRC_VAR)) > ABS(SUM(V.QTY_VAR)) THEN N'구매 (단가차이 우세)'
                   ELSE N'-' END
    ,SUM(CASE WHEN V.MATCH_FG = N'BOM외투입'     THEN 1 ELSE 0 END) AS BOM외투입_건수
    ,SUM(CASE WHEN V.MATCH_FG = N'미투입(BOM만)' THEN 1 ELSE 0 END) AS 미투입_건수
FROM   #VAR V
;


/*==============================================================================================
  ** 쿼리 B : 생산품목별 차이분석  (제품 단위 원가 관리)
==============================================================================================*/
SELECT
     N'[B] 생산품목별 차이분석'                     AS REPORT_NM
    ,D.DIV_NM                                       AS 사업장
    ,V.PROD_ITEM_CD                                 AS 생산품번
    ,PI.ITEM_NM                                     AS 생산품명
    ,PI.ITEM_DC                                     AS 규격
    ,PI.UNIT_DC                                     AS 단위
    ,G.ITEMGRP_NM                                   AS 품목군
    ,MAX(V.PRD_QT)                                  AS 생산수량
    ,MAX(V.PRD_CNT)                                 AS 실적건수
    ,COUNT(DISTINCT V.MTL_ITEM_CD)                  AS 투입자재종수

    ,SUM(V.STD_AM)                                  AS 표준재료비
    ,SUM(V.ACT_AM)                                  AS 실제재료비
    ,CAST(CASE WHEN MAX(V.PRD_QT) <> 0 THEN SUM(V.STD_AM)/MAX(V.PRD_QT) END AS DECIMAL(19,4)) AS 단위당표준재료비
    ,CAST(CASE WHEN MAX(V.PRD_QT) <> 0 THEN SUM(V.ACT_AM)/MAX(V.PRD_QT) END AS DECIMAL(19,4)) AS 단위당실제재료비

    ,SUM(V.QTY_VAR)                                 AS 수량차이금액
    ,SUM(V.PRC_VAR)                                 AS 단가차이금액
    ,SUM(V.TOT_VAR)                                 AS 총차이금액
    ,CAST(CASE WHEN SUM(V.STD_AM) <> 0
               THEN SUM(V.TOT_VAR)/SUM(V.STD_AM)*100 END AS DECIMAL(19,2)) AS 총차이율_PCT
    ,주책임 = CASE WHEN ABS(SUM(V.QTY_VAR)) > ABS(SUM(V.PRC_VAR)) THEN N'생산' ELSE N'구매' END
    ,판정 = CASE WHEN SUM(V.STD_AM) = 0 THEN N'-표준없음'
                 WHEN ABS(SUM(V.TOT_VAR)/NULLIF(SUM(V.STD_AM),0)*100) <= @TH_VAR_RT THEN N'0.정상'
                 WHEN SUM(V.TOT_VAR) > 0 THEN N'1.★불리(원가상승)'
                 ELSE N'2.유리(원가절감)' END
FROM       #VAR  V
LEFT  JOIN SDIV     D  WITH (NOLOCK) ON D.CO_CD  = V.CO_CD AND D.DIV_CD  = V.DIV_CD
LEFT  JOIN SITEM    PI WITH (NOLOCK) ON PI.CO_CD = V.CO_CD AND PI.ITEM_CD = V.PROD_ITEM_CD
LEFT  JOIN SITEMGRP G  WITH (NOLOCK) ON G.CO_CD  = PI.CO_CD AND G.ITEMGRP_CD = PI.ITEMGRP_CD
GROUP BY V.CO_CD, V.DIV_CD, D.DIV_NM, V.PROD_ITEM_CD, PI.ITEM_NM, PI.ITEM_DC, PI.UNIT_DC, G.ITEMGRP_NM
ORDER BY ABS(SUM(V.TOT_VAR)) DESC
;


/*==============================================================================================
  ** 쿼리 C : 자재별 차이분석  (구매 협상 / 대체품 검토용)
==============================================================================================*/
SELECT
     N'[C] 자재별 차이분석'                         AS REPORT_NM
    ,V.MTL_ITEM_CD                                  AS 자재품번
    ,MI.ITEM_NM                                     AS 자재품명
    ,MI.ITEM_DC                                     AS 규격
    ,MI.UNIT_DC                                     AS 단위
    ,MI.ACCT_FG                                     AS 계정구분
    ,MG.ITEMGRP_NM                                  AS 품목군
    ,TR.TR_NM                                       AS 주거래처
    ,COUNT(DISTINCT V.PROD_ITEM_CD)                 AS 사용제품수

    ,SUM(V.STD_QT)                                  AS 표준사용량
    ,SUM(V.ACT_QT)                                  AS 실제사용량
    ,SUM(V.DIFF_QT)                                 AS 초과사용량
    ,MAX(V.STD_UM)                                  AS 표준단가
    ,MAX(V.ACT_UM)                                  AS 실제단가
    ,MAX(V.ACT_UM) - MAX(V.STD_UM)                  AS 단가차
    ,CAST(CASE WHEN MAX(V.STD_UM) <> 0
               THEN (MAX(V.ACT_UM)-MAX(V.STD_UM))/MAX(V.STD_UM)*100 END AS DECIMAL(19,2)) AS 단가차이율_PCT

    ,SUM(V.STD_AM)                                  AS 표준재료비
    ,SUM(V.ACT_AM)                                  AS 실제재료비
    ,SUM(V.QTY_VAR)                                 AS 수량차이금액
    ,SUM(V.PRC_VAR)                                 AS 단가차이금액
    ,SUM(V.TOT_VAR)                                 AS 총차이금액
    ,구성비_PCT = CAST(SUM(V.ACT_AM) / NULLIF(SUM(SUM(V.ACT_AM)) OVER (), 0) * 100 AS DECIMAL(19,2))
    ,누적구성비_PCT = CAST(SUM(SUM(V.ACT_AM)) OVER (ORDER BY SUM(V.ACT_AM) DESC ROWS UNBOUNDED PRECEDING)
                          / NULLIF(SUM(SUM(V.ACT_AM)) OVER (), 0) * 100 AS DECIMAL(19,2))
FROM       #VAR  V
LEFT  JOIN SITEM    MI WITH (NOLOCK) ON MI.CO_CD = V.CO_CD AND MI.ITEM_CD = V.MTL_ITEM_CD
LEFT  JOIN SITEMGRP MG WITH (NOLOCK) ON MG.CO_CD = MI.CO_CD AND MG.ITEMGRP_CD = MI.ITEMGRP_CD
LEFT  JOIN STRADE   TR WITH (NOLOCK) ON TR.CO_CD = MI.CO_CD AND TR.TR_CD = MI.TRMAIN_CD
GROUP BY V.CO_CD, V.MTL_ITEM_CD, MI.ITEM_NM, MI.ITEM_DC, MI.UNIT_DC, MI.ACCT_FG, MG.ITEMGRP_NM, TR.TR_NM
ORDER BY SUM(V.ACT_AM) DESC
;


/*==============================================================================================
  ** 쿼리 D : 생산품목 x 자재 상세 (드릴다운)
==============================================================================================*/
SELECT
     N'[D] 품목x자재 상세'                          AS REPORT_NM
    ,V.PROD_ITEM_CD                                 AS 생산품번
    ,PI.ITEM_NM                                     AS 생산품명
    ,V.PRD_QT                                       AS 생산수량
    ,V.BOM_LVL                                      AS BOM레벨
    ,V.MTL_ITEM_CD                                  AS 자재품번
    ,MI.ITEM_NM                                     AS 자재품명
    ,MI.UNIT_DC                                     AS 단위
    ,V.MATCH_FG                                     AS 대사구분

    ,V.BOM_JUST_QT                                  AS BOM정미수량
    ,V.BOM_LOSS_RT                                  AS BOM로스율
    ,V.BOM_QTY_PER                                  AS BOM원단위
    ,CAST(CASE WHEN V.PRD_QT <> 0 THEN V.ACT_QT/V.PRD_QT END AS DECIMAL(19,6)) AS 실제원단위
    ,CAST(CASE WHEN ISNULL(V.BOM_QTY_PER,0) <> 0 AND V.PRD_QT <> 0
               THEN (V.ACT_QT/V.PRD_QT - V.BOM_QTY_PER)/V.BOM_QTY_PER*100
               END AS DECIMAL(19,2))                AS 원단위편차_PCT

    ,V.STD_QT                                       AS 표준사용량
    ,V.ACT_QT                                       AS 실제사용량
    ,V.DIFF_QT                                      AS 사용량차이
    ,V.STD_UM                                       AS 표준단가
    ,V.ACT_UM                                       AS 실제단가
    ,V.STD_AM                                       AS 표준재료비
    ,V.ACT_AM                                       AS 실제재료비
    ,V.QTY_VAR                                      AS 수량차이금액
    ,V.PRC_VAR                                      AS 단가차이금액
    ,V.TOT_VAR                                      AS 총차이금액
    ,V.UM_SRC                                       AS 단가기준
FROM       #VAR  V
LEFT  JOIN SITEM PI WITH (NOLOCK) ON PI.CO_CD = V.CO_CD AND PI.ITEM_CD = V.PROD_ITEM_CD
LEFT  JOIN SITEM MI WITH (NOLOCK) ON MI.CO_CD = V.CO_CD AND MI.ITEM_CD = V.MTL_ITEM_CD
ORDER BY ABS(V.TOT_VAR) DESC
;


/*==============================================================================================
  ** 쿼리 E : 월별 차이 추이
==============================================================================================*/
;WITH M AS (
    SELECT S.CO_CD, S.DOC_YM
          ,STD_AM = SUM(S.STD_QT * ISNULL(U.STD_UM,0))
    FROM   #STD S LEFT JOIN #UM U ON U.CO_CD=S.CO_CD AND U.ITEM_CD=S.MTL_ITEM_CD
    GROUP BY S.CO_CD, S.DOC_YM
)
,N AS (
    SELECT A.CO_CD, A.DOC_YM
          ,ACT_AM = SUM(A.USE_QT * ISNULL(U.ACT_UM,0))
          ,ACT_STD_AM = SUM(A.USE_QT * ISNULL(U.STD_UM,0))
    FROM   #ACT A LEFT JOIN #UM U ON U.CO_CD=A.CO_CD AND U.ITEM_CD=A.MTL_ITEM_CD
    GROUP BY A.CO_CD, A.DOC_YM
)
SELECT
     N'[E] 월별 차이 추이'                          AS REPORT_NM
    ,ISNULL(M.DOC_YM, N.DOC_YM)                     AS 실적년월
    ,ISNULL(M.STD_AM, 0)                            AS 표준재료비
    ,ISNULL(N.ACT_AM, 0)                            AS 실제재료비
    ,ISNULL(N.ACT_STD_AM,0) - ISNULL(M.STD_AM,0)    AS 수량차이금액
    ,ISNULL(N.ACT_AM,0) - ISNULL(N.ACT_STD_AM,0)    AS 단가차이금액
    ,ISNULL(N.ACT_AM,0) - ISNULL(M.STD_AM,0)        AS 총차이금액
    ,CAST(CASE WHEN ISNULL(M.STD_AM,0) <> 0
               THEN (ISNULL(N.ACT_AM,0)-ISNULL(M.STD_AM,0))/M.STD_AM*100 END AS DECIMAL(19,2)) AS 총차이율_PCT
FROM       M
FULL OUTER JOIN N ON N.CO_CD = M.CO_CD AND N.DOC_YM = M.DOC_YM
ORDER BY 실적년월
;


/*==============================================================================================
  ** 쿼리 F : 이상 항목 (조치 리스트)
==============================================================================================*/
SELECT
     N'[F] 이상 항목'                               AS REPORT_NM
    ,이상유형 = CASE
         WHEN V.MATCH_FG = N'BOM외투입'                                THEN N'1.BOM 미등록 자재 투입'
         WHEN V.MATCH_FG = N'미투입(BOM만)'                            THEN N'2.BOM 자재 미투입'
         WHEN V.STD_UM = 0                                             THEN N'3.표준단가(구매단가) 미등록'
         WHEN V.ACT_UM = 0                                             THEN N'4.실제단가 산출불가'
         WHEN V.STD_AM <> 0 AND ABS(V.TOT_VAR/V.STD_AM*100) > @TH_VAR_RT
              AND ABS(V.QTY_VAR) > ABS(V.PRC_VAR)                      THEN N'5.★수량차이 초과 (생산)'
         WHEN V.STD_AM <> 0 AND ABS(V.TOT_VAR/V.STD_AM*100) > @TH_VAR_RT
                                                                        THEN N'6.★단가차이 초과 (구매)'
         ELSE NULL END
    ,V.PROD_ITEM_CD                                 AS 생산품번
    ,PI.ITEM_NM                                     AS 생산품명
    ,V.MTL_ITEM_CD                                  AS 자재품번
    ,MI.ITEM_NM                                     AS 자재품명
    ,V.STD_QT                                       AS 표준사용량
    ,V.ACT_QT                                       AS 실제사용량
    ,V.DIFF_QT                                      AS 사용량차이
    ,V.STD_UM                                       AS 표준단가
    ,V.ACT_UM                                       AS 실제단가
    ,V.QTY_VAR                                      AS 수량차이금액
    ,V.PRC_VAR                                      AS 단가차이금액
    ,V.TOT_VAR                                      AS 총차이금액
    ,CAST(CASE WHEN V.STD_AM <> 0 THEN V.TOT_VAR/V.STD_AM*100 END AS DECIMAL(19,2)) AS 총차이율_PCT
    ,TR.TR_NM                                       AS 자재주거래처
FROM       #VAR  V
LEFT  JOIN SITEM  PI WITH (NOLOCK) ON PI.CO_CD = V.CO_CD AND PI.ITEM_CD = V.PROD_ITEM_CD
LEFT  JOIN SITEM  MI WITH (NOLOCK) ON MI.CO_CD = V.CO_CD AND MI.ITEM_CD = V.MTL_ITEM_CD
LEFT  JOIN STRADE TR WITH (NOLOCK) ON TR.CO_CD = MI.CO_CD AND TR.TR_CD = MI.TRMAIN_CD
WHERE  V.MATCH_FG <> N'정상'
    OR V.STD_UM = 0 OR V.ACT_UM = 0
    OR (V.STD_AM <> 0 AND ABS(V.TOT_VAR/V.STD_AM*100) > @TH_VAR_RT)
ORDER BY 이상유형, ABS(V.TOT_VAR) DESC
;


/*==============================================================================================
  ** 쿼리 G : ERP 원가(CIV_PRD_TAV_D) 대사   @UM_BASE_FG='TAV' 로 실행 시 일치해야 함
==============================================================================================*/
IF OBJECT_ID(N'dbo.CIV_PRD_TAV_D', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
    SELECT
         N''[G] ERP 원가 대사''                       AS REPORT_NM
        ,X.PROD_ITEM_CD                               AS 생산품번
        ,PI.ITEM_NM                                   AS 생산품명
        ,X.MTL_ITEM_CD                                AS 자재품번
        ,MI.ITEM_NM                                   AS 자재품명
        ,X.ACT_QT                                     AS 본쿼리_사용량
        ,V.USE_QT                                     AS ERP_사용량
        ,X.ACT_QT - ISNULL(V.USE_QT,0)                AS 사용량차이
        ,X.ACT_UM                                     AS 본쿼리_단가
        ,V.MTL_UM                                     AS ERP_단가
        ,X.ACT_AM                                     AS 본쿼리_재료비
        ,V.USE_AM                                     AS ERP_재료비
        ,X.ACT_AM - ISNULL(V.USE_AM,0)                AS 재료비차이
        ,V.REAL_QT                                    AS ERP_실제원단위
        ,판정 = CASE WHEN V.CITEM_CD IS NULL THEN N''ERP 미집계''
                     WHEN ABS(X.ACT_AM - ISNULL(V.USE_AM,0)) < 1 THEN N''일치''
                     ELSE N''차이발생'' END
    FROM ( SELECT CO_CD, PROD_ITEM_CD, MTL_ITEM_CD
                 ,ACT_QT = SUM(ACT_QT), ACT_AM = SUM(ACT_AM), ACT_UM = MAX(ACT_UM)
           FROM   #VAR GROUP BY CO_CD, PROD_ITEM_CD, MTL_ITEM_CD ) X
    LEFT JOIN dbo.CIV_PRD_TAV_D V WITH (NOLOCK)
           ON V.CO_CD=X.CO_CD AND V.P_YR=@p_YR AND V.CHASU=@p_CH
          AND V.PITEM_CD=X.PROD_ITEM_CD AND V.CITEM_CD=X.MTL_ITEM_CD
          AND (@p_DIV IS NULL OR V.DIV_CD=@p_DIV)
    LEFT JOIN SITEM PI WITH (NOLOCK) ON PI.CO_CD=X.CO_CD AND PI.ITEM_CD=X.PROD_ITEM_CD
    LEFT JOIN SITEM MI WITH (NOLOCK) ON MI.CO_CD=X.CO_CD AND MI.ITEM_CD=X.MTL_ITEM_CD
    ORDER BY ABS(X.ACT_AM - ISNULL(V.USE_AM,0)) DESC';
    EXEC sp_executesql @SQL
        ,N'@p_DIV NVARCHAR(4), @p_YR NVARCHAR(4), @p_CH NUMERIC(3,0)'
        ,@p_DIV=@DIV_CD, @p_YR=@COST_YR, @p_CH=@COST_CHASU;
END
ELSE
    PRINT N'[INFO] CIV_PRD_TAV_D 없음 - ERP 대사(쿼리 G) 생략';


DROP TABLE #PRD, #BOM_SRC, #BOM_EXP, #STD, #ACT, #UM, #VAR;
GO


/*==============================================================================================
  [ 해석 가이드 ]
  ----------------------------------------------------------------------------------------------
   수량차이 (+)  실제사용 > 표준사용   -> 과투입·LOSS 과다·BOM 과소등록   [생산 / 기술]
   수량차이 (-)  실제사용 < 표준사용   -> BOM 과다등록 의심 (절감이 아닐 수 있음)
   단가차이 (+)  실제단가 > 표준단가   -> 매입가 상승·고가 대체품          [구매]
   단가차이 (-)  실제단가 < 표준단가   -> 매입가 하락 또는 표준단가 미갱신

   ※ 수량차이가 (-) 인데 금액이 크면 **BOM 정합성부터 의심**하십시오. 실제 절감보다
      BOM 이 부정확한 경우가 훨씬 흔합니다. 쿼리 F 의 '미투입(BOM만)' 건수를 함께 보십시오.

  [ 선행 조건 ]
  ----------------------------------------------------------------------------------------------
   1) `SITEM.PURCH_UM`(표준단가) 등록률 — B-01 스코어카드로 확인. 70% 미만이면 의미 없음
   2) BOM 등록률 — 지시품목 중 BOM 미등록이 많으면 표준사용량이 과소 집계됨
   3) @UM_BASE_FG='TAV' 사용 시 `CIV_CHASU.CLS_YN='1'`(마감) 차수인지 확인
        SELECT P_YR, CHASU, SMM, FMM, CLS_YN FROM CIV_CHASU
        WHERE CO_CD='1000' ORDER BY P_YR DESC, CHASU DESC;

  [ 프로젝트별 분석이 필요하면 ]
  ----------------------------------------------------------------------------------------------
   `PJT_생산원가_보고서.sql` 을 사용하십시오. 본 쿼리는 프로젝트 축을 제거한 전사 버전입니다.

  [ 성능 인덱스 ]
  ----------------------------------------------------------------------------------------------
   LORCV_H  (CO_CD, DOC_DT) INCLUDE (WO_CD, ITEM_CD, ITEM_QT, BAD_YN, SUB_TP, DIV_CD)
   LMTL_USE (CO_CD, WR_CD)  INCLUDE (ITEM_CD, USE_QT)
   SBOM_WF  (CO_CD, ITEMPARENT_CD, START_DT, END_DT)
   CIV_PUR_TAV (CO_CD, DIV_CD, P_YR, CHASU, ITEM_CD)

  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------

  -- (1) ★ 실제단가 기준(@UM_BASE_FG)을 먼저 정한다. 기준이 바뀌면 단가차이가 통째로 바뀐다
     --> 'TAV' 원가확정(CIV_PUR_TAV) / 'INV' 재고평가(LINV_TAV) / 'PUR' 매입평균 / 'STD' 표준
        원가 마감이 도는 사이트는 'TAV', 아니면 'INV' 가 무난하다.

  -- (2) ★ 'INV' 를 쓸 때 기수(GISU) 확인. 기수를 섞으면 과거 단가가 평균에 끌려 들어온다
     SELECT GISU, MIN(SMM) 시작월, MAX(FMM) 종료월, COUNT(*) 건수
     FROM   LINV_TAV WHERE CO_CD='1000' GROUP BY GISU ORDER BY GISU DESC;
     --> @GISU 를 비워 두면 @TAV_YM 을 덮는 최신 기수를 자동으로 잡는다.
        기수가 여러 개 겹쳐 나오면 @GISU 를 직접 지정할 것.

  -- (3) 'TAV' 를 쓸 때는 원가 마감이 끝나 있어야 한다 (C-07 선행)
     SELECT P_YR, CHASU, CLS_YN FROM CIV_CHASU WHERE CO_CD='1000' ORDER BY P_YR DESC, CHASU DESC;

  -- (4) 표준단가(SITEM.PURCH_UM) 등록률. 미등록 품목은 차이분석에서 빠진다 (B-01 A영역)

  [ 한계 ]
  ----------------------------------------------------------------------------------------------

  1) **수량차이 / 단가차이 2요소 분해다.** 배합차이(Mix)와 수율차이(Yield)를 따로 뽑지 않는다.
     다품종 배합 공정에서는 배합 변경이 수량차이에 섞여 들어온다.

  2) **표준사용량이 BOM 누적소요량 기준**이다. BOM 이 현행화되지 않은 품목은 BOM 오류가
     그대로 수량차이로 나타나 생산 책임으로 잘못 읽힌다. M-10 BOM 정합성을 먼저 볼 것.

  3) **'INV' 기준 단가는 기수 단위 평균**이다. 기수 안의 월별 단가 변동은 보이지 않는다.
     월 단위로 봐야 하면 @TAV_YM 을 옮겨 가며 여러 번 돌려야 한다.

  4) **프로젝트 축이 없다.** 전사·사업장 기준이며, 프로젝트별로 봐야 하면
     `PJT_생산원가_보고서.sql` 을 쓴다.

==============================================================================================*/
