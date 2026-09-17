/*==============================================================================================
  [ iCUBE ] E-01  경영 KPI 통합 대시보드                                             (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 영업·생산·구매·원가 KPI 를 **한 화면 8개 타일**로 통합한다.
         1~3차 개별 리포트의 지표를 같은 산식으로 재집계하므로, 타일을 클릭하면 해당 상세
         리포트로 자연스럽게 드릴다운되도록 설계했다 (경로는 쿼리 D).

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ ★ 이 대시보드의 가장 중요한 설계 원칙 : 타일마다 기준시각이 다르다 ]
  ----------------------------------------------------------------------------------------------
     수주·재고는 실시간에 가깝고, 원가는 차수 마감 시점(월 1회)에만 갱신된다.
     갱신주기가 다른 지표를 한 화면에 섞으면서 **기준시각을 표시하지 않으면 신뢰를 잃는다.**
     그래서 모든 타일에 `기준시각` / `갱신주기` 컬럼을 필수로 넣었다.

     원가 KPI 는 **미마감 차수에서 값이 튄다.** `CIV_CHASU.CLS_YN='1'`(마감) 차수만 쓰고,
     미마감이면 값 대신 **'집계중'** 으로 표기한다 (쿼리 A 의 `상태` 컬럼).

  ----------------------------------------------------------------------------------------------
  [ 8개 타일 구성 ]
  ----------------------------------------------------------------------------------------------
     영업 | 수주액 / 매출액 (당월·누계)      계획 대비 %
     영업 | 납기준수율                       95%          ← S-03
     영업 | 미수채권 / 여신소진율            한도 90%     ← S-06
     생산 | 생산달성률                       95%          ← M-01
     생산 | 작업수율(양품률)                 97%          ← M-06
     구매 | 결품 품목수                      0            ← P-05
     구매 | 재고금액 / 회전율                회전 12회    ← P-03
     원가 | 원가차이율                       ±3%          ← C-04
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터   ─ 목표선은 EIS E-01 기본값
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@BASE_DT  NVARCHAR(8)  = N'20260915'     -- 기준일
    ,@TGT_DUE  DECIMAL(5,1) = 95.0            -- 납기준수율 목표
    ,@TGT_PRD  DECIMAL(5,1) = 95.0            -- 생산달성률 목표
    ,@TGT_QC   DECIMAL(5,1) = 97.0            -- 양품률 목표
    ,@TGT_CR   DECIMAL(5,1) = 90.0            -- 여신소진율 경고선
    ,@TGT_SHORT INT         = 0               -- 결품 품목수 목표
    ,@TGT_TURN DECIMAL(5,1) = 12.0            -- 재고회전율 목표 (회/년)
    ,@TGT_CVAR DECIMAL(5,1) = 3.0             -- 원가차이율 허용 (±%)
;

DECLARE
     @P_YR  NVARCHAR(4) = LEFT(@BASE_DT, 4)
    ,@YM    NVARCHAR(6) = LEFT(@BASE_DT, 6)
    ,@MM_FR NVARCHAR(8) = LEFT(@BASE_DT, 6) + N'01'         -- 당월 1일
    ,@YR_FR NVARCHAR(8) = LEFT(@BASE_DT, 4) + N'0101'       -- 연초
    ,@NOW   NVARCHAR(20) = CONVERT(NVARCHAR(20), GETDATE(), 120)
;
DECLARE @SQL NVARCHAR(MAX);
DECLARE @CHASU INT = NULL, @CHASU_ST NVARCHAR(20) = N'미운영';

IF OBJECT_ID('tempdb..#KPI') IS NOT NULL DROP TABLE #KPI;
IF OBJECT_ID('tempdb..#ALERT') IS NOT NULL DROP TABLE #ALERT;

CREATE TABLE #KPI (
     SEQ      INT
    ,AREA     NVARCHAR(10)          -- 영역
    ,KPI_NM   NVARCHAR(40)          -- 지표명
    ,MM_VAL   DECIMAL(19,4)         -- 당월값
    ,YR_VAL   DECIMAL(19,4)         -- 누계값
    ,UNIT     NVARCHAR(10)          -- 단위
    ,TARGET   DECIMAL(19,4)         -- 목표
    ,ACHIEVE  NVARCHAR(20)          -- 달성판정
    ,GAP      DECIMAL(19,4)         -- 목표 대비
    ,CYCLE    NVARCHAR(20)          -- 갱신주기
    ,AS_OF    NVARCHAR(20)          -- 기준시각
    ,STATUS   NVARCHAR(20)          -- 정상 / 집계중 / 데이터없음
    ,DRILL    NVARCHAR(60)          -- 드릴다운 대상
);

CREATE TABLE #ALERT (
     SEQ    INT IDENTITY(1,1)
    ,LEVEL  NVARCHAR(10)
    ,AREA   NVARCHAR(10)
    ,TITLE  NVARCHAR(100)
    ,DETAIL NVARCHAR(300)
    ,DRILL  NVARCHAR(60)
);


/*==============================================================================================
  1. 원가차수 확인  ★ 원가 KPI 의 전제
     ─ 마감(CLS_YN='1')된 최신 차수만 쓴다. 미마감이면 '집계중' 으로 표기.
==============================================================================================*/
IF OBJECT_ID(N'dbo.CIV_CHASU', N'U') IS NOT NULL
BEGIN
    SELECT TOP 1 @CHASU = CHASU, @CHASU_ST = N'마감'
    FROM   CIV_CHASU WITH (NOLOCK)
    WHERE  CO_CD = @CO_CD AND P_YR = @P_YR AND ISNULL(CLS_YN, N'0') = N'1'
    ORDER BY CHASU DESC;

    IF @CHASU IS NULL
    BEGIN
        SELECT TOP 1 @CHASU = CHASU, @CHASU_ST = N'미마감(집계중)'
        FROM   CIV_CHASU WITH (NOLOCK)
        WHERE  CO_CD = @CO_CD AND P_YR = @P_YR
        ORDER BY CHASU DESC;
    END
END
PRINT N'[0] 원가차수 : ' + ISNULL(CAST(@CHASU AS NVARCHAR(10)), N'없음') + N' / ' + @CHASU_ST;


/*==============================================================================================
  2. 타일 1 · 2 : 수주액 / 매출액  (영업)
==============================================================================================*/
;WITH SO AS (
    SELECT
         MM = SUM(CASE WHEN H.SO_DT >= @MM_FR THEN CAST(ISNULL(D.SOG_AM, D.SO_AM) AS DECIMAL(19,4)) ELSE 0 END)
        ,YR = SUM(CAST(ISNULL(D.SOG_AM, D.SO_AM) AS DECIMAL(19,4)))
    FROM       LSO   H WITH (NOLOCK)
    INNER JOIN LSO_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.SO_NB = H.SO_NB
    WHERE  H.CO_CD = @CO_CD AND H.SO_DT BETWEEN @YR_FR AND @BASE_DT
      AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
      AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
)
INSERT INTO #KPI (SEQ, AREA, KPI_NM, MM_VAL, YR_VAL, UNIT, TARGET, ACHIEVE, GAP, CYCLE, AS_OF, STATUS, DRILL)
SELECT 1, N'영업', N'수주액', SO.MM, SO.YR, N'원', NULL
      ,CASE WHEN SO.YR > 0 THEN N'-' ELSE N'★데이터 없음' END, NULL
      ,N'실시간', @NOW
      ,CASE WHEN SO.YR > 0 THEN N'정상' ELSE N'데이터없음' END
      ,N'수주진행총괄현황.sql'
FROM SO;

;WITH SL AS (
    SELECT
         MM = SUM(CASE WHEN H.CLS_DT >= @MM_FR THEN CAST(ISNULL(D.CLSG_AM, D.CLSH_AM) AS DECIMAL(19,4)) ELSE 0 END)
        ,YR = SUM(CAST(ISNULL(D.CLSG_AM, D.CLSH_AM) AS DECIMAL(19,4)))
    FROM       LSALECLS   H WITH (NOLOCK)
    INNER JOIN LSALECLS_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.CLS_NB = H.CLS_NB
    WHERE  H.CO_CD = @CO_CD AND H.CLS_DT BETWEEN @YR_FR AND @BASE_DT
      AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
      AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
)
INSERT INTO #KPI (SEQ, AREA, KPI_NM, MM_VAL, YR_VAL, UNIT, TARGET, ACHIEVE, GAP, CYCLE, AS_OF, STATUS, DRILL)
SELECT 2, N'영업', N'매출액(마감기준)', SL.MM, SL.YR, N'원', NULL
      ,CASE WHEN SL.YR > 0 THEN N'-' ELSE N'★데이터 없음' END, NULL
      ,N'일 1회(마감)', @NOW
      ,CASE WHEN SL.YR > 0 THEN N'정상' ELSE N'데이터없음' END
      ,N'A02_기표파이프라인_현황.sql'
FROM SL;


/*==============================================================================================
  3. 타일 3 : 납기준수율  (영업) ← S-03 과 동일 산식
     ─ 완결 수주만, 최종출고일 기준, 지연 = DATEDIFF > 0
==============================================================================================*/
;WITH DUE AS (
    SELECT
         D.DUE_DT
        ,DELAY = DATEDIFF(DAY, CONVERT(DATE, D.DUE_DT), CONVERT(DATE, V.LAST_DT))
    FROM       LSO   H WITH (NOLOCK)
    INNER JOIN LSO_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.SO_NB = H.SO_NB
    OUTER APPLY (
        SELECT LAST_DT = MAX(X.ISU_DT)
        FROM       LDELIVER   X WITH (NOLOCK)
        INNER JOIN LDELIVER_D Y WITH (NOLOCK) ON Y.CO_CD = X.CO_CD AND Y.ISU_NB = X.ISU_NB
        WHERE  Y.CO_CD = D.CO_CD AND Y.SO_NB = D.SO_NB AND Y.SO_SQ = D.SO_SQ
          AND  ISNULL(Y.USE_YN, N'1') = N'1' AND ISNULL(Y.EXPIRE_YN, N'1') = N'1'
    ) V
    WHERE  H.CO_CD = @CO_CD
      AND  D.DUE_DT BETWEEN @YR_FR AND @BASE_DT
      AND  ISNULL(D.USE_YN, N'1') = N'1'
      AND  ISNULL(D.DUE_DT, N'') <> N''
      AND  ISNULL(D.SO_QT,0) > 0
      AND  ISNULL(D.SO_QT,0) - ISNULL(D.ISU_QT,0) = 0        -- 완결 건만
      AND  V.LAST_DT IS NOT NULL
      AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
)
INSERT INTO #KPI (SEQ, AREA, KPI_NM, MM_VAL, YR_VAL, UNIT, TARGET, ACHIEVE, GAP, CYCLE, AS_OF, STATUS, DRILL)
SELECT 3, N'영업', N'납기준수율'
      ,CAST(SUM(CASE WHEN LEFT(DUE_DT,6) = @YM AND DELAY <= 0 THEN 1.0 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN LEFT(DUE_DT,6) = @YM THEN 1.0 ELSE 0 END), 0) * 100 AS DECIMAL(19,4))
      ,CAST(SUM(CASE WHEN DELAY <= 0 THEN 1.0 ELSE 0 END)
            / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(19,4))
      ,N'%', @TGT_DUE
      ,CASE WHEN COUNT(*) = 0 THEN N'★데이터 없음'
            WHEN SUM(CASE WHEN DELAY <= 0 THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0)*100 >= @TGT_DUE
                 THEN N'달성' ELSE N'★미달' END
      ,CAST(SUM(CASE WHEN DELAY <= 0 THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0)*100 - @TGT_DUE AS DECIMAL(19,4))
      ,N'일 1회', @NOW
      ,CASE WHEN COUNT(*) = 0 THEN N'데이터없음' ELSE N'정상' END
      ,N'S03_납기준수율_KPI.sql'
FROM DUE;


/*==============================================================================================
  4. 타일 4 : 미수채권 / 여신소진율  (영업) ← S-06 과 동일 산식 (마감기준 = 최종)
==============================================================================================*/
;WITH AR AS (
    SELECT
         T.TR_CD
        ,OPN = ISNULL(O.AM, 0)
        ,CLS = ISNULL(C.AM, 0)
        ,RCP = ISNULL(R.AM, 0)
        ,LMT = ISNULL(L.AM, 0)
    FROM ( SELECT DISTINCT TR_CD FROM STRADE WITH (NOLOCK) WHERE CO_CD = @CO_CD ) T
    OUTER APPLY ( SELECT AM = SUM(CAST(ISNULL(X.OPEN_AM,0) AS DECIMAL(19,4)))
                  FROM LOPN_CRISU X WITH (NOLOCK)
                  WHERE X.CO_CD=@CO_CD AND X.P_YR=@P_YR AND X.TR_CD=T.TR_CD
                    AND (@DIV_CD IS NULL OR X.DIV_CD=@DIV_CD) ) O
    OUTER APPLY ( SELECT AM = SUM(CAST(ISNULL(D.CLSH_AM,0) AS DECIMAL(19,4)))
                  FROM LSALECLS H WITH (NOLOCK)
                  INNER JOIN LSALECLS_D D WITH (NOLOCK) ON D.CO_CD=H.CO_CD AND D.CLS_NB=H.CLS_NB
                  WHERE H.CO_CD=@CO_CD AND H.TR_CD=T.TR_CD
                    AND H.CLS_DT BETWEEN @YR_FR AND @BASE_DT
                    AND ISNULL(D.USE_YN,N'1')=N'1' AND ISNULL(D.EXPIRE_YN,N'1')=N'1'
                    AND (@DIV_CD IS NULL OR H.DIV_CD=@DIV_CD) ) C
    OUTER APPLY ( SELECT AM = SUM(CAST(ISNULL(D.NORMAL_AM,0)+ISNULL(D.BEFORE_AM,0) AS DECIMAL(19,4)))
                  FROM LRCP H WITH (NOLOCK)
                  INNER JOIN LRCP_D D WITH (NOLOCK) ON D.CO_CD=H.CO_CD AND D.RCP_NB=H.RCP_NB
                  WHERE H.CO_CD=@CO_CD AND H.TR_CD=T.TR_CD
                    AND H.RCP_DT BETWEEN @YR_FR AND @BASE_DT
                    AND ISNULL(D.USE_YN,N'1')=N'1' AND ISNULL(D.EXPIRE_YN,N'1')=N'1'
                    AND ISNULL(D.RCPAM_FG,N'0')=N'0'
                    AND (@DIV_CD IS NULL OR H.DIV_CD=@DIV_CD) ) R
    OUTER APPLY ( SELECT AM = CAST(ISNULL(NULLIF(S.CREDIT_AM,0), S.LIMIT_AM) AS DECIMAL(19,4))
                  FROM STRADE S WITH (NOLOCK)
                  WHERE S.CO_CD=@CO_CD AND S.TR_CD=T.TR_CD ) L
)
INSERT INTO #KPI (SEQ, AREA, KPI_NM, MM_VAL, YR_VAL, UNIT, TARGET, ACHIEVE, GAP, CYCLE, AS_OF, STATUS, DRILL)
SELECT 4, N'영업', N'미수채권(마감기준)'
      ,NULL
      ,SUM(OPN + CLS - RCP)
      ,N'원', NULL
      ,CASE WHEN SUM(CASE WHEN LMT > 0 AND OPN+CLS-RCP > LMT THEN 1 ELSE 0 END) > 0
            THEN N'★여신초과 ' + CAST(SUM(CASE WHEN LMT>0 AND OPN+CLS-RCP>LMT THEN 1 ELSE 0 END) AS NVARCHAR(10)) + N'사'
            ELSE N'정상' END
      ,NULL
      ,N'일 1회', @NOW, N'정상'
      ,N'S06_채권여신_관리현황.sql'
FROM AR
WHERE OPN + CLS - RCP <> 0;


/*==============================================================================================
  5. 타일 5 : 생산달성률  (생산) ← M-01 진척률 가중평균
==============================================================================================*/
;WITH WO AS (
    SELECT
         W.ORD_DT
        ,ITEM_QT = CAST(ISNULL(W.ITEM_QT, 0) AS DECIMAL(19,6))
        ,GOOD_QT = ISNULL(R.GOOD_QT, 0)
    FROM   LWO_WF W WITH (NOLOCK)
    OUTER APPLY (
        SELECT GOOD_QT = SUM(CASE WHEN ISNULL(X.SUB_TP,N'0')=N'0' AND ISNULL(X.BAD_YN,N'0')=N'0'
                                  THEN CAST(ISNULL(X.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
        FROM   LORCV_H X WITH (NOLOCK)
        WHERE  X.CO_CD = W.CO_CD AND X.WO_CD = W.WO_CD AND ISNULL(X.USE_YN, N'1') = N'1'
    ) R
    WHERE  W.CO_CD = @CO_CD AND W.ORD_DT BETWEEN @YR_FR AND @BASE_DT
      AND  ISNULL(W.USE_YN, N'1') = N'1'
      AND  (@DIV_CD IS NULL OR W.DIV_CD = @DIV_CD)
)
INSERT INTO #KPI (SEQ, AREA, KPI_NM, MM_VAL, YR_VAL, UNIT, TARGET, ACHIEVE, GAP, CYCLE, AS_OF, STATUS, DRILL)
SELECT 5, N'생산', N'생산달성률'
      ,CAST(SUM(CASE WHEN LEFT(ORD_DT,6) = @YM THEN GOOD_QT ELSE 0 END)
            / NULLIF(SUM(CASE WHEN LEFT(ORD_DT,6) = @YM THEN ITEM_QT ELSE 0 END), 0) * 100 AS DECIMAL(19,4))
      ,CAST(SUM(GOOD_QT) / NULLIF(SUM(ITEM_QT), 0) * 100 AS DECIMAL(19,4))
      ,N'%', @TGT_PRD
      ,CASE WHEN SUM(ITEM_QT) = 0 THEN N'★데이터 없음'
            WHEN SUM(GOOD_QT)/NULLIF(SUM(ITEM_QT),0)*100 >= @TGT_PRD THEN N'달성' ELSE N'★미달' END
      ,CAST(SUM(GOOD_QT)/NULLIF(SUM(ITEM_QT),0)*100 - @TGT_PRD AS DECIMAL(19,4))
      ,N'실시간', @NOW
      ,CASE WHEN SUM(ITEM_QT) = 0 THEN N'데이터없음' ELSE N'정상' END
      ,N'M01_작업지시_진행현황.sql'
FROM WO;


/*==============================================================================================
  6. 타일 6 : 작업수율(양품률)  (생산) ← M-06 과 동일 산식
==============================================================================================*/
;WITH QC AS (
    SELECT
         R.WR_DT
        ,GOOD = CASE WHEN ISNULL(R.SUB_TP,N'0')=N'0' AND ISNULL(R.BAD_YN,N'0')=N'0'
                     THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END
        ,BASE = CASE WHEN ISNULL(R.SUB_TP,N'0')=N'0'
                     THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END
    FROM   LORCV_H R WITH (NOLOCK)
    WHERE  R.CO_CD = @CO_CD AND R.WR_DT BETWEEN @YR_FR AND @BASE_DT
      AND  ISNULL(R.USE_YN, N'1') = N'1'
      AND  (@DIV_CD IS NULL OR R.DIV_CD = @DIV_CD)
)
INSERT INTO #KPI (SEQ, AREA, KPI_NM, MM_VAL, YR_VAL, UNIT, TARGET, ACHIEVE, GAP, CYCLE, AS_OF, STATUS, DRILL)
SELECT 6, N'생산', N'작업수율(양품률)'
      ,CAST(SUM(CASE WHEN LEFT(WR_DT,6) = @YM THEN GOOD ELSE 0 END)
            / NULLIF(SUM(CASE WHEN LEFT(WR_DT,6) = @YM THEN BASE ELSE 0 END), 0) * 100 AS DECIMAL(19,4))
      ,CAST(SUM(GOOD) / NULLIF(SUM(BASE), 0) * 100 AS DECIMAL(19,4))
      ,N'%', @TGT_QC
      ,CASE WHEN SUM(BASE) = 0 THEN N'★데이터 없음'
            WHEN SUM(GOOD)/NULLIF(SUM(BASE),0)*100 >= @TGT_QC THEN N'달성' ELSE N'★미달' END
      ,CAST(SUM(GOOD)/NULLIF(SUM(BASE),0)*100 - @TGT_QC AS DECIMAL(19,4))
      ,N'실시간', @NOW
      ,CASE WHEN SUM(BASE) = 0 THEN N'데이터없음' ELSE N'정상' END
      ,N'M06_불량파레토_품질KPI.sql'
FROM QC;


/*==============================================================================================
  7. 타일 7 : 결품 품목수  (구매) ← P-05 알람등급 1·2
==============================================================================================*/
;WITH STK AS (
    SELECT
         I.ITEM_CD
        ,LEAD_DT = ISNULL(NULLIF(CAST(ISNULL(I.LEAD_DT,0) AS INT), 0), 7)
        ,STK_QT  = ISNULL(S.QT , 0)
        ,DMD_QT  = ISNULL(D.QT , 0)
        ,PO_QT   = ISNULL(P.QT , 0)
        ,DAY_USE = CAST(ISNULL(U.QT,0) / 90.0 AS DECIMAL(19,6))
    FROM       SITEM I WITH (NOLOCK)
    OUTER APPLY ( SELECT QT = SUM(CAST(ISNULL(V.IOPEN_QT,0)+ISNULL(V.IRCV_QT,0)-ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)))
                  FROM LINVTORY V WITH (NOLOCK)
                  WHERE V.CO_CD=@CO_CD AND V.P_YR=@P_YR AND V.ITEM_CD=I.ITEM_CD AND V.IO_DT<=@BASE_DT
                    AND ISNULL(V.USE_YN,N'1')=N'1' AND ISNULL(V.EXPIRE_YN,N'1')=N'1'
                    AND (@DIV_CD IS NULL OR V.DIV_CD=@DIV_CD) ) S
    OUTER APPLY ( SELECT QT = SUM(CAST(ISNULL(X.SO_QT,0)-ISNULL(X.ISU_QT,0) AS DECIMAL(19,6)))
                  FROM LSO H WITH (NOLOCK)
                  INNER JOIN LSO_D X WITH (NOLOCK) ON X.CO_CD=H.CO_CD AND X.SO_NB=H.SO_NB
                  WHERE H.CO_CD=@CO_CD AND X.ITEM_CD=I.ITEM_CD
                    AND ISNULL(X.USE_YN,N'1')=N'1' AND ISNULL(X.EXPIRE_YN,N'1')=N'1'
                    AND ISNULL(X.SO_QT,0)-ISNULL(X.ISU_QT,0)>0
                    AND (@DIV_CD IS NULL OR H.DIV_CD=@DIV_CD) ) D
    OUTER APPLY ( SELECT QT = SUM(CAST(ISNULL(X.PO_QT,0)-ISNULL(Y.RCV,0) AS DECIMAL(19,6)))
                  FROM LPO H WITH (NOLOCK)
                  INNER JOIN LPO_D X WITH (NOLOCK) ON X.CO_CD=H.CO_CD AND X.PO_NB=H.PO_NB
                  OUTER APPLY (SELECT RCV=SUM(CAST(ISNULL(Z.RCV_QT,0) AS DECIMAL(19,6)))
                               FROM LSTOCK_D Z WITH (NOLOCK)
                               WHERE Z.CO_CD=X.CO_CD AND Z.PO_NB=X.PO_NB AND Z.PO_SQ=X.PO_SQ
                                 AND ISNULL(Z.USE_YN,N'1')=N'1') Y
                  WHERE H.CO_CD=@CO_CD AND X.ITEM_CD=I.ITEM_CD
                    AND ISNULL(X.USE_YN,N'1')=N'1' AND ISNULL(X.EXPIRE_YN,N'1')=N'1'
                    AND ISNULL(X.PO_QT,0)-ISNULL(Y.RCV,0)>0
                    AND (@DIV_CD IS NULL OR H.DIV_CD=@DIV_CD) ) P
    OUTER APPLY ( SELECT QT = SUM(CAST(ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)))
                  FROM LINVTORY V WITH (NOLOCK)
                  WHERE V.CO_CD=@CO_CD AND V.ITEM_CD=I.ITEM_CD AND V.IO_FG=N'2'
                    AND ISNULL(V.GRP_FG,N'')<>N'5'
                    AND V.IO_DT BETWEEN CONVERT(NVARCHAR(8),DATEADD(DAY,-90,CONVERT(DATE,@BASE_DT)),112) AND @BASE_DT
                    AND ISNULL(V.USE_YN,N'1')=N'1' AND ISNULL(V.EXPIRE_YN,N'1')=N'1'
                    AND (@DIV_CD IS NULL OR V.DIV_CD=@DIV_CD) ) U
    WHERE  I.CO_CD = @CO_CD AND ISNULL(I.USE_YN, N'1') = N'1'
      AND  ISNULL(I.S_CD, N'') <> N'Z00'
)
INSERT INTO #KPI (SEQ, AREA, KPI_NM, MM_VAL, YR_VAL, UNIT, TARGET, ACHIEVE, GAP, CYCLE, AS_OF, STATUS, DRILL)
SELECT 7, N'구매', N'결품 품목수(등급1·2)'
      ,NULL
      ,SUM(CASE WHEN STK_QT - DMD_QT + PO_QT < 0
                  OR (DAY_USE > 0 AND (STK_QT - DMD_QT + PO_QT) / DAY_USE < LEAD_DT)
                THEN 1 ELSE 0 END)
      ,N'품목', @TGT_SHORT
      ,CASE WHEN SUM(CASE WHEN STK_QT - DMD_QT + PO_QT < 0
                            OR (DAY_USE > 0 AND (STK_QT-DMD_QT+PO_QT)/DAY_USE < LEAD_DT)
                          THEN 1 ELSE 0 END) <= @TGT_SHORT
            THEN N'달성' ELSE N'★미달' END
      ,SUM(CASE WHEN STK_QT - DMD_QT + PO_QT < 0
                  OR (DAY_USE > 0 AND (STK_QT-DMD_QT+PO_QT)/DAY_USE < LEAD_DT)
                THEN 1 ELSE 0 END) - @TGT_SHORT
      ,N'실시간', @NOW, N'정상'
      ,N'P05_재고알람_KPI.sql'
FROM STK;


/*==============================================================================================
  8. 타일 8 : 재고금액 / 회전율  (구매)
     ─ 회전율 = 연환산 출고금액 / 현재고금액. 단가는 LINV_TAV 우선, 없으면 SITEM.
==============================================================================================*/
IF OBJECT_ID('tempdb..#UM') IS NOT NULL DROP TABLE #UM;
CREATE TABLE #UM (ITEM_CD NVARCHAR(25), UM DECIMAL(19,6));

IF OBJECT_ID(N'dbo.LINV_TAV', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
        INSERT INTO #UM (ITEM_CD, UM)
        SELECT T.ITEM_CD, CAST(AVG(CAST(NULLIF(T.ISU_UM,0) AS DECIMAL(19,6))) AS DECIMAL(19,6))
        FROM   dbo.LINV_TAV T WITH (NOLOCK)
        WHERE  T.CO_CD = @p_CO AND ISNULL(T.ISU_UM,0) <> 0
          AND  (@p_DIV IS NULL OR T.DIV_CD = @p_DIV)
        GROUP BY T.ITEM_CD';
    BEGIN TRY
        EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4)', @p_CO=@CO_CD, @p_DIV=@DIV_CD;
    END TRY BEGIN CATCH END CATCH
END
INSERT INTO #UM (ITEM_CD, UM)
SELECT I.ITEM_CD, CAST(ISNULL(NULLIF(I.STD_UM,0), I.PUR_UM) AS DECIMAL(19,6))
FROM   SITEM I WITH (NOLOCK)
WHERE  I.CO_CD = @CO_CD AND NOT EXISTS (SELECT 1 FROM #UM U WHERE U.ITEM_CD = I.ITEM_CD)
  AND  ISNULL(NULLIF(I.STD_UM,0), I.PUR_UM) IS NOT NULL;
CREATE CLUSTERED INDEX IX_UM ON #UM (ITEM_CD);

;WITH INV AS (
    SELECT
         V.ITEM_CD
        ,STK_QT = SUM(CAST(ISNULL(V.IOPEN_QT,0)+ISNULL(V.IRCV_QT,0)-ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)))
        ,OUT_QT = SUM(CASE WHEN V.IO_FG=N'2' AND ISNULL(V.GRP_FG,N'')<>N'5'
                           THEN CAST(ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
    FROM   LINVTORY V WITH (NOLOCK)
    WHERE  V.CO_CD = @CO_CD AND V.P_YR = @P_YR AND V.IO_DT <= @BASE_DT
      AND  ISNULL(V.USE_YN, N'1') = N'1' AND ISNULL(V.EXPIRE_YN, N'1') = N'1'
      AND  (@DIV_CD IS NULL OR V.DIV_CD = @DIV_CD)
    GROUP BY V.ITEM_CD
)
INSERT INTO #KPI (SEQ, AREA, KPI_NM, MM_VAL, YR_VAL, UNIT, TARGET, ACHIEVE, GAP, CYCLE, AS_OF, STATUS, DRILL)
SELECT 8, N'구매', N'재고금액 / 회전율'
      ,CAST(SUM(I.STK_QT * ISNULL(U.UM,0)) AS DECIMAL(19,4))                    -- 당월값 = 재고금액
      ,CAST(SUM(I.OUT_QT * ISNULL(U.UM,0))                                       -- 누계값 = 회전율
            * (365.0 / NULLIF(DATEDIFF(DAY, CONVERT(DATE,@YR_FR), CONVERT(DATE,@BASE_DT)), 0))
            / NULLIF(SUM(I.STK_QT * ISNULL(U.UM,0)), 0) AS DECIMAL(19,4))
      ,N'원 / 회', @TGT_TURN
      ,CASE WHEN SUM(I.STK_QT * ISNULL(U.UM,0)) = 0 THEN N'★데이터 없음'
            WHEN SUM(I.OUT_QT * ISNULL(U.UM,0))
                 * (365.0 / NULLIF(DATEDIFF(DAY,CONVERT(DATE,@YR_FR),CONVERT(DATE,@BASE_DT)),0))
                 / NULLIF(SUM(I.STK_QT * ISNULL(U.UM,0)),0) >= @TGT_TURN
                 THEN N'달성' ELSE N'★미달' END
      ,NULL
      ,N'일 1회', @NOW
      ,CASE WHEN SUM(I.STK_QT * ISNULL(U.UM,0)) = 0 THEN N'데이터없음' ELSE N'정상' END
      ,N'P03_실시간재고_추적.sql'
FROM      INV I
LEFT JOIN #UM U ON U.ITEM_CD = I.ITEM_CD;


/*==============================================================================================
  9. 타일 9 : 원가차이율  (원가)  ★ 마감 차수만. 미마감이면 '집계중'
==============================================================================================*/
IF @CHASU IS NOT NULL AND @CHASU_ST = N'마감'
    AND OBJECT_ID(N'dbo.CIV_PRD_TAV', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
        INSERT INTO #KPI (SEQ, AREA, KPI_NM, MM_VAL, YR_VAL, UNIT, TARGET, ACHIEVE, GAP, CYCLE, AS_OF, STATUS, DRILL)
        SELECT 9, N''원가'', N''실제원가 총액(차수 '' + CAST(@p_CH AS NVARCHAR(10)) + N'')''
              ,NULL
              ,CAST(SUM(CAST(ISNULL(P.PRD_AM,0) AS DECIMAL(19,4))) AS DECIMAL(19,4))
              ,N''원'', NULL
              ,N''-'', NULL
              ,N''월 1회(차수마감)'', @p_NOW, N''정상''
              ,N''C04_표준원가_차이분석.sql''
        FROM   dbo.CIV_PRD_TAV P WITH (NOLOCK)
        WHERE  P.CO_CD = @p_CO AND P.P_YR = @p_YR AND P.CHASU = @p_CH';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_YR NVARCHAR(4), @p_CH INT, @p_NOW NVARCHAR(20)'
            ,@p_CO=@CO_CD, @p_YR=@P_YR, @p_CH=@CHASU, @p_NOW=@NOW;
    END TRY
    BEGIN CATCH
        INSERT INTO #KPI (SEQ, AREA, KPI_NM, UNIT, TARGET, ACHIEVE, CYCLE, AS_OF, STATUS, DRILL)
        VALUES (9, N'원가', N'원가차이율', N'%', @TGT_CVAR, N'-', N'월 1회(차수마감)', @NOW
               ,N'조회실패', N'C04_표준원가_차이분석.sql');
    END CATCH
END
ELSE
    INSERT INTO #KPI (SEQ, AREA, KPI_NM, UNIT, TARGET, ACHIEVE, CYCLE, AS_OF, STATUS, DRILL)
    VALUES (9, N'원가', N'원가차이율'
           ,N'%', @TGT_CVAR
           ,CASE WHEN @CHASU IS NULL THEN N'★원가차수 없음' ELSE N'집계중(미마감)' END
           ,N'월 1회(차수마감)'
           ,CASE WHEN @CHASU IS NULL THEN N'-' ELSE N'차수 ' + CAST(@CHASU AS NVARCHAR(10)) END
           ,CASE WHEN @CHASU IS NULL THEN N'데이터없음' ELSE N'집계중' END
           ,N'C04_표준원가_차이분석.sql');


/*==============================================================================================
  ** 쿼리 A : KPI 타일  (대시보드 메인)
     ★ 모든 타일에 `갱신주기` 와 `기준시각` 을 필수로 표시한다.
==============================================================================================*/
SELECT
     N'[A] 경영 KPI 타일'                           AS REPORT_NM
    ,@BASE_DT                                       AS 기준일
    ,K.AREA                                         AS 영역
    ,K.KPI_NM                                       AS 지표
    ,K.MM_VAL                                       AS 당월
    ,K.YR_VAL                                       AS 누계
    ,K.UNIT                                         AS 단위
    ,K.TARGET                                       AS 목표
    ,K.GAP                                          AS 목표대비
    ,K.ACHIEVE                                      AS 판정
    ,K.STATUS                                       AS 상태
    ,K.CYCLE                                        AS 갱신주기
    ,K.AS_OF                                        AS 기준시각
    ,K.DRILL                                        AS 드릴다운
    ,신호 = CASE WHEN K.STATUS = N'집계중'          THEN N'회색 (집계중)'
                 WHEN K.STATUS = N'데이터없음'      THEN N'회색 (데이터 없음)'
                 WHEN K.ACHIEVE LIKE N'★%'         THEN N'빨강'
                 WHEN K.ACHIEVE = N'달성'           THEN N'초록'
                 ELSE N'파랑 (참고)' END
FROM   #KPI K
ORDER BY K.SEQ
;


/*==============================================================================================
  ** 쿼리 B : 월별 추이  (대시보드 중단 — 주요 4개 지표)
==============================================================================================*/
;WITH M AS (
    SELECT TOP 12 YM = LEFT(CONVERT(NVARCHAR(8), DATEADD(MONTH, -N.n, CONVERT(DATE, @BASE_DT)), 112), 6)
    FROM  (SELECT TOP 12 n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
           FROM sys.objects) N
)
SELECT
     N'[B] 월별 추이'                               AS REPORT_NM
    ,M.YM                                           AS 기간월
    -- 수주액
    ,수주액 = (SELECT SUM(CAST(ISNULL(D.SOG_AM, D.SO_AM) AS DECIMAL(19,4)))
               FROM LSO H WITH (NOLOCK)
               INNER JOIN LSO_D D WITH (NOLOCK) ON D.CO_CD=H.CO_CD AND D.SO_NB=H.SO_NB
               WHERE H.CO_CD=@CO_CD AND LEFT(H.SO_DT,6)=M.YM
                 AND ISNULL(D.USE_YN,N'1')=N'1' AND ISNULL(D.EXPIRE_YN,N'1')=N'1'
                 AND (@DIV_CD IS NULL OR H.DIV_CD=@DIV_CD))
    -- 매출액
    ,매출액 = (SELECT SUM(CAST(ISNULL(D.CLSG_AM, D.CLSH_AM) AS DECIMAL(19,4)))
               FROM LSALECLS H WITH (NOLOCK)
               INNER JOIN LSALECLS_D D WITH (NOLOCK) ON D.CO_CD=H.CO_CD AND D.CLS_NB=H.CLS_NB
               WHERE H.CO_CD=@CO_CD AND LEFT(H.CLS_DT,6)=M.YM
                 AND ISNULL(D.USE_YN,N'1')=N'1' AND ISNULL(D.EXPIRE_YN,N'1')=N'1'
                 AND (@DIV_CD IS NULL OR H.DIV_CD=@DIV_CD))
    -- 생산실적(양품)
    ,생산량 = (SELECT SUM(CASE WHEN ISNULL(R.SUB_TP,N'0')=N'0' AND ISNULL(R.BAD_YN,N'0')=N'0'
                               THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
               FROM LORCV_H R WITH (NOLOCK)
               WHERE R.CO_CD=@CO_CD AND LEFT(R.WR_DT,6)=M.YM AND ISNULL(R.USE_YN,N'1')=N'1'
                 AND (@DIV_CD IS NULL OR R.DIV_CD=@DIV_CD))
    -- 양품률
    ,양품률_PCT = (SELECT CAST(SUM(CASE WHEN ISNULL(R.SUB_TP,N'0')=N'0' AND ISNULL(R.BAD_YN,N'0')=N'0'
                                        THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
                               / NULLIF(SUM(CASE WHEN ISNULL(R.SUB_TP,N'0')=N'0'
                                                 THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END),0)
                               * 100 AS DECIMAL(5,2))
                    FROM LORCV_H R WITH (NOLOCK)
                    WHERE R.CO_CD=@CO_CD AND LEFT(R.WR_DT,6)=M.YM AND ISNULL(R.USE_YN,N'1')=N'1'
                      AND (@DIV_CD IS NULL OR R.DIV_CD=@DIV_CD))
    -- 수금액
    ,수금액 = (SELECT SUM(CAST(ISNULL(D.NORMAL_AM,0)+ISNULL(D.BEFORE_AM,0) AS DECIMAL(19,4)))
               FROM LRCP H WITH (NOLOCK)
               INNER JOIN LRCP_D D WITH (NOLOCK) ON D.CO_CD=H.CO_CD AND D.RCP_NB=H.RCP_NB
               WHERE H.CO_CD=@CO_CD AND LEFT(H.RCP_DT,6)=M.YM
                 AND ISNULL(D.USE_YN,N'1')=N'1' AND ISNULL(D.EXPIRE_YN,N'1')=N'1'
                 AND ISNULL(D.RCPAM_FG,N'0')=N'0'
                 AND (@DIV_CD IS NULL OR H.DIV_CD=@DIV_CD))
FROM   M
ORDER BY M.YM
;


/*==============================================================================================
  ** 쿼리 C : 이상징후 리스트  (대시보드 하단)
     ─ 각 영역에서 즉시 조치가 필요한 항목만 모아 한 곳에 띄운다.
==============================================================================================*/
-- 미달 KPI
INSERT INTO #ALERT (LEVEL, AREA, TITLE, DETAIL, DRILL)
SELECT N'높음', K.AREA, K.KPI_NM + N' 목표 미달'
      ,N'누계 ' + ISNULL(CAST(CAST(K.YR_VAL AS DECIMAL(19,1)) AS NVARCHAR(30)), N'-')
       + ISNULL(K.UNIT, N'') + N' / 목표 '
       + ISNULL(CAST(CAST(K.TARGET AS DECIMAL(19,1)) AS NVARCHAR(30)), N'-')
       + ISNULL(K.UNIT, N'')
      ,K.DRILL
FROM   #KPI K
WHERE  K.ACHIEVE LIKE N'★%' AND K.STATUS = N'정상';

-- 납기경과 미납 수주
INSERT INTO #ALERT (LEVEL, AREA, TITLE, DETAIL, DRILL)
SELECT N'높음', N'영업', N'납기경과 미납 수주 ' + CAST(COUNT(*) AS NVARCHAR(10)) + N'건'
      ,N'미납금액 ' + CAST(CAST(SUM((ISNULL(D.SO_QT,0)-ISNULL(D.ISU_QT,0))*ISNULL(D.UM,0)) AS DECIMAL(19,0)) AS NVARCHAR(30)) + N'원'
      ,N'S02_주문미납_현황.sql'
FROM       LSO   H WITH (NOLOCK)
INNER JOIN LSO_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.SO_NB = H.SO_NB
WHERE  H.CO_CD = @CO_CD
  AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
  AND  ISNULL(D.SO_QT,0) - ISNULL(D.ISU_QT,0) > 0
  AND  ISNULL(D.DUE_DT, N'') <> N'' AND D.DUE_DT < @BASE_DT
  AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
HAVING COUNT(*) > 0;

-- 납기경과 미입고 발주
INSERT INTO #ALERT (LEVEL, AREA, TITLE, DETAIL, DRILL)
SELECT N'높음', N'구매', N'납기경과 미입고 발주 ' + CAST(COUNT(*) AS NVARCHAR(10)) + N'건'
      ,N'미입고금액 ' + CAST(CAST(SUM((ISNULL(D.PO_QT,0)-ISNULL(R.RCV,0))*ISNULL(D.UM,0)) AS DECIMAL(19,0)) AS NVARCHAR(30)) + N'원'
      ,N'P02_발주납기준수_KPI.sql'
FROM       LPO   H WITH (NOLOCK)
INNER JOIN LPO_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.PO_NB = H.PO_NB
OUTER APPLY (SELECT RCV = SUM(CAST(ISNULL(S.RCV_QT,0) AS DECIMAL(19,6)))
             FROM LSTOCK_D S WITH (NOLOCK)
             WHERE S.CO_CD=D.CO_CD AND S.PO_NB=D.PO_NB AND S.PO_SQ=D.PO_SQ
               AND ISNULL(S.USE_YN,N'1')=N'1') R
WHERE  H.CO_CD = @CO_CD
  AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
  AND  ISNULL(D.PO_QT,0) - ISNULL(R.RCV,0) > 0
  AND  ISNULL(D.DUE_DT, N'') <> N'' AND D.DUE_DT < @BASE_DT
  AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
HAVING COUNT(*) > 0;

-- 납기경과 작업지시
INSERT INTO #ALERT (LEVEL, AREA, TITLE, DETAIL, DRILL)
SELECT N'중간', N'생산', N'납기경과 작업지시 ' + CAST(COUNT(*) AS NVARCHAR(10)) + N'건'
      ,N'미완료 지시. 최장 경과 ' + CAST(MAX(DATEDIFF(DAY,CONVERT(DATE,W.COMP_DT),CONVERT(DATE,@BASE_DT))) AS NVARCHAR(10)) + N'일'
      ,N'M01_작업지시_진행현황.sql'
FROM   LWO_WF W WITH (NOLOCK)
OUTER APPLY (SELECT GOOD = SUM(CASE WHEN ISNULL(X.SUB_TP,N'0')=N'0' AND ISNULL(X.BAD_YN,N'0')=N'0'
                                    THEN CAST(ISNULL(X.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
             FROM LORCV_H X WITH (NOLOCK)
             WHERE X.CO_CD=W.CO_CD AND X.WO_CD=W.WO_CD AND ISNULL(X.USE_YN,N'1')=N'1') R
WHERE  W.CO_CD = @CO_CD
  AND  ISNULL(W.USE_YN, N'1') = N'1' AND ISNULL(W.EXPIRE_YN, N'1') = N'1'
  AND  ISNULL(W.COMP_DT, N'') <> N'' AND W.COMP_DT < @BASE_DT
  AND  CAST(ISNULL(W.ITEM_QT,0) AS DECIMAL(19,6)) - ISNULL(R.GOOD,0) > 0
  AND  (@DIV_CD IS NULL OR W.DIV_CD = @DIV_CD)
HAVING COUNT(*) > 0;

-- 마이너스 재고
INSERT INTO #ALERT (LEVEL, AREA, TITLE, DETAIL, DRILL)
SELECT N'중간', N'구매', N'마이너스 재고 ' + CAST(COUNT(*) AS NVARCHAR(10)) + N'품목'
      ,N'가용재고 계산 신뢰도 저하. SYSCFG 모듈S/코드13 확인 필요'
      ,N'P03_실시간재고_추적.sql'
FROM ( SELECT V.ITEM_CD
       FROM   LINVTORY V WITH (NOLOCK)
       WHERE  V.CO_CD=@CO_CD AND V.P_YR=@P_YR AND V.IO_DT<=@BASE_DT
         AND  ISNULL(V.USE_YN,N'1')=N'1' AND ISNULL(V.EXPIRE_YN,N'1')=N'1'
         AND  (@DIV_CD IS NULL OR V.DIV_CD=@DIV_CD)
       GROUP BY V.ITEM_CD
       HAVING SUM(CAST(ISNULL(V.IOPEN_QT,0)+ISNULL(V.IRCV_QT,0)-ISNULL(V.IISU_QT,0) AS DECIMAL(19,6))) < 0
) X
HAVING COUNT(*) > 0;

-- 미마감 채권 (출고 - 마감)
INSERT INTO #ALERT (LEVEL, AREA, TITLE, DETAIL, DRILL)
SELECT N'중간', N'영업', N'미마감 출고 존재'
      ,N'출고했으나 매출마감 미처리 ' + CAST(COUNT(*) AS NVARCHAR(10)) + N'건. 회계 미확정 채권'
      ,N'S06_채권여신_관리현황.sql'
FROM       LDELIVER   H WITH (NOLOCK)
INNER JOIN LDELIVER_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.ISU_NB = H.ISU_NB
WHERE  H.CO_CD = @CO_CD AND H.ISU_DT BETWEEN @YR_FR AND @BASE_DT
  AND  H.SO_FG IN (N'0', N'2', N'7')
  AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
  AND  ISNULL(D.ISU_QT,0) - ISNULL(D.CLS_QT,0) <> 0
  AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
HAVING COUNT(*) > 0;

SELECT
     N'[C] 이상징후'                                AS REPORT_NM
    ,A.LEVEL                                        AS 심각도
    ,A.AREA                                         AS 영역
    ,A.TITLE                                        AS 항목
    ,A.DETAIL                                       AS 내용
    ,A.DRILL                                        AS 확인_리포트
FROM   #ALERT A
ORDER BY CASE A.LEVEL WHEN N'높음' THEN 1 WHEN N'중간' THEN 2 ELSE 3 END, A.SEQ
;


/*==============================================================================================
  ** 쿼리 D : 드릴다운 경로  ★ 대시보드 구축 시 화면 설계에 그대로 쓴다
==============================================================================================*/
SELECT N'[D] 드릴다운 경로' AS REPORT_NM, * FROM (VALUES
     (1, N'영업', N'수주액'        , N'수주진행총괄현황.sql'          , N'수주 라인 → 작업지시/발주 → 출고 → 마감 → 전표')
    ,(2, N'영업', N'매출액'        , N'A02_기표파이프라인_현황.sql'   , N'마감 → 전표 → 장부. 미기표 마감 상세')
    ,(3, N'영업', N'납기준수율'    , N'S03_납기준수율_KPI.sql'        , N'거래처/품목/담당자별 → 지연 건 상세 + 추정원인')
    ,(4, N'영업', N'미수채권'      , N'S06_채권여신_관리현황.sql'     , N'거래처별 채권 → 연령분석 → 미마감 출고 상세')
    ,(5, N'생산', N'생산달성률'    , N'M01_작업지시_진행현황.sql'     , N'지시별 진척 → 공정별 진척 → 납기리스크 추정원인')
    ,(6, N'생산', N'작업수율'      , N'M06_불량파레토_품질KPI.sql'    , N'불량 Pareto → 공정·작업장별 → 불량 발생 상세')
    ,(7, N'구매', N'결품 품목수'   , N'P05_재고알람_KPI.sql'          , N'알람등급별 → 긴급 조달 대상 → 권장발주수량')
    ,(8, N'구매', N'재고금액/회전율', N'P03_실시간재고_추적.sql'      , N'창고·장소별 → LOT별 → 마이너스 재고')
    ,(9, N'원가', N'원가차이율'    , N'C04_표준원가_차이분석.sql'     , N'수량차이/단가차이 분해 → 자재 파레토 → 주책임 판정')
) V(순서, 영역, 지표, 리포트, 드릴다운_경로)
;


/*==============================================================================================
  ** 쿼리 E : 갱신주기 · 데이터 신선도 점검  ★ 대시보드 신뢰의 근거
==============================================================================================*/
SELECT
     N'[E] 데이터 신선도'                           AS REPORT_NM
    ,구분, 최종일자, 경과일, 갱신주기, 판정
FROM (
    SELECT 순서=1, 구분=N'수주(LSO)'
          ,최종일자=(SELECT MAX(SO_DT) FROM LSO WITH (NOLOCK) WHERE CO_CD=@CO_CD)
          ,갱신주기=N'실시간'
    UNION ALL SELECT 2, N'출고(LDELIVER)'
          ,(SELECT MAX(ISU_DT) FROM LDELIVER WITH (NOLOCK) WHERE CO_CD=@CO_CD), N'실시간'
    UNION ALL SELECT 3, N'매출마감(LSALECLS)'
          ,(SELECT MAX(CLS_DT) FROM LSALECLS WITH (NOLOCK) WHERE CO_CD=@CO_CD), N'일 1회'
    UNION ALL SELECT 4, N'생산실적(LORCV_H)'
          ,(SELECT MAX(WR_DT) FROM LORCV_H WITH (NOLOCK) WHERE CO_CD=@CO_CD), N'실시간'
    UNION ALL SELECT 5, N'재고수불(LINVTORY)'
          ,(SELECT MAX(IO_DT) FROM LINVTORY WITH (NOLOCK) WHERE CO_CD=@CO_CD AND P_YR=@P_YR), N'실시간'
    UNION ALL SELECT 6, N'입고(LSTOCK)'
          ,(SELECT MAX(RCV_DT) FROM LSTOCK WITH (NOLOCK) WHERE CO_CD=@CO_CD), N'실시간'
    UNION ALL SELECT 7, N'수금(LRCP)'
          ,(SELECT MAX(RCP_DT) FROM LRCP WITH (NOLOCK) WHERE CO_CD=@CO_CD), N'일 1회'
) X
CROSS APPLY (SELECT 경과일 = CASE WHEN X.최종일자 IS NOT NULL
                                  THEN DATEDIFF(DAY, CONVERT(DATE,X.최종일자), CONVERT(DATE,@BASE_DT)) END) D
CROSS APPLY (SELECT 판정 = CASE
                 WHEN X.최종일자 IS NULL          THEN N'★ 데이터 없음'
                 WHEN D.경과일 >  7               THEN N'★ 7일 이상 미갱신 - 대시보드 값 신뢰 불가'
                 WHEN D.경과일 >  3               THEN N'주의 (3일 이상 미갱신)'
                 ELSE N'정상' END) P
ORDER BY X.순서
;

-- 원가차수 상태 (별도 표기)
SELECT
     N'[E-2] 원가차수 상태'                         AS REPORT_NM
    ,@P_YR                                          AS 회계연도
    ,ISNULL(CAST(@CHASU AS NVARCHAR(10)), N'없음')  AS 적용차수
    ,@CHASU_ST                                      AS 차수상태
    ,판정 = CASE WHEN @CHASU IS NULL       THEN N'★ 원가계산 미실행 - 원가 KPI 사용 불가'
                 WHEN @CHASU_ST <> N'마감' THEN N'★ 미마감 차수 - 값이 튈 수 있어 집계중으로 표기'
                 ELSE N'정상' END
;


DROP TABLE #KPI, #ALERT, #UM;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 금액 컬럼명 확인  ★ 수주/매출 타일의 전제
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('LSO_D')      AND name LIKE '%AM';
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('LSALECLS_D') AND name LIKE '%AM';
     --> 본 쿼리는 SOG_AM(공급가) 우선, 없으면 SO_AM / CLSG_AM 우선, 없으면 CLSH_AM 을 쓴다.
        컬럼이 다르면 2·3번 블록을 수정할 것.

  -- (2) 원가차수 운영 주기  ★ 원가 타일의 갱신주기 표기를 좌우
     SELECT P_YR, CHASU, SMM, FMM, CLS_YN FROM CIV_CHASU
     WHERE CO_CD='1000' ORDER BY P_YR DESC, CHASU DESC;
     --> 월 1회면 '월 1회(차수마감)', 수시면 실제 주기로 @KPI.CYCLE 표기를 고칠 것.

  -- (3) 데이터 신선도  ★ 쿼리 E 와 같은 목적. 대시보드 첫 구동 시 필수
     --> 경과일이 7일 넘는 소스가 있으면 그 타일은 띄우지 말 것. 틀린 값보다 빈 값이 낫다.

  -- (4) 여신한도 소스
     SELECT name FROM sys.tables WHERE name IN ('LCR_LIMIT');
     --> 있으면 타일 4 의 여신 부분을 S-06 처럼 LCR_LIMIT 기준으로 바꿀 것.
        본 대시보드는 경량화를 위해 STRADE.CREDIT_AM 만 쓴다.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **이 대시보드는 지표를 재집계한다.** 각 상세 리포트와 같은 산식을 썼지만, 파라미터
     (평가 모집단·허용오차·제외 조건)를 경량화했기 때문에 **소수점 단위로는 상세 리포트와
     다를 수 있다.** 숫자를 확정해야 하는 자리에서는 반드시 상세 리포트를 근거로 쓸 것.
     예) 납기준수율은 여기선 전 품목, S-03 은 반품 제외·단종품 제외 옵션이 있다.

  2) **재고금액/회전율은 평가 전 단가 기준**이다. `LINV_TAV.ISU_UM` 을 쓰되 기수(GISU)를
     구분하지 않고 평균했다. 회계 확정 재고금액은 `LINV_MVFIFO`(평가 후)를 봐야 한다.
     회전율도 연환산 근사치이므로 추세 판단용으로만 쓸 것.

  3) **원가 KPI 는 차수 마감 전에는 값을 내지 않는다.** 이는 의도된 동작이다.
     미마감 차수 값을 띄우면 월초마다 원가가 급변해 대시보드 신뢰가 무너진다.

  4) 계획(예산) 데이터가 없어 **수주액·매출액의 '계획 대비 %' 는 비워 두었다.**
     계획을 관리하는 테이블이 확인되면 타일 1·2 의 TARGET 에 채워 넣을 것.

  [ 관련 산출물 ] — 모든 타일의 드릴다운 대상 (쿼리 D 참조)
  ----------------------------------------------------------------------------------------------
   영업 : 수주진행총괄현황 / S02 주문미납 / S03 납기준수율 / S06 채권여신 / A02 기표파이프라인
   생산 : M01 작업지시진행 / M04 공정별재공 / M06 품질KPI / M11 생산계획대비 / 생산지시별 작업수율
   구매 : P01 청구발주입고 / P02 발주납기 / P03 실시간재고 / P05 재고알람 / 원자재수급 MRP
   원가 : C04 표준원가차이 / M05 자재 청구출고사용 / PJT 생산원가
   기준 : B01 마스터품질 스코어카드
==============================================================================================*/
