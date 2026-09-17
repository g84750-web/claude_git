/*==============================================================================================
  [ iCUBE ] 프로젝트별 생산 원가 보고서                                              (Rev.4)
  ----------------------------------------------------------------------------------------------
  목적 : 프로젝트 -> 작업지시 -> 생산실적 -> 자재 청구/출고/사용 흐름을 따라가며
         (1) 생산품목의 BOM 표준사용량 대비  청구 -> 출고 -> 사용  4단계 수량을 비교하고
         (2) 투입 원자재를 [실제단가] 와 [표준단가(품목별 구매단가)] 두 기준으로 금액 환산하여
         (3) 수량차이 / 단가차이 / 총원가차이(Variance) 를 산출한다.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 근거 문서 ]
  ----------------------------------------------------------------------------------------------
   (1) 아이큐브테이블명세서.xls                          - 테이블/컬럼 구조
   (2) 아이큐브_API 연동규약서_20160108_V1.00_최종.docx  - 코드값 정의
   (3) CUBE(NEW)_SYC0620_BOM정전개.ppt                   - BOM 조회테이블 / 총전개(무한루프체크)
   (4) CUBE(NEW)_SYC0640_BATCHBOM등록.ppt                - BATCH BOM = SITEM.FOQ_QT
   (5) CUBE(NEW)_SYC1110_품목단가등록.ppt                - 단가 필드 정의
   (6) USP_COT0010_CALC_COST_TAV.sql                     - iCUBE 원가계산 SP
   (7) 원가모듈_쿼리 작업관련 화면 및 테이블.pptx        - CIV_* 원가 테이블 맵
   (8) neo-x_field_layout.xls                            - NEO-X 레이아웃(명세서 누락분 보완)
   (9) **USP_SYC0630_BY_SELECT_BOM (BOM역전개.sql)**     - BOM 테이블 = SBOM_WF 확정, UFN_FLAGS
  (10) **USP_COT0020_SELECT (당기재료비분석.sql)**       - 당기재료비분석 화면 원본 쿼리
  (11) 참조_지시별_자재현황(청구,출고,사용)_쿼리        - **LWO_REQ_WF(청구) 조인 체계 확정**
                                                          **LSTKMOVE_D(생산자재출고) 조인 확정**

  ----------------------------------------------------------------------------------------------
  [ 자재 흐름 4단계 : (11) 확정 조인 체계 ]
  ----------------------------------------------------------------------------------------------
     BOM 표준          청구               출고                    사용
     SBOM_WF      ->   LWO_REQ_WF    ->   LSTKMOVE_D         ->   LMTL_USE / LMTL_USEWO
     REAL_QT           REQ_QT             MOVE_QT                 USE_QT
     (설계 소요)       (지시 확정 청구)   (창고 실제 불출)        (현장 투입 확정)

     조인 키
       LWO_REQ_WF  F : CO_CD + DIV_CD + WO_CD + WOBOM_SQ + ITEM_CD
       LWO_WF     WF : CO_CD + DIV_CD + WO_CD
       LSTKMOVE_D  D : CO_CD + WO_CD + ITEM_CD + WOBOM_SQ (+ ITEMPARENT_CD = 지시품목)
       LSTKMOVE    H : CO_CD + MOVE_NB
       LORCV_H     R : CO_CD + DIV_CD + WO_CD
       LMTL_USE    U : CO_CD + WR_CD(=R.DOC_CD) + WOBOM_SQ
       LMTL_USEWO  U : CO_CD + DIV_CD + WO_CD + WOBOM_SQ

     단계별 차이의 의미
       표준 vs 청구  : BOM 오류 / 지시 확정 시 수동 조정
       청구 vs 출고  : 불출 누락, 대체품 출고, 분할 출고
       출고 vs 사용  : 현장 잔량/반납 미처리, 사용보고 누락  <- 원가 마감 시 최우선 점검

  ----------------------------------------------------------------------------------------------
  [ 코드값 정의 : (2) 확정, (6) 실사용 코드와 일치 ]
  ----------------------------------------------------------------------------------------------
   USE_YN  1.사용 0.미사용     EXPIRE_YN 1.유효 2.만료     BAD_YN  0.적합 1.부적합
   SUB_TP  0.주산물 1.부산물   REWORK_YN 0.정상 1.재작업    UMU_FG  0.무상 1.유상
   DOC_FG  0.생산 1.외주 5.재고이동        WOC_FG 0.생산지시 2.임가공 4.외주발주 5.작업지시
   WF_FG   0.이동 1.입고       QC_FG 0.무검사 1.검사        DOC_ST 0.미처리 1.처리
   OUT_FG(BOM) 0.무상 1.유상   ODR_FG(BOM) 0.재고 1.사급
   ACCT_FG 원가대상 = ('0','1','2','4','5','6')                                  [(6) 1번 블록]
   * 코드 명칭은 사이트별 다국어 설정을 따르므로 UFN_FLAGS 사용을 권장 - [부록 4] 참조   [(9)]

  ----------------------------------------------------------------------------------------------
  [ BOM 테이블 : SBOM_WF 확정 ]
  ----------------------------------------------------------------------------------------------
   테이블명세서(1)는 `SBOM` 으로 등재되어 있으나, iCUBE 실제 SP 인
   USP_SYC0630_BY_SELECT_BOM(9) 및 API GetSBOM_WF(2), UI설계서 SYC0620(3) 이 모두
   **`SBOM_WF`** 를 사용한다. 본 쿼리는 실행 시 존재하는 테이블을 자동 감지한다.
   BATCH BOM 은 `SBOM_WF_B` + `SITEM.FOQ_QT` [부록 2].

  ----------------------------------------------------------------------------------------------
  [ 산출 로직 ]
  ----------------------------------------------------------------------------------------------
   표준사용량 STD_QT = SUM( 생산실적수량 * BOM누적소요량 )
   청구수량   REQ_QT = SUM( LWO_REQ_WF.REQ_QT )
   출고수량   ISU_QT = SUM( LSTKMOVE_D.MOVE_QT )
   실사용량   ACT_QT = SUM( LMTL_USE.USE_QT [+ LMTL_USEWO] )
   표준단가   STD_UM = SITEM.PURCH_UM
   실제단가   PUR_UM = 'TAV' CIV_PUR_TAV.ISU_UM / 'RCV' 입고가중평균 / 'CLS' 매입마감가중평균

   표준원가     = STD_QT * STD_UM
   실제원가     = ACT_QT * PUR_UM
   수량차이금액 = (ACT_QT - STD_QT) * STD_UM      -- Quantity(Usage) Variance
   단가차이금액 = (PUR_UM - STD_UM) * ACT_QT      -- Price Variance
   총차이금액   = 실제원가 - 표준원가  ( = 수량차이 + 단가차이 )
   ( 부호 : (+) 불리(원가상승) / (-) 유리(원가절감) )
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD        NVARCHAR(4)   = N'1000'        -- 회사코드
    ,@DIV_CD       NVARCHAR(4)   = NULL           -- 사업장코드 (NULL = 전체)
    ,@FR_DT        NVARCHAR(8)   = N'20260101'    -- 생산실적일 FROM
    ,@TO_DT        NVARCHAR(8)   = N'20261231'    -- 생산실적일 TO
    ,@PJT_CD       NVARCHAR(10)  = NULL           -- 프로젝트코드 (NULL = 전체)
    ,@PJTGRP_CD    NVARCHAR(10)  = NULL           -- 프로젝트분류 (NULL = 전체)

    -- 품목 필터 (당기재료비분석 화면 USP_COT0020_SELECT 대응)
    ,@ITEMGRP_CD   NVARCHAR(10)  = NULL           -- 자재 품목군
    ,@L_CD         NVARCHAR(10)  = NULL           -- 자재 대분류
    ,@M_CD         NVARCHAR(10)  = NULL           -- 자재 중분류
    ,@S_CD         NVARCHAR(10)  = NULL           -- 자재 소분류
    ,@ACCT_FG_ONLY NVARCHAR(1)   = N'Y'           -- 원가대상 계정구분만 집계

    ,@BOM_BASE_DT  NVARCHAR(8)   = NULL           -- BOM 기준일자 (NULL = @TO_DT)
    ,@BOM_LEVEL_FG NVARCHAR(1)   = N'S'           -- 'S'=1레벨 / 'A'=BOM총전개(최하위 원자재)
    ,@BOM_MAX_LVL  INT           = 10             -- 총전개 최대 레벨

    ,@MTL_SRC_FG   NVARCHAR(4)   = N'USE'         -- 실사용 원천
                                                  --   'USE'  = 실적별(LMTL_USE)만
                                                  --   'ALL'  = 실적별 + 지시별(LMTL_USEWO)
                                                  --   'MOVE' = 자재출고(LSTKMOVE_D)를 사용으로 간주
                                                  --            (사용보고 미완료 시점의 잠정 집계용)

    ,@UM_BASE_FG   NVARCHAR(3)   = N'RCV'         -- 실제단가 : 'TAV'/'RCV'/'CLS'
    ,@COST_YR      NVARCHAR(4)   = NULL           -- ('TAV') 원가 기준년도. NULL이면 LEFT(@TO_DT,4)
    ,@COST_CHASU   NUMERIC(3,0)  = NULL           -- ('TAV') 원가 차수. NULL이면 최종차수
    ,@PUR_FR_DT    NVARCHAR(8)   = NULL           -- ('RCV'/'CLS') 집계 FROM (NULL이면 @FR_DT - 1년)
    ,@PUR_TO_DT    NVARCHAR(8)   = NULL           -- ('RCV'/'CLS') 집계 TO   (NULL이면 @TO_DT)

    ,@INC_BAD_YN   NVARCHAR(1)   = N'N'           -- 부적합(BAD_YN=1) 실적 포함
    ,@INC_SUB_YN   NVARCHAR(1)   = N'N'           -- 부산물(SUB_TP=1) 실적 포함
    ,@INC_REWORK   NVARCHAR(1)   = N'Y'           -- 재작업(REWORK_YN=1) 실적 포함
;

SET @BOM_BASE_DT = ISNULL(@BOM_BASE_DT, @TO_DT);
SET @PUR_FR_DT   = ISNULL(@PUR_FR_DT, CONVERT(NVARCHAR(8), DATEADD(YEAR, -1, CONVERT(DATE, @FR_DT)), 112));
SET @PUR_TO_DT   = ISNULL(@PUR_TO_DT, @TO_DT);
SET @COST_YR     = ISNULL(@COST_YR, LEFT(@TO_DT, 4));


IF OBJECT_ID('tempdb..#BOM_SRC') IS NOT NULL DROP TABLE #BOM_SRC;
IF OBJECT_ID('tempdb..#PRD')     IS NOT NULL DROP TABLE #PRD;
IF OBJECT_ID('tempdb..#WO')      IS NOT NULL DROP TABLE #WO;
IF OBJECT_ID('tempdb..#BOM_EXP') IS NOT NULL DROP TABLE #BOM_EXP;
IF OBJECT_ID('tempdb..#MTL_STD') IS NOT NULL DROP TABLE #MTL_STD;
IF OBJECT_ID('tempdb..#MTL_REQ') IS NOT NULL DROP TABLE #MTL_REQ;
IF OBJECT_ID('tempdb..#MTL_ISU') IS NOT NULL DROP TABLE #MTL_ISU;
IF OBJECT_ID('tempdb..#MTL_ACT') IS NOT NULL DROP TABLE #MTL_ACT;
IF OBJECT_ID('tempdb..#ACT_WO')  IS NOT NULL DROP TABLE #ACT_WO;
IF OBJECT_ID('tempdb..#MTL_UM')  IS NOT NULL DROP TABLE #MTL_UM;
IF OBJECT_ID('tempdb..#TAV_UM')  IS NOT NULL DROP TABLE #TAV_UM;
IF OBJECT_ID('tempdb..#OUT_AM')  IS NOT NULL DROP TABLE #OUT_AM;
IF OBJECT_ID('tempdb..#COST')    IS NOT NULL DROP TABLE #COST;

DECLARE @SQL NVARCHAR(MAX);


/*==============================================================================================
  1. #PRD : 작업지시 + 생산실적 (프로젝트 확정)      [(6) 5-1 필터와 동일]
==============================================================================================*/
SELECT
     H.CO_CD
    ,DIV_CD        = H.DIV_CD
    ,PJT_CD        = ISNULL(NULLIF(H.PJT_CD, N''), W.PJT_CD)
    ,WO_CD         = H.WO_CD
    ,DOC_CD        = H.DOC_CD                                   -- 실적번호
    ,DOC_DT        = H.DOC_DT                                   -- 실적일
    ,DOC_YM        = LEFT(H.DOC_DT, 6)
    ,ORD_DT        = W.ORD_DT
    ,COMP_DT       = W.COMP_DT
    ,DOC_FG        = H.DOC_FG
    ,WOC_FG        = W.WOC_FG
    ,PROD_ITEM_CD  = ISNULL(NULLIF(H.ITEM_CD, N''), W.ITEM_CD)  -- 생산품목
    ,WO_QT         = CAST(W.ITEM_QT AS DECIMAL(19,6))
    ,PRD_QT        = CAST(H.ITEM_QT AS DECIMAL(19,6))
    ,BASELOC_CD    = H.BASELOC_CD
    ,LOC_CD        = H.LOC_CD
    ,DEPT_CD       = H.DEPT_CD
    ,EMP_CD        = H.EMP_CD
    ,LOT_NB        = H.LOT_NB
    ,BAD_YN        = H.BAD_YN
    ,SUB_TP        = H.SUB_TP
    ,REWORK_YN     = H.REWORK_YN
INTO #PRD
FROM        LORCV_H H WITH (NOLOCK)
LEFT  JOIN  LWO_WF  W WITH (NOLOCK)
       ON   W.CO_CD = H.CO_CD
      AND   W.WO_CD = H.WO_CD
WHERE   H.CO_CD   = @CO_CD
  AND   H.DOC_DT BETWEEN @FR_DT AND @TO_DT
  AND   H.USE_YN    = N'1'
  AND   H.EXPIRE_YN = N'1'
  AND   (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
  AND   (@INC_BAD_YN = N'Y' OR ISNULL(H.BAD_YN   , N'0') = N'0')
  AND   (@INC_SUB_YN = N'Y' OR ISNULL(H.SUB_TP   , N'0') = N'0')
  AND   (@INC_REWORK = N'Y' OR ISNULL(H.REWORK_YN, N'0') = N'0')
  AND   ISNULL(NULLIF(H.PJT_CD, N''), W.PJT_CD) IS NOT NULL
  AND   (@PJT_CD IS NULL OR ISNULL(NULLIF(H.PJT_CD, N''), W.PJT_CD) = @PJT_CD)
;
CREATE CLUSTERED INDEX IX_PRD  ON #PRD (CO_CD, DOC_CD);
CREATE NONCLUSTERED INDEX IX_PRD2 ON #PRD (CO_CD, WO_CD);
CREATE NONCLUSTERED INDEX IX_PRD3 ON #PRD (CO_CD, PROD_ITEM_CD);

-- 프로젝트분류 필터
IF @PJTGRP_CD IS NOT NULL
    DELETE P
    FROM        #PRD P
    LEFT  JOIN  SPJT J WITH (NOLOCK)
           ON   J.CO_CD  = P.CO_CD AND J.PJT_CD = P.PJT_CD
    WHERE ISNULL(J.PJTGRP_CD, N'') <> @PJTGRP_CD;


/*==============================================================================================
  1-1. #WO : 대상 작업지시 집합 (청구/출고 집계 기준)
       실적이 발생한 지시만 대상. 지시품목/프로젝트/사업장을 고정한다.
==============================================================================================*/
SELECT
     CO_CD
    ,WO_CD
    ,DIV_CD      = MIN(DIV_CD)
    ,PJT_CD      = MIN(PJT_CD)
    ,PROD_ITEM_CD= MIN(PROD_ITEM_CD)
INTO #WO
FROM   #PRD
GROUP BY CO_CD, WO_CD;
CREATE CLUSTERED INDEX IX_WO ON #WO (CO_CD, WO_CD);


/*==============================================================================================
  2. #BOM_SRC : BOM 원천 적재 (기준일자 유효분)    [SBOM_WF 확정 (9)]
==============================================================================================*/
CREATE TABLE #BOM_SRC (
     CO_CD NVARCHAR(4), ITEMPARENT_CD NVARCHAR(30), ITEMCHILD_CD NVARCHAR(30)
    ,JUST_QT DECIMAL(19,6), LOSS_RT DECIMAL(19,6), REAL_QT DECIMAL(19,6)
    ,OUT_FG NVARCHAR(1), ODR_FG NVARCHAR(1)
);

DECLARE @BOM_TB SYSNAME =
        CASE WHEN OBJECT_ID(N'dbo.SBOM_WF', N'U') IS NOT NULL THEN N'SBOM_WF'
             WHEN OBJECT_ID(N'dbo.SBOM'   , N'U') IS NOT NULL THEN N'SBOM'
             ELSE NULL END;

IF @BOM_TB IS NULL
BEGIN
    RAISERROR(N'BOM 테이블(SBOM_WF / SBOM)을 찾을 수 없습니다.', 16, 1);
    RETURN;
END

SET @SQL = N'
    INSERT INTO #BOM_SRC (CO_CD, ITEMPARENT_CD, ITEMCHILD_CD, JUST_QT, LOSS_RT, REAL_QT, OUT_FG, ODR_FG)
    SELECT  B.CO_CD, B.ITEMPARENT_CD, B.ITEMCHILD_CD
           ,CAST(ISNULL(B.JUST_QT, 0) AS DECIMAL(19,6))
           ,CAST(ISNULL(B.LOSS_RT, 0) AS DECIMAL(19,6))
           ,CAST(ISNULL(B.REAL_QT, 0) AS DECIMAL(19,6))
           ,B.OUT_FG, B.ODR_FG
    FROM    dbo.' + QUOTENAME(@BOM_TB) + N' B WITH (NOLOCK)
    WHERE   B.CO_CD    = @p_CO_CD
      AND   B.USE_YN   = N''1''
      AND   B.ITEMPARENT_CD <> B.ITEMCHILD_CD
      AND   @p_BASE_DT >= B.START_DT
      AND   @p_BASE_DT <= ISNULL(NULLIF(B.END_DT, N''''), N''99991231'')';

EXEC sp_executesql @SQL, N'@p_CO_CD NVARCHAR(4), @p_BASE_DT NVARCHAR(8)'
    ,@p_CO_CD = @CO_CD, @p_BASE_DT = @BOM_BASE_DT;

CREATE CLUSTERED INDEX IX_BOM_SRC ON #BOM_SRC (CO_CD, ITEMPARENT_CD);

PRINT N'[INFO] BOM 원천 = ' + @BOM_TB + N' / 기준일자 = ' + @BOM_BASE_DT
    + N' / 건수 = ' + CAST((SELECT COUNT(*) FROM #BOM_SRC) AS NVARCHAR(20));


/*==============================================================================================
  3. #BOM_EXP : BOM 전개 ('S'=1레벨 / 'A'=총전개 + 순환참조 차단)     [(3) 무한루프체크 요건]
==============================================================================================*/
;WITH ROOTS AS
(
    SELECT DISTINCT CO_CD, PROD_ITEM_CD FROM #PRD
)
,EXP AS
(
    SELECT
         R.CO_CD
        ,ROOT_ITEM_CD = R.PROD_ITEM_CD
        ,LVL          = 1
        ,PARENT_CD    = B.ITEMPARENT_CD
        ,CHILD_CD     = B.ITEMCHILD_CD
        ,QTY_PER      = B.REAL_QT
        ,JUST_QT      = B.JUST_QT
        ,LOSS_RT      = B.LOSS_RT
        ,REAL_QT      = B.REAL_QT
        ,NODE_PATH    = CAST(N'|' + B.ITEMPARENT_CD + N'|' + B.ITEMCHILD_CD + N'|' AS NVARCHAR(4000))
    FROM        ROOTS    R
    INNER JOIN  #BOM_SRC B
           ON   B.CO_CD = R.CO_CD AND B.ITEMPARENT_CD = R.PROD_ITEM_CD

    UNION ALL

    SELECT
         E.CO_CD
        ,E.ROOT_ITEM_CD
        ,LVL          = E.LVL + 1
        ,PARENT_CD    = B.ITEMPARENT_CD
        ,CHILD_CD     = B.ITEMCHILD_CD
        ,QTY_PER      = E.QTY_PER * B.REAL_QT
        ,JUST_QT      = B.JUST_QT
        ,LOSS_RT      = B.LOSS_RT
        ,REAL_QT      = B.REAL_QT
        ,NODE_PATH    = CAST(E.NODE_PATH + B.ITEMCHILD_CD + N'|' AS NVARCHAR(4000))
    FROM        EXP      E
    INNER JOIN  #BOM_SRC B
           ON   B.CO_CD = E.CO_CD AND B.ITEMPARENT_CD = E.CHILD_CD
    WHERE   @BOM_LEVEL_FG = N'A'
      AND   E.LVL < @BOM_MAX_LVL
      AND   E.NODE_PATH NOT LIKE N'%|' + B.ITEMCHILD_CD + N'|%'
)
SELECT
     CO_CD, ROOT_ITEM_CD, LVL, PARENT_CD, CHILD_CD, QTY_PER, JUST_QT, LOSS_RT, REAL_QT, NODE_PATH
    ,LEAF_YN = CASE WHEN NOT EXISTS (SELECT 1 FROM #BOM_SRC C
                                     WHERE C.CO_CD = EXP.CO_CD AND C.ITEMPARENT_CD = EXP.CHILD_CD)
                    THEN N'Y' ELSE N'N' END
INTO #BOM_EXP
FROM EXP
OPTION (MAXRECURSION 0)
;
CREATE CLUSTERED INDEX IX_BOM_EXP ON #BOM_EXP (CO_CD, ROOT_ITEM_CD, CHILD_CD);


/*==============================================================================================
  4. #MTL_STD : 표준 소요량 = 실적수량 x 누적소요량(QTY_PER)
==============================================================================================*/
SELECT
     P.CO_CD, P.DIV_CD, P.PJT_CD, P.PROD_ITEM_CD
    ,MTL_ITEM_CD = E.CHILD_CD
    ,WO_CD  = P.WO_CD
    ,DOC_CD = P.DOC_CD
    ,DOC_DT = P.DOC_DT
    ,PRD_QT = P.PRD_QT
    ,BOM_LVL= E.LVL
    ,JUST_QT= E.JUST_QT
    ,LOSS_RT= E.LOSS_RT
    ,REAL_QT= E.REAL_QT
    ,QTY_PER= E.QTY_PER
    ,STD_QT = CAST(P.PRD_QT * E.QTY_PER AS DECIMAL(19,6))
INTO #MTL_STD
FROM        #PRD     P
INNER JOIN  #BOM_EXP E
       ON   E.CO_CD = P.CO_CD AND E.ROOT_ITEM_CD = P.PROD_ITEM_CD
WHERE   ( @BOM_LEVEL_FG = N'S' AND E.LVL = 1 )
     OR ( @BOM_LEVEL_FG = N'A' AND E.LEAF_YN = N'Y' )
;
CREATE CLUSTERED INDEX IX_MTL_STD ON #MTL_STD (CO_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD);


/*==============================================================================================
  5. #MTL_REQ : 작업지시 소요자재(청구)  -  LWO_REQ_WF          [(11) 확정]
==============================================================================================*/
CREATE TABLE #MTL_REQ (
     CO_CD NVARCHAR(4), DIV_CD NVARCHAR(4), PJT_CD NVARCHAR(10)
    ,PROD_ITEM_CD NVARCHAR(30), MTL_ITEM_CD NVARCHAR(30)
    ,WO_CD NVARCHAR(12), WOBOM_SQ NUMERIC(5,0)
    ,BASELOC_CD NVARCHAR(4), LOC_CD NVARCHAR(4)
    ,REQ_QT DECIMAL(19,6)
);

IF OBJECT_ID(N'dbo.LWO_REQ_WF', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
        INSERT INTO #MTL_REQ (CO_CD, DIV_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD,
                              WO_CD, WOBOM_SQ, BASELOC_CD, LOC_CD, REQ_QT)
        SELECT  W.CO_CD, W.DIV_CD, W.PJT_CD, W.PROD_ITEM_CD, F.ITEM_CD
               ,F.WO_CD, F.WOBOM_SQ, F.BASELOC_CD, F.LOC_CD
               ,CAST(ISNULL(F.REQ_QT, 0) AS DECIMAL(19,6))
        FROM        dbo.LWO_REQ_WF F WITH (NOLOCK)
        INNER JOIN  #WO W ON W.CO_CD = F.CO_CD AND W.WO_CD = F.WO_CD
        WHERE   F.ITEM_CD <> W.PROD_ITEM_CD';

    EXEC sp_executesql @SQL;
    PRINT N'[INFO] 청구(LWO_REQ_WF) 건수 = ' + CAST((SELECT COUNT(*) FROM #MTL_REQ) AS NVARCHAR(20));
END
ELSE
    PRINT N'[WARN] LWO_REQ_WF(작업지시 소요자재) 테이블 없음 - 청구수량 비교는 생략됩니다.';

CREATE CLUSTERED INDEX IX_MTL_REQ ON #MTL_REQ (CO_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD);


/*==============================================================================================
  6. #MTL_ISU : 생산자재출고  -  LSTKMOVE_D + LSTKMOVE          [(11) 확정]
     LSTKMOVE_D 는 WO_CD / WOBOM_SQ / ITEMPARENT_CD(지시품목) 를 보유한다.
==============================================================================================*/
CREATE TABLE #MTL_ISU (
     CO_CD NVARCHAR(4), DIV_CD NVARCHAR(4), PJT_CD NVARCHAR(10)
    ,PROD_ITEM_CD NVARCHAR(30), MTL_ITEM_CD NVARCHAR(30)
    ,WO_CD NVARCHAR(12), WOBOM_SQ NUMERIC(5,0)
    ,MOVE_NB NVARCHAR(12), MOVE_SQ NUMERIC(5,0), MOVE_DT NVARCHAR(8)
    ,LOT_NB NVARCHAR(20)
    ,ISU_QT DECIMAL(19,6)
);

IF OBJECT_ID(N'dbo.LSTKMOVE_D', N'U') IS NOT NULL AND OBJECT_ID(N'dbo.LSTKMOVE', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
        INSERT INTO #MTL_ISU (CO_CD, DIV_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD,
                              WO_CD, WOBOM_SQ, MOVE_NB, MOVE_SQ, MOVE_DT, LOT_NB, ISU_QT)
        SELECT  W.CO_CD, W.DIV_CD
               ,ISNULL(NULLIF(H.PJT_CD, N''''), W.PJT_CD)
               ,W.PROD_ITEM_CD, D.ITEM_CD
               ,D.WO_CD, D.WOBOM_SQ, D.MOVE_NB, D.MOVE_SQ, H.MOVE_DT, D.LOT_NB
               ,CAST(ISNULL(D.MOVE_QT, 0) AS DECIMAL(19,6))
        FROM        dbo.LSTKMOVE_D D WITH (NOLOCK)
        INNER JOIN  dbo.LSTKMOVE   H WITH (NOLOCK)
               ON   H.CO_CD = D.CO_CD AND H.MOVE_NB = D.MOVE_NB
        INNER JOIN  #WO W ON W.CO_CD = D.CO_CD AND W.WO_CD = D.WO_CD
        WHERE   D.USE_YN    = N''1''
          AND   D.EXPIRE_YN = N''1''
          AND   D.ITEM_CD  <> W.PROD_ITEM_CD';

    EXEC sp_executesql @SQL;
    PRINT N'[INFO] 출고(LSTKMOVE_D) 건수 = ' + CAST((SELECT COUNT(*) FROM #MTL_ISU) AS NVARCHAR(20));
END
ELSE
    PRINT N'[WARN] LSTKMOVE_D(생산자재출고) 테이블 없음 - 출고수량 비교는 생략됩니다.';

CREATE CLUSTERED INDEX IX_MTL_ISU ON #MTL_ISU (CO_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD);


/*==============================================================================================
  7. #MTL_ACT : 실제 자재사용
     [(6) 5-2 준용] 모품목=자품목 제외
       'USE'  : LMTL_USE (실적별)
       'ALL'  : + LMTL_USEWO (지시별)
       'MOVE' : LSTKMOVE_D 출고분을 사용으로 간주
                (사용자재보고 미완료 시점의 잠정 원가를 출고 기준으로 보고 싶을 때)
==============================================================================================*/
CREATE TABLE #MTL_ACT (
     CO_CD NVARCHAR(4), DIV_CD NVARCHAR(4), PJT_CD NVARCHAR(10)
    ,PROD_ITEM_CD NVARCHAR(30), MTL_ITEM_CD NVARCHAR(30)
    ,SRC_FG NVARCHAR(10)
    ,WO_CD NVARCHAR(12), DOC_CD NVARCHAR(12), DOC_DT NVARCHAR(8)
    ,USE_DT NVARCHAR(8), USE_SQ NUMERIC(5,0), USE_QT DECIMAL(19,6)
    ,UMU_FG NVARCHAR(1), WOOP_SQ NUMERIC(5,0), WOBOM_SQ NUMERIC(5,0)
    ,BASELOC_CD NVARCHAR(4), LOC_CD NVARCHAR(4), LOT_NB NVARCHAR(20)
);

-- (a) 실적별사용자재보고
IF @MTL_SRC_FG IN (N'USE', N'ALL')
INSERT INTO #MTL_ACT
SELECT
     P.CO_CD, P.DIV_CD, P.PJT_CD, P.PROD_ITEM_CD
    ,U.ITEM_CD, N'실적별'
    ,P.WO_CD, P.DOC_CD, P.DOC_DT
    ,U.USE_DT, U.USE_SQ
    ,CAST(ISNULL(U.USE_QT, 0) AS DECIMAL(19,6))
    ,U.UMU_FG, U.WOOP_SQ, U.WOBOM_SQ, U.BASELOC_CD, U.LOC_CD, U.LOT_NB
FROM        #PRD     P
INNER JOIN  LMTL_USE U WITH (NOLOCK)
       ON   U.CO_CD = P.CO_CD AND U.WR_CD = P.DOC_CD
WHERE   U.USE_YN    = N'1'
  AND   U.EXPIRE_YN = N'1'
  AND   U.ITEM_CD  <> P.PROD_ITEM_CD
;

-- 자기참조 방지용 스냅샷
SELECT DISTINCT CO_CD, WO_CD, MTL_ITEM_CD INTO #ACT_WO FROM #MTL_ACT;
CREATE CLUSTERED INDEX IX_ACT_WO ON #ACT_WO (CO_CD, WO_CD, MTL_ITEM_CD);

-- (b) 지시별사용자재보고
IF @MTL_SRC_FG = N'ALL'
INSERT INTO #MTL_ACT
SELECT
     W.CO_CD, W.DIV_CD
    ,PJT_CD = ISNULL(NULLIF(U.PJT_CD, N''), W.PJT_CD)
    ,W.ITEM_CD
    ,U.ITEM_CD, N'지시별'
    ,W.WO_CD, NULL, W.ORD_DT
    ,U.USE_DT, U.USE_SQ
    ,CAST(ISNULL(U.USE_QT, 0) AS DECIMAL(19,6))
    ,NULL, U.WOOP_SQ, U.WOBOM_SQ, U.BASELOC_CD, U.LOC_CD, U.LOT_NB
FROM        LMTL_USEWO U WITH (NOLOCK)
INNER JOIN  LWO_WF     W WITH (NOLOCK)
       ON   W.CO_CD = U.CO_CD AND W.WO_CD = U.WO_CD
WHERE   U.CO_CD     = @CO_CD
  AND   U.USE_YN    = N'1'
  AND   U.EXPIRE_YN = N'1'
  AND   U.USE_DT BETWEEN @FR_DT AND @TO_DT
  AND   U.ITEM_CD  <> W.ITEM_CD
  AND   (@DIV_CD IS NULL OR W.DIV_CD = @DIV_CD)
  AND   ISNULL(NULLIF(U.PJT_CD, N''), W.PJT_CD) IS NOT NULL
  AND   (@PJT_CD IS NULL OR ISNULL(NULLIF(U.PJT_CD, N''), W.PJT_CD) = @PJT_CD)
  AND   NOT EXISTS (SELECT 1 FROM #ACT_WO A
                    WHERE A.CO_CD = U.CO_CD AND A.WO_CD = U.WO_CD AND A.MTL_ITEM_CD = U.ITEM_CD)
;

-- (c) 출고를 사용으로 간주 (사용자재보고 미운영)
IF @MTL_SRC_FG = N'MOVE'
INSERT INTO #MTL_ACT
SELECT
     I.CO_CD, I.DIV_CD, I.PJT_CD, I.PROD_ITEM_CD, I.MTL_ITEM_CD, N'출고대체'
    ,I.WO_CD, NULL, I.MOVE_DT
    ,I.MOVE_DT, I.MOVE_SQ, I.ISU_QT
    ,NULL, NULL, I.WOBOM_SQ, NULL, NULL, I.LOT_NB
FROM   #MTL_ISU I
;

-- 품목 필터
IF @ACCT_FG_ONLY = N'Y' OR @ITEMGRP_CD IS NOT NULL
   OR @L_CD IS NOT NULL OR @M_CD IS NOT NULL OR @S_CD IS NOT NULL
BEGIN
    DELETE A FROM #MTL_ACT A INNER JOIN SITEM I WITH (NOLOCK)
           ON I.CO_CD = A.CO_CD AND I.ITEM_CD = A.MTL_ITEM_CD
    WHERE  (@ACCT_FG_ONLY = N'Y' AND I.ACCT_FG NOT IN (N'0',N'1',N'2',N'4',N'5',N'6'))
        OR (@ITEMGRP_CD IS NOT NULL AND ISNULL(I.ITEMGRP_CD, N'') <> @ITEMGRP_CD)
        OR (@L_CD IS NOT NULL AND ISNULL(I.L_CD, N'') <> @L_CD)
        OR (@M_CD IS NOT NULL AND ISNULL(I.M_CD, N'') <> @M_CD)
        OR (@S_CD IS NOT NULL AND ISNULL(I.S_CD, N'') <> @S_CD);

    DELETE A FROM #MTL_REQ A INNER JOIN SITEM I WITH (NOLOCK)
           ON I.CO_CD = A.CO_CD AND I.ITEM_CD = A.MTL_ITEM_CD
    WHERE  (@ACCT_FG_ONLY = N'Y' AND I.ACCT_FG NOT IN (N'0',N'1',N'2',N'4',N'5',N'6'))
        OR (@ITEMGRP_CD IS NOT NULL AND ISNULL(I.ITEMGRP_CD, N'') <> @ITEMGRP_CD)
        OR (@L_CD IS NOT NULL AND ISNULL(I.L_CD, N'') <> @L_CD)
        OR (@M_CD IS NOT NULL AND ISNULL(I.M_CD, N'') <> @M_CD)
        OR (@S_CD IS NOT NULL AND ISNULL(I.S_CD, N'') <> @S_CD);

    DELETE A FROM #MTL_ISU A INNER JOIN SITEM I WITH (NOLOCK)
           ON I.CO_CD = A.CO_CD AND I.ITEM_CD = A.MTL_ITEM_CD
    WHERE  (@ACCT_FG_ONLY = N'Y' AND I.ACCT_FG NOT IN (N'0',N'1',N'2',N'4',N'5',N'6'))
        OR (@ITEMGRP_CD IS NOT NULL AND ISNULL(I.ITEMGRP_CD, N'') <> @ITEMGRP_CD)
        OR (@L_CD IS NOT NULL AND ISNULL(I.L_CD, N'') <> @L_CD)
        OR (@M_CD IS NOT NULL AND ISNULL(I.M_CD, N'') <> @M_CD)
        OR (@S_CD IS NOT NULL AND ISNULL(I.S_CD, N'') <> @S_CD);

    DELETE A FROM #MTL_STD A INNER JOIN SITEM I WITH (NOLOCK)
           ON I.CO_CD = A.CO_CD AND I.ITEM_CD = A.MTL_ITEM_CD
    WHERE  (@ACCT_FG_ONLY = N'Y' AND I.ACCT_FG NOT IN (N'0',N'1',N'2',N'4',N'5',N'6'))
        OR (@ITEMGRP_CD IS NOT NULL AND ISNULL(I.ITEMGRP_CD, N'') <> @ITEMGRP_CD)
        OR (@L_CD IS NOT NULL AND ISNULL(I.L_CD, N'') <> @L_CD)
        OR (@M_CD IS NOT NULL AND ISNULL(I.M_CD, N'') <> @M_CD)
        OR (@S_CD IS NOT NULL AND ISNULL(I.S_CD, N'') <> @S_CD);
END

CREATE CLUSTERED INDEX IX_MTL_ACT ON #MTL_ACT (CO_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD);

PRINT N'[INFO] 실사용 건수 = ' + CAST((SELECT COUNT(*) FROM #MTL_ACT) AS NVARCHAR(20))
    + N' (원천 : ' + @MTL_SRC_FG + N')';


/*==============================================================================================
  8. #TAV_UM : 원가모듈 확정 출고단가 (@UM_BASE_FG='TAV')
     [(6) 3번 블록] CIV_PUR_TAV.ISU_UM
        = (기초금액+입고금액+대체입고금액) / (기초수량+입고수량+대체입고수량)
==============================================================================================*/
CREATE TABLE #TAV_UM ( CO_CD NVARCHAR(4), ITEM_CD NVARCHAR(30), ISU_UM DECIMAL(19,6) );

IF @UM_BASE_FG = N'TAV'
BEGIN
    IF OBJECT_ID(N'dbo.CIV_PUR_TAV', N'U') IS NULL
    BEGIN
        RAISERROR(N'CIV_PUR_TAV 테이블이 없습니다. @UM_BASE_FG 를 RCV/CLS 로 변경하십시오.', 16, 1);
        RETURN;
    END

    IF @COST_CHASU IS NULL
        SET @SQL = N'SELECT @p_out = MAX(CHASU) FROM dbo.CIV_PUR_TAV WITH (NOLOCK)
                      WHERE CO_CD = @p_CO_CD AND P_YR = @p_YR
                        AND (@p_DIV IS NULL OR DIV_CD = @p_DIV)';
    ELSE
        SET @SQL = N'SELECT @p_out = @p_CHASU';

    EXEC sp_executesql @SQL
        ,N'@p_CO_CD NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YR NVARCHAR(4), @p_CHASU NUMERIC(3,0), @p_out NUMERIC(3,0) OUTPUT'
        ,@p_CO_CD = @CO_CD, @p_DIV = @DIV_CD, @p_YR = @COST_YR, @p_CHASU = @COST_CHASU
        ,@p_out = @COST_CHASU OUTPUT;

    SET @SQL = N'
        INSERT INTO #TAV_UM (CO_CD, ITEM_CD, ISU_UM)
        SELECT  P.CO_CD, P.ITEM_CD
               ,CAST(AVG(CAST(ISNULL(P.ISU_UM, 0) AS DECIMAL(19,6))) AS DECIMAL(19,6))
        FROM    dbo.CIV_PUR_TAV P WITH (NOLOCK)
        WHERE   P.CO_CD = @p_CO_CD AND P.P_YR = @p_YR AND P.CHASU = @p_CHASU
          AND   (@p_DIV IS NULL OR P.DIV_CD = @p_DIV)
        GROUP BY P.CO_CD, P.ITEM_CD';

    EXEC sp_executesql @SQL
        ,N'@p_CO_CD NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YR NVARCHAR(4), @p_CHASU NUMERIC(3,0)'
        ,@p_CO_CD = @CO_CD, @p_DIV = @DIV_CD, @p_YR = @COST_YR, @p_CHASU = @COST_CHASU;

    PRINT N'[INFO] 원가 출고단가 : P_YR=' + @COST_YR
        + N' CHASU=' + ISNULL(CAST(@COST_CHASU AS NVARCHAR(10)), N'(없음)')
        + N' 품목수=' + CAST((SELECT COUNT(*) FROM #TAV_UM) AS NVARCHAR(20));
END

CREATE CLUSTERED INDEX IX_TAV_UM ON #TAV_UM (CO_CD, ITEM_CD);


/*==============================================================================================
  9. #MTL_UM : 자재품목별 단가 마스터
==============================================================================================*/
;WITH PUR_RCV AS
(
    SELECT
         D.CO_CD, D.ITEM_CD
        ,PUR_DT = S.RCV_DT
        ,PUR_QT = CAST(ISNULL(D.RCV_QT , 0) AS DECIMAL(19,6))
        ,PUR_AM = CAST(ISNULL(D.RCVG_AM, 0) AS DECIMAL(19,6))
        ,PUR_UM = CAST(ISNULL(D.RCV_UM , 0) AS DECIMAL(19,6))
    FROM        LSTOCK   S WITH (NOLOCK)
    INNER JOIN  LSTOCK_D D WITH (NOLOCK)
           ON   D.CO_CD = S.CO_CD AND D.RCV_NB = S.RCV_NB
    WHERE   @UM_BASE_FG = N'RCV'
      AND   S.CO_CD     = @CO_CD
      AND   S.RCV_DT BETWEEN @PUR_FR_DT AND @PUR_TO_DT
      AND   (@DIV_CD IS NULL OR S.DIV_CD = @DIV_CD)
      AND   D.EXPIRE_YN = N'1'
      AND   ISNULL(D.RCV_QT, 0) > 0
)
,PUR_CLS AS
(
    SELECT
         C.CO_CD, C.ITEM_CD
        ,PUR_DT = ISNULL(NULLIF(S.RCV_DT, N''), @PUR_TO_DT)
        ,PUR_QT = CAST(ISNULL(C.CLS_QT , 0) AS DECIMAL(19,6))
        ,PUR_AM = CAST(ISNULL(C.CLSG_AM, 0) AS DECIMAL(19,6))
        ,PUR_UM = CAST(ISNULL(C.CLS_UM , 0) AS DECIMAL(19,6))
    FROM        LPURCLS_D C WITH (NOLOCK)
    LEFT  JOIN  LSTOCK    S WITH (NOLOCK)
           ON   S.CO_CD = C.CO_CD AND S.RCV_NB = C.RCV_NB
    WHERE   @UM_BASE_FG = N'CLS'
      AND   C.CO_CD     = @CO_CD
      AND   C.EXPIRE_YN = N'1'
      AND   ISNULL(C.CLS_QT, 0) > 0
      AND   ISNULL(NULLIF(S.RCV_DT, N''), @PUR_TO_DT) BETWEEN @PUR_FR_DT AND @PUR_TO_DT
      AND   (@DIV_CD IS NULL OR S.DIV_CD = @DIV_CD OR S.DIV_CD IS NULL)
)
,PUR AS ( SELECT * FROM PUR_RCV UNION ALL SELECT * FROM PUR_CLS )
,PUR_AGG AS
(
    SELECT CO_CD, ITEM_CD, TOT_QT = SUM(PUR_QT), TOT_AM = SUM(PUR_AM)
    FROM PUR GROUP BY CO_CD, ITEM_CD
)
,PUR_LAST AS
(
    SELECT CO_CD, ITEM_CD, PUR_DT, PUR_UM
    FROM ( SELECT CO_CD, ITEM_CD, PUR_DT, PUR_UM
                 ,RN = ROW_NUMBER() OVER (PARTITION BY CO_CD, ITEM_CD ORDER BY PUR_DT DESC)
           FROM PUR WHERE PUR_UM > 0 ) X
    WHERE RN = 1
)
SELECT
     I.CO_CD
    ,I.ITEM_CD
    ,ITEM_NM    = I.ITEM_NM
    ,ITEM_DC    = I.ITEM_DC
    ,UNIT_DC    = I.UNIT_DC
    ,ITEMGRP_CD = I.ITEMGRP_CD
    ,ACCT_FG    = I.ACCT_FG
    ,ODR_FG     = I.ODR_FG
    ,FOQ_QT     = CAST(ISNULL(I.FOQ_QT, 0) AS DECIMAL(19,6))
    ,STD_UM     = CAST(ISNULL(I.PURCH_UM, 0) AS DECIMAL(19,6))
    ,STDCOST_UM = CAST(ROUND(ISNULL(I.STANDARD_UM, 0) * ISNULL(NULLIF(I.UNITCHNG_NB, 0), 1), 0, 1)
                       AS DECIMAL(19,6))                            -- 생산표준원가 [(5)]
    ,TAV_UM     = T.ISU_UM
    ,AVG_UM     = CAST(CASE WHEN ISNULL(A.TOT_QT, 0) > 0 THEN A.TOT_AM / A.TOT_QT END AS DECIMAL(19,6))
    ,LST_UM     = CAST(L.PUR_UM AS DECIMAL(19,6))
    ,LST_DT     = L.PUR_DT
    ,PUR_UM     = CAST(COALESCE( NULLIF(T.ISU_UM, 0)
                               , CASE WHEN ISNULL(A.TOT_QT, 0) > 0 THEN A.TOT_AM / A.TOT_QT END
                               , NULLIF(L.PUR_UM, 0)
                               , I.PURCH_UM, 0 ) AS DECIMAL(19,6))
    ,UM_SRC_FG  = CASE WHEN ISNULL(T.ISU_UM , 0) > 0 THEN N'원가확정출고단가(CIV_PUR_TAV)'
                       WHEN ISNULL(A.TOT_QT , 0) > 0 THEN N'기간가중평균매입'
                       WHEN ISNULL(L.PUR_UM , 0) > 0 THEN N'최종매입'
                       WHEN ISNULL(I.PURCH_UM,0) > 0 THEN N'표준단가(구매단가)대체'
                       ELSE N'단가없음' END
INTO #MTL_UM
FROM        SITEM    I WITH (NOLOCK)
LEFT  JOIN  #TAV_UM  T ON T.CO_CD = I.CO_CD AND T.ITEM_CD = I.ITEM_CD
LEFT  JOIN  PUR_AGG  A ON A.CO_CD = I.CO_CD AND A.ITEM_CD = I.ITEM_CD
LEFT  JOIN  PUR_LAST L ON L.CO_CD = I.CO_CD AND L.ITEM_CD = I.ITEM_CD
WHERE   I.CO_CD = @CO_CD
;
CREATE CLUSTERED INDEX IX_MTL_UM ON #MTL_UM (CO_CD, ITEM_CD);


/*==============================================================================================
 10. #OUT_AM : 프로젝트별 외주가공비   [(6) 5-4 : LOCLS_D x LOCLS_H]
==============================================================================================*/
CREATE TABLE #OUT_AM ( CO_CD NVARCHAR(4), PJT_CD NVARCHAR(10), LBR_AM DECIMAL(19,4), SRC_FG NVARCHAR(20) );

IF OBJECT_ID(N'dbo.LOCLS_H', N'U') IS NOT NULL AND OBJECT_ID(N'dbo.LOCLS_D', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
        INSERT INTO #OUT_AM (CO_CD, PJT_CD, LBR_AM, SRC_FG)
        SELECT  H.CO_CD, H.PJT_CD
               ,SUM(CAST(ISNULL(D.LBR_AM, 0) AS DECIMAL(19,4)))
               ,N''외주마감(LOCLS)''
        FROM    dbo.LOCLS_D D WITH (NOLOCK)
        INNER JOIN dbo.LOCLS_H H WITH (NOLOCK)
               ON  H.CO_CD = D.CO_CD AND H.DOC_CD = D.DOC_CD
        WHERE   H.CO_CD  = @p_CO_CD
          AND   H.DOC_DT BETWEEN @p_FR AND @p_TO
          AND   (@p_DIV IS NULL OR H.DIV_CD = @p_DIV)
          AND   ISNULL(D.USE_YN, N''1'') = N''1''
          AND   H.PJT_CD IS NOT NULL AND H.PJT_CD <> N''''
          AND   (@p_PJT IS NULL OR H.PJT_CD = @p_PJT)
        GROUP BY H.CO_CD, H.PJT_CD';

    EXEC sp_executesql @SQL
        ,N'@p_CO_CD NVARCHAR(4), @p_DIV NVARCHAR(4), @p_FR NVARCHAR(8), @p_TO NVARCHAR(8), @p_PJT NVARCHAR(10)'
        ,@p_CO_CD = @CO_CD, @p_DIV = @DIV_CD, @p_FR = @FR_DT, @p_TO = @TO_DT, @p_PJT = @PJT_CD;
END
ELSE
BEGIN
    INSERT INTO #OUT_AM (CO_CD, PJT_CD, LBR_AM, SRC_FG)
    SELECT  P.CO_CD, P.PJT_CD
           ,SUM(CAST(ISNULL(WD.LBR_AM, 0) AS DECIMAL(19,4)))
           ,N'지시외주금액(LWO_WF_D)'
    FROM   (SELECT DISTINCT CO_CD, PJT_CD, WO_CD FROM #PRD) P
    INNER JOIN LWO_WF_D WD WITH (NOLOCK)
           ON  WD.CO_CD = P.CO_CD AND WD.WO_CD = P.WO_CD
    WHERE  WD.USE_YN = N'1' AND WD.DOC_FG = N'1'
    GROUP BY P.CO_CD, P.PJT_CD;
END

CREATE CLUSTERED INDEX IX_OUT_AM ON #OUT_AM (CO_CD, PJT_CD);


/*==============================================================================================
 11. #COST : 표준 / 청구 / 출고 / 사용  4단계 대사 + 원가/차이 산출
==============================================================================================*/
;WITH STD AS
(
    SELECT CO_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD
          ,STD_QT = SUM(STD_QT), BOM_LVL = MIN(BOM_LVL)
          ,BOM_JUST_QT = MAX(JUST_QT), BOM_LOSS_RT = MAX(LOSS_RT)
          ,BOM_REAL_QT = MAX(REAL_QT), BOM_QTY_PER = MAX(QTY_PER)
    FROM #MTL_STD GROUP BY CO_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD
)
,REQ AS
(
    SELECT CO_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD, REQ_QT = SUM(REQ_QT)
    FROM #MTL_REQ GROUP BY CO_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD
)
,ISU AS
(
    SELECT CO_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD, ISU_QT = SUM(ISU_QT)
    FROM #MTL_ISU GROUP BY CO_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD
)
,ACT AS
(
    SELECT CO_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD, ACT_QT = SUM(USE_QT), USE_CNT = COUNT(*)
    FROM #MTL_ACT GROUP BY CO_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD
)
,KEYS AS                                                        -- 4개 축의 합집합 키
(
    SELECT CO_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD FROM STD
    UNION SELECT CO_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD FROM REQ
    UNION SELECT CO_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD FROM ISU
    UNION SELECT CO_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD FROM ACT
)
SELECT
     K.CO_CD, K.PJT_CD, K.PROD_ITEM_CD, K.MTL_ITEM_CD

    ,MATCH_FG = CASE WHEN S.MTL_ITEM_CD IS NULL AND A.MTL_ITEM_CD IS NOT NULL THEN N'BOM외투입'
                     WHEN S.MTL_ITEM_CD IS NOT NULL AND A.MTL_ITEM_CD IS NULL THEN N'미투입(BOM만)'
                     WHEN S.MTL_ITEM_CD IS NULL AND A.MTL_ITEM_CD IS NULL     THEN N'청구/출고만'
                     ELSE N'정상' END

    -- 4단계 수량
    ,STD_QT  = CAST(ISNULL(S.STD_QT, 0) AS DECIMAL(19,6))
    ,REQ_QT  = CAST(ISNULL(R.REQ_QT, 0) AS DECIMAL(19,6))
    ,ISU_QT  = CAST(ISNULL(U.ISU_QT, 0) AS DECIMAL(19,6))
    ,ACT_QT  = CAST(ISNULL(A.ACT_QT, 0) AS DECIMAL(19,6))

    -- 단계별 차이
    ,D_STD_REQ = CAST(ISNULL(R.REQ_QT,0) - ISNULL(S.STD_QT,0) AS DECIMAL(19,6))  -- 표준->청구
    ,D_REQ_ISU = CAST(ISNULL(U.ISU_QT,0) - ISNULL(R.REQ_QT,0) AS DECIMAL(19,6))  -- 청구->출고
    ,D_ISU_ACT = CAST(ISNULL(A.ACT_QT,0) - ISNULL(U.ISU_QT,0) AS DECIMAL(19,6))  -- 출고->사용
    ,DIFF_QT   = CAST(ISNULL(A.ACT_QT,0) - ISNULL(S.STD_QT,0) AS DECIMAL(19,6))  -- 표준->사용(총)

    ,REQ_YN = CASE WHEN R.MTL_ITEM_CD IS NOT NULL THEN N'Y' ELSE N'N' END
    ,ISU_YN = CASE WHEN U.MTL_ITEM_CD IS NOT NULL THEN N'Y' ELSE N'N' END
    ,USE_CNT = ISNULL(A.USE_CNT, 0)

    ,BOM_LVL     = S.BOM_LVL
    ,BOM_JUST_QT = S.BOM_JUST_QT
    ,BOM_LOSS_RT = S.BOM_LOSS_RT
    ,BOM_REAL_QT = S.BOM_REAL_QT
    ,BOM_QTY_PER = S.BOM_QTY_PER

    ,STD_UM    = CAST(ISNULL(M.STD_UM, 0) AS DECIMAL(19,6))
    ,PUR_UM    = CAST(ISNULL(M.PUR_UM, 0) AS DECIMAL(19,6))
    ,UM_SRC_FG = M.UM_SRC_FG
INTO #COST
FROM        KEYS K
LEFT  JOIN  STD S ON S.CO_CD=K.CO_CD AND S.PJT_CD=K.PJT_CD AND S.PROD_ITEM_CD=K.PROD_ITEM_CD AND S.MTL_ITEM_CD=K.MTL_ITEM_CD
LEFT  JOIN  REQ R ON R.CO_CD=K.CO_CD AND R.PJT_CD=K.PJT_CD AND R.PROD_ITEM_CD=K.PROD_ITEM_CD AND R.MTL_ITEM_CD=K.MTL_ITEM_CD
LEFT  JOIN  ISU U ON U.CO_CD=K.CO_CD AND U.PJT_CD=K.PJT_CD AND U.PROD_ITEM_CD=K.PROD_ITEM_CD AND U.MTL_ITEM_CD=K.MTL_ITEM_CD
LEFT  JOIN  ACT A ON A.CO_CD=K.CO_CD AND A.PJT_CD=K.PJT_CD AND A.PROD_ITEM_CD=K.PROD_ITEM_CD AND A.MTL_ITEM_CD=K.MTL_ITEM_CD
LEFT  JOIN  #MTL_UM M ON M.CO_CD = K.CO_CD AND M.ITEM_CD = K.MTL_ITEM_CD
;


/*==============================================================================================
  ** 쿼리 A : 프로젝트별 생산원가 요약
==============================================================================================*/
SELECT
     N'[A] 프로젝트별 생산원가 요약'                AS REPORT_NM
    ,C.PJT_CD                                       AS 프로젝트코드
    ,J.PJT_NM                                       AS 프로젝트명
    ,G.PJTGRP_NM                                    AS 프로젝트분류
    ,J.ORD_AM                                       AS 수주금액
    ,J.ESTI_AM                                      AS 예정원가

    ,COUNT(DISTINCT C.PROD_ITEM_CD)                 AS 생산품목수
    ,COUNT(DISTINCT C.MTL_ITEM_CD)                  AS 투입자재품목수

    ,SUM(C.STD_QT)                                  AS 표준사용량계
    ,SUM(C.REQ_QT)                                  AS 청구량계
    ,SUM(C.ISU_QT)                                  AS 출고량계
    ,SUM(C.ACT_QT)                                  AS 실사용량계
    ,SUM(C.DIFF_QT)                                 AS 사용량차이계

    ,SUM(C.STD_QT * C.STD_UM)                       AS 표준재료비
    ,SUM(C.ACT_QT * C.PUR_UM)                       AS 실제재료비
    ,SUM(C.ISU_QT * C.PUR_UM)                       AS 출고기준재료비
    ,SUM(C.ACT_QT * C.STD_UM)                       AS 실사용량_표준단가금액

    ,SUM(C.DIFF_QT * C.STD_UM)                      AS 수량차이금액
    ,SUM((C.PUR_UM - C.STD_UM) * C.ACT_QT)          AS 단가차이금액
    ,SUM(C.ACT_QT * C.PUR_UM) - SUM(C.STD_QT * C.STD_UM) AS 총원가차이금액

    ,CAST( CASE WHEN SUM(C.STD_QT * C.STD_UM) <> 0
                THEN (SUM(C.ACT_QT * C.PUR_UM) - SUM(C.STD_QT * C.STD_UM))
                     / SUM(C.STD_QT * C.STD_UM) * 100 END AS DECIMAL(19,2)) AS 원가차이율_PCT

    ,SUM((C.ISU_QT - C.ACT_QT) * C.PUR_UM)          AS 출고미사용금액   -- 사용보고 누락/현장잔량 추정

    ,MAX(O.LBR_AM)                                  AS 외주가공비
    ,SUM(C.ACT_QT * C.PUR_UM) + ISNULL(MAX(O.LBR_AM), 0) AS 재료비_외주비_합계
    ,MAX(O.SRC_FG)                                  AS 외주비산출근거
FROM        #COST C
LEFT  JOIN  SPJT    J WITH (NOLOCK) ON J.CO_CD = C.CO_CD AND J.PJT_CD = C.PJT_CD
LEFT  JOIN  SPJTGRP G WITH (NOLOCK) ON G.CO_CD = J.CO_CD AND G.PJTGRP_CD = J.PJTGRP_CD
LEFT  JOIN  #OUT_AM O ON O.CO_CD = C.CO_CD AND O.PJT_CD = C.PJT_CD
GROUP BY C.CO_CD, C.PJT_CD, J.PJT_NM, G.PJTGRP_NM, J.ORD_AM, J.ESTI_AM
ORDER BY 총원가차이금액 DESC
;


/*==============================================================================================
  ** 쿼리 B : 프로젝트 x 생산품목 x 투입자재 상세 (메인 보고서)
==============================================================================================*/
SELECT
     N'[B] 프로젝트별 자재 표준 vs 실적 상세'       AS REPORT_NM
    ,C.PJT_CD                                       AS 프로젝트코드
    ,J.PJT_NM                                       AS 프로젝트명

    ,C.PROD_ITEM_CD                                 AS 생산품번
    ,PI.ITEM_NM                                     AS 생산품명
    ,PI.ITEM_DC                                     AS 생산규격
    ,Q.PRD_QT                                       AS 생산실적수량
    ,PI.UNIT_DC                                     AS 생산단위
    ,Q.WO_CNT                                       AS 작업지시건수
    ,Q.PRD_CNT                                      AS 실적건수

    ,C.BOM_LVL                                      AS BOM레벨
    ,C.MTL_ITEM_CD                                  AS 자재품번
    ,MI.ITEM_NM                                     AS 자재품명
    ,MI.ITEM_DC                                     AS 자재규격
    ,MI.UNIT_DC                                     AS 자재단위
    ,MG.ITEMGRP_NM                                  AS 자재품목군
    ,C.MATCH_FG                                     AS 대사구분

    ,C.BOM_JUST_QT                                  AS BOM정미수량
    ,C.BOM_LOSS_RT                                  AS BOM로스율
    ,C.BOM_REAL_QT                                  AS BOM필요수량
    ,C.BOM_QTY_PER                                  AS BOM누적소요량

    -- 4단계 수량
    ,C.STD_QT                                       AS 표준사용량
    ,C.REQ_QT                                       AS 청구량
    ,C.ISU_QT                                       AS 출고량
    ,C.ACT_QT                                       AS 실사용량

    -- 단계별 차이
    ,C.D_STD_REQ                                    AS 차이_표준대비청구
    ,C.D_REQ_ISU                                    AS 차이_청구대비출고
    ,C.D_ISU_ACT                                    AS 차이_출고대비사용
    ,C.DIFF_QT                                      AS 차이_표준대비사용
    ,CAST(CASE WHEN C.STD_QT <> 0 THEN C.DIFF_QT / C.STD_QT * 100 END AS DECIMAL(19,2)) AS 사용량차이율_PCT
    ,CAST(CASE WHEN Q.PRD_QT  <> 0 THEN C.ACT_QT / Q.PRD_QT END AS DECIMAL(19,6))       AS 실제원단위
       -- 실제원단위 = USE_QT / PRD_QT : 원가계산 SP 의 CIV_PRD_TAV_D.REAL_QT 와 동일 정의 [(6) 5-3]

    ,C.STD_UM                                       AS 표준단가_구매단가
    ,C.PUR_UM                                       AS 실제단가
    ,C.PUR_UM - C.STD_UM                            AS 단가차이
    ,CAST(CASE WHEN C.STD_UM <> 0 THEN (C.PUR_UM - C.STD_UM) / C.STD_UM * 100 END AS DECIMAL(19,2)) AS 단가차이율_PCT
    ,C.UM_SRC_FG                                    AS 실제단가산출근거

    ,C.STD_QT * C.STD_UM                            AS 표준재료비
    ,C.ACT_QT * C.PUR_UM                            AS 실제재료비
    ,C.ISU_QT * C.PUR_UM                            AS 출고기준재료비
    ,C.DIFF_QT * C.STD_UM                           AS 수량차이금액
    ,(C.PUR_UM - C.STD_UM) * C.ACT_QT               AS 단가차이금액
    ,(C.ACT_QT * C.PUR_UM) - (C.STD_QT * C.STD_UM)  AS 총원가차이금액
FROM        #COST C
LEFT  JOIN  SPJT     J  WITH (NOLOCK) ON J.CO_CD  = C.CO_CD AND J.PJT_CD   = C.PJT_CD
LEFT  JOIN  SITEM    PI WITH (NOLOCK) ON PI.CO_CD = C.CO_CD AND PI.ITEM_CD = C.PROD_ITEM_CD
LEFT  JOIN  SITEM    MI WITH (NOLOCK) ON MI.CO_CD = C.CO_CD AND MI.ITEM_CD = C.MTL_ITEM_CD
LEFT  JOIN  SITEMGRP MG WITH (NOLOCK) ON MG.CO_CD = MI.CO_CD AND MG.ITEMGRP_CD = MI.ITEMGRP_CD
LEFT  JOIN  ( SELECT CO_CD, PJT_CD, PROD_ITEM_CD
                    ,PRD_QT  = SUM(PRD_QT)
                    ,PRD_CNT = COUNT(DISTINCT DOC_CD)
                    ,WO_CNT  = COUNT(DISTINCT WO_CD)
              FROM   #PRD GROUP BY CO_CD, PJT_CD, PROD_ITEM_CD ) Q
       ON   Q.CO_CD = C.CO_CD AND Q.PJT_CD = C.PJT_CD AND Q.PROD_ITEM_CD = C.PROD_ITEM_CD
ORDER BY C.PJT_CD, C.PROD_ITEM_CD, C.BOM_LVL, C.MTL_ITEM_CD
;


/*==============================================================================================
  ** 쿼리 C : 지시별 자재현황 (청구 -> 출고 -> 사용) 진행상태 추적
     [(11) 참조 쿼리 구조 + 프로젝트/BOM표준 축 추가]
==============================================================================================*/
SELECT
     N'[C] 지시별 자재현황(청구/출고/사용)'         AS REPORT_NM
    ,X.PJT_CD                                       AS 프로젝트코드
    ,J.PJT_NM                                       AS 프로젝트명
    ,D.DIV_NM                                       AS 사업장
    ,X.WO_CD                                        AS 지시_NO
    ,W.ORD_DT                                       AS 지시일
    ,X.PROD_ITEM_CD                                 AS 지시품목
    ,PI.ITEM_NM                                     AS 지시품명
    ,W.WO_QT                                        AS 지시량
    ,W.PRD_QT                                       AS 실적량
    ,X.WOBOM_SQ                                     AS 순번
    ,X.MTL_ITEM_CD                                  AS 자재품목
    ,MI.ITEM_NM                                     AS 자재품명
    ,MI.UNIT_DC                                     AS 단위
    ,SB.BASELOC_NM                                  AS 공정
    ,SL.LOC_NM                                      AS 작업장

    ,X.REQ_QT                                       AS 청구량
    ,X.ISU_QT                                       AS 출고량
    ,X.ACT_QT                                       AS 사용량
    ,진행구분 = CASE
         WHEN X.REQ_QT <> 0 AND X.ISU_QT  = 0                     THEN N'출고대기'
         WHEN X.ISU_QT <> 0 AND X.ACT_QT  = 0                     THEN N'사용대기'
         WHEN X.REQ_QT <> 0 AND X.ISU_QT <> 0 AND X.REQ_QT > X.ISU_QT THEN N'출고중'
         WHEN X.ISU_QT <> 0 AND X.ACT_QT <> 0 AND X.ISU_QT = X.ACT_QT THEN N'사용완료'
         WHEN X.ISU_QT <> 0 AND X.ACT_QT <> 0 AND X.ISU_QT > X.ACT_QT THEN N'사용중(잔량)'
         WHEN X.REQ_QT  = 0 AND X.ISU_QT <> 0                     THEN N'청구없는출고'
         ELSE N'기타' END
    ,X.ISU_QT - X.ACT_QT                            AS 출고미사용량
    ,M.PUR_UM                                       AS 실제단가
    ,(X.ISU_QT - X.ACT_QT) * M.PUR_UM               AS 출고미사용금액
FROM (
        SELECT CO_CD, DIV_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD, WO_CD, WOBOM_SQ
              ,BASELOC_CD = MAX(BASELOC_CD), LOC_CD = MAX(LOC_CD)
              ,REQ_QT = SUM(REQ_QT), ISU_QT = SUM(ISU_QT), ACT_QT = SUM(ACT_QT)
        FROM (
                SELECT CO_CD, DIV_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD, WO_CD, WOBOM_SQ
                      ,BASELOC_CD, LOC_CD, REQ_QT, ISU_QT = CAST(0 AS DECIMAL(19,6)), ACT_QT = CAST(0 AS DECIMAL(19,6))
                FROM   #MTL_REQ
                UNION ALL
                SELECT CO_CD, DIV_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD, WO_CD, WOBOM_SQ
                      ,NULL, NULL, 0, ISU_QT, 0
                FROM   #MTL_ISU
                UNION ALL
                SELECT CO_CD, DIV_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD, WO_CD, WOBOM_SQ
                      ,BASELOC_CD, LOC_CD, 0, 0, USE_QT
                FROM   #MTL_ACT
             ) Z
        GROUP BY CO_CD, DIV_CD, PJT_CD, PROD_ITEM_CD, MTL_ITEM_CD, WO_CD, WOBOM_SQ
     ) X
LEFT  JOIN  ( SELECT CO_CD, WO_CD, WO_QT = MAX(WO_QT), PRD_QT = SUM(PRD_QT), ORD_DT = MIN(ORD_DT)
              FROM #PRD GROUP BY CO_CD, WO_CD ) W
       ON   W.CO_CD = X.CO_CD AND W.WO_CD = X.WO_CD
LEFT  JOIN  #MTL_UM  M  ON M.CO_CD  = X.CO_CD AND M.ITEM_CD = X.MTL_ITEM_CD
LEFT  JOIN  SPJT     J  WITH (NOLOCK) ON J.CO_CD  = X.CO_CD AND J.PJT_CD  = X.PJT_CD
LEFT  JOIN  SDIV     D  WITH (NOLOCK) ON D.CO_CD  = X.CO_CD AND D.DIV_CD  = X.DIV_CD
LEFT  JOIN  SITEM    PI WITH (NOLOCK) ON PI.CO_CD = X.CO_CD AND PI.ITEM_CD = X.PROD_ITEM_CD
LEFT  JOIN  SITEM    MI WITH (NOLOCK) ON MI.CO_CD = X.CO_CD AND MI.ITEM_CD = X.MTL_ITEM_CD
LEFT  JOIN  SBASELOC SB WITH (NOLOCK) ON SB.CO_CD = X.CO_CD AND SB.BASELOC_CD = X.BASELOC_CD
LEFT  JOIN  SLOC     SL WITH (NOLOCK) ON SL.CO_CD = X.CO_CD AND SL.LOC_CD = X.LOC_CD
                                     AND SL.BASELOC_CD = SB.BASELOC_CD
ORDER BY X.PJT_CD, X.WO_CD, X.WOBOM_SQ, X.MTL_ITEM_CD
;


/*==============================================================================================
  ** 쿼리 D : 실적 단위 자재사용 추적 (Drill-Down)
==============================================================================================*/
SELECT
     N'[D] 실적별 자재사용 추적'                    AS REPORT_NM
    ,U.PJT_CD                                       AS 프로젝트코드
    ,J.PJT_NM                                       AS 프로젝트명
    ,U.SRC_FG                                       AS 자재보고원천
    ,U.WO_CD                                        AS 작업지시번호
    ,P.ORD_DT                                       AS 지시일
    ,CASE P.WOC_FG WHEN N'0' THEN N'생산지시' WHEN N'2' THEN N'임가공지시'
                   WHEN N'4' THEN N'외주발주' WHEN N'5' THEN N'작업지시' END AS 지시구분
    ,U.DOC_CD                                       AS 실적번호
    ,U.DOC_DT                                       AS 실적일
    ,CASE P.DOC_FG WHEN N'0' THEN N'생산' WHEN N'1' THEN N'외주'
                   WHEN N'5' THEN N'재고이동' END   AS 생산외주구분
    ,U.PROD_ITEM_CD                                 AS 생산품번
    ,PI.ITEM_NM                                     AS 생산품명
    ,P.PRD_QT                                       AS 실적수량
    ,CASE P.BAD_YN WHEN N'0' THEN N'적합'   WHEN N'1' THEN N'부적합' END AS 실적구분
    ,CASE P.SUB_TP WHEN N'0' THEN N'주산물' WHEN N'1' THEN N'부산물' END AS 실적품유형
    ,P.LOT_NB                                       AS 생산LOT
    ,BL.BASELOC_NM                                  AS 실적공정
    ,LC.LOC_NM                                      AS 실적작업장

    ,U.MTL_ITEM_CD                                  AS 자재품번
    ,MI.ITEM_NM                                     AS 자재품명
    ,MI.UNIT_DC                                     AS 자재단위
    ,U.USE_DT                                       AS 자재사용일
    ,U.LOT_NB                                       AS 자재LOT
    ,CASE U.UMU_FG WHEN N'0' THEN N'무상' WHEN N'1' THEN N'유상' END AS 유무상구분
    ,U.WOOP_SQ                                      AS 지시전개순번
    ,U.WOBOM_SQ                                     AS 소요자재순번

    ,SB.STD_QT                                      AS 실적건_표준사용량
    ,U.USE_QT                                       AS 실적건_실사용량
    ,U.USE_QT - ISNULL(SB.STD_QT, 0)                AS 사용량차이

    ,M.STD_UM                                       AS 표준단가
    ,M.PUR_UM                                       AS 실제단가
    ,ISNULL(SB.STD_QT, 0) * M.STD_UM                AS 표준재료비
    ,U.USE_QT * M.PUR_UM                            AS 실제재료비
    ,(U.USE_QT * M.PUR_UM) - (ISNULL(SB.STD_QT, 0) * M.STD_UM) AS 원가차이
FROM        #MTL_ACT U
LEFT  JOIN  #PRD     P  ON P.CO_CD  = U.CO_CD AND P.DOC_CD  = U.DOC_CD
LEFT  JOIN  #MTL_STD SB ON SB.CO_CD = U.CO_CD AND SB.DOC_CD = U.DOC_CD
                       AND SB.MTL_ITEM_CD = U.MTL_ITEM_CD
LEFT  JOIN  #MTL_UM  M  ON M.CO_CD  = U.CO_CD AND M.ITEM_CD = U.MTL_ITEM_CD
LEFT  JOIN  SPJT     J  WITH (NOLOCK) ON J.CO_CD  = U.CO_CD AND J.PJT_CD  = U.PJT_CD
LEFT  JOIN  SITEM    PI WITH (NOLOCK) ON PI.CO_CD = U.CO_CD AND PI.ITEM_CD = U.PROD_ITEM_CD
LEFT  JOIN  SITEM    MI WITH (NOLOCK) ON MI.CO_CD = U.CO_CD AND MI.ITEM_CD = U.MTL_ITEM_CD
LEFT  JOIN  SBASELOC BL WITH (NOLOCK) ON BL.CO_CD = P.CO_CD AND BL.BASELOC_CD = P.BASELOC_CD
LEFT  JOIN  SLOC     LC WITH (NOLOCK) ON LC.CO_CD = P.CO_CD AND LC.LOC_CD = P.LOC_CD
                                     AND LC.BASELOC_CD = P.BASELOC_CD
ORDER BY U.PJT_CD, U.WO_CD, U.DOC_CD, U.USE_SQ
;


/*==============================================================================================
  ** 쿼리 E : 이상징후(Exception) 리스트
==============================================================================================*/
SELECT
     N'[E] 이상징후'                                AS REPORT_NM
    ,C.PJT_CD                                       AS 프로젝트코드
    ,J.PJT_NM                                       AS 프로젝트명
    ,C.PROD_ITEM_CD                                 AS 생산품번
    ,C.MTL_ITEM_CD                                  AS 자재품번
    ,MI.ITEM_NM                                     AS 자재품명
    ,이상유형 = CASE
          WHEN C.ISU_QT <> 0 AND C.ACT_QT = 0                                THEN N'1.출고 후 사용보고 누락'
          WHEN C.MATCH_FG = N'BOM외투입'                                     THEN N'2.BOM 미등록 자재 투입'
          WHEN C.MATCH_FG = N'미투입(BOM만)'                                 THEN N'3.BOM 자재 미투입'
          WHEN C.REQ_QT <> 0 AND C.ISU_QT = 0                                THEN N'4.청구 후 출고 누락'
          WHEN C.STD_UM  = 0                                                 THEN N'5.표준단가(구매단가) 미등록'
          WHEN C.UM_SRC_FG = N'단가없음'                                     THEN N'6.실제단가 산출불가'
          WHEN C.ISU_QT <> 0 AND ABS(C.D_ISU_ACT / NULLIF(C.ISU_QT,0)) > 0.05 THEN N'7.출고-사용 5% 초과 괴리'
          WHEN C.STD_QT <> 0 AND ABS(C.DIFF_QT / C.STD_QT) > 0.1             THEN N'8.사용량 +-10% 초과'
          WHEN C.STD_UM <> 0 AND ABS((C.PUR_UM - C.STD_UM) / C.STD_UM) > 0.1 THEN N'9.단가 +-10% 초과'
          ELSE NULL END
    ,C.STD_QT                                       AS 표준사용량
    ,C.REQ_QT                                       AS 청구량
    ,C.ISU_QT                                       AS 출고량
    ,C.ACT_QT                                       AS 실사용량
    ,C.D_ISU_ACT                                    AS 출고대비사용차이
    ,C.DIFF_QT                                      AS 표준대비사용차이
    ,C.STD_UM                                       AS 표준단가
    ,C.PUR_UM                                       AS 실제단가
    ,(C.ACT_QT * C.PUR_UM) - (C.STD_QT * C.STD_UM)  AS 총원가차이금액
    ,(C.ISU_QT - C.ACT_QT) * C.PUR_UM               AS 출고미사용금액
FROM        #COST C
LEFT  JOIN  SPJT  J  WITH (NOLOCK) ON J.CO_CD  = C.CO_CD AND J.PJT_CD  = C.PJT_CD
LEFT  JOIN  SITEM MI WITH (NOLOCK) ON MI.CO_CD = C.CO_CD AND MI.ITEM_CD = C.MTL_ITEM_CD
WHERE   C.MATCH_FG <> N'정상'
   OR   C.STD_UM = 0
   OR   C.UM_SRC_FG = N'단가없음'
   OR   (C.ISU_QT <> 0 AND C.ACT_QT = 0)
   OR   (C.REQ_QT <> 0 AND C.ISU_QT = 0)
   OR   (C.ISU_QT <> 0 AND ABS(C.D_ISU_ACT / NULLIF(C.ISU_QT,0)) > 0.05)
   OR   (C.STD_QT <> 0 AND ABS(C.DIFF_QT / C.STD_QT) > 0.1)
   OR   (C.STD_UM <> 0 AND ABS((C.PUR_UM - C.STD_UM) / C.STD_UM) > 0.1)
ORDER BY ABS((C.ACT_QT * C.PUR_UM) - (C.STD_QT * C.STD_UM)) DESC
;


/*==============================================================================================
  ** 쿼리 F : BOM 정전개 명세 (SYC0620 대응 / 표준사용량 산출근거)
==============================================================================================*/
SELECT
     N'[F] BOM 정전개'                              AS REPORT_NM
    ,E.ROOT_ITEM_CD                                 AS 생산품번
    ,RI.ITEM_NM                                     AS 생산품명
    ,E.LVL                                          AS LEVEL
    ,REPLICATE(N'    ', E.LVL - 1) + E.CHILD_CD     AS 전개품번
    ,E.PARENT_CD                                    AS 모품번
    ,E.CHILD_CD                                     AS 자품번
    ,CI.ITEM_NM                                     AS 자품명
    ,CI.ITEM_DC                                     AS 자규격
    ,CI.UNIT_DC                                     AS 단위
    ,E.JUST_QT                                      AS 정미수량
    ,E.LOSS_RT                                      AS LOSS율_PCT
    ,E.REAL_QT                                      AS 필요수량
    ,E.QTY_PER                                      AS 누적소요량
    ,E.LEAF_YN                                      AS 최하위여부
    ,CI.DESIGN_NB                                   AS 도면번호
    ,TR.TR_NM                                       AS 주거래처
    ,CI.ODR_FG                                      AS 조달구분
    ,CI.ACCT_FG                                     AS 계정구분
    ,E.NODE_PATH                                    AS 전개경로
FROM        #BOM_EXP E
LEFT  JOIN  SITEM   RI WITH (NOLOCK) ON RI.CO_CD = E.CO_CD AND RI.ITEM_CD = E.ROOT_ITEM_CD
LEFT  JOIN  SITEM   CI WITH (NOLOCK) ON CI.CO_CD = E.CO_CD AND CI.ITEM_CD = E.CHILD_CD
LEFT  JOIN  STRADE  TR WITH (NOLOCK) ON TR.CO_CD = CI.CO_CD AND TR.TR_CD  = CI.TRMAIN_CD
ORDER BY E.ROOT_ITEM_CD, E.NODE_PATH
;


/*==============================================================================================
  ** 쿼리 G : ERP 당기재료비분석(CIV_PRD_TAV_D) 대사 검증
     [(10) USP_COT0020_SELECT 대응] - @UM_BASE_FG='TAV' 로 실행 시 금액이 일치해야 한다.
     * 본 쿼리는 프로젝트별, ERP 는 사업장 전체이므로 생산품목 기준으로 합산하여 비교한다.
==============================================================================================*/
IF OBJECT_ID(N'dbo.CIV_PRD_TAV_D', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
    SELECT
         N''[G] ERP 당기재료비분석 대사''            AS REPORT_NM
        ,X.PROD_ITEM_CD                              AS 생산품번
        ,PI.ITEM_NM                                  AS 생산품명
        ,X.MTL_ITEM_CD                               AS 자재품번
        ,MI.ITEM_NM                                  AS 자재품명
        ,X.ACT_QT                                    AS 본쿼리_사용량
        ,V.USE_QT                                    AS ERP_사용량
        ,X.ACT_QT - ISNULL(V.USE_QT, 0)              AS 사용량_차이
        ,X.PUR_UM                                    AS 본쿼리_단가
        ,V.MTL_UM                                    AS ERP_자재단가
        ,X.PUR_UM - ISNULL(V.MTL_UM, 0)              AS 단가_차이
        ,X.ACT_QT * X.PUR_UM                         AS 본쿼리_재료비
        ,V.USE_AM                                    AS ERP_재료비
        ,(X.ACT_QT * X.PUR_UM) - ISNULL(V.USE_AM, 0) AS 재료비_차이
        ,V.REAL_QT                                   AS ERP_실제원단위
        ,판정 = CASE WHEN V.CITEM_CD IS NULL THEN N''ERP 미집계(프로젝트 외 or 차수 불일치)''
                     WHEN ABS((X.ACT_QT * X.PUR_UM) - ISNULL(V.USE_AM, 0)) < 1 THEN N''일치''
                     ELSE N''차이발생'' END
    FROM (
            SELECT CO_CD, PROD_ITEM_CD, MTL_ITEM_CD
                  ,ACT_QT = SUM(ACT_QT)
                  ,PUR_UM = MAX(PUR_UM)
            FROM   #COST
            GROUP BY CO_CD, PROD_ITEM_CD, MTL_ITEM_CD
         ) X
    LEFT JOIN dbo.CIV_PRD_TAV_D V WITH (NOLOCK)
           ON V.CO_CD = X.CO_CD AND V.P_YR = @p_YR AND V.CHASU = @p_CHASU
          AND V.PITEM_CD = X.PROD_ITEM_CD AND V.CITEM_CD = X.MTL_ITEM_CD
          AND (@p_DIV IS NULL OR V.DIV_CD = @p_DIV)
    LEFT JOIN SITEM PI WITH (NOLOCK) ON PI.CO_CD = X.CO_CD AND PI.ITEM_CD = X.PROD_ITEM_CD
    LEFT JOIN SITEM MI WITH (NOLOCK) ON MI.CO_CD = X.CO_CD AND MI.ITEM_CD = X.MTL_ITEM_CD
    ORDER BY ABS((X.ACT_QT * X.PUR_UM) - ISNULL(V.USE_AM, 0)) DESC';

    EXEC sp_executesql @SQL
        ,N'@p_DIV NVARCHAR(4), @p_YR NVARCHAR(4), @p_CHASU NUMERIC(3,0)'
        ,@p_DIV = @DIV_CD, @p_YR = @COST_YR, @p_CHASU = @COST_CHASU;
END
ELSE
    PRINT N'[INFO] CIV_PRD_TAV_D 없음 - ERP 대사(쿼리 G) 생략';


DROP TABLE #BOM_SRC, #PRD, #WO, #BOM_EXP, #MTL_STD, #MTL_REQ, #MTL_ISU,
           #MTL_ACT, #ACT_WO, #MTL_UM, #TAV_UM, #OUT_AM, #COST;
GO


/*==============================================================================================
  [ 부록 1 ] 도입 전 검증 쿼리
  ----------------------------------------------------------------------------------------------
  -- (1) 테이블 실체 확인
     SELECT name FROM sys.tables
     WHERE name IN ('SBOM','SBOM_WF','SBOM_WF_B','LWO_REQ_WF','LSTKMOVE','LSTKMOVE_D',
                    'LOCLS_H','LOCLS_D','LPRODUCTION','LPRODUCTION_D',
                    'CIV_PUR_TAV','CIV_TAV','CIV_CHASU','CIV_PRD_TAV','CIV_PRD_TAV_D')
     ORDER BY name;

  -- (2) LWO_REQ_WF 컬럼 확인 (청구 비교의 전제)
     SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS
     WHERE TABLE_NAME = 'LWO_REQ_WF' ORDER BY ORDINAL_POSITION;

  -- (3) LSTKMOVE 의 생산자재출고 구분(GRP_FG) 확인
     --   사이트에 따라 재고이동/사업장이동 등이 섞여 있을 수 있다.
     --   본 쿼리는 WO_CD 가 있는 이동만 집계하므로 대부분 문제없으나 반드시 확인할 것.
     SELECT H.GRP_FG, H.IO_FG, COUNT(*) CNT, SUM(D.MOVE_QT) QT
     FROM   LSTKMOVE H INNER JOIN LSTKMOVE_D D ON D.CO_CD=H.CO_CD AND D.MOVE_NB=H.MOVE_NB
     WHERE  H.CO_CD='1000' AND D.WO_CD IS NOT NULL AND D.WO_CD <> ''
     GROUP BY H.GRP_FG, H.IO_FG;

  -- (4) 사용자재보고 집계 여부 (0 건이면 @MTL_SRC_FG='MOVE' 로 잠정 집계 가능)
     SELECT '실적별' SRC, COUNT(*) FROM LMTL_USE   WHERE CO_CD='1000' AND USE_DT BETWEEN '20260101' AND '20261231'
     UNION ALL
     SELECT '지시별', COUNT(*) FROM LMTL_USEWO WHERE CO_CD='1000' AND USE_DT BETWEEN '20260101' AND '20261231';

  -- (5) 코드값 실제 분포
     SELECT USE_YN, EXPIRE_YN, BAD_YN, SUB_TP, REWORK_YN, DOC_FG, COUNT(*) CNT
     FROM   LORCV_H GROUP BY USE_YN, EXPIRE_YN, BAD_YN, SUB_TP, REWORK_YN, DOC_FG;

  -- (6) 원가차수 확인 (@UM_BASE_FG='TAV' 필수)
     SELECT CO_CD, DIV_CD, P_YR, CHASU, SMM, FMM, CLS_YN FROM CIV_CHASU
     WHERE CO_CD='1000' ORDER BY P_YR DESC, CHASU DESC;

  -- (7) BOM 순환참조 사전 점검
     WITH C AS (
         SELECT ITEMPARENT_CD, ITEMCHILD_CD,
                CAST('|'+ITEMPARENT_CD+'|'+ITEMCHILD_CD+'|' AS NVARCHAR(4000)) PATH, 1 LVL
         FROM   SBOM_WF WHERE CO_CD='1000' AND USE_YN='1'
         UNION ALL
         SELECT B.ITEMPARENT_CD, B.ITEMCHILD_CD, C.PATH+B.ITEMCHILD_CD+'|', C.LVL+1
         FROM   C JOIN SBOM_WF B ON B.ITEMPARENT_CD=C.ITEMCHILD_CD AND B.USE_YN='1'
         WHERE  C.LVL < 20 AND C.PATH NOT LIKE '%|'+B.ITEMCHILD_CD+'|%'
     )
     SELECT TOP 100 * FROM C WHERE LVL >= 15 ORDER BY LVL DESC OPTION (MAXRECURSION 0);


  [ 부록 2 ] BATCH BOM 운영 사이트
  ----------------------------------------------------------------------------------------------
  BATCH BOM = `SBOM_WF_B`, 배치수량 = `SITEM.FOQ_QT`  [(4)]
  해당 품목은 QTY_PER = REAL_QT / NULLIF(부모.FOQ_QT, 0)
  일반 BOM 의 REAL_QT 는 모품목 1단위 기준이므로 나누지 않는다.


  [ 부록 3 ] 일괄생산실적(간편생산실적) 사용 사이트
  ----------------------------------------------------------------------------------------------
  원가계산 SP(6) 5-2 의 세 번째 원천. LPRODUCTION 헤더 컬럼이 명세서에 없어 미포함이다.

      SELECT H.PITEM_CD, D.CITEM_CD, SUM( D.USE_QT ) USE_QT
        FROM LPRODUCTION_D D INNER JOIN LPRODUCTION H
               ON H.CO_CD = D.CO_CD AND H.DOC_CD = D.DOC_CD
       WHERE D.CO_CD = @CO_CD AND H.DIV_CD = @DIV_CD
         AND H.DOC_DT BETWEEN @FR_DT AND @TO_DT
         AND H.PITEM_CD <> D.CITEM_CD
       GROUP BY H.PITEM_CD, D.CITEM_CD

      SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='LPRODUCTION';


  [ 부록 4 ] 코드 명칭 조회 - UFN_FLAGS   [(9)(10) 에서 사용]
  ----------------------------------------------------------------------------------------------
  본 쿼리는 이식성을 위해 코드값을 CASE 로 직접 디코딩했으나,
  iCUBE 표준 방식은 UFN_FLAGS TVF 로 사이트/다국어 설정에 맞는 명칭을 가져오는 것이다.

      LEFT OUTER JOIN UFN_FLAGS( @LANGKIND, 'ACCT_FG', @CO_CD ) F ON F.FLAG_CD = I.ACCT_FG

  사용 가능한 FLAG 그룹 예 : 'ACCT_FG', 'ODR_FG', 'OUT_FG', 'USE_YN', 'CONSIGNMENT_YN'
  다중 파라미터(구분자 '|')는 UFN_MULTI_PARAMETERS( @CDS ) 를 사용한다.
      AND ( CHARINDEX('|', ISNULL(@ACCT_FGS,'')) = 0
            OR EXISTS( SELECT 1 FROM UFN_MULTI_PARAMETERS(@ACCT_FGS) WHERE STR_PARAMETER = I.ACCT_FG ) )


  [ 부록 5 ] ERP 표준 원가계산과의 차이 (의도된 차이)
  ----------------------------------------------------------------------------------------------
  항목            본 쿼리                            USP_COT0010_CALC_COST_TAV / COT0020
  --------------  ---------------------------------  ----------------------------------------
  집계 축         프로젝트 x 생산품목 x 자재         사업장 x 품목 (프로젝트 축 없음)
  기간            일자 범위 자유                     원가차수(CIV_CHASU.SMM~FMM)
  재료비 단가     선택('TAV'/'RCV'/'CLS')            CIV_PUR_TAV.ISU_UM 고정
  비교축          표준/청구/출고/사용 4단계          실적 원단위만 산출(비교 없음)
  가공비          미포함(외주가공비만 별도)          CIV_CONVCST/CIV_OE 배부 포함
  레벨전개        BOM 정전개                         생산실적 레벨전개

  => 재료비를 ERP 와 일치시키려면 @UM_BASE_FG='TAV' + 원가차수 마감 후 실행하고 쿼리 G 로 대사.
     가공비 포함 완전원가는 CIV_PRD_TAV 를 직접 조회하되, 프로젝트 배분은
     본 쿼리의 프로젝트별 재료비 비율을 배부기준으로 사용할 것.


  [ 부록 6 ] 남은 확인 사항
  ----------------------------------------------------------------------------------------------
  1) 청구/출고는 '실적이 발생한 지시'(#WO)에 한정 집계한다.
     미착수 지시의 선출고분까지 보려면 #WO 를 LWO_WF 전체로 확장할 것.
  2) BOM 기준일자는 @BOM_BASE_DT 단일 스냅샷(SYC0620 화면과 동일). 개정이 잦으면 월별 분할 실행.
  3) LSTKMOVE_D.MOVE_QT 는 반납(음수)도 합산된다. 반납을 분리하려면 GRP_FG/IO_FG 로 나눌 것.
  4) 매입단가('RCV'/'CLS')는 수입 부대비용(LSTOCK.EXCST_NB, LPURCLS_D.DIST_AM) 미반영.
  5) 성능 인덱스
     LORCV_H    (CO_CD, DOC_DT) INCLUDE (WO_CD, PJT_CD, ITEM_CD, DIV_CD)
     LMTL_USE   (CO_CD, WR_CD)
     LMTL_USEWO (CO_CD, WO_CD, USE_DT)
     LWO_REQ_WF (CO_CD, WO_CD, WOBOM_SQ)
     LSTKMOVE_D (CO_CD, WO_CD, ITEM_CD, WOBOM_SQ)
     SBOM_WF    (CO_CD, ITEMPARENT_CD, START_DT, END_DT)
     CIV_PUR_TAV(CO_CD, DIV_CD, P_YR, CHASU, ITEM_CD)

  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------

  -- (1) ★ 프로젝트 축이 어디에 있는지 확인한다. 지시에 없으면 수주에서 끌어와야 한다
     SELECT COUNT(*) 지시건수, SUM(CASE WHEN ISNULL(PJT_CD,'')<>'' THEN 1 ELSE 0 END) 프로젝트기재
     FROM   LWO_WF WHERE CO_CD='1000';

  -- (2) ★ 외주가공비 소스 확인. LOCLS 가 없으면 지시상 예정치로 대체된다
     SELECT OBJECT_ID('dbo.LOCLS_H') H, OBJECT_ID('dbo.LOCLS_D') D;
     --> NULL 이면 결과의 SRC_FG 가 '지시외주금액(LWO_WF_D)' 로 찍힌다. 확정치가 아니다.

  -- (3) 원가 차수 마감 여부 (C-07 선행)
     SELECT P_YR, CHASU, CLS_YN FROM CIV_CHASU WHERE CO_CD='1000' ORDER BY P_YR DESC, CHASU DESC;

  -- (4) BATCH BOM 품목의 FOQ_QT 등록 여부. 미등록이면 소요량이 과대 계산된다
     SELECT COUNT(*) FROM SITEM WHERE CO_CD='1000' AND ISNULL(FOQ_QT,0)=0
       AND  ITEM_CD IN (SELECT ITEM_CD FROM SBOM_WF_B WHERE CO_CD='1000');

  [ 한계 ]
  ----------------------------------------------------------------------------------------------

  1) **원가모듈에는 프로젝트 축이 없다.** 이 보고서는 물류·생산 데이터를 프로젝트로 재집계한
     것이며, 원가계산 SP 가 확정한 금액과 일치하지 않는다. 회계 관점(A-06)과도 다르다.
     세 관점 중 어느 하나가 정답이 아니라 **차이를 설명할 수 있어야** 한다.

  2) **외주가공비는 `LOCLS_H`/`LOCLS_D`(외주마감) 가 정본**이다. 이 테이블이 없는 사이트에서는
     `LWO_WF_D.LBR_AM`(지시상 예정치)으로 내려간다. 결과의 `SRC_FG` 컬럼으로 어느 쪽이
     쓰였는지 반드시 확인할 것. 예정치는 정산 근거가 되지 못한다.

  3) **간접비·판관비를 포함하지 않는다.** 재료비·외주비·가공비까지의 제조원가만 본다.

  4) **BATCH BOM 은 `SITEM.FOQ_QT` 로 나눈다.** FOQ_QT 가 비어 있으면 배치 소요량이 그대로
     단위 소요량으로 잡혀 재료비가 크게 부풀려진다. 도입 전 확인 (4) 를 반드시 돌릴 것.

==============================================================================================*/
