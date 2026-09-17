/*==============================================================================================
  [ iCUBE ] 생산지시별 작업수율 현황                                                 (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 작업지시 단위로 아래 수율/손실 지표를 산출한다.
         (1) 생산수율   - 지시수량 대비 실적, 양품률, 직행률(FTT), 불량률, 재작업률
         (2) 검사수율   - 실적검사 합격률 및 불량유형별 Pareto
         (3) 자재수율   - BOM 표준소요 대비 실제투입 (원단위 편차 / LOSS)
         (4) 공정수율   - 공정 순서별 실적 추이 (전공정 대비 당공정)
         (5) 입고수율   - 양품 대비 실적입고

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 근거 문서 ]
  ----------------------------------------------------------------------------------------------
   (1) 아이큐브테이블명세서.xls                          - 테이블/컬럼 구조
   (2) 아이큐브_API 연동규약서_20160108_V1.00_최종.docx  - 코드값 정의
   (3) CUBE(NEW)_SYC0620_BOM정전개.ppt                   - BOM 전개(무한루프체크)
   (4) USP_COT0010_CALC_COST_TAV.sql                     - iCUBE 원가계산 SP (자재 집계 로직)
   (5) USP_SYC0630_BY_SELECT_BOM (BOM역전개.sql)         - BOM 테이블 = SBOM_WF 확정
   (6) 완성)제품별자재사용현황(수율)_쿼리_20180529.txt   - **재료수율 산식 참조**
   (7) 참조_지시별_자재현황(청구,출고,사용)_쿼리        - 지시-자재 조인 체계
   (8) neo-x_field_layout.xls                            - LBAD(불량유형) 등 명세서 누락분

  ----------------------------------------------------------------------------------------------
  [ 수율 지표 정의 ]
  ----------------------------------------------------------------------------------------------
   구분          지표              산식                                           단위
   ------------  ----------------  ---------------------------------------------  ------
   생산          지시달성률        주산물양품수량 / 지시수량                      %
                 양품률            주산물양품수량 / 주산물실적수량                %
                 직행률(FTT)       (양품 AND 재작업아님) / 주산물실적수량         %
                 불량률            부적합수량 / 주산물실적수량                    %
                 재작업률          재작업수량 / 주산물실적수량                    %
   검사          검사합격률        QCRCV_QT / (QCRCV_QT + QCBAD_QT)               %
   입고          입고율            실적입고수량 / 주산물양품수량                  %
   자재          BOM대비자재수율   표준소요량 / 실제사용량                        %
                 자재LOSS율        100 - BOM대비자재수율                          %
                 원단위편차        (실제원단위 - BOM원단위) / BOM원단위           %
                 재료수율(참고)    생산수량 / 총자재투입량                        %   <- (6) 방식
   공정          공정수율          당공정 실적수량 / 전공정 실적수량              %

   * 재료수율(참고)은 생산품과 자재의 단위가 같은 업종(화학/식품/제지 등)에서만 의미가 있다.
     조립형 제조에서는 **BOM대비자재수율**을 사용해야 한다.

  ----------------------------------------------------------------------------------------------
  [ 사용 테이블 ]
  ----------------------------------------------------------------------------------------------
   작업지시      LWO_WF            CO_CD + WO_CD                    (PJT_CD, ITEM_QT=지시수량)
   지시 공정     LWO_WF_D          CO_CD + WO_CD + BASELOC_CD + LOC_CD  (WOOP_SQ=전개순번)
   생산실적      LORCV_H           CO_CD + DOC_CD   BAD_YN / SUB_TP / REWORK_YN
   실적검사      LQC_INSP          CO_CD + DOC_CD   QCRCV_QT(합격) / QCBAD_QT(불합격)
   불량내역      LQC_INSP_D        CO_CD + DOC_CD + BAD_CD   BAD_QT
   불량유형      LBAD              CO_CD + BAD_CD   BAD_NM                        [(8)]
   실적입고      LPRDINWH          CO_CD + INWH_NB  WR_CD=실적번호, INWH_QT
   자재사용      LMTL_USE          CO_CD + WR_CD + USE_SQ
                 LMTL_USEWO        CO_CD + WO_CD + USE_SQ
   BOM           SBOM_WF / SBOM    CO_CD + ITEMPARENT_CD + ITEMCHILD_CD           [(5)]
   품목/공정     SITEM / SBASELOC / SLOC / SPJT / SDIV / SEMP / SDEPT

  ----------------------------------------------------------------------------------------------
  [ 코드값 : (2) 확정 ]
  ----------------------------------------------------------------------------------------------
   USE_YN 1.사용 0.미사용     EXPIRE_YN 1.유효 2.만료      BAD_YN 0.적합 1.부적합
   SUB_TP 0.주산물 1.부산물   REWORK_YN 0.정상작업 1.재작업
   DOC_ST 0.미처리 1.처리     QC_FG 0.무검사 1.검사        ACCEPT_YN 1.합격 0.불합격
   INSP_FG 0.샘플검사 1.전수검사
   WOC_FG 0.생산지시 2.임가공지시 4.외주발주 5.작업지시
   DOC_FG 0.생산 1.외주 5.재고이동
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD        NVARCHAR(4)   = N'1000'        -- 회사코드
    ,@DIV_CD       NVARCHAR(4)   = NULL           -- 사업장코드 (NULL = 전체)
    ,@FR_DT        NVARCHAR(8)   = N'20260101'    -- 기간 FROM
    ,@TO_DT        NVARCHAR(8)   = N'20261231'    -- 기간 TO
    ,@DT_FG        NVARCHAR(1)   = N'D'           -- 기간기준 : 'D'=실적일 / 'O'=지시일 / 'C'=완료일

    ,@PJT_CD       NVARCHAR(10)  = NULL           -- 프로젝트코드
    ,@WO_CD        NVARCHAR(12)  = NULL           -- 특정 작업지시
    ,@ITEM_CD      NVARCHAR(30)  = NULL           -- 특정 생산품목
    ,@ITEMGRP_CD   NVARCHAR(10)  = NULL           -- 생산품목군
    ,@DEPT_CD      NVARCHAR(4)   = NULL           -- 생산부서
    ,@BASELOC_CD   NVARCHAR(4)   = NULL           -- 공정
    ,@WOC_FG       NVARCHAR(1)   = NULL           -- 지시구분 (0.생산 2.임가공 4.외주발주 5.작업)
    ,@DOC_FG       NVARCHAR(1)   = NULL           -- 생산외주구분 (0.생산 1.외주)

    ,@BOM_BASE_DT  NVARCHAR(8)   = NULL           -- BOM 기준일자 (NULL = @TO_DT)
    ,@BOM_LEVEL_FG NVARCHAR(1)   = N'S'           -- 'S'=1레벨 / 'A'=BOM총전개(최하위 원자재)
    ,@BOM_MAX_LVL  INT           = 10

    ,@MTL_SRC_FG   NVARCHAR(3)   = N'USE'         -- 자재사용 원천 : 'USE'=실적별 / 'ALL'=실적별+지시별
    ,@ACCT_FG_ONLY NVARCHAR(1)   = N'Y'           -- 자재는 원가대상 계정('0','1','2','4','5','6')만

    -- 이상 판정 임계치 (쿼리 F)
    ,@TH_ACHIEVE   DECIMAL(9,2)  = 95.0           -- 지시달성률 하한 %
    ,@TH_GOOD      DECIMAL(9,2)  = 97.0           -- 양품률 하한 %
    ,@TH_MTL_LOSS  DECIMAL(9,2)  = 5.0            -- 자재LOSS율 상한 %
;

SET @BOM_BASE_DT = ISNULL(@BOM_BASE_DT, @TO_DT);


IF OBJECT_ID('tempdb..#WO')      IS NOT NULL DROP TABLE #WO;
IF OBJECT_ID('tempdb..#PRD')     IS NOT NULL DROP TABLE #PRD;
IF OBJECT_ID('tempdb..#PRDSUM')  IS NOT NULL DROP TABLE #PRDSUM;
IF OBJECT_ID('tempdb..#QC')      IS NOT NULL DROP TABLE #QC;
IF OBJECT_ID('tempdb..#BAD')     IS NOT NULL DROP TABLE #BAD;
IF OBJECT_ID('tempdb..#INWH')    IS NOT NULL DROP TABLE #INWH;
IF OBJECT_ID('tempdb..#BOM_SRC') IS NOT NULL DROP TABLE #BOM_SRC;
IF OBJECT_ID('tempdb..#BOM_EXP') IS NOT NULL DROP TABLE #BOM_EXP;
IF OBJECT_ID('tempdb..#MTL')     IS NOT NULL DROP TABLE #MTL;
IF OBJECT_ID('tempdb..#MTLSUM')  IS NOT NULL DROP TABLE #MTLSUM;
IF OBJECT_ID('tempdb..#YIELD')   IS NOT NULL DROP TABLE #YIELD;

DECLARE @SQL NVARCHAR(MAX);


/*==============================================================================================
  1. #PRD : 생산실적 (지시 연결)
     - 코드값은 (2) 확정값 : USE_YN='1', EXPIRE_YN='1'
     - 실적 성격을 주산물/부산물, 적합/부적합, 정상/재작업 으로 분해
==============================================================================================*/
SELECT
     H.CO_CD
    ,DIV_CD       = H.DIV_CD
    ,WO_CD        = H.WO_CD
    ,DOC_CD       = H.DOC_CD
    ,DOC_DT       = H.DOC_DT
    ,DOC_YM       = LEFT(H.DOC_DT, 6)
    ,PJT_CD       = ISNULL(NULLIF(H.PJT_CD, N''), W.PJT_CD)
    ,PROD_ITEM_CD = ISNULL(NULLIF(H.ITEM_CD, N''), W.ITEM_CD)
    ,ORD_DT       = W.ORD_DT
    ,COMP_DT      = W.COMP_DT
    ,WO_QT        = CAST(W.ITEM_QT AS DECIMAL(19,6))
    ,PRD_QT       = CAST(H.ITEM_QT AS DECIMAL(19,6))
    ,BASELOC_CD   = H.BASELOC_CD
    ,LOC_CD       = H.LOC_CD
    ,DEPT_CD      = H.DEPT_CD
    ,EMP_CD       = H.EMP_CD
    ,WTEAM_CD     = H.WTEAM_CD
    ,WSHFT_CD     = H.WSHFT_CD
    ,EQUIP_CD     = H.EQUIP_CD
    ,LOT_NB       = H.LOT_NB
    ,DOC_FG       = H.DOC_FG
    ,WOC_FG       = W.WOC_FG
    ,QC_FG        = H.QC_FG
    ,BAD_YN       = ISNULL(H.BAD_YN   , N'0')                   -- 0.적합 1.부적합
    ,SUB_TP       = ISNULL(H.SUB_TP   , N'0')                   -- 0.주산물 1.부산물
    ,REWORK_YN    = ISNULL(H.REWORK_YN, N'0')                   -- 0.정상 1.재작업
    ,BAD_CD       = H.BAD_CD
INTO #PRD
FROM        LORCV_H H WITH (NOLOCK)
LEFT  JOIN  LWO_WF  W WITH (NOLOCK)
       ON   W.CO_CD = H.CO_CD AND W.WO_CD = H.WO_CD
WHERE   H.CO_CD    = @CO_CD
  AND   H.USE_YN   = N'1'
  AND   H.EXPIRE_YN= N'1'
  AND   (   (@DT_FG = N'D' AND H.DOC_DT  BETWEEN @FR_DT AND @TO_DT)
         OR (@DT_FG = N'O' AND W.ORD_DT  BETWEEN @FR_DT AND @TO_DT)
         OR (@DT_FG = N'C' AND W.COMP_DT BETWEEN @FR_DT AND @TO_DT) )
  AND   (@DIV_CD     IS NULL OR H.DIV_CD     = @DIV_CD)
  AND   (@WO_CD      IS NULL OR H.WO_CD      = @WO_CD)
  AND   (@DEPT_CD    IS NULL OR H.DEPT_CD    = @DEPT_CD)
  AND   (@BASELOC_CD IS NULL OR H.BASELOC_CD = @BASELOC_CD)
  AND   (@DOC_FG     IS NULL OR H.DOC_FG     = @DOC_FG)
  AND   (@WOC_FG     IS NULL OR W.WOC_FG     = @WOC_FG)
  AND   (@PJT_CD     IS NULL OR ISNULL(NULLIF(H.PJT_CD, N''), W.PJT_CD) = @PJT_CD)
  AND   (@ITEM_CD    IS NULL OR ISNULL(NULLIF(H.ITEM_CD, N''), W.ITEM_CD) = @ITEM_CD)
;
CREATE CLUSTERED INDEX IX_PRD  ON #PRD (CO_CD, DOC_CD);
CREATE NONCLUSTERED INDEX IX_PRD2 ON #PRD (CO_CD, WO_CD);

-- 생산품목군 필터
IF @ITEMGRP_CD IS NOT NULL
    DELETE P
    FROM        #PRD P
    LEFT  JOIN  SITEM I WITH (NOLOCK) ON I.CO_CD = P.CO_CD AND I.ITEM_CD = P.PROD_ITEM_CD
    WHERE ISNULL(I.ITEMGRP_CD, N'') <> @ITEMGRP_CD;


/*==============================================================================================
  2. #WO : 대상 작업지시 마스터
==============================================================================================*/
SELECT
     CO_CD
    ,WO_CD
    ,DIV_CD       = MIN(DIV_CD)
    ,PJT_CD       = MIN(PJT_CD)
    ,PROD_ITEM_CD = MIN(PROD_ITEM_CD)
    ,WO_QT        = MAX(WO_QT)
    ,ORD_DT       = MIN(ORD_DT)
    ,COMP_DT      = MAX(COMP_DT)
    ,DEPT_CD      = MIN(DEPT_CD)
    ,WOC_FG       = MIN(WOC_FG)
    ,DOC_FG       = MIN(DOC_FG)
INTO #WO
FROM   #PRD
GROUP BY CO_CD, WO_CD;
CREATE CLUSTERED INDEX IX_WO ON #WO (CO_CD, WO_CD);


/*==============================================================================================
  3. #PRDSUM : 지시별 실적 분해 집계
     주산물(SUB_TP='0') 기준으로 수율을 계산하고, 부산물은 별도 표기한다.
==============================================================================================*/
SELECT
     CO_CD
    ,WO_CD
    -- 주산물
    ,MAIN_QT   = SUM(CASE WHEN SUB_TP = N'0'                       THEN PRD_QT ELSE 0 END)  -- 주산물 총실적
    ,GOOD_QT   = SUM(CASE WHEN SUB_TP = N'0' AND BAD_YN = N'0'     THEN PRD_QT ELSE 0 END)  -- 양품
    ,BAD_QT    = SUM(CASE WHEN SUB_TP = N'0' AND BAD_YN = N'1'     THEN PRD_QT ELSE 0 END)  -- 부적합
    ,FTT_QT    = SUM(CASE WHEN SUB_TP = N'0' AND BAD_YN = N'0'
                                             AND REWORK_YN = N'0'  THEN PRD_QT ELSE 0 END)  -- 직행(무재작업 양품)
    ,REWORK_QT = SUM(CASE WHEN SUB_TP = N'0' AND REWORK_YN = N'1'  THEN PRD_QT ELSE 0 END)  -- 재작업
    -- 부산물
    ,SUB_QT    = SUM(CASE WHEN SUB_TP = N'1'                       THEN PRD_QT ELSE 0 END)
    -- 건수/기간
    ,PRD_CNT   = COUNT(*)
    ,BAD_CNT   = SUM(CASE WHEN BAD_YN = N'1' THEN 1 ELSE 0 END)
    ,FR_DOC_DT = MIN(DOC_DT)
    ,TO_DOC_DT = MAX(DOC_DT)
    ,QC_CNT    = SUM(CASE WHEN QC_FG = N'1' THEN 1 ELSE 0 END)
INTO #PRDSUM
FROM   #PRD
GROUP BY CO_CD, WO_CD;
CREATE CLUSTERED INDEX IX_PRDSUM ON #PRDSUM (CO_CD, WO_CD);


/*==============================================================================================
  4. #QC / #BAD : 실적검사 및 불량내역
==============================================================================================*/
SELECT
     P.CO_CD
    ,P.WO_CD
    ,QCRCV_QT  = SUM(CAST(ISNULL(Q.QCRCV_QT, 0) AS DECIMAL(19,6)))      -- 합격수량
    ,QCBAD_QT  = SUM(CAST(ISNULL(Q.QCBAD_QT, 0) AS DECIMAL(19,6)))      -- 불합격수량
    ,SAMPLE_QT = SUM(CAST(ISNULL(Q.SAMPLE_QT, 0) AS DECIMAL(19,6)))     -- 시료수
    ,INSP_CNT  = COUNT(*)
    ,NG_CNT    = SUM(CASE WHEN ISNULL(Q.ACCEPT_YN, N'1') = N'0' THEN 1 ELSE 0 END)
INTO #QC
FROM        #PRD      P
INNER JOIN  LQC_INSP  Q WITH (NOLOCK)
       ON   Q.CO_CD = P.CO_CD AND Q.DOC_CD = P.DOC_CD
GROUP BY P.CO_CD, P.WO_CD;
CREATE CLUSTERED INDEX IX_QC ON #QC (CO_CD, WO_CD);

SELECT
     P.CO_CD
    ,P.WO_CD
    ,P.PROD_ITEM_CD
    ,D.BAD_CD
    ,BAD_QT  = SUM(CAST(ISNULL(D.BAD_QT, 0) AS DECIMAL(19,6)))
    ,BAD_CNT = COUNT(*)
INTO #BAD
FROM        #PRD        P
INNER JOIN  LQC_INSP_D  D WITH (NOLOCK)
       ON   D.CO_CD = P.CO_CD AND D.DOC_CD = P.DOC_CD
WHERE   D.USE_YN    = N'1'
  AND   D.EXPIRE_YN = N'1'
GROUP BY P.CO_CD, P.WO_CD, P.PROD_ITEM_CD, D.BAD_CD;
CREATE CLUSTERED INDEX IX_BAD ON #BAD (CO_CD, WO_CD);


/*==============================================================================================
  5. #INWH : 실적입고 (LPRDINWH)
==============================================================================================*/
SELECT
     P.CO_CD
    ,P.WO_CD
    ,INWH_QT  = SUM(CAST(ISNULL(N.INWH_QT, 0) AS DECIMAL(19,6)))
    ,INWH_CNT = COUNT(*)
INTO #INWH
FROM        #PRD      P
INNER JOIN  LPRDINWH  N WITH (NOLOCK)
       ON   N.CO_CD = P.CO_CD AND N.WR_CD = P.DOC_CD
WHERE   N.USE_YN    = N'1'
  AND   N.EXPIRE_YN = N'1'
GROUP BY P.CO_CD, P.WO_CD;
CREATE CLUSTERED INDEX IX_INWH ON #INWH (CO_CD, WO_CD);


/*==============================================================================================
  6. #BOM_SRC / #BOM_EXP : BOM 전개   [SBOM_WF 확정 (5), 무한루프 차단 (3)]
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

;WITH ROOTS AS ( SELECT DISTINCT CO_CD, PROD_ITEM_CD FROM #WO )
,EXP AS
(
    SELECT
         R.CO_CD
        ,ROOT_ITEM_CD = R.PROD_ITEM_CD
        ,LVL       = 1
        ,CHILD_CD  = B.ITEMCHILD_CD
        ,QTY_PER   = B.REAL_QT
        ,JUST_QT   = B.JUST_QT
        ,LOSS_RT   = B.LOSS_RT
        ,REAL_QT   = B.REAL_QT
        ,NODE_PATH = CAST(N'|' + B.ITEMPARENT_CD + N'|' + B.ITEMCHILD_CD + N'|' AS NVARCHAR(4000))
    FROM        ROOTS    R
    INNER JOIN  #BOM_SRC B ON B.CO_CD = R.CO_CD AND B.ITEMPARENT_CD = R.PROD_ITEM_CD
    UNION ALL
    SELECT
         E.CO_CD, E.ROOT_ITEM_CD
        ,LVL       = E.LVL + 1
        ,CHILD_CD  = B.ITEMCHILD_CD
        ,QTY_PER   = E.QTY_PER * B.REAL_QT
        ,JUST_QT   = B.JUST_QT
        ,LOSS_RT   = B.LOSS_RT
        ,REAL_QT   = B.REAL_QT
        ,NODE_PATH = CAST(E.NODE_PATH + B.ITEMCHILD_CD + N'|' AS NVARCHAR(4000))
    FROM        EXP      E
    INNER JOIN  #BOM_SRC B ON B.CO_CD = E.CO_CD AND B.ITEMPARENT_CD = E.CHILD_CD
    WHERE   @BOM_LEVEL_FG = N'A'
      AND   E.LVL < @BOM_MAX_LVL
      AND   E.NODE_PATH NOT LIKE N'%|' + B.ITEMCHILD_CD + N'|%'
)
SELECT
     CO_CD, ROOT_ITEM_CD, LVL, CHILD_CD, QTY_PER, JUST_QT, LOSS_RT, REAL_QT, NODE_PATH
    ,LEAF_YN = CASE WHEN NOT EXISTS (SELECT 1 FROM #BOM_SRC C
                                     WHERE C.CO_CD = EXP.CO_CD AND C.ITEMPARENT_CD = EXP.CHILD_CD)
                    THEN N'Y' ELSE N'N' END
INTO #BOM_EXP
FROM EXP
OPTION (MAXRECURSION 0);
CREATE CLUSTERED INDEX IX_BOM_EXP ON #BOM_EXP (CO_CD, ROOT_ITEM_CD, CHILD_CD);


/*==============================================================================================
  7. #MTL : 지시 x 자재별 실제사용량 + BOM 표준소요량
     [(4) 5-2 준용] 모품목=자품목 제외, USE_YN='1' AND EXPIRE_YN='1'
     표준소요량 = 주산물 총실적수량 x BOM 누적소요량
==============================================================================================*/
CREATE TABLE #MTL (
     CO_CD NVARCHAR(4), WO_CD NVARCHAR(12), PROD_ITEM_CD NVARCHAR(30)
    ,MTL_ITEM_CD NVARCHAR(30), SRC_FG NVARCHAR(10), USE_QT DECIMAL(19,6)
);

-- (a) 실적별사용자재보고
INSERT INTO #MTL
SELECT P.CO_CD, P.WO_CD, P.PROD_ITEM_CD, U.ITEM_CD, N'실적별'
      ,CAST(ISNULL(U.USE_QT, 0) AS DECIMAL(19,6))
FROM        #PRD     P
INNER JOIN  LMTL_USE U WITH (NOLOCK)
       ON   U.CO_CD = P.CO_CD AND U.WR_CD = P.DOC_CD
WHERE   U.USE_YN = N'1' AND U.EXPIRE_YN = N'1'
  AND   U.ITEM_CD <> P.PROD_ITEM_CD;

-- (b) 지시별사용자재보고 (실적별로 이미 잡힌 조합은 제외)
IF @MTL_SRC_FG = N'ALL'
INSERT INTO #MTL
SELECT W.CO_CD, W.WO_CD, W.PROD_ITEM_CD, U.ITEM_CD, N'지시별'
      ,CAST(ISNULL(U.USE_QT, 0) AS DECIMAL(19,6))
FROM        #WO        W
INNER JOIN  LMTL_USEWO U WITH (NOLOCK)
       ON   U.CO_CD = W.CO_CD AND U.WO_CD = W.WO_CD
WHERE   U.USE_YN = N'1' AND U.EXPIRE_YN = N'1'
  AND   U.ITEM_CD <> W.PROD_ITEM_CD
  AND   NOT EXISTS (SELECT 1 FROM #MTL M
                    WHERE M.CO_CD = W.CO_CD AND M.WO_CD = W.WO_CD AND M.MTL_ITEM_CD = U.ITEM_CD);

-- 원가대상 계정만
IF @ACCT_FG_ONLY = N'Y'
    DELETE M
    FROM        #MTL M
    INNER JOIN  SITEM I WITH (NOLOCK) ON I.CO_CD = M.CO_CD AND I.ITEM_CD = M.MTL_ITEM_CD
    WHERE I.ACCT_FG NOT IN (N'0', N'1', N'2', N'4', N'5', N'6');

CREATE CLUSTERED INDEX IX_MTL ON #MTL (CO_CD, WO_CD, MTL_ITEM_CD);


-- #MTLSUM : 지시 x 자재 단위로 표준 vs 실제 대사
;WITH ACT AS
(
    SELECT CO_CD, WO_CD, PROD_ITEM_CD, MTL_ITEM_CD, ACT_QT = SUM(USE_QT)
    FROM #MTL GROUP BY CO_CD, WO_CD, PROD_ITEM_CD, MTL_ITEM_CD
)
,STD AS
(
    SELECT
         W.CO_CD, W.WO_CD, W.PROD_ITEM_CD
        ,MTL_ITEM_CD = E.CHILD_CD
        ,BOM_LVL     = E.LVL
        ,BOM_QTY_PER = E.QTY_PER
        ,BOM_JUST_QT = E.JUST_QT
        ,BOM_LOSS_RT = E.LOSS_RT
        ,STD_QT      = CAST(ISNULL(S.MAIN_QT, 0) * E.QTY_PER AS DECIMAL(19,6))
    FROM        #WO      W
    INNER JOIN  #BOM_EXP E ON E.CO_CD = W.CO_CD AND E.ROOT_ITEM_CD = W.PROD_ITEM_CD
    LEFT  JOIN  #PRDSUM  S ON S.CO_CD = W.CO_CD AND S.WO_CD = W.WO_CD
    WHERE   ( @BOM_LEVEL_FG = N'S' AND E.LVL = 1 )
         OR ( @BOM_LEVEL_FG = N'A' AND E.LEAF_YN = N'Y' )
)
SELECT
     CO_CD        = ISNULL(S.CO_CD       , A.CO_CD)
    ,WO_CD        = ISNULL(S.WO_CD       , A.WO_CD)
    ,PROD_ITEM_CD = ISNULL(S.PROD_ITEM_CD, A.PROD_ITEM_CD)
    ,MTL_ITEM_CD  = ISNULL(S.MTL_ITEM_CD , A.MTL_ITEM_CD)
    ,BOM_LVL      = S.BOM_LVL
    ,BOM_QTY_PER  = S.BOM_QTY_PER                               -- 생산 1단위당 BOM 소요(원단위)
    ,BOM_JUST_QT  = S.BOM_JUST_QT
    ,BOM_LOSS_RT  = S.BOM_LOSS_RT
    ,STD_QT       = CAST(ISNULL(S.STD_QT, 0) AS DECIMAL(19,6))
    ,ACT_QT       = CAST(ISNULL(A.ACT_QT, 0) AS DECIMAL(19,6))
    ,MATCH_FG     = CASE WHEN S.MTL_ITEM_CD IS NULL THEN N'BOM외투입'
                         WHEN A.MTL_ITEM_CD IS NULL THEN N'미투입(BOM만)'
                         ELSE N'정상' END
INTO #MTLSUM
FROM        STD S
FULL OUTER JOIN ACT A
       ON   A.CO_CD = S.CO_CD AND A.WO_CD = S.WO_CD
      AND   A.PROD_ITEM_CD = S.PROD_ITEM_CD AND A.MTL_ITEM_CD = S.MTL_ITEM_CD
;
CREATE CLUSTERED INDEX IX_MTLSUM ON #MTLSUM (CO_CD, WO_CD, MTL_ITEM_CD);


/*==============================================================================================
  8. #YIELD : 지시별 수율 종합
==============================================================================================*/
SELECT
     W.CO_CD
    ,W.WO_CD
    ,W.DIV_CD
    ,W.PJT_CD
    ,W.PROD_ITEM_CD
    ,W.DEPT_CD
    ,W.WOC_FG
    ,W.DOC_FG
    ,W.ORD_DT
    ,W.COMP_DT
    ,S.FR_DOC_DT
    ,S.TO_DOC_DT

    -- 생산 수량
    ,WO_QT     = W.WO_QT
    ,MAIN_QT   = ISNULL(S.MAIN_QT  , 0)
    ,GOOD_QT   = ISNULL(S.GOOD_QT  , 0)
    ,BAD_QT    = ISNULL(S.BAD_QT   , 0)
    ,FTT_QT    = ISNULL(S.FTT_QT   , 0)
    ,REWORK_QT = ISNULL(S.REWORK_QT, 0)
    ,SUB_QT    = ISNULL(S.SUB_QT   , 0)
    ,PRD_CNT   = ISNULL(S.PRD_CNT  , 0)

    -- 검사
    ,QCRCV_QT  = ISNULL(Q.QCRCV_QT, 0)
    ,QCBAD_QT  = ISNULL(Q.QCBAD_QT, 0)
    ,INSP_CNT  = ISNULL(Q.INSP_CNT, 0)

    -- 입고
    ,INWH_QT   = ISNULL(N.INWH_QT, 0)

    -- 자재
    ,STD_MTL_QT = ISNULL(M.STD_QT, 0)
    ,ACT_MTL_QT = ISNULL(M.ACT_QT, 0)
    ,MTL_KIND   = ISNULL(M.MTL_KIND, 0)
    ,BOM_NG_CNT = ISNULL(M.NG_CNT, 0)

    -- ============ 수율 지표 ============
    ,ACHIEVE_RT = CAST(CASE WHEN W.WO_QT <> 0
                            THEN ISNULL(S.GOOD_QT,0) / W.WO_QT * 100 END AS DECIMAL(19,2))   -- 지시달성률
    ,GOOD_RT    = CAST(CASE WHEN ISNULL(S.MAIN_QT,0) <> 0
                            THEN ISNULL(S.GOOD_QT,0) / S.MAIN_QT * 100 END AS DECIMAL(19,2)) -- 양품률
    ,FTT_RT     = CAST(CASE WHEN ISNULL(S.MAIN_QT,0) <> 0
                            THEN ISNULL(S.FTT_QT,0)  / S.MAIN_QT * 100 END AS DECIMAL(19,2)) -- 직행률
    ,BAD_RT     = CAST(CASE WHEN ISNULL(S.MAIN_QT,0) <> 0
                            THEN ISNULL(S.BAD_QT,0)  / S.MAIN_QT * 100 END AS DECIMAL(19,2)) -- 불량률
    ,REWORK_RT  = CAST(CASE WHEN ISNULL(S.MAIN_QT,0) <> 0
                            THEN ISNULL(S.REWORK_QT,0) / S.MAIN_QT * 100 END AS DECIMAL(19,2))-- 재작업률
    ,QC_PASS_RT = CAST(CASE WHEN ISNULL(Q.QCRCV_QT,0) + ISNULL(Q.QCBAD_QT,0) <> 0
                            THEN ISNULL(Q.QCRCV_QT,0)
                               / (ISNULL(Q.QCRCV_QT,0) + ISNULL(Q.QCBAD_QT,0)) * 100 END AS DECIMAL(19,2))
    ,INWH_RT    = CAST(CASE WHEN ISNULL(S.GOOD_QT,0) <> 0
                            THEN ISNULL(N.INWH_QT,0) / S.GOOD_QT * 100 END AS DECIMAL(19,2)) -- 입고율
    ,MTL_YIELD_RT = CAST(CASE WHEN ISNULL(M.ACT_QT,0) <> 0
                              THEN ISNULL(M.STD_QT,0) / M.ACT_QT * 100 END AS DECIMAL(19,2)) -- BOM대비 자재수율
    ,MTL_LOSS_RT  = CAST(CASE WHEN ISNULL(M.ACT_QT,0) <> 0
                              THEN 100 - ISNULL(M.STD_QT,0) / M.ACT_QT * 100 END AS DECIMAL(19,2))
    ,RAW_YIELD_RT = CAST(CASE WHEN ISNULL(M.ACT_QT,0) <> 0
                              THEN ISNULL(S.MAIN_QT,0) / M.ACT_QT * 100 END AS DECIMAL(19,2)) -- 재료수율(참고) [(6)]
INTO #YIELD
FROM        #WO     W
LEFT  JOIN  #PRDSUM S ON S.CO_CD = W.CO_CD AND S.WO_CD = W.WO_CD
LEFT  JOIN  #QC     Q ON Q.CO_CD = W.CO_CD AND Q.WO_CD = W.WO_CD
LEFT  JOIN  #INWH   N ON N.CO_CD = W.CO_CD AND N.WO_CD = W.WO_CD
LEFT  JOIN  ( SELECT CO_CD, WO_CD
                    ,STD_QT   = SUM(STD_QT)
                    ,ACT_QT   = SUM(ACT_QT)
                    ,MTL_KIND = COUNT(DISTINCT MTL_ITEM_CD)
                    ,NG_CNT   = SUM(CASE WHEN MATCH_FG <> N'정상' THEN 1 ELSE 0 END)
              FROM #MTLSUM GROUP BY CO_CD, WO_CD ) M
       ON   M.CO_CD = W.CO_CD AND M.WO_CD = W.WO_CD
;
CREATE CLUSTERED INDEX IX_YIELD ON #YIELD (CO_CD, WO_CD);


/*==============================================================================================
  ** 쿼리 A : 생산지시별 작업수율 현황  (메인 보고서 / 1행 = 1작업지시)
==============================================================================================*/
SELECT
     N'[A] 생산지시별 작업수율'                     AS REPORT_NM
    ,Y.WO_CD                                        AS 작업지시번호
    ,Y.ORD_DT                                       AS 지시일
    ,Y.COMP_DT                                      AS 완료일
    ,Y.FR_DOC_DT                                    AS 최초실적일
    ,Y.TO_DOC_DT                                    AS 최종실적일
    ,D.DIV_NM                                       AS 사업장
    ,DP.DEPT_NM                                     AS 생산부서
    ,J.PJT_NM                                       AS 프로젝트
    ,CASE Y.WOC_FG WHEN N'0' THEN N'생산지시' WHEN N'2' THEN N'임가공지시'
                   WHEN N'4' THEN N'외주발주' WHEN N'5' THEN N'작업지시' END AS 지시구분
    ,CASE Y.DOC_FG WHEN N'0' THEN N'생산' WHEN N'1' THEN N'외주' END          AS 생산외주

    ,Y.PROD_ITEM_CD                                 AS 생산품번
    ,I.ITEM_NM                                      AS 생산품명
    ,I.ITEM_DC                                      AS 규격
    ,I.UNIT_DC                                      AS 단위
    ,G.ITEMGRP_NM                                   AS 품목군

    -- 수량
    ,Y.WO_QT                                        AS 지시수량
    ,Y.MAIN_QT                                      AS 실적수량_주산물
    ,Y.GOOD_QT                                      AS 양품수량
    ,Y.BAD_QT                                       AS 부적합수량
    ,Y.REWORK_QT                                    AS 재작업수량
    ,Y.FTT_QT                                       AS 직행수량
    ,Y.SUB_QT                                       AS 부산물수량
    ,Y.WO_QT - Y.GOOD_QT                            AS 미달수량
    ,Y.PRD_CNT                                      AS 실적건수

    -- 수율 (%)
    ,Y.ACHIEVE_RT                                   AS 지시달성률_PCT
    ,Y.GOOD_RT                                      AS 양품률_PCT
    ,Y.FTT_RT                                       AS 직행률_PCT
    ,Y.BAD_RT                                       AS 불량률_PCT
    ,Y.REWORK_RT                                    AS 재작업률_PCT

    -- 검사
    ,Y.INSP_CNT                                     AS 검사건수
    ,Y.QCRCV_QT                                     AS 검사합격수량
    ,Y.QCBAD_QT                                     AS 검사불합격수량
    ,Y.QC_PASS_RT                                   AS 검사합격률_PCT

    -- 입고
    ,Y.INWH_QT                                      AS 실적입고수량
    ,Y.INWH_RT                                      AS 입고율_PCT

    -- 자재
    ,Y.MTL_KIND                                     AS 투입자재종수
    ,Y.STD_MTL_QT                                   AS 자재표준소요량
    ,Y.ACT_MTL_QT                                   AS 자재실투입량
    ,Y.ACT_MTL_QT - Y.STD_MTL_QT                    AS 자재초과투입량
    ,Y.MTL_YIELD_RT                                 AS BOM대비자재수율_PCT
    ,Y.MTL_LOSS_RT                                  AS 자재LOSS율_PCT
    ,Y.RAW_YIELD_RT                                 AS 재료수율_참고_PCT
    ,Y.BOM_NG_CNT                                   AS BOM불일치자재수
FROM        #YIELD Y
LEFT  JOIN  SITEM    I  WITH (NOLOCK) ON I.CO_CD  = Y.CO_CD AND I.ITEM_CD = Y.PROD_ITEM_CD
LEFT  JOIN  SITEMGRP G  WITH (NOLOCK) ON G.CO_CD  = I.CO_CD AND G.ITEMGRP_CD = I.ITEMGRP_CD
LEFT  JOIN  SDIV     D  WITH (NOLOCK) ON D.CO_CD  = Y.CO_CD AND D.DIV_CD  = Y.DIV_CD
LEFT  JOIN  SDEPT    DP WITH (NOLOCK) ON DP.CO_CD = Y.CO_CD AND DP.DEPT_CD = Y.DEPT_CD
LEFT  JOIN  SPJT     J  WITH (NOLOCK) ON J.CO_CD  = Y.CO_CD AND J.PJT_CD  = Y.PJT_CD
ORDER BY Y.ORD_DT, Y.WO_CD
;


/*==============================================================================================
  ** 쿼리 B : 지시 x 공정/작업장별 수율 (공정 순서별 추이)
     LWO_WF_D.WOOP_SQ(전개순번) 순으로 전공정 대비 당공정 실적비율을 계산한다.
==============================================================================================*/
;WITH OPR AS
(
    SELECT
         W.CO_CD, W.WO_CD, W.PROD_ITEM_CD
        ,WD.WOOP_SQ, WD.BASELOC_CD, WD.LOC_CD
        ,OP_WO_QT = CAST(ISNULL(WD.ITEM_QT, 0) AS DECIMAL(19,6))
        ,WD.DOC_ST
        ,WD.EQUIP_CD
    FROM        #WO      W
    INNER JOIN  LWO_WF_D WD WITH (NOLOCK)
           ON   WD.CO_CD = W.CO_CD AND WD.WO_CD = W.WO_CD
    WHERE   WD.USE_YN = N'1'
)
,OPRPRD AS
(
    SELECT
         P.CO_CD, P.WO_CD, P.BASELOC_CD, P.LOC_CD
        ,MAIN_QT   = SUM(CASE WHEN P.SUB_TP = N'0'                     THEN P.PRD_QT ELSE 0 END)
        ,GOOD_QT   = SUM(CASE WHEN P.SUB_TP = N'0' AND P.BAD_YN = N'0' THEN P.PRD_QT ELSE 0 END)
        ,BAD_QT    = SUM(CASE WHEN P.SUB_TP = N'0' AND P.BAD_YN = N'1' THEN P.PRD_QT ELSE 0 END)
        ,REWORK_QT = SUM(CASE WHEN P.REWORK_YN = N'1'                  THEN P.PRD_QT ELSE 0 END)
        ,PRD_CNT   = COUNT(*)
    FROM   #PRD P
    GROUP BY P.CO_CD, P.WO_CD, P.BASELOC_CD, P.LOC_CD
)
,J AS
(
    SELECT
         O.CO_CD, O.WO_CD, O.PROD_ITEM_CD, O.WOOP_SQ, O.BASELOC_CD, O.LOC_CD
        ,O.OP_WO_QT, O.DOC_ST, O.EQUIP_CD
        ,MAIN_QT   = ISNULL(R.MAIN_QT  , 0)
        ,GOOD_QT   = ISNULL(R.GOOD_QT  , 0)
        ,BAD_QT    = ISNULL(R.BAD_QT   , 0)
        ,REWORK_QT = ISNULL(R.REWORK_QT, 0)
        ,PRD_CNT   = ISNULL(R.PRD_CNT  , 0)
        ,PREV_QT   = LAG(ISNULL(R.GOOD_QT, 0)) OVER (PARTITION BY O.CO_CD, O.WO_CD
                                                     ORDER BY O.WOOP_SQ, O.BASELOC_CD, O.LOC_CD)
    FROM        OPR    O
    LEFT  JOIN  OPRPRD R
           ON   R.CO_CD = O.CO_CD AND R.WO_CD = O.WO_CD
          AND   R.BASELOC_CD = O.BASELOC_CD AND R.LOC_CD = O.LOC_CD
)
SELECT
     N'[B] 지시 x 공정별 수율'                      AS REPORT_NM
    ,J.WO_CD                                        AS 작업지시번호
    ,J.PROD_ITEM_CD                                 AS 생산품번
    ,I.ITEM_NM                                      AS 생산품명
    ,J.WOOP_SQ                                      AS 공정순번
    ,J.BASELOC_CD                                   AS 공정코드
    ,BL.BASELOC_NM                                  AS 공정명
    ,J.LOC_CD                                       AS 작업장코드
    ,LC.LOC_NM                                      AS 작업장명
    ,J.EQUIP_CD                                     AS 설비코드
    ,CASE J.DOC_ST WHEN N'0' THEN N'미처리' WHEN N'1' THEN N'처리' END AS 지시상태

    ,J.OP_WO_QT                                     AS 공정지시수량
    ,J.MAIN_QT                                      AS 공정실적수량
    ,J.GOOD_QT                                      AS 공정양품수량
    ,J.BAD_QT                                       AS 공정부적합수량
    ,J.REWORK_QT                                    AS 공정재작업수량
    ,J.PRD_CNT                                      AS 실적건수

    ,CAST(CASE WHEN J.OP_WO_QT <> 0 THEN J.GOOD_QT / J.OP_WO_QT * 100 END AS DECIMAL(19,2)) AS 공정달성률_PCT
    ,CAST(CASE WHEN J.MAIN_QT  <> 0 THEN J.GOOD_QT / J.MAIN_QT  * 100 END AS DECIMAL(19,2)) AS 공정양품률_PCT
    ,J.PREV_QT                                      AS 전공정양품수량
    ,CAST(CASE WHEN ISNULL(J.PREV_QT,0) <> 0
               THEN J.GOOD_QT / J.PREV_QT * 100 END AS DECIMAL(19,2))                       AS 공정수율_PCT
    ,CAST(CASE WHEN ISNULL(J.PREV_QT,0) <> 0
               THEN 100 - J.GOOD_QT / J.PREV_QT * 100 END AS DECIMAL(19,2))                 AS 공정LOSS율_PCT
    ,J.PREV_QT - J.GOOD_QT                          AS 공정손실수량
FROM        J
LEFT  JOIN  SITEM    I  WITH (NOLOCK) ON I.CO_CD  = J.CO_CD AND I.ITEM_CD = J.PROD_ITEM_CD
LEFT  JOIN  SBASELOC BL WITH (NOLOCK) ON BL.CO_CD = J.CO_CD AND BL.BASELOC_CD = J.BASELOC_CD
LEFT  JOIN  SLOC     LC WITH (NOLOCK) ON LC.CO_CD = J.CO_CD AND LC.LOC_CD = J.LOC_CD
                                     AND LC.BASELOC_CD = J.BASELOC_CD
ORDER BY J.WO_CD, J.WOOP_SQ, J.BASELOC_CD, J.LOC_CD
;


/*==============================================================================================
  ** 쿼리 C : 지시 x 자재별 원단위 / 자재수율 상세
==============================================================================================*/
SELECT
     N'[C] 지시 x 자재별 원단위 분석'               AS REPORT_NM
    ,M.WO_CD                                        AS 작업지시번호
    ,Y.ORD_DT                                       AS 지시일
    ,M.PROD_ITEM_CD                                 AS 생산품번
    ,PI.ITEM_NM                                     AS 생산품명
    ,PI.UNIT_DC                                     AS 생산단위
    ,Y.MAIN_QT                                      AS 생산실적수량

    ,M.BOM_LVL                                      AS BOM레벨
    ,M.MTL_ITEM_CD                                  AS 자재품번
    ,MI.ITEM_NM                                     AS 자재품명
    ,MI.ITEM_DC                                     AS 자재규격
    ,MI.UNIT_DC                                     AS 자재단위
    ,MG.ITEMGRP_NM                                  AS 자재품목군
    ,M.MATCH_FG                                     AS 대사구분

    ,M.BOM_JUST_QT                                  AS BOM정미수량
    ,M.BOM_LOSS_RT                                  AS BOM로스율_PCT
    ,M.BOM_QTY_PER                                  AS BOM원단위                -- 생산 1단위당 표준
    ,CAST(CASE WHEN Y.MAIN_QT <> 0 THEN M.ACT_QT / Y.MAIN_QT END AS DECIMAL(19,6)) AS 실제원단위
    ,CAST(CASE WHEN ISNULL(M.BOM_QTY_PER,0) <> 0 AND Y.MAIN_QT <> 0
               THEN (M.ACT_QT / Y.MAIN_QT - M.BOM_QTY_PER) / M.BOM_QTY_PER * 100
               END AS DECIMAL(19,2))                AS 원단위편차_PCT

    ,M.STD_QT                                       AS 표준소요량
    ,M.ACT_QT                                       AS 실제사용량
    ,M.ACT_QT - M.STD_QT                            AS 초과사용량
    ,CAST(CASE WHEN M.ACT_QT <> 0 THEN M.STD_QT / M.ACT_QT * 100 END AS DECIMAL(19,2))       AS 자재수율_PCT
    ,CAST(CASE WHEN M.ACT_QT <> 0 THEN 100 - M.STD_QT / M.ACT_QT * 100 END AS DECIMAL(19,2)) AS 자재LOSS율_PCT
    ,CAST(ISNULL(MI.PURCH_UM, 0) AS DECIMAL(19,6))  AS 구매단가
    ,(M.ACT_QT - M.STD_QT) * CAST(ISNULL(MI.PURCH_UM, 0) AS DECIMAL(19,6)) AS 초과투입금액
FROM        #MTLSUM  M
LEFT  JOIN  #YIELD   Y  ON Y.CO_CD  = M.CO_CD AND Y.WO_CD   = M.WO_CD
LEFT  JOIN  SITEM    PI WITH (NOLOCK) ON PI.CO_CD = M.CO_CD AND PI.ITEM_CD = M.PROD_ITEM_CD
LEFT  JOIN  SITEM    MI WITH (NOLOCK) ON MI.CO_CD = M.CO_CD AND MI.ITEM_CD = M.MTL_ITEM_CD
LEFT  JOIN  SITEMGRP MG WITH (NOLOCK) ON MG.CO_CD = MI.CO_CD AND MG.ITEMGRP_CD = MI.ITEMGRP_CD
ORDER BY M.WO_CD, M.BOM_LVL, M.MTL_ITEM_CD
;


/*==============================================================================================
  ** 쿼리 D : 불량유형별 Pareto (불량그룹 -> 불량코드)
     LBAD(불량유형) / LBADGRP(불량그룹) 은 명세서 누락분으로 API 규약서(2)에서 구조 확인.
     미존재 사이트에서는 코드만 출력한다.
==============================================================================================*/
IF OBJECT_ID(N'dbo.LBAD', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
    ;WITH B AS
    (
        SELECT B.CO_CD, B.BAD_CD
              ,BAD_QT = SUM(B.BAD_QT), BAD_CNT = SUM(B.BAD_CNT)
              ,WO_CNT = COUNT(DISTINCT B.WO_CD), ITM_CNT = COUNT(DISTINCT B.PROD_ITEM_CD)
        FROM   #BAD B GROUP BY B.CO_CD, B.BAD_CD
    )
    SELECT
         N''[D] 불량유형별 Pareto''                     AS REPORT_NM
        ,GR.BADGRP_NM                                   AS 불량그룹
        ,B.BAD_CD                                       AS 불량코드
        ,L.BAD_NM                                       AS 불량유형명
        ,B.BAD_QT                                       AS 불량수량
        ,B.BAD_CNT                                      AS 발생건수
        ,B.WO_CNT                                       AS 발생지시수
        ,B.ITM_CNT                                      AS 발생품목수
        ,CAST(B.BAD_QT / NULLIF(SUM(B.BAD_QT) OVER (), 0) * 100 AS DECIMAL(19,2)) AS 구성비_PCT
        ,CAST(SUM(B.BAD_QT) OVER (ORDER BY B.BAD_QT DESC ROWS UNBOUNDED PRECEDING)
              / NULLIF(SUM(B.BAD_QT) OVER (), 0) * 100 AS DECIMAL(19,2))          AS 누적구성비_PCT
        ,ROW_NUMBER() OVER (ORDER BY B.BAD_QT DESC)     AS 순위
    FROM        B
    LEFT  JOIN  dbo.LBAD L WITH (NOLOCK) ON L.CO_CD = B.CO_CD AND L.BAD_CD = B.BAD_CD
    LEFT  JOIN  dbo.LBADGRP GR WITH (NOLOCK) ON GR.CO_CD = L.CO_CD AND GR.BADGRP_CD = L.BADGRP_CD
    ORDER BY B.BAD_QT DESC';

    IF OBJECT_ID(N'dbo.LBADGRP', N'U') IS NULL
        SET @SQL = REPLACE(REPLACE(@SQL, N'GR.BADGRP_NM', N'CAST(NULL AS NVARCHAR(40))'),
                    N'LEFT  JOIN  dbo.LBADGRP GR WITH (NOLOCK) ON GR.CO_CD = L.CO_CD AND GR.BADGRP_CD = L.BADGRP_CD', N'');

    EXEC sp_executesql @SQL;
END
ELSE
BEGIN
    SELECT
         N'[D] 불량유형별 Pareto'                       AS REPORT_NM
        ,CAST(NULL AS NVARCHAR(40))                     AS 불량그룹
        ,B.BAD_CD                                       AS 불량코드
        ,CAST(NULL AS NVARCHAR(40))                     AS 불량유형명
        ,SUM(B.BAD_QT)                                  AS 불량수량
        ,SUM(B.BAD_CNT)                                 AS 발생건수
        ,COUNT(DISTINCT B.WO_CD)                        AS 발생지시수
        ,COUNT(DISTINCT B.PROD_ITEM_CD)                 AS 발생품목수
    FROM   #BAD B
    GROUP BY B.CO_CD, B.BAD_CD
    ORDER BY 불량수량 DESC;
END


/*==============================================================================================
  ** 쿼리 E : 생산품목별 수율 집계 및 편차 (지시 간 산포 확인)
==============================================================================================*/
SELECT
     N'[E] 품목별 수율 집계'                        AS REPORT_NM
    ,Y.PROD_ITEM_CD                                 AS 생산품번
    ,I.ITEM_NM                                      AS 생산품명
    ,I.ITEM_DC                                      AS 규격
    ,I.UNIT_DC                                      AS 단위
    ,G.ITEMGRP_NM                                   AS 품목군
    ,COUNT(*)                                       AS 지시건수

    ,SUM(Y.WO_QT)                                   AS 지시수량계
    ,SUM(Y.MAIN_QT)                                 AS 실적수량계
    ,SUM(Y.GOOD_QT)                                 AS 양품수량계
    ,SUM(Y.BAD_QT)                                  AS 부적합수량계
    ,SUM(Y.REWORK_QT)                               AS 재작업수량계

    ,CAST(CASE WHEN SUM(Y.WO_QT)   <> 0 THEN SUM(Y.GOOD_QT) / SUM(Y.WO_QT)   * 100 END AS DECIMAL(19,2)) AS 지시달성률_PCT
    ,CAST(CASE WHEN SUM(Y.MAIN_QT) <> 0 THEN SUM(Y.GOOD_QT) / SUM(Y.MAIN_QT) * 100 END AS DECIMAL(19,2)) AS 양품률_PCT
    ,CAST(CASE WHEN SUM(Y.MAIN_QT) <> 0 THEN SUM(Y.FTT_QT)  / SUM(Y.MAIN_QT) * 100 END AS DECIMAL(19,2)) AS 직행률_PCT
    ,CAST(CASE WHEN SUM(Y.MAIN_QT) <> 0 THEN SUM(Y.BAD_QT)  / SUM(Y.MAIN_QT) * 100 END AS DECIMAL(19,2)) AS 불량률_PCT

    -- 지시 간 산포 : 평균/최소/최대/표준편차
    ,CAST(AVG(Y.GOOD_RT)    AS DECIMAL(19,2))       AS 양품률_평균_PCT
    ,CAST(MIN(Y.GOOD_RT)    AS DECIMAL(19,2))       AS 양품률_최소_PCT
    ,CAST(MAX(Y.GOOD_RT)    AS DECIMAL(19,2))       AS 양품률_최대_PCT
    ,CAST(STDEV(Y.GOOD_RT)  AS DECIMAL(19,2))       AS 양품률_표준편차

    ,SUM(Y.STD_MTL_QT)                              AS 자재표준소요계
    ,SUM(Y.ACT_MTL_QT)                              AS 자재실투입계
    ,CAST(CASE WHEN SUM(Y.ACT_MTL_QT) <> 0
               THEN SUM(Y.STD_MTL_QT) / SUM(Y.ACT_MTL_QT) * 100 END AS DECIMAL(19,2)) AS BOM대비자재수율_PCT
    ,CAST(AVG(Y.MTL_LOSS_RT) AS DECIMAL(19,2))      AS 자재LOSS율_평균_PCT
    ,CAST(MAX(Y.MTL_LOSS_RT) AS DECIMAL(19,2))      AS 자재LOSS율_최대_PCT
FROM        #YIELD   Y
LEFT  JOIN  SITEM    I WITH (NOLOCK) ON I.CO_CD = Y.CO_CD AND I.ITEM_CD = Y.PROD_ITEM_CD
LEFT  JOIN  SITEMGRP G WITH (NOLOCK) ON G.CO_CD = I.CO_CD AND G.ITEMGRP_CD = I.ITEMGRP_CD
GROUP BY Y.CO_CD, Y.PROD_ITEM_CD, I.ITEM_NM, I.ITEM_DC, I.UNIT_DC, G.ITEMGRP_NM
ORDER BY 양품률_PCT
;


/*==============================================================================================
  ** 쿼리 F : 수율 이상 지시 (임계치 미달 / 초과)
==============================================================================================*/
SELECT
     N'[F] 수율 이상 지시'                          AS REPORT_NM
    ,Y.WO_CD                                        AS 작업지시번호
    ,Y.ORD_DT                                       AS 지시일
    ,DP.DEPT_NM                                     AS 생산부서
    ,Y.PROD_ITEM_CD                                 AS 생산품번
    ,I.ITEM_NM                                      AS 생산품명
    ,이상유형 = CASE
          WHEN ISNULL(Y.MAIN_QT, 0) = 0                          THEN N'1.실적없음(지시 미착수/미마감)'
          WHEN Y.GOOD_RT    < @TH_GOOD                           THEN N'2.양품률 미달'
          WHEN Y.ACHIEVE_RT < @TH_ACHIEVE                        THEN N'3.지시달성률 미달'
          WHEN Y.MTL_LOSS_RT > @TH_MTL_LOSS                      THEN N'4.자재LOSS 초과'
          WHEN Y.BOM_NG_CNT > 0                                  THEN N'5.BOM 불일치 자재 존재'
          WHEN ISNULL(Y.ACT_MTL_QT, 0) = 0 AND Y.MAIN_QT > 0     THEN N'6.자재사용보고 누락'
          WHEN Y.INWH_RT IS NOT NULL AND Y.INWH_RT < 99          THEN N'7.실적입고 미완료'
          WHEN Y.QC_PASS_RT IS NOT NULL AND Y.QC_PASS_RT < 100   THEN N'8.검사 불합격 발생'
          ELSE NULL END
    ,Y.WO_QT                                        AS 지시수량
    ,Y.MAIN_QT                                      AS 실적수량
    ,Y.GOOD_QT                                      AS 양품수량
    ,Y.BAD_QT                                       AS 부적합수량
    ,Y.ACHIEVE_RT                                   AS 지시달성률_PCT
    ,Y.GOOD_RT                                      AS 양품률_PCT
    ,Y.MTL_YIELD_RT                                 AS 자재수율_PCT
    ,Y.MTL_LOSS_RT                                  AS 자재LOSS율_PCT
    ,Y.ACT_MTL_QT - Y.STD_MTL_QT                    AS 자재초과투입량
    ,Y.BOM_NG_CNT                                   AS BOM불일치자재수
    ,Y.INWH_RT                                      AS 입고율_PCT
    ,Y.QC_PASS_RT                                   AS 검사합격률_PCT
FROM        #YIELD Y
LEFT  JOIN  SITEM I  WITH (NOLOCK) ON I.CO_CD  = Y.CO_CD AND I.ITEM_CD  = Y.PROD_ITEM_CD
LEFT  JOIN  SDEPT DP WITH (NOLOCK) ON DP.CO_CD = Y.CO_CD AND DP.DEPT_CD = Y.DEPT_CD
WHERE   ISNULL(Y.MAIN_QT, 0) = 0
   OR   Y.GOOD_RT    < @TH_GOOD
   OR   Y.ACHIEVE_RT < @TH_ACHIEVE
   OR   Y.MTL_LOSS_RT > @TH_MTL_LOSS
   OR   Y.BOM_NG_CNT > 0
   OR   (ISNULL(Y.ACT_MTL_QT, 0) = 0 AND Y.MAIN_QT > 0)
   OR   (Y.INWH_RT IS NOT NULL AND Y.INWH_RT < 99)
   OR   (Y.QC_PASS_RT IS NOT NULL AND Y.QC_PASS_RT < 100)
ORDER BY ISNULL(Y.GOOD_RT, -1), Y.MTL_LOSS_RT DESC
;


/*==============================================================================================
  ** 쿼리 G : 월별 수율 추이 (품목군 / 부서별)
==============================================================================================*/
SELECT
     N'[G] 월별 수율 추이'                          AS REPORT_NM
    ,P.DOC_YM                                       AS 실적년월
    ,G.ITEMGRP_NM                                   AS 품목군
    ,DP.DEPT_NM                                     AS 생산부서
    ,COUNT(DISTINCT P.WO_CD)                        AS 지시건수
    ,SUM(CASE WHEN P.SUB_TP = N'0'                     THEN P.PRD_QT ELSE 0 END) AS 실적수량
    ,SUM(CASE WHEN P.SUB_TP = N'0' AND P.BAD_YN = N'0' THEN P.PRD_QT ELSE 0 END) AS 양품수량
    ,SUM(CASE WHEN P.SUB_TP = N'0' AND P.BAD_YN = N'1' THEN P.PRD_QT ELSE 0 END) AS 부적합수량
    ,SUM(CASE WHEN P.REWORK_YN = N'1'                  THEN P.PRD_QT ELSE 0 END) AS 재작업수량
    ,CAST(CASE WHEN SUM(CASE WHEN P.SUB_TP = N'0' THEN P.PRD_QT ELSE 0 END) <> 0
               THEN SUM(CASE WHEN P.SUB_TP = N'0' AND P.BAD_YN = N'0' THEN P.PRD_QT ELSE 0 END)
                  / SUM(CASE WHEN P.SUB_TP = N'0' THEN P.PRD_QT ELSE 0 END) * 100
               END AS DECIMAL(19,2))                AS 양품률_PCT
    ,CAST(CASE WHEN SUM(CASE WHEN P.SUB_TP = N'0' THEN P.PRD_QT ELSE 0 END) <> 0
               THEN SUM(CASE WHEN P.SUB_TP = N'0' AND P.BAD_YN = N'1' THEN P.PRD_QT ELSE 0 END)
                  / SUM(CASE WHEN P.SUB_TP = N'0' THEN P.PRD_QT ELSE 0 END) * 100
               END AS DECIMAL(19,2))                AS 불량률_PCT
FROM        #PRD     P
LEFT  JOIN  SITEM    I  WITH (NOLOCK) ON I.CO_CD  = P.CO_CD AND I.ITEM_CD  = P.PROD_ITEM_CD
LEFT  JOIN  SITEMGRP G  WITH (NOLOCK) ON G.CO_CD  = I.CO_CD AND G.ITEMGRP_CD = I.ITEMGRP_CD
LEFT  JOIN  SDEPT    DP WITH (NOLOCK) ON DP.CO_CD = P.CO_CD AND DP.DEPT_CD = P.DEPT_CD
GROUP BY P.DOC_YM, G.ITEMGRP_NM, DP.DEPT_NM
ORDER BY P.DOC_YM, G.ITEMGRP_NM, DP.DEPT_NM
;


DROP TABLE #WO, #PRD, #PRDSUM, #QC, #BAD, #INWH, #BOM_SRC, #BOM_EXP, #MTL, #MTLSUM, #YIELD;
GO


/*==============================================================================================
  [ 부록 1 ] 수율 지표 해석 가이드
  ----------------------------------------------------------------------------------------------
   지표                 정상범위(예)  낮을 때 의심 원인
   -------------------  ------------  ----------------------------------------------------------
   지시달성률           95~105%       지시 과다/과소, 미마감 지시, 분할 실적
   양품률               97% 이상      공정 불량, 설비 이상, 작업자 숙련도
   직행률(FTT)          95% 이상      재작업 다발 -> 양품률은 높아도 원가는 악화
   검사합격률           99% 이상      수입검사/공정검사 기준 또는 자재 품질
   입고율               100%          실적입고 누락, 재공 미처리
   BOM대비자재수율      95~100%       BOM 미갱신, 과투입, 자재 반납 미처리
   자재LOSS율           5% 이하       현장 손실, 대체품 투입, 계량 오차
   공정수율             99% 이상      특정 공정 병목/손실 (공정순번으로 위치 특정)

   * 자재수율 100% 초과 = BOM 소요보다 적게 투입 = BOM 과다 등록 의심 (절감이 아닐 수 있음)
   * 직행률과 양품률의 괴리가 크면 재작업 비용이 원가에 숨어 있다는 뜻이다.


  [ 부록 2 ] 도입 전 검증 쿼리
  ----------------------------------------------------------------------------------------------
  -- (1) 테이블 존재 확인
     SELECT name FROM sys.tables
     WHERE name IN ('LWO_WF','LWO_WF_D','LORCV_H','LQC_INSP','LQC_INSP_D','LBAD',
                    'LPRDINWH','LMTL_USE','LMTL_USEWO','SBOM_WF','SBOM')
     ORDER BY name;

  -- (2) 실적 플래그 분포 (수율 분해의 전제)
     SELECT SUB_TP, BAD_YN, REWORK_YN, QC_FG, COUNT(*) CNT, SUM(ITEM_QT) QT
     FROM   LORCV_H
     WHERE  CO_CD='1000' AND USE_YN='1' AND EXPIRE_YN='1'
       AND  DOC_DT BETWEEN '20260101' AND '20261231'
     GROUP BY SUB_TP, BAD_YN, REWORK_YN, QC_FG
     ORDER BY 1,2,3,4;
     --> BAD_YN/REWORK_YN 이 전부 '0' 이면 해당 사이트는 부적합/재작업을 실적에 구분하지 않는다.
     --   이 경우 양품률/직행률은 항상 100% 가 되므로 LQC_INSP(검사) 기준으로 봐야 한다.

  -- (3) 검사 운영 여부
     SELECT COUNT(*) 검사건수, SUM(QCRCV_QT) 합격, SUM(QCBAD_QT) 불합격
     FROM   LQC_INSP WHERE CO_CD='1000' AND DOC_DT BETWEEN '20260101' AND '20261231';

  -- (4) 공정 전개 운영 여부 (쿼리 B 의 전제)
     SELECT WO_CD, COUNT(*) 공정수, MIN(WOOP_SQ) FR, MAX(WOOP_SQ) TO
     FROM   LWO_WF_D WHERE CO_CD='1000' AND USE_YN='1'
     GROUP BY WO_CD HAVING COUNT(*) > 1;
     --> 결과가 없으면 단일공정 운영이므로 쿼리 B 는 의미가 없다.

  -- (5) BOM 등록률 (자재수율의 전제)
     SELECT COUNT(DISTINCT W.ITEM_CD) 지시품목수,
            COUNT(DISTINCT B.ITEMPARENT_CD) BOM등록품목수
     FROM   LWO_WF W LEFT OUTER JOIN SBOM_WF B
            ON B.CO_CD=W.CO_CD AND B.ITEMPARENT_CD=W.ITEM_CD AND B.USE_YN='1'
     WHERE  W.CO_CD='1000' AND W.ORD_DT BETWEEN '20260101' AND '20261231';


  [ 부록 3 ] 단위 불일치 주의
  ----------------------------------------------------------------------------------------------
  '재료수율(참고)' = 생산수량 / 총자재투입량 은 참조 쿼리(6)의 산식을 그대로 옮긴 것으로,
  생산품과 자재의 재고단위(SITEM.UNIT_DC)가 동일할 때만 의미가 있다.
  단위가 섞여 있으면 값 자체가 무의미하므로 아래로 확인 후 사용할 것.

     SELECT I.UNIT_DC 생산단위, C.UNIT_DC 자재단위, COUNT(*) CNT
     FROM   SBOM_WF B
            LEFT OUTER JOIN SITEM I ON I.CO_CD=B.CO_CD AND I.ITEM_CD=B.ITEMPARENT_CD
            LEFT OUTER JOIN SITEM C ON C.CO_CD=B.CO_CD AND C.ITEM_CD=B.ITEMCHILD_CD
     WHERE  B.CO_CD='1000' AND B.USE_YN='1'
     GROUP BY I.UNIT_DC, C.UNIT_DC ORDER BY CNT DESC;

  조립형 제조에서는 **BOM대비자재수율**(쿼리 A/C)만 사용하십시오.


  [ 부록 4 ] 일괄생산실적(간편생산실적) 사용 사이트
  ----------------------------------------------------------------------------------------------
  LPRODUCTION / LPRODUCTION_D 는 **작업지시 없이** 생산실적을 등록하는 기능이므로
  '생산지시별' 인 본 보고서의 대상이 아니다. 품목 단위 수율이 필요하면 아래를 별도 집계할 것.
  (컬럼 구성은 참조 쿼리(6)에서 확인됨)

      SELECT H.PITEM_CD, SUM(H.ITEM_QT) PRD_QT, SUM(D.USE_QT) USE_QT
            ,CASE WHEN SUM(D.USE_QT) <> 0
                  THEN SUM(H.ITEM_QT) / SUM(D.USE_QT) * 100 END 재료수율
        FROM LPRODUCTION H LEFT OUTER JOIN LPRODUCTION_D D
               ON D.CO_CD = H.CO_CD AND D.DOC_CD = H.DOC_CD AND D.CITEM_CD <> H.PITEM_CD
       WHERE H.CO_CD = @CO_CD AND H.DIV_CD = @DIV_CD
         AND H.DOC_DT BETWEEN @FR_DT AND @TO_DT
       GROUP BY H.PITEM_CD


  [ 부록 5 ] BATCH BOM 사이트
  ----------------------------------------------------------------------------------------------
  BATCH BOM 은 `SBOM_WF_B`, 배치수량은 모품목의 `SITEM.FOQ_QT` 이다.
  BOM 원단위는 JUST_QT / FOQ_QT 로 환산해야 하며, 아래로 정합성을 먼저 점검할 것.

      SELECT B.ITEMPARENT_CD, S.FOQ_QT, SUM(B.JUST_QT) 자품목합계
            ,S.FOQ_QT - SUM(B.JUST_QT) 차이
      FROM   SBOM_WF_B B LEFT OUTER JOIN SITEM S
             ON S.CO_CD = B.CO_CD AND S.ITEM_CD = B.ITEMPARENT_CD
      WHERE  B.CO_CD = @CO_CD
      GROUP BY B.ITEMPARENT_CD, S.FOQ_QT
      HAVING ABS(S.FOQ_QT - SUM(B.JUST_QT)) > 0.000001;


  [ 부록 6 ] 남은 확인 사항
  ----------------------------------------------------------------------------------------------
  1) 부산물(SUB_TP='1')은 수율 분모에서 제외하고 별도 표기한다.
     부산물도 산출물로 인정하는 업종이면 MAIN_QT 에 합산하도록 #PRDSUM 을 수정할 것.
  2) 재작업 실적을 별도 등록하지 않고 원 실적을 수정하는 사이트에서는 재작업률이 0 으로 나온다.
  3) 공정수율(쿼리 B)은 LWO_WF_D.WOOP_SQ 순서를 공정 순서로 가정한다.
     라우팅(LROUTING_D)의 공정순서와 다르면 LROUTING_D 기준으로 교체할 것.
  4) BOM 기준일자는 @BOM_BASE_DT 단일 스냅샷. 개정이 잦으면 기간을 나눠 실행할 것.
  5) 성능 인덱스
     LORCV_H    (CO_CD, DOC_DT) INCLUDE (WO_CD, ITEM_CD, ITEM_QT, BAD_YN, SUB_TP, REWORK_YN)
     LWO_WF_D   (CO_CD, WO_CD, WOOP_SQ)
     LQC_INSP   (CO_CD, DOC_CD)  /  LQC_INSP_D (CO_CD, DOC_CD, BAD_CD)
     LPRDINWH   (CO_CD, WR_CD)
     LMTL_USE   (CO_CD, WR_CD)   /  LMTL_USEWO (CO_CD, WO_CD)
     SBOM_WF    (CO_CD, ITEMPARENT_CD, START_DT, END_DT)

  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------

  -- (1) ★ 양품 산식의 전제. 부산물과 재작업이 어떻게 기록되는지 먼저 본다
     SELECT SUB_TP, REWORK_YN, BAD_YN, COUNT(*)
     FROM   LORCV_H WHERE CO_CD='1000' GROUP BY SUB_TP, REWORK_YN, BAD_YN;
     --> SUB_TP=1(부산물)은 양품에 합산하지 않는다. REWORK_YN=1 은 양품이지만 직행은 아니다.
        전 건이 0/0/0 이면 플래그를 운영하지 않는 사이트이고, 직행률은 의미가 없다.

  -- (2) 불량유형 마스터 존재 여부. 없으면 Pareto 구간이 비어 나온다
     SELECT OBJECT_ID('dbo.LBAD') LBAD;

  -- (3) 공정 순서 컬럼이 채워져 있는지. 비어 있으면 공정수율(전공정 대비)이 성립하지 않는다

  [ 한계 ]
  ----------------------------------------------------------------------------------------------

  1) **직행률(FTT)은 재작업 플래그에 의존한다.** 재작업을 별도 작업지시로 끊어 관리하는
     사이트에서는 원 지시의 직행률이 100% 로 나와 실제보다 좋아 보인다.

  2) **부산물(`SUB_TP=1`)을 양품에 넣지 않는다.** 부산물도 판매 실적으로 관리하는 사이트에서는
     수율이 실제보다 낮게 보인다. 필요하면 산식에서 부산물을 별도 축으로 뺄 것.

  3) **자재수율은 BOM 표준 대비**다. BOM 이 현행화되지 않으면 BOM 오차가 LOSS 로 잡힌다.
     수율이 전 품목에서 일관되게 나쁘면 공정이 아니라 BOM 을 먼저 의심할 것.

  4) **검사 실적을 남기지 않는 사이트**에서는 검사수율 구간이 통째로 비어 나온다.
     값이 없는 것과 합격률 100% 는 다르다 — 건수를 같이 보고 판단할 것.

==============================================================================================*/
