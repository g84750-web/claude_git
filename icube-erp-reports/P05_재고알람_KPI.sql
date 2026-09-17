/*==============================================================================================
  [ iCUBE ] P-05  안전재고 미달 / 과잉재고 알람 KPI                                  (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 결품 위험과 과잉 재고를 **동시에** 잡는 양방향 알람.
         핵심 지표는 `소진예상일수 < 리드타임` — "지금 발주해도 늦는" 품목을 미리 찾아낸다.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 산식 ]
  ----------------------------------------------------------------------------------------------
     현재고       = SUM(IOPEN_QT) + SUM(IRCV_QT) - SUM(IISU_QT)
     가용재고     = 현재고 - 수주잔량 - 자재할당잔량 + 발주입고예정
     안전재고     = SITEM.SAFESTOCK_QT
     일평균사용량 = 최근 @AVG_MM 개월 출고합계 / 일수
     소진예상일수 = 가용재고 / 일평균사용량
     부족율       = (안전재고 - 가용재고) / 안전재고 * 100
     과잉배수     = 현재고 / 안전재고

     알람등급 = CASE WHEN 가용재고 < 0                        THEN '1.결품'
                     WHEN 소진예상일수 < LEAD_DT              THEN '2.조달불가(긴급)'   ★ 핵심
                     WHEN 가용재고 < 안전재고                 THEN '3.안전재고 미달'
                     WHEN 과잉배수 > 5 AND 최근6개월출고 = 0  THEN '8.체화'
                     WHEN 과잉배수 > 3                        THEN '9.과잉'
                     ELSE '0.정상' END

  ----------------------------------------------------------------------------------------------
  [ ★ 이 리포트의 성패는 안전재고 등록률에 달려 있다 ]
  ----------------------------------------------------------------------------------------------
     `SAFESTOCK_QT` 미등록 품목이 많으면 알람 자체가 무의미하다. 그래서 두 가지를 넣었다.
       · 쿼리 F 가 **등록률을 먼저 측정**한다. 도입 전 반드시 확인할 것.
       · 미등록 품목에는 **자동 제안값**을 함께 낸다 (쿼리 E).
             제안 안전재고 = 일평균사용량 × 리드타임 × @SAFE_K
         실무에서는 제안값을 주는 편이 채택률이 훨씬 높다.

     `소진예상일수 < LEAD_DT` 판정은 안전재고가 없어도 동작한다. 따라서 안전재고 미등록
     사이트라도 **알람등급 1·2 는 그대로 쓸 수 있다.**
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터   ─ 목표선/계수는 EIS 기본값을 채웠다.
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@BASE_DT  NVARCHAR(8)  = N'20260915'     -- 기준일
    ,@ITEM_CD  NVARCHAR(25) = NULL
    ,@ACCT_FG  NVARCHAR(1)  = NULL            -- 0원재료 1부재료 2제품 4반제품 5상품
    ,@EXC_Z00  NCHAR(1)     = N'1'            -- 단종품 제외

    ,@AVG_MM   INT          = 3               -- 일평균사용량 산정 개월수  [기본 3개월]
    ,@DEAD_MM  INT          = 6               -- 체화 판정 무출고 개월수   [기본 6개월]
    ,@SAFE_K   DECIMAL(5,2) = 1.50            -- 안전계수 (제안값 산정)    [기본 1.5]
    ,@OVER_K1  DECIMAL(5,2) = 3.00            -- 과잉 판정 배수            [기본 3배]
    ,@OVER_K2  DECIMAL(5,2) = 5.00            -- 체화 판정 배수            [기본 5배]
    ,@TGT_SHORT INT         = 0               -- ★ 목표 결품 품목수        [EIS 기본값 0]
    ,@LEAD_DFT INT          = 7               -- 리드타임 미등록 시 대체값  [기본 7일]
;

DECLARE @P_YR NVARCHAR(4) = LEFT(@BASE_DT, 4);
DECLARE @AVG_FR  NVARCHAR(8) = CONVERT(NVARCHAR(8), DATEADD(MONTH, -@AVG_MM , CONVERT(DATE,@BASE_DT)), 112);
DECLARE @DEAD_FR NVARCHAR(8) = CONVERT(NVARCHAR(8), DATEADD(MONTH, -@DEAD_MM, CONVERT(DATE,@BASE_DT)), 112);
DECLARE @AVG_DAYS INT = DATEDIFF(DAY, CONVERT(DATE,@AVG_FR), CONVERT(DATE,@BASE_DT));
-- 전년 동기 (계절성 비교용)
DECLARE @LY_FR NVARCHAR(8) = CONVERT(NVARCHAR(8), DATEADD(YEAR,-1,CONVERT(DATE,@AVG_FR )), 112);
DECLARE @LY_TO NVARCHAR(8) = CONVERT(NVARCHAR(8), DATEADD(YEAR,-1,CONVERT(DATE,@BASE_DT)), 112);

IF OBJECT_ID('tempdb..#STK') IS NOT NULL DROP TABLE #STK;
IF OBJECT_ID('tempdb..#USE') IS NOT NULL DROP TABLE #USE;
IF OBJECT_ID('tempdb..#DMD') IS NOT NULL DROP TABLE #DMD;
IF OBJECT_ID('tempdb..#SUP') IS NOT NULL DROP TABLE #SUP;
IF OBJECT_ID('tempdb..#ALM') IS NOT NULL DROP TABLE #ALM;


/*==============================================================================================
  1. #STK : 품목별 현재고 (창고 합산)
==============================================================================================*/
SELECT
     V.ITEM_CD
    ,STK_QT  = SUM(CAST(ISNULL(V.IOPEN_QT,0)+ISNULL(V.IRCV_QT,0)-ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)))
    ,WH_CNT  = COUNT(DISTINCT V.WH_CD)
    ,LAST_DT = MAX(V.IO_DT)
INTO #STK
FROM   LINVTORY V WITH (NOLOCK)
WHERE  V.CO_CD = @CO_CD AND V.P_YR = @P_YR
  AND  V.IO_DT <= @BASE_DT
  AND  ISNULL(V.USE_YN, N'1') = N'1' AND ISNULL(V.EXPIRE_YN, N'1') = N'1'
  AND  (@DIV_CD  IS NULL OR V.DIV_CD  = @DIV_CD)
  AND  (@ITEM_CD IS NULL OR V.ITEM_CD = @ITEM_CD)
GROUP BY V.ITEM_CD;
CREATE CLUSTERED INDEX IX_STK ON #STK (ITEM_CD);


/*==============================================================================================
  2. #USE : 사용량 (최근 @AVG_MM 개월 / 체화판정 기간 / 전년 동기)
     ─ 출고(IO_FG='2') 중 생산출고·매출출고만 사용량으로 본다.
       재고이동(GRP_FG='5')은 실제 소비가 아니므로 제외한다.
==============================================================================================*/
SELECT
     V.ITEM_CD
    ,USE_QT  = SUM(CASE WHEN V.IO_DT >= @AVG_FR
                        THEN CAST(ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
    ,DEAD_QT = SUM(CASE WHEN V.IO_DT >= @DEAD_FR
                        THEN CAST(ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
    ,LY_QT   = SUM(CASE WHEN V.IO_DT BETWEEN @LY_FR AND @LY_TO
                        THEN CAST(ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
    ,LAST_USE = MAX(CASE WHEN ISNULL(V.IISU_QT,0) > 0 THEN V.IO_DT END)
INTO #USE
FROM   LINVTORY V WITH (NOLOCK)
WHERE  V.CO_CD = @CO_CD
  AND  V.IO_DT BETWEEN @LY_FR AND @BASE_DT
  AND  V.IO_FG = N'2'
  AND  ISNULL(V.GRP_FG, N'') <> N'5'                        -- 재고이동 제외
  AND  ISNULL(V.USE_YN, N'1') = N'1' AND ISNULL(V.EXPIRE_YN, N'1') = N'1'
  AND  (@DIV_CD  IS NULL OR V.DIV_CD  = @DIV_CD)
  AND  (@ITEM_CD IS NULL OR V.ITEM_CD = @ITEM_CD)
GROUP BY V.ITEM_CD;
CREATE CLUSTERED INDEX IX_USE ON #USE (ITEM_CD);


/*==============================================================================================
  3. #DMD / #SUP : 수요(수주잔량 + 자재할당) / 공급(발주 입고예정)
==============================================================================================*/
SELECT
     D.ITEM_CD
    ,SO_BAL  = SUM(CASE WHEN D.SRC = N'SO'  THEN D.QT ELSE 0 END)
    ,MTL_BAL = SUM(CASE WHEN D.SRC = N'MTL' THEN D.QT ELSE 0 END)
INTO #DMD
FROM (
    SELECT SRC = N'SO', X.ITEM_CD
          ,QT = CAST(ISNULL(X.SO_QT,0) - ISNULL(X.ISU_QT,0) AS DECIMAL(19,6))
    FROM       LSO   H WITH (NOLOCK)
    INNER JOIN LSO_D X WITH (NOLOCK) ON X.CO_CD = H.CO_CD AND X.SO_NB = H.SO_NB
    WHERE  H.CO_CD = @CO_CD
      AND  ISNULL(X.USE_YN, N'1') = N'1' AND ISNULL(X.EXPIRE_YN, N'1') = N'1'
      AND  ISNULL(X.SO_QT,0) - ISNULL(X.ISU_QT,0) > 0
      AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
    UNION ALL
    SELECT SRC = N'MTL', Q.ITEM_CD
          ,QT = CAST(ISNULL(Q.REQ_QT,0) - ISNULL(Q.ISU_QT,0) AS DECIMAL(19,6))
    FROM       LWO_REQ_WF Q WITH (NOLOCK)
    INNER JOIN LWO_WF     W WITH (NOLOCK) ON W.CO_CD = Q.CO_CD AND W.WO_CD = Q.WO_CD
    WHERE  Q.CO_CD = @CO_CD
      AND  ISNULL(Q.USE_YN, N'1') = N'1'
      AND  ISNULL(W.EXPIRE_YN, N'1') = N'1'
      AND  ISNULL(Q.REQ_QT,0) - ISNULL(Q.ISU_QT,0) > 0
      AND  (@DIV_CD IS NULL OR W.DIV_CD = @DIV_CD)
) D
GROUP BY D.ITEM_CD;
CREATE CLUSTERED INDEX IX_DMD ON #DMD (ITEM_CD);

SELECT
     D.ITEM_CD
    ,PO_BAL  = SUM(CAST(ISNULL(D.PO_QT,0) - ISNULL(R.RCV_QT,0) AS DECIMAL(19,6)))
    ,NEAR_DT = MIN(D.DUE_DT)
    ,PO_CNT  = COUNT(*)
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
  4. #ALM : 품목별 알람 판정
==============================================================================================*/
SELECT
     I.ITEM_CD
    ,I.ITEM_NM
    ,I.SPEC
    ,I.UNIT_CD
    ,I.ACCT_FG
    ,LEAD_DT   = ISNULL(NULLIF(CAST(ISNULL(I.LEAD_DT,0) AS INT), 0), @LEAD_DFT)
    ,LEAD_REG  = CASE WHEN ISNULL(CAST(ISNULL(I.LEAD_DT,0) AS INT),0) = 0 THEN N'0' ELSE N'1' END
    ,SAFE_QT   = CAST(ISNULL(I.SAFESTOCK_QT, 0) AS DECIMAL(19,6))
    ,SAFE_REG  = CASE WHEN ISNULL(I.SAFESTOCK_QT, 0) = 0 THEN N'0' ELSE N'1' END
    ,STK_QT    = ISNULL(S.STK_QT , 0)
    ,SO_BAL    = ISNULL(D.SO_BAL , 0)
    ,MTL_BAL   = ISNULL(D.MTL_BAL, 0)
    ,PO_BAL    = ISNULL(P.PO_BAL , 0)
    ,NEAR_DT   = P.NEAR_DT
    ,AVL_QT    = ISNULL(S.STK_QT,0) - ISNULL(D.SO_BAL,0) - ISNULL(D.MTL_BAL,0) + ISNULL(P.PO_BAL,0)
    ,USE_QT    = ISNULL(U.USE_QT , 0)
    ,DEAD_QT   = ISNULL(U.DEAD_QT, 0)
    ,LY_QT     = ISNULL(U.LY_QT  , 0)
    ,LAST_USE  = U.LAST_USE
    ,DAY_USE   = CAST(ISNULL(U.USE_QT,0) / NULLIF(@AVG_DAYS,0) AS DECIMAL(19,6))
    ,S.LAST_DT
INTO #ALM
FROM       SITEM I WITH (NOLOCK)
LEFT  JOIN #STK  S ON S.ITEM_CD = I.ITEM_CD
LEFT  JOIN #USE  U ON U.ITEM_CD = I.ITEM_CD
LEFT  JOIN #DMD  D ON D.ITEM_CD = I.ITEM_CD
LEFT  JOIN #SUP  P ON P.ITEM_CD = I.ITEM_CD
WHERE  I.CO_CD = @CO_CD
  AND  ISNULL(I.USE_YN, N'1') = N'1'
  AND  (@EXC_Z00 = N'0' OR ISNULL(I.S_CD, N'') <> N'Z00')
  AND  (@ACCT_FG IS NULL OR I.ACCT_FG = @ACCT_FG)
  AND  (@ITEM_CD IS NULL OR I.ITEM_CD = @ITEM_CD)
  -- 재고도 없고 수요도 없고 사용 이력도 없는 품목은 알람 대상이 아니다
  AND  (ISNULL(S.STK_QT,0) <> 0 OR ISNULL(D.SO_BAL,0) <> 0 OR ISNULL(D.MTL_BAL,0) <> 0
        OR ISNULL(U.USE_QT,0) <> 0 OR ISNULL(P.PO_BAL,0) <> 0)
;
CREATE CLUSTERED INDEX IX_ALM ON #ALM (ITEM_CD);

PRINT N'[1] 알람 대상 품목 : ' + CAST((SELECT COUNT(*) FROM #ALM) AS NVARCHAR(20));


/*==============================================================================================
  ** 쿼리 A : 품목별 재고 알람  (메인)
==============================================================================================*/
SELECT
     N'[A] 재고 알람'                               AS REPORT_NM
    ,알람등급 = CASE
         WHEN A.AVL_QT < 0                                                    THEN N'1.★결품'
         WHEN A.DAY_USE > 0
          AND A.AVL_QT / A.DAY_USE < A.LEAD_DT                                THEN N'2.★조달불가(긴급)'
         WHEN A.SAFE_REG = N'1' AND A.AVL_QT < A.SAFE_QT                      THEN N'3.안전재고 미달'
         WHEN A.SAFE_REG = N'1' AND A.STK_QT > A.SAFE_QT * @OVER_K2
          AND A.DEAD_QT = 0                                                   THEN N'8.체화'
         WHEN A.SAFE_REG = N'1' AND A.STK_QT > A.SAFE_QT * @OVER_K1           THEN N'9.과잉'
         WHEN A.SAFE_REG = N'0' AND A.DEAD_QT = 0 AND A.STK_QT > 0            THEN N'8.체화(안전재고 미등록)'
         ELSE N'0.정상' END
    ,A.ITEM_CD                                      AS 품번
    ,A.ITEM_NM                                      AS 품명
    ,A.SPEC                                         AS 규격
    ,A.UNIT_CD                                      AS 단위
    ,계정구분 = CASE A.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE A.ACCT_FG END

    ,A.STK_QT                                       AS 현재고
    ,A.SO_BAL                                       AS 수주잔량
    ,A.MTL_BAL                                      AS 자재할당잔량
    ,A.PO_BAL                                       AS 발주입고예정
    ,A.NEAR_DT                                      AS 최단입고예정일
    ,A.AVL_QT                                       AS 가용재고
    ,A.SAFE_QT                                      AS 안전재고
    ,안전재고등록 = CASE A.SAFE_REG WHEN N'1' THEN N'등록' ELSE N'★미등록' END

    ,A.USE_QT                                       AS 최근사용량
    ,A.DAY_USE                                      AS 일평균사용량
    ,소진예상일수 = CAST(CASE WHEN A.DAY_USE > 0 THEN A.AVL_QT / A.DAY_USE END AS DECIMAL(9,1))
    ,A.LEAD_DT                                      AS 리드타임일
    ,리드타임등록 = CASE A.LEAD_REG WHEN N'1' THEN N'등록' ELSE N'★미등록(기본값 적용)' END
    ,부족율_PCT = CAST(CASE WHEN A.SAFE_QT > 0 AND A.AVL_QT < A.SAFE_QT
                            THEN (A.SAFE_QT - A.AVL_QT) / A.SAFE_QT * 100 END AS DECIMAL(9,1))
    ,과잉배수   = CAST(CASE WHEN A.SAFE_QT > 0 THEN A.STK_QT / A.SAFE_QT END AS DECIMAL(9,2))
    ,부족수량   = CASE WHEN A.SAFE_QT > A.AVL_QT THEN A.SAFE_QT - A.AVL_QT END
    ,A.LAST_USE                                     AS 최종사용일
    ,무사용일수 = CASE WHEN A.LAST_USE IS NOT NULL
                       THEN DATEDIFF(DAY, CONVERT(DATE,A.LAST_USE), CONVERT(DATE,@BASE_DT)) END
    ,권장조치 = CASE
         WHEN A.AVL_QT < 0
              THEN N'즉시 발주 + 기존 주문 납기 재조정'
         WHEN A.DAY_USE > 0 AND A.AVL_QT / A.DAY_USE < A.LEAD_DT
              THEN N'긴급 발주 (지금 발주해도 ' + CAST(A.LEAD_DT AS NVARCHAR(10)) + N'일 소요)'
         WHEN A.SAFE_REG = N'1' AND A.AVL_QT < A.SAFE_QT
              THEN N'정상 발주 (부족 ' + CAST(CAST(A.SAFE_QT - A.AVL_QT AS DECIMAL(19,2)) AS NVARCHAR(30)) + N')'
         WHEN A.DEAD_QT = 0 AND A.STK_QT > 0
              THEN CAST(@DEAD_MM AS NVARCHAR(5)) + N'개월 무출고 - 실사/처분 검토'
         WHEN A.SAFE_REG = N'1' AND A.STK_QT > A.SAFE_QT * @OVER_K1
              THEN N'발주 중단 + 소진 계획 수립'
         ELSE N'-' END
FROM   #ALM A
ORDER BY 알람등급, 소진예상일수, A.ITEM_CD
;


/*==============================================================================================
  ** 쿼리 B : 알람등급별 집계 (대시보드 상단 카드)
==============================================================================================*/
;WITH X AS (
    SELECT
         A.*
        ,GRD = CASE
             WHEN A.AVL_QT < 0                                                 THEN N'1.결품'
             WHEN A.DAY_USE > 0 AND A.AVL_QT / A.DAY_USE < A.LEAD_DT           THEN N'2.조달불가(긴급)'
             WHEN A.SAFE_REG = N'1' AND A.AVL_QT < A.SAFE_QT                   THEN N'3.안전재고 미달'
             WHEN A.SAFE_REG = N'1' AND A.STK_QT > A.SAFE_QT*@OVER_K2
              AND A.DEAD_QT = 0                                                THEN N'8.체화'
             WHEN A.SAFE_REG = N'1' AND A.STK_QT > A.SAFE_QT*@OVER_K1          THEN N'9.과잉'
             WHEN A.SAFE_REG = N'0' AND A.DEAD_QT = 0 AND A.STK_QT > 0         THEN N'8.체화(안전재고 미등록)'
             ELSE N'0.정상' END
    FROM #ALM A
)
SELECT
     N'[B] 알람등급별 집계'                         AS REPORT_NM
    ,X.GRD                                          AS 알람등급
    ,COUNT(*)                                       AS 품목수
    ,SUM(X.STK_QT)                                  AS 현재고계
    ,SUM(X.AVL_QT)                                  AS 가용재고계
    ,SUM(X.SO_BAL)                                  AS 수주잔량계
    ,SUM(X.MTL_BAL)                                 AS 자재할당계
    ,SUM(X.PO_BAL)                                  AS 입고예정계
    ,SUM(CASE WHEN X.SAFE_QT > X.AVL_QT THEN X.SAFE_QT - X.AVL_QT ELSE 0 END) AS 부족수량계
    ,구성비_PCT = CAST(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0) AS DECIMAL(5,1))
    ,안전재고미등록 = SUM(CASE WHEN X.SAFE_REG = N'0' THEN 1 ELSE 0 END)
FROM   X
GROUP BY X.GRD
ORDER BY X.GRD
;


/*==============================================================================================
  ** 쿼리 C : 결품 · 조달불가 긴급 목록  ★ 구매팀 즉시 조치 대상
==============================================================================================*/
SELECT
     N'[C] 긴급 조달 대상'                          AS REPORT_NM
    ,긴급도 = CASE WHEN A.AVL_QT < 0 THEN N'1.★결품 (이미 부족)'
                   ELSE N'2.★조달불가 (리드타임 내 소진)' END
    ,A.ITEM_CD                                      AS 품번
    ,A.ITEM_NM                                      AS 품명
    ,A.SPEC                                         AS 규격
    ,A.UNIT_CD                                      AS 단위
    ,계정구분 = CASE A.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE A.ACCT_FG END
    ,A.STK_QT                                       AS 현재고
    ,A.SO_BAL                                       AS 수주잔량
    ,A.MTL_BAL                                      AS 자재할당잔량
    ,A.PO_BAL                                       AS 발주입고예정
    ,A.NEAR_DT                                      AS 최단입고예정일
    ,A.AVL_QT                                       AS 가용재고
    ,A.SAFE_QT                                      AS 안전재고
    ,A.DAY_USE                                      AS 일평균사용량
    ,소진예상일수 = CAST(CASE WHEN A.DAY_USE > 0 THEN A.AVL_QT / A.DAY_USE END AS DECIMAL(9,1))
    ,A.LEAD_DT                                      AS 리드타임일
    ,여유일수 = CAST(CASE WHEN A.DAY_USE > 0
                          THEN A.AVL_QT / A.DAY_USE - A.LEAD_DT END AS DECIMAL(9,1))
    ,권장발주수량 = CAST(CASE
         WHEN A.SAFE_REG = N'1' THEN A.SAFE_QT - A.AVL_QT
         ELSE A.DAY_USE * A.LEAD_DT * @SAFE_K - A.AVL_QT      -- 안전재고 미등록 시 제안 기준
         END AS DECIMAL(19,2))
    ,발주기한 = CASE WHEN A.DAY_USE > 0
                     THEN CONVERT(NVARCHAR(8),
                          DATEADD(DAY, CAST(A.AVL_QT/A.DAY_USE - A.LEAD_DT AS INT),
                                  CONVERT(DATE,@BASE_DT)), 112) END
    ,기발주여부 = CASE WHEN A.PO_BAL > 0
                       THEN N'발주 있음 (' + ISNULL(A.NEAR_DT, N'납기 미정') + N' 입고예정)'
                       ELSE N'★ 발주 없음' END
FROM   #ALM A
WHERE  A.AVL_QT < 0
   OR  (A.DAY_USE > 0 AND A.AVL_QT / A.DAY_USE < A.LEAD_DT)
ORDER BY 긴급도, 여유일수, A.ITEM_CD
;


/*==============================================================================================
  ** 쿼리 D : 과잉 · 체화 재고  ★ 자금이 잠겨 있는 곳
==============================================================================================*/
SELECT
     N'[D] 과잉 · 체화 재고'                        AS REPORT_NM
    ,구분 = CASE
         WHEN A.DEAD_QT = 0 AND A.STK_QT > 0                              THEN N'1.★체화 (' + CAST(@DEAD_MM AS NVARCHAR(5)) + N'개월 무출고)'
         WHEN A.SAFE_REG = N'1' AND A.STK_QT > A.SAFE_QT * @OVER_K2       THEN N'2.★과잉 (' + CAST(@OVER_K2 AS NVARCHAR(10)) + N'배 초과)'
         ELSE N'3.과잉 (' + CAST(@OVER_K1 AS NVARCHAR(10)) + N'배 초과)' END
    ,A.ITEM_CD                                      AS 품번
    ,A.ITEM_NM                                      AS 품명
    ,A.SPEC                                         AS 규격
    ,A.UNIT_CD                                      AS 단위
    ,계정구분 = CASE A.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE A.ACCT_FG END
    ,A.STK_QT                                       AS 현재고
    ,A.SAFE_QT                                      AS 안전재고
    ,과잉배수 = CAST(CASE WHEN A.SAFE_QT > 0 THEN A.STK_QT / A.SAFE_QT END AS DECIMAL(9,2))
    ,과잉수량 = CASE WHEN A.SAFE_QT > 0 THEN A.STK_QT - A.SAFE_QT ELSE A.STK_QT END
    ,A.USE_QT                                       AS 최근사용량
    ,A.DEAD_QT                                      AS 체화판정기간_사용량
    ,A.DAY_USE                                      AS 일평균사용량
    ,소진예상일수 = CAST(CASE WHEN A.DAY_USE > 0 THEN A.STK_QT / A.DAY_USE END AS DECIMAL(9,1))
    ,A.LAST_USE                                     AS 최종사용일
    ,무사용일수 = CASE WHEN A.LAST_USE IS NOT NULL
                       THEN DATEDIFF(DAY, CONVERT(DATE,A.LAST_USE), CONVERT(DATE,@BASE_DT))
                       ELSE 9999 END
    ,A.PO_BAL                                       AS 발주입고예정
    ,경고 = CASE WHEN A.PO_BAL > 0 AND A.DEAD_QT = 0
                 THEN N'★ 무출고인데 추가 발주가 진행 중 - 발주 취소 검토'
                 WHEN A.DAY_USE > 0 AND A.STK_QT / A.DAY_USE > 365
                 THEN N'1년치 초과 보유'
                 ELSE N'-' END
FROM   #ALM A
WHERE  A.STK_QT > 0
  AND  ( (A.DEAD_QT = 0)
      OR (A.SAFE_REG = N'1' AND A.STK_QT > A.SAFE_QT * @OVER_K1) )
ORDER BY 구분, 무사용일수 DESC, A.STK_QT DESC
;


/*==============================================================================================
  ** 쿼리 E : 안전재고 자동 제안값  ★ 미등록 품목의 등록을 유도하는 목록
     ─ 제안 안전재고 = 일평균사용량 × 리드타임 × @SAFE_K
       실무 채택률을 높이려면 "등록하세요"보다 "이 값을 등록하세요"가 훨씬 낫다.
==============================================================================================*/
SELECT
     N'[E] 안전재고 제안값'                         AS REPORT_NM
    ,상태 = CASE WHEN A.SAFE_REG = N'0' THEN N'1.★미등록 - 신규 등록 권장'
                 WHEN A.SAFE_QT < A.DAY_USE * A.LEAD_DT       THEN N'2.과소 등록 - 상향 검토'
                 WHEN A.SAFE_QT > A.DAY_USE * A.LEAD_DT * 3   THEN N'3.과대 등록 - 하향 검토'
                 ELSE N'0.적정' END
    ,A.ITEM_CD                                      AS 품번
    ,A.ITEM_NM                                      AS 품명
    ,A.SPEC                                         AS 규격
    ,A.UNIT_CD                                      AS 단위
    ,계정구분 = CASE A.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE A.ACCT_FG END
    ,A.SAFE_QT                                      AS 현재_안전재고
    ,A.DAY_USE                                      AS 일평균사용량
    ,A.LEAD_DT                                      AS 리드타임일
    ,@SAFE_K                                        AS 안전계수
    ,제안_안전재고 = CAST(A.DAY_USE * A.LEAD_DT * @SAFE_K AS DECIMAL(19,2))
    ,차이 = CAST(A.DAY_USE * A.LEAD_DT * @SAFE_K - A.SAFE_QT AS DECIMAL(19,2))
    ,A.STK_QT                                       AS 현재고
    ,A.USE_QT                                       AS 최근사용량
    ,A.LY_QT                                        AS 전년동기_사용량
    ,계절성_배수 = CAST(CASE WHEN A.LY_QT > 0 THEN A.USE_QT / A.LY_QT END AS DECIMAL(9,2))
    ,비고 = CASE
         WHEN A.LEAD_REG = N'0'
              THEN N'★ 리드타임 미등록 - 기본값 ' + CAST(@LEAD_DFT AS NVARCHAR(5)) + N'일로 산정. 실제값 등록 필요'
         WHEN A.LY_QT > 0 AND (A.USE_QT / A.LY_QT > 1.5 OR A.USE_QT / A.LY_QT < 0.67)
              THEN N'★ 전년 동기 대비 변동 큼 - 계절성 확인 후 조정'
         WHEN A.DAY_USE = 0
              THEN N'사용 이력 없음 - 제안값 산정 불가'
         ELSE N'-' END
FROM   #ALM A
WHERE  A.DAY_USE > 0                                        -- 사용 이력 있는 품목만 제안
  AND  ( A.SAFE_REG = N'0'
      OR A.SAFE_QT < A.DAY_USE * A.LEAD_DT
      OR A.SAFE_QT > A.DAY_USE * A.LEAD_DT * 3 )
ORDER BY 상태, 제안_안전재고 DESC
;


/*==============================================================================================
  ** 쿼리 F : 마스터 등록률  ★ 이 리포트를 믿어도 되는지 판단하는 선행 지표
==============================================================================================*/
SELECT
     N'[F] 마스터 등록률'                           AS REPORT_NM
    ,COUNT(*)                                       AS 대상품목수
    ,안전재고_등록   = SUM(CASE WHEN A.SAFE_REG = N'1' THEN 1 ELSE 0 END)
    ,안전재고_미등록 = SUM(CASE WHEN A.SAFE_REG = N'0' THEN 1 ELSE 0 END)
    ,안전재고_등록률_PCT = CAST(SUM(CASE WHEN A.SAFE_REG = N'1' THEN 1.0 ELSE 0 END)
                                / NULLIF(COUNT(*),0) * 100 AS DECIMAL(5,1))
    ,리드타임_등록   = SUM(CASE WHEN A.LEAD_REG = N'1' THEN 1 ELSE 0 END)
    ,리드타임_미등록 = SUM(CASE WHEN A.LEAD_REG = N'0' THEN 1 ELSE 0 END)
    ,리드타임_등록률_PCT = CAST(SUM(CASE WHEN A.LEAD_REG = N'1' THEN 1.0 ELSE 0 END)
                                / NULLIF(COUNT(*),0) * 100 AS DECIMAL(5,1))
    ,사용이력_있음   = SUM(CASE WHEN A.DAY_USE > 0 THEN 1 ELSE 0 END)
    ,판정 = CASE
         WHEN SUM(CASE WHEN A.SAFE_REG=N'1' THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0) < 0.3
              THEN N'1.★안전재고 등록률 30% 미만 - 알람등급 3/9 는 신뢰할 수 없음. 등급 1·2 만 사용할 것'
         WHEN SUM(CASE WHEN A.SAFE_REG=N'1' THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0) < 0.7
              THEN N'2.안전재고 등록률 70% 미만 - 쿼리 E 로 등록을 먼저 확대할 것'
         WHEN SUM(CASE WHEN A.LEAD_REG=N'1' THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0) < 0.7
              THEN N'3.리드타임 등록률 70% 미만 - 조달불가 판정 정확도 저하'
         ELSE N'0.정상 - 전 등급 사용 가능' END
FROM   #ALM A
;


/*==============================================================================================
  ** 쿼리 G : 전체 요약 (경영 보고 1행)  ★ 목표 결품 품목수 = 0
==============================================================================================*/
;WITH X AS (
    SELECT
         A.*
        ,GRD = CASE
             WHEN A.AVL_QT < 0                                                 THEN 1
             WHEN A.DAY_USE > 0 AND A.AVL_QT / A.DAY_USE < A.LEAD_DT           THEN 2
             WHEN A.SAFE_REG = N'1' AND A.AVL_QT < A.SAFE_QT                   THEN 3
             WHEN A.SAFE_REG = N'1' AND A.STK_QT > A.SAFE_QT*@OVER_K2
              AND A.DEAD_QT = 0                                                THEN 8
             WHEN A.SAFE_REG = N'1' AND A.STK_QT > A.SAFE_QT*@OVER_K1          THEN 9
             WHEN A.SAFE_REG = N'0' AND A.DEAD_QT = 0 AND A.STK_QT > 0         THEN 8
             ELSE 0 END
    FROM #ALM A
)
SELECT
     N'[G] 재고 알람 요약'                          AS REPORT_NM
    ,@BASE_DT                                       AS 기준일
    ,@TGT_SHORT                                     AS 목표_결품품목수
    ,COUNT(*)                                       AS 대상품목수
    ,결품품목수     = SUM(CASE WHEN X.GRD = 1 THEN 1 ELSE 0 END)
    ,조달불가품목수 = SUM(CASE WHEN X.GRD = 2 THEN 1 ELSE 0 END)
    ,안전재고미달수 = SUM(CASE WHEN X.GRD = 3 THEN 1 ELSE 0 END)
    ,체화품목수     = SUM(CASE WHEN X.GRD = 8 THEN 1 ELSE 0 END)
    ,과잉품목수     = SUM(CASE WHEN X.GRD = 9 THEN 1 ELSE 0 END)
    ,정상품목수     = SUM(CASE WHEN X.GRD = 0 THEN 1 ELSE 0 END)
    ,긴급조치합계   = SUM(CASE WHEN X.GRD IN (1,2) THEN 1 ELSE 0 END)
    ,부족수량계     = SUM(CASE WHEN X.SAFE_QT > X.AVL_QT THEN X.SAFE_QT - X.AVL_QT ELSE 0 END)
    ,안전재고등록률_PCT = CAST(SUM(CASE WHEN X.SAFE_REG=N'1' THEN 1.0 ELSE 0 END)
                               / NULLIF(COUNT(*),0) * 100 AS DECIMAL(5,1))
    ,판정 = CASE
         WHEN SUM(CASE WHEN X.GRD = 1 THEN 1 ELSE 0 END) > @TGT_SHORT
              THEN N'1.★결품 발생 - 목표(' + CAST(@TGT_SHORT AS NVARCHAR(10)) + N') 초과'
         WHEN SUM(CASE WHEN X.GRD = 2 THEN 1 ELSE 0 END) > 0
              THEN N'2.★조달불가 품목 존재 - 긴급 발주 필요'
         WHEN SUM(CASE WHEN X.SAFE_REG=N'1' THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0) < 0.3
              THEN N'3.★안전재고 등록률 부족 - 알람 신뢰도 낮음'
         ELSE N'0.정상' END
FROM   X
;


DROP TABLE #STK, #USE, #DMD, #SUP, #ALM;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 안전재고 등록률  ★ 쿼리 F 와 같은 목적. 이 리포트의 전제
     SELECT COUNT(*) 전체,
            SUM(CASE WHEN ISNULL(SAFESTOCK_QT,0)=0 THEN 1 ELSE 0 END) 안전재고미등록,
            SUM(CASE WHEN ISNULL(LEAD_DT,0)=0      THEN 1 ELSE 0 END) 리드타임미등록
     FROM   SITEM WHERE CO_CD='1000' AND ISNULL(USE_YN,'1')='1';
     --> 안전재고 등록률이 30% 미만이면 알람등급 1·2 만 쓰고, 쿼리 E 로 등록을 먼저 확대할 것.

  -- (2) 컬럼명 확인  ★ 사이트/버전에 따라 다를 수 있다
     SELECT name FROM sys.columns WHERE object_id = OBJECT_ID('SITEM')
       AND name IN ('SAFESTOCK_QT','LEAD_DT','LOT_FG','S_CD','ACCT_FG');
     --> SAFESTOCK_QT 가 없으면 안전재고를 다른 컬럼이나 별도 테이블로 관리하는 사이트다.

  -- (3) 사용량 정의 점검  ★ 재고이동을 사용량으로 세면 알람이 과잉 발생한다
     SELECT GRP_FG, COUNT(*) 건수, SUM(IISU_QT) 출고량
     FROM   LINVTORY WHERE CO_CD='1000' AND P_YR='2026' AND IO_FG='2' GROUP BY GRP_FG;
     --> 본 쿼리는 GRP_FG='5'(재고이동)만 제외한다. 사이트에 다른 비소비 출고가 있으면 추가할 것.

  -- (4) 마이너스 재고 여부  ★ 가용재고 신뢰도에 직결
     SELECT COUNT(*) FROM (
       SELECT ITEM_CD, SUM(ISNULL(IOPEN_QT,0)+ISNULL(IRCV_QT,0)-ISNULL(IISU_QT,0)) Q
       FROM LINVTORY WHERE CO_CD='1000' AND P_YR='2026' GROUP BY ITEM_CD
     ) X WHERE Q < 0;
     --> 많으면 P-03 쿼리 E 로 원인을 먼저 잡을 것.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **계절성 품목은 최근 @AVG_MM 개월 평균이 왜곡된다.** 쿼리 E 에 전년 동기 대비
     `계절성_배수` 를 넣어 감지할 수 있게 했지만, 자동 보정은 하지 않는다.
     배수가 1.5 초과 또는 0.67 미만인 품목은 제안값을 그대로 쓰지 말 것.

  2) **금액이 없다.** 과잉/체화의 심각도는 결국 금액인데, 재고 금액은 평가 방법에 따라
     달라지므로 넣지 않았다. 금액 기준 우선순위가 필요하면 `LINV_TAV.ISU_UM` 또는
     `LINV_MVFIFO` 를 조인할 것. (M-04 쿼리 A 의 단가 조회 패턴 참조)

  3) 가용재고에 **가출고·검사중·이동중 재고는 반영하지 않았다.** 정밀한 MRP 가용재고는
     `원자재수급총괄현황_MRP.sql` 의 LDEMAND_STORY 산식을 쓸 것.

  4) LOT 사이즈(`SITEM.FOQ_QT`)와 발주 단위를 고려하지 않은 `권장발주수량` 이다.
     실제 발주 시에는 최소 발주량·포장 단위로 올림해야 한다.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   P03_실시간재고_추적.sql       : 현재고·가용재고의 원천 (창고·장소·LOT 상세)
   원자재수급총괄현황_MRP.sql    : 정밀 소요량 전개 + 발주 제안
   P01_청구발주입고_진행현황.sql : 발주가 실제로 진행되는지 추적
   B01_마스터품질_스코어카드.sql : 안전재고·리드타임 등록률 전사 측정
==============================================================================================*/
