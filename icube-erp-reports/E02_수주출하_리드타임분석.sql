/*==============================================================================================
  [ iCUBE ] E-02  수주 → 출하 리드타임 분석                                          (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 수주부터 출하까지 실제 며칠 걸리는가, **어느 구간이 긴가**.
         + 마스터에 등록된 조달일수(`SITEM.LEAD_DT`)와 실측의 괴리를 드러내
           MRP 예정발주일의 신뢰도 개선 과제를 자동 도출한다.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 구간 분해 ]
  ----------------------------------------------------------------------------------------------
     ① 수주 → 청구        LSO.SO_DT        → LPUR_REQ.REQ_DT
     ② 청구 → 발주/지시    REQ_DT           → LPO.PO_DT / LWO_WF.ORD_DT
     ③ 발주 → 입고        PO_DT            → LSTOCK.RCV_DT          [구매 경로]
     ④ 지시 → 실적        ORD_DT           → LORCV_H.WR_DT          [생산 경로]
     ⑤ 실적 → 실적입고    WR_DT            → LPRDINWH.INWH_DT       [생산 경로]
     ⑥ 입고 → 출고        RCV_DT / INWH_DT → LDELIVER.ISU_DT
     ─────────────────────────────────────────────────────────────
     총 리드타임          SO_DT            → ISU_DT

  ----------------------------------------------------------------------------------------------
  [ ★ 반드시 지킨 것 ]
  ----------------------------------------------------------------------------------------------
   1. **중앙값(median)을 평균과 함께 낸다.** 평균은 이상치 몇 건에 끌려간다.
      리드타임은 오른쪽 꼬리가 긴 분포라 **평균 > 중앙값** 이 정상이며, 둘의 차이가 크면
      "가끔 아주 오래 걸리는 건"이 있다는 뜻이다. P90 도 함께 내 그 꼬리를 보여준다.
      → `PERCENTILE_CONT(0.5)` / `PERCENTILE_CONT(0.9)` 사용.

   2. **등록 리드타임과의 괴리를 표시한다.** `SITEM.LEAD_DT` 가 실측과 다르면
      MRP 의 예정발주일이 통째로 틀어진다. 쿼리 C 가 이 괴리를 품목별로 낸다.

   3. **전사 평균은 행동으로 이어지지 않는다.** 품목군·거래처·경로(구매/생산)별로 나눈다.

   4. **구매 경로와 생산 경로를 분기**한다. `LWO_WF.SO_NB` 로 생산, 청구→발주로 구매.
      한 수주에 두 경로가 섞이면 각각의 최종 시점을 잡는다.
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@FR_DT    NVARCHAR(8)  = N'20260101'     -- 수주일 FROM
    ,@TO_DT    NVARCHAR(8)  = N'20261231'
    ,@TR_CD    NVARCHAR(10) = NULL
    ,@ITEM_CD  NVARCHAR(25) = NULL
    ,@ACCT_FG  NVARCHAR(1)  = NULL
    ,@MIN_CNT  INT          = 3               -- 통계 산출 최소 표본 건수
    ,@OUT_P    DECIMAL(5,2) = 0.90            -- 꼬리 분위 (P90)
;

IF OBJECT_ID('tempdb..#LT')  IS NOT NULL DROP TABLE #LT;
IF OBJECT_ID('tempdb..#PCT') IS NOT NULL DROP TABLE #PCT;


/*==============================================================================================
  1. #LT : 수주 라인별 구간 일수
     ─ 각 단계는 OUTER APPLY (SELECT TOP 1 / MIN / MAX) 로 잡아 수주 1행을 유지한다.
       (fan-out 을 만들면 통계가 전부 왜곡된다)
==============================================================================================*/
SELECT
     H.SO_NB
    ,D.SO_SQ
    ,H.SO_DT
    ,D.DUE_DT
    ,H.TR_CD
    ,D.ITEM_CD
    ,SO_QT  = CAST(ISNULL(D.SO_QT , 0) AS DECIMAL(19,6))
    ,ISU_QT = CAST(ISNULL(D.ISU_QT, 0) AS DECIMAL(19,6))
    ,SO_AM  = CAST(ISNULL(D.SO_AM , 0) AS DECIMAL(19,4))
    -- 각 단계 시점
    ,REQ_DT  = RQ.DT
    ,PO_DT   = PO.DT
    ,RCV_DT  = RC.DT
    ,ORD_DT  = WO.DT
    ,WR_DT   = WR.DT
    ,INWH_DT = IW.DT
    ,ISU_DT  = DV.DT
    -- 경로 판정
    ,ROUTE = CASE WHEN WO.DT IS NOT NULL AND PO.DT IS NOT NULL THEN N'3.혼합'
                  WHEN WO.DT IS NOT NULL                       THEN N'2.생산'
                  WHEN PO.DT IS NOT NULL                       THEN N'1.구매'
                  ELSE N'9.직출고(재고)' END
    -- 구간 일수
    ,L1 = DATEDIFF(DAY, CONVERT(DATE,H.SO_DT), CONVERT(DATE,RQ.DT))   -- 수주→청구
    ,L2P= DATEDIFF(DAY, CONVERT(DATE,RQ.DT ), CONVERT(DATE,PO.DT))   -- 청구→발주
    ,L2W= DATEDIFF(DAY, CONVERT(DATE,H.SO_DT), CONVERT(DATE,WO.DT))  -- 수주→지시
    ,L3 = DATEDIFF(DAY, CONVERT(DATE,PO.DT ), CONVERT(DATE,RC.DT))   -- 발주→입고
    ,L4 = DATEDIFF(DAY, CONVERT(DATE,WO.DT ), CONVERT(DATE,WR.DT))   -- 지시→실적
    ,L5 = DATEDIFF(DAY, CONVERT(DATE,WR.DT ), CONVERT(DATE,IW.DT))   -- 실적→실적입고
    ,L6 = DATEDIFF(DAY, CONVERT(DATE, ISNULL(IW.DT, RC.DT)), CONVERT(DATE,DV.DT))  -- 입고→출고
    ,LT = DATEDIFF(DAY, CONVERT(DATE,H.SO_DT), CONVERT(DATE,DV.DT))  -- 총 리드타임
    -- 납기 대비
    ,DELAY = DATEDIFF(DAY, CONVERT(DATE,D.DUE_DT), CONVERT(DATE,DV.DT))
    ,PROMISE = DATEDIFF(DAY, CONVERT(DATE,H.SO_DT), CONVERT(DATE,D.DUE_DT))  -- 약속 리드타임
INTO #LT
FROM       LSO   H WITH (NOLOCK)
INNER JOIN LSO_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.SO_NB = H.SO_NB
-- ① 청구 (수주 연결이 있는 경우만)
OUTER APPLY ( SELECT DT = MIN(Q.REQ_DT)
              FROM       LPUR_REQ   P WITH (NOLOCK)
              INNER JOIN LPUR_REQ_D Q2 WITH (NOLOCK) ON Q2.CO_CD=P.CO_CD AND Q2.REQ_NB=P.REQ_NB
              CROSS APPLY (SELECT REQ_DT = P.REQ_DT) Q
              WHERE  P.CO_CD = D.CO_CD AND Q2.ITEM_CD = D.ITEM_CD
                AND  P.REQ_DT >= H.SO_DT
                AND  ISNULL(Q2.USE_YN, N'1') = N'1' ) RQ
-- ② 발주
OUTER APPLY ( SELECT DT = MIN(P.PO_DT)
              FROM       LPO   P WITH (NOLOCK)
              INNER JOIN LPO_D X WITH (NOLOCK) ON X.CO_CD=P.CO_CD AND X.PO_NB=P.PO_NB
              WHERE  P.CO_CD = D.CO_CD AND X.ITEM_CD = D.ITEM_CD
                AND  P.PO_DT >= H.SO_DT
                AND  ISNULL(X.USE_YN, N'1') = N'1' ) PO
-- ③ 입고
OUTER APPLY ( SELECT DT = MIN(S.RCV_DT)
              FROM       LSTOCK   S WITH (NOLOCK)
              INNER JOIN LSTOCK_D Y WITH (NOLOCK) ON Y.CO_CD=S.CO_CD AND Y.RCV_NB=S.RCV_NB
              WHERE  S.CO_CD = D.CO_CD AND Y.ITEM_CD = D.ITEM_CD
                AND  S.RCV_DT >= H.SO_DT
                AND  ISNULL(Y.USE_YN, N'1') = N'1' ) RC
-- ④ 작업지시  ★ 수주 직결 (SO_NB + LN_SQ)
OUTER APPLY ( SELECT TOP 1 DT = W.ORD_DT, W.WO_CD
              FROM   LWO_WF W WITH (NOLOCK)
              WHERE  W.CO_CD = D.CO_CD AND W.SO_NB = D.SO_NB AND W.LN_SQ = D.SO_SQ
                AND  ISNULL(W.USE_YN, N'1') = N'1'
              ORDER BY W.ORD_DT ) WO
-- ⑤ 생산실적
OUTER APPLY ( SELECT DT = MAX(R.WR_DT)
              FROM   LORCV_H R WITH (NOLOCK)
              WHERE  R.CO_CD = D.CO_CD AND R.WO_CD = WO.WO_CD
                AND  ISNULL(R.SUB_TP, N'0') = N'0' AND ISNULL(R.BAD_YN, N'0') = N'0'
                AND  ISNULL(R.USE_YN, N'1') = N'1' ) WR
-- ⑥ 실적입고
OUTER APPLY ( SELECT DT = MAX(N.INWH_DT)
              FROM       LPRDINWH N WITH (NOLOCK)
              INNER JOIN LORCV_H  R WITH (NOLOCK) ON R.CO_CD=N.CO_CD AND R.WR_CD=N.WR_CD
              WHERE  N.CO_CD = D.CO_CD AND R.WO_CD = WO.WO_CD
                AND  ISNULL(N.USE_YN, N'1') = N'1' ) IW
-- ⑦ 출고  ★ 수주 직결
OUTER APPLY ( SELECT DT = MAX(X.ISU_DT)
              FROM       LDELIVER   X WITH (NOLOCK)
              INNER JOIN LDELIVER_D Y WITH (NOLOCK) ON Y.CO_CD=X.CO_CD AND Y.ISU_NB=X.ISU_NB
              WHERE  Y.CO_CD = D.CO_CD AND Y.SO_NB = D.SO_NB AND Y.SO_SQ = D.SO_SQ
                AND  ISNULL(Y.USE_YN, N'1') = N'1' AND ISNULL(Y.EXPIRE_YN, N'1') = N'1' ) DV
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = D.CO_CD AND I.ITEM_CD = D.ITEM_CD
WHERE  H.CO_CD = @CO_CD
  AND  H.SO_DT BETWEEN @FR_DT AND @TO_DT
  AND  ISNULL(D.USE_YN, N'1') = N'1'
  AND  ISNULL(D.SO_QT, 0) > 0
  AND  DV.DT IS NOT NULL                                    -- ★ 출고 완료 건만 (리드타임 확정)
  AND  (@DIV_CD  IS NULL OR H.DIV_CD  = @DIV_CD)
  AND  (@TR_CD   IS NULL OR H.TR_CD   = @TR_CD)
  AND  (@ITEM_CD IS NULL OR D.ITEM_CD = @ITEM_CD)
  AND  (@ACCT_FG IS NULL OR I.ACCT_FG = @ACCT_FG)
  AND  ISNULL(I.S_CD, N'') <> N'Z00'
;
CREATE CLUSTERED INDEX IX_LT ON #LT (ITEM_CD, SO_NB, SO_SQ);
PRINT N'[1] 리드타임 확정 건 : ' + CAST(@@ROWCOUNT AS NVARCHAR(20));


/*==============================================================================================
  2. #PCT : 구간별 분위수 (중앙값 / P90)
     ─ PERCENTILE_CONT 는 SQL Server 에서 윈도 함수이므로 행마다 값이 나온다.
       DISTINCT 로 한 행만 남긴다.
==============================================================================================*/
SELECT DISTINCT
     STAGE
    ,MED = PERCENTILE_CONT(0.5)    WITHIN GROUP (ORDER BY V) OVER (PARTITION BY STAGE)
    ,P90 = PERCENTILE_CONT(@OUT_P) WITHIN GROUP (ORDER BY V) OVER (PARTITION BY STAGE)
INTO #PCT
FROM (
    SELECT STAGE = N'1.수주→청구'    , V = CAST(L1  AS FLOAT) FROM #LT WHERE L1  IS NOT NULL AND L1  >= 0
    UNION ALL SELECT N'2.청구→발주'  , CAST(L2P AS FLOAT) FROM #LT WHERE L2P IS NOT NULL AND L2P >= 0
    UNION ALL SELECT N'2.수주→지시'  , CAST(L2W AS FLOAT) FROM #LT WHERE L2W IS NOT NULL AND L2W >= 0
    UNION ALL SELECT N'3.발주→입고'  , CAST(L3  AS FLOAT) FROM #LT WHERE L3  IS NOT NULL AND L3  >= 0
    UNION ALL SELECT N'4.지시→실적'  , CAST(L4  AS FLOAT) FROM #LT WHERE L4  IS NOT NULL AND L4  >= 0
    UNION ALL SELECT N'5.실적→입고'  , CAST(L5  AS FLOAT) FROM #LT WHERE L5  IS NOT NULL AND L5  >= 0
    UNION ALL SELECT N'6.입고→출고'  , CAST(L6  AS FLOAT) FROM #LT WHERE L6  IS NOT NULL AND L6  >= 0
    UNION ALL SELECT N'9.총 리드타임', CAST(LT  AS FLOAT) FROM #LT WHERE LT  IS NOT NULL AND LT  >= 0
) X;


/*==============================================================================================
  ** 쿼리 A : 구간별 리드타임 통계  ★ 병목 구간 식별 (메인)
     ─ 평균과 중앙값을 나란히 본다. 차이가 크면 이상치가 평균을 끌고 있는 것이다.
==============================================================================================*/
;WITH S AS (
    SELECT STAGE = N'1.수주→청구'    , V = CAST(L1  AS DECIMAL(9,2)) FROM #LT WHERE L1  >= 0
    UNION ALL SELECT N'2.청구→발주'  , CAST(L2P AS DECIMAL(9,2)) FROM #LT WHERE L2P >= 0
    UNION ALL SELECT N'2.수주→지시'  , CAST(L2W AS DECIMAL(9,2)) FROM #LT WHERE L2W >= 0
    UNION ALL SELECT N'3.발주→입고'  , CAST(L3  AS DECIMAL(9,2)) FROM #LT WHERE L3  >= 0
    UNION ALL SELECT N'4.지시→실적'  , CAST(L4  AS DECIMAL(9,2)) FROM #LT WHERE L4  >= 0
    UNION ALL SELECT N'5.실적→입고'  , CAST(L5  AS DECIMAL(9,2)) FROM #LT WHERE L5  >= 0
    UNION ALL SELECT N'6.입고→출고'  , CAST(L6  AS DECIMAL(9,2)) FROM #LT WHERE L6  >= 0
    UNION ALL SELECT N'9.총 리드타임', CAST(LT  AS DECIMAL(9,2)) FROM #LT WHERE LT  >= 0
)
SELECT
     N'[A] 구간별 리드타임'                         AS REPORT_NM
    ,S.STAGE                                        AS 구간
    ,COUNT(*)                                       AS 표본건수
    ,평균일 = CAST(AVG(S.V) AS DECIMAL(9,1))
    ,중앙값 = CAST(MAX(P.MED) AS DECIMAL(9,1))
    ,P90    = CAST(MAX(P.P90) AS DECIMAL(9,1))
    ,최소일 = MIN(S.V)
    ,최대일 = MAX(S.V)
    ,표준편차 = CAST(STDEV(S.V) AS DECIMAL(9,1))
    ,평균_중앙값차 = CAST(AVG(S.V) - MAX(P.MED) AS DECIMAL(9,1))
    ,구성비_PCT = CAST(CASE WHEN S.STAGE <> N'9.총 리드타임'
                            THEN MAX(P.MED) * 100.0
                                 / NULLIF((SELECT MAX(MED) FROM #PCT WHERE STAGE = N'9.총 리드타임'), 0)
                            END AS DECIMAL(5,1))
    ,판정 = CASE
         WHEN COUNT(*) < @MIN_CNT                                  THEN N'9.표본 부족'
         WHEN AVG(S.V) - MAX(P.MED) > MAX(P.MED)                   THEN N'1.★이상치 영향 큼 (평균이 중앙값의 2배 초과)'
         WHEN MAX(P.P90) > MAX(P.MED) * 3                          THEN N'2.★꼬리가 김 (P90 이 중앙값의 3배 초과)'
         WHEN STDEV(S.V) > AVG(S.V)                                THEN N'3.편차 큼 (표준편차 > 평균)'
         ELSE N'0.안정' END
FROM       S
LEFT  JOIN #PCT P ON P.STAGE = S.STAGE
GROUP BY S.STAGE
ORDER BY S.STAGE
;


/*==============================================================================================
  ** 쿼리 B : 경로별 리드타임  (구매 / 생산 / 혼합)
==============================================================================================*/
SELECT
     N'[B] 경로별 리드타임'                         AS REPORT_NM
    ,L.ROUTE                                        AS 조달경로
    ,COUNT(*)                                       AS 건수
    ,SUM(L.SO_AM)                                   AS 수주금액
    ,평균_총리드타임 = CAST(AVG(CAST(L.LT AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,중앙값_총리드타임 = CAST(MAX(M.MED) AS DECIMAL(9,1))
    ,최대_총리드타임 = MAX(L.LT)
    ,평균_약속리드타임 = CAST(AVG(CAST(L.PROMISE AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,여유일 = CAST(AVG(CAST(L.PROMISE AS DECIMAL(9,2))) - AVG(CAST(L.LT AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,납기준수건수 = SUM(CASE WHEN L.DELAY <= 0 THEN 1 ELSE 0 END)
    ,납기준수율_PCT = CAST(SUM(CASE WHEN L.DELAY <= 0 THEN 1.0 ELSE 0 END)
                           / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
    ,평균_발주입고 = CAST(AVG(CAST(L.L3 AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,평균_지시실적 = CAST(AVG(CAST(L.L4 AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,평균_입고출고 = CAST(AVG(CAST(L.L6 AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,판정 = CASE
         WHEN AVG(CAST(L.PROMISE AS DECIMAL(9,2))) < AVG(CAST(L.LT AS DECIMAL(9,2)))
              THEN N'1.★약속 납기가 실제 리드타임보다 짧음 - 구조적 지연'
         WHEN AVG(CAST(L.PROMISE AS DECIMAL(9,2))) - AVG(CAST(L.LT AS DECIMAL(9,2))) < 3
              THEN N'2.여유 3일 미만 - 변동에 취약'
         ELSE N'0.여유 있음' END
FROM       #LT L
OUTER APPLY ( SELECT MED = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CAST(X.LT AS FLOAT))
                           OVER (PARTITION BY (SELECT NULL))
              FROM   #LT X WHERE X.ROUTE = L.ROUTE AND X.LT >= 0 ) M
WHERE  L.LT >= 0
GROUP BY L.ROUTE
ORDER BY L.ROUTE
;


/*==============================================================================================
  ** 쿼리 C : 품목별 리드타임 vs 등록 LEAD_DT  ★ MRP 정확도 개선 과제 자동 도출
     ─ 등록 리드타임이 실측과 다르면 MRP 예정발주일이 통째로 틀어진다.
==============================================================================================*/
;WITH P AS (
    SELECT DISTINCT
         ITEM_CD
        ,MED = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CAST(LT AS FLOAT)) OVER (PARTITION BY ITEM_CD)
        ,MED3 = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CAST(ISNULL(L3, L4) AS FLOAT)) OVER (PARTITION BY ITEM_CD)
    FROM   #LT WHERE LT >= 0
)
SELECT
     N'[C] 품목별 리드타임 · 마스터 괴리'           AS REPORT_NM
    ,L.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
    ,COUNT(*)                                       AS 표본건수
    ,평균_총리드타임 = CAST(AVG(CAST(L.LT AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,중앙값_총리드타임 = CAST(MAX(P.MED) AS DECIMAL(9,1))
    ,최대_총리드타임 = MAX(L.LT)
    ,실측_조달일 = CAST(MAX(P.MED3) AS DECIMAL(9,1))     -- 발주→입고 또는 지시→실적 중앙값
    ,I.LEAD_DT                                      AS 등록_LEAD_DT
    ,괴리일 = CAST(MAX(P.MED3) - CAST(ISNULL(I.LEAD_DT, 0) AS DECIMAL(9,2)) AS DECIMAL(9,1))
    ,괴리율_PCT = CAST(CASE WHEN ISNULL(CAST(I.LEAD_DT AS INT), 0) > 0
                            THEN (MAX(P.MED3) - CAST(I.LEAD_DT AS DECIMAL(9,2)))
                                 / CAST(I.LEAD_DT AS DECIMAL(9,2)) * 100 END AS DECIMAL(9,1))
    ,평균_약속리드타임 = CAST(AVG(CAST(L.PROMISE AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,납기준수율_PCT = CAST(SUM(CASE WHEN L.DELAY <= 0 THEN 1.0 ELSE 0 END)
                           / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
    ,개선과제 = CASE
         WHEN COUNT(*) < @MIN_CNT                                              THEN N'9.표본 부족'
         WHEN ISNULL(CAST(I.LEAD_DT AS INT), 0) = 0
              THEN N'1.★LEAD_DT 미등록 - 실측 ' + CAST(CAST(MAX(P.MED3) AS DECIMAL(9,0)) AS NVARCHAR(10)) + N'일 등록 권장'
         WHEN MAX(P.MED3) > CAST(I.LEAD_DT AS DECIMAL(9,2)) * 1.5
              THEN N'2.★실측이 등록값의 1.5배 초과 - MRP 예정발주일이 늦게 계산됨. 상향 필요'
         WHEN MAX(P.MED3) < CAST(I.LEAD_DT AS DECIMAL(9,2)) * 0.5
              THEN N'3.실측이 등록값의 절반 미만 - 과다 등록. 하향 검토 (불필요한 조기 발주)'
         ELSE N'0.적정' END
FROM       #LT   L
INNER JOIN P     ON P.ITEM_CD = L.ITEM_CD
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = L.ITEM_CD
WHERE  L.LT >= 0
GROUP BY L.ITEM_CD, I.ITEM_NM, I.SPEC, I.ACCT_FG, I.LEAD_DT
ORDER BY 개선과제, ABS(괴리일) DESC
;


/*==============================================================================================
  ** 쿼리 D : 거래처별 리드타임
==============================================================================================*/
;WITH P AS (
    SELECT DISTINCT
         TR_CD
        ,MED = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CAST(LT AS FLOAT)) OVER (PARTITION BY TR_CD)
    FROM   #LT WHERE LT >= 0
)
SELECT
     N'[D] 거래처별 리드타임'                       AS REPORT_NM
    ,L.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,COUNT(*)                                       AS 건수
    ,COUNT(DISTINCT L.ITEM_CD)                      AS 품목수
    ,SUM(L.SO_AM)                                   AS 수주금액
    ,평균_총리드타임 = CAST(AVG(CAST(L.LT AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,중앙값_총리드타임 = CAST(MAX(P.MED) AS DECIMAL(9,1))
    ,최대_총리드타임 = MAX(L.LT)
    ,평균_약속리드타임 = CAST(AVG(CAST(L.PROMISE AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,여유일 = CAST(AVG(CAST(L.PROMISE AS DECIMAL(9,2))) - AVG(CAST(L.LT AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,납기준수율_PCT = CAST(SUM(CASE WHEN L.DELAY <= 0 THEN 1.0 ELSE 0 END)
                           / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
    ,평균_입고출고 = CAST(AVG(CAST(L.L6 AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,판정 = CASE
         WHEN COUNT(*) < @MIN_CNT                                              THEN N'9.표본 부족'
         WHEN AVG(CAST(L.PROMISE AS DECIMAL(9,2))) < AVG(CAST(L.LT AS DECIMAL(9,2)))
              THEN N'1.★무리한 납기 약속 - 구조적으로 못 지킨다'
         WHEN AVG(CAST(L.L6 AS DECIMAL(9,2))) > 7
              THEN N'2.입고→출고 구간이 김 (7일 초과) - 출하 프로세스 확인'
         ELSE N'0.정상' END
FROM       #LT    L
INNER JOIN P      ON P.TR_CD = L.TR_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD = L.TR_CD
WHERE  L.LT >= 0
GROUP BY L.TR_CD, T.TR_NM
ORDER BY 판정 DESC, 평균_총리드타임 DESC
;


/*==============================================================================================
  ** 쿼리 E : 월별 리드타임 추이
==============================================================================================*/
;WITH P AS (
    SELECT DISTINCT
         YM = LEFT(SO_DT, 6)
        ,MED = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CAST(LT AS FLOAT)) OVER (PARTITION BY LEFT(SO_DT, 6))
    FROM   #LT WHERE LT >= 0
)
SELECT
     N'[E] 월별 리드타임 추이'                      AS REPORT_NM
    ,LEFT(L.SO_DT, 6)                               AS 수주월
    ,COUNT(*)                                       AS 건수
    ,SUM(L.SO_AM)                                   AS 수주금액
    ,평균_총리드타임 = CAST(AVG(CAST(L.LT AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,중앙값 = CAST(MAX(P.MED) AS DECIMAL(9,1))
    ,평균_수주지시 = CAST(AVG(CAST(L.L2W AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,평균_발주입고 = CAST(AVG(CAST(L.L3  AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,평균_지시실적 = CAST(AVG(CAST(L.L4  AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,평균_입고출고 = CAST(AVG(CAST(L.L6  AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,납기준수율_PCT = CAST(SUM(CASE WHEN L.DELAY <= 0 THEN 1.0 ELSE 0 END)
                           / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
    ,전월대비_일 = CAST(AVG(CAST(L.LT AS DECIMAL(9,2)))
                        - LAG(AVG(CAST(L.LT AS DECIMAL(9,2)))) OVER (ORDER BY LEFT(L.SO_DT, 6))
                        AS DECIMAL(9,1))
FROM       #LT L
INNER JOIN P   ON P.YM = LEFT(L.SO_DT, 6)
WHERE  L.LT >= 0
GROUP BY LEFT(L.SO_DT, 6)
ORDER BY 수주월
;


/*==============================================================================================
  ** 쿼리 F : 장기 리드타임 상위  (이상치 — 원인 규명 대상)
==============================================================================================*/
SELECT TOP 100
     N'[F] 장기 리드타임 상위'                      AS REPORT_NM
    ,L.SO_NB                                        AS 수주번호
    ,L.SO_SQ                                        AS 수주순번
    ,L.SO_DT                                        AS 수주일
    ,L.DUE_DT                                       AS 납기일
    ,L.ISU_DT                                       AS 출고일
    ,L.LT                                           AS 총리드타임
    ,L.PROMISE                                      AS 약속리드타임
    ,L.DELAY                                        AS 납기지연일
    ,L.ROUTE                                        AS 조달경로
    ,L.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,L.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,L.SO_QT                                        AS 수주수량
    ,L.SO_AM                                        AS 수주금액
    -- 구간
    ,L.L1                                           AS 수주_청구
    ,L.L2P                                          AS 청구_발주
    ,L.L2W                                          AS 수주_지시
    ,L.L3                                           AS 발주_입고
    ,L.L4                                           AS 지시_실적
    ,L.L5                                           AS 실적_입고
    ,L.L6                                           AS 입고_출고
    ,최장구간 = CASE
         WHEN ISNULL(L.L3,0) >= ISNULL(L.L4,0) AND ISNULL(L.L3,0) >= ISNULL(L.L6,0)
          AND ISNULL(L.L3,0) >= ISNULL(L.L2W,0)                            THEN N'발주→입고 (구매)'
         WHEN ISNULL(L.L4,0) >= ISNULL(L.L6,0) AND ISNULL(L.L4,0) >= ISNULL(L.L2W,0)
                                                                            THEN N'지시→실적 (생산)'
         WHEN ISNULL(L.L6,0) >= ISNULL(L.L2W,0)                             THEN N'입고→출고 (출하)'
         WHEN ISNULL(L.L2W,0) > 0                                           THEN N'수주→지시 (착수 지연)'
         ELSE N'구간 미상' END
    ,확인 = CASE
         WHEN ISNULL(L.L2W,0) > 14 THEN N'★ 지시 착수가 2주 이상 늦음 - 생산계획 확인 (M-11)'
         WHEN ISNULL(L.L3 ,0) > 30 THEN N'★ 조달에 30일 초과 - 공급사 확인 (P-02)'
         WHEN ISNULL(L.L4 ,0) > 30 THEN N'★ 생산에 30일 초과 - 지시 진행 확인 (M-01)'
         WHEN ISNULL(L.L6 ,0) > 14 THEN N'★ 입고 후 출고까지 2주 초과 - 출하 프로세스 확인'
         ELSE N'복합 원인' END
FROM       #LT    L
LEFT  JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = L.ITEM_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = L.TR_CD
WHERE  L.LT >= 0
ORDER BY L.LT DESC
;


/*==============================================================================================
  ** 쿼리 G : 데이터 점검  ★ 구간 추적 가능 여부
     ─ 단계 간 연결이 끊어져 있으면 그 구간은 NULL 이 되어 통계에서 빠진다.
==============================================================================================*/
SELECT
     N'[G] 구간 추적 가능성'                        AS REPORT_NM
    ,전체건수 = COUNT(*)
    ,청구추적 = SUM(CASE WHEN L.REQ_DT  IS NOT NULL THEN 1 ELSE 0 END)
    ,발주추적 = SUM(CASE WHEN L.PO_DT   IS NOT NULL THEN 1 ELSE 0 END)
    ,입고추적 = SUM(CASE WHEN L.RCV_DT  IS NOT NULL THEN 1 ELSE 0 END)
    ,지시추적 = SUM(CASE WHEN L.ORD_DT  IS NOT NULL THEN 1 ELSE 0 END)
    ,실적추적 = SUM(CASE WHEN L.WR_DT   IS NOT NULL THEN 1 ELSE 0 END)
    ,실적입고추적 = SUM(CASE WHEN L.INWH_DT IS NOT NULL THEN 1 ELSE 0 END)
    ,지시추적률_PCT = CAST(SUM(CASE WHEN L.ORD_DT IS NOT NULL THEN 1.0 ELSE 0 END)
                           / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
    ,직출고건수 = SUM(CASE WHEN L.ROUTE = N'9.직출고(재고)' THEN 1 ELSE 0 END)
    ,음수구간건수 = SUM(CASE WHEN L.LT < 0 THEN 1 ELSE 0 END)
    ,판정 = CASE
         WHEN COUNT(*) = 0
              THEN N'1.★출고 완료 수주가 없음 - 기간을 넓혀 재조회'
         WHEN SUM(CASE WHEN L.ORD_DT IS NOT NULL THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0) < 0.3
              THEN N'2.★수주-지시 연결(LWO_WF.SO_NB) 30% 미만 - 생산 경로 분석 신뢰도 낮음'
         WHEN SUM(CASE WHEN L.REQ_DT IS NOT NULL THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0) < 0.1
              THEN N'3.청구 연결 거의 없음 - 구간 ① 은 무시할 것 (청구 미운영 가능성)'
         WHEN SUM(CASE WHEN L.LT < 0 THEN 1 ELSE 0 END) > 0
              THEN N'4.★음수 리드타임 존재 - 수주일보다 빠른 출고. 데이터 확인 필요'
         ELSE N'0.정상' END
FROM   #LT L
;


DROP TABLE #LT, #PCT;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 수주 → 작업지시 연결률  ★ 생산 경로 분석의 전제
     SELECT COUNT(*) 전체, SUM(CASE WHEN ISNULL(SO_NB,'')='' THEN 1 ELSE 0 END) 수주미연결
     FROM   LWO_WF WHERE CO_CD='1000';
     --> 수주 미연결이 대부분이면 계획생산(MTS) 사이트다. 구간 ②·④·⑤ 는 의미가 없고
        ⑥(입고→출고)만 유효하다. 이 경우 M-11(생산계획 대비)이 더 맞는 도구다.

  -- (2) 청구 운영 여부  ★ 구간 ① 의 전제
     SELECT COUNT(*) FROM LPUR_REQ WHERE CO_CD='1000' AND REQ_DT LIKE '2026%';
     --> 0 이면 구간 ① 을 빼고 해석할 것.

  -- (3) 실적 일자 컬럼명 확인  ★ 본 쿼리는 WR_DT 를 쓴다
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('LORCV_H')
       AND name IN ('WR_DT','DOC_DT','ORCV_DT');
     --> EIS 문서는 DOC_DT 로 기술되어 있으나, 본 산출물군(M-01/M-06/M-11)은 일관되게
        WR_DT 를 쓴다. 사이트 실제 컬럼이 DOC_DT 면 ⑤ OUTER APPLY 를 수정할 것.

  -- (4) 출고 완료 수주 규모  ★ 평가 모집단
     SELECT COUNT(*) FROM LSO_D D WHERE CO_CD='1000'
       AND EXISTS (SELECT 1 FROM LDELIVER_D Y WHERE Y.SO_NB=D.SO_NB AND Y.SO_SQ=D.SO_SQ);

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **청구·발주·입고 단계는 품목 기준 근사 매칭이다.** `LPUR_REQ_D` 에 수주번호가 없는
     사이트가 많아, "이 수주 이후 같은 품목의 최초 청구/발주/입고"를 잡는 방식을 썼다.
     따라서 **구간 ①②③ 은 정확도가 떨어진다.** 수주 직결이 확실한 구간은
     ④(지시, `SO_NB`+`LN_SQ` 직결)와 ⑦(출고, 동일 직결)뿐이다.
     청구에 수주번호를 남기는 사이트라면 조인을 직결로 바꿔 정확도를 크게 올릴 수 있다.

  2) **출고 완료 건만 대상**이다. 아직 안 나간 수주는 리드타임이 확정되지 않았으므로 제외했다.
     이 때문에 **오래 걸리는 건이 체계적으로 빠질 수 있다**(생존 편향). 진행 중 건의 경과일은
     S-02(주문미납 현황)에서 봐야 한다. 두 리포트를 같이 보는 것이 맞다.

  3) 구간 합이 총 리드타임과 일치하지 않는다. 구간이 겹치거나(구매·생산 병행) 비어 있을 수
     있기 때문이다. `구성비_PCT` 는 중앙값 기준의 **상대 비중**이며 합이 100%가 되지 않는다.

  4) 분할 출고 시 **최종 출고일** 기준이다. 첫 출고 기준으로 보면 리드타임이 짧아진다.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   S02_주문미납_현황.sql        : 아직 안 나간 건의 경과일 (본 리포트의 보완)
   S03_납기준수율_KPI.sql       : 약속 납기 대비 결과
   P02_발주납기준수_KPI.sql     : 구간 ③(발주→입고)의 공급사별 상세
   M01_작업지시_진행현황.sql    : 구간 ④(지시→실적)의 지시별 상세
   원자재수급총괄현황_MRP.sql   : LEAD_DT 가 실제로 쓰이는 곳 (쿼리 C 개선과제의 수요처)
==============================================================================================*/
