/*==============================================================================================
  [ iCUBE ] 원자재 수급 총괄현황 (MRP 기준)                                          (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 수주(주문) 오더를 기점으로 BOM 을 다단계 전개하여 주문제품의 원자재 필요량을 추적하고,
         iCUBE 소요량전개(LDEMAND)와 동일한 로직으로 수급 과부족을 산출한다.

           수주잔량 → BOM 정전개 → 총소요량(Gross)
                                  → 가용재고 차감 → 순소요량(Net) → 발주권고량 / 예정발주일
           원자재 ← BOM 역전개(Where-Used) ← 어느 수주/제품에 얼마나 필요한지 역추적(Pegging)

  DBMS : MS-SQL Server 2012 이상 (T-SQL)   ★ 2008 R2 불가 : 집계 SUM() OVER(ORDER BY …)

  ----------------------------------------------------------------------------------------------
  [ 근거 문서 ]
  ----------------------------------------------------------------------------------------------
   (1) 아이큐브테이블명세서.xls                          - 테이블/컬럼 구조
   (2) 아이큐브_API 연동규약서_20160108_V1.00_최종.docx  - 코드값 정의
   (3) USP_SYC0630_BY_SELECT_BOM (BOM역전개.sql)         - BOM = SBOM_WF, 역전개/재고조회 로직
   (4) **LDEMAND / LDEMAND_D / LDEMAND_STORY**           - iCUBE 소요량전개(MRP) 원본 구조
   (5) 중요)재고자산수불부(전체) 관련 테이블 모음        - **수불 GRP_FG/IO_FG/CLS_NB 코드맵**
   (6) 참조_icube 물류,생산 데이터 조회 쿼리 모음        - LINVTORY / VL_* 뷰 / 수불 집계 방식
   (7) 참조_지시별_자재현황(청구,출고,사용)_쿼리        - LWO_REQ_WF(자재청구) 조인 체계
   (8) 참조-재고입출고현황(상세)_평가기준                - LINV_MVFIFO 수불 구분 코드
   (9) neo-x_field_layout.xls                            - LRENT_D 등 명세서 누락분
  (12) 사용자정의보고서(UDR) 쿼리모음 167건            - **EXPIRE_YN / ACCT_FG / ODR_FG 코드 확정**

  ----------------------------------------------------------------------------------------------
  [ MRP 가용수량 산식 : LDEMAND_STORY 컬럼 구성 그대로 ]                              [(4)]
  ----------------------------------------------------------------------------------------------
     가용재고 =   INV_QT    현재고
                - SO_QT     주문출고예정량      (수주 미출고 잔량)
                - JUMUN_QT  주문(유통)출고예정량
                - RENT_QT   가출고예정량
                - REQ_QT    자재할당량          (작업지시 청구 미출고분)
                + PO_QT     구매입고예정량      (발주 미입고 잔량)
                + WO_QT     생산입고예정량      (작업지시 미완료분)
                + IWO_QT    외주입고예정량      (외주발주 미완료분)
                - SF_QT     안전재고량

     순소요량 = 총소요량 - 가용재고          ( < 0 이면 0 )
     발주권고량 = LOT 단위 절상 ( SITEM.LOT_QT )
     예정발주일 = 소요일자 - SITEM.LEAD_DT(조달일수)
     소요일자   = 수주 납기일 - 상위 레벨 누적 리드타임        <- MRP Lead-time offsetting

  ----------------------------------------------------------------------------------------------
  [ 사용 테이블 ]
  ----------------------------------------------------------------------------------------------
   수주          LSO / LSO_D       CO_CD + SO_NB (+SO_SQ)   SO_QT, ISU_QT, DUE_DT, EXPIRE_YN('1'=진행)
   BOM           SBOM_WF / SBOM    CO_CD + ITEMPARENT_CD + ITEMCHILD_CD
   품목          SITEM             LEAD_DT(조달일수) SAFESTOCK_QT LOT_QT FOQ_QT ODR_FG ACCT_FG
   재고          LINVTORY          CO_CD+DIV_CD+P_YR+ITEM_CD  IOPEN_QT/IRCV_QT/IISU_QT       [(6)]
   발주          LPO / LPO_D       PO_QT - RCV_QT = 미입고잔량, EXPIRE_YN('1'=진행)
   작업지시      LWO_WF            ITEM_QT - 실적 = 생산입고예정 (WOC_FG 로 생산/외주 구분)
   생산실적      LORCV_H           지시 소진량
   자재청구      LWO_REQ_WF        REQ_QT - RCV_QT = 자재할당(미출고)                        [(7)]
   가출고        LRENT / LRENT_D   RENT_QT                                                   [(9)]
   소요량전개    LDEMAND / LDEMAND_D / LDEMAND_STORY   ERP 대사용                            [(4)]
   코드명        SITEMGRP / STRADE / SDIV / SPJT

  ----------------------------------------------------------------------------------------------
  [ 주의 : EXPIRE_YN 은 '1'=유효/진행 - 한글명에 속지 말 것 ]                      [(1)(12)]
  ----------------------------------------------------------------------------------------------
     명세서 한글명은 "유효여부/마감여부"로 갈리지만, 실제 코드값은 **전 테이블 공통**이다.

          EXPIRE_YN = '1'  ->  유효 / 진행 / 미마감      <-- 정상 데이터 조건
          EXPIRE_YN = '0'  ->  만료 / 마감
          (API 연동규약서는 '2'=만료로 표기 - 어느 쪽이든 '1'=유효는 동일)

     근거 : 사용자정의보고서 코퍼스 8건 이상이 일관되게 사용
        LSO_D.EXPIRE_YN='1' THEN '진행' / ='0' THEN '마감'      (수주진행현황 외 5건)
        PD.EXPIRE_YN='1' THEN '발주진행' / ='0' THEN '발주마감'  (주문총괄생산진행현황)
        WF.EXPIRE_YN='1' THEN '생산진행' / ='0' THEN '생산마감'  (동일)
        DDL 기본값도 DEFAULT ('1')

     => 수주/발주 잔량 조회도 `= '1'` 이 정답. ( <> '1' 로 걸면 진행 건이 전부 빠진다 )
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD        NVARCHAR(4)   = N'1000'        -- 회사코드
    ,@DIV_CD       NVARCHAR(4)   = N'1000'        -- 사업장코드 (재고 집계상 필수 권장)
    ,@BASE_DT      NVARCHAR(8)   = N'20260915'    -- 기준일자 (현재고 기준일)

    -- 수주(소요 원천) 범위
    ,@DUE_FR_DT    NVARCHAR(8)   = N'20260901'    -- 납기일 FROM
    ,@DUE_TO_DT    NVARCHAR(8)   = N'20261231'    -- 납기일 TO
    ,@TR_CD        NVARCHAR(10)  = NULL           -- 거래처
    ,@SO_NB        NVARCHAR(12)  = NULL           -- 특정 수주번호
    ,@PROD_ITEM_CD NVARCHAR(30)  = NULL           -- 특정 주문제품
    ,@PJT_CD       NVARCHAR(10)  = NULL           -- 프로젝트

    -- 역전개(Where-Used) 대상
    ,@MTL_ITEM_CD  NVARCHAR(30)  = NULL           -- 특정 원자재 (쿼리 C/H 용. NULL = 전체)
    ,@ITEMGRP_CD   NVARCHAR(10)  = NULL           -- 원자재 품목군
    ,@ACCT_FG      NVARCHAR(1)   = NULL           -- 원자재 계정구분 (0.원재료 1.부재료 ...)

    -- BOM
    ,@BOM_BASE_DT  NVARCHAR(8)   = NULL           -- BOM 기준일자 (NULL = @BASE_DT)
    ,@BOM_MAX_LVL  INT           = 10             -- 최대 전개 레벨 (순환참조 방어)
    ,@LEAF_ONLY    NVARCHAR(1)   = N'Y'           -- Y = 최하위(구매/원자재)만 소요 집계
                                                  -- N = 전 레벨 (반제품 포함)

    -- MRP 옵션 (LDEMAND 헤더 옵션과 1:1 대응)
    ,@OPT_INV      NVARCHAR(1)   = N'1'           -- 현재고 반영
    ,@OPT_SO       NVARCHAR(1)   = N'1'           -- 주문출고예정량 차감
    ,@OPT_RENT     NVARCHAR(1)   = N'1'           -- 가출고예정량 차감
    ,@OPT_REQ      NVARCHAR(1)   = N'1'           -- 자재할당량(작지청구) 차감
    ,@OPT_PO       NVARCHAR(1)   = N'1'           -- 구매입고예정량 가산
    ,@OPT_WO       NVARCHAR(1)   = N'1'           -- 생산입고예정량 가산
    ,@OPT_IWO      NVARCHAR(1)   = N'1'           -- 외주입고예정량 가산
    ,@OPT_SAFE     NVARCHAR(1)   = N'1'           -- 안전재고량 차감
    ,@OPT_LOT      NVARCHAR(1)   = N'1'           -- 최소발주량(LOT_QT) 절상 적용

    ,@BUCKET_FG    NVARCHAR(1)   = N'W'           -- 쿼리 D 버킷 : 'W'=주별 / 'M'=월별

    -- ERP 소요량전개 대사 (쿼리 G)
    ,@DEMAND_EXP_DT NVARCHAR(8)  = NULL           -- 비교할 LDEMAND 전개일 (NULL = 최근)
;

SET @BOM_BASE_DT = ISNULL(@BOM_BASE_DT, @BASE_DT);


IF OBJECT_ID('tempdb..#SO')      IS NOT NULL DROP TABLE #SO;
IF OBJECT_ID('tempdb..#BOM_SRC') IS NOT NULL DROP TABLE #BOM_SRC;
IF OBJECT_ID('tempdb..#BOM_EXP') IS NOT NULL DROP TABLE #BOM_EXP;
IF OBJECT_ID('tempdb..#PEG')     IS NOT NULL DROP TABLE #PEG;
IF OBJECT_ID('tempdb..#SUP')     IS NOT NULL DROP TABLE #SUP;
IF OBJECT_ID('tempdb..#MRP')     IS NOT NULL DROP TABLE #MRP;

DECLARE @SQL NVARCHAR(MAX);


/*==============================================================================================
  1. #SO : 수주 잔량 (소요 원천)
     수주잔량 = SO_QT(수주수량) - ISU_QT(출고적용수량), 진행분(EXPIRE_YN='1')만
==============================================================================================*/
SELECT
     H.CO_CD
    ,DIV_CD       = H.DIV_CD
    ,SO_NB        = D.SO_NB
    ,SO_SQ        = D.SO_SQ
    ,SO_DT        = H.SO_DT
    ,DUE_DT       = D.DUE_DT
    ,TR_CD        = H.TR_CD
    ,PJT_CD       = ISNULL(NULLIF(D.PJT_CD, N''), H.PJT_CD)
    ,PROD_ITEM_CD = D.ITEM_CD
    ,SO_QT        = CAST(ISNULL(D.SO_QT , 0) AS DECIMAL(19,6))
    ,ISU_QT       = CAST(ISNULL(D.ISU_QT, 0) AS DECIMAL(19,6))
    ,OPEN_QT      = CAST(ISNULL(D.SO_QT, 0) - ISNULL(D.ISU_QT, 0) AS DECIMAL(19,6))  -- 수주잔량
INTO #SO
FROM        LSO   H WITH (NOLOCK)
INNER JOIN  LSO_D D WITH (NOLOCK)
       ON   D.CO_CD = H.CO_CD AND D.SO_NB = H.SO_NB
WHERE   H.CO_CD = @CO_CD
  AND   D.DUE_DT BETWEEN @DUE_FR_DT AND @DUE_TO_DT
  AND   ISNULL(D.USE_YN   , N'1') = N'1'
  AND   ISNULL(D.EXPIRE_YN, N'1') = N'1'                       -- 1.진행(미마감)  * UDR 코퍼스 8건 교차확인
  AND   ISNULL(D.SO_QT, 0) - ISNULL(D.ISU_QT, 0) > 0            -- 잔량 있는 건만
  AND   (@DIV_CD       IS NULL OR H.DIV_CD  = @DIV_CD)
  AND   (@TR_CD        IS NULL OR H.TR_CD   = @TR_CD)
  AND   (@SO_NB        IS NULL OR D.SO_NB   = @SO_NB)
  AND   (@PROD_ITEM_CD IS NULL OR D.ITEM_CD = @PROD_ITEM_CD)
  AND   (@PJT_CD       IS NULL OR ISNULL(NULLIF(D.PJT_CD, N''), H.PJT_CD) = @PJT_CD)
;
CREATE CLUSTERED INDEX IX_SO ON #SO (CO_CD, SO_NB, SO_SQ);

PRINT N'[INFO] 대상 수주 : ' + CAST((SELECT COUNT(*) FROM #SO) AS NVARCHAR(20)) + N' 건 / 잔량 '
    + CAST((SELECT ISNULL(SUM(OPEN_QT),0) FROM #SO) AS NVARCHAR(40));


/*==============================================================================================
  2. #BOM_SRC : BOM 원천 (기준일자 유효분)   [SBOM_WF 확정 (3)]
==============================================================================================*/
CREATE TABLE #BOM_SRC (
     CO_CD NVARCHAR(4), ITEMPARENT_CD NVARCHAR(30), ITEMCHILD_CD NVARCHAR(30)
    ,JUST_QT DECIMAL(19,6), LOSS_RT DECIMAL(19,6), REAL_QT DECIMAL(19,6)
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
    INSERT INTO #BOM_SRC (CO_CD, ITEMPARENT_CD, ITEMCHILD_CD, JUST_QT, LOSS_RT, REAL_QT)
    SELECT  B.CO_CD, B.ITEMPARENT_CD, B.ITEMCHILD_CD
           ,CAST(ISNULL(B.JUST_QT, 0) AS DECIMAL(19,6))
           ,CAST(ISNULL(B.LOSS_RT, 0) AS DECIMAL(19,6))
           ,CAST(ISNULL(B.REAL_QT, 0) AS DECIMAL(19,6))
    FROM    dbo.' + QUOTENAME(@BOM_TB) + N' B WITH (NOLOCK)
    WHERE   B.CO_CD  = @p_CO_CD
      AND   B.USE_YN = N''1''
      AND   B.ITEMPARENT_CD <> B.ITEMCHILD_CD
      AND   @p_BASE_DT >= B.START_DT
      AND   @p_BASE_DT <= ISNULL(NULLIF(B.END_DT, N''''), N''99991231'')';

EXEC sp_executesql @SQL, N'@p_CO_CD NVARCHAR(4), @p_BASE_DT NVARCHAR(8)'
    ,@p_CO_CD = @CO_CD, @p_BASE_DT = @BOM_BASE_DT;

CREATE CLUSTERED INDEX IX_BOM_SRC ON #BOM_SRC (CO_CD, ITEMPARENT_CD);
CREATE NONCLUSTERED INDEX IX_BOM_SRC2 ON #BOM_SRC (CO_CD, ITEMCHILD_CD);

PRINT N'[INFO] BOM 원천 = ' + @BOM_TB + N' / 기준일 = ' + @BOM_BASE_DT
    + N' / ' + CAST((SELECT COUNT(*) FROM #BOM_SRC) AS NVARCHAR(20)) + N' 건';


/*==============================================================================================
  3. #BOM_EXP : BOM 다단계 정전개 (주문제품 기준)
     - QTY_PER  : 제품 1단위당 누적 소요량 (레벨별 REAL_QT 곱, LOSS 누적 반영)
     - CUM_LEAD : 상위 레벨 누적 조달일수 (MRP Lead-time offsetting 용)
     - 순환참조는 NODE_PATH 로 차단                                          [(3) 무한루프체크]
==============================================================================================*/
;WITH ROOTS AS
(
    SELECT DISTINCT CO_CD, PROD_ITEM_CD FROM #SO
)
,EXP AS
(
    -- 1레벨 : 제품 자신의 리드타임이 상위 누적 리드타임이 된다
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
        ,CUM_LEAD     = CAST(ISNULL(PI.LEAD_DT, 0) AS INT)
        ,NODE_PATH    = CAST(N'|' + B.ITEMPARENT_CD + N'|' + B.ITEMCHILD_CD + N'|' AS NVARCHAR(4000))
    FROM        ROOTS    R
    INNER JOIN  #BOM_SRC B  ON B.CO_CD = R.CO_CD AND B.ITEMPARENT_CD = R.PROD_ITEM_CD
    LEFT  JOIN  SITEM    PI WITH (NOLOCK) ON PI.CO_CD = R.CO_CD AND PI.ITEM_CD = R.PROD_ITEM_CD

    UNION ALL

    -- N레벨 : 부모(=직전 CHILD)의 리드타임을 누적
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
        ,CUM_LEAD     = E.CUM_LEAD + CAST(ISNULL(MI.LEAD_DT, 0) AS INT)
        ,NODE_PATH    = CAST(E.NODE_PATH + B.ITEMCHILD_CD + N'|' AS NVARCHAR(4000))
    FROM        EXP      E
    INNER JOIN  #BOM_SRC B  ON B.CO_CD = E.CO_CD AND B.ITEMPARENT_CD = E.CHILD_CD
    LEFT  JOIN  SITEM    MI WITH (NOLOCK) ON MI.CO_CD = E.CO_CD AND MI.ITEM_CD = E.CHILD_CD
    WHERE   E.LVL < @BOM_MAX_LVL
      AND   E.NODE_PATH NOT LIKE N'%|' + B.ITEMCHILD_CD + N'|%'
)
SELECT
     CO_CD, ROOT_ITEM_CD, LVL, PARENT_CD, CHILD_CD
    ,QTY_PER, JUST_QT, LOSS_RT, REAL_QT, CUM_LEAD, NODE_PATH
    ,LEAF_YN = CASE WHEN NOT EXISTS (SELECT 1 FROM #BOM_SRC C
                                     WHERE C.CO_CD = EXP.CO_CD AND C.ITEMPARENT_CD = EXP.CHILD_CD)
                    THEN N'Y' ELSE N'N' END
INTO #BOM_EXP
FROM EXP
OPTION (MAXRECURSION 0);
CREATE CLUSTERED INDEX IX_BOM_EXP ON #BOM_EXP (CO_CD, ROOT_ITEM_CD, CHILD_CD);


/*==============================================================================================
  4. #PEG : 수주 x 원자재 소요 (Pegging)
     총소요량 = 수주잔량 x 누적소요량
     소요일자 = 납기일 - 상위 누적 리드타임
==============================================================================================*/
SELECT
     S.CO_CD
    ,S.DIV_CD
    ,S.SO_NB
    ,S.SO_SQ
    ,S.SO_DT
    ,S.DUE_DT
    ,S.TR_CD
    ,S.PJT_CD
    ,S.PROD_ITEM_CD
    ,S.OPEN_QT                                                  -- 수주잔량
    ,MTL_ITEM_CD = E.CHILD_CD
    ,BOM_LVL     = E.LVL
    ,QTY_PER     = E.QTY_PER
    ,CUM_LEAD    = E.CUM_LEAD
    ,LEAF_YN     = E.LEAF_YN
    ,GROSS_QT    = CAST(S.OPEN_QT * E.QTY_PER AS DECIMAL(19,6))  -- 총소요량
    ,SCHD_DT     = CONVERT(NVARCHAR(8), DATEADD(DAY, -E.CUM_LEAD, CONVERT(DATE, S.DUE_DT)), 112)  -- 소요일자
    ,NODE_PATH   = E.NODE_PATH
INTO #PEG
FROM        #SO      S
INNER JOIN  #BOM_EXP E
       ON   E.CO_CD = S.CO_CD AND E.ROOT_ITEM_CD = S.PROD_ITEM_CD
WHERE   (@LEAF_ONLY = N'N' OR E.LEAF_YN = N'Y')
;
CREATE CLUSTERED INDEX IX_PEG ON #PEG (CO_CD, MTL_ITEM_CD, SCHD_DT);

-- 원자재 필터 (품목군 / 계정구분 / 특정품목)
IF @MTL_ITEM_CD IS NOT NULL OR @ITEMGRP_CD IS NOT NULL OR @ACCT_FG IS NOT NULL
    DELETE P
    FROM        #PEG P
    LEFT  JOIN  SITEM I WITH (NOLOCK) ON I.CO_CD = P.CO_CD AND I.ITEM_CD = P.MTL_ITEM_CD
    WHERE  (@MTL_ITEM_CD IS NOT NULL AND P.MTL_ITEM_CD <> @MTL_ITEM_CD)
        OR (@ITEMGRP_CD  IS NOT NULL AND ISNULL(I.ITEMGRP_CD, N'') <> @ITEMGRP_CD)
        OR (@ACCT_FG     IS NOT NULL AND ISNULL(I.ACCT_FG   , N'') <> @ACCT_FG);

PRINT N'[INFO] Pegging 라인 : ' + CAST((SELECT COUNT(*) FROM #PEG) AS NVARCHAR(20));


/*==============================================================================================
  5. #SUP : 품목별 수급 요소 (LDEMAND_STORY 구성과 동일)                          [(4)]
     존재하지 않는 테이블은 0 으로 처리하고 경고를 출력한다.
==============================================================================================*/
CREATE TABLE #SUP (
     CO_CD     NVARCHAR(4)
    ,ITEM_CD   NVARCHAR(30)
    ,INV_QT    DECIMAL(19,6) DEFAULT 0   -- 현재고
    ,SO_QT     DECIMAL(19,6) DEFAULT 0   -- 주문출고예정
    ,RENT_QT   DECIMAL(19,6) DEFAULT 0   -- 가출고예정
    ,REQ_QT    DECIMAL(19,6) DEFAULT 0   -- 자재할당(작지청구 미출고)
    ,PO_QT     DECIMAL(19,6) DEFAULT 0   -- 구매입고예정
    ,WO_QT     DECIMAL(19,6) DEFAULT 0   -- 생산입고예정
    ,IWO_QT    DECIMAL(19,6) DEFAULT 0   -- 외주입고예정
    ,SF_QT     DECIMAL(19,6) DEFAULT 0   -- 안전재고
);

-- 대상 품목 골격 (소요가 걸린 원자재 + 주문제품)
INSERT INTO #SUP (CO_CD, ITEM_CD)
SELECT DISTINCT CO_CD, MTL_ITEM_CD FROM #PEG
UNION
SELECT DISTINCT CO_CD, PROD_ITEM_CD FROM #SO;

CREATE CLUSTERED INDEX IX_SUP ON #SUP (CO_CD, ITEM_CD);


-- (1) 현재고 : LINVTORY 수불 집계                                                 [(5)(6)]
--     현재고 = SUM(기초 IOPEN_QT) + SUM(입고 IRCV_QT) - SUM(출고 IISU_QT)  (해당년도, 기준일 이하)
IF @OPT_INV = N'1' AND OBJECT_ID(N'dbo.LINVTORY', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
        UPDATE S SET INV_QT = X.QT
        FROM   #SUP S
        INNER JOIN (
            SELECT  V.CO_CD, V.ITEM_CD
                   ,QT = SUM(ISNULL(V.IOPEN_QT,0) + ISNULL(V.IRCV_QT,0) - ISNULL(V.IISU_QT,0))
            FROM    dbo.LINVTORY V WITH (NOLOCK)
            WHERE   V.CO_CD  = @p_CO_CD
              AND   V.P_YR   = LEFT(@p_BASE_DT, 4)
              AND   V.IO_DT <= @p_BASE_DT
              AND   (@p_DIV IS NULL OR V.DIV_CD = @p_DIV)
            GROUP BY V.CO_CD, V.ITEM_CD
        ) X ON X.CO_CD = S.CO_CD AND X.ITEM_CD = S.ITEM_CD';

    EXEC sp_executesql @SQL
        ,N'@p_CO_CD NVARCHAR(4), @p_DIV NVARCHAR(4), @p_BASE_DT NVARCHAR(8)'
        ,@p_CO_CD = @CO_CD, @p_DIV = @DIV_CD, @p_BASE_DT = @BASE_DT;
END
ELSE IF @OPT_INV = N'1'
    PRINT N'[WARN] LINVTORY 없음 - 현재고 0 으로 처리됩니다.';


-- (2) 주문출고예정량 : 수주 미출고 잔량 (대상 기간 밖 수주까지 전체)
IF @OPT_SO = N'1'
    UPDATE S SET SO_QT = X.QT
    FROM   #SUP S
    INNER JOIN (
        SELECT  D.CO_CD, D.ITEM_CD
               ,QT = SUM(CAST(ISNULL(D.SO_QT,0) - ISNULL(D.ISU_QT,0) AS DECIMAL(19,6)))
        FROM    LSO   H WITH (NOLOCK)
        INNER JOIN LSO_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.SO_NB = H.SO_NB
        WHERE   H.CO_CD = @CO_CD
          AND   ISNULL(D.USE_YN, N'1') = N'1'
          AND   ISNULL(D.EXPIRE_YN, N'1') = N'1'
          AND   ISNULL(D.SO_QT,0) - ISNULL(D.ISU_QT,0) > 0
          AND   (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
        GROUP BY D.CO_CD, D.ITEM_CD
    ) X ON X.CO_CD = S.CO_CD AND X.ITEM_CD = S.ITEM_CD;


-- (3) 가출고예정량 : LRENT / LRENT_D
IF @OPT_RENT = N'1' AND OBJECT_ID(N'dbo.LRENT', N'U') IS NOT NULL
                   AND OBJECT_ID(N'dbo.LRENT_D', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
        UPDATE S SET RENT_QT = X.QT
        FROM   #SUP S
        INNER JOIN (
            SELECT  D.CO_CD, D.ITEM_CD, QT = SUM(CAST(ISNULL(D.RENT_QT,0) AS DECIMAL(19,6)))
            FROM    dbo.LRENT   H WITH (NOLOCK)
            INNER JOIN dbo.LRENT_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.RENT_NB = H.RENT_NB
            WHERE   H.CO_CD = @p_CO_CD
              AND   (@p_DIV IS NULL OR H.DIV_CD = @p_DIV)
            GROUP BY D.CO_CD, D.ITEM_CD
        ) X ON X.CO_CD = S.CO_CD AND X.ITEM_CD = S.ITEM_CD';

    EXEC sp_executesql @SQL, N'@p_CO_CD NVARCHAR(4), @p_DIV NVARCHAR(4)'
        ,@p_CO_CD = @CO_CD, @p_DIV = @DIV_CD;
END


-- (4) 자재할당량 : 작업지시 자재청구 미출고분 (LWO_REQ_WF)                        [(7)]
IF @OPT_REQ = N'1' AND OBJECT_ID(N'dbo.LWO_REQ_WF', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
        UPDATE S SET REQ_QT = X.QT
        FROM   #SUP S
        INNER JOIN (
            SELECT  F.CO_CD, F.ITEM_CD
                   ,QT = SUM(CASE WHEN ISNULL(F.REQ_QT,0) - ISNULL(F.RCV_QT,0) > 0
                                  THEN CAST(ISNULL(F.REQ_QT,0) - ISNULL(F.RCV_QT,0) AS DECIMAL(19,6))
                                  ELSE 0 END)
            FROM    dbo.LWO_REQ_WF F WITH (NOLOCK)
            WHERE   F.CO_CD = @p_CO_CD
              AND   (@p_DIV IS NULL OR F.DIV_CD = @p_DIV)
            GROUP BY F.CO_CD, F.ITEM_CD
        ) X ON X.CO_CD = S.CO_CD AND X.ITEM_CD = S.ITEM_CD';

    EXEC sp_executesql @SQL, N'@p_CO_CD NVARCHAR(4), @p_DIV NVARCHAR(4)'
        ,@p_CO_CD = @CO_CD, @p_DIV = @DIV_CD;
END
ELSE IF @OPT_REQ = N'1'
    PRINT N'[WARN] LWO_REQ_WF 없음 - 자재할당량 0 으로 처리됩니다.';


-- (5) 구매입고예정량 : 발주 미입고 잔량 (LPO / LPO_D)
--     LPO(발주 헤더)는 테이블명세서에 없고 API GetLPO 로 확인되므로 존재 여부를 확인 후 사용한다.
IF @OPT_PO = N'1' AND OBJECT_ID(N'dbo.LPO_D', N'U') IS NOT NULL
BEGIN
    IF OBJECT_ID(N'dbo.LPO', N'U') IS NOT NULL
        SET @SQL = N'
            UPDATE S SET PO_QT = X.QT
            FROM   #SUP S
            INNER JOIN (
                SELECT  D.CO_CD, D.ITEM_CD
                       ,QT = SUM(CAST(ISNULL(D.PO_QT,0) - ISNULL(D.RCV_QT,0) AS DECIMAL(19,6)))
                FROM    dbo.LPO   H WITH (NOLOCK)
                INNER JOIN dbo.LPO_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.PO_NB = H.PO_NB
                WHERE   H.CO_CD = @p_CO_CD
                  AND   ISNULL(D.USE_YN, N''1'') = N''1''
                  AND   ISNULL(D.EXPIRE_YN, N''1'') = N''1''
                  AND   ISNULL(D.PO_QT,0) - ISNULL(D.RCV_QT,0) > 0
                  AND   (@p_DIV IS NULL OR H.DIV_CD = @p_DIV)
                GROUP BY D.CO_CD, D.ITEM_CD
            ) X ON X.CO_CD = S.CO_CD AND X.ITEM_CD = S.ITEM_CD';
    ELSE
        SET @SQL = N'
            UPDATE S SET PO_QT = X.QT
            FROM   #SUP S
            INNER JOIN (
                SELECT  D.CO_CD, D.ITEM_CD
                       ,QT = SUM(CAST(ISNULL(D.PO_QT,0) - ISNULL(D.RCV_QT,0) AS DECIMAL(19,6)))
                FROM    dbo.LPO_D D WITH (NOLOCK)
                WHERE   D.CO_CD = @p_CO_CD
                  AND   ISNULL(D.USE_YN, N''1'') = N''1''
                  AND   ISNULL(D.EXPIRE_YN, N''1'') = N''1''
                  AND   ISNULL(D.PO_QT,0) - ISNULL(D.RCV_QT,0) > 0
                GROUP BY D.CO_CD, D.ITEM_CD
            ) X ON X.CO_CD = S.CO_CD AND X.ITEM_CD = S.ITEM_CD';

    EXEC sp_executesql @SQL, N'@p_CO_CD NVARCHAR(4), @p_DIV NVARCHAR(4)'
        ,@p_CO_CD = @CO_CD, @p_DIV = @DIV_CD;
END
ELSE IF @OPT_PO = N'1'
    PRINT N'[WARN] LPO_D 없음 - 구매입고예정량 0 으로 처리됩니다.';


-- (6)(7) 생산/외주 입고예정량 : 작업지시 미완료 잔량
--        WOC_FG 0.생산지시 2.임가공 5.작업지시 => 생산  /  4.외주발주 => 외주      [(2)]
;WITH WO AS
(
    SELECT
         W.CO_CD, W.ITEM_CD
        ,WOC_FG   = ISNULL(W.WOC_FG, N'0')
        ,OPEN_QT  = CAST(ISNULL(W.ITEM_QT,0) AS DECIMAL(19,6))
                  - CAST(ISNULL(R.PRD_QT ,0) AS DECIMAL(19,6))
    FROM        LWO_WF W WITH (NOLOCK)
    OUTER APPLY (
        SELECT PRD_QT = SUM(H.ITEM_QT)
        FROM   LORCV_H H WITH (NOLOCK)
        WHERE  H.CO_CD = W.CO_CD AND H.WO_CD = W.WO_CD
          AND  H.USE_YN = N'1' AND H.EXPIRE_YN = N'1'
          AND  ISNULL(H.SUB_TP, N'0') = N'0'
          AND  ISNULL(H.BAD_YN, N'0') = N'0'
    ) R
    WHERE   W.CO_CD  = @CO_CD
      AND   W.USE_YN = N'1'
      AND   ISNULL(W.DOC_ST, N'0') <> N'1'                      -- 미처리(미완료) 지시
      AND   (@DIV_CD IS NULL OR W.DIV_CD = @DIV_CD)
      AND   ISNULL(W.ITEM_QT,0) - ISNULL(R.PRD_QT,0) > 0
)
UPDATE S
   SET WO_QT  = ISNULL(X.WO_QT , 0)
      ,IWO_QT = ISNULL(X.IWO_QT, 0)
FROM   #SUP S
INNER JOIN (
    SELECT CO_CD, ITEM_CD
          ,WO_QT  = SUM(CASE WHEN WOC_FG <> N'4' THEN OPEN_QT ELSE 0 END)
          ,IWO_QT = SUM(CASE WHEN WOC_FG  = N'4' THEN OPEN_QT ELSE 0 END)
    FROM   WO GROUP BY CO_CD, ITEM_CD
) X ON X.CO_CD = S.CO_CD AND X.ITEM_CD = S.ITEM_CD;

-- 옵션 미적용 시 0 처리
IF @OPT_WO  <> N'1' UPDATE #SUP SET WO_QT  = 0;
IF @OPT_IWO <> N'1' UPDATE #SUP SET IWO_QT = 0;


-- (8) 안전재고량
IF @OPT_SAFE = N'1'
    UPDATE S SET SF_QT = CAST(ISNULL(I.SAFESTOCK_QT, 0) AS DECIMAL(19,6))
    FROM   #SUP S
    INNER JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = S.CO_CD AND I.ITEM_CD = S.ITEM_CD;


/*==============================================================================================
  6. #MRP : 품목별 총소요 -> 가용재고 -> 순소요 -> 발주권고
==============================================================================================*/
;WITH G AS
(
    SELECT
         CO_CD
        ,MTL_ITEM_CD
        ,GROSS_QT   = SUM(GROSS_QT)
        ,SO_CNT     = COUNT(DISTINCT SO_NB + CAST(SO_SQ AS NVARCHAR(10)))
        ,PROD_CNT   = COUNT(DISTINCT PROD_ITEM_CD)
        ,FIRST_SCHD = MIN(SCHD_DT)
        ,LAST_SCHD  = MAX(SCHD_DT)
        ,MIN_LVL    = MIN(BOM_LVL)
        ,MAX_LVL    = MAX(BOM_LVL)
    FROM   #PEG
    GROUP BY CO_CD, MTL_ITEM_CD
)
SELECT
     G.CO_CD
    ,ITEM_CD    = G.MTL_ITEM_CD
    ,G.GROSS_QT
    ,G.SO_CNT
    ,G.PROD_CNT
    ,G.FIRST_SCHD
    ,G.LAST_SCHD
    ,G.MIN_LVL
    ,G.MAX_LVL

    ,INV_QT     = ISNULL(S.INV_QT , 0)
    ,SO_QT      = ISNULL(S.SO_QT  , 0)
    ,RENT_QT    = ISNULL(S.RENT_QT, 0)
    ,REQ_QT     = ISNULL(S.REQ_QT , 0)
    ,PO_QT      = ISNULL(S.PO_QT  , 0)
    ,WO_QT      = ISNULL(S.WO_QT  , 0)
    ,IWO_QT     = ISNULL(S.IWO_QT , 0)
    ,SF_QT      = ISNULL(S.SF_QT  , 0)

    -- 가용재고 (LDEMAND_STORY 산식)
    ,AVAIL_QT   = CAST( ISNULL(S.INV_QT,0)
                      - ISNULL(S.SO_QT,0)  - ISNULL(S.RENT_QT,0) - ISNULL(S.REQ_QT,0)
                      + ISNULL(S.PO_QT,0)  + ISNULL(S.WO_QT,0)   + ISNULL(S.IWO_QT,0)
                      - ISNULL(S.SF_QT,0) AS DECIMAL(19,6))

    -- 순소요량
    ,NET_QT     = CAST( CASE WHEN G.GROSS_QT
                                - ( ISNULL(S.INV_QT,0)
                                  - ISNULL(S.SO_QT,0)  - ISNULL(S.RENT_QT,0) - ISNULL(S.REQ_QT,0)
                                  + ISNULL(S.PO_QT,0)  + ISNULL(S.WO_QT,0)   + ISNULL(S.IWO_QT,0)
                                  - ISNULL(S.SF_QT,0) ) > 0
                             THEN G.GROSS_QT
                                - ( ISNULL(S.INV_QT,0)
                                  - ISNULL(S.SO_QT,0)  - ISNULL(S.RENT_QT,0) - ISNULL(S.REQ_QT,0)
                                  + ISNULL(S.PO_QT,0)  + ISNULL(S.WO_QT,0)   + ISNULL(S.IWO_QT,0)
                                  - ISNULL(S.SF_QT,0) )
                             ELSE 0 END AS DECIMAL(19,6))

    ,LEAD_DT    = CAST(ISNULL(I.LEAD_DT , 0) AS INT)
    ,LOT_QT     = CAST(ISNULL(I.LOT_QT  , 0) AS DECIMAL(19,6))
    ,ODR_FG     = I.ODR_FG
    ,ACCT_FG    = I.ACCT_FG
    ,TRMAIN_CD  = I.TRMAIN_CD
INTO #MRP
FROM        G
LEFT  JOIN  #SUP  S ON S.CO_CD = G.CO_CD AND S.ITEM_CD = G.MTL_ITEM_CD
LEFT  JOIN  SITEM I WITH (NOLOCK) ON I.CO_CD = G.CO_CD AND I.ITEM_CD = G.MTL_ITEM_CD
;
CREATE CLUSTERED INDEX IX_MRP ON #MRP (CO_CD, ITEM_CD);


/*==============================================================================================
  ** 쿼리 A : 원자재 수급 총괄현황  (메인 / 1행 = 1원자재)
==============================================================================================*/
SELECT
     N'[A] 원자재 수급 총괄현황'                    AS REPORT_NM
    ,M.ITEM_CD                                      AS 원자재품번
    ,I.ITEM_NM                                      AS 품명
    ,I.ITEM_DC                                      AS 규격
    ,I.UNIT_DC                                      AS 단위
    ,G.ITEMGRP_NM                                   AS 품목군
    ,M.ACCT_FG                                      AS 계정구분
    ,M.ODR_FG                                       AS 조달구분
    ,TR.TR_NM                                       AS 주거래처

    -- 소요
    ,M.GROSS_QT                                     AS 총소요량
    ,M.SO_CNT                                       AS 관련수주건수
    ,M.PROD_CNT                                     AS 관련제품수
    ,M.FIRST_SCHD                                   AS 최초소요일
    ,M.LAST_SCHD                                    AS 최종소요일

    -- 수급 구성 (LDEMAND_STORY 와 동일 항목)
    ,M.INV_QT                                       AS 현재고
    ,M.SO_QT                                        AS 주문출고예정
    ,M.RENT_QT                                      AS 가출고예정
    ,M.REQ_QT                                       AS 자재할당량
    ,M.PO_QT                                        AS 구매입고예정
    ,M.WO_QT                                        AS 생산입고예정
    ,M.IWO_QT                                       AS 외주입고예정
    ,M.SF_QT                                        AS 안전재고
    ,M.AVAIL_QT                                     AS 가용재고

    -- 판정
    ,M.NET_QT                                       AS 순소요량
    ,부족여부 = CASE WHEN M.NET_QT > 0 THEN N'부족' ELSE N'충족' END
    ,M.LEAD_DT                                      AS 조달일수
    ,M.LOT_QT                                       AS 최소발주량

    -- 발주권고 : LOT 단위 절상
    ,발주권고량 = CAST( CASE
          WHEN M.NET_QT <= 0 THEN 0
          WHEN @OPT_LOT = N'1' AND M.LOT_QT > 0
               THEN CEILING(M.NET_QT / M.LOT_QT) * M.LOT_QT
          ELSE M.NET_QT END AS DECIMAL(19,6))

    -- 예정발주일 = 최초 소요일 - 조달일수
    ,예정발주일 = CONVERT(NVARCHAR(8),
                         DATEADD(DAY, -M.LEAD_DT, CONVERT(DATE, M.FIRST_SCHD)), 112)
    ,발주지연일수 = CASE WHEN M.NET_QT > 0
                         THEN DATEDIFF(DAY,
                                DATEADD(DAY, -M.LEAD_DT, CONVERT(DATE, M.FIRST_SCHD)),
                                CONVERT(DATE, @BASE_DT))
                    END
    ,긴급도 = CASE WHEN M.NET_QT <= 0 THEN N'-'
                   WHEN DATEADD(DAY, -M.LEAD_DT, CONVERT(DATE, M.FIRST_SCHD)) < CONVERT(DATE, @BASE_DT)
                        THEN N'1.발주시점 경과(긴급)'
                   WHEN DATEADD(DAY, -M.LEAD_DT, CONVERT(DATE, M.FIRST_SCHD))
                        <= DATEADD(DAY, 7, CONVERT(DATE, @BASE_DT)) THEN N'2.7일 이내 발주'
                   ELSE N'3.여유' END
FROM        #MRP M
LEFT  JOIN  SITEM    I  WITH (NOLOCK) ON I.CO_CD  = M.CO_CD AND I.ITEM_CD = M.ITEM_CD
LEFT  JOIN  SITEMGRP G  WITH (NOLOCK) ON G.CO_CD  = I.CO_CD AND G.ITEMGRP_CD = I.ITEMGRP_CD
LEFT  JOIN  STRADE   TR WITH (NOLOCK) ON TR.CO_CD = I.CO_CD AND TR.TR_CD = I.TRMAIN_CD
ORDER BY CASE WHEN M.NET_QT > 0 THEN 0 ELSE 1 END, M.FIRST_SCHD, M.ITEM_CD
;


/*==============================================================================================
  ** 쿼리 B : 수주오더별 원자재 소요 (BOM 정전개 / Pegging)
==============================================================================================*/
SELECT
     N'[B] 수주오더별 원자재 소요'                  AS REPORT_NM
    ,P.SO_NB                                        AS 수주번호
    ,P.SO_SQ                                        AS 수주순번
    ,P.SO_DT                                        AS 수주일
    ,P.DUE_DT                                       AS 납기일
    ,TR.TR_NM                                       AS 거래처
    ,J.PJT_NM                                       AS 프로젝트
    ,P.PROD_ITEM_CD                                 AS 주문제품
    ,PI.ITEM_NM                                     AS 제품명
    ,PI.UNIT_DC                                     AS 제품단위
    ,P.OPEN_QT                                      AS 수주잔량

    ,P.BOM_LVL                                      AS BOM레벨
    ,REPLICATE(N'    ', P.BOM_LVL - 1) + P.MTL_ITEM_CD AS 전개품번
    ,P.MTL_ITEM_CD                                  AS 원자재품번
    ,MI.ITEM_NM                                     AS 원자재명
    ,MI.ITEM_DC                                     AS 원자재규격
    ,MI.UNIT_DC                                     AS 원자재단위
    ,P.LEAF_YN                                      AS 최하위여부

    ,P.QTY_PER                                      AS 제품1단위당소요
    ,P.GROSS_QT                                     AS 총소요량
    ,P.CUM_LEAD                                     AS 상위누적리드타임
    ,P.SCHD_DT                                      AS 소요일자
    ,CONVERT(NVARCHAR(8), DATEADD(DAY, -CAST(ISNULL(MI.LEAD_DT,0) AS INT),
             CONVERT(DATE, P.SCHD_DT)), 112)        AS 예정발주일
    ,M.AVAIL_QT                                     AS 품목가용재고
    ,M.NET_QT                                       AS 품목순소요
    ,P.NODE_PATH                                    AS 전개경로
FROM        #PEG P
LEFT  JOIN  #MRP   M  ON M.CO_CD  = P.CO_CD AND M.ITEM_CD = P.MTL_ITEM_CD
LEFT  JOIN  SITEM  PI WITH (NOLOCK) ON PI.CO_CD = P.CO_CD AND PI.ITEM_CD = P.PROD_ITEM_CD
LEFT  JOIN  SITEM  MI WITH (NOLOCK) ON MI.CO_CD = P.CO_CD AND MI.ITEM_CD = P.MTL_ITEM_CD
LEFT  JOIN  STRADE TR WITH (NOLOCK) ON TR.CO_CD = P.CO_CD AND TR.TR_CD  = P.TR_CD
LEFT  JOIN  SPJT   J  WITH (NOLOCK) ON J.CO_CD  = P.CO_CD AND J.PJT_CD  = P.PJT_CD
ORDER BY P.DUE_DT, P.SO_NB, P.SO_SQ, P.BOM_LVL, P.MTL_ITEM_CD
;


/*==============================================================================================
  ** 쿼리 C : 원자재 기준 역추적 (Pegging / Where-Used by Demand)
     "이 원자재는 어느 수주 때문에 얼마나 필요한가" - @MTL_ITEM_CD 로 특정 가능
==============================================================================================*/
SELECT
     N'[C] 원자재 역추적(Pegging)'                  AS REPORT_NM
    ,P.MTL_ITEM_CD                                  AS 원자재품번
    ,MI.ITEM_NM                                     AS 원자재명
    ,MI.UNIT_DC                                     AS 단위
    ,P.SCHD_DT                                      AS 소요일자
    ,P.GROSS_QT                                     AS 소요량
    ,CAST(P.GROSS_QT / NULLIF(SUM(P.GROSS_QT) OVER (PARTITION BY P.CO_CD, P.MTL_ITEM_CD), 0) * 100
          AS DECIMAL(19,2))                         AS 소요비중_PCT
    ,SUM(P.GROSS_QT) OVER (PARTITION BY P.CO_CD, P.MTL_ITEM_CD
                           ORDER BY P.SCHD_DT, P.SO_NB, P.SO_SQ
                           ROWS UNBOUNDED PRECEDING) AS 누적소요량
    ,M.AVAIL_QT                                     AS 가용재고
    ,SUM(P.GROSS_QT) OVER (PARTITION BY P.CO_CD, P.MTL_ITEM_CD
                           ORDER BY P.SCHD_DT, P.SO_NB, P.SO_SQ
                           ROWS UNBOUNDED PRECEDING) - M.AVAIL_QT AS 누적부족량
    ,충당가능여부 = CASE WHEN SUM(P.GROSS_QT) OVER (PARTITION BY P.CO_CD, P.MTL_ITEM_CD
                                     ORDER BY P.SCHD_DT, P.SO_NB, P.SO_SQ
                                     ROWS UNBOUNDED PRECEDING) <= M.AVAIL_QT
                         THEN N'충당가능' ELSE N'부족' END

    ,P.SO_NB                                        AS 수주번호
    ,P.SO_SQ                                        AS 수주순번
    ,P.DUE_DT                                       AS 납기일
    ,TR.TR_NM                                       AS 거래처
    ,P.PROD_ITEM_CD                                 AS 주문제품
    ,PI.ITEM_NM                                     AS 제품명
    ,P.OPEN_QT                                      AS 수주잔량
    ,P.BOM_LVL                                      AS BOM레벨
    ,P.QTY_PER                                      AS 제품1단위당소요
    ,P.NODE_PATH                                    AS 전개경로
FROM        #PEG P
LEFT  JOIN  #MRP   M  ON M.CO_CD  = P.CO_CD AND M.ITEM_CD = P.MTL_ITEM_CD
LEFT  JOIN  SITEM  MI WITH (NOLOCK) ON MI.CO_CD = P.CO_CD AND MI.ITEM_CD = P.MTL_ITEM_CD
LEFT  JOIN  SITEM  PI WITH (NOLOCK) ON PI.CO_CD = P.CO_CD AND PI.ITEM_CD = P.PROD_ITEM_CD
LEFT  JOIN  STRADE TR WITH (NOLOCK) ON TR.CO_CD = P.CO_CD AND TR.TR_CD  = P.TR_CD
ORDER BY P.MTL_ITEM_CD, P.SCHD_DT, P.SO_NB, P.SO_SQ
;


/*==============================================================================================
  ** 쿼리 D : 시계열 수급 밸런스 (주별/월별 버킷) - 최초 부족 시점 파악
==============================================================================================*/
;WITH BK AS
(
    SELECT
         P.CO_CD
        ,P.MTL_ITEM_CD
        ,BUCKET = CASE WHEN @BUCKET_FG = N'M' THEN LEFT(P.SCHD_DT, 6)
                       ELSE CONVERT(NVARCHAR(8),
                              DATEADD(DAY, -(DATEPART(WEEKDAY, CONVERT(DATE, P.SCHD_DT)) - 1),
                                      CONVERT(DATE, P.SCHD_DT)), 112) END
        ,REQ_QT = SUM(P.GROSS_QT)
    FROM   #PEG P
    GROUP BY P.CO_CD, P.MTL_ITEM_CD
            ,CASE WHEN @BUCKET_FG = N'M' THEN LEFT(P.SCHD_DT, 6)
                  ELSE CONVERT(NVARCHAR(8),
                         DATEADD(DAY, -(DATEPART(WEEKDAY, CONVERT(DATE, P.SCHD_DT)) - 1),
                                 CONVERT(DATE, P.SCHD_DT)), 112) END
)
SELECT
     N'[D] 시계열 수급 밸런스'                      AS REPORT_NM
    ,B.MTL_ITEM_CD                                  AS 원자재품번
    ,I.ITEM_NM                                      AS 품명
    ,I.UNIT_DC                                      AS 단위
    ,B.BUCKET                                       AS 기간
    ,M.AVAIL_QT                                     AS 기초가용재고
    ,B.REQ_QT                                       AS 기간소요량
    ,SUM(B.REQ_QT) OVER (PARTITION BY B.CO_CD, B.MTL_ITEM_CD
                         ORDER BY B.BUCKET ROWS UNBOUNDED PRECEDING) AS 누적소요량
    ,M.AVAIL_QT - SUM(B.REQ_QT) OVER (PARTITION BY B.CO_CD, B.MTL_ITEM_CD
                                      ORDER BY B.BUCKET ROWS UNBOUNDED PRECEDING) AS 기말잔량
    ,판정 = CASE WHEN M.AVAIL_QT - SUM(B.REQ_QT) OVER (PARTITION BY B.CO_CD, B.MTL_ITEM_CD
                                        ORDER BY B.BUCKET ROWS UNBOUNDED PRECEDING) < 0
                 THEN N'부족' ELSE N'정상' END
    ,M.LEAD_DT                                      AS 조달일수
    ,CONVERT(NVARCHAR(8), DATEADD(DAY, -M.LEAD_DT, CONVERT(DATE, B.BUCKET)), 112) AS 해당기간_발주마감일
FROM        BK B
LEFT  JOIN  #MRP  M ON M.CO_CD = B.CO_CD AND M.ITEM_CD = B.MTL_ITEM_CD
LEFT  JOIN  SITEM I WITH (NOLOCK) ON I.CO_CD = B.CO_CD AND I.ITEM_CD = B.MTL_ITEM_CD
ORDER BY B.MTL_ITEM_CD, B.BUCKET
;


/*==============================================================================================
  ** 쿼리 E : 부족 자재 긴급 조치 리스트
==============================================================================================*/
SELECT
     N'[E] 부족자재 조치 리스트'                    AS REPORT_NM
    ,M.긴급도
    ,M.ITEM_CD                                      AS 원자재품번
    ,I.ITEM_NM                                      AS 품명
    ,I.ITEM_DC                                      AS 규격
    ,I.UNIT_DC                                      AS 단위
    ,TR.TR_NM                                       AS 주거래처
    ,M.GROSS_QT                                     AS 총소요량
    ,M.AVAIL_QT                                     AS 가용재고
    ,M.NET_QT                                       AS 부족수량
    ,M.발주권고량
    ,M.LEAD_DT                                      AS 조달일수
    ,M.FIRST_SCHD                                   AS 최초소요일
    ,M.예정발주일
    ,M.발주지연일수
    ,M.PO_QT                                        AS 기발주잔량
    ,조치 = CASE
         WHEN M.발주지연일수 > 0 THEN N'즉시 발주 + 납기 협의 필요 (' + CAST(M.발주지연일수 AS NVARCHAR(10)) + N'일 경과)'
         WHEN M.PO_QT >= M.NET_QT THEN N'기발주분으로 충당 가능 - 입고일 확인'
         ELSE N'발주 진행' END
    ,M.SO_CNT                                       AS 영향수주건수
    ,SO.영향수주목록
FROM        ( SELECT *
                    ,발주권고량 = CAST( CASE WHEN NET_QT <= 0 THEN 0
                                            WHEN @OPT_LOT = N'1' AND LOT_QT > 0
                                                 THEN CEILING(NET_QT / LOT_QT) * LOT_QT
                                            ELSE NET_QT END AS DECIMAL(19,6))
                    ,예정발주일 = CONVERT(NVARCHAR(8), DATEADD(DAY, -LEAD_DT, CONVERT(DATE, FIRST_SCHD)), 112)
                    ,발주지연일수 = DATEDIFF(DAY, DATEADD(DAY, -LEAD_DT, CONVERT(DATE, FIRST_SCHD)),
                                             CONVERT(DATE, @BASE_DT))
                    ,긴급도 = CASE WHEN DATEADD(DAY, -LEAD_DT, CONVERT(DATE, FIRST_SCHD)) < CONVERT(DATE, @BASE_DT)
                                   THEN N'1.발주시점 경과(긴급)'
                                   WHEN DATEADD(DAY, -LEAD_DT, CONVERT(DATE, FIRST_SCHD))
                                        <= DATEADD(DAY, 7, CONVERT(DATE, @BASE_DT)) THEN N'2.7일 이내 발주'
                                   ELSE N'3.여유' END
              FROM #MRP WHERE NET_QT > 0 ) M
LEFT  JOIN  SITEM  I  WITH (NOLOCK) ON I.CO_CD  = M.CO_CD AND I.ITEM_CD = M.ITEM_CD
LEFT  JOIN  STRADE TR WITH (NOLOCK) ON TR.CO_CD = I.CO_CD AND TR.TR_CD = I.TRMAIN_CD
OUTER APPLY (
    SELECT 영향수주목록 = STUFF((
        SELECT TOP 5 N', ' + P2.SO_NB + N'(' + P2.DUE_DT + N')'
        FROM   #PEG P2
        WHERE  P2.CO_CD = M.CO_CD AND P2.MTL_ITEM_CD = M.ITEM_CD
        GROUP BY P2.SO_NB, P2.DUE_DT
        ORDER BY P2.DUE_DT
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'')
) SO
ORDER BY M.긴급도, M.발주지연일수 DESC, M.NET_QT DESC
;


/*==============================================================================================
  ** 쿼리 F : 수주 오더별 충족 가능성 (Order Feasibility)
     수주에 필요한 원자재 중 하나라도 부족하면 해당 수주는 납기 리스크가 있다.
==============================================================================================*/
;WITH OF_ AS
(
    SELECT
         P.CO_CD, P.SO_NB, P.SO_SQ, P.DUE_DT, P.TR_CD, P.PROD_ITEM_CD, P.OPEN_QT
        ,MTL_CNT   = COUNT(DISTINCT P.MTL_ITEM_CD)
        ,SHORT_CNT = COUNT(DISTINCT CASE WHEN M.NET_QT > 0 THEN P.MTL_ITEM_CD END)
        ,SHORT_QT  = SUM(CASE WHEN M.NET_QT > 0 THEN P.GROSS_QT ELSE 0 END)
        ,MIN_SCHD  = MIN(P.SCHD_DT)
        ,MAX_DELAY = MAX(CASE WHEN M.NET_QT > 0
                              THEN DATEDIFF(DAY,
                                     DATEADD(DAY, -M.LEAD_DT, CONVERT(DATE, P.SCHD_DT)),
                                     CONVERT(DATE, @BASE_DT)) END)
    FROM        #PEG P
    LEFT  JOIN  #MRP M ON M.CO_CD = P.CO_CD AND M.ITEM_CD = P.MTL_ITEM_CD
    GROUP BY P.CO_CD, P.SO_NB, P.SO_SQ, P.DUE_DT, P.TR_CD, P.PROD_ITEM_CD, P.OPEN_QT
)
SELECT
     N'[F] 수주별 충족 가능성'                      AS REPORT_NM
    ,O.SO_NB                                        AS 수주번호
    ,O.SO_SQ                                        AS 수주순번
    ,O.DUE_DT                                       AS 납기일
    ,TR.TR_NM                                       AS 거래처
    ,O.PROD_ITEM_CD                                 AS 주문제품
    ,PI.ITEM_NM                                     AS 제품명
    ,O.OPEN_QT                                      AS 수주잔량
    ,O.MTL_CNT                                      AS 소요자재수
    ,O.SHORT_CNT                                    AS 부족자재수
    ,CAST(CASE WHEN O.MTL_CNT <> 0
               THEN CAST(O.MTL_CNT - O.SHORT_CNT AS DECIMAL(19,6)) / O.MTL_CNT * 100
               END AS DECIMAL(19,2))                AS 자재확보율_PCT
    ,O.MIN_SCHD                                     AS 최초소요일
    ,O.MAX_DELAY                                    AS 최대발주지연일수
    ,납기리스크 = CASE WHEN O.SHORT_CNT = 0                 THEN N'0.정상'
                       WHEN ISNULL(O.MAX_DELAY, 0) > 0      THEN N'1.높음(발주시점 경과)'
                       WHEN O.SHORT_CNT * 1.0 / NULLIF(O.MTL_CNT,0) > 0.3 THEN N'2.중간(부족자재 30% 초과)'
                       ELSE N'3.낮음' END
    ,S.병목자재
FROM        OF_ O
LEFT  JOIN  STRADE TR WITH (NOLOCK) ON TR.CO_CD = O.CO_CD AND TR.TR_CD  = O.TR_CD
LEFT  JOIN  SITEM  PI WITH (NOLOCK) ON PI.CO_CD = O.CO_CD AND PI.ITEM_CD = O.PROD_ITEM_CD
OUTER APPLY (
    SELECT 병목자재 = STUFF((
        SELECT TOP 5 N', ' + P2.MTL_ITEM_CD
        FROM   #PEG P2
        INNER JOIN #MRP M2 ON M2.CO_CD = P2.CO_CD AND M2.ITEM_CD = P2.MTL_ITEM_CD
        WHERE  P2.CO_CD = O.CO_CD AND P2.SO_NB = O.SO_NB AND P2.SO_SQ = O.SO_SQ
          AND  M2.NET_QT > 0
        GROUP BY P2.MTL_ITEM_CD, M2.NET_QT
        ORDER BY M2.NET_QT DESC
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'')
) S
ORDER BY 납기리스크, O.DUE_DT, O.SO_NB
;


/*==============================================================================================
  ** 쿼리 G : ERP 소요량전개(LDEMAND_D) 대사 검증                                [(4)]
     iCUBE 소요량전개를 실행한 뒤 본 쿼리 결과와 순소요량이 일치하는지 확인한다.
==============================================================================================*/
IF OBJECT_ID(N'dbo.LDEMAND_D', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
    DECLARE @p_exp NVARCHAR(8);
    SELECT  @p_exp = ISNULL(@p_in_exp, MAX(EXP_DT))
    FROM    dbo.LDEMAND WITH (NOLOCK) WHERE CO_CD = @p_CO_CD AND (@p_DIV IS NULL OR DIV_CD = @p_DIV);

    SELECT
         N''[G] ERP 소요량전개 대사''                 AS REPORT_NM
        ,@p_exp                                       AS ERP전개일
        ,X.ITEM_CD                                    AS 원자재품번
        ,I.ITEM_NM                                    AS 품명
        ,X.GROSS_QT                                   AS 본쿼리_총소요
        ,V.GROSS_REQUIRE_QT                           AS ERP_총소요
        ,X.GROSS_QT - ISNULL(V.GROSS_REQUIRE_QT, 0)   AS 총소요_차이
        ,X.NET_QT                                     AS 본쿼리_순소요
        ,V.NET_REQUIRE_QT                             AS ERP_순소요
        ,X.NET_QT - ISNULL(V.NET_REQUIRE_QT, 0)       AS 순소요_차이
        ,V.COMPONENT_INV_QT                           AS ERP_부품재고
        ,X.AVAIL_QT                                   AS 본쿼리_가용재고
        ,V.SCHD_DT                                    AS ERP_소요일자
        ,X.FIRST_SCHD                                 AS 본쿼리_최초소요일
        ,V.EPUR_DT                                    AS ERP_예정발주일
        ,판정 = CASE WHEN V.ITEM_CD IS NULL THEN N''ERP 미집계''
                     WHEN ABS(X.NET_QT - ISNULL(V.NET_REQUIRE_QT,0)) < 0.000001 THEN N''일치''
                     ELSE N''차이발생'' END
    FROM   #MRP X
    LEFT JOIN (
        SELECT  CO_CD, ITEM_CD
               ,GROSS_REQUIRE_QT = SUM(GROSS_REQUIRE_QT)
               ,NET_REQUIRE_QT   = SUM(NET_REQUIRE_QT)
               ,COMPONENT_INV_QT = MAX(COMPONENT_INV_QT)
               ,SCHD_DT          = MIN(SCHD_DT)
               ,EPUR_DT          = MIN(EPUR_DT)
        FROM    dbo.LDEMAND_D WITH (NOLOCK)
        WHERE   CO_CD = @p_CO_CD AND USE_YN = N''1'' AND EXPIRE_YN = N''1''
          AND   (@p_DIV IS NULL OR DIV_CD = @p_DIV)
        GROUP BY CO_CD, ITEM_CD
    ) V ON V.CO_CD = X.CO_CD AND V.ITEM_CD = X.ITEM_CD
    LEFT JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = X.CO_CD AND I.ITEM_CD = X.ITEM_CD
    ORDER BY ABS(X.NET_QT - ISNULL(V.NET_REQUIRE_QT, 0)) DESC';

    EXEC sp_executesql @SQL
        ,N'@p_CO_CD NVARCHAR(4), @p_DIV NVARCHAR(4), @p_in_exp NVARCHAR(8)'
        ,@p_CO_CD = @CO_CD, @p_DIV = @DIV_CD, @p_in_exp = @DEMAND_EXP_DT;
END
ELSE
    PRINT N'[INFO] LDEMAND_D 없음 - ERP 대사(쿼리 G) 생략';


/*==============================================================================================
  ** 쿼리 H : BOM 역전개 (Where-Used) - 특정 원자재의 상위 모품목 경로
     @MTL_ITEM_CD 지정 시 해당 자재가 어떤 제품에 쓰이는지 BOM 구조를 거슬러 올라간다.
     (USP_SYC0630_BY_SELECT_BOM 과 동일 개념 / 재귀 CTE 로 구현)                   [(3)]
==============================================================================================*/
IF @MTL_ITEM_CD IS NOT NULL
BEGIN
    ;WITH RUP AS
    (
        SELECT
             B.CO_CD
            ,BASE_ITEM_CD = B.ITEMCHILD_CD
            ,LVL          = 1
            ,CHILD_CD     = B.ITEMCHILD_CD
            ,PARENT_CD    = B.ITEMPARENT_CD
            ,QTY_PER      = B.REAL_QT
            ,NODE_PATH    = CAST(N'|' + B.ITEMCHILD_CD + N'|' + B.ITEMPARENT_CD + N'|' AS NVARCHAR(4000))
        FROM   #BOM_SRC B
        WHERE  B.CO_CD = @CO_CD AND B.ITEMCHILD_CD = @MTL_ITEM_CD

        UNION ALL

        SELECT
             R.CO_CD
            ,R.BASE_ITEM_CD
            ,LVL          = R.LVL + 1
            ,CHILD_CD     = B.ITEMCHILD_CD
            ,PARENT_CD    = B.ITEMPARENT_CD
            ,QTY_PER      = R.QTY_PER * B.REAL_QT
            ,NODE_PATH    = CAST(R.NODE_PATH + B.ITEMPARENT_CD + N'|' AS NVARCHAR(4000))
        FROM        RUP      R
        INNER JOIN  #BOM_SRC B
               ON   B.CO_CD = R.CO_CD AND B.ITEMCHILD_CD = R.PARENT_CD
        WHERE  R.LVL < @BOM_MAX_LVL
          AND  R.NODE_PATH NOT LIKE N'%|' + B.ITEMPARENT_CD + N'|%'
    )
    SELECT
         N'[H] BOM 역전개(Where-Used)'              AS REPORT_NM
        ,R.BASE_ITEM_CD                             AS 기준원자재
        ,BI.ITEM_NM                                 AS 원자재명
        ,R.LVL                                      AS 역전개레벨
        ,REPLICATE(N'    ', R.LVL - 1) + R.PARENT_CD AS 상위품번
        ,R.CHILD_CD                                 AS 자품번
        ,R.PARENT_CD                                AS 모품번
        ,PI.ITEM_NM                                 AS 모품명
        ,PI.ITEM_DC                                 AS 모규격
        ,PI.UNIT_DC                                 AS 단위
        ,PI.ACCT_FG                                 AS 모품목계정구분
        ,R.QTY_PER                                  AS 누적소요량
        ,최상위여부 = CASE WHEN NOT EXISTS (SELECT 1 FROM #BOM_SRC U
                                            WHERE U.CO_CD = R.CO_CD AND U.ITEMCHILD_CD = R.PARENT_CD)
                           THEN N'Y' ELSE N'N' END
        ,수주여부 = CASE WHEN EXISTS (SELECT 1 FROM #SO S
                                      WHERE S.CO_CD = R.CO_CD AND S.PROD_ITEM_CD = R.PARENT_CD)
                         THEN N'Y(대상수주 있음)' ELSE N'N' END
        ,R.NODE_PATH                                AS 역전개경로
    FROM        RUP R
    LEFT  JOIN  SITEM BI WITH (NOLOCK) ON BI.CO_CD = R.CO_CD AND BI.ITEM_CD = R.BASE_ITEM_CD
    LEFT  JOIN  SITEM PI WITH (NOLOCK) ON PI.CO_CD = R.CO_CD AND PI.ITEM_CD = R.PARENT_CD
    ORDER BY R.NODE_PATH
    OPTION (MAXRECURSION 0);
END
ELSE
    PRINT N'[INFO] @MTL_ITEM_CD 미지정 - BOM 역전개(쿼리 H) 생략';


DROP TABLE #SO, #BOM_SRC, #BOM_EXP, #PEG, #SUP, #MRP;
GO


/*==============================================================================================
  [ 부록 1 ] MRP 로직 대응표 : 본 쿼리 vs iCUBE 소요량전개(LDEMAND)
  ----------------------------------------------------------------------------------------------
   LDEMAND 옵션                본 쿼리 파라미터   구현 소스
   --------------------------  -----------------  ------------------------------------------
   OPTION_INV      재고        @OPT_INV           LINVTORY (IOPEN+IRCV-IISU)
   OPTION_SO       주문잔량    @OPT_SO            LSO_D (SO_QT - ISU_QT)
   OPTION_JUMUN    주문수량    (미구현)           LJUMUN / LJUMUN_ISU - 유통 사용 시 추가
   OPTION_RENT     가출고      @OPT_RENT          LRENT + LRENT_D (RENT_QT)
   OPTION_WOBOM    작지청구    @OPT_REQ           LWO_REQ_WF (REQ_QT - RCV_QT)
   OPTION_PO       발주잔량    @OPT_PO            LPO_D (PO_QT - RCV_QT)
   OPTION_WR_IN    작지        @OPT_WO            LWO_WF (ITEM_QT - 실적), WOC_FG <> '4'
   OPTION_WR_OUT   외주        @OPT_IWO           LWO_WF (ITEM_QT - 실적), WOC_FG  = '4'
   OPTION_SAFE     안전재고    @OPT_SAFE          SITEM.SAFESTOCK_QT
   OPTION_LOT_QT   최소발주량  @OPT_LOT           SITEM.LOT_QT 절상
   OPTION_BATCH_BOM_YN         (미구현)           SBOM_WF_B + SITEM.FOQ_QT - [부록 3]
   OPTION_INCLUDE_PARENT_ITEM_YN  @LEAF_ONLY='N'  전 레벨 집계
   OPTION_EXCEPT_BAD 불량재고제외 / OPTION_AVAILABLE 가용재고제외 / OPTION_EXCEPT_MINUS
                               (미구현)           LINVTORY 의 LC_CD 별 SLOC.BAD_YN / AVABSTOCK_YN 활용

   => ERP 소요량전개를 같은 옵션으로 실행한 뒤 쿼리 G 로 순소요량을 대사하십시오.


  [ 부록 2 ] 도입 전 검증 쿼리
  ----------------------------------------------------------------------------------------------
  -- (1) 테이블 존재 확인
     SELECT name FROM sys.tables
     WHERE name IN ('LSO','LSO_D','LPO','LPO_D','LINVTORY','LWO_REQ_WF','LRENT','LRENT_D',
                    'LWO_WF','LORCV_H','SBOM_WF','SBOM','LDEMAND','LDEMAND_D','LDEMAND_STORY')
     ORDER BY name;

  -- (2) EXPIRE_YN 분포 확인
     SELECT 'LSO_D' TB, EXPIRE_YN, COUNT(*) FROM LSO_D  GROUP BY EXPIRE_YN
     UNION ALL
     SELECT 'LPO_D',    EXPIRE_YN, COUNT(*) FROM LPO_D  GROUP BY EXPIRE_YN;
     --> '1'=진행(미마감), '0'=마감. 잔량 조회는 = '1'.

  -- (3) 현재고 검증 : LINVTORY 집계 vs 재고관리 화면
     SELECT ITEM_CD, SUM(ISNULL(IOPEN_QT,0)+ISNULL(IRCV_QT,0)-ISNULL(IISU_QT,0)) 현재고
     FROM   LINVTORY
     WHERE  CO_CD='1000' AND DIV_CD='1000' AND P_YR='2026' AND IO_DT<='20260915'
     GROUP BY ITEM_CD HAVING SUM(ISNULL(IOPEN_QT,0)+ISNULL(IRCV_QT,0)-ISNULL(IISU_QT,0)) <> 0
     ORDER BY ITEM_CD;

  -- (4) 리드타임/안전재고/최소발주량 등록률 (미등록이면 MRP 정확도가 떨어진다)
     SELECT COUNT(*) 전체
           ,SUM(CASE WHEN ISNULL(LEAD_DT,0)      = 0 THEN 1 ELSE 0 END) 조달일수미등록
           ,SUM(CASE WHEN ISNULL(SAFESTOCK_QT,0) = 0 THEN 1 ELSE 0 END) 안전재고미등록
           ,SUM(CASE WHEN ISNULL(LOT_QT,0)       = 0 THEN 1 ELSE 0 END) 최소발주량미등록
     FROM   SITEM WHERE CO_CD='1000' AND USE_YN='1' AND ACCT_FG IN ('0','1');

  -- (5) BOM 미등록 주문제품 (전개 누락의 원인)
     SELECT DISTINCT D.ITEM_CD, I.ITEM_NM
     FROM   LSO_D D LEFT OUTER JOIN SITEM I ON I.CO_CD=D.CO_CD AND I.ITEM_CD=D.ITEM_CD
     WHERE  D.CO_CD='1000' AND D.DUE_DT BETWEEN '20260901' AND '20261231'
       AND  NOT EXISTS (SELECT 1 FROM SBOM_WF B
                        WHERE B.CO_CD=D.CO_CD AND B.ITEMPARENT_CD=D.ITEM_CD AND B.USE_YN='1');

  -- (6) BOM 순환참조 점검 (전개가 멈추지 않는 원인)
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


  [ 부록 3 ] BATCH BOM 사이트
  ----------------------------------------------------------------------------------------------
  BATCH BOM = `SBOM_WF_B`, 배치수량 = 모품목의 `SITEM.FOQ_QT`.
  해당 품목은 #BOM_SRC 적재 시 REAL_QT 를 FOQ_QT 로 나누어 1단위 기준으로 환산해야 한다.

      QTY_PER = REAL_QT / NULLIF(모품목.FOQ_QT, 0)

  BATCH BOM 정합성 점검 :
      SELECT B.ITEMPARENT_CD, S.FOQ_QT, SUM(B.JUST_QT) 자품목합계, S.FOQ_QT - SUM(B.JUST_QT) 차이
      FROM   SBOM_WF_B B LEFT OUTER JOIN SITEM S ON S.CO_CD=B.CO_CD AND S.ITEM_CD=B.ITEMPARENT_CD
      WHERE  B.CO_CD='1000'
      GROUP BY B.ITEMPARENT_CD, S.FOQ_QT
      HAVING ABS(S.FOQ_QT - SUM(B.JUST_QT)) > 0.000001;


  [ 부록 4 ] 수불 코드맵 (재고 산출 근거)                                          [(5)(8)]
  ----------------------------------------------------------------------------------------------
   IO_FG  : 0.기초  1.입고  2.출고
   GRP_FG : '0' 생산입고/생산자재출고/일괄생산실적   '2' 구매입고   '3' 매출출고
            '6' 재고조정/해체조정/기초이월
   CLS_NB (앞 2자리)
     IW 생산>작업실적입고(입고)      MF 일괄생산실적(입고/출고)
     MV,MB 생산자재출고처리(출고)    PC 매입마감(입고)      RV,RB 입고처리
     SC 매출마감(출고)               IS,IB 출고처리
     IA,IB 재고조정                  DJ 해체조정            XY 재고이월기초
     WI 재공입고  WM 재공이동  WA 재공조정  OW 기초재공     * 수불NB 는 사용자 임의 입력 가능

   재고 관련 테이블
     LINVTORY     재고수불부(평가 전)   <- 본 쿼리의 현재고 소스
     LINV_MVFIFO  재고자산수불부(평가 후)
     LINV_WIP     재공수불부
     VL_LINVTORY_ALL / VL_LINV_WIP_ALL / VL_LWO_REQ_WF  (사이트에 따라 제공되는 뷰)
       -> 뷰가 있으면 LINVTORY 대신 VL_LINVTORY_ALL 을 쓰는 편이 안전하다.


  [ 부록 5 ] 남은 확인 사항 / 한계
  ----------------------------------------------------------------------------------------------
  1) 본 쿼리는 **수주 기준 소요(MTO)** 만 반영한다.
     판매계획(LFORECST) / 주계획(LMPS) 기반 소요까지 포함하려면 #SO 를 UNION 으로 확장할 것.
  2) 가용재고는 **시점 무관 총량** 기준이다(쿼리 A/E).
     시점별 과부족은 쿼리 D 의 버킷 잔량으로 확인하고, 정밀한 Time-phased MRP 가 필요하면
     입고예정(PO/WO)에도 납기일(LPO_D.DUE_DT, LWO_WF.COMP_DT)을 버킷에 배치해야 한다.
  3) 리드타임 오프셋은 SITEM.LEAD_DT(조달일수) 만 사용한다.
     공정 리드타임(LROUTING_D)까지 반영하려면 CUM_LEAD 계산을 공정경로 기준으로 교체할 것.
  4) 반제품을 자체 생산하는 경우 @LEAF_ONLY='Y' 는 최하위 구매품만 집계하므로
     반제품 재고가 있어도 그만큼 하위 원자재 소요가 줄지 않는다.
     반제품 재고를 소요에서 차감하려면 레벨별 순소요 전개(Level-by-level netting)가 필요하다.
     -> 우선 @LEAF_ONLY='N' 으로 전 레벨을 조회해 반제품 재고/순소요를 확인하십시오.
  5) 성능 인덱스
     LSO_D      (CO_CD, DUE_DT) INCLUDE (SO_NB, SO_SQ, ITEM_CD, SO_QT, ISU_QT, EXPIRE_YN)
     LPO_D      (CO_CD, ITEM_CD) INCLUDE (PO_QT, RCV_QT, EXPIRE_YN)
     LINVTORY   (CO_CD, DIV_CD, P_YR, ITEM_CD, IO_DT)
     LWO_REQ_WF (CO_CD, DIV_CD, ITEM_CD)
     SBOM_WF    (CO_CD, ITEMPARENT_CD, START_DT, END_DT) / (CO_CD, ITEMCHILD_CD)

  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------

  -- (1) ★★ EXPIRE_YN 방향. 이 리포트는 과거 두 번 반대로 걸려 전 건이 사라진 적이 있다
     SELECT EXPIRE_YN, COUNT(*) FROM LSO_D WHERE CO_CD='1000' GROUP BY EXPIRE_YN;
     --> '1' 이 진행이다. 결과가 0 건이면 여기부터 의심할 것.

  -- (2) iCUBE 소요량전개를 운영하는지 확인한다. 없으면 이 파일의 자체 전개로만 동작한다
     SELECT OBJECT_ID('dbo.LDEMAND') H, OBJECT_ID('dbo.LDEMAND_D') D;

  -- (3) 조달일수 등록률. 예정발주일의 유일한 근거다
     SELECT COUNT(*) 전체, SUM(CASE WHEN ISNULL(LEAD_DT,0)=0 THEN 1 ELSE 0 END) 미등록
     FROM   SITEM WHERE CO_CD='1000' AND ACCT_FG IN ('0','1');
     --> 미등록이 많으면 예정발주일은 참고치일 뿐이다.

  -- (4) 가용재고를 어느 소스로 볼지 결정한다 (VL_INVDIV / LINVTORY)

  [ 한계 ]
  ----------------------------------------------------------------------------------------------

  1) **iCUBE 소요량전개(`LDEMAND`)와 같은 결과를 보장하지 않는다.** 안전재고 차감 시점,
     로트 크기 반올림, 기발주 반영 범위가 표준 MRP 와 다를 수 있다. 두 결과가 다르면
     어느 쪽이 맞다가 아니라 **어떤 가정이 다른지**를 먼저 맞춰야 한다.

  2) **BOM 다단계 전개에 깊이 제한이 있다.** 무한루프를 막기 위한 것이며, 설계 단계가 아주
     깊은 품목은 하위가 잘릴 수 있다. 순환참조 품목은 B-01 의 BOM 점검에서 먼저 걸러낼 것.

  3) **예정발주일은 조달일수 역산이다.** 휴무일·검수기간·운송 리드타임을 반영하지 않으므로
     실제 발주일은 이보다 앞서야 한다.

  4) **기발주 잔량은 "발주했으나 미입고" 기준**이다. 납기가 지연 통보된 건도 정상 입고예정으로
     잡히므로, P-02(발주납기준수)와 함께 봐야 과부족 판단이 현실에 맞는다.

==============================================================================================*/
