/*==============================================================================================
  [ iCUBE ] P-03  실시간 재고 추적 (창고 · 장소 · LOT)                              (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : "지금 이 품목이 어느 창고 어느 장소에 몇 개, 어느 LOT 으로 있는가"를 즉시 답한다.
         + 가용재고(주문·할당·입고예정 반영)로 "팔 수 있는 수량"까지 낸다.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ ★ 3계층 소스 선택 — 이 리포트의 핵심 설계 ]
  ----------------------------------------------------------------------------------------------
     재고 조회 테이블이 10종 넘는 이유는 **계층이 다르기 때문**이다. 목적에 맞는 계층을 고르면
     성능과 정확도가 동시에 확보된다.

       [3계층] 사전집계  VL_INVLC / L_INVSUM_LC   연도 집계. 현재고 조회 최속.
                                                  ※ IO_DT 없음 → 과거 특정일 조회 불가
       [2계층] 통합 뷰   LINVTORY_D               창고 + 실적입고 통합 (BASELOC_CD/LOC_CD)
       [1계층] 원장      LINVTORY                 건별 수불. 일자 조건 가능. 가장 느림

     @SRC 파라미터로 선택한다. 'AUTO' 는 아래 규칙으로 자동 판정한다.
       · @AS_OF_YN='0' (현재고)   → 사전집계 뷰 (VL_INVLC)  ← 가장 빠름
       · @AS_OF_YN='1' (특정일)   → 원장 (LINVTORY + IO_DT <= 기준일)
     선택한 소스가 없으면 아래 계층으로 자동 강등한다.

  ----------------------------------------------------------------------------------------------
  [ 산식 ]
  ----------------------------------------------------------------------------------------------
     현재고 = SUM(IOPEN_QT) + SUM(IRCV_QT) - SUM(IISU_QT)

     -- 용도별 출고 분할 (LX_BOM_BACK_INVTORY 패턴)
     생산출고 = SUM(CASE WHEN GRP_FG='0' AND IO_FG='2' THEN IISU_QT END)
     매출출고 = SUM(CASE WHEN GRP_FG='3' AND IO_FG='2' THEN IISU_QT END)
     기타출고 = SUM(CASE WHEN GRP_FG='6' AND IO_FG='2' THEN IISU_QT END)

     가용재고 = 현재고 - 수주잔량 - 자재할당잔량 + 발주잔량 - 안전재고

  ----------------------------------------------------------------------------------------------
  [ 반드시 지킨 것 ]
  ----------------------------------------------------------------------------------------------
   1. **연도 경계.** `P_YR` 파티션이므로 연초 조회 시 전년 이월(`GRP_FG='6'`, `IO_NB='XY'`)이
      기초로 넘어왔는지 확인해야 한다. 쿼리 H 가 이 점검이다.
   2. **단종품 제외** — `S_CD <> 'Z00'`. 실무 쿼리 다수의 공통 관례. 빼면 재고 리스트가 오염된다.
   3. **LOT 은 `SITEM.LOT_FG='1'` 품목만 의미가 있다.** 비관리 품목의 LOT 은 공백이거나 쓰레기값.
   4. **재공은 `LINVTORY` 가 아니라 `LINV_WIP`** 에 있다. 통합 재고는 쿼리 G 에서 UNION 한다.
   5. 마이너스 재고가 나오면 `SYSCFG` 모듈 'S' / 코드 '13'(마이너스재고통제)을 확인할 것.
      `0`(허용)이면 데이터 자체가 음수일 수 있어 가용재고 신뢰도가 떨어진다.
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@BASE_DT  NVARCHAR(8)  = N'20260915'     -- 기준일 (@AS_OF_YN='1' 일 때만 의미)
    ,@AS_OF_YN NCHAR(1)     = N'0'            -- 0 현재고(최속) / 1 특정일 기준
    ,@SRC      NVARCHAR(10) = N'AUTO'         -- AUTO / VL_INVLC / L_INVSUM_LC / LINVTORY / LINVTORY_D
    ,@ITEM_CD  NVARCHAR(25) = NULL
    ,@WH_CD    NVARCHAR(10) = NULL            -- 특정 창고
    ,@ACCT_FG  NVARCHAR(1)  = NULL            -- 0원재료 1부재료 2제품 4반제품 5상품
    ,@EXC_Z00  NCHAR(1)     = N'1'            -- 단종품 제외
    ,@EXC_ZERO NCHAR(1)     = N'1'            -- 재고 0 인 행 제외
;

DECLARE @P_YR NVARCHAR(4) = LEFT(@BASE_DT, 4);
DECLARE @SQL NVARCHAR(MAX), @USED NVARCHAR(30);

IF OBJECT_ID('tempdb..#STK')  IS NOT NULL DROP TABLE #STK;
IF OBJECT_ID('tempdb..#DMD')  IS NOT NULL DROP TABLE #DMD;
IF OBJECT_ID('tempdb..#SUP')  IS NOT NULL DROP TABLE #SUP;


/*==============================================================================================
  1. #STK : 재고 적재  ─ 3계층 중 선택 (없으면 자동 강등)
==============================================================================================*/
CREATE TABLE #STK (
     ITEM_CD  NVARCHAR(25)
    ,WH_CD    NVARCHAR(10)
    ,LC_CD    NVARCHAR(10)
    ,OPEN_QT  DECIMAL(19,6) DEFAULT 0
    ,RCV_QT   DECIMAL(19,6) DEFAULT 0
    ,ISU_QT   DECIMAL(19,6) DEFAULT 0
    ,PISU_QT  DECIMAL(19,6) DEFAULT 0     -- 생산출고 GRP_FG='0'
    ,SISU_QT  DECIMAL(19,6) DEFAULT 0     -- 매출출고 GRP_FG='3'
    ,EISU_QT  DECIMAL(19,6) DEFAULT 0     -- 기타출고 GRP_FG='6'
    ,PRCV_QT  DECIMAL(19,6) DEFAULT 0     -- 구매입고 GRP_FG='2'
    ,LAST_DT  NVARCHAR(8)   NULL
);

-- 소스 결정
IF @SRC = N'AUTO'
    SET @SRC = CASE WHEN @AS_OF_YN = N'1' THEN N'LINVTORY' ELSE N'VL_INVLC' END;

-- 강등 규칙 : 요청한 소스가 없으면 아래 계층으로
IF @SRC = N'VL_INVLC'    AND OBJECT_ID(N'dbo.VL_INVLC')    IS NULL SET @SRC = N'L_INVSUM_LC';
IF @SRC = N'L_INVSUM_LC' AND OBJECT_ID(N'dbo.L_INVSUM_LC') IS NULL SET @SRC = N'LINVTORY_D';
IF @SRC = N'LINVTORY_D'  AND OBJECT_ID(N'dbo.LINVTORY_D')  IS NULL SET @SRC = N'LINVTORY';

SET @USED = @SRC;

/*----------------------------------------------------------------------------------------------
  1-A. 사전집계 뷰 (VL_INVLC) — 현재고 최속. GRP_FG 없음 → 용도별 분할 불가
----------------------------------------------------------------------------------------------*/
IF @SRC = N'VL_INVLC'
BEGIN
    SET @SQL = N'
        INSERT INTO #STK (ITEM_CD, WH_CD, LC_CD, OPEN_QT, RCV_QT, ISU_QT)
        SELECT V.ITEM_CD, V.WH_CD, V.LC_CD
              ,SUM(CAST(ISNULL(V.IOPEN,0) AS DECIMAL(19,6)))
              ,SUM(CAST(ISNULL(V.IRCV ,0) AS DECIMAL(19,6)))
              ,SUM(CAST(ISNULL(V.IISU ,0) AS DECIMAL(19,6)))
        FROM   dbo.VL_INVLC V
        WHERE  V.CO_CD = @p_CO AND V.P_YR = @p_YR
          AND  (@p_DIV  IS NULL OR V.DIV_CD  = @p_DIV)
          AND  (@p_ITEM IS NULL OR V.ITEM_CD = @p_ITEM)
          AND  (@p_WH   IS NULL OR V.WH_CD   = @p_WH)
        GROUP BY V.ITEM_CD, V.WH_CD, V.LC_CD';
END

/*----------------------------------------------------------------------------------------------
  1-B. 수불유형별 집계 (L_INVSUM_LC) — GRP_FG 보유 → 용도별 분할 가능
----------------------------------------------------------------------------------------------*/
ELSE IF @SRC = N'L_INVSUM_LC'
BEGIN
    SET @SQL = N'
        INSERT INTO #STK (ITEM_CD, WH_CD, LC_CD, OPEN_QT, RCV_QT, ISU_QT,
                          PISU_QT, SISU_QT, EISU_QT, PRCV_QT)
        SELECT V.ITEM_CD, V.WH_CD, V.LC_CD
              ,SUM(CAST(ISNULL(V.IOPEN,0) AS DECIMAL(19,6)))
              ,SUM(CAST(ISNULL(V.IRCV ,0) AS DECIMAL(19,6)))
              ,SUM(CAST(ISNULL(V.IISU ,0) AS DECIMAL(19,6)))
              ,SUM(CASE WHEN V.GRP_FG = N''0'' THEN CAST(ISNULL(V.IISU,0) AS DECIMAL(19,6)) ELSE 0 END)
              ,SUM(CASE WHEN V.GRP_FG = N''3'' THEN CAST(ISNULL(V.IISU,0) AS DECIMAL(19,6)) ELSE 0 END)
              ,SUM(CASE WHEN V.GRP_FG = N''6'' THEN CAST(ISNULL(V.IISU,0) AS DECIMAL(19,6)) ELSE 0 END)
              ,SUM(CASE WHEN V.GRP_FG = N''2'' THEN CAST(ISNULL(V.IRCV,0) AS DECIMAL(19,6)) ELSE 0 END)
        FROM   dbo.L_INVSUM_LC V
        WHERE  V.CO_CD = @p_CO AND V.P_YR = @p_YR
          AND  (@p_DIV  IS NULL OR V.DIV_CD  = @p_DIV)
          AND  (@p_ITEM IS NULL OR V.ITEM_CD = @p_ITEM)
          AND  (@p_WH   IS NULL OR V.WH_CD   = @p_WH)
        GROUP BY V.ITEM_CD, V.WH_CD, V.LC_CD';
END

/*----------------------------------------------------------------------------------------------
  1-C / 1-D. 원장 (LINVTORY / LINVTORY_D) — 일자 조건 가능. 가장 정확하고 가장 느림
----------------------------------------------------------------------------------------------*/
ELSE
BEGIN
    SET @SQL = N'
        INSERT INTO #STK (ITEM_CD, WH_CD, LC_CD, OPEN_QT, RCV_QT, ISU_QT,
                          PISU_QT, SISU_QT, EISU_QT, PRCV_QT, LAST_DT)
        SELECT V.ITEM_CD, V.WH_CD, V.LC_CD
              ,SUM(CAST(ISNULL(V.IOPEN_QT,0) AS DECIMAL(19,6)))
              ,SUM(CAST(ISNULL(V.IRCV_QT ,0) AS DECIMAL(19,6)))
              ,SUM(CAST(ISNULL(V.IISU_QT ,0) AS DECIMAL(19,6)))
              ,SUM(CASE WHEN V.GRP_FG=N''0'' AND V.IO_FG=N''2'' THEN CAST(ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
              ,SUM(CASE WHEN V.GRP_FG=N''3'' AND V.IO_FG=N''2'' THEN CAST(ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
              ,SUM(CASE WHEN V.GRP_FG=N''6'' AND V.IO_FG=N''2'' THEN CAST(ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
              ,SUM(CASE WHEN V.GRP_FG=N''2'' AND V.IO_FG=N''1'' THEN CAST(ISNULL(V.IRCV_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
              ,MAX(V.IO_DT)
        FROM   dbo.' + @SRC + N' V WITH (NOLOCK)
        WHERE  V.CO_CD = @p_CO AND V.P_YR = @p_YR
          AND  ISNULL(V.USE_YN, N''1'') = N''1''
          AND  ISNULL(V.EXPIRE_YN, N''1'') = N''1''
          AND  (@p_ASOF = N''0'' OR V.IO_DT <= @p_DT)
          AND  (@p_DIV  IS NULL OR V.DIV_CD  = @p_DIV)
          AND  (@p_ITEM IS NULL OR V.ITEM_CD = @p_ITEM)
          AND  (@p_WH   IS NULL OR V.WH_CD   = @p_WH)
        GROUP BY V.ITEM_CD, V.WH_CD, V.LC_CD';
END

EXEC sp_executesql @SQL
    ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YR NVARCHAR(4), @p_DT NVARCHAR(8)
      ,@p_ASOF NCHAR(1), @p_ITEM NVARCHAR(25), @p_WH NVARCHAR(10)'
    ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_YR=@P_YR, @p_DT=@BASE_DT
    ,@p_ASOF=@AS_OF_YN, @p_ITEM=@ITEM_CD, @p_WH=@WH_CD;

CREATE CLUSTERED INDEX IX_STK ON #STK (ITEM_CD, WH_CD, LC_CD);
PRINT N'[1] 재고 소스 = ' + @USED + N' / 적재 ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 행';

-- 단종품 / 계정 필터 (마스터 기준)
IF @EXC_Z00 = N'1' OR @ACCT_FG IS NOT NULL
    DELETE S FROM #STK S
    LEFT JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = S.ITEM_CD
    WHERE (@EXC_Z00 = N'1' AND ISNULL(I.S_CD, N'') = N'Z00')
       OR (@ACCT_FG IS NOT NULL AND ISNULL(I.ACCT_FG, N'') <> @ACCT_FG);


/*==============================================================================================
  2. #DMD / #SUP : 가용재고 산정용 수요 · 공급 (LDEMAND_STORY 산식과 동일 축)
==============================================================================================*/
-- 수요 : 수주 잔량 + 자재 청구 잔량
SELECT
     D.ITEM_CD
    ,SO_BAL  = SUM(CASE WHEN D.SRC = N'SO'  THEN D.QT ELSE 0 END)
    ,MTL_BAL = SUM(CASE WHEN D.SRC = N'MTL' THEN D.QT ELSE 0 END)
INTO #DMD
FROM (
    -- 수주 미출고 잔량
    SELECT SRC = N'SO', X.ITEM_CD
          ,QT = CAST(ISNULL(X.SO_QT,0) - ISNULL(X.ISU_QT,0) AS DECIMAL(19,6))
    FROM       LSO   H WITH (NOLOCK)
    INNER JOIN LSO_D X WITH (NOLOCK) ON X.CO_CD = H.CO_CD AND X.SO_NB = H.SO_NB
    WHERE  H.CO_CD = @CO_CD
      AND  ISNULL(X.USE_YN, N'1') = N'1' AND ISNULL(X.EXPIRE_YN, N'1') = N'1'
      AND  ISNULL(X.SO_QT,0) - ISNULL(X.ISU_QT,0) > 0
      AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
    UNION ALL
    -- 작업지시 자재 청구 미출고 잔량 (할당)
    SELECT SRC = N'MTL', Q.ITEM_CD
          ,QT = CAST(ISNULL(Q.REQ_QT,0) - ISNULL(Q.ISU_QT,0) AS DECIMAL(19,6))
    FROM       LWO_REQ_WF Q WITH (NOLOCK)
    INNER JOIN LWO_WF     W WITH (NOLOCK) ON W.CO_CD = Q.CO_CD AND W.WO_CD = Q.WO_CD
    WHERE  Q.CO_CD = @CO_CD
      AND  ISNULL(Q.USE_YN, N'1') = N'1'
      AND  ISNULL(W.EXPIRE_YN, N'1') = N'1'                 -- 진행 지시만
      AND  ISNULL(Q.REQ_QT,0) - ISNULL(Q.ISU_QT,0) > 0
      AND  (@DIV_CD IS NULL OR W.DIV_CD = @DIV_CD)
) D
GROUP BY D.ITEM_CD;
CREATE CLUSTERED INDEX IX_DMD ON #DMD (ITEM_CD);

-- 공급 : 발주 미입고 잔량
SELECT
     D.ITEM_CD
    ,PO_BAL  = SUM(CAST(ISNULL(D.PO_QT,0) - ISNULL(R.RCV_QT,0) AS DECIMAL(19,6)))
    ,NEAR_DT = MIN(D.DUE_DT)
INTO #SUP
FROM       LPO   H WITH (NOLOCK)
INNER JOIN LPO_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.PO_NB = H.PO_NB
OUTER APPLY (
    SELECT RCV_QT = SUM(CAST(ISNULL(S.RCV_QT,0) AS DECIMAL(19,6)))
    FROM   LSTOCK_D S WITH (NOLOCK)
    WHERE  S.CO_CD = D.CO_CD AND S.PO_NB = D.PO_NB AND S.PO_SQ = D.PO_SQ
      AND  ISNULL(S.USE_YN, N'1') = N'1' AND ISNULL(S.EXPIRE_YN, N'1') = N'1'
) R
WHERE  H.CO_CD = @CO_CD
  AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
  AND  ISNULL(D.PO_QT,0) - ISNULL(R.RCV_QT,0) > 0
  AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
GROUP BY D.ITEM_CD;
CREATE CLUSTERED INDEX IX_SUP ON #SUP (ITEM_CD);


/*==============================================================================================
  ** 쿼리 A : 품목 × 창고 × 장소 현재고  (메인)
==============================================================================================*/
SELECT
     N'[A] 창고·장소별 재고'                        AS REPORT_NM
    ,@USED                                          AS 소스계층
    ,CASE @AS_OF_YN WHEN N'1' THEN @BASE_DT ELSE N'현재' END AS 기준
    ,S.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
    ,S.WH_CD                                        AS 창고코드
    ,W.WH_NM                                        AS 창고명
    ,S.LC_CD                                        AS 장소코드
    ,L.LC_NM                                        AS 장소명
    ,S.OPEN_QT                                      AS 기초수량
    ,S.RCV_QT                                       AS 입고수량
    ,S.ISU_QT                                       AS 출고수량
    ,현재고 = S.OPEN_QT + S.RCV_QT - S.ISU_QT
    ,S.PRCV_QT                                      AS 구매입고
    ,S.PISU_QT                                      AS 생산출고
    ,S.SISU_QT                                      AS 매출출고
    ,S.EISU_QT                                      AS 기타출고
    ,S.LAST_DT                                      AS 최종수불일
    ,정체일수 = CASE WHEN S.LAST_DT IS NOT NULL
                     THEN DATEDIFF(DAY, CONVERT(DATE,S.LAST_DT), CONVERT(DATE,@BASE_DT)) END
    ,재고상태 = CASE
         WHEN S.OPEN_QT + S.RCV_QT - S.ISU_QT <  0 THEN N'1.★마이너스 재고'
         WHEN S.OPEN_QT + S.RCV_QT - S.ISU_QT =  0 THEN N'2.재고 없음'
         WHEN S.LAST_DT IS NOT NULL
          AND DATEDIFF(DAY,CONVERT(DATE,S.LAST_DT),CONVERT(DATE,@BASE_DT)) > 180
                                                    THEN N'3.장기 정체(180일)'
         ELSE N'0.정상' END
    ,I.LOT_FG                                       AS LOT관리여부
FROM       #STK  S
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = S.ITEM_CD
LEFT  JOIN SWH   W WITH (NOLOCK) ON W.CO_CD = @CO_CD AND W.WH_CD   = S.WH_CD
LEFT  JOIN SLC   L WITH (NOLOCK) ON L.CO_CD = @CO_CD AND L.WH_CD   = S.WH_CD AND L.LC_CD = S.LC_CD
WHERE  @EXC_ZERO = N'0' OR S.OPEN_QT + S.RCV_QT - S.ISU_QT <> 0
ORDER BY 재고상태, S.ITEM_CD, S.WH_CD, S.LC_CD
;


/*==============================================================================================
  ** 쿼리 B : 품목별 현재고 + 가용재고  ★ "팔 수 있는 수량"
==============================================================================================*/
;WITH B AS (
    SELECT
         S.ITEM_CD
        ,OPEN_QT = SUM(S.OPEN_QT), RCV_QT = SUM(S.RCV_QT), ISU_QT = SUM(S.ISU_QT)
        ,PISU_QT = SUM(S.PISU_QT), SISU_QT = SUM(S.SISU_QT), PRCV_QT = SUM(S.PRCV_QT)
        ,WH_CNT  = COUNT(DISTINCT S.WH_CD)
        ,LAST_DT = MAX(S.LAST_DT)
    FROM   #STK S
    GROUP BY S.ITEM_CD
)
SELECT
     N'[B] 품목별 현재고 · 가용재고'                AS REPORT_NM
    ,B.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
    ,B.WH_CNT                                       AS 보관창고수
    ,현재고   = B.OPEN_QT + B.RCV_QT - B.ISU_QT
    ,B.OPEN_QT                                      AS 기초
    ,B.RCV_QT                                       AS 입고
    ,B.ISU_QT                                       AS 출고
    ,ISNULL(D.SO_BAL , 0)                           AS 수주잔량
    ,ISNULL(D.MTL_BAL, 0)                           AS 자재할당잔량
    ,ISNULL(P.PO_BAL , 0)                           AS 발주입고예정
    ,P.NEAR_DT                                      AS 최단입고예정일
    ,I.SAFESTOCK_QT                                 AS 안전재고
    ,가용재고 = (B.OPEN_QT + B.RCV_QT - B.ISU_QT)
              - ISNULL(D.SO_BAL,0) - ISNULL(D.MTL_BAL,0)
              + ISNULL(P.PO_BAL,0)
              - CAST(ISNULL(I.SAFESTOCK_QT,0) AS DECIMAL(19,6))
    ,순가용재고 = (B.OPEN_QT + B.RCV_QT - B.ISU_QT)
                - ISNULL(D.SO_BAL,0) - ISNULL(D.MTL_BAL,0)   -- 입고예정·안전재고 제외
    ,I.LEAD_DT                                      AS 리드타임일
    ,B.LAST_DT                                      AS 최종수불일
    ,판정 = CASE
         WHEN (B.OPEN_QT+B.RCV_QT-B.ISU_QT) < 0                             THEN N'1.★마이너스 재고'
         WHEN (B.OPEN_QT+B.RCV_QT-B.ISU_QT)
              - ISNULL(D.SO_BAL,0) - ISNULL(D.MTL_BAL,0) < 0                THEN N'2.★결품 (할당 초과)'
         WHEN (B.OPEN_QT+B.RCV_QT-B.ISU_QT)
              - ISNULL(D.SO_BAL,0) - ISNULL(D.MTL_BAL,0)
              + ISNULL(P.PO_BAL,0) < 0                                      THEN N'3.★입고예정 포함해도 부족'
         WHEN ISNULL(I.SAFESTOCK_QT,0) > 0
          AND (B.OPEN_QT+B.RCV_QT-B.ISU_QT) < I.SAFESTOCK_QT                THEN N'4.안전재고 미달'
         ELSE N'0.정상' END
FROM       B
LEFT  JOIN #DMD  D ON D.ITEM_CD = B.ITEM_CD
LEFT  JOIN #SUP  P ON P.ITEM_CD = B.ITEM_CD
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = B.ITEM_CD
WHERE  @EXC_ZERO = N'0' OR B.OPEN_QT + B.RCV_QT - B.ISU_QT <> 0
                        OR ISNULL(D.SO_BAL,0) + ISNULL(D.MTL_BAL,0) <> 0
ORDER BY 판정, 가용재고
;


/*==============================================================================================
  ** 쿼리 C : LOT 별 재고  ★ SITEM.LOT_FG='1' 품목만 의미가 있다
     ─ 집계 뷰에는 LOT 이 없으므로 항상 원장(LINVTORY)을 직접 읽는다.
==============================================================================================*/
SELECT
     N'[C] LOT별 재고'                              AS REPORT_NM
    ,V.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.UNIT_CD                                      AS 단위
    ,V.WH_CD                                        AS 창고코드
    ,W.WH_NM                                        AS 창고명
    ,V.LC_CD                                        AS 장소코드
    ,V.LOT_NB                                       AS LOT번호
    ,기초 = SUM(CAST(ISNULL(V.IOPEN_QT,0) AS DECIMAL(19,6)))
    ,입고 = SUM(CAST(ISNULL(V.IRCV_QT ,0) AS DECIMAL(19,6)))
    ,출고 = SUM(CAST(ISNULL(V.IISU_QT ,0) AS DECIMAL(19,6)))
    ,현재고 = SUM(CAST(ISNULL(V.IOPEN_QT,0) + ISNULL(V.IRCV_QT,0) - ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)))
    ,최초입고일 = MIN(CASE WHEN V.IO_FG IN (N'0', N'1') THEN V.IO_DT END)
    ,최종수불일 = MAX(V.IO_DT)
    ,체류일수 = DATEDIFF(DAY, CONVERT(DATE, MIN(CASE WHEN V.IO_FG IN (N'0',N'1') THEN V.IO_DT END)),
                              CONVERT(DATE, @BASE_DT))
    ,LOT상태 = CASE
         WHEN SUM(ISNULL(V.IOPEN_QT,0)+ISNULL(V.IRCV_QT,0)-ISNULL(V.IISU_QT,0)) <= 0 THEN N'9.소진'
         WHEN DATEDIFF(DAY, CONVERT(DATE, MIN(CASE WHEN V.IO_FG IN (N'0',N'1') THEN V.IO_DT END)),
                            CONVERT(DATE, @BASE_DT)) > 365                           THEN N'1.★1년 초과'
         WHEN DATEDIFF(DAY, CONVERT(DATE, MIN(CASE WHEN V.IO_FG IN (N'0',N'1') THEN V.IO_DT END)),
                            CONVERT(DATE, @BASE_DT)) > 180                           THEN N'2.180일 초과'
         ELSE N'0.정상' END
FROM       LINVTORY V WITH (NOLOCK)
INNER JOIN SITEM    I WITH (NOLOCK) ON I.CO_CD = V.CO_CD AND I.ITEM_CD = V.ITEM_CD
LEFT  JOIN SWH      W WITH (NOLOCK) ON W.CO_CD = V.CO_CD AND W.WH_CD   = V.WH_CD
WHERE  V.CO_CD = @CO_CD AND V.P_YR = @P_YR
  AND  ISNULL(V.USE_YN, N'1') = N'1' AND ISNULL(V.EXPIRE_YN, N'1') = N'1'
  AND  ISNULL(I.LOT_FG, N'0') = N'1'                        -- ★ LOT 관리 품목만
  AND  ISNULL(V.LOT_NB, N'') <> N''
  AND  (@AS_OF_YN = N'0' OR V.IO_DT <= @BASE_DT)
  AND  (@DIV_CD  IS NULL OR V.DIV_CD  = @DIV_CD)
  AND  (@ITEM_CD IS NULL OR V.ITEM_CD = @ITEM_CD)
  AND  (@WH_CD   IS NULL OR V.WH_CD   = @WH_CD)
  AND  (@EXC_Z00 = N'0' OR ISNULL(I.S_CD, N'') <> N'Z00')
GROUP BY V.ITEM_CD, I.ITEM_NM, I.UNIT_CD, V.WH_CD, W.WH_NM, V.LC_CD, V.LOT_NB
HAVING @EXC_ZERO = N'0'
    OR SUM(ISNULL(V.IOPEN_QT,0)+ISNULL(V.IRCV_QT,0)-ISNULL(V.IISU_QT,0)) <> 0
ORDER BY LOT상태, 체류일수 DESC
;


/*==============================================================================================
  ** 쿼리 D : 창고별 요약
==============================================================================================*/
SELECT
     N'[D] 창고별 요약'                             AS REPORT_NM
    ,S.WH_CD                                        AS 창고코드
    ,W.WH_NM                                        AS 창고명
    ,COUNT(DISTINCT S.ITEM_CD)                      AS 품목수
    ,COUNT(DISTINCT S.LC_CD)                        AS 장소수
    ,SUM(S.OPEN_QT)                                 AS 기초계
    ,SUM(S.RCV_QT)                                  AS 입고계
    ,SUM(S.ISU_QT)                                  AS 출고계
    ,SUM(S.OPEN_QT + S.RCV_QT - S.ISU_QT)           AS 현재고계
    ,원재료품목수 = COUNT(DISTINCT CASE WHEN I.ACCT_FG IN (N'0',N'1') THEN S.ITEM_CD END)
    ,제품품목수   = COUNT(DISTINCT CASE WHEN I.ACCT_FG IN (N'2',N'4') THEN S.ITEM_CD END)
    ,상품품목수   = COUNT(DISTINCT CASE WHEN I.ACCT_FG =  N'5'        THEN S.ITEM_CD END)
    ,마이너스품목수 = COUNT(DISTINCT CASE WHEN S.OPEN_QT+S.RCV_QT-S.ISU_QT < 0 THEN S.ITEM_CD END)
FROM       #STK  S
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = S.ITEM_CD
LEFT  JOIN SWH   W WITH (NOLOCK) ON W.CO_CD = @CO_CD AND W.WH_CD   = S.WH_CD
GROUP BY S.WH_CD, W.WH_NM
ORDER BY 현재고계 DESC
;


/*==============================================================================================
  ** 쿼리 E : 마이너스 재고  ★ 데이터 신뢰도 점검
     ─ 나오면 SYSCFG 모듈 'S' / 코드 '13'(마이너스재고통제)을 먼저 확인할 것.
==============================================================================================*/
SELECT
     N'[E] 마이너스 재고'                           AS REPORT_NM
    ,S.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
    ,S.WH_CD                                        AS 창고코드
    ,W.WH_NM                                        AS 창고명
    ,S.LC_CD                                        AS 장소코드
    ,S.OPEN_QT                                      AS 기초
    ,S.RCV_QT                                       AS 입고
    ,S.ISU_QT                                       AS 출고
    ,현재고 = S.OPEN_QT + S.RCV_QT - S.ISU_QT
    ,S.PISU_QT                                      AS 생산출고
    ,S.SISU_QT                                      AS 매출출고
    ,S.EISU_QT                                      AS 기타출고
    ,S.LAST_DT                                      AS 최종수불일
    ,추정원인 = CASE
         WHEN S.OPEN_QT = 0 AND S.RCV_QT = 0 THEN N'1.★입고 없이 출고 (입고 등록 누락)'
         WHEN S.PISU_QT > S.RCV_QT           THEN N'2.생산출고 과다 (자재 선출고)'
         WHEN S.SISU_QT > S.RCV_QT           THEN N'3.매출출고 과다 (미입고 판매)'
         ELSE N'4.수불 순서 역전 (일자 확인)' END
FROM       #STK  S
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = S.ITEM_CD
LEFT  JOIN SWH   W WITH (NOLOCK) ON W.CO_CD = @CO_CD AND W.WH_CD   = S.WH_CD
WHERE  S.OPEN_QT + S.RCV_QT - S.ISU_QT < 0
ORDER BY 현재고
;


/*==============================================================================================
  ** 쿼리 F : 창고재고 + 재공 통합  ★ 재공은 LINV_WIP (별도 테이블)
     ─ BASELOC_FG 로 창고/공정을 구분하므로 UNION 해도 중복되지 않는다.
==============================================================================================*/
;WITH U AS (
    SELECT 구분 = N'1.창고', S.ITEM_CD
          ,QT = SUM(S.OPEN_QT + S.RCV_QT - S.ISU_QT)
    FROM   #STK S GROUP BY S.ITEM_CD
    UNION ALL
    SELECT 구분 = N'2.재공', V.ITEM_CD
          ,QT = SUM(CAST(ISNULL(V.IOPEN_QT,0)+ISNULL(V.IRCV_QT,0)-ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)))
    FROM   LINV_WIP V WITH (NOLOCK)
    WHERE  V.CO_CD = @CO_CD AND V.P_YR = @P_YR
      AND  ISNULL(V.USE_YN, N'1') = N'1' AND ISNULL(V.EXPIRE_YN, N'1') = N'1'
      AND  (@AS_OF_YN = N'0' OR V.IO_DT <= @BASE_DT)
      AND  (@DIV_CD  IS NULL OR V.DIV_CD  = @DIV_CD)
      AND  (@ITEM_CD IS NULL OR V.ITEM_CD = @ITEM_CD)
    GROUP BY V.ITEM_CD
)
SELECT
     N'[F] 창고 + 재공 통합재고'                    AS REPORT_NM
    ,U.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
    ,창고재고 = SUM(CASE WHEN U.구분 = N'1.창고' THEN U.QT ELSE 0 END)
    ,재공재고 = SUM(CASE WHEN U.구분 = N'2.재공' THEN U.QT ELSE 0 END)
    ,통합재고 = SUM(U.QT)
    ,재공비율_PCT = CAST(CASE WHEN SUM(U.QT) <> 0
                              THEN SUM(CASE WHEN U.구분=N'2.재공' THEN U.QT ELSE 0 END)/SUM(U.QT)*100
                              END AS DECIMAL(19,2))
FROM       U
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = U.ITEM_CD
WHERE  @EXC_Z00 = N'0' OR ISNULL(I.S_CD, N'') <> N'Z00'
GROUP BY U.ITEM_CD, I.ITEM_NM, I.UNIT_CD, I.ACCT_FG
HAVING @EXC_ZERO = N'0' OR SUM(U.QT) <> 0
ORDER BY 통합재고 DESC
;


/*==============================================================================================
  ** 쿼리 G : 연도 경계 점검  ★ 연초 조회 시 필수
     ─ P_YR 파티션이므로 전년 이월(GRP_FG='6')이 당해 기초로 넘어왔는지 확인한다.
       안 넘어왔으면 당해 재고가 과소 계상된다.
==============================================================================================*/
SELECT
     N'[G] 연도 경계 점검'                          AS REPORT_NM
    ,@P_YR                                          AS 조회연도
    ,당해_기초보유품목수 = (SELECT COUNT(DISTINCT ITEM_CD) FROM LINVTORY WITH (NOLOCK)
                            WHERE CO_CD=@CO_CD AND P_YR=@P_YR AND ISNULL(IOPEN_QT,0) <> 0
                              AND (@DIV_CD IS NULL OR DIV_CD=@DIV_CD))
    ,당해_기초수량계     = (SELECT SUM(CAST(ISNULL(IOPEN_QT,0) AS DECIMAL(19,6))) FROM LINVTORY WITH (NOLOCK)
                            WHERE CO_CD=@CO_CD AND P_YR=@P_YR
                              AND (@DIV_CD IS NULL OR DIV_CD=@DIV_CD))
    ,전년_기말수량계     = (SELECT SUM(CAST(ISNULL(IOPEN_QT,0)+ISNULL(IRCV_QT,0)-ISNULL(IISU_QT,0) AS DECIMAL(19,6)))
                            FROM LINVTORY WITH (NOLOCK)
                            WHERE CO_CD=@CO_CD AND P_YR=CAST(CAST(@P_YR AS INT)-1 AS NVARCHAR(4))
                              AND (@DIV_CD IS NULL OR DIV_CD=@DIV_CD))
    ,이월수불건수        = (SELECT COUNT(*) FROM LINVTORY WITH (NOLOCK)
                            WHERE CO_CD=@CO_CD AND P_YR=@P_YR AND GRP_FG=N'6'
                              AND (@DIV_CD IS NULL OR DIV_CD=@DIV_CD))
    ,판정 = CASE
         WHEN (SELECT SUM(CAST(ISNULL(IOPEN_QT,0)+ISNULL(IRCV_QT,0)-ISNULL(IISU_QT,0) AS DECIMAL(19,6)))
               FROM LINVTORY WITH (NOLOCK)
               WHERE CO_CD=@CO_CD AND P_YR=CAST(CAST(@P_YR AS INT)-1 AS NVARCHAR(4))) IS NULL
              THEN N'0.전년 데이터 없음 (첫 해)'
         WHEN ABS(ISNULL((SELECT SUM(CAST(ISNULL(IOPEN_QT,0) AS DECIMAL(19,6))) FROM LINVTORY WITH (NOLOCK)
                          WHERE CO_CD=@CO_CD AND P_YR=@P_YR),0)
                - ISNULL((SELECT SUM(CAST(ISNULL(IOPEN_QT,0)+ISNULL(IRCV_QT,0)-ISNULL(IISU_QT,0) AS DECIMAL(19,6)))
                          FROM LINVTORY WITH (NOLOCK)
                          WHERE CO_CD=@CO_CD AND P_YR=CAST(CAST(@P_YR AS INT)-1 AS NVARCHAR(4))),0)) < 0.001
              THEN N'1.정상 (전년 기말 = 당해 기초)'
         ELSE N'2.★불일치 - 이월 처리 확인 필요' END
;


/*==============================================================================================
  ** 쿼리 H : 전체 요약 (경영 보고 1행)
==============================================================================================*/
SELECT
     N'[H] 재고 요약'                               AS REPORT_NM
    ,@USED                                          AS 소스계층
    ,CASE @AS_OF_YN WHEN N'1' THEN @BASE_DT ELSE N'현재' END AS 기준
    ,COUNT(DISTINCT S.ITEM_CD)                      AS 재고보유품목수
    ,COUNT(DISTINCT S.WH_CD)                        AS 창고수
    ,COUNT(*)                                       AS 재고행수
    ,SUM(S.OPEN_QT + S.RCV_QT - S.ISU_QT)           AS 현재고계
    ,원재료수량 = SUM(CASE WHEN I.ACCT_FG IN (N'0',N'1') THEN S.OPEN_QT+S.RCV_QT-S.ISU_QT ELSE 0 END)
    ,제품수량   = SUM(CASE WHEN I.ACCT_FG IN (N'2',N'4') THEN S.OPEN_QT+S.RCV_QT-S.ISU_QT ELSE 0 END)
    ,상품수량   = SUM(CASE WHEN I.ACCT_FG =  N'5'        THEN S.OPEN_QT+S.RCV_QT-S.ISU_QT ELSE 0 END)
    ,마이너스행수 = SUM(CASE WHEN S.OPEN_QT+S.RCV_QT-S.ISU_QT < 0 THEN 1 ELSE 0 END)
    ,마이너스품목수 = COUNT(DISTINCT CASE WHEN S.OPEN_QT+S.RCV_QT-S.ISU_QT < 0 THEN S.ITEM_CD END)
    ,장기정체행수 = SUM(CASE WHEN S.LAST_DT IS NOT NULL
                              AND DATEDIFF(DAY,CONVERT(DATE,S.LAST_DT),CONVERT(DATE,@BASE_DT)) > 180
                              AND S.OPEN_QT+S.RCV_QT-S.ISU_QT > 0
                             THEN 1 ELSE 0 END)
    ,판정 = CASE
         WHEN SUM(CASE WHEN S.OPEN_QT+S.RCV_QT-S.ISU_QT < 0 THEN 1 ELSE 0 END) > 0
              THEN N'1.★마이너스 재고 존재 - 가용재고 신뢰도 저하'
         ELSE N'0.정상' END
FROM       #STK  S
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = S.ITEM_CD
;


DROP TABLE #STK, #DMD, #SUP;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 어느 계층이 있는가  ★ @SRC 선택의 근거
     SELECT name, type_desc FROM sys.objects
     WHERE name IN ('VL_INVLC','VL_INVDIV','L_INVSUM_LC','LINVTORY','LINVTORY_D','LINV_WIP',
                    'VL_LINVTORY_ALL','VL_LINV_WIP_ALL');

  -- (2) 집계뷰 vs 원장 정합성  ★ 뷰를 믿어도 되는지 판단
     SELECT '뷰' 구분, SUM(ISNULL(IOPEN,0)+ISNULL(IRCV,0)-ISNULL(IISU,0)) 재고
     FROM   VL_INVLC WHERE CO_CD='1000' AND P_YR='2026'
     UNION ALL
     SELECT '원장', SUM(ISNULL(IOPEN_QT,0)+ISNULL(IRCV_QT,0)-ISNULL(IISU_QT,0))
     FROM   LINVTORY WHERE CO_CD='1000' AND P_YR='2026' AND ISNULL(EXPIRE_YN,'1')='1';
     --> 차이가 나면 뷰의 갱신 주기(야간 배치 여부)를 확인할 것.

  -- (3) 마이너스재고 통제 설정  ★ 마이너스가 나올 때 먼저 볼 것
     SELECT * FROM SYSCFG WHERE CO_CD='1000' AND MODULE_FG='S' AND CFG_CD='13';
     --> 0(허용)이면 데이터 자체가 음수일 수 있다. 1(통제)인데 음수면 데이터 오류다.

  -- (4) LOT 관리 품목 비중  ★ 쿼리 C 의 대상 규모
     SELECT LOT_FG, COUNT(*) FROM SITEM WHERE CO_CD='1000' GROUP BY LOT_FG;

  -- (5) 안전재고 등록률  ★ 쿼리 B 의 '안전재고 미달' 판정이 의미 있으려면
     SELECT COUNT(*) 전체, SUM(CASE WHEN ISNULL(SAFESTOCK_QT,0)=0 THEN 1 ELSE 0 END) 미등록
     FROM   SITEM WHERE CO_CD='1000' AND ISNULL(USE_YN,'1')='1';

  -- (6) 창고/장소 마스터 테이블명 확인
     SELECT name FROM sys.tables WHERE name IN ('SWH','SLC');

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **@AS_OF_YN='0'(현재고) 은 집계 뷰를 쓰므로 뷰의 갱신 시점까지만 반영된다.** 야간 배치로
     갱신되는 사이트면 "실시간"이 아니라 "전일 마감 기준"이다. 진짜 실시간이 필요하면
     @SRC='LINVTORY' 로 원장을 직접 읽되 응답속도를 감수할 것. 확인 (2)번으로 차이를 먼저 볼 것.

  2) **가용재고(쿼리 B)는 근사치다.** 가출고, 검사중 재고, 이동중 재고는 반영하지 않았다.
     정밀한 MRP 가용재고는 `원자재수급총괄현황_MRP.sql` 의 LDEMAND_STORY 산식을 쓸 것.

  3) 금액은 내지 않았다. 재고 금액은 평가 방법(이동평균/총평균/FIFO)에 따라 달라지므로
     `LINV_MVFIFO`(평가 후) 또는 `LINV_TAV`(기간 평가단가)를 조인해야 한다.
     수량 기준 조회와 금액 기준 조회는 성격이 다르므로 분리하는 편이 낫다.

  4) 쿼리 C(LOT)는 집계 뷰에 LOT 이 없어 항상 원장을 읽는다. 품목 범위를 좁히지 않으면 느리다.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   재고수불_뷰테이블_레퍼런스.md   : 3계층 구조 상세 + 컬럼 명세
   원자재수급총괄현황_MRP.sql      : 정밀 가용재고 + 소요량 전개
   M04_공정별재공_현황.sql         : 재공(LINV_WIP) 전용 분석
==============================================================================================*/
