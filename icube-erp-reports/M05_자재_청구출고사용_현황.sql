/*==============================================================================================
  [ iCUBE ] M-05  자재 청구 / 출고 / 사용 대비 현황                                  (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 작업지시에 청구된 자재가 실제로 불출되고 투입되었는지를 단계별로 추적한다.
         **원가 마감 전 최우선 점검 항목.**

             BOM표준  →  청구  →  출고  →  사용
             SBOM_WF     LWO_REQ_WF  LSTKMOVE_D  LMTL_USE / LMTL_USEWO
             REAL_QT     REQ_QT      MOVE_QT     USE_QT

     단계별 차이의 의미
        표준 vs 청구 : BOM 오류 / 지시 확정 시 수동 조정
        청구 vs 출고 : 불출 누락, 대체품 출고, 분할 출고
        출고 vs 사용 : **현장 잔량·반납 미처리, 사용보고 누락**  ← 원가 왜곡의 주범

     ★ 핵심 산출물 = **출고미사용금액**
        원가에 반영되지 않은 잠재 재료비. 이 금액만큼 재료비가 과소 계상되거나 재공에 남는다.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 조인 체계 (검증 완료) ]
  ----------------------------------------------------------------------------------------------
     LWO_REQ_WF  F : CO_CD + DIV_CD + WO_CD + WOBOM_SQ + ITEM_CD      REQ_QT / RCV_QT / USE_QT
     LWO_WF     WF : CO_CD + DIV_CD + WO_CD
     LSTKMOVE_D  D : CO_CD + WO_CD + ITEM_CD + WOBOM_SQ (+ ITEMPARENT_CD = 지시품목)
     LSTKMOVE    H : CO_CD + MOVE_NB          생산자재출고 = IO_FG='2' AND GRP_FG='0'
     LORCV_H     R : CO_CD + DIV_CD + WO_CD
     LMTL_USE    U : CO_CD + WR_CD(=R.DOC_CD) + WOBOM_SQ
     LMTL_USEWO  U : CO_CD + DIV_CD + WO_CD + WOBOM_SQ

  ----------------------------------------------------------------------------------------------
  [ 코드값 ]  EXPIRE_YN '1'=유효 / USE_YN '1'=사용
              LSTKMOVE : IO_FG 0기초 1입고 2출고 / GRP_FG 0생산 2구매입고 3매출출고 5재고이동 6조정
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD       NVARCHAR(4)  = N'1000'
    ,@DIV_CD      NVARCHAR(4)  = N'1000'
    ,@FR_DT       NVARCHAR(8)  = N'20260101'    -- 기간 FROM
    ,@TO_DT       NVARCHAR(8)  = N'20261231'
    ,@DT_FG       NVARCHAR(1)  = N'O'           -- 'O'=지시일 / 'D'=실적일 / 'U'=사용일
    ,@WO_CD       NVARCHAR(12) = NULL           -- 특정 작업지시
    ,@PROD_ITEM   NVARCHAR(30) = NULL           -- 특정 생산품목
    ,@MTL_ITEM    NVARCHAR(30) = NULL           -- 특정 자재
    ,@PJT_CD      NVARCHAR(10) = NULL           -- 프로젝트

    ,@UM_BASE_FG  NVARCHAR(3)  = N'INV'         -- 'INV' 재고평가 / 'PUR' 매입평균 / 'TAV' 원가확정 / 'STD' 구매단가
    ,@TAV_YM      NVARCHAR(6)  = NULL           -- ('INV') NULL = @TO_DT 의 월
    ,@GISU        INT          = NULL           -- ('INV') 재고평가 기수. NULL = 자동 판정
    ,@COST_YR     NVARCHAR(4)  = NULL
    ,@COST_CHASU  NUMERIC(3,0) = NULL
    ,@PUR_FR_DT   NVARCHAR(8)  = NULL

    ,@BOM_BASE_DT NVARCHAR(8)  = NULL           -- BOM 기준일 (표준 비교용, NULL=@TO_DT)
    ,@INC_STD     NVARCHAR(1)  = N'Y'           -- BOM 표준 비교 포함 여부

    ,@TH_GAP_RT   DECIMAL(9,2) = 5.0            -- 출고-사용 괴리 임계치 %
;

SET @TAV_YM      = ISNULL(@TAV_YM, LEFT(@TO_DT, 6));
SET @COST_YR     = ISNULL(@COST_YR, LEFT(@TO_DT, 4));
SET @PUR_FR_DT   = ISNULL(@PUR_FR_DT, CONVERT(NVARCHAR(8), DATEADD(YEAR,-1,CONVERT(DATE,@FR_DT)), 112));
SET @BOM_BASE_DT = ISNULL(@BOM_BASE_DT, @TO_DT);

DECLARE @SQL NVARCHAR(MAX);
-- LINV_TAV 기수 필터 조각. GISU 컬럼이 없는 사이트에서는 빈 문자열로 남는다
DECLARE @GI_FLT NVARCHAR(100) = N'';

IF OBJECT_ID('tempdb..#WO')  IS NOT NULL DROP TABLE #WO;
IF OBJECT_ID('tempdb..#REQ') IS NOT NULL DROP TABLE #REQ;
IF OBJECT_ID('tempdb..#ISU') IS NOT NULL DROP TABLE #ISU;
IF OBJECT_ID('tempdb..#USE') IS NOT NULL DROP TABLE #USE;
IF OBJECT_ID('tempdb..#STD') IS NOT NULL DROP TABLE #STD;
IF OBJECT_ID('tempdb..#UM')  IS NOT NULL DROP TABLE #UM;
IF OBJECT_ID('tempdb..#MTL') IS NOT NULL DROP TABLE #MTL;


/*==============================================================================================
  1. #WO : 대상 작업지시 + 실적
==============================================================================================*/
SELECT
     W.CO_CD
    ,W.DIV_CD
    ,W.WO_CD
    ,W.ORD_DT
    ,W.COMP_DT
    ,PROD_ITEM = W.ITEM_CD
    ,WO_QT     = CAST(ISNULL(W.ITEM_QT,0) AS DECIMAL(19,6))
    ,W.DOC_ST
    ,W.WOC_FG
    ,PJT_CD    = W.PJT_CD
    ,PRD_QT    = CAST(ISNULL(R.PRD_QT, 0) AS DECIMAL(19,6))
    ,GOOD_QT   = CAST(ISNULL(R.GOOD_QT,0) AS DECIMAL(19,6))
    ,LAST_DOC_DT = R.LAST_DT
INTO #WO
FROM        LWO_WF W WITH (NOLOCK)
OUTER APPLY (
    SELECT PRD_QT  = SUM(H.ITEM_QT)
          ,GOOD_QT = SUM(CASE WHEN ISNULL(H.SUB_TP,N'0')=N'0' AND ISNULL(H.BAD_YN,N'0')=N'0'
                              THEN H.ITEM_QT ELSE 0 END)
          ,LAST_DT = MAX(H.DOC_DT)
    FROM   LORCV_H H WITH (NOLOCK)
    WHERE  H.CO_CD = W.CO_CD AND H.WO_CD = W.WO_CD
      AND  H.USE_YN = N'1' AND H.EXPIRE_YN = N'1'
) R
WHERE   W.CO_CD  = @CO_CD
  AND   W.USE_YN = N'1'
  AND   (   (@DT_FG = N'O' AND W.ORD_DT BETWEEN @FR_DT AND @TO_DT)
         OR (@DT_FG IN (N'D', N'U') AND ISNULL(R.LAST_DT, W.ORD_DT) BETWEEN @FR_DT AND @TO_DT) )
  AND   (@DIV_CD    IS NULL OR W.DIV_CD  = @DIV_CD)
  AND   (@WO_CD     IS NULL OR W.WO_CD   = @WO_CD)
  AND   (@PROD_ITEM IS NULL OR W.ITEM_CD = @PROD_ITEM)
  AND   (@PJT_CD    IS NULL OR W.PJT_CD  = @PJT_CD)
;
CREATE CLUSTERED INDEX IX_WO ON #WO (CO_CD, WO_CD);

PRINT N'[1] 대상 작업지시 : ' + CAST((SELECT COUNT(*) FROM #WO) AS NVARCHAR(20)) + N' 건';


/*==============================================================================================
  2. #REQ : 자재청구  (LWO_REQ_WF — 명세서 누락 테이블이므로 존재 확인)
==============================================================================================*/
CREATE TABLE #REQ (
     CO_CD NVARCHAR(4), WO_CD NVARCHAR(12), WOBOM_SQ NUMERIC(5,0), MTL_ITEM NVARCHAR(30)
    ,BASELOC_CD NVARCHAR(4), LOC_CD NVARCHAR(4), REQ_DT NVARCHAR(8)
    ,REQ_QT DECIMAL(19,6), RCV_QT DECIMAL(19,6), USE_QT DECIMAL(19,6)
);

IF OBJECT_ID(N'dbo.LWO_REQ_WF', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
        INSERT INTO #REQ (CO_CD, WO_CD, WOBOM_SQ, MTL_ITEM, BASELOC_CD, LOC_CD, REQ_DT,
                          REQ_QT, RCV_QT, USE_QT)
        SELECT  F.CO_CD, F.WO_CD, F.WOBOM_SQ, F.ITEM_CD, F.BASELOC_CD, F.LOC_CD, F.REQ_DT
               ,CAST(ISNULL(F.REQ_QT,0) AS DECIMAL(19,6))
               ,CAST(ISNULL(F.RCV_QT,0) AS DECIMAL(19,6))
               ,CAST(ISNULL(F.USE_QT,0) AS DECIMAL(19,6))
        FROM    dbo.LWO_REQ_WF F WITH (NOLOCK)
        INNER JOIN #WO W ON W.CO_CD = F.CO_CD AND W.WO_CD = F.WO_CD
        WHERE   F.ITEM_CD <> W.PROD_ITEM';
    EXEC sp_executesql @SQL;
    PRINT N'[2] 자재청구 : ' + CAST((SELECT COUNT(*) FROM #REQ) AS NVARCHAR(20)) + N' 라인';
END
ELSE
    PRINT N'[WARN] LWO_REQ_WF 없음 - 청구 단계 생략 (출고/사용만 비교)';

CREATE CLUSTERED INDEX IX_REQ ON #REQ (CO_CD, WO_CD, MTL_ITEM, WOBOM_SQ);


/*==============================================================================================
  3. #ISU : 생산자재출고  (LSTKMOVE_D + LSTKMOVE, IO_FG='2' AND GRP_FG='0')
==============================================================================================*/
CREATE TABLE #ISU (
     CO_CD NVARCHAR(4), WO_CD NVARCHAR(12), WOBOM_SQ NUMERIC(5,0), MTL_ITEM NVARCHAR(30)
    ,MOVE_NB NVARCHAR(12), MOVE_SQ NUMERIC(5,0), MOVE_DT NVARCHAR(8), LOT_NB NVARCHAR(20)
    ,ISU_QT DECIMAL(19,6)
);

IF OBJECT_ID(N'dbo.LSTKMOVE_D', N'U') IS NOT NULL AND OBJECT_ID(N'dbo.LSTKMOVE', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
        INSERT INTO #ISU (CO_CD, WO_CD, WOBOM_SQ, MTL_ITEM, MOVE_NB, MOVE_SQ, MOVE_DT, LOT_NB, ISU_QT)
        SELECT  D.CO_CD, D.WO_CD, D.WOBOM_SQ, D.ITEM_CD, D.MOVE_NB, D.MOVE_SQ, H.MOVE_DT, D.LOT_NB
               ,CAST(ISNULL(D.MOVE_QT,0) AS DECIMAL(19,6))
        FROM    dbo.LSTKMOVE_D D WITH (NOLOCK)
        INNER JOIN dbo.LSTKMOVE H WITH (NOLOCK)
               ON H.CO_CD = D.CO_CD AND H.MOVE_NB = D.MOVE_NB
        INNER JOIN #WO W ON W.CO_CD = D.CO_CD AND W.WO_CD = D.WO_CD
        WHERE   D.USE_YN = N''1'' AND D.EXPIRE_YN = N''1''
          AND   H.IO_FG = N''2'' AND H.GRP_FG = N''0''      -- 생산자재출고
          AND   D.ITEM_CD <> W.PROD_ITEM';
    EXEC sp_executesql @SQL;
    PRINT N'[3] 자재출고 : ' + CAST((SELECT COUNT(*) FROM #ISU) AS NVARCHAR(20)) + N' 라인';
END
ELSE
    PRINT N'[WARN] LSTKMOVE_D 없음 - 출고 단계 생략';

CREATE CLUSTERED INDEX IX_ISU ON #ISU (CO_CD, WO_CD, MTL_ITEM, WOBOM_SQ);


/*==============================================================================================
  4. #USE : 자재사용  (실적별 LMTL_USE + 지시별 LMTL_USEWO)
==============================================================================================*/
CREATE TABLE #USE (
     CO_CD NVARCHAR(4), WO_CD NVARCHAR(12), WOBOM_SQ NUMERIC(5,0), MTL_ITEM NVARCHAR(30)
    ,SRC_FG NVARCHAR(10), DOC_CD NVARCHAR(12), USE_DT NVARCHAR(8), LOT_NB NVARCHAR(20)
    ,USE_QT DECIMAL(19,6)
);

-- 실적별
INSERT INTO #USE
SELECT W.CO_CD, W.WO_CD, U.WOBOM_SQ, U.ITEM_CD, N'실적별', R.DOC_CD, U.USE_DT, U.LOT_NB
      ,CAST(ISNULL(U.USE_QT,0) AS DECIMAL(19,6))
FROM       #WO      W
INNER JOIN LORCV_H  R WITH (NOLOCK) ON R.CO_CD = W.CO_CD AND R.WO_CD = W.WO_CD
INNER JOIN LMTL_USE U WITH (NOLOCK) ON U.CO_CD = R.CO_CD AND U.WR_CD = R.DOC_CD
WHERE  R.USE_YN = N'1' AND R.EXPIRE_YN = N'1'
  AND  U.USE_YN = N'1' AND U.EXPIRE_YN = N'1'
  AND  U.ITEM_CD <> W.PROD_ITEM;

-- 지시별 (실적별로 안 잡힌 조합만)
INSERT INTO #USE
SELECT W.CO_CD, W.WO_CD, U.WOBOM_SQ, U.ITEM_CD, N'지시별', NULL, U.USE_DT, U.LOT_NB
      ,CAST(ISNULL(U.USE_QT,0) AS DECIMAL(19,6))
FROM       #WO        W
INNER JOIN LMTL_USEWO U WITH (NOLOCK) ON U.CO_CD = W.CO_CD AND U.WO_CD = W.WO_CD
WHERE  U.USE_YN = N'1' AND U.EXPIRE_YN = N'1'
  AND  U.ITEM_CD <> W.PROD_ITEM
  AND  NOT EXISTS (SELECT 1 FROM #USE X
                   WHERE X.CO_CD=W.CO_CD AND X.WO_CD=W.WO_CD AND X.MTL_ITEM=U.ITEM_CD);

CREATE CLUSTERED INDEX IX_USE ON #USE (CO_CD, WO_CD, MTL_ITEM, WOBOM_SQ);
PRINT N'[4] 자재사용 : ' + CAST((SELECT COUNT(*) FROM #USE) AS NVARCHAR(20)) + N' 라인';


/*==============================================================================================
  5. #STD : BOM 표준소요 (선택)
==============================================================================================*/
CREATE TABLE #STD (
     CO_CD NVARCHAR(4), WO_CD NVARCHAR(12), MTL_ITEM NVARCHAR(30)
    ,BOM_QTY_PER DECIMAL(19,6), STD_QT DECIMAL(19,6)
);

IF @INC_STD = N'Y'
BEGIN
    DECLARE @BOM_TB SYSNAME =
            CASE WHEN OBJECT_ID(N'dbo.SBOM_WF', N'U') IS NOT NULL THEN N'SBOM_WF'
                 WHEN OBJECT_ID(N'dbo.SBOM'   , N'U') IS NOT NULL THEN N'SBOM'
                 ELSE NULL END;
    IF @BOM_TB IS NOT NULL
    BEGIN
        -- 1레벨 기준 (자재사용보고와 동일 레벨)
        SET @SQL = N'
            INSERT INTO #STD (CO_CD, WO_CD, MTL_ITEM, BOM_QTY_PER, STD_QT)
            SELECT  W.CO_CD, W.WO_CD, B.ITEMCHILD_CD
                   ,CAST(ISNULL(B.REAL_QT,0) AS DECIMAL(19,6))
                   ,CAST(W.GOOD_QT * ISNULL(B.REAL_QT,0) AS DECIMAL(19,6))
            FROM    #WO W
            INNER JOIN dbo.' + QUOTENAME(@BOM_TB) + N' B WITH (NOLOCK)
                   ON B.CO_CD = W.CO_CD AND B.ITEMPARENT_CD = W.PROD_ITEM
            WHERE   B.USE_YN = N''1''
              AND   B.ITEMPARENT_CD <> B.ITEMCHILD_CD
              AND   @p_DT >= B.START_DT
              AND   @p_DT <= ISNULL(NULLIF(B.END_DT, N''''), N''99991231'')';
        EXEC sp_executesql @SQL, N'@p_DT NVARCHAR(8)', @p_DT = @BOM_BASE_DT;
    END
END
CREATE CLUSTERED INDEX IX_STD ON #STD (CO_CD, WO_CD, MTL_ITEM);


/*==============================================================================================
  6. #UM : 자재 단가
==============================================================================================*/
CREATE TABLE #UM ( CO_CD NVARCHAR(4), ITEM_CD NVARCHAR(30), MTL_UM DECIMAL(19,6), UM_SRC NVARCHAR(40) );

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
        SET @GI_FLT = N' AND (@p_GI IS NULL OR T.GISU = @p_GI)';
    END
    SET @SQL = N'
        INSERT INTO #UM SELECT T.CO_CD, T.ITEM_CD
              ,CAST(AVG(CAST(ISNULL(T.ISU_UM,0) AS DECIMAL(19,6))) AS DECIMAL(19,6))
              ,N''재고평가출고단가(LINV_TAV)''
        FROM   dbo.LINV_TAV T WITH (NOLOCK)
        WHERE  T.CO_CD=@p_CO AND @p_YM BETWEEN T.SMM AND T.FMM
          AND  (@p_DIV IS NULL OR T.DIV_CD=@p_DIV)' + @GI_FLT + N'
        GROUP BY T.CO_CD, T.ITEM_CD';
    EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YM NVARCHAR(6), @p_GI INT'
        ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_YM=@TAV_YM, @p_GI=@GISU;
END

IF @UM_BASE_FG = N'TAV' AND OBJECT_ID(N'dbo.CIV_PUR_TAV', N'U') IS NOT NULL
BEGIN
    IF @COST_CHASU IS NULL
    BEGIN
        SET @SQL = N'SELECT @o=MAX(CHASU) FROM dbo.CIV_PUR_TAV WITH (NOLOCK)
                      WHERE CO_CD=@p_CO AND P_YR=@p_YR AND (@p_DIV IS NULL OR DIV_CD=@p_DIV)';
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YR NVARCHAR(4), @o NUMERIC(3,0) OUTPUT'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_YR=@COST_YR, @o=@COST_CHASU OUTPUT;
    END
    SET @SQL = N'
        INSERT INTO #UM SELECT P.CO_CD, P.ITEM_CD
              ,CAST(AVG(CAST(ISNULL(P.ISU_UM,0) AS DECIMAL(19,6))) AS DECIMAL(19,6))
              ,N''원가확정출고단가(CIV_PUR_TAV)''
        FROM   dbo.CIV_PUR_TAV P WITH (NOLOCK)
        WHERE  P.CO_CD=@p_CO AND P.P_YR=@p_YR AND P.CHASU=@p_CH
          AND  (@p_DIV IS NULL OR P.DIV_CD=@p_DIV)
        GROUP BY P.CO_CD, P.ITEM_CD';
    EXEC sp_executesql @SQL
        ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YR NVARCHAR(4), @p_CH NUMERIC(3,0)'
        ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_YR=@COST_YR, @p_CH=@COST_CHASU;
END

IF @UM_BASE_FG = N'PUR'
INSERT INTO #UM
SELECT D.CO_CD, D.ITEM_CD
      ,CAST(SUM(CAST(ISNULL(D.RCVG_AM,0) AS DECIMAL(19,6)))
          / NULLIF(SUM(CAST(ISNULL(D.RCV_QT,0) AS DECIMAL(19,6))),0) AS DECIMAL(19,6))
      ,N'구매가중평균매입단가'
FROM       LSTOCK   S WITH (NOLOCK)
INNER JOIN LSTOCK_D D WITH (NOLOCK) ON D.CO_CD=S.CO_CD AND D.RCV_NB=S.RCV_NB
WHERE  S.CO_CD=@CO_CD AND S.RCV_DT BETWEEN @PUR_FR_DT AND @TO_DT
  AND  D.EXPIRE_YN=N'1' AND ISNULL(D.RCV_QT,0)>0
  AND  (@DIV_CD IS NULL OR S.DIV_CD=@DIV_CD)
GROUP BY D.CO_CD, D.ITEM_CD
HAVING SUM(CAST(ISNULL(D.RCV_QT,0) AS DECIMAL(19,6))) > 0;

-- 보완 : SITEM.PURCH_UM
INSERT INTO #UM
SELECT I.CO_CD, I.ITEM_CD, CAST(ISNULL(I.PURCH_UM,0) AS DECIMAL(19,6)), N'품목 구매단가(대체)'
FROM   SITEM I WITH (NOLOCK)
WHERE  I.CO_CD = @CO_CD AND ISNULL(I.PURCH_UM,0) > 0
  AND  NOT EXISTS (SELECT 1 FROM #UM U WHERE U.CO_CD=I.CO_CD AND U.ITEM_CD=I.ITEM_CD);

CREATE CLUSTERED INDEX IX_UM ON #UM (CO_CD, ITEM_CD);


/*==============================================================================================
  7. #MTL : 지시 x 자재 통합  (청구/출고/사용/표준)
==============================================================================================*/
;WITH K AS (
    SELECT CO_CD, WO_CD, MTL_ITEM FROM #REQ
    UNION SELECT CO_CD, WO_CD, MTL_ITEM FROM #ISU
    UNION SELECT CO_CD, WO_CD, MTL_ITEM FROM #USE
    UNION SELECT CO_CD, WO_CD, MTL_ITEM FROM #STD
)
SELECT
     K.CO_CD, K.WO_CD, K.MTL_ITEM
    ,W.DIV_CD, W.ORD_DT, W.COMP_DT, W.PROD_ITEM, W.WO_QT, W.GOOD_QT, W.PJT_CD, W.DOC_ST
    ,STD_QT      = CAST(ISNULL(S.STD_QT, 0) AS DECIMAL(19,6))
    ,BOM_QTY_PER = S.BOM_QTY_PER
    ,REQ_QT      = CAST(ISNULL(R.REQ_QT, 0) AS DECIMAL(19,6))
    ,REQ_DT      = R.REQ_DT
    ,BASELOC_CD  = R.BASELOC_CD
    ,LOC_CD      = R.LOC_CD
    ,ISU_QT      = CAST(ISNULL(I.ISU_QT, 0) AS DECIMAL(19,6))
    ,FIRST_ISU_DT= I.FIRST_DT
    ,LAST_ISU_DT = I.LAST_DT
    ,ISU_CNT     = ISNULL(I.CNT, 0)
    ,USE_QT      = CAST(ISNULL(U.USE_QT, 0) AS DECIMAL(19,6))
    ,LAST_USE_DT = U.LAST_DT
    ,USE_SRC     = U.SRC_FG
    ,MTL_UM      = CAST(ISNULL(M.MTL_UM, 0) AS DECIMAL(19,6))
    ,UM_SRC      = M.UM_SRC
INTO #MTL
FROM       K
INNER JOIN #WO W ON W.CO_CD = K.CO_CD AND W.WO_CD = K.WO_CD
OUTER APPLY (SELECT REQ_QT=SUM(REQ_QT), REQ_DT=MIN(REQ_DT)
                   ,BASELOC_CD=MAX(BASELOC_CD), LOC_CD=MAX(LOC_CD)
             FROM #REQ X WHERE X.CO_CD=K.CO_CD AND X.WO_CD=K.WO_CD AND X.MTL_ITEM=K.MTL_ITEM) R
OUTER APPLY (SELECT ISU_QT=SUM(ISU_QT), FIRST_DT=MIN(MOVE_DT), LAST_DT=MAX(MOVE_DT), CNT=COUNT(*)
             FROM #ISU X WHERE X.CO_CD=K.CO_CD AND X.WO_CD=K.WO_CD AND X.MTL_ITEM=K.MTL_ITEM) I
OUTER APPLY (SELECT USE_QT=SUM(USE_QT), LAST_DT=MAX(USE_DT), SRC_FG=MAX(SRC_FG)
             FROM #USE X WHERE X.CO_CD=K.CO_CD AND X.WO_CD=K.WO_CD AND X.MTL_ITEM=K.MTL_ITEM) U
OUTER APPLY (SELECT STD_QT=SUM(STD_QT), BOM_QTY_PER=MAX(BOM_QTY_PER)
             FROM #STD X WHERE X.CO_CD=K.CO_CD AND X.WO_CD=K.WO_CD AND X.MTL_ITEM=K.MTL_ITEM) S
LEFT  JOIN #UM M ON M.CO_CD = K.CO_CD AND M.ITEM_CD = K.MTL_ITEM
WHERE  (@MTL_ITEM IS NULL OR K.MTL_ITEM = @MTL_ITEM)
;
CREATE CLUSTERED INDEX IX_MTL ON #MTL (CO_CD, WO_CD, MTL_ITEM);


/*==============================================================================================
  ** 쿼리 A : 지시 x 자재 현황  (메인 / 4단계 진행추적)
==============================================================================================*/
SELECT
     N'[A] 지시별 자재 청구/출고/사용'              AS REPORT_NM
    ,D.DIV_NM                                       AS 사업장
    ,M.WO_CD                                        AS 작업지시번호
    ,M.ORD_DT                                       AS 지시일
    ,M.COMP_DT                                      AS 완료예정일
    ,CASE M.DOC_ST WHEN N'0' THEN N'계획' WHEN N'1' THEN N'확정' WHEN N'2' THEN N'마감' END AS 지시상태
    ,J.PJT_NM                                       AS 프로젝트
    ,M.PROD_ITEM                                    AS 생산품번
    ,PI.ITEM_NM                                     AS 생산품명
    ,M.WO_QT                                        AS 지시수량
    ,M.GOOD_QT                                      AS 양품수량

    ,SB.BASELOC_NM                                  AS 공정
    ,SL.LOC_NM                                      AS 작업장
    ,M.MTL_ITEM                                     AS 자재품번
    ,MI.ITEM_NM                                     AS 자재품명
    ,MI.UNIT_DC                                     AS 단위
    ,MI.ACCT_FG                                     AS 계정구분

    -- ★ 4단계 수량
    ,M.STD_QT                                       AS 표준소요량
    ,M.REQ_QT                                       AS 청구량
    ,M.ISU_QT                                       AS 출고량
    ,M.USE_QT                                       AS 사용량

    -- 단계별 차이
    ,M.REQ_QT - M.STD_QT                            AS 차이_표준대비청구
    ,M.ISU_QT - M.REQ_QT                            AS 차이_청구대비출고
    ,M.USE_QT - M.ISU_QT                            AS 차이_출고대비사용
    ,M.ISU_QT - M.USE_QT                            AS 출고미사용량

    ,진행구분 = CASE
         WHEN M.REQ_QT <> 0 AND M.ISU_QT  = 0                THEN N'1.출고대기'
         WHEN M.ISU_QT <> 0 AND M.USE_QT  = 0                THEN N'2.사용대기'
         WHEN M.REQ_QT <> 0 AND M.ISU_QT <> 0
                            AND M.REQ_QT > M.ISU_QT          THEN N'3.출고중'
         WHEN M.ISU_QT <> 0 AND M.USE_QT <> 0
                            AND M.ISU_QT > M.USE_QT          THEN N'4.사용중(잔량)'
         WHEN M.ISU_QT <> 0 AND M.ISU_QT = M.USE_QT          THEN N'5.사용완료'
         WHEN M.REQ_QT  = 0 AND M.ISU_QT <> 0                THEN N'6.청구없는출고'
         WHEN M.STD_QT <> 0 AND M.REQ_QT = 0                 THEN N'7.미청구(BOM만)'
         ELSE N'0.-' END

    ,M.REQ_DT                                       AS 청구일
    ,M.FIRST_ISU_DT                                 AS 최초출고일
    ,M.LAST_ISU_DT                                  AS 최종출고일
    ,M.ISU_CNT                                      AS 출고건수
    ,M.LAST_USE_DT                                  AS 최종사용일
    ,M.USE_SRC                                      AS 사용보고원천

    -- 금액
    ,M.MTL_UM                                       AS 자재단가
    ,M.USE_QT * M.MTL_UM                            AS 사용금액
    ,(M.ISU_QT - M.USE_QT) * M.MTL_UM               AS 출고미사용금액
    ,M.UM_SRC                                       AS 단가기준
FROM       #MTL M
LEFT  JOIN SDIV     D  WITH (NOLOCK) ON D.CO_CD  = M.CO_CD AND D.DIV_CD  = M.DIV_CD
LEFT  JOIN SPJT     J  WITH (NOLOCK) ON J.CO_CD  = M.CO_CD AND J.PJT_CD  = M.PJT_CD
LEFT  JOIN SITEM    PI WITH (NOLOCK) ON PI.CO_CD = M.CO_CD AND PI.ITEM_CD = M.PROD_ITEM
LEFT  JOIN SITEM    MI WITH (NOLOCK) ON MI.CO_CD = M.CO_CD AND MI.ITEM_CD = M.MTL_ITEM
LEFT  JOIN SBASELOC SB WITH (NOLOCK) ON SB.CO_CD = M.CO_CD AND SB.BASELOC_CD = M.BASELOC_CD
LEFT  JOIN SLOC     SL WITH (NOLOCK) ON SL.CO_CD = M.CO_CD AND SL.LOC_CD = M.LOC_CD
                                    AND SL.BASELOC_CD = SB.BASELOC_CD
ORDER BY M.WO_CD, M.MTL_ITEM
;


/*==============================================================================================
  ** 쿼리 B : 자재별 집계  ★ 출고미사용금액 큰 순 = 원가 왜곡 규모
==============================================================================================*/
SELECT
     N'[B] 자재별 집계'                             AS REPORT_NM
    ,M.MTL_ITEM                                     AS 자재품번
    ,MI.ITEM_NM                                     AS 자재품명
    ,MI.ITEM_DC                                     AS 규격
    ,MI.UNIT_DC                                     AS 단위
    ,MI.ACCT_FG                                     AS 계정구분
    ,G.ITEMGRP_NM                                   AS 품목군
    ,COUNT(DISTINCT M.WO_CD)                        AS 관련지시수
    ,COUNT(DISTINCT M.PROD_ITEM)                    AS 관련제품수

    ,SUM(M.STD_QT)                                  AS 표준소요량계
    ,SUM(M.REQ_QT)                                  AS 청구량계
    ,SUM(M.ISU_QT)                                  AS 출고량계
    ,SUM(M.USE_QT)                                  AS 사용량계
    ,SUM(M.ISU_QT - M.USE_QT)                       AS 출고미사용량

    ,CAST(CASE WHEN SUM(M.ISU_QT) <> 0
               THEN SUM(M.ISU_QT - M.USE_QT)/SUM(M.ISU_QT)*100 END AS DECIMAL(19,2)) AS 출고미사용률_PCT
    ,CAST(CASE WHEN SUM(M.STD_QT) <> 0
               THEN SUM(M.USE_QT)/SUM(M.STD_QT)*100 END AS DECIMAL(19,2))            AS 표준대비사용률_PCT

    ,MAX(M.MTL_UM)                                  AS 자재단가
    ,SUM(M.USE_QT * M.MTL_UM)                       AS 사용금액
    ,SUM((M.ISU_QT - M.USE_QT) * M.MTL_UM)          AS 출고미사용금액
    ,구성비_PCT = CAST(SUM((M.ISU_QT-M.USE_QT)*M.MTL_UM)
                      / NULLIF(SUM(SUM((M.ISU_QT-M.USE_QT)*M.MTL_UM)) OVER (),0)*100 AS DECIMAL(19,2))
    ,누적구성비_PCT = CAST(SUM(SUM((M.ISU_QT-M.USE_QT)*M.MTL_UM))
                          OVER (ORDER BY SUM((M.ISU_QT-M.USE_QT)*M.MTL_UM) DESC ROWS UNBOUNDED PRECEDING)
                          / NULLIF(SUM(SUM((M.ISU_QT-M.USE_QT)*M.MTL_UM)) OVER (),0)*100 AS DECIMAL(19,2))
FROM       #MTL     M
LEFT  JOIN SITEM    MI WITH (NOLOCK) ON MI.CO_CD = M.CO_CD AND MI.ITEM_CD = M.MTL_ITEM
LEFT  JOIN SITEMGRP G  WITH (NOLOCK) ON G.CO_CD  = MI.CO_CD AND G.ITEMGRP_CD = MI.ITEMGRP_CD
GROUP BY M.CO_CD, M.MTL_ITEM, MI.ITEM_NM, MI.ITEM_DC, MI.UNIT_DC, MI.ACCT_FG, G.ITEMGRP_NM
ORDER BY 출고미사용금액 DESC
;


/*==============================================================================================
  ** 쿼리 C : 지시별 요약  (마감 대상 판정)
==============================================================================================*/
SELECT
     N'[C] 지시별 요약'                             AS REPORT_NM
    ,M.WO_CD                                        AS 작업지시번호
    ,M.ORD_DT                                       AS 지시일
    ,M.COMP_DT                                      AS 완료예정일
    ,CASE M.DOC_ST WHEN N'0' THEN N'계획' WHEN N'1' THEN N'확정' WHEN N'2' THEN N'마감' END AS 지시상태
    ,M.PROD_ITEM                                    AS 생산품번
    ,PI.ITEM_NM                                     AS 생산품명
    ,MAX(M.WO_QT)                                   AS 지시수량
    ,MAX(M.GOOD_QT)                                 AS 양품수량
    ,COUNT(*)                                       AS 자재종수
    ,SUM(CASE WHEN M.REQ_QT > 0 AND M.ISU_QT = 0 THEN 1 ELSE 0 END) AS 출고대기종수
    ,SUM(CASE WHEN M.ISU_QT > 0 AND M.USE_QT = 0 THEN 1 ELSE 0 END) AS 사용대기종수
    ,SUM(CASE WHEN M.ISU_QT > M.USE_QT           THEN 1 ELSE 0 END) AS 잔량존재종수
    ,SUM(M.USE_QT * M.MTL_UM)                       AS 투입재료비
    ,SUM((M.ISU_QT - M.USE_QT) * M.MTL_UM)          AS 출고미사용금액
    ,CAST(CASE WHEN SUM(M.USE_QT*M.MTL_UM) <> 0
               THEN SUM((M.ISU_QT-M.USE_QT)*M.MTL_UM)/SUM(M.USE_QT*M.MTL_UM)*100
               END AS DECIMAL(19,2))                AS 미사용_투입대비_PCT
    ,마감가능여부 = CASE
         WHEN SUM(CASE WHEN M.ISU_QT > M.USE_QT THEN 1 ELSE 0 END) = 0 THEN N'0.가능'
         WHEN SUM(CASE WHEN M.ISU_QT > 0 AND M.USE_QT = 0 THEN 1 ELSE 0 END) > 0
              THEN N'1.★사용보고 누락 (마감 불가)'
         ELSE N'2.잔량 확인 필요' END
FROM       #MTL  M
LEFT  JOIN SITEM PI WITH (NOLOCK) ON PI.CO_CD = M.CO_CD AND PI.ITEM_CD = M.PROD_ITEM
GROUP BY M.CO_CD, M.WO_CD, M.ORD_DT, M.COMP_DT, M.DOC_ST, M.PROD_ITEM, PI.ITEM_NM
ORDER BY 출고미사용금액 DESC
;


/*==============================================================================================
  ** 쿼리 D : 이상징후 (조치 리스트)
==============================================================================================*/
SELECT
     N'[D] 이상징후'                                AS REPORT_NM
    ,이상유형 = CASE
         WHEN M.ISU_QT > 0 AND M.USE_QT = 0                              THEN N'1.★출고 후 사용보고 누락'
         WHEN M.REQ_QT > 0 AND M.ISU_QT = 0 AND M.GOOD_QT > 0            THEN N'2.★생산했으나 자재 미출고'
         WHEN M.REQ_QT = 0 AND M.ISU_QT > 0                              THEN N'3.청구없는 출고'
         WHEN M.STD_QT > 0 AND M.REQ_QT = 0 AND M.ISU_QT = 0             THEN N'4.BOM 자재 미청구'
         WHEN M.STD_QT = 0 AND M.USE_QT > 0                              THEN N'5.BOM 외 자재 투입'
         WHEN M.ISU_QT <> 0
              AND ABS((M.ISU_QT-M.USE_QT)/NULLIF(M.ISU_QT,0))*100 > @TH_GAP_RT
                                                                          THEN N'6.출고-사용 괴리 초과'
         WHEN M.MTL_UM = 0                                               THEN N'7.자재단가 없음'
         ELSE NULL END
    ,M.WO_CD                                        AS 작업지시번호
    ,M.ORD_DT                                       AS 지시일
    ,M.PROD_ITEM                                    AS 생산품번
    ,PI.ITEM_NM                                     AS 생산품명
    ,M.GOOD_QT                                      AS 양품수량
    ,M.MTL_ITEM                                     AS 자재품번
    ,MI.ITEM_NM                                     AS 자재품명
    ,M.STD_QT                                       AS 표준소요량
    ,M.REQ_QT                                       AS 청구량
    ,M.ISU_QT                                       AS 출고량
    ,M.USE_QT                                       AS 사용량
    ,M.ISU_QT - M.USE_QT                            AS 출고미사용량
    ,M.MTL_UM                                       AS 자재단가
    ,(M.ISU_QT - M.USE_QT) * M.MTL_UM               AS 출고미사용금액
    ,M.LAST_ISU_DT                                  AS 최종출고일
    ,경과일 = CASE WHEN M.ISU_QT > M.USE_QT AND M.LAST_ISU_DT IS NOT NULL
                   THEN DATEDIFF(DAY, CONVERT(DATE, M.LAST_ISU_DT), GETDATE()) END
FROM       #MTL  M
LEFT  JOIN SITEM PI WITH (NOLOCK) ON PI.CO_CD = M.CO_CD AND PI.ITEM_CD = M.PROD_ITEM
LEFT  JOIN SITEM MI WITH (NOLOCK) ON MI.CO_CD = M.CO_CD AND MI.ITEM_CD = M.MTL_ITEM
WHERE  (M.ISU_QT > 0 AND M.USE_QT = 0)
    OR (M.REQ_QT > 0 AND M.ISU_QT = 0 AND M.GOOD_QT > 0)
    OR (M.REQ_QT = 0 AND M.ISU_QT > 0)
    OR (M.STD_QT > 0 AND M.REQ_QT = 0 AND M.ISU_QT = 0)
    OR (M.STD_QT = 0 AND M.USE_QT > 0)
    OR (M.ISU_QT <> 0 AND ABS((M.ISU_QT-M.USE_QT)/NULLIF(M.ISU_QT,0))*100 > @TH_GAP_RT)
    OR (M.MTL_UM = 0)
ORDER BY 이상유형, ABS((M.ISU_QT - M.USE_QT) * M.MTL_UM) DESC
;


/*==============================================================================================
  ** 쿼리 E : 전체 요약  (원가 마감 판정 1행)
==============================================================================================*/
SELECT
     N'[E] 전체 요약'                               AS REPORT_NM
    ,@FR_DT + N' ~ ' + @TO_DT                       AS 기간
    ,COUNT(DISTINCT M.WO_CD)                        AS 작업지시수
    ,COUNT(DISTINCT M.MTL_ITEM)                     AS 자재종수
    ,SUM(M.REQ_QT)                                  AS 청구량계
    ,SUM(M.ISU_QT)                                  AS 출고량계
    ,SUM(M.USE_QT)                                  AS 사용량계
    ,SUM(M.USE_QT * M.MTL_UM)                       AS 투입재료비
    ,SUM((M.ISU_QT - M.USE_QT) * M.MTL_UM)          AS 출고미사용금액
    ,CAST(CASE WHEN SUM(M.USE_QT*M.MTL_UM) <> 0
               THEN SUM((M.ISU_QT-M.USE_QT)*M.MTL_UM)/SUM(M.USE_QT*M.MTL_UM)*100
               END AS DECIMAL(19,2))                AS 미사용_투입대비_PCT
    ,SUM(CASE WHEN M.ISU_QT > 0 AND M.USE_QT = 0 THEN 1 ELSE 0 END) AS 사용보고누락_라인수
    ,COUNT(DISTINCT CASE WHEN M.ISU_QT > M.USE_QT THEN M.WO_CD END) AS 잔량존재_지시수
    ,원가마감_판정 = CASE
         WHEN SUM(CASE WHEN M.ISU_QT > 0 AND M.USE_QT = 0 THEN 1 ELSE 0 END) = 0
              AND ABS(ISNULL(SUM((M.ISU_QT-M.USE_QT)*M.MTL_UM),0)) < 1 THEN N'0.마감 가능'
         WHEN SUM(CASE WHEN M.ISU_QT > 0 AND M.USE_QT = 0 THEN 1 ELSE 0 END) > 0
              THEN N'1.★사용보고 누락 존재 - 마감 전 처리 필요'
         ELSE N'2.잔량 존재 - 재공 처리 여부 확인' END
FROM   #MTL M
;


DROP TABLE #WO, #REQ, #ISU, #USE, #STD, #UM, #MTL;
GO


/*==============================================================================================
  [ 활용 ]
  ----------------------------------------------------------------------------------------------
  1) **원가 마감 전 필수 실행.** 쿼리 E 의 `원가마감_판정` 이 '1.사용보고 누락' 이면
     그 상태로 원가를 돌리면 재료비가 과소 계상된다. 쿼리 D 의 1번 유형부터 처리할 것.

  2) 쿼리 B 는 **금액 기준 파레토**다. 누적구성비 80% 까지만 처리해도 왜곡의 대부분이 해소된다.

  3) `출고미사용량` 은 두 가지로 해석된다.
     - 현장에 남아 있다  -> 재공 처리(`LWIPIO`) 또는 반납 처리가 필요
     - 이미 썼는데 보고를 안 했다 -> 사용보고 등록 필요
     쿼리 D 의 `경과일` 이 길면 후자일 가능성이 높다.

  [ 선행 조건 ]
  ----------------------------------------------------------------------------------------------
   1) `LWO_REQ_WF`(자재청구) 존재 여부 — 없으면 청구 단계가 빠지고 출고/사용만 비교된다.
        SELECT name FROM sys.tables WHERE name = 'LWO_REQ_WF';
   2) 생산자재출고 구분 확인 — 본 쿼리는 `IO_FG='2' AND GRP_FG='0'` 을 쓴다.
        SELECT H.GRP_FG, H.IO_FG, COUNT(*), SUM(D.MOVE_QT)
        FROM   LSTKMOVE H INNER JOIN LSTKMOVE_D D ON D.CO_CD=H.CO_CD AND D.MOVE_NB=H.MOVE_NB
        WHERE  H.CO_CD='1000' AND ISNULL(D.WO_CD,'') <> ''
        GROUP BY H.GRP_FG, H.IO_FG;
      -> 대체출고(`GRP_FG='6'`)로 자재를 투입하는 사이트면 조건을 확장해야 한다.
   3) 사용보고 운영 여부
        SELECT '실적별' SRC, COUNT(*) FROM LMTL_USE   WHERE CO_CD='1000'
        UNION ALL SELECT '지시별', COUNT(*) FROM LMTL_USEWO WHERE CO_CD='1000';

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   PJT_생산원가_보고서.sql  쿼리 C  : 프로젝트 축이 포함된 동일 분석
   C04_표준원가_차이분석.sql        : 표준 대비 차이를 금액으로 분해
   생산지시별_작업수율현황.sql       : 자재수율(BOM 대비) 관점

  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------

  -- (1) ★ 생산자재출고 조건이 사이트에서 맞는지 실측한다. 틀리면 출고 단계가 통째로 빈다
     SELECT IO_FG, GRP_FG, COUNT(*) FROM LSTKMOVE WHERE CO_CD='1000' GROUP BY IO_FG, GRP_FG;
     --> 표준은 IO_FG='2'(출고) AND GRP_FG='0'(생산). 다른 조합이 많으면 무슨 거래인지 확인.

  -- (2) 사용보고를 어느 테이블에 하는지 확인한다
     SELECT N'LMTL_USE' T, COUNT(*) FROM LMTL_USE   WHERE CO_CD='1000'
     UNION ALL SELECT N'LMTL_USEWO', COUNT(*) FROM LMTL_USEWO WHERE CO_CD='1000';
     --> 한쪽이 0 이면 그쪽 경로는 쓰지 않는 사이트다.

  -- (3) WOBOM_SQ 가 채워져 있는지. 비어 있으면 단계 매칭이 품목 기준으로 떨어져 정확도가 낮다
     SELECT COUNT(*) 전체, SUM(CASE WHEN ISNULL(WOBOM_SQ,0)=0 THEN 1 ELSE 0 END) 미기재
     FROM   LWO_REQ_WF WHERE CO_CD='1000';

  -- (4) 단가 기준(@UM_BASE_FG)과 기수(@GISU). 'INV' 는 C-04 의 (2) 와 같은 확인이 필요하다

  [ 한계 ]
  ----------------------------------------------------------------------------------------------

  1) **출고미사용금액은 "사용보고 누락"과 "현장 잔량"을 구분하지 못한다.** 둘 다 출고 후
     사용으로 안 잡힌 금액으로 나온다. 어느 쪽인지는 현장 확인이 필요하다.

  2) **대체품 출고는 청구-출고 차이로 보인다.** 청구한 품목과 다른 품목을 불출하면 청구
     쪽은 미출고, 출고 쪽은 청구외로 각각 잡힌다. 합계로는 맞아도 품목별로는 어긋난다.

  3) **사용보고를 운영하지 않는 사이트**에서는 사용 단계가 통째로 비어 출고=사용으로 볼
     수밖에 없다. 이 경우 이 리포트의 핵심 지표가 성립하지 않는다.

  4) **금액 환산 단가는 기수 평균 출고단가**다. 실제 투입 시점의 단가가 아니므로 금액은
     규모를 보는 용도이고, 정산 근거로 쓸 숫자는 원가모듈(C-02/C-03)에서 가져와야 한다.

==============================================================================================*/
