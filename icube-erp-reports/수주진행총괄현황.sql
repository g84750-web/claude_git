/*==============================================================================================
  [ iCUBE ] 수주 진행 총괄 현황 (Order-to-Cash + Procure-to-Pay)                    (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 수주 1건이 생산·조달·출고·회계·자금까지 어디를 지나 어디에 멈춰 있는지 한 줄로 본다.

     ①수주 → ②작업지시 → ③자재발주 → ④자재수급 → ⑤납품가능스케줄 → ⑥생산실적
            → ⑦자재사용(원가추적) → ⑧출고/납기잔량 → ⑨매출마감 → ⑩전표 → ⑪장부반영
            → ⑫채권/수금            ⑬지급(구매발주 대금)

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 전체 조인 체계 — 전부 실 쿼리/명세서로 확인된 키 ]
  ----------------------------------------------------------------------------------------------
   ① 수주        LSO / LSO_D              CO_CD + SO_NB (+ SO_SQ)
   ② 작업지시    LWO_WF                   SO_NB + LN_SQ   ->  LSO_D.SO_NB + SO_SQ
                 LWO_WF_D                 CO_CD + WO_CD + BASELOC_CD + LOC_CD
   ③ 자재청구    LWO_REQ_WF               CO_CD + DIV_CD + WO_CD + WOBOM_SQ + ITEM_CD
      구매청구    LPUR_REQ / LPUR_REQ_D    REQ_NB + REQ_SQ + ITEM_CD
      자재발주    LPO / LPO_D              REQ_NB + REQ_SQ + ITEM_CD  ->  PO_NB + PO_SQ
      자재입고    LSTOCK / LSTOCK_D        PO_NB + PO_SQ + ITEM_CD
   ④ 자재출고    LSTKMOVE / LSTKMOVE_D    WO_CD + ITEM_CD + WOBOM_SQ (+ITEMPARENT_CD)
      재고        VL_INVDIV / LINVTORY
   ⑥ 생산실적    LORCV_H                  CO_CD + WO_CD  (DOC_CD = 실적번호)
      실적입고    LPRDINWH                 CO_CD + WR_CD(=LORCV_H.DOC_CD)
   ⑦ 자재사용    LMTL_USE                 CO_CD + WR_CD(=실적번호) + WOBOM_SQ
      단가        CIV_PUR_TAV / LINV_TAV / LSTOCK_D   (@UM_BASE_FG)
   ⑧ 출고        LDELIVER / LDELIVER_D    SO_NB + SO_SQ + ITEM_CD  ->  ISU_NB + ISU_SQ
   ⑨ 매출마감    LSALECLS / LSALECLS_D    ISU_NB + ISU_SQ          ->  CLS_NB + CLS_SQ
   ⑩ 전표        ADOCUH / ADOCUD          LSALECLS.DOCU_DT + DOCU_SQ  ->  ADOCUH.ISU_DT + ISU_SQ
   ⑫ 수금/채권   LRCP / LRCP_D            LRCP_D.ISU_NB + ISU_SQ   ->  LDELIVER_D
                 LOPN_CRISU(기초채권) / LCR_ADJUST(채권조정) / LRCPFG(수금구분명)
                 ** 채권은 출고기준·마감기준 2종을 병행 산출하며, 최종(회계확정)은 마감기준 **
                    출고기준 : LDELIVER_D.ISUH_AM   (선행지표. 필터 SO_FG IN ('0','2','7'))
                    마감기준 : LSALECLS_D.CLSH_AM   ★최종 - 매출마감이 회계 확정 시점
                    수금     : LRCP_D.NORMAL_AM + BEFORE_AM  (필터 RCPAM_FG='0' 영업모듈)
                    출고-마감 차이 = 미마감 채권 (회계 미확정분) -> 마감 누락 통제 지표
   ⑬ 매입마감    LPURCLS / LPURCLS_D      RCV_NB + RCV_SQ          ->  LSTOCK_D
      지급        LPAY / LPAY_D            LPAY.DOCU_DT + DOCU_SQ   ->  ADOCUH
                 LOPN_PAY_CLS(기초채무)

  ----------------------------------------------------------------------------------------------
  [ 회계 연동 키 — 물류/영업 -> 전표 ]                                                      ★
  ----------------------------------------------------------------------------------------------
     매출마감 LSALECLS . DOCU_YN(기표여부) + DOCU_DT(기표일자) + DOCU_SQ(기표순번)
     매입마감 LPURCLS  . DOCU_YN           + DOCU_DT           + DOCU_SQ
     수금     LRCP     .                     DOCU_DT           + DOCU_SQ
     지급     LPAY     .                     DOCU_DT           + DOCU_SQ
                                    |
                                    +--> ADOCUH ( CO_CD + ISU_DT + ISU_SQ )   결의일자+결의번호
                                         ADOCUH.DOCU_ST  승인구분  (장부 반영 여부)
                                         ADOCUH.GET_FG   전표원인내역(연동구분)
                                         ADOCUD ( + LN_SQ ) DRCR_FG(차대) ACCT_CD(계정) ACCT_AM(금액)

     * LSALECLS 는 DOCU_DT_PLUS / DOCU_SQ_PLUS 도 보유 (부가세 등 추가전표). 필요 시 UNION.

  ----------------------------------------------------------------------------------------------
  [ 코드값 ]
  ----------------------------------------------------------------------------------------------
   EXPIRE_YN  '1'=유효/진행/미마감  '0'=만료/마감      <-- 한글명이 "마감여부"여도 동일
   USE_YN     '1'=사용              '0'=미사용
   ACCT_FG    0.원재료 1.부재료 2.제품 4.반제품 5.상품
   ODR_FG     0.구매 1.생산   /  REQODR_FG 0.구매 1.생산
   WOC_FG     0.생산지시 2.임가공 4.외주발주 5.작업지시
   DOC_ST     0.계획 1.확정 2.마감  (사이트 확인 필요 - API는 0.미처리/1.처리)
   BAD_YN     0.적합 1.부적합  /  SUB_TP 0.주산물 1.부산물
   DRCR_FG    차대구분 (1.차변 2.대변 - 실 DB 확인)
   DOCU_ST    승인구분 (미결/승인 - 실 DB 확인)
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD        NVARCHAR(4)   = N'1000'        -- 회사코드
    ,@DIV_CD       NVARCHAR(4)   = N'1000'        -- 사업장코드
    ,@BASE_DT      NVARCHAR(8)   = N'20260915'    -- 기준일자 (재고/지연 판정)

    ,@SO_FR_DT     NVARCHAR(8)   = N'20260101'    -- 수주일 FROM
    ,@SO_TO_DT     NVARCHAR(8)   = N'20261231'    -- 수주일 TO
    ,@DT_FG        NVARCHAR(1)   = N'S'           -- 기간기준 'S'=수주일 / 'D'=납기일

    ,@TR_CD        NVARCHAR(10)  = NULL           -- 거래처
    ,@SO_NB        NVARCHAR(12)  = NULL           -- 특정 수주번호
    ,@ITEM_CD      NVARCHAR(30)  = NULL           -- 특정 제품
    ,@PJT_CD       NVARCHAR(10)  = NULL           -- 프로젝트
    ,@PLN_CD       NVARCHAR(5)   = NULL           -- 영업담당자
    ,@OPEN_ONLY    NVARCHAR(1)   = N'N'           -- 'Y' = 미완결(잔량 있는) 수주만

    -- 재료비 단가 기준
    ,@UM_BASE_FG   NVARCHAR(3)   = N'INV'         -- 'INV' = 전월 재고평가 출고단가 (LINV_TAV.ISU_UM)
                                                  -- 'PUR' = 구매 가중평균 매입단가 (LSTOCK_D)
                                                  -- 'TAV' = 원가모듈 확정 출고단가 (CIV_PUR_TAV)
    ,@COST_YR      NVARCHAR(4)   = NULL           -- ('TAV') 원가 년도. NULL이면 LEFT(@BASE_DT,4)
    ,@COST_CHASU   NUMERIC(3,0)  = NULL           -- ('TAV') 원가 차수. NULL이면 최종차수
    ,@PUR_FR_DT    NVARCHAR(8)   = NULL           -- ('PUR') 매입 집계 FROM. NULL이면 @SO_FR_DT - 1년
    ,@TAV_YM       NVARCHAR(6)   = NULL           -- ('INV') 평가 기준 년월. NULL이면 전월
    ,@GISU         INT           = NULL           -- ('INV') 재고평가 기수. NULL = 자동 판정

    ,@LEAD_BUF_DD  INT           = 0              -- 납품가능일 산정 시 여유일수
;

SET @COST_YR   = ISNULL(@COST_YR, LEFT(@BASE_DT, 4));
SET @PUR_FR_DT = ISNULL(@PUR_FR_DT, CONVERT(NVARCHAR(8), DATEADD(YEAR, -1, CONVERT(DATE, @SO_FR_DT)), 112));
SET @TAV_YM    = ISNULL(@TAV_YM, CONVERT(NVARCHAR(6), DATEADD(MONTH, -1, CONVERT(DATE, @BASE_DT)), 112));

DECLARE @SQL NVARCHAR(MAX);
-- LINV_TAV 기수 필터 조각. GISU 컬럼이 없는 사이트에서는 빈 문자열로 남는다
DECLARE @GI_FLT NVARCHAR(100) = N'';

IF OBJECT_ID('tempdb..#SO')   IS NOT NULL DROP TABLE #SO;
IF OBJECT_ID('tempdb..#WO')   IS NOT NULL DROP TABLE #WO;
IF OBJECT_ID('tempdb..#PRD')  IS NOT NULL DROP TABLE #PRD;
IF OBJECT_ID('tempdb..#MTL')  IS NOT NULL DROP TABLE #MTL;
IF OBJECT_ID('tempdb..#UM')   IS NOT NULL DROP TABLE #UM;
IF OBJECT_ID('tempdb..#PO')   IS NOT NULL DROP TABLE #PO;
IF OBJECT_ID('tempdb..#ISU')  IS NOT NULL DROP TABLE #ISU;
IF OBJECT_ID('tempdb..#CLS')  IS NOT NULL DROP TABLE #CLS;
IF OBJECT_ID('tempdb..#AR')   IS NOT NULL DROP TABLE #AR;
IF OBJECT_ID('tempdb..#AP')   IS NOT NULL DROP TABLE #AP;
IF OBJECT_ID('tempdb..#TOT')  IS NOT NULL DROP TABLE #TOT;


/*==============================================================================================
  ① #SO : 수주 (기준 라인)
==============================================================================================*/
SELECT
     H.CO_CD
    ,DIV_CD    = H.DIV_CD
    ,SO_NB     = D.SO_NB
    ,SO_SQ     = D.SO_SQ
    ,SO_DT     = H.SO_DT
    ,DUE_DT    = D.DUE_DT
    ,TR_CD     = H.TR_CD
    ,PLN_CD    = H.PLN_CD
    ,EMP_CD    = H.EMP_CD
    ,DEPT_CD   = H.DEPT_CD
    ,PJT_CD    = ISNULL(NULLIF(D.PJT_CD, N''), H.PJT_CD)
    ,ITEM_CD   = D.ITEM_CD
    ,SO_QT     = CAST(ISNULL(D.SO_QT , 0) AS DECIMAL(19,6))
    ,ISU_QT    = CAST(ISNULL(D.ISU_QT, 0) AS DECIMAL(19,6))     -- 주문 대비 출고수량(ERP 관리 필드)
    ,OPEN_QT   = CAST(ISNULL(D.SO_QT,0) - ISNULL(D.ISU_QT,0) AS DECIMAL(19,6))   -- 수주잔량
    ,SO_UM     = CAST(ISNULL(D.SO_UM , 0) AS DECIMAL(19,6))
    ,SOG_AM    = CAST(ISNULL(D.SOG_AM, 0) AS DECIMAL(19,4))     -- 수주 공급가액
    ,SOV_AM    = CAST(ISNULL(D.SOV_AM, 0) AS DECIMAL(19,4))     -- 부가세
    ,SOH_AM    = CAST(ISNULL(D.SOH_AM, 0) AS DECIMAL(19,4))     -- 합계
    ,EXCH_CD   = D.EXCH_CD
    ,SO_ST     = D.EXPIRE_YN                                    -- '1'진행 '0'마감
    ,REMARK_DC = D.REMARK_DC
INTO #SO
FROM        LSO   H WITH (NOLOCK)
INNER JOIN  LSO_D D WITH (NOLOCK)
       ON   D.CO_CD = H.CO_CD AND D.SO_NB = H.SO_NB
WHERE   H.CO_CD = @CO_CD
  AND   ISNULL(D.USE_YN, N'1') = N'1'
  AND   (   (@DT_FG = N'S' AND H.SO_DT  BETWEEN @SO_FR_DT AND @SO_TO_DT)
         OR (@DT_FG = N'D' AND D.DUE_DT BETWEEN @SO_FR_DT AND @SO_TO_DT) )
  AND   (@DIV_CD  IS NULL OR H.DIV_CD  = @DIV_CD)
  AND   (@TR_CD   IS NULL OR H.TR_CD   = @TR_CD)
  AND   (@SO_NB   IS NULL OR D.SO_NB   = @SO_NB)
  AND   (@ITEM_CD IS NULL OR D.ITEM_CD = @ITEM_CD)
  AND   (@PLN_CD  IS NULL OR H.PLN_CD  = @PLN_CD)
  AND   (@PJT_CD  IS NULL OR ISNULL(NULLIF(D.PJT_CD, N''), H.PJT_CD) = @PJT_CD)
  AND   (@OPEN_ONLY = N'N' OR ISNULL(D.SO_QT,0) - ISNULL(D.ISU_QT,0) > 0)
;
CREATE CLUSTERED INDEX IX_SO ON #SO (CO_CD, SO_NB, SO_SQ);
CREATE NONCLUSTERED INDEX IX_SO2 ON #SO (CO_CD, ITEM_CD);

PRINT N'[①] 수주 라인 : ' + CAST((SELECT COUNT(*) FROM #SO) AS NVARCHAR(20));


/*==============================================================================================
  ② #WO : 작업지시 (수주 연결)  LWO_WF.SO_NB + LN_SQ  ->  수주
==============================================================================================*/
SELECT
     S.CO_CD
    ,S.SO_NB
    ,S.SO_SQ
    ,WO_CD    = W.WO_CD
    ,ORD_DT   = W.ORD_DT
    ,COMP_DT  = W.COMP_DT
    ,WO_ITEM  = W.ITEM_CD
    ,WO_QT    = CAST(ISNULL(W.ITEM_QT, 0) AS DECIMAL(19,6))
    ,DOC_ST   = W.DOC_ST                                        -- 0.계획 1.확정 2.마감
    ,WO_ST    = W.EXPIRE_YN                                     -- '1'생산진행 '0'생산마감
    ,WOC_FG   = W.WOC_FG
    ,LOT_NB   = W.LOT_NB
INTO #WO
FROM        #SO    S
INNER JOIN  LWO_WF W WITH (NOLOCK)
       ON   W.CO_CD = S.CO_CD
      AND   W.SO_NB = S.SO_NB
      AND   W.LN_SQ = S.SO_SQ
WHERE   ISNULL(W.USE_YN, N'1') = N'1'
;
CREATE CLUSTERED INDEX IX_WO ON #WO (CO_CD, WO_CD);
CREATE NONCLUSTERED INDEX IX_WO2 ON #WO (CO_CD, SO_NB, SO_SQ);

PRINT N'[②] 연결 작업지시 : ' + CAST((SELECT COUNT(*) FROM #WO) AS NVARCHAR(20))
    + N'  (수주-지시 미연결 수주는 ⑤ 스케줄에서 ''지시없음''으로 표시)';


/*==============================================================================================
  ⑥ #PRD : 생산실적 + 실적입고
==============================================================================================*/
SELECT
     W.CO_CD
    ,W.SO_NB
    ,W.SO_SQ
    ,W.WO_CD
    ,DOC_CD   = H.DOC_CD
    ,DOC_DT   = H.DOC_DT
    ,PRD_QT   = CAST(ISNULL(H.ITEM_QT, 0) AS DECIMAL(19,6))
    ,GOOD_QT  = CAST(CASE WHEN ISNULL(H.SUB_TP,N'0')=N'0' AND ISNULL(H.BAD_YN,N'0')=N'0'
                          THEN H.ITEM_QT ELSE 0 END AS DECIMAL(19,6))
    ,BAD_QT   = CAST(CASE WHEN ISNULL(H.BAD_YN,N'0')=N'1' THEN H.ITEM_QT ELSE 0 END AS DECIMAL(19,6))
    ,INWH_QT  = CAST(ISNULL(N.INWH_QT, 0) AS DECIMAL(19,6))
    ,INWH_DT  = N.INWH_DT
INTO #PRD
FROM        #WO     W
INNER JOIN  LORCV_H H WITH (NOLOCK)
       ON   H.CO_CD = W.CO_CD AND H.WO_CD = W.WO_CD
OUTER APPLY (
    SELECT INWH_QT = SUM(CAST(ISNULL(P.INWH_QT,0) AS DECIMAL(19,6)))
          ,INWH_DT = MAX(P.INWH_DT)
    FROM   LPRDINWH P WITH (NOLOCK)
    WHERE  P.CO_CD = H.CO_CD AND P.WR_CD = H.DOC_CD
      AND  P.USE_YN = N'1' AND P.EXPIRE_YN = N'1'
) N
WHERE   H.USE_YN = N'1' AND H.EXPIRE_YN = N'1'
;
CREATE CLUSTERED INDEX IX_PRD ON #PRD (CO_CD, DOC_CD);
CREATE NONCLUSTERED INDEX IX_PRD2 ON #PRD (CO_CD, SO_NB, SO_SQ);


/*==============================================================================================
  ③④ #PO : 자재 청구 -> 발주 -> 입고  (작업지시 기준)
       LWO_REQ_WF(청구)  +  LPUR_REQ_D->LPO_D(발주)  +  LSTOCK_D(입고)  +  LSTKMOVE_D(현장출고)
==============================================================================================*/
CREATE TABLE #PO (
     CO_CD    NVARCHAR(4)
    ,SO_NB    NVARCHAR(12)
    ,SO_SQ    NUMERIC(5,0)
    ,WO_CD    NVARCHAR(12)
    ,MTL_ITEM NVARCHAR(30)
    ,WOBOM_SQ NUMERIC(5,0)
    ,REQ_QT   DECIMAL(19,6) DEFAULT 0   -- 자재청구량
    ,RCVREQ_QT DECIMAL(19,6) DEFAULT 0  -- 청구 대비 출고량 (LWO_REQ_WF.RCV_QT)
    ,PO_QT    DECIMAL(19,6) DEFAULT 0   -- 발주량
    ,PORCV_QT DECIMAL(19,6) DEFAULT 0   -- 발주 대비 입고량
    ,ISU_QT   DECIMAL(19,6) DEFAULT 0   -- 현장 자재출고량 (LSTKMOVE_D)
    ,USE_QT   DECIMAL(19,6) DEFAULT 0   -- 실제 사용량 (LMTL_USE)
    ,PO_NB    NVARCHAR(12)
    ,PO_DUE   NVARCHAR(8)
    ,PO_ST    NVARCHAR(1)
);

-- 청구 (LWO_REQ_WF) : 명세서 누락 테이블이므로 존재 확인 후 사용
IF OBJECT_ID(N'dbo.LWO_REQ_WF', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
    INSERT INTO #PO (CO_CD, SO_NB, SO_SQ, WO_CD, MTL_ITEM, WOBOM_SQ, REQ_QT, RCVREQ_QT)
    SELECT  W.CO_CD, W.SO_NB, W.SO_SQ, F.WO_CD, F.ITEM_CD, F.WOBOM_SQ
           ,CAST(ISNULL(F.REQ_QT,0) AS DECIMAL(19,6))
           ,CAST(ISNULL(F.RCV_QT,0) AS DECIMAL(19,6))
    FROM    dbo.LWO_REQ_WF F WITH (NOLOCK)
    INNER JOIN #WO W ON W.CO_CD = F.CO_CD AND W.WO_CD = F.WO_CD
    WHERE   F.ITEM_CD <> W.WO_ITEM';
    EXEC sp_executesql @SQL;
    PRINT N'[③] 자재청구 라인 : ' + CAST((SELECT COUNT(*) FROM #PO) AS NVARCHAR(20));
END
ELSE
    PRINT N'[WARN] LWO_REQ_WF 없음 - 자재청구 단계 생략';

CREATE CLUSTERED INDEX IX_PO ON #PO (CO_CD, WO_CD, MTL_ITEM);

-- 자재발주 : 청구번호 경유 (LPUR_REQ_D -> LPO_D) 우선, 없으면 품목 기준 합산
IF OBJECT_ID(N'dbo.LPO_D', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
    UPDATE P
       SET PO_QT    = X.PO_QT
          ,PORCV_QT = X.RCV_QT
          ,PO_NB    = X.PO_NB
          ,PO_DUE   = X.DUE_DT
          ,PO_ST    = X.EXPIRE_YN
    FROM   #PO P
    INNER JOIN (
        SELECT  D.CO_CD, D.ITEM_CD
               ,PO_QT     = SUM(CAST(ISNULL(D.PO_QT ,0) AS DECIMAL(19,6)))
               ,RCV_QT    = SUM(CAST(ISNULL(D.RCV_QT,0) AS DECIMAL(19,6)))
               ,PO_NB     = MAX(D.PO_NB)
               ,DUE_DT    = MIN(D.DUE_DT)
               ,EXPIRE_YN = MAX(D.EXPIRE_YN)
        FROM    dbo.LPO_D D WITH (NOLOCK)
        WHERE   D.CO_CD = @p_CO_CD
          AND   ISNULL(D.USE_YN, N''1'') = N''1''
          AND   ISNULL(D.EXPIRE_YN, N''1'') = N''1''      -- 진행(미마감) 발주
        GROUP BY D.CO_CD, D.ITEM_CD
    ) X ON X.CO_CD = P.CO_CD AND X.ITEM_CD = P.MTL_ITEM';
    EXEC sp_executesql @SQL, N'@p_CO_CD NVARCHAR(4)', @p_CO_CD = @CO_CD;
END

-- 현장 자재출고 (LSTKMOVE_D)
IF OBJECT_ID(N'dbo.LSTKMOVE_D', N'U') IS NOT NULL AND OBJECT_ID(N'dbo.LSTKMOVE', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
    UPDATE P SET ISU_QT = X.QT
    FROM   #PO P
    INNER JOIN (
        SELECT  D.CO_CD, D.WO_CD, D.ITEM_CD, D.WOBOM_SQ
               ,QT = SUM(CAST(ISNULL(D.MOVE_QT,0) AS DECIMAL(19,6)))
        FROM    dbo.LSTKMOVE_D D WITH (NOLOCK)
        INNER JOIN dbo.LSTKMOVE H WITH (NOLOCK)
               ON H.CO_CD = D.CO_CD AND H.MOVE_NB = D.MOVE_NB
        WHERE   D.CO_CD = @p_CO_CD
          AND   D.USE_YN = N''1'' AND D.EXPIRE_YN = N''1''
          AND   H.IO_FG = N''2'' AND H.GRP_FG = N''0''      -- 생산자재출고
        GROUP BY D.CO_CD, D.WO_CD, D.ITEM_CD, D.WOBOM_SQ
    ) X ON X.CO_CD = P.CO_CD AND X.WO_CD = P.WO_CD
       AND X.ITEM_CD = P.MTL_ITEM AND ISNULL(X.WOBOM_SQ,0) = ISNULL(P.WOBOM_SQ,0)';
    EXEC sp_executesql @SQL, N'@p_CO_CD NVARCHAR(4)', @p_CO_CD = @CO_CD;
END


/*==============================================================================================
  ⑦ #UM / #MTL : 자재사용량 + 재료비 단가
     @UM_BASE_FG  'INV' 전월 재고평가 출고단가 / 'PUR' 구매 가중평균 / 'TAV' 원가확정 출고단가
==============================================================================================*/
CREATE TABLE #UM ( CO_CD NVARCHAR(4), ITEM_CD NVARCHAR(30), MTL_UM DECIMAL(19,6), UM_SRC NVARCHAR(30) );

-- (1) 전월 재고평가 출고단가 : LINV_TAV  ※ 조인키에 GISU(기수) 포함 필수
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
    INSERT INTO #UM (CO_CD, ITEM_CD, MTL_UM, UM_SRC)
    SELECT  T.CO_CD, T.ITEM_CD
           ,CAST(AVG(CAST(ISNULL(T.ISU_UM,0) AS DECIMAL(19,6))) AS DECIMAL(19,6))
           ,N''전월재고평가출고단가(LINV_TAV)''
    FROM    dbo.LINV_TAV T WITH (NOLOCK)
    WHERE   T.CO_CD = @p_CO_CD
      AND   (@p_DIV IS NULL OR T.DIV_CD = @p_DIV)
      AND   @p_YM BETWEEN T.SMM AND T.FMM' + @GI_FLT + N'
    GROUP BY T.CO_CD, T.ITEM_CD';
    EXEC sp_executesql @SQL, N'@p_CO_CD NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YM NVARCHAR(6), @p_GI INT'
        ,@p_CO_CD = @CO_CD, @p_DIV = @DIV_CD, @p_YM = @TAV_YM, @p_GI=@GISU;
    PRINT N'[⑦] 단가기준 = 전월 재고평가(' + @TAV_YM + N' / 기수 ' + ISNULL(CAST(@GISU AS NVARCHAR(10)), N'전체') + N') / 품목 '
        + CAST((SELECT COUNT(*) FROM #UM) AS NVARCHAR(20));
END

-- (2) 원가모듈 확정 출고단가 : CIV_PUR_TAV
IF @UM_BASE_FG = N'TAV' AND OBJECT_ID(N'dbo.CIV_PUR_TAV', N'U') IS NOT NULL
BEGIN
    IF @COST_CHASU IS NULL
    BEGIN
        SET @SQL = N'SELECT @p_out = MAX(CHASU) FROM dbo.CIV_PUR_TAV WITH (NOLOCK)
                      WHERE CO_CD=@p_CO_CD AND P_YR=@p_YR AND (@p_DIV IS NULL OR DIV_CD=@p_DIV)';
        EXEC sp_executesql @SQL
            ,N'@p_CO_CD NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YR NVARCHAR(4), @p_out NUMERIC(3,0) OUTPUT'
            ,@p_CO_CD=@CO_CD, @p_DIV=@DIV_CD, @p_YR=@COST_YR, @p_out=@COST_CHASU OUTPUT;
    END
    SET @SQL = N'
    INSERT INTO #UM (CO_CD, ITEM_CD, MTL_UM, UM_SRC)
    SELECT  P.CO_CD, P.ITEM_CD
           ,CAST(AVG(CAST(ISNULL(P.ISU_UM,0) AS DECIMAL(19,6))) AS DECIMAL(19,6))
           ,N''원가확정출고단가(CIV_PUR_TAV)''
    FROM    dbo.CIV_PUR_TAV P WITH (NOLOCK)
    WHERE   P.CO_CD=@p_CO_CD AND P.P_YR=@p_YR AND P.CHASU=@p_CHASU
      AND   (@p_DIV IS NULL OR P.DIV_CD=@p_DIV)
    GROUP BY P.CO_CD, P.ITEM_CD';
    EXEC sp_executesql @SQL
        ,N'@p_CO_CD NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YR NVARCHAR(4), @p_CHASU NUMERIC(3,0)'
        ,@p_CO_CD=@CO_CD, @p_DIV=@DIV_CD, @p_YR=@COST_YR, @p_CHASU=@COST_CHASU;
    PRINT N'[⑦] 단가기준 = 원가확정(P_YR=' + @COST_YR + N' CHASU='
        + ISNULL(CAST(@COST_CHASU AS NVARCHAR(10)),N'-') + N')';
END

-- (3) 구매 가중평균 매입단가 : LSTOCK / LSTOCK_D
IF @UM_BASE_FG = N'PUR'
BEGIN
    INSERT INTO #UM (CO_CD, ITEM_CD, MTL_UM, UM_SRC)
    SELECT  D.CO_CD, D.ITEM_CD
           ,CAST(SUM(CAST(ISNULL(D.RCVG_AM,0) AS DECIMAL(19,6)))
               / NULLIF(SUM(CAST(ISNULL(D.RCV_QT,0) AS DECIMAL(19,6))),0) AS DECIMAL(19,6))
           ,N'구매가중평균매입단가'
    FROM        LSTOCK   S WITH (NOLOCK)
    INNER JOIN  LSTOCK_D D WITH (NOLOCK) ON D.CO_CD = S.CO_CD AND D.RCV_NB = S.RCV_NB
    WHERE   S.CO_CD = @CO_CD
      AND   S.RCV_DT BETWEEN @PUR_FR_DT AND @BASE_DT
      AND   (@DIV_CD IS NULL OR S.DIV_CD = @DIV_CD)
      AND   D.EXPIRE_YN = N'1'
      AND   ISNULL(D.RCV_QT,0) > 0
    GROUP BY D.CO_CD, D.ITEM_CD
    HAVING  SUM(CAST(ISNULL(D.RCV_QT,0) AS DECIMAL(19,6))) > 0;
    PRINT N'[⑦] 단가기준 = 구매 가중평균(' + @PUR_FR_DT + N'~' + @BASE_DT + N')';
END

-- 단가 없는 품목은 SITEM.PURCH_UM 으로 보완
INSERT INTO #UM (CO_CD, ITEM_CD, MTL_UM, UM_SRC)
SELECT I.CO_CD, I.ITEM_CD, CAST(ISNULL(I.PURCH_UM,0) AS DECIMAL(19,6)), N'품목 구매단가(대체)'
FROM   SITEM I WITH (NOLOCK)
WHERE  I.CO_CD = @CO_CD
  AND  ISNULL(I.PURCH_UM,0) > 0
  AND  NOT EXISTS (SELECT 1 FROM #UM U WHERE U.CO_CD=I.CO_CD AND U.ITEM_CD=I.ITEM_CD);

CREATE CLUSTERED INDEX IX_UM ON #UM (CO_CD, ITEM_CD);


-- 자재사용 + 재료비
SELECT
     P.CO_CD
    ,P.SO_NB
    ,P.SO_SQ
    ,P.WO_CD
    ,P.DOC_CD
    ,MTL_ITEM = U.ITEM_CD
    ,USE_DT   = U.USE_DT
    ,USE_QT   = CAST(ISNULL(U.USE_QT,0) AS DECIMAL(19,6))
    ,MTL_UM   = CAST(ISNULL(M.MTL_UM,0) AS DECIMAL(19,6))
    ,MTL_AM   = CAST(ISNULL(U.USE_QT,0) * ISNULL(M.MTL_UM,0) AS DECIMAL(19,4))
    ,UM_SRC   = M.UM_SRC
INTO #MTL
FROM        #PRD     P
INNER JOIN  LMTL_USE U WITH (NOLOCK)
       ON   U.CO_CD = P.CO_CD AND U.WR_CD = P.DOC_CD
LEFT  JOIN  #UM      M ON M.CO_CD = U.CO_CD AND M.ITEM_CD = U.ITEM_CD
WHERE   U.USE_YN = N'1' AND U.EXPIRE_YN = N'1'
;
CREATE CLUSTERED INDEX IX_MTL ON #MTL (CO_CD, SO_NB, SO_SQ);

-- 사용량을 #PO 에 반영
UPDATE P SET USE_QT = X.QT
FROM   #PO P
INNER JOIN ( SELECT CO_CD, WO_CD, MTL_ITEM, QT = SUM(USE_QT)
             FROM #MTL GROUP BY CO_CD, WO_CD, MTL_ITEM ) X
       ON X.CO_CD = P.CO_CD AND X.WO_CD = P.WO_CD AND X.MTL_ITEM = P.MTL_ITEM;


/*==============================================================================================
  ⑧ #ISU : 출고
==============================================================================================*/
SELECT
     S.CO_CD
    ,S.SO_NB
    ,S.SO_SQ
    ,ISU_NB   = D.ISU_NB
    ,ISU_SQ   = D.ISU_SQ
    ,ISU_DT   = H.ISU_DT
    ,ISU_QT   = CAST(ISNULL(D.ISU_QT,0) AS DECIMAL(19,6))
    ,ISU_UM   = CAST(ISNULL(D.ISU_UM,0) AS DECIMAL(19,6))
    ,ISUG_AM  = CAST(ISNULL(D.ISUG_AM,0) AS DECIMAL(19,4))      -- 공급가액
    ,ISUV_AM  = CAST(ISNULL(D.ISUV_AM,0) AS DECIMAL(19,4))      -- 부가세
    ,ISUH_AM  = CAST(ISNULL(D.ISUH_AM,0) AS DECIMAL(19,4))      -- 합계액 ★ 채권 발생액
    ,CLS_QT   = CAST(ISNULL(D.CLS_QT,0) AS DECIMAL(19,6))       -- 마감수량
    ,SO_FG    = H.SO_FG                                         -- 거래구분 (채권대상 '0','2','7')
    ,WH_CD    = H.WH_CD
    ,RETURN_YN= CASE WHEN ISNULL(D.ISU_NB_ORG,N'') <> N'' THEN N'Y' ELSE N'N' END
INTO #ISU
FROM        #SO        S
INNER JOIN  LDELIVER_D D WITH (NOLOCK)
       ON   D.CO_CD = S.CO_CD AND D.SO_NB = S.SO_NB AND D.SO_SQ = S.SO_SQ
INNER JOIN  LDELIVER   H WITH (NOLOCK)
       ON   H.CO_CD = D.CO_CD AND H.ISU_NB = D.ISU_NB
WHERE   ISNULL(D.USE_YN, N'1') = N'1'
  AND   ISNULL(D.EXPIRE_YN, N'1') = N'1'
;
CREATE CLUSTERED INDEX IX_ISU ON #ISU (CO_CD, ISU_NB, ISU_SQ);
CREATE NONCLUSTERED INDEX IX_ISU2 ON #ISU (CO_CD, SO_NB, SO_SQ);


/*==============================================================================================
  ⑨⑩⑪ #CLS : 매출마감 -> 전표 -> 장부반영
==============================================================================================*/
SELECT
     I.CO_CD
    ,I.SO_NB
    ,I.SO_SQ
    ,I.ISU_NB
    ,I.ISU_SQ
    ,CLS_NB   = D.CLS_NB
    ,CLS_SQ   = D.CLS_SQ
    ,CLS_DT   = H.CLS_DT
    ,CLS_QT   = CAST(ISNULL(D.CLS_QT ,0) AS DECIMAL(19,6))
    ,CLSG_AM  = CAST(ISNULL(D.CLSG_AM,0) AS DECIMAL(19,4))      -- 공급가액
    ,CLSV_AM  = CAST(ISNULL(D.CLSV_AM,0) AS DECIMAL(19,4))      -- 부가세
    ,CLSH_AM  = CAST(ISNULL(D.CLSH_AM,0) AS DECIMAL(19,4))      -- 합계
    ,TAX_NB   = D.TAX_NB                                        -- 세금계산서번호
    ,DOCU_YN  = H.DOCU_YN                                       -- 기표여부
    ,DOCU_DT  = H.DOCU_DT                                       -- 기표일자  -> ADOCUH.ISU_DT
    ,DOCU_SQ  = H.DOCU_SQ                                       -- 기표순번  -> ADOCUH.ISU_SQ
    ,DOCU_ST  = A.DOCU_ST                                       -- 전표 승인구분
    ,DOCU_TY  = A.DOCU_TY
    ,GET_FG   = A.GET_FG
    ,DOC_AM   = A.DOC_AM                                        -- 전표 차변합계 (검증용)
INTO #CLS
FROM        #ISU        I
INNER JOIN  LSALECLS_D  D WITH (NOLOCK)
       ON   D.CO_CD = I.CO_CD AND D.ISU_NB = I.ISU_NB AND D.ISU_SQ = I.ISU_SQ
INNER JOIN  LSALECLS    H WITH (NOLOCK)
       ON   H.CO_CD = D.CO_CD AND H.CLS_NB = D.CLS_NB
OUTER APPLY (
    SELECT TOP 1 HH.DOCU_ST, HH.DOCU_TY, HH.GET_FG
          ,DOC_AM = (SELECT SUM(CAST(ISNULL(DD.ACCT_AM,0) AS DECIMAL(19,4)))
                     FROM   ADOCUD DD WITH (NOLOCK)
                     WHERE  DD.CO_CD = HH.CO_CD AND DD.ISU_DT = HH.ISU_DT AND DD.ISU_SQ = HH.ISU_SQ
                       AND  DD.DRCR_FG = N'1')                  -- 차변 (코드값 확인 필요)
    FROM   ADOCUH HH WITH (NOLOCK)
    WHERE  HH.CO_CD  = H.CO_CD
      AND  HH.ISU_DT = H.DOCU_DT
      AND  HH.ISU_SQ = H.DOCU_SQ
) A
WHERE   ISNULL(D.USE_YN, N'1') = N'1'
  AND   ISNULL(D.EXPIRE_YN, N'1') = N'1'
;
CREATE CLUSTERED INDEX IX_CLS ON #CLS (CO_CD, SO_NB, SO_SQ);


/*==============================================================================================
  ⑫ #AR : 수금 / 채권
     LRCP_D.ISU_NB + ISU_SQ  ->  출고건 매칭 (수주 단위 채권 추적의 핵심)
==============================================================================================*/
SELECT
     I.CO_CD
    ,I.SO_NB
    ,I.SO_SQ
    ,I.ISU_NB
    ,I.ISU_SQ
    ,RCP_NB    = D.RCP_NB
    ,RCP_SQ    = D.RCP_SQ
    ,RCP_DT    = H.RCP_DT
    ,RCP_FG    = D.RCP_FG                                       -- 수금구분(현금/어음/카드 등)
    ,RCP_NM    = F.RCP_NM                                       -- 수금구분명 (LRCPFG)
    ,RCPAM_FG  = D.RCPAM_FG                                     -- 모듈구분 ('0'=영업)
    ,NORMAL_AM = CAST(ISNULL(D.NORMAL_AM,0) AS DECIMAL(19,4))    -- 정상수금액
    ,BEFORE_AM = CAST(ISNULL(D.BEFORE_AM,0) AS DECIMAL(19,4))    -- 선수금액
    ,DUE_DT    = D.DUE_DT                                       -- 어음 만기/약정일
    ,BANK_CD   = D.BANK_CD
    ,RCP_DOCU_DT = D.DOCU_DT
    ,RCP_DOCU_SQ = D.DOCU_SQ
INTO #AR
FROM        #ISU    I
INNER JOIN  LRCP_D  D WITH (NOLOCK)
       ON   D.CO_CD = I.CO_CD AND D.ISU_NB = I.ISU_NB AND D.ISU_SQ = I.ISU_SQ
INNER JOIN  LRCP    H WITH (NOLOCK)
       ON   H.CO_CD = D.CO_CD AND H.RCP_NB = D.RCP_NB
LEFT  JOIN  LRCPFG  F WITH (NOLOCK)
       ON   F.CO_CD = D.CO_CD AND F.RCP_FG = D.RCP_FG
WHERE   ISNULL(D.USE_YN, N'1') = N'1'
  AND   ISNULL(D.EXPIRE_YN, N'1') = N'1'
  AND   ISNULL(D.RCPAM_FG, N'0') = N'0'                         -- ★ 영업 모듈 수금만 (미수채권현황 표준)
;
CREATE CLUSTERED INDEX IX_AR ON #AR (CO_CD, SO_NB, SO_SQ);


/*==============================================================================================
  ⑫-1 #CLSOPN / #LIMIT : 마감기준 기초채권 + 여신한도  (명세서 누락 테이블 -> 존재 확인 후 사용)
     LOPN_CRISU     기초채권 (출고기준)
     LOPN_CRISU_CLS 기초채권 (마감기준)   ★ 마감기준 채권잔액에는 이쪽을 써야 한다
     LCR_LIMIT      여신한도등록 (사업장별). DAMBO_AM 담보 / SINYONG_AM 신용 / YUSIN_AM 여신
==============================================================================================*/
IF OBJECT_ID('tempdb..#CLSOPN') IS NOT NULL DROP TABLE #CLSOPN;
IF OBJECT_ID('tempdb..#LIMIT')  IS NOT NULL DROP TABLE #LIMIT;
CREATE TABLE #CLSOPN ( CO_CD NVARCHAR(4), TR_CD NVARCHAR(10), OPEN_AM DECIMAL(19,4) );
CREATE TABLE #LIMIT  ( CO_CD NVARCHAR(4), TR_CD NVARCHAR(10)
                      ,YUSIN_AM DECIMAL(19,4), DAMBO_AM DECIMAL(19,4), SINYONG_AM DECIMAL(19,4) );

IF OBJECT_ID(N'dbo.LOPN_CRISU_CLS', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
        INSERT INTO #CLSOPN (CO_CD, TR_CD, OPEN_AM)
        SELECT CO_CD, TR_CD, SUM(CAST(ISNULL(OPEN_AM,0) AS DECIMAL(19,4)))
        FROM   dbo.LOPN_CRISU_CLS WITH (NOLOCK)
        WHERE  CO_CD = @p_CO_CD AND P_YR = @p_YR AND ISNULL(USE_YN, N''1'') = N''1''
          AND  (@p_DIV IS NULL OR DIV_CD = @p_DIV)
        GROUP BY CO_CD, TR_CD';
    EXEC sp_executesql @SQL, N'@p_CO_CD NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YR NVARCHAR(4)'
        ,@p_CO_CD=@CO_CD, @p_DIV=@DIV_CD, @p_YR=LEFT(@BASE_DT,4);
END
ELSE
    PRINT N'[INFO] LOPN_CRISU_CLS 없음 - 마감기준 기초채권은 LOPN_CRISU(출고기준)로 대체';

IF OBJECT_ID(N'dbo.LCR_LIMIT', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
        INSERT INTO #LIMIT (CO_CD, TR_CD, YUSIN_AM, DAMBO_AM, SINYONG_AM)
        SELECT CO_CD, TR_CD
              ,SUM(CAST(ISNULL(YUSIN_AM  ,0) AS DECIMAL(19,4)))
              ,SUM(CAST(ISNULL(DAMBO_AM  ,0) AS DECIMAL(19,4)))
              ,SUM(CAST(ISNULL(SINYONG_AM,0) AS DECIMAL(19,4)))
        FROM   dbo.LCR_LIMIT WITH (NOLOCK)
        WHERE  CO_CD = @p_CO_CD AND ISNULL(USE_YN, N''1'') = N''1''
          AND  (@p_DIV IS NULL OR DIV_CD = @p_DIV)
        GROUP BY CO_CD, TR_CD';
    EXEC sp_executesql @SQL, N'@p_CO_CD NVARCHAR(4), @p_DIV NVARCHAR(4)'
        ,@p_CO_CD=@CO_CD, @p_DIV=@DIV_CD;
END
ELSE
    PRINT N'[INFO] LCR_LIMIT 없음 - 여신한도는 STRADE.CREDIT_AM 으로 대체';

CREATE CLUSTERED INDEX IX_CLSOPN ON #CLSOPN (CO_CD, TR_CD);
CREATE CLUSTERED INDEX IX_LIMIT  ON #LIMIT  (CO_CD, TR_CD);


/*==============================================================================================
  ⑬ #AP : 자재발주 -> 매입마감 -> 지급  (거래처 단위)
==============================================================================================*/
CREATE TABLE #AP (
     CO_CD    NVARCHAR(4)
    ,TR_CD    NVARCHAR(10)
    ,PO_AM    DECIMAL(19,4) DEFAULT 0   -- 발주금액
    ,RCV_AM   DECIMAL(19,4) DEFAULT 0   -- 입고금액
    ,CLS_AM   DECIMAL(19,4) DEFAULT 0   -- 매입마감금액
    ,PAY_AM   DECIMAL(19,4) DEFAULT 0   -- 지급액
    ,BEFORE_AM DECIMAL(19,4) DEFAULT 0  -- 선급금
    ,OPEN_AM  DECIMAL(19,4) DEFAULT 0   -- 기초채무
    ,DOCU_CNT INT DEFAULT 0             -- 미기표 마감건수
);

INSERT INTO #AP (CO_CD, TR_CD)
SELECT DISTINCT H.CO_CD, H.TR_CD
FROM   LPO H WITH (NOLOCK)
WHERE  H.CO_CD = @CO_CD
  AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
  AND  H.PO_DT BETWEEN @PUR_FR_DT AND @BASE_DT;

CREATE CLUSTERED INDEX IX_AP ON #AP (CO_CD, TR_CD);

-- 발주 / 입고
UPDATE A SET PO_AM = X.AM
FROM   #AP A
INNER JOIN ( SELECT H.CO_CD, H.TR_CD, AM = SUM(CAST(ISNULL(D.POG_AM,0) AS DECIMAL(19,4)))
             FROM   LPO H WITH (NOLOCK)
             INNER JOIN LPO_D D WITH (NOLOCK) ON D.CO_CD=H.CO_CD AND D.PO_NB=H.PO_NB
             WHERE  H.CO_CD=@CO_CD AND H.PO_DT BETWEEN @PUR_FR_DT AND @BASE_DT
               AND  ISNULL(D.USE_YN,N'1')=N'1'
             GROUP BY H.CO_CD, H.TR_CD ) X
       ON X.CO_CD=A.CO_CD AND X.TR_CD=A.TR_CD;

UPDATE A SET RCV_AM = X.AM
FROM   #AP A
INNER JOIN ( SELECT S.CO_CD, S.TR_CD, AM = SUM(CAST(ISNULL(D.RCVG_AM,0) AS DECIMAL(19,4)))
             FROM   LSTOCK S WITH (NOLOCK)
             INNER JOIN LSTOCK_D D WITH (NOLOCK) ON D.CO_CD=S.CO_CD AND D.RCV_NB=S.RCV_NB
             WHERE  S.CO_CD=@CO_CD AND S.RCV_DT BETWEEN @PUR_FR_DT AND @BASE_DT
               AND  ISNULL(D.EXPIRE_YN,N'1')=N'1'
             GROUP BY S.CO_CD, S.TR_CD ) X
       ON X.CO_CD=A.CO_CD AND X.TR_CD=A.TR_CD;

-- 매입마감 + 미기표 건수 (LPURCLS 는 명세서 누락 -> 존재 확인)
IF OBJECT_ID(N'dbo.LPURCLS', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
    UPDATE A SET CLS_AM = X.AM, DOCU_CNT = X.CNT
    FROM   #AP A
    INNER JOIN ( SELECT H.CO_CD, H.TR_CD
                       ,AM  = SUM(CAST(ISNULL(D.CLSG_AM,0) AS DECIMAL(19,4)))
                       ,CNT = COUNT(DISTINCT CASE WHEN ISNULL(H.DOCU_YN,N''0'') <> N''1''
                                                  THEN H.CLS_NB END)
                 FROM   dbo.LPURCLS H WITH (NOLOCK)
                 INNER JOIN dbo.LPURCLS_D D WITH (NOLOCK) ON D.CO_CD=H.CO_CD AND D.CLS_NB=H.CLS_NB
                 WHERE  H.CO_CD=@p_CO_CD AND H.CLS_DT BETWEEN @p_FR AND @p_TO
                   AND  ISNULL(D.EXPIRE_YN,N''1'')=N''1''
                 GROUP BY H.CO_CD, H.TR_CD ) X
           ON X.CO_CD=A.CO_CD AND X.TR_CD=A.TR_CD';
    EXEC sp_executesql @SQL, N'@p_CO_CD NVARCHAR(4), @p_FR NVARCHAR(8), @p_TO NVARCHAR(8)'
        ,@p_CO_CD=@CO_CD, @p_FR=@PUR_FR_DT, @p_TO=@BASE_DT;
END

-- 지급
UPDATE A SET PAY_AM = X.AM, BEFORE_AM = X.BAM
FROM   #AP A
INNER JOIN ( SELECT H.CO_CD, H.TR_CD
                   ,AM  = SUM(CAST(ISNULL(D.NORMAL_AM,0) AS DECIMAL(19,4)))
                   ,BAM = SUM(CAST(ISNULL(D.BEFORE_AM,0) AS DECIMAL(19,4)))
             FROM   LPAY H WITH (NOLOCK)
             INNER JOIN LPAY_D D WITH (NOLOCK) ON D.CO_CD=H.CO_CD AND D.PAY_NB=H.PAY_NB
             WHERE  H.CO_CD=@CO_CD AND H.PAY_DT BETWEEN @PUR_FR_DT AND @BASE_DT
               AND  ISNULL(D.EXPIRE_YN,N'1')=N'1'
             GROUP BY H.CO_CD, H.TR_CD ) X
       ON X.CO_CD=A.CO_CD AND X.TR_CD=A.TR_CD;

-- 기초채무 (LOPN_PAY_CLS = 마감기준. LOPN_PAY(발생기준)도 별도 존재 - 사이트 확인)
UPDATE A SET OPEN_AM = X.AM
FROM   #AP A
INNER JOIN ( SELECT CO_CD, TR_CD, AM = SUM(CAST(ISNULL(OPEN_AM,0) AS DECIMAL(19,4)))
             FROM   LOPN_PAY_CLS WITH (NOLOCK)
             WHERE  CO_CD=@CO_CD AND P_YR=LEFT(@BASE_DT,4) AND ISNULL(USE_YN,N'1')=N'1'
             GROUP BY CO_CD, TR_CD ) X
       ON X.CO_CD=A.CO_CD AND X.TR_CD=A.TR_CD;


/*==============================================================================================
  #TOT : 수주 라인 단위 통합 (1행 = 1수주라인)
==============================================================================================*/
SELECT
     S.*
    -- ② 생산지시
    ,WO_CNT    = ISNULL(W.CNT, 0)
    ,WO_QT_T   = ISNULL(W.WO_QT, 0)
    ,WO_MIN_ST = W.MIN_ST
    ,WO_COMP_DT= W.COMP_DT
    -- ③④ 자재
    ,MTL_KIND  = ISNULL(M.KIND, 0)
    ,REQ_QT_T  = ISNULL(M.REQ_QT, 0)
    ,PO_QT_T   = ISNULL(M.PO_QT, 0)
    ,PORCV_QT_T= ISNULL(M.PORCV_QT, 0)
    ,MISU_MTL  = ISNULL(M.SHORT_CNT, 0)                         -- 미입고 자재 품목수
    -- ⑥ 생산실적
    ,PRD_QT_T  = ISNULL(P.PRD_QT, 0)
    ,GOOD_QT_T = ISNULL(P.GOOD_QT, 0)
    ,INWH_QT_T = ISNULL(P.INWH_QT, 0)
    ,LAST_PRD_DT = P.LAST_DT
    -- ⑦ 재료비
    ,MTL_AM_T  = ISNULL(C.MTL_AM, 0)
    ,UM_SRC    = C.UM_SRC
    -- ⑧ 출고
    ,ISU_QT_T  = ISNULL(V.ISU_QT, 0)
    ,ISUG_AM_T = ISNULL(V.ISUG_AM, 0)
    ,ISUH_AM_T = ISNULL(V.ISUH_AM, 0)                           -- 출고 합계액 (채권 발생액)
    ,LAST_ISU_DT = V.LAST_DT
    -- ⑨⑩⑪ 마감/전표
    ,CLS_QT_T  = ISNULL(L.CLS_QT, 0)
    ,CLSG_AM_T = ISNULL(L.CLSG_AM, 0)
    ,CLSH_AM_T = ISNULL(L.CLSH_AM, 0)
    ,DOCU_YN   = L.DOCU_YN
    ,DOCU_DT   = L.DOCU_DT
    ,DOCU_SQ   = L.DOCU_SQ
    ,DOCU_ST   = L.DOCU_ST
    -- ⑫ 수금
    ,RCP_AM_T  = ISNULL(R.RCP_AM, 0)
    ,LAST_RCP_DT = R.LAST_DT
INTO #TOT
FROM        #SO S
OUTER APPLY (SELECT CNT=COUNT(*), WO_QT=SUM(WO_QT), MIN_ST=MIN(DOC_ST), COMP_DT=MAX(COMP_DT)
             FROM #WO X WHERE X.CO_CD=S.CO_CD AND X.SO_NB=S.SO_NB AND X.SO_SQ=S.SO_SQ) W
OUTER APPLY (SELECT KIND=COUNT(DISTINCT MTL_ITEM), REQ_QT=SUM(REQ_QT), PO_QT=SUM(PO_QT)
                   ,PORCV_QT=SUM(PORCV_QT)
                   ,SHORT_CNT=COUNT(DISTINCT CASE WHEN PO_QT > PORCV_QT THEN MTL_ITEM END)
             FROM #PO X WHERE X.CO_CD=S.CO_CD AND X.SO_NB=S.SO_NB AND X.SO_SQ=S.SO_SQ) M
OUTER APPLY (SELECT PRD_QT=SUM(PRD_QT), GOOD_QT=SUM(GOOD_QT), INWH_QT=SUM(INWH_QT)
                   ,LAST_DT=MAX(DOC_DT)
             FROM #PRD X WHERE X.CO_CD=S.CO_CD AND X.SO_NB=S.SO_NB AND X.SO_SQ=S.SO_SQ) P
OUTER APPLY (SELECT MTL_AM=SUM(MTL_AM), UM_SRC=MAX(UM_SRC)
             FROM #MTL X WHERE X.CO_CD=S.CO_CD AND X.SO_NB=S.SO_NB AND X.SO_SQ=S.SO_SQ) C
OUTER APPLY (SELECT ISU_QT=SUM(ISU_QT), ISUG_AM=SUM(ISUG_AM), LAST_DT=MAX(ISU_DT)
                   ,ISUH_AM=SUM(CASE WHEN X.SO_FG IN (N'0',N'2',N'7') THEN X.ISUH_AM ELSE 0 END)
             FROM #ISU X WHERE X.CO_CD=S.CO_CD AND X.SO_NB=S.SO_NB AND X.SO_SQ=S.SO_SQ) V
OUTER APPLY (SELECT CLS_QT=SUM(CLS_QT), CLSG_AM=SUM(CLSG_AM), CLSH_AM=SUM(CLSH_AM)
                   ,DOCU_YN=MAX(DOCU_YN), DOCU_DT=MAX(DOCU_DT), DOCU_SQ=MAX(DOCU_SQ)
                   ,DOCU_ST=MAX(DOCU_ST)
             FROM #CLS X WHERE X.CO_CD=S.CO_CD AND X.SO_NB=S.SO_NB AND X.SO_SQ=S.SO_SQ) L
OUTER APPLY (SELECT RCP_AM=SUM(NORMAL_AM + BEFORE_AM), LAST_DT=MAX(RCP_DT)
             FROM #AR X WHERE X.CO_CD=S.CO_CD AND X.SO_NB=S.SO_NB AND X.SO_SQ=S.SO_SQ) R
;
CREATE CLUSTERED INDEX IX_TOT ON #TOT (CO_CD, SO_NB, SO_SQ);


/*==============================================================================================
  ** 쿼리 A : 수주 진행 총괄 현황  (메인 / 1행 = 1수주라인 / 11단계 전부)
==============================================================================================*/
SELECT
     N'[A] 수주 진행 총괄'                           AS REPORT_NM
    -- ① 수주
    ,T.SO_NB                                         AS 수주번호
    ,T.SO_SQ                                         AS 순번
    ,T.SO_DT                                         AS 수주일
    ,T.DUE_DT                                        AS 납기일
    ,TR.TR_NM                                        AS 거래처
    ,T.PLN_CD                                        AS 영업담당코드
    ,J.PJT_NM                                        AS 프로젝트
    ,T.ITEM_CD                                       AS 제품번호
    ,I.ITEM_NM                                       AS 제품명
    ,I.UNIT_DC                                       AS 단위
    ,T.SO_QT                                         AS 수주수량
    ,T.SOG_AM                                        AS 수주금액

    -- ★ 진행단계 (역순 판정 : 가장 진행된 단계를 잡는다)
    ,진행단계 = CASE
         WHEN ISNULL(T.RCP_AM_T,0)  >= T.SOH_AM AND T.SOH_AM > 0     THEN N'A.수금완료'
         WHEN ISNULL(T.RCP_AM_T,0)  > 0                              THEN N'9.부분수금'
         WHEN T.DOCU_ST IS NOT NULL                                  THEN N'8.전표승인'
         WHEN ISNULL(T.DOCU_YN,N'0') = N'1'                          THEN N'7.기표완료'
         WHEN ISNULL(T.CLS_QT_T,0)  > 0                              THEN N'6.매출마감'
         WHEN T.OPEN_QT <= 0                                         THEN N'5.출고완료'
         WHEN ISNULL(T.ISU_QT_T,0)  > 0                              THEN N'4.부분출고'
         WHEN ISNULL(T.INWH_QT_T,0) > 0                              THEN N'3.생산입고'
         WHEN ISNULL(T.PRD_QT_T,0)  > 0                              THEN N'2.생산중'
         WHEN ISNULL(T.WO_CNT,0)    > 0                              THEN N'1.지시등록'
         ELSE N'0.미착수' END

    -- ② 생산지시
    ,T.WO_CNT                                        AS 지시건수
    ,T.WO_QT_T                                       AS 지시수량
    ,CASE T.WO_MIN_ST WHEN N'0' THEN N'계획' WHEN N'1' THEN N'확정'
                      WHEN N'2' THEN N'마감' END      AS 지시상태
    ,T.WO_COMP_DT                                    AS 지시완료예정일

    -- ③④ 자재 수급
    ,T.MTL_KIND                                      AS 소요자재종수
    ,T.REQ_QT_T                                      AS 자재청구량
    ,T.PO_QT_T                                       AS 자재발주량
    ,T.PORCV_QT_T                                    AS 자재입고량
    ,T.MISU_MTL                                      AS 미입고자재종수
    ,자재수급상태 = CASE WHEN T.MTL_KIND = 0        THEN N'-'
                         WHEN T.MISU_MTL = 0         THEN N'확보'
                         WHEN T.MISU_MTL <= 2        THEN N'일부미입고'
                         ELSE N'다수미입고' END

    -- ⑥ 생산실적
    ,T.PRD_QT_T                                      AS 생산실적수량
    ,T.GOOD_QT_T                                     AS 양품수량
    ,T.INWH_QT_T                                     AS 생산입고수량
    ,T.LAST_PRD_DT                                   AS 최종실적일
    ,CAST(CASE WHEN T.SO_QT <> 0 THEN T.GOOD_QT_T / T.SO_QT * 100 END AS DECIMAL(19,2)) AS 생산진척률_PCT

    -- ⑦ 재료비 (원가추적)
    ,T.MTL_AM_T                                      AS 투입재료비
    ,CAST(CASE WHEN T.GOOD_QT_T <> 0 THEN T.MTL_AM_T / T.GOOD_QT_T END AS DECIMAL(19,4)) AS 단위당재료비
    ,T.UM_SRC                                        AS 단가기준
    ,T.SOG_AM - ISNULL(T.MTL_AM_T,0)                 AS 재료비차감이익
    ,CAST(CASE WHEN T.SOG_AM <> 0
               THEN (T.SOG_AM - ISNULL(T.MTL_AM_T,0)) / T.SOG_AM * 100 END AS DECIMAL(19,2)) AS 재료비차감이익률_PCT

    -- ⑧ 출고 / 납기잔량
    ,T.ISU_QT_T                                      AS 출고수량
    ,T.OPEN_QT                                       AS 납기잔량
    ,T.ISUG_AM_T                                     AS 출고금액
    ,T.LAST_ISU_DT                                   AS 최종출고일
    ,납기상태 = CASE
         WHEN T.OPEN_QT <= 0 AND T.LAST_ISU_DT <= T.DUE_DT       THEN N'0.정상완료'
         WHEN T.OPEN_QT <= 0                                     THEN N'1.지연완료'
         WHEN T.DUE_DT < @BASE_DT                                THEN N'2.납기경과'
         WHEN T.DUE_DT <= CONVERT(NVARCHAR(8), DATEADD(DAY,7,CONVERT(DATE,@BASE_DT)),112)
                                                                 THEN N'3.임박(7일)'
         ELSE N'4.여유' END
    ,납기경과일 = CASE WHEN T.OPEN_QT > 0 AND T.DUE_DT < @BASE_DT
                       THEN DATEDIFF(DAY, CONVERT(DATE,T.DUE_DT), CONVERT(DATE,@BASE_DT)) END
    ,출고지연일 = CASE WHEN T.LAST_ISU_DT IS NOT NULL
                       THEN DATEDIFF(DAY, CONVERT(DATE,T.DUE_DT), CONVERT(DATE,T.LAST_ISU_DT)) END

    -- ⑨⑩⑪ 회계
    ,T.CLS_QT_T                                      AS 마감수량
    ,T.CLSG_AM_T                                     AS 마감공급가액
    ,T.CLSH_AM_T                                     AS 마감합계액
    ,T.ISUG_AM_T - ISNULL(T.CLSG_AM_T,0)             AS 미마감금액
    ,CASE ISNULL(T.DOCU_YN,N'0') WHEN N'1' THEN N'기표' ELSE N'미기표' END AS 기표여부
    ,T.DOCU_DT                                       AS 기표일자
    ,T.DOCU_SQ                                       AS 기표순번
    ,T.DOCU_ST                                       AS 전표승인구분
    ,장부반영 = CASE WHEN T.DOCU_ST IS NOT NULL       THEN N'반영'
                     WHEN ISNULL(T.DOCU_YN,N'0')=N'1' THEN N'기표만(전표확인필요)'
                     WHEN ISNULL(T.CLS_QT_T,0) > 0    THEN N'마감만(미기표)'
                     ELSE N'-' END

    -- ⑫ 채권  (출고기준=선행지표 / **마감기준=최종 회계확정 채권**)
    ,T.ISUH_AM_T                                     AS 채권발생액_출고기준
    ,T.CLSH_AM_T                                     AS 채권발생액_마감기준        -- ★ 최종
    ,ISNULL(T.ISUH_AM_T,0) - ISNULL(T.CLSH_AM_T,0)   AS 미마감채권                 -- 회계 미확정분
    ,T.RCP_AM_T                                      AS 수금액
    ,ISNULL(T.CLSH_AM_T,0) - ISNULL(T.RCP_AM_T,0)    AS 채권잔액                   -- ★ 마감기준
    ,ISNULL(T.ISUH_AM_T,0) - ISNULL(T.RCP_AM_T,0)    AS 채권잔액_출고기준
    ,T.LAST_RCP_DT                                   AS 최종수금일
    ,CAST(CASE WHEN ISNULL(T.CLSH_AM_T,0) <> 0
               THEN ISNULL(T.RCP_AM_T,0) / T.CLSH_AM_T * 100 END AS DECIMAL(19,2)) AS 회수율_PCT
FROM        #TOT   T
LEFT  JOIN  STRADE TR WITH (NOLOCK) ON TR.CO_CD = T.CO_CD AND TR.TR_CD  = T.TR_CD
LEFT  JOIN  SITEM  I  WITH (NOLOCK) ON I.CO_CD  = T.CO_CD AND I.ITEM_CD = T.ITEM_CD
LEFT  JOIN  SPJT   J  WITH (NOLOCK) ON J.CO_CD  = T.CO_CD AND J.PJT_CD  = T.PJT_CD
ORDER BY T.DUE_DT, T.SO_NB, T.SO_SQ
;


/*==============================================================================================
  ** 쿼리 B : 납품 가능 스케줄 (출고 가능일 산정)
     자재 미입고 -> 생산 미완료 -> 출고 순으로 병목을 찾아 납품가능일을 역산한다.
==============================================================================================*/
SELECT
     N'[B] 납품가능 스케줄'                          AS REPORT_NM
    ,T.SO_NB                                         AS 수주번호
    ,T.SO_SQ                                         AS 순번
    ,T.DUE_DT                                        AS 고객납기일
    ,TR.TR_NM                                        AS 거래처
    ,T.ITEM_CD                                       AS 제품번호
    ,I.ITEM_NM                                       AS 제품명
    ,T.SO_QT                                         AS 수주수량
    ,T.OPEN_QT                                       AS 미출고잔량

    ,병목단계 = CASE
         WHEN T.OPEN_QT <= 0                          THEN N'0.완료'
         WHEN ISNULL(T.WO_CNT,0) = 0                  THEN N'1.작업지시 미등록'
         WHEN T.MISU_MTL > 0                          THEN N'2.자재 미입고'
         WHEN ISNULL(T.GOOD_QT_T,0) < T.SO_QT         THEN N'3.생산 미완료'
         WHEN ISNULL(T.INWH_QT_T,0) < ISNULL(T.GOOD_QT_T,0) THEN N'4.생산입고 미처리'
         ELSE N'5.출고 대기' END

    ,T.MISU_MTL                                      AS 미입고자재종수
    ,MT.최장자재입고예정일
    ,MT.병목자재
    ,T.WO_COMP_DT                                    AS 지시완료예정일
    ,ISNULL(T.GOOD_QT_T,0)                           AS 생산완료수량
    ,T.SO_QT - ISNULL(T.GOOD_QT_T,0)                 AS 생산잔량

    -- 납품가능일 = MAX(자재입고예정일, 지시완료예정일) + 여유일
    ,납품가능예상일 = CASE WHEN T.OPEN_QT <= 0 THEN NULL
         ELSE CONVERT(NVARCHAR(8), DATEADD(DAY, @LEAD_BUF_DD,
                CASE WHEN ISNULL(MT.최장자재입고예정일, N'') > ISNULL(T.WO_COMP_DT, N'')
                     THEN CONVERT(DATE, NULLIF(MT.최장자재입고예정일, N''))
                     ELSE CONVERT(DATE, NULLIF(ISNULL(T.WO_COMP_DT, @BASE_DT), N'')) END), 112) END

    ,납기가능여부 = CASE
         WHEN T.OPEN_QT <= 0 THEN N'-'
         WHEN DATEADD(DAY, @LEAD_BUF_DD,
                CASE WHEN ISNULL(MT.최장자재입고예정일,N'') > ISNULL(T.WO_COMP_DT,N'')
                     THEN CONVERT(DATE, NULLIF(MT.최장자재입고예정일,N''))
                     ELSE CONVERT(DATE, NULLIF(ISNULL(T.WO_COMP_DT,@BASE_DT),N'')) END)
              <= CONVERT(DATE, T.DUE_DT) THEN N'가능'
         ELSE N'위험(납기초과)' END
FROM        #TOT   T
LEFT  JOIN  STRADE TR WITH (NOLOCK) ON TR.CO_CD = T.CO_CD AND TR.TR_CD  = T.TR_CD
LEFT  JOIN  SITEM  I  WITH (NOLOCK) ON I.CO_CD  = T.CO_CD AND I.ITEM_CD = T.ITEM_CD
OUTER APPLY (
    SELECT 최장자재입고예정일 = MAX(P.PO_DUE)
          ,병목자재 = STUFF((SELECT TOP 5 N', ' + P2.MTL_ITEM
                             FROM   #PO P2
                             WHERE  P2.CO_CD=T.CO_CD AND P2.SO_NB=T.SO_NB AND P2.SO_SQ=T.SO_SQ
                               AND  P2.PO_QT > P2.PORCV_QT
                             GROUP BY P2.MTL_ITEM
                             FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 2, N'')
    FROM   #PO P
    WHERE  P.CO_CD=T.CO_CD AND P.SO_NB=T.SO_NB AND P.SO_SQ=T.SO_SQ
      AND  P.PO_QT > P.PORCV_QT
) MT
WHERE  T.OPEN_QT > 0
ORDER BY 납기가능여부 DESC, T.DUE_DT, T.SO_NB
;


/*==============================================================================================
  ** 쿼리 C : 수주별 자재 수급 상세 (청구 -> 발주 -> 입고 -> 현장출고 -> 사용)
==============================================================================================*/
SELECT
     N'[C] 수주별 자재 수급'                         AS REPORT_NM
    ,P.SO_NB                                         AS 수주번호
    ,P.SO_SQ                                         AS 순번
    ,S.DUE_DT                                        AS 납기일
    ,S.ITEM_CD                                       AS 제품번호
    ,PI.ITEM_NM                                      AS 제품명
    ,P.WO_CD                                         AS 작업지시번호
    ,P.WOBOM_SQ                                      AS 소요순번
    ,P.MTL_ITEM                                      AS 자재품번
    ,MI.ITEM_NM                                      AS 자재품명
    ,MI.UNIT_DC                                      AS 단위
    ,MI.ACCT_FG                                      AS 계정구분

    ,P.REQ_QT                                        AS 청구량
    ,P.PO_QT                                         AS 발주량
    ,P.PORCV_QT                                      AS 입고량
    ,P.PO_QT - P.PORCV_QT                            AS 미입고량
    ,P.ISU_QT                                        AS 현장출고량
    ,P.USE_QT                                        AS 실사용량
    ,P.ISU_QT - P.USE_QT                             AS 출고미사용량

    ,P.PO_NB                                         AS 발주번호
    ,P.PO_DUE                                        AS 발주납기일
    ,CASE ISNULL(P.PO_ST,N'1') WHEN N'1' THEN N'발주진행' WHEN N'0' THEN N'발주마감' END AS 발주상태
    ,입고지연일 = CASE WHEN P.PO_QT > P.PORCV_QT AND P.PO_DUE < @BASE_DT
                       THEN DATEDIFF(DAY, CONVERT(DATE,P.PO_DUE), CONVERT(DATE,@BASE_DT)) END

    ,수급상태 = CASE WHEN P.REQ_QT > 0 AND P.PO_QT = 0        THEN N'1.미발주'
                     WHEN P.PO_QT > P.PORCV_QT                 THEN N'2.미입고'
                     WHEN P.PORCV_QT > 0 AND P.ISU_QT = 0      THEN N'3.출고대기'
                     WHEN P.ISU_QT > P.USE_QT                  THEN N'4.사용대기'
                     WHEN P.USE_QT > 0                         THEN N'5.사용완료'
                     ELSE N'0.-' END

    ,U.MTL_UM                                        AS 자재단가
    ,P.USE_QT * ISNULL(U.MTL_UM,0)                   AS 투입금액
    ,U.UM_SRC                                        AS 단가기준
FROM        #PO    P
LEFT  JOIN  #SO    S  ON S.CO_CD=P.CO_CD AND S.SO_NB=P.SO_NB AND S.SO_SQ=P.SO_SQ
LEFT  JOIN  #UM    U  ON U.CO_CD=P.CO_CD AND U.ITEM_CD=P.MTL_ITEM
LEFT  JOIN  SITEM  PI WITH (NOLOCK) ON PI.CO_CD=P.CO_CD AND PI.ITEM_CD=S.ITEM_CD
LEFT  JOIN  SITEM  MI WITH (NOLOCK) ON MI.CO_CD=P.CO_CD AND MI.ITEM_CD=P.MTL_ITEM
ORDER BY P.SO_NB, P.SO_SQ, P.WO_CD, P.WOBOM_SQ
;


/*==============================================================================================
  ** 쿼리 D : 수주별 생산원가 추적 (재료비 상세)
==============================================================================================*/
SELECT
     N'[D] 수주별 생산원가 추적'                     AS REPORT_NM
    ,M.SO_NB                                         AS 수주번호
    ,M.SO_SQ                                         AS 순번
    ,S.ITEM_CD                                       AS 제품번호
    ,PI.ITEM_NM                                      AS 제품명
    ,S.SO_QT                                         AS 수주수량
    ,S.SOG_AM                                        AS 수주금액
    ,M.WO_CD                                         AS 작업지시번호
    ,M.DOC_CD                                        AS 실적번호
    ,M.USE_DT                                        AS 사용일
    ,M.MTL_ITEM                                      AS 자재품번
    ,MI.ITEM_NM                                      AS 자재품명
    ,MI.UNIT_DC                                      AS 단위
    ,MI.ACCT_FG                                      AS 계정구분
    ,M.USE_QT                                        AS 사용량
    ,M.MTL_UM                                        AS 적용단가
    ,M.MTL_AM                                        AS 재료비
    ,M.UM_SRC                                        AS 단가기준
    ,CAST(M.MTL_AM / NULLIF(SUM(M.MTL_AM) OVER (PARTITION BY M.CO_CD, M.SO_NB, M.SO_SQ), 0) * 100
          AS DECIMAL(19,2))                          AS 재료비구성비_PCT
    ,SUM(M.MTL_AM) OVER (PARTITION BY M.CO_CD, M.SO_NB, M.SO_SQ) AS 수주총재료비
FROM        #MTL  M
LEFT  JOIN  #SO   S  ON S.CO_CD=M.CO_CD AND S.SO_NB=M.SO_NB AND S.SO_SQ=M.SO_SQ
LEFT  JOIN  SITEM PI WITH (NOLOCK) ON PI.CO_CD=M.CO_CD AND PI.ITEM_CD=S.ITEM_CD
LEFT  JOIN  SITEM MI WITH (NOLOCK) ON MI.CO_CD=M.CO_CD AND MI.ITEM_CD=M.MTL_ITEM
ORDER BY M.SO_NB, M.SO_SQ, M.MTL_AM DESC
;


/*==============================================================================================
  ** 쿼리 E : 회계 반영 현황 (출고 -> 매출마감 -> 전표 -> 장부)
==============================================================================================*/
SELECT
     N'[E] 회계 반영 현황'                           AS REPORT_NM
    ,I.SO_NB                                         AS 수주번호
    ,I.SO_SQ                                         AS 순번
    ,TR.TR_NM                                        AS 거래처
    ,I.ISU_NB                                        AS 출고번호
    ,I.ISU_SQ                                        AS 출고순번
    ,I.ISU_DT                                        AS 출고일
    ,I.ISU_QT                                        AS 출고수량
    ,I.ISUG_AM                                       AS 출고공급가액
    ,I.RETURN_YN                                     AS 반품여부

    ,C.CLS_NB                                        AS 마감번호
    ,C.CLS_DT                                        AS 마감일
    ,C.CLS_QT                                        AS 마감수량
    ,C.CLSG_AM                                       AS 마감공급가액
    ,C.CLSV_AM                                       AS 마감부가세
    ,C.CLSH_AM                                       AS 마감합계액
    ,C.TAX_NB                                        AS 세금계산서번호
    ,I.ISU_QT - ISNULL(C.CLS_QT,0)                   AS 미마감수량

    ,CASE ISNULL(C.DOCU_YN,N'0') WHEN N'1' THEN N'기표' ELSE N'미기표' END AS 기표여부
    ,C.DOCU_DT                                       AS 전표일자
    ,C.DOCU_SQ                                       AS 전표번호
    ,C.DOCU_ST                                       AS 승인구분
    ,C.DOCU_TY                                       AS 전표유형
    ,C.GET_FG                                        AS 연동구분
    ,C.DOC_AM                                        AS 전표차변합계
    ,ISNULL(C.CLSH_AM,0) - ISNULL(C.DOC_AM,0)        AS 마감_전표차이

    ,처리단계 = CASE WHEN C.DOCU_ST IS NOT NULL                THEN N'4.장부반영'
                     WHEN ISNULL(C.DOCU_YN,N'0') = N'1'        THEN N'3.기표완료'
                     WHEN C.CLS_NB IS NOT NULL                 THEN N'2.매출마감'
                     ELSE N'1.출고만' END
FROM        #ISU   I
LEFT  JOIN  #CLS   C  ON C.CO_CD=I.CO_CD AND C.ISU_NB=I.ISU_NB AND C.ISU_SQ=I.ISU_SQ
LEFT  JOIN  #SO    S  ON S.CO_CD=I.CO_CD AND S.SO_NB=I.SO_NB AND S.SO_SQ=I.SO_SQ
LEFT  JOIN  STRADE TR WITH (NOLOCK) ON TR.CO_CD=S.CO_CD AND TR.TR_CD=S.TR_CD
ORDER BY 처리단계, I.ISU_DT, I.ISU_NB, I.ISU_SQ
;


/*==============================================================================================
  ** 쿼리 F : 채권 현황 (수주/거래처별 매출-수금-잔액)
==============================================================================================*/
;WITH AR AS
(
    -- 채권은 2개 기준으로 본다.
    --   출고기준(선행) = LDELIVER_D.ISUH_AM  (SO_FG IN '0','2','7')
    --   마감기준(최종) = LSALECLS_D.CLSH_AM  ★ 매출마감이 회계 확정 시점
    --   기초채권       = LOPN_CRISU + LCR_ADJUST
    --   당기수금       = LRCP_D.NORMAL_AM + BEFORE_AM  (RCPAM_FG='0')
    --   출고-마감 차이 = 미마감 채권. 마감 누락 통제 지표.
    SELECT
         T.CO_CD, T.TR_CD
        ,출고기준매출 = SUM(ISNULL(T.ISUH_AM_T, 0))
        ,마감기준매출 = SUM(ISNULL(T.CLSH_AM_T, 0))
        ,수금액       = SUM(ISNULL(T.RCP_AM_T , 0))
        ,수주건수     = COUNT(*)
        ,미마감액     = SUM(ISNULL(T.ISUG_AM_T,0) - ISNULL(T.CLSG_AM_T,0))
    FROM   #TOT T
    GROUP BY T.CO_CD, T.TR_CD
)
SELECT
     N'[F] 채권 현황'                                AS REPORT_NM
    ,A.TR_CD                                         AS 거래처코드
    ,TR.TR_NM                                        AS 거래처명
    ,ISNULL(CO.OPEN_AM, ISNULL(O.OPEN_AM,0))         AS 기초채권_마감기준          -- LOPN_CRISU_CLS
    ,ISNULL(O.OPEN_AM, 0)                            AS 기초채권_출고기준          -- LOPN_CRISU
    ,A.마감기준매출                                  AS 당기매출_마감기준          -- ★ 최종
    ,A.출고기준매출                                  AS 당기매출_출고기준          -- 선행지표
    ,A.수금액
    ,ISNULL(J.ADJUST_AM, 0)                          AS 채권조정
    ,ISNULL(CO.OPEN_AM, ISNULL(O.OPEN_AM,0)) + A.마감기준매출 - A.수금액 + ISNULL(J.ADJUST_AM,0) AS 채권잔액
    ,ISNULL(O.OPEN_AM,0) + A.출고기준매출 - A.수금액 + ISNULL(J.ADJUST_AM,0) AS 채권잔액_출고기준
    ,A.출고기준매출 - A.마감기준매출                  AS 미마감채권                 -- 회계 미확정분
    ,A.미마감액                                      AS 출고미마감액_공급가
    ,A.수주건수
    ,CAST(CASE WHEN A.마감기준매출 <> 0 THEN A.수금액 / A.마감기준매출 * 100 END AS DECIMAL(19,2)) AS 회수율_PCT
    ,ISNULL(LM.YUSIN_AM, TR.CREDIT_AM)               AS 여신한도                  -- LCR_LIMIT 우선
    ,LM.DAMBO_AM                                     AS 담보한도
    ,LM.SINYONG_AM                                   AS 신용한도
    ,CAST(CASE WHEN ISNULL(ISNULL(NULLIF(LM.YUSIN_AM,0),TR.CREDIT_AM),0) <> 0
               THEN (ISNULL(CO.OPEN_AM,ISNULL(O.OPEN_AM,0)) + A.마감기준매출 - A.수금액)
                    / ISNULL(NULLIF(LM.YUSIN_AM,0), TR.CREDIT_AM) * 100
               END AS DECIMAL(19,2))                 AS 여신소진율_PCT
    ,여신상태 = CASE
         WHEN ISNULL(ISNULL(NULLIF(LM.YUSIN_AM,0),TR.CREDIT_AM),0) = 0 THEN N'한도미등록'
         WHEN (ISNULL(CO.OPEN_AM,ISNULL(O.OPEN_AM,0))+A.마감기준매출-A.수금액)
              > ISNULL(NULLIF(LM.YUSIN_AM,0),TR.CREDIT_AM)       THEN N'1.한도초과'
         WHEN (ISNULL(CO.OPEN_AM,ISNULL(O.OPEN_AM,0))+A.마감기준매출-A.수금액)
              > ISNULL(NULLIF(LM.YUSIN_AM,0),TR.CREDIT_AM)*0.9   THEN N'2.한도임박'
         ELSE N'3.정상' END
FROM        AR A
LEFT  JOIN  STRADE TR WITH (NOLOCK) ON TR.CO_CD = A.CO_CD AND TR.TR_CD = A.TR_CD
-- 기초채권은 출고기준(LOPN_CRISU) / 마감기준(LOPN_CRISU_CLS) 테이블이 분리되어 있다
OUTER APPLY (SELECT OPEN_AM = SUM(CAST(ISNULL(OPEN_AM,0) AS DECIMAL(19,4)))
             FROM   LOPN_CRISU WITH (NOLOCK)
             WHERE  CO_CD=A.CO_CD AND TR_CD=A.TR_CD AND P_YR=LEFT(@BASE_DT,4)
               AND  ISNULL(USE_YN,N'1')=N'1') O
OUTER APPLY (SELECT ADJUST_AM = SUM(CAST(ISNULL(ADJUST_AM,0) AS DECIMAL(19,4)))
             FROM   LCR_ADJUST WITH (NOLOCK)
             WHERE  CO_CD=A.CO_CD AND TR_CD=A.TR_CD AND P_YR=LEFT(@BASE_DT,4)
               AND  ISNULL(USE_YN,N'1')=N'1') J
LEFT  JOIN  #CLSOPN CO ON CO.CO_CD = A.CO_CD AND CO.TR_CD = A.TR_CD
LEFT  JOIN  #LIMIT  LM ON LM.CO_CD = A.CO_CD AND LM.TR_CD = A.TR_CD
ORDER BY 채권잔액 DESC
;


/*==============================================================================================
  ** 쿼리 G : 지급 현황 (자재발주 -> 입고 -> 매입마감 -> 지급)
==============================================================================================*/
SELECT
     N'[G] 지급 현황 (구매 대금)'                    AS REPORT_NM
    ,A.TR_CD                                         AS 거래처코드
    ,TR.TR_NM                                        AS 거래처명
    ,A.OPEN_AM                                       AS 기초채무
    ,A.PO_AM                                         AS 발주금액
    ,A.RCV_AM                                        AS 입고금액
    ,A.CLS_AM                                        AS 매입마감금액
    ,A.PAY_AM                                        AS 지급액
    ,A.BEFORE_AM                                     AS 선급금
    ,A.OPEN_AM + A.CLS_AM - A.PAY_AM                 AS 채무잔액
    ,A.RCV_AM - A.CLS_AM                             AS 입고미마감액
    ,A.PO_AM  - A.RCV_AM                             AS 발주미입고액
    ,A.DOCU_CNT                                      AS 미기표마감건수
    ,CAST(CASE WHEN A.CLS_AM <> 0 THEN A.PAY_AM / A.CLS_AM * 100 END AS DECIMAL(19,2)) AS 지급율_PCT
    ,지급상태 = CASE WHEN A.OPEN_AM + A.CLS_AM - A.PAY_AM <= 0 THEN N'0.정산완료'
                     WHEN A.DOCU_CNT > 0                       THEN N'1.미기표 마감 존재'
                     WHEN A.RCV_AM > A.CLS_AM                   THEN N'2.입고 미마감'
                     ELSE N'3.지급대기' END
FROM        #AP    A
LEFT  JOIN  STRADE TR WITH (NOLOCK) ON TR.CO_CD = A.CO_CD AND TR.TR_CD = A.TR_CD
WHERE   A.PO_AM + A.RCV_AM + A.CLS_AM + A.PAY_AM + A.OPEN_AM <> 0
ORDER BY 채무잔액 DESC
;


/*==============================================================================================
  ** 쿼리 H : 이상징후 / 조치 리스트
==============================================================================================*/
SELECT
     N'[H] 이상징후'                                 AS REPORT_NM
    ,이상유형 = CASE
         WHEN T.OPEN_QT > 0 AND T.DUE_DT < @BASE_DT AND ISNULL(T.WO_CNT,0)=0
              THEN N'1.납기경과 + 작업지시 미등록'
         WHEN T.OPEN_QT > 0 AND T.DUE_DT < @BASE_DT
              THEN N'2.납기경과 (미출고)'
         WHEN T.MISU_MTL > 0 AND T.DUE_DT <= CONVERT(NVARCHAR(8), DATEADD(DAY,14,CONVERT(DATE,@BASE_DT)),112)
              THEN N'3.자재 미입고 + 납기 임박'
         WHEN ISNULL(T.ISU_QT_T,0) > 0 AND ISNULL(T.CLS_QT_T,0) < ISNULL(T.ISU_QT_T,0)
              THEN N'4.출고 후 매출마감 누락'
         WHEN ISNULL(T.CLS_QT_T,0) > 0 AND ISNULL(T.DOCU_YN,N'0') <> N'1'
              THEN N'5.매출마감 후 미기표'
         WHEN ISNULL(T.DOCU_YN,N'0') = N'1' AND T.DOCU_ST IS NULL
              THEN N'6.기표됐으나 전표 미확인(장부 미반영)'
         WHEN ISNULL(T.CLSH_AM_T,0) > 0 AND ISNULL(T.RCP_AM_T,0) = 0
              AND T.DUE_DT < CONVERT(NVARCHAR(8), DATEADD(DAY,-30,CONVERT(DATE,@BASE_DT)),112)
              THEN N'7.매출 30일 경과 미수금'
         WHEN ISNULL(T.GOOD_QT_T,0) > 0 AND ISNULL(T.MTL_AM_T,0) = 0
              THEN N'8.생산실적 있으나 재료비 0 (자재사용보고 누락)'
         WHEN ISNULL(T.MTL_AM_T,0) > T.SOG_AM AND T.SOG_AM > 0
              THEN N'9.재료비가 수주금액 초과 (역마진)'
         ELSE NULL END
    ,T.SO_NB                                         AS 수주번호
    ,T.SO_SQ                                         AS 순번
    ,T.DUE_DT                                        AS 납기일
    ,TR.TR_NM                                        AS 거래처
    ,T.ITEM_CD                                       AS 제품번호
    ,I.ITEM_NM                                       AS 제품명
    ,T.SO_QT                                         AS 수주수량
    ,T.OPEN_QT                                       AS 미출고잔량
    ,T.SOG_AM                                        AS 수주금액
    ,T.MTL_AM_T                                      AS 투입재료비
    ,T.CLSH_AM_T                                     AS 마감합계액
    ,T.RCP_AM_T                                      AS 수금액
    ,ISNULL(T.CLSH_AM_T,0) - ISNULL(T.RCP_AM_T,0)    AS 채권잔액
    ,T.MISU_MTL                                      AS 미입고자재종수
FROM        #TOT   T
LEFT  JOIN  STRADE TR WITH (NOLOCK) ON TR.CO_CD=T.CO_CD AND TR.TR_CD=T.TR_CD
LEFT  JOIN  SITEM  I  WITH (NOLOCK) ON I.CO_CD =T.CO_CD AND I.ITEM_CD=T.ITEM_CD
WHERE  (T.OPEN_QT > 0 AND T.DUE_DT < @BASE_DT)
    OR (T.MISU_MTL > 0 AND T.DUE_DT <= CONVERT(NVARCHAR(8), DATEADD(DAY,14,CONVERT(DATE,@BASE_DT)),112))
    OR (ISNULL(T.ISU_QT_T,0) > 0 AND ISNULL(T.CLS_QT_T,0) < ISNULL(T.ISU_QT_T,0))
    OR (ISNULL(T.CLS_QT_T,0) > 0 AND ISNULL(T.DOCU_YN,N'0') <> N'1')
    OR (ISNULL(T.DOCU_YN,N'0') = N'1' AND T.DOCU_ST IS NULL)
    OR (ISNULL(T.CLSH_AM_T,0) > 0 AND ISNULL(T.RCP_AM_T,0) = 0
        AND T.DUE_DT < CONVERT(NVARCHAR(8), DATEADD(DAY,-30,CONVERT(DATE,@BASE_DT)),112))
    OR (ISNULL(T.GOOD_QT_T,0) > 0 AND ISNULL(T.MTL_AM_T,0) = 0)
    OR (ISNULL(T.MTL_AM_T,0) > T.SOG_AM AND T.SOG_AM > 0)
ORDER BY 이상유형, T.DUE_DT
;


/*==============================================================================================
  ** 쿼리 I : 전체 요약 (경영 보고용 1행)
==============================================================================================*/
SELECT
     N'[I] 수주 진행 요약'                           AS REPORT_NM
    ,COUNT(*)                                        AS 수주라인수
    ,COUNT(DISTINCT T.SO_NB)                         AS 수주건수
    ,COUNT(DISTINCT T.TR_CD)                         AS 거래처수
    ,SUM(T.SO_QT)                                    AS 수주수량계
    ,SUM(T.SOG_AM)                                   AS 수주금액계
    ,SUM(T.ISU_QT_T)                                 AS 출고수량계
    ,SUM(T.OPEN_QT)                                  AS 미출고잔량계
    ,SUM(T.ISUG_AM_T)                                AS 출고금액계
    ,SUM(T.MTL_AM_T)                                 AS 투입재료비계
    ,SUM(T.CLSG_AM_T)                                AS 매출마감액계
    ,SUM(T.CLSH_AM_T)                                AS 채권발생액계_마감기준
    ,SUM(T.ISUH_AM_T)                                AS 채권발생액계_출고기준
    ,SUM(ISNULL(T.ISUH_AM_T,0) - ISNULL(T.CLSH_AM_T,0)) AS 미마감채권계
    ,SUM(T.RCP_AM_T)                                 AS 수금액계
    ,SUM(ISNULL(T.CLSH_AM_T,0) - ISNULL(T.RCP_AM_T,0)) AS 채권잔액계
    ,SUM(CASE WHEN T.OPEN_QT > 0 AND T.DUE_DT < @BASE_DT THEN 1 ELSE 0 END) AS 납기경과건수
    ,SUM(CASE WHEN ISNULL(T.CLS_QT_T,0) > 0 AND ISNULL(T.DOCU_YN,N'0') <> N'1' THEN 1 ELSE 0 END) AS 미기표건수
    ,CAST(CASE WHEN SUM(T.SO_QT) <> 0 THEN SUM(T.ISU_QT_T)/SUM(T.SO_QT)*100 END AS DECIMAL(19,2)) AS 출고달성률_PCT
    ,CAST(CASE WHEN SUM(T.CLSH_AM_T) <> 0 THEN SUM(T.RCP_AM_T)/SUM(T.CLSH_AM_T)*100 END AS DECIMAL(19,2)) AS 회수율_PCT
    ,CAST(CASE WHEN SUM(T.SOG_AM) <> 0
               THEN (SUM(T.SOG_AM)-SUM(ISNULL(T.MTL_AM_T,0)))/SUM(T.SOG_AM)*100 END AS DECIMAL(19,2)) AS 재료비차감이익률_PCT
FROM   #TOT T
;


DROP TABLE #SO, #WO, #PRD, #MTL, #UM, #PO, #ISU, #CLS, #AR, #AP, #TOT, #CLSOPN, #LIMIT;
GO


/*==============================================================================================
  [ 부록 1 ] 도입 전 필수 검증
  ----------------------------------------------------------------------------------------------
  -- (1) 수주 -> 작업지시 연결 여부 (②단계의 전제)
     SELECT COUNT(*) 전체지시,
            SUM(CASE WHEN ISNULL(SO_NB,'')='' THEN 1 ELSE 0 END) 수주미연결
     FROM   LWO_WF WHERE CO_CD='1000' AND USE_YN='1'
       AND  ORD_DT BETWEEN '20260101' AND '20261231';
     --> 수주미연결이 대부분이면 ②~⑦ 단계가 비므로, 품목+기간 근사매칭으로 대체하거나
         해당 컬럼(SO_NB/LN_SQ) 입력 운영을 먼저 정착시켜야 한다.

  -- (2) 전표 연동 키 분포
     SELECT DOCU_YN, COUNT(*) 건수,
            SUM(CASE WHEN ISNULL(DOCU_DT,'')='' THEN 1 ELSE 0 END) 기표일자없음
     FROM   LSALECLS WHERE CO_CD='1000' GROUP BY DOCU_YN;

  -- (3) 전표 코드값 확인 (쿼리 E 의 라벨 확정)
     SELECT DOCU_ST, DOCU_TY, GET_FG, COUNT(*) FROM ADOCUH
     WHERE CO_CD='1000' GROUP BY DOCU_ST, DOCU_TY, GET_FG ORDER BY 4 DESC;
     SELECT DRCR_FG, COUNT(*), SUM(ACCT_AM) FROM ADOCUD
     WHERE CO_CD='1000' GROUP BY DRCR_FG;
     --> 본 쿼리는 DRCR_FG='1'을 차변으로 가정했다. 실제 코드로 교체할 것.

  -- (4) 수금 <-> 출고 매칭률 (⑫ 채권추적의 전제)
     SELECT COUNT(*) 전체수금라인,
            SUM(CASE WHEN ISNULL(ISU_NB,'')='' THEN 1 ELSE 0 END) 출고미매칭
     FROM   LRCP_D WHERE CO_CD='1000';
     --> 출고미매칭이 많으면 수주 단위 채권추적이 불가하므로, 쿼리 F(거래처 단위)만 사용한다.

  -- (5) 여신한도 등록률 (쿼리 F)
     --   STRADE.CREDIT_AM(여신한도금액) / LIMIT_AM(한도금액) / CREDITCTRL_YN(여신통제방법)
     SELECT COUNT(*) 전체거래처,
            SUM(CASE WHEN ISNULL(CREDIT_AM,0)=0 THEN 1 ELSE 0 END) 여신한도미등록,
            SUM(CASE WHEN ISNULL(LIMIT_AM ,0)=0 THEN 1 ELSE 0 END) 한도금액미등록
     FROM   STRADE WHERE CO_CD='1000' AND USE_YN='1';
     --> 미등록이 대부분이면 쿼리 F 의 여신소진율은 무의미하므로 컬럼을 숨기는 편이 낫다.

  -- (5-1) 영업담당자 명칭 테이블 (선택)
     SELECT name FROM sys.tables WHERE name IN ('LPLNNERCD','LPLNNERSCD');
     --> 존재하면 쿼리 A 에 LEFT JOIN LPLNNERCD PL ON PL.CO_CD=T.CO_CD AND PL.PLN_CD=T.PLN_CD
         를 추가해 담당자명을 표시할 수 있다. (명세서 누락 테이블이라 기본 제외)

  -- (5-1) 출고기준 vs 마감기준 채권 대사  ★ 차이 = 미마감(회계 미확정) 채권
     SELECT TR_CD,
            출고기준 = SUM(ISUH),
            마감기준 = SUM(CLSH),
            미마감   = SUM(ISUH) - SUM(CLSH)
     FROM (
        SELECT H.TR_CD, ISUH = SUM(D.ISUH_AM), CLSH = 0
        FROM   LDELIVER H INNER JOIN LDELIVER_D D ON D.CO_CD=H.CO_CD AND D.ISU_NB=H.ISU_NB
        WHERE  H.CO_CD='1000' AND H.ISU_DT BETWEEN '20260101' AND '20261231'
          AND  H.SO_FG IN ('0','2','7') AND D.USE_YN='1'
        GROUP BY H.TR_CD
        UNION ALL
        SELECT H.TR_CD, 0, SUM(D.CLSH_AM)
        FROM   LSALECLS H INNER JOIN LSALECLS_D D ON D.CO_CD=H.CO_CD AND D.CLS_NB=H.CLS_NB
        WHERE  H.CO_CD='1000' AND H.CLS_DT BETWEEN '20260101' AND '20261231'
          AND  D.USE_YN='1'
        GROUP BY H.TR_CD ) X
     GROUP BY TR_CD HAVING SUM(ISUH) <> SUM(CLSH) ORDER BY 미마감 DESC;
     --> 미마감이 큰 거래처는 매출마감 누락이므로 회계 확정 전 반드시 처리해야 한다.

  -- (5-2) 거래구분(SO_FG) / 수금 모듈구분(RCPAM_FG) 분포  ★ 채권 산식의 전제
     SELECT SO_FG, COUNT(*) 건수, SUM(D.ISUH_AM) 합계액
     FROM   LDELIVER H INNER JOIN LDELIVER_D D ON D.CO_CD=H.CO_CD AND D.ISU_NB=H.ISU_NB
     WHERE  H.CO_CD='1000' GROUP BY SO_FG ORDER BY 1;
     --> 표준 미수채권현황은 SO_FG IN ('0','2','7') 만 채권으로 본다.
         사이트에 다른 값이 있으면 어떤 거래인지 확인 후 조건을 조정할 것.

     SELECT RCPAM_FG, COUNT(*), SUM(NORMAL_AM+BEFORE_AM) FROM LRCP_D
     WHERE  CO_CD='1000' GROUP BY RCPAM_FG;
     --> '0' = 영업 모듈 수금. 다른 값은 타 모듈 수금이므로 채권에서 제외한다.

  -- (5-3) 수출 사용 여부 (부록 4-5 참조)
     SELECT COUNT(*) 수출선적건수 FROM LEBL WHERE CO_CD='1000';

  -- (5-4) 기초채권/채무·여신한도 테이블 확인  ★ 명세서 누락분
     SELECT name FROM sys.tables
     WHERE name IN ('LOPN_CRISU','LOPN_CRISU_CLS','LOPN_PAY','LOPN_PAY_CLS','LCR_LIMIT','LCR_ADJUST');
     --> 기초채권은 출고기준(LOPN_CRISU) / 마감기준(LOPN_CRISU_CLS) 2종
     --  기초채무는 LOPN_PAY / LOPN_PAY_CLS 2종
     --  여신한도는 전용 테이블 LCR_LIMIT 이 우선 (STRADE.CREDIT_AM 은 대체값)
     SELECT TOP 20 * FROM LCR_LIMIT WHERE CO_CD='1000';
     --  DAMBO_AM(담보) SINYONG_AM(신용) ETC_AM(기타) YUSIN_AM(여신) YUSIN_FG YUSIN_TY TERMS

  -- (6) 테이블 실존 확인
     SELECT name FROM sys.tables
     WHERE name IN ('LSO','LSO_D','LWO_WF','LWO_REQ_WF','LPO','LPO_D','LSTOCK','LSTOCK_D',
                    'LSTKMOVE','LSTKMOVE_D','LORCV_H','LPRDINWH','LMTL_USE',
                    'LDELIVER','LDELIVER_D','LSALECLS','LSALECLS_D','LPURCLS','LPURCLS_D',
                    'ADOCUH','ADOCUD','LRCP','LRCP_D','LPAY','LPAY_D',
                    'LOPN_CRISU','LOPN_CRISU_CLS','LOPN_PAY','LOPN_PAY_CLS','LCR_ADJUST',
                    'LCR_LIMIT','LINV_TAV','CIV_PUR_TAV','LPLNNERCD')
     ORDER BY name;


  [ 부록 2 ] 단가 기준 선택 가이드
  ----------------------------------------------------------------------------------------------
   @UM_BASE_FG   단가 소스                    특징                              권장 상황
   ------------  --------------------------   -------------------------------   ------------------
   'INV'(기본)   LINV_TAV.ISU_UM              전월 재고평가 확정 출고단가       월중 수시 조회
                 (SMM~FMM + GISU 키)          평가 마감된 값이라 안정적         (요청하신 기준)
   'PUR'         LSTOCK_D 가중평균            (입고금액합/입고수량합)           구매 시각 원가
                                              평가 무관, 매입 실적 그대로       평가 미운영 사이트
   'TAV'         CIV_PUR_TAV.ISU_UM           원가모듈 확정 (기초+입고)/(수량)  ERP 원가와 대사

   * 세 기준 모두 단가 없는 품목은 SITEM.PURCH_UM 으로 자동 보완된다 (UM_SRC 컬럼으로 확인).
   * 'INV' 는 @TAV_YM(기본: 전월)로 평가월을 바꿀 수 있다.


  [ 부록 3 ] 자재발주 매칭 정밀도 ⚠️
  ----------------------------------------------------------------------------------------------
  ③단계의 자재발주(#PO의 PO_QT/PORCV_QT)는 **품목 기준 합산**이다.
  즉 "이 수주의 이 자재에 대한 발주"가 아니라 "해당 자재의 전체 미마감 발주"가 붙는다.

  수주 단위로 정확히 매칭하려면 청구번호를 경유해야 한다.

      LWO_REQ_WF (작지 자재청구)
        -> LPUR_REQ_D (구매청구)   ※ 작지청구 -> 구매청구 연결 컬럼 확인 필요
        -> LPO_D (REQ_NB + REQ_SQ + ITEM_CD)
        -> LSTOCK_D (PO_NB + PO_SQ + ITEM_CD)

  사이트가 작업지시 자재청구를 구매청구로 자동 전환하는지 먼저 확인하십시오.
  전환하지 않고 구매팀이 별도 청구하는 운영이면 **수주 단위 발주 추적은 불가**하며,
  품목 기준 합산(현재 구현)이 최선입니다. 이 경우 쿼리 C 의 발주 관련 컬럼은
  "해당 자재의 전사 발주 현황"으로 해석해야 합니다.

      SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS
      WHERE TABLE_NAME='LPUR_REQ_D' AND COLUMN_NAME IN ('WO_CD','SO_NB','WOBOM_SQ');


  [ 부록 4 ] 한계 및 확장
  ----------------------------------------------------------------------------------------------
  1) **원가는 재료비만** 반영한다. 노무비·가공비는 원가모듈(CIV_CONVCST/CIV_OE) 배부 결과이며
     수주 단위로 직접 귀속되지 않는다. 완전원가가 필요하면 재료비 비율을 배부기준으로 사용하라.
  2) **부가세 전표 분리**: LSALECLS 는 DOCU_DT_PLUS / DOCU_SQ_PLUS 를 별도 보유한다.
     부가세를 별도 전표로 발행하는 사이트는 #CLS 의 ADOCUH 조인을 UNION 으로 확장할 것.
  3) **반품**: LDELIVER_D.ISU_NB_ORG 가 있으면 반품이다. 현재는 RETURN_YN 으로 표시만 하고
     수량은 그대로 합산한다(음수로 들어오면 자동 상계). 별도 집계가 필요하면 분리하라.
  4) **지급(⑬)은 거래처 단위**다. 발주-입고-마감-지급을 수주 단위로 귀속하려면
     LPO.PJT_CD 또는 관리구분을 수주와 연결하는 운영 규칙이 선행되어야 한다.
  5) **수출(직수출) 미포함**: 본 쿼리의 ⑨매출마감은 국내 `LSALECLS` 만 본다.
     직수출은 **`LEBL` / `LEBL_D`(수출선적)** 이 매출마감 역할을 하며 컬럼명이 다르다.

         LEBL   . EBL_NB, BL_DT(선적일)
         LEBL_D . EBL_NB + EBL_SQ, ISU_NB + ISU_SQ(출고연결), BL_QT, KOR_UM, KOR_AM(원화)
                  EXCH_CD / EXCH_UM / EXCH_AM (외화)

     수출 비중이 있는 사이트는 #CLS 를 아래 형태로 UNION 해야 한다.

         LSALECLS  L + LSALECLS_D D  ->  LDELIVER_D (D.ISU_NB + D.ISU_SQ + D.ITEM_CD)
         UNION ALL
         LEBL      L + LEBL_D      D  ->  LDELIVER_D (D.ISU_NB + D.ISU_SQ + D.ITEM_CD)

     (수입은 LIBL / LIBL_D 가 대응. 매입마감 LPURCLS 와 UNION)

  6) **성능**: 수주 라인이 수만 건이면 #PO 의 LPO_D 품목 합산이 가장 무겁다.
     기간을 좁히거나 @OPEN_ONLY='Y'(미완결만)로 실행할 것.

  [ 부록 5 ] 성능 인덱스
  ----------------------------------------------------------------------------------------------
     LSO_D      (CO_CD, SO_NB, SO_SQ) INCLUDE (ITEM_CD, SO_QT, ISU_QT, DUE_DT, EXPIRE_YN)
     LWO_WF     (CO_CD, SO_NB, LN_SQ) INCLUDE (WO_CD, ITEM_QT, DOC_ST, EXPIRE_YN)
     LORCV_H    (CO_CD, WO_CD)        INCLUDE (DOC_CD, DOC_DT, ITEM_QT, BAD_YN, SUB_TP)
     LMTL_USE   (CO_CD, WR_CD)        INCLUDE (ITEM_CD, USE_QT, USE_DT)
     LDELIVER_D (CO_CD, SO_NB, SO_SQ) INCLUDE (ISU_NB, ISU_SQ, ISU_QT, ISUG_AM, CLS_QT)
     LSALECLS_D (CO_CD, ISU_NB, ISU_SQ) INCLUDE (CLS_NB, CLS_SQ, CLS_QT, CLSG_AM, CLSH_AM)
     LSALECLS   (CO_CD, CLS_NB)       INCLUDE (CLS_DT, DOCU_YN, DOCU_DT, DOCU_SQ)
     ADOCUH     (CO_CD, ISU_DT, ISU_SQ)
     LRCP_D     (CO_CD, ISU_NB, ISU_SQ) INCLUDE (RCP_NB, NORMAL_AM, BEFORE_AM)
     LPO_D      (CO_CD, ITEM_CD)      INCLUDE (PO_NB, PO_QT, RCV_QT, DUE_DT, EXPIRE_YN)
     LWO_REQ_WF (CO_CD, WO_CD, WOBOM_SQ)

  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------

  -- (1) ★ 수주잔량 표준산식(SO_QT - ISU_QT)의 근거. ISU_QT 가 비어 있으면 잔량이 전부 미출고로 나온다
     SELECT COUNT(*) 전체, SUM(CASE WHEN ISU_QT IS NULL THEN 1 ELSE 0 END) ISU_QT_NULL
     FROM   LSO_D WHERE CO_CD='1000';
     --> 대부분 NULL 이면 출고원장 재집계(VL_SO_ISU) 기준으로 바꿔야 한다.

  -- (2) ★ 진행 판정 코드값. 반대로 걸면 전 건이 사라진다
     SELECT EXPIRE_YN, COUNT(*) FROM LSO_D WHERE CO_CD='1000' GROUP BY EXPIRE_YN;
     --> '1' 이 진행/미마감이다.

  -- (3) 단가 기준(@UM_BASE_FG)과 기수(@GISU). 'INV' 는 아래 분포를 보고 정한다
     SELECT GISU, MIN(SMM), MAX(FMM), COUNT(*) FROM LINV_TAV WHERE CO_CD='1000' GROUP BY GISU;

  -- (4) 13단계 중 사이트에 없는 모듈을 먼저 파악한다 — Z00_사이트진단.sql 을 선행할 것

  [ 한계 ]
  ----------------------------------------------------------------------------------------------

  1) **③자재발주 구간은 수주-발주 직결 키가 없다.** 품목 기준 근사 매칭이므로, 같은 원자재를
     여러 수주가 함께 쓰면 배분이 부정확하다. `LPO.PJT_CD` 또는 관리구분으로 수주를 물리는
     운영 규칙이 있어야 정확해진다.

  2) **단가는 전월 재고평가의 기수 평균 출고단가**다. 수주 시점·출고 시점의 실제 단가가
     아니므로 ⑦자재사용 금액은 규모 파악용이다.

  3) **⑬지급은 구매 대금**이라 수주 1건에 직접 귀속되지 않는다. 같은 발주가 여러 수주에
     걸쳐 있으면 그 발주의 지급이 여러 수주에 중복으로 보인다.

  4) **13단계를 모두 운영하는 사이트는 드물다.** 빈 구간이 "정체"인지 "미사용 모듈"인지는
     Z00 진단의 판정 매트릭스와 대조해야 구분된다.

==============================================================================================*/
