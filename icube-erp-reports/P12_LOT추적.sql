/*==============================================================================================
  [ iCUBE ] P-12  LOT 추적 (정방향 / 역방향)                                         (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : **품질 사고 대응의 핵심 도구.**
         정방향 — "이 원자재 LOT 이 어느 제품, 어느 고객에게 갔는가"  (리콜 범위 확정)
         역방향 — "이 제품 LOT 에 어느 원자재 LOT 이 들어갔는가"      (원인 자재 규명)

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 추적 체인 ]
  ----------------------------------------------------------------------------------------------
     [입고]  LSTOCK_D + LINVTORY.LOT_NB     원자재 LOT 입고
       ↓
     [투입]  LMTL_USE (WR_CD + LOT_NB)      생산실적에 투입된 자재 LOT
       ↓
     [생산]  LORCV_H (WR_CD → 제품 LOT)     그 실적에서 나온 제품 LOT
       ↓
     [출고]  LDELIVER_D.LOT_NB              제품 LOT 의 출고처

  ----------------------------------------------------------------------------------------------
  [ ★ 추적이 성립하려면 ]
  ----------------------------------------------------------------------------------------------
     LOT 이 **모든 단계에 기록**되어야 한다. 한 군데라도 비면 사슬이 끊긴다.
     쿼리 F 가 단계별 LOT 기록률을 먼저 측정한다. **도입 시 이것부터 볼 것.**
     기록률이 낮으면 추적 결과가 "전부"가 아니라 "기록된 것 중 일부"일 뿐이다.
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
    ,@MODE     NVARCHAR(3)  = N'FWD'          -- FWD 정방향(자재→고객) / BWD 역방향(제품→자재)
    ,@LOT_NB   NVARCHAR(30) = NULL            -- ★ 추적 대상 LOT (필수에 가까움)
    ,@ITEM_CD  NVARCHAR(25) = NULL            -- 대상 품목 (LOT 과 함께 지정 권장)
    ,@FR_DT    NVARCHAR(8)  = N'20260101'
    ,@TO_DT    NVARCHAR(8)  = N'20261231'
;

DECLARE @HAS_USE BIT = 0;
IF OBJECT_ID(N'dbo.LMTL_USE', N'U') IS NOT NULL SET @HAS_USE = 1;

IF OBJECT_ID('tempdb..#USE') IS NOT NULL DROP TABLE #USE;
IF OBJECT_ID('tempdb..#PRD') IS NOT NULL DROP TABLE #PRD;


/*==============================================================================================
  1. #USE : 자재 사용(투입) — 실적번호 × 자재LOT
==============================================================================================*/
CREATE TABLE #USE (
     WR_CD      NVARCHAR(20)
    ,MITEM_CD   NVARCHAR(25)     -- 투입 자재 품번
    ,MLOT_NB    NVARCHAR(30)     -- 투입 자재 LOT
    ,USE_QT     DECIMAL(19,6)
);

IF @HAS_USE = 1
BEGIN
    INSERT INTO #USE (WR_CD, MITEM_CD, MLOT_NB, USE_QT)
    SELECT
         U.WR_CD
        ,U.ITEM_CD
        ,ISNULL(U.LOT_NB, N'')
        ,SUM(CAST(ISNULL(U.USE_QT, 0) AS DECIMAL(19,6)))
    FROM   LMTL_USE U WITH (NOLOCK)
    WHERE  U.CO_CD = @CO_CD
      AND  ISNULL(U.USE_YN, N'1') = N'1'
      AND  ISNULL(U.WR_CD, N'') <> N''
    GROUP BY U.WR_CD, U.ITEM_CD, ISNULL(U.LOT_NB, N'');
    PRINT N'[1] LMTL_USE : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 행';
END
ELSE PRINT N'[1] ★ LMTL_USE 없음 - 자재 LOT 추적 불가';

CREATE CLUSTERED INDEX IX_USE ON #USE (WR_CD, MLOT_NB);


/*==============================================================================================
  2. #PRD : 생산실적 — 실적번호 × 제품LOT
==============================================================================================*/
SELECT
     R.WR_CD
    ,R.WO_CD
    ,R.ITEM_CD                                      -- 생산 품번
    ,PLOT_NB = ISNULL(R.LOT_NB, N'')                -- 제품 LOT
    ,R.WR_DT
    ,GOOD_QT = SUM(CASE WHEN ISNULL(R.SUB_TP,N'0')=N'0' AND ISNULL(R.BAD_YN,N'0')=N'0'
                        THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
    ,BAD_QT  = SUM(CASE WHEN ISNULL(R.BAD_YN,N'0')=N'1'
                        THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
INTO #PRD
FROM   LORCV_H R WITH (NOLOCK)
WHERE  R.CO_CD = @CO_CD
  AND  R.WR_DT BETWEEN @FR_DT AND @TO_DT
  AND  ISNULL(R.USE_YN, N'1') = N'1'
  AND  (@DIV_CD IS NULL OR R.DIV_CD = @DIV_CD)
GROUP BY R.WR_CD, R.WO_CD, R.ITEM_CD, ISNULL(R.LOT_NB, N''), R.WR_DT;
CREATE CLUSTERED INDEX IX_PRD ON #PRD (WR_CD);


/*==============================================================================================
  ** 쿼리 A : 정방향 추적  ─ 자재 LOT → 제품 LOT → 고객   ★ 리콜 범위 확정
     실행 : @MODE='FWD', @LOT_NB = 문제 자재 LOT
==============================================================================================*/
SELECT
     N'[A] 정방향 추적 (자재→고객)'                 AS REPORT_NM
    -- 투입 자재
    ,U.MITEM_CD                                     AS 자재품번
    ,MI.ITEM_NM                                     AS 자재품명
    ,U.MLOT_NB                                      AS 자재LOT
    ,U.USE_QT                                       AS 투입수량
    -- 생산
    ,P.WR_CD                                        AS 실적번호
    ,P.WO_CD                                        AS 지시번호
    ,P.WR_DT                                        AS 생산일
    ,P.ITEM_CD                                      AS 제품품번
    ,PI.ITEM_NM                                     AS 제품품명
    ,P.PLOT_NB                                      AS 제품LOT
    ,P.GOOD_QT                                      AS 생산양품
    ,P.BAD_QT                                       AS 생산불량
    -- 출고
    ,D.ISU_NB                                       AS 출고번호
    ,H.ISU_DT                                       AS 출고일
    ,H.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,D.ISU_QT                                       AS 출고수량
    ,D.LOT_NB                                       AS 출고LOT
    ,H.SO_FG                                        AS 거래구분
    ,추적상태 = CASE
         WHEN D.ISU_NB IS NULL AND P.WR_CD IS NULL  THEN N'1.★생산 미연결 (자재만 투입)'
         WHEN D.ISU_NB IS NULL                      THEN N'2.미출고 (사내 재고)'
         ELSE                                            N'0.출고 완료 - 리콜 대상' END
    ,조치 = CASE
         WHEN D.ISU_NB IS NOT NULL THEN N'★ 고객 통보 대상 - ' + ISNULL(T.TR_NM, H.TR_CD)
         WHEN P.WR_CD IS NOT NULL  THEN N'사내 재고 회수 - 제품 LOT ' + P.PLOT_NB
         ELSE N'자재 재고 회수' END
FROM       #USE  U
LEFT  JOIN #PRD  P ON P.WR_CD = U.WR_CD
LEFT  JOIN LDELIVER_D D WITH (NOLOCK)
        ON D.CO_CD = @CO_CD AND D.ITEM_CD = P.ITEM_CD
       AND ISNULL(D.LOT_NB, N'') = P.PLOT_NB
       AND ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
LEFT  JOIN LDELIVER   H WITH (NOLOCK) ON H.CO_CD = D.CO_CD AND H.ISU_NB = D.ISU_NB
LEFT  JOIN SITEM     MI WITH (NOLOCK) ON MI.CO_CD = @CO_CD AND MI.ITEM_CD = U.MITEM_CD
LEFT  JOIN SITEM     PI WITH (NOLOCK) ON PI.CO_CD = @CO_CD AND PI.ITEM_CD = P.ITEM_CD
LEFT  JOIN STRADE     T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = H.TR_CD
WHERE  @MODE = N'FWD'
  AND  (@LOT_NB  IS NULL OR U.MLOT_NB  = @LOT_NB)
  AND  (@ITEM_CD IS NULL OR U.MITEM_CD = @ITEM_CD)
  AND  U.MLOT_NB <> N''
ORDER BY 추적상태, H.ISU_DT, P.WR_DT
;


/*==============================================================================================
  ** 쿼리 B : 역방향 추적  ─ 제품 LOT → 투입 자재 LOT → 공급처   ★ 원인 자재 규명
     실행 : @MODE='BWD', @LOT_NB = 문제 제품 LOT
==============================================================================================*/
SELECT
     N'[B] 역방향 추적 (제품→자재)'                 AS REPORT_NM
    -- 제품
    ,P.ITEM_CD                                      AS 제품품번
    ,PI.ITEM_NM                                     AS 제품품명
    ,P.PLOT_NB                                      AS 제품LOT
    ,P.WR_CD                                        AS 실적번호
    ,P.WO_CD                                        AS 지시번호
    ,P.WR_DT                                        AS 생산일
    ,P.GOOD_QT                                      AS 생산양품
    ,P.BAD_QT                                       AS 생산불량
    -- 투입 자재
    ,U.MITEM_CD                                     AS 자재품번
    ,MI.ITEM_NM                                     AS 자재품명
    ,MI.SPEC                                        AS 자재규격
    ,U.MLOT_NB                                      AS 자재LOT
    ,U.USE_QT                                       AS 투입수량
    -- 자재 입고 이력 (LOT 기준)
    ,S.RCV_DT                                       AS 자재입고일
    ,S.TR_CD                                        AS 공급처코드
    ,ST.TR_NM                                       AS 공급처명
    ,S.RCV_QT                                       AS 입고수량
    ,S.RCV_NB                                       AS 입고번호
    ,추적상태 = CASE
         WHEN U.MLOT_NB = N''                       THEN N'1.★자재 LOT 미기록 - 추적 불가'
         WHEN S.RCV_NB IS NULL                      THEN N'2.★입고 이력 미확인'
         ELSE                                            N'0.추적 완료' END
    ,조치 = CASE
         WHEN S.TR_CD IS NOT NULL
              THEN N'★ 공급처 ' + ISNULL(ST.TR_NM, S.TR_CD) + N' 에 품질 이의 제기'
         ELSE N'자재 LOT 기록 확인 필요' END
FROM       #PRD  P
INNER JOIN #USE  U ON U.WR_CD = P.WR_CD
OUTER APPLY (
    SELECT TOP 1
         H.RCV_DT, H.TR_CD, H.RCV_NB
        ,RCV_QT = D.RCV_QT
    FROM       LSTOCK   H WITH (NOLOCK)
    INNER JOIN LSTOCK_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.RCV_NB = H.RCV_NB
    WHERE  H.CO_CD = @CO_CD
      AND  D.ITEM_CD = U.MITEM_CD
      AND  ISNULL(D.LOT_NB, N'') = U.MLOT_NB
      AND  ISNULL(D.USE_YN, N'1') = N'1'
    ORDER BY H.RCV_DT DESC
) S
LEFT  JOIN SITEM  PI WITH (NOLOCK) ON PI.CO_CD = @CO_CD AND PI.ITEM_CD = P.ITEM_CD
LEFT  JOIN SITEM  MI WITH (NOLOCK) ON MI.CO_CD = @CO_CD AND MI.ITEM_CD = U.MITEM_CD
LEFT  JOIN STRADE ST WITH (NOLOCK) ON ST.CO_CD = @CO_CD AND ST.TR_CD   = S.TR_CD
WHERE  @MODE = N'BWD'
  AND  (@LOT_NB  IS NULL OR P.PLOT_NB = @LOT_NB)
  AND  (@ITEM_CD IS NULL OR P.ITEM_CD = @ITEM_CD)
  AND  P.PLOT_NB <> N''
ORDER BY 추적상태, P.PLOT_NB, U.USE_QT DESC
;


/*==============================================================================================
  ** 쿼리 C : 리콜 범위 요약  (정방향 결과의 집계)  ★ 경영 보고용
==============================================================================================*/
SELECT
     N'[C] 리콜 범위 요약'                          AS REPORT_NM
    ,추적LOT = ISNULL(@LOT_NB, N'(전체)')
    ,영향_제품LOT수 = COUNT(DISTINCT NULLIF(P.PLOT_NB, N''))
    ,영향_실적건수  = COUNT(DISTINCT P.WR_CD)
    ,생산수량계     = SUM(DISTINCT P.GOOD_QT)
    ,출고건수       = COUNT(DISTINCT D.ISU_NB)
    ,출고수량계     = SUM(ISNULL(D.ISU_QT, 0))
    ,영향_거래처수  = COUNT(DISTINCT H.TR_CD)
    ,최초출고일     = MIN(H.ISU_DT)
    ,최종출고일     = MAX(H.ISU_DT)
    ,미출고_사내재고 = SUM(CASE WHEN D.ISU_NB IS NULL THEN P.GOOD_QT ELSE 0 END)
    ,판정 = CASE
         WHEN COUNT(DISTINCT H.TR_CD) = 0
              THEN N'0.출고 없음 - 사내 재고만 회수하면 된다'
         WHEN COUNT(DISTINCT H.TR_CD) > 10
              THEN N'1.★거래처 10곳 초과 - 대규모 리콜. 공식 대응 절차 가동'
         ELSE N'2.★' + CAST(COUNT(DISTINCT H.TR_CD) AS NVARCHAR(10)) + N'개 거래처 통보 필요' END
FROM       #USE  U
LEFT  JOIN #PRD  P ON P.WR_CD = U.WR_CD
LEFT  JOIN LDELIVER_D D WITH (NOLOCK)
        ON D.CO_CD = @CO_CD AND D.ITEM_CD = P.ITEM_CD
       AND ISNULL(D.LOT_NB, N'') = P.PLOT_NB
       AND ISNULL(D.USE_YN, N'1') = N'1'
LEFT  JOIN LDELIVER H WITH (NOLOCK) ON H.CO_CD = D.CO_CD AND H.ISU_NB = D.ISU_NB
WHERE  @MODE = N'FWD'
  AND  (@LOT_NB  IS NULL OR U.MLOT_NB  = @LOT_NB)
  AND  (@ITEM_CD IS NULL OR U.MITEM_CD = @ITEM_CD)
  AND  U.MLOT_NB <> N''
;


/*==============================================================================================
  ** 쿼리 D : LOT별 재고 잔량  (회수 대상 파악)
==============================================================================================*/
SELECT
     N'[D] LOT별 재고 잔량'                         AS REPORT_NM
    ,V.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.UNIT_CD                                      AS 단위
    ,V.LOT_NB                                       AS LOT번호
    ,V.WH_CD                                        AS 창고코드
    ,W.WH_NM                                        AS 창고명
    ,V.LC_CD                                        AS 장소코드
    ,입고수량 = SUM(CAST(ISNULL(V.IRCV_QT,0) AS DECIMAL(19,6)))
    ,출고수량 = SUM(CAST(ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)))
    ,잔여수량 = SUM(CAST(ISNULL(V.IOPEN_QT,0)+ISNULL(V.IRCV_QT,0)-ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)))
    ,최초입고일 = MIN(CASE WHEN V.IO_FG IN (N'0',N'1') THEN V.IO_DT END)
    ,최종수불일 = MAX(V.IO_DT)
    ,회수가능 = CASE
         WHEN SUM(CAST(ISNULL(V.IOPEN_QT,0)+ISNULL(V.IRCV_QT,0)-ISNULL(V.IISU_QT,0) AS DECIMAL(19,6))) > 0
              THEN N'★ 사내 재고 있음 - 즉시 출고 정지 및 격리'
         ELSE N'전량 소진 - 출고처 추적 필요 (쿼리 A)' END
FROM       LINVTORY V WITH (NOLOCK)
LEFT  JOIN SITEM    I WITH (NOLOCK) ON I.CO_CD = V.CO_CD AND I.ITEM_CD = V.ITEM_CD
LEFT  JOIN SWH      W WITH (NOLOCK) ON W.CO_CD = V.CO_CD AND W.WH_CD   = V.WH_CD
WHERE  V.CO_CD = @CO_CD AND V.P_YR = @P_YR
  AND  ISNULL(V.LOT_NB, N'') <> N''
  AND  ISNULL(V.USE_YN, N'1') = N'1' AND ISNULL(V.EXPIRE_YN, N'1') = N'1'
  AND  (@DIV_CD  IS NULL OR V.DIV_CD  = @DIV_CD)
  AND  (@LOT_NB  IS NULL OR V.LOT_NB  = @LOT_NB)
  AND  (@ITEM_CD IS NULL OR V.ITEM_CD = @ITEM_CD)
GROUP BY V.ITEM_CD, I.ITEM_NM, I.UNIT_CD, V.LOT_NB, V.WH_CD, W.WH_NM, V.LC_CD
ORDER BY 잔여수량 DESC
;


/*==============================================================================================
  ** 쿼리 E : 제품 LOT 출고처 일람  (제품 LOT 을 알 때 바로 고객을 찾는다)
==============================================================================================*/
SELECT
     N'[E] 제품 LOT 출고처'                         AS REPORT_NM
    ,D.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,D.LOT_NB                                       AS 제품LOT
    ,H.ISU_DT                                       AS 출고일
    ,H.ISU_NB                                       AS 출고번호
    ,H.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,D.ISU_QT                                       AS 출고수량
    ,D.ISUH_AM                                      AS 출고금액
    ,D.SO_NB                                        AS 수주번호
    ,H.SO_FG                                        AS 거래구분
    ,경과일 = DATEDIFF(DAY, CONVERT(DATE, H.ISU_DT), GETDATE())
    ,마감여부 = CASE WHEN ISNULL(D.CLS_QT, 0) >= ISNULL(D.ISU_QT, 0) THEN N'마감' ELSE N'미마감' END
FROM       LDELIVER   H WITH (NOLOCK)
INNER JOIN LDELIVER_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.ISU_NB = H.ISU_NB
LEFT  JOIN SITEM      I WITH (NOLOCK) ON I.CO_CD = D.CO_CD AND I.ITEM_CD = D.ITEM_CD
LEFT  JOIN STRADE     T WITH (NOLOCK) ON T.CO_CD = H.CO_CD AND T.TR_CD   = H.TR_CD
WHERE  H.CO_CD  = @CO_CD
  AND  H.ISU_DT BETWEEN @FR_DT AND @TO_DT
  AND  ISNULL(D.LOT_NB, N'') <> N''
  AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
  AND  (@DIV_CD  IS NULL OR H.DIV_CD  = @DIV_CD)
  AND  (@LOT_NB  IS NULL OR D.LOT_NB  = @LOT_NB)
  AND  (@ITEM_CD IS NULL OR D.ITEM_CD = @ITEM_CD)
ORDER BY H.ISU_DT DESC
;


/*==============================================================================================
  ** 쿼리 F : LOT 기록률 점검  ★ 도입 시 가장 먼저 볼 것
     ─ 단계 중 하나라도 LOT 이 비면 추적 사슬이 끊긴다.
==============================================================================================*/
SELECT
     N'[F] 단계별 LOT 기록률'                       AS REPORT_NM
    ,순서, 단계, 테이블, 전체건수, LOT기록건수, 기록률_PCT, 판정
FROM (
    SELECT 순서=1, 단계=N'1.LOT 관리 품목 지정', 테이블=N'SITEM.LOT_FG'
          ,전체건수 = COUNT(*)
          ,LOT기록건수 = SUM(CASE WHEN ISNULL(LOT_FG, N'0') = N'1' THEN 1 ELSE 0 END)
    FROM SITEM WITH (NOLOCK) WHERE CO_CD = @CO_CD AND ISNULL(USE_YN, N'1') = N'1'
    UNION ALL
    SELECT 2, N'2.자재 입고', N'LSTOCK_D.LOT_NB'
          ,COUNT(*), SUM(CASE WHEN ISNULL(D.LOT_NB, N'') <> N'' THEN 1 ELSE 0 END)
    FROM       LSTOCK   H WITH (NOLOCK)
    INNER JOIN LSTOCK_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.RCV_NB = H.RCV_NB
    WHERE  H.CO_CD = @CO_CD AND H.RCV_DT BETWEEN @FR_DT AND @TO_DT
    UNION ALL
    SELECT 3, N'3.자재 투입', N'LMTL_USE.LOT_NB'
          ,COUNT(*), SUM(CASE WHEN MLOT_NB <> N'' THEN 1 ELSE 0 END)
    FROM #USE
    UNION ALL
    SELECT 4, N'4.제품 생산', N'LORCV_H.LOT_NB'
          ,COUNT(*), SUM(CASE WHEN PLOT_NB <> N'' THEN 1 ELSE 0 END)
    FROM #PRD
    UNION ALL
    SELECT 5, N'5.제품 출고', N'LDELIVER_D.LOT_NB'
          ,COUNT(*), SUM(CASE WHEN ISNULL(D.LOT_NB, N'') <> N'' THEN 1 ELSE 0 END)
    FROM       LDELIVER   H WITH (NOLOCK)
    INNER JOIN LDELIVER_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.ISU_NB = H.ISU_NB
    WHERE  H.CO_CD = @CO_CD AND H.ISU_DT BETWEEN @FR_DT AND @TO_DT
) X
CROSS APPLY (SELECT 기록률_PCT = CAST(X.LOT기록건수 * 100.0
                     / NULLIF(X.전체건수, 0) AS DECIMAL(5,1))) R
CROSS APPLY (SELECT 판정 = CASE
                 WHEN X.전체건수 = 0        THEN N'데이터 없음'
                 WHEN R.기록률_PCT >= 90    THEN N'0.양호'
                 WHEN R.기록률_PCT >= 50    THEN N'1.부분 기록 - 추적 결과가 일부만 대표'
                 ELSE N'2.★기록률 50% 미만 - 이 단계에서 추적 사슬이 끊긴다' END) P
ORDER BY X.순서
;

SELECT
     N'[F-2] 추적 가능성 종합'                      AS REPORT_NM
    ,LMTL_USE_존재 = CASE WHEN @HAS_USE = 1 THEN N'O' ELSE N'X' END
    ,추적모드 = CASE @MODE WHEN N'FWD' THEN N'정방향(자재→고객)' ELSE N'역방향(제품→자재)' END
    ,대상LOT = ISNULL(@LOT_NB, N'★미지정 - 전체 조회는 매우 느리다')
    ,자재투입_LOT기록 = (SELECT COUNT(*) FROM #USE WHERE MLOT_NB <> N'')
    ,제품생산_LOT기록 = (SELECT COUNT(*) FROM #PRD WHERE PLOT_NB <> N'')
    ,판정 = CASE
         WHEN @HAS_USE = 0
              THEN N'1.★LMTL_USE 없음 - 자재 투입 추적 불가. 지시 단위(M-05)로만 가능'
         WHEN (SELECT COUNT(*) FROM #USE WHERE MLOT_NB <> N'') = 0
              THEN N'2.★자재 투입에 LOT 기록 없음 - 역방향 추적 불가'
         WHEN (SELECT COUNT(*) FROM #PRD WHERE PLOT_NB <> N'') = 0
              THEN N'3.★제품 생산에 LOT 기록 없음 - 정방향 추적이 제품에서 끊긴다'
         WHEN @LOT_NB IS NULL
              THEN N'4.대상 LOT 미지정 - @LOT_NB 를 지정해 실행할 것'
         ELSE N'0.추적 가능' END
;


DROP TABLE #USE, #PRD;
GO


/*==============================================================================================
  [ 사용법 ]
  ----------------------------------------------------------------------------------------------
  [ 품질 사고 발생 시 ]
   ① 쿼리 F 실행 → LOT 기록률 확인 (추적이 성립하는지)
   ② 원자재 문제면  : @MODE='FWD', @LOT_NB=자재LOT → 쿼리 A·C 로 리콜 범위 확정
      제품 문제면    : @MODE='BWD', @LOT_NB=제품LOT → 쿼리 B 로 원인 자재·공급처 규명
   ③ 쿼리 D 로 사내 잔여 재고 격리
   ④ 쿼리 C 의 거래처 목록으로 고객 통보

  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) LOT 관리 품목 비중  ★ 추적 대상 규모
     SELECT LOT_FG, COUNT(*) FROM SITEM WHERE CO_CD='1000' GROUP BY LOT_FG;

  -- (2) LOT 컬럼 실존  ★ 각 단계에 LOT_NB 가 있는지
     SELECT t.name AS 테이블, c.name AS 컬럼 FROM sys.columns c
     INNER JOIN sys.tables t ON t.object_id = c.object_id
     WHERE c.name LIKE '%LOT%'
       AND t.name IN ('LSTOCK_D','LMTL_USE','LORCV_H','LDELIVER_D','LINVTORY','LPRDINWH');
     --> 어느 하나라도 없으면 그 단계에서 사슬이 끊긴다.

  -- (3) 자재 사용보고 운영  ★ LMTL_USE 가 추적의 중심축이다
     SELECT COUNT(*) 전체, SUM(CASE WHEN ISNULL(LOT_NB,'')='' THEN 1 ELSE 0 END) LOT없음
     FROM   LMTL_USE WHERE CO_CD='1000';

  -- (4) 제품 LOT 채번 규칙 확인
     SELECT TOP 20 LOT_NB, COUNT(*) FROM LORCV_H
     WHERE CO_CD='1000' AND ISNULL(LOT_NB,'')<>'' GROUP BY LOT_NB ORDER BY 2 DESC;
     --> LOT 이 일자 단위인지 지시 단위인지에 따라 추적 정밀도가 달라진다.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **출고 LOT 매칭이 품번+LOT 기준**이다. `LDELIVER_D` 에 실적번호(WR_CD)가 없어
     "이 실적에서 나온 물건이 저 출고"라고 직접 잇지 못하고, 같은 품번·같은 LOT 이면
     동일하다고 본다. LOT 채번이 느슨하면(예: 일자 단위) 실제보다 넓게 잡힐 수 있다.
     **리콜 범위는 넓게 잡히는 편이 안전하므로 이 방향의 오차는 허용 가능**하다고 보았다.

  2) **반제품을 거치는 다단 생산은 한 단계만 추적**한다. 원자재 → 반제품 → 제품 구조에서는
     쿼리 A 를 반제품 LOT 으로 한 번 더 실행해야 최종 제품까지 닿는다.
     자동 다단 전개는 LOT 계보 테이블이 없으면 구현할 수 없다.

  3) **LOT 미관리 품목은 추적에서 빠진다.** 쿼리 F 의 기록률이 낮으면 추적 결과는
     "전부"가 아니라 "기록된 것 중 일부"다. 이 점을 보고서에 반드시 명시할 것.

  4) `@LOT_NB` 없이 전체 조회하면 매우 느리다. 실무에서는 항상 특정 LOT 을 지정해 쓴다.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   P03_실시간재고_추적.sql        : 쿼리 C — LOT별 재고 (격리 대상 확인)
   M06_불량파레토_품질KPI.sql     : 불량 원인 분석
   M05_자재_청구출고사용_현황.sql : 지시 단위 자재 추적 (LOT 없을 때의 대안)
==============================================================================================*/
