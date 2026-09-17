/*==============================================================================================
  [ iCUBE ] P-09 재고평가 정합성  +  M-09 재공 실사 대비                             (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : **상시 점검 리포트.** 원가 마감 전·재고 실사 후에 돌려 장부를 믿을 수 있는지 확인한다.
         두 가지를 본다.
           P-09  평가 전(LINVTORY) ↔ 평가 후(LINV_MVFIFO) 가 맞는가.  `*_AM_GAP` 이 차이금액.
           M-09  장부 재공(LINV_WIP) ↔ 실사 재공(LINVINSP_WIP) 이 맞는가.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 왜 한 파일에 묶었나 ]
  ----------------------------------------------------------------------------------------------
     둘 다 **"장부 숫자를 믿어도 되는가"** 를 묻는 점검이고, 실행 시점도 같다(원가 마감 직전).
     평가가 틀어졌는데 원가를 마감하면 그 달 원가가 통째로 틀린다. 재공이 틀어져도 마찬가지다.
     그래서 마감 전에 이 파일 하나를 돌려 두 가지를 같이 확인하도록 했다.

  ----------------------------------------------------------------------------------------------
  [ 소스 ]
  ----------------------------------------------------------------------------------------------
     LINVTORY        평가 전 수불    IOPEN_QT / IRCV_QT / IISU_QT
     LINV_MVFIFO     평가 후 수불부  OPEN_QT/AM, RCV_QT/AM, RCVT_QT/UM/AM, ISU_QT/UM/AM,
                                     TRNS_QT/UM/AM, INV_QT/AM  (+ GISU, SMM, FMM, CLS_NB)
     LINV_MVFIFO_WK  평가 작업본     위 + **OPEN_AM_GAP / RCV_AM_GAP / RCVT_AM_GAP** ★ 차이금액
     LINV_WIP        재공수불부
     LINVINSP_WIP    재공 실사

  ----------------------------------------------------------------------------------------------
  [ 판정 기준 ]
  ----------------------------------------------------------------------------------------------
     GAP 이 0 이 아니면 평가가 완결되지 않았거나 재계산이 필요한 상태다.
     **금액 기준 @TH_AM(기본 1원) 이상이면 전부 잡아낸다.** 재고평가는 1원도 안 맞으면
     재무제표가 안 맞으므로 임계값을 크게 두지 않았다.
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)   = N'1000'
    ,@DIV_CD   NVARCHAR(4)   = N'1000'
    ,@P_YR     NVARCHAR(4)   = N'2026'
    ,@BASE_DT  NVARCHAR(8)   = N'20260916'    -- 기준일 (재공 체류 산정)
    ,@GISU     INT           = NULL           -- 기수 (NULL = 최신)
    ,@SMM      NVARCHAR(6)   = NULL           -- 평가 시작월 (NULL = 전체)
    ,@FMM      NVARCHAR(6)   = NULL           -- 평가 종료월
    ,@ITEM_CD  NVARCHAR(25)  = NULL
    ,@TH_AM    DECIMAL(19,4) = 1.0            -- 금액 차이 임계 (원)
    ,@TH_QT    DECIMAL(19,6) = 0.000001       -- 수량 차이 임계
;

DECLARE @SQL NVARCHAR(MAX);
DECLARE @HAS_WK BIT = 0, @HAS_FIFO BIT = 0, @HAS_INSP BIT = 0;
DECLARE @INSP_QT NVARCHAR(30), @INSP_DT NVARCHAR(30);

IF OBJECT_ID('tempdb..#GAP')  IS NOT NULL DROP TABLE #GAP;
IF OBJECT_ID('tempdb..#EVAL') IS NOT NULL DROP TABLE #EVAL;
IF OBJECT_ID('tempdb..#WIP')  IS NOT NULL DROP TABLE #WIP;
IF OBJECT_ID('tempdb..#INSP') IS NOT NULL DROP TABLE #INSP;


/*==============================================================================================
  1. 기수 결정 + #GAP : 평가 차이금액 (LINV_MVFIFO_WK)
==============================================================================================*/
CREATE TABLE #GAP (
     ITEM_CD   NVARCHAR(25)
    ,GISU      INT
    ,SMM       NVARCHAR(6)
    ,FMM       NVARCHAR(6)
    ,OPEN_GAP  DECIMAL(19,4)
    ,RCV_GAP   DECIMAL(19,4)
    ,RCVT_GAP  DECIMAL(19,4)
    ,TOT_GAP   DECIMAL(19,4)
);

IF OBJECT_ID(N'dbo.LINV_MVFIFO_WK', N'U') IS NOT NULL
BEGIN
    IF @GISU IS NULL
    BEGIN
        SET @SQL = N'SELECT @o = MAX(GISU) FROM dbo.LINV_MVFIFO_WK WITH (NOLOCK)
                     WHERE CO_CD = @p_CO AND (@p_DIV IS NULL OR DIV_CD = @p_DIV)';
        BEGIN TRY
            EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @o INT OUTPUT'
                ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @o=@GISU OUTPUT;
        END TRY BEGIN CATCH END CATCH
    END

    SET @SQL = N'
        INSERT INTO #GAP (ITEM_CD, GISU, SMM, FMM, OPEN_GAP, RCV_GAP, RCVT_GAP, TOT_GAP)
        SELECT W.ITEM_CD, W.GISU, W.SMM, W.FMM
              ,SUM(CAST(ISNULL(W.OPEN_AM_GAP,0) AS DECIMAL(19,4)))
              ,SUM(CAST(ISNULL(W.RCV_AM_GAP ,0) AS DECIMAL(19,4)))
              ,SUM(CAST(ISNULL(W.RCVT_AM_GAP,0) AS DECIMAL(19,4)))
              ,SUM(CAST(ISNULL(W.OPEN_AM_GAP,0)+ISNULL(W.RCV_AM_GAP,0)+ISNULL(W.RCVT_AM_GAP,0)
                        AS DECIMAL(19,4)))
        FROM   dbo.LINV_MVFIFO_WK W WITH (NOLOCK)
        WHERE  W.CO_CD = @p_CO
          AND  (@p_GI   IS NULL OR W.GISU    = @p_GI)
          AND  (@p_DIV  IS NULL OR W.DIV_CD  = @p_DIV)
          AND  (@p_SMM  IS NULL OR W.SMM    >= @p_SMM)
          AND  (@p_FMM  IS NULL OR W.FMM    <= @p_FMM)
          AND  (@p_ITEM IS NULL OR W.ITEM_CD = @p_ITEM)
        GROUP BY W.ITEM_CD, W.GISU, W.SMM, W.FMM';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_GI INT
              ,@p_SMM NVARCHAR(6), @p_FMM NVARCHAR(6), @p_ITEM NVARCHAR(25)'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_GI=@GISU
            ,@p_SMM=@SMM, @p_FMM=@FMM, @p_ITEM=@ITEM_CD;
        SET @HAS_WK = 1;
        PRINT N'[1] LINV_MVFIFO_WK (GISU=' + ISNULL(CAST(@GISU AS NVARCHAR(10)), N'전체') + N') : '
              + CAST((SELECT COUNT(*) FROM #GAP) AS NVARCHAR(20)) + N' 행';
    END TRY
    BEGIN CATCH
        PRINT N'[1] ★ LINV_MVFIFO_WK 조회 실패 : ' + ERROR_MESSAGE();
    END CATCH
END
ELSE PRINT N'[1] LINV_MVFIFO_WK 없음 - 평가 차이 점검 생략';

CREATE CLUSTERED INDEX IX_GAP ON #GAP (ITEM_CD);


/*==============================================================================================
  2. #EVAL : 평가 전(LINVTORY) vs 평가 후(LINV_MVFIFO) 수량 대사
==============================================================================================*/
CREATE TABLE #EVAL (
     ITEM_CD    NVARCHAR(25)
    ,RAW_OPEN   DECIMAL(19,6)
    ,RAW_RCV    DECIMAL(19,6)
    ,RAW_ISU    DECIMAL(19,6)
    ,RAW_INV    DECIMAL(19,6)
    ,EV_OPEN    DECIMAL(19,6)
    ,EV_RCV     DECIMAL(19,6)
    ,EV_ISU     DECIMAL(19,6)
    ,EV_INV     DECIMAL(19,6)
    ,EV_INV_AM  DECIMAL(19,4)
);

-- 평가 전
INSERT INTO #EVAL (ITEM_CD, RAW_OPEN, RAW_RCV, RAW_ISU, RAW_INV)
SELECT
     V.ITEM_CD
    ,SUM(CAST(ISNULL(V.IOPEN_QT,0) AS DECIMAL(19,6)))
    ,SUM(CAST(ISNULL(V.IRCV_QT ,0) AS DECIMAL(19,6)))
    ,SUM(CAST(ISNULL(V.IISU_QT ,0) AS DECIMAL(19,6)))
    ,SUM(CAST(ISNULL(V.IOPEN_QT,0)+ISNULL(V.IRCV_QT,0)-ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)))
FROM   LINVTORY V WITH (NOLOCK)
WHERE  V.CO_CD = @CO_CD AND V.P_YR = @P_YR
  AND  ISNULL(V.USE_YN, N'1') = N'1' AND ISNULL(V.EXPIRE_YN, N'1') = N'1'
  AND  (@DIV_CD  IS NULL OR V.DIV_CD  = @DIV_CD)
  AND  (@ITEM_CD IS NULL OR V.ITEM_CD = @ITEM_CD)
GROUP BY V.ITEM_CD;

-- 평가 후
IF OBJECT_ID(N'dbo.LINV_MVFIFO', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
        MERGE #EVAL AS T
        USING ( SELECT F.ITEM_CD
                      ,O = SUM(CAST(ISNULL(F.OPEN_QT,0) AS DECIMAL(19,6)))
                      ,R = SUM(CAST(ISNULL(F.RCV_QT ,0) AS DECIMAL(19,6)))
                      ,I = SUM(CAST(ISNULL(F.ISU_QT ,0) AS DECIMAL(19,6)))
                      ,N = SUM(CAST(ISNULL(F.INV_QT ,0) AS DECIMAL(19,6)))
                      ,A = SUM(CAST(ISNULL(F.INV_AM ,0) AS DECIMAL(19,4)))
                FROM   dbo.LINV_MVFIFO F WITH (NOLOCK)
                WHERE  F.CO_CD = @p_CO
                  AND  (@p_GI   IS NULL OR F.GISU    = @p_GI)
                  AND  (@p_DIV  IS NULL OR F.DIV_CD  = @p_DIV)
                  AND  (@p_ITEM IS NULL OR F.ITEM_CD = @p_ITEM)
                GROUP BY F.ITEM_CD ) AS S ON S.ITEM_CD = T.ITEM_CD
        WHEN MATCHED THEN UPDATE SET EV_OPEN=S.O, EV_RCV=S.R, EV_ISU=S.I, EV_INV=S.N, EV_INV_AM=S.A
        WHEN NOT MATCHED THEN
             INSERT (ITEM_CD, RAW_OPEN, RAW_RCV, RAW_ISU, RAW_INV, EV_OPEN, EV_RCV, EV_ISU, EV_INV, EV_INV_AM)
             VALUES (S.ITEM_CD, 0,0,0,0, S.O, S.R, S.I, S.N, S.A);';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_GI INT, @p_ITEM NVARCHAR(25)'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_GI=@GISU, @p_ITEM=@ITEM_CD;
        SET @HAS_FIFO = 1;
        PRINT N'[2] LINV_MVFIFO 대사 적재 완료';
    END TRY
    BEGIN CATCH
        PRINT N'[2] ★ LINV_MVFIFO 조회 실패 : ' + ERROR_MESSAGE();
    END CATCH
END
ELSE PRINT N'[2] LINV_MVFIFO 없음 - 평가 전후 대사 생략';

CREATE CLUSTERED INDEX IX_EVAL ON #EVAL (ITEM_CD);


/*==============================================================================================
  3. #WIP / #INSP : 재공 장부 vs 실사  (M-09)
==============================================================================================*/
SELECT
     WH_CD   = ISNULL(V.WH_CD, N'')
    ,V.ITEM_CD
    ,BOOK_QT = SUM(CAST(ISNULL(V.IOPEN_QT,0)+ISNULL(V.IRCV_QT,0)-ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)))
    ,LAST_DT = MAX(V.IO_DT)
INTO #WIP
FROM   LINV_WIP V WITH (NOLOCK)
WHERE  V.CO_CD = @CO_CD AND V.P_YR = @P_YR
  AND  ISNULL(V.USE_YN, N'1') = N'1' AND ISNULL(V.EXPIRE_YN, N'1') = N'1'
  AND  (@DIV_CD  IS NULL OR V.DIV_CD  = @DIV_CD)
  AND  (@ITEM_CD IS NULL OR V.ITEM_CD = @ITEM_CD)
GROUP BY V.WH_CD, V.ITEM_CD;
CREATE CLUSTERED INDEX IX_WIP ON #WIP (WH_CD, ITEM_CD);

CREATE TABLE #INSP (
     WH_CD   NVARCHAR(10)
    ,ITEM_CD NVARCHAR(25)
    ,INSP_QT DECIMAL(19,6)
    ,INSP_DT NVARCHAR(8)
);

IF OBJECT_ID(N'dbo.LINVINSP_WIP', N'U') IS NOT NULL
BEGIN
    SELECT TOP 1 @INSP_QT = name FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.LINVINSP_WIP')
      AND name IN (N'INSP_QT', N'REAL_QT', N'MGMT_QT', N'ITEM_QT')
    ORDER BY CASE name WHEN N'INSP_QT' THEN 1 WHEN N'REAL_QT' THEN 2 ELSE 3 END;

    SELECT TOP 1 @INSP_DT = name FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.LINVINSP_WIP')
      AND name IN (N'INSP_DT', N'IO_DT', N'CHK_DT', N'REG_DT')
    ORDER BY CASE name WHEN N'INSP_DT' THEN 1 WHEN N'IO_DT' THEN 2 ELSE 3 END;

    IF @INSP_QT IS NOT NULL
    BEGIN
        SET @SQL = N'
            INSERT INTO #INSP (WH_CD, ITEM_CD, INSP_QT, INSP_DT)
            SELECT ISNULL(S.WH_CD, N''''), S.ITEM_CD
                  ,SUM(CAST(ISNULL(S.' + QUOTENAME(@INSP_QT) + N', 0) AS DECIMAL(19,6)))
                  ,' + CASE WHEN @INSP_DT IS NOT NULL THEN N'MAX(S.' + QUOTENAME(@INSP_DT) + N')'
                            ELSE N'NULL' END + N'
            FROM   dbo.LINVINSP_WIP S WITH (NOLOCK)
            WHERE  S.CO_CD = @p_CO
              AND  ISNULL(S.USE_YN, N''1'') = N''1''
              AND  (@p_DIV  IS NULL OR S.DIV_CD  = @p_DIV)
              AND  (@p_ITEM IS NULL OR S.ITEM_CD = @p_ITEM)
            GROUP BY S.WH_CD, S.ITEM_CD';
        BEGIN TRY
            EXEC sp_executesql @SQL
                ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_ITEM NVARCHAR(25)'
                ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_ITEM=@ITEM_CD;
            SET @HAS_INSP = 1;
            PRINT N'[3] LINVINSP_WIP (' + @INSP_QT + N') : '
                  + CAST((SELECT COUNT(*) FROM #INSP) AS NVARCHAR(20)) + N' 행';
        END TRY
        BEGIN CATCH PRINT N'[3] ★ LINVINSP_WIP 조회 실패 : ' + ERROR_MESSAGE(); END CATCH
    END
    ELSE PRINT N'[3] LINVINSP_WIP 에 실사수량 컬럼을 찾지 못함';
END
ELSE PRINT N'[3] LINVINSP_WIP 없음 - 재공 실사 점검 생략';

CREATE CLUSTERED INDEX IX_INSP ON #INSP (WH_CD, ITEM_CD);


/*==============================================================================================
  ** 쿼리 A : 평가 정합성 종합 판정  ★ 원가 마감 전 첫 화면
==============================================================================================*/
SELECT
     N'[A] 평가 정합성 종합'                        AS REPORT_NM
    ,@P_YR                                          AS 회계연도
    ,ISNULL(CAST(@GISU AS NVARCHAR(10)), N'전체')   AS 기수
    ,LINV_MVFIFO_WK = CASE WHEN @HAS_WK   = 1 THEN N'O' ELSE N'X' END
    ,LINV_MVFIFO    = CASE WHEN @HAS_FIFO = 1 THEN N'O' ELSE N'X' END
    ,LINVINSP_WIP   = CASE WHEN @HAS_INSP = 1 THEN N'O' ELSE N'X' END

    -- 평가 차이금액
    ,GAP_품목수  = (SELECT COUNT(*) FROM #GAP WHERE ABS(TOT_GAP) >= @TH_AM)
    ,GAP_기초    = (SELECT SUM(OPEN_GAP) FROM #GAP)
    ,GAP_입고    = (SELECT SUM(RCV_GAP ) FROM #GAP)
    ,GAP_대체입고 = (SELECT SUM(RCVT_GAP) FROM #GAP)
    ,GAP_합계    = (SELECT SUM(TOT_GAP ) FROM #GAP)
    ,GAP_절대합계 = (SELECT SUM(ABS(TOT_GAP)) FROM #GAP)

    -- 평가 전후 수량 대사
    ,수량불일치_품목수 = (SELECT COUNT(*) FROM #EVAL
                          WHERE @HAS_FIFO = 1 AND ABS(RAW_INV - EV_INV) >= @TH_QT)
    ,평가후_재고금액 = (SELECT SUM(EV_INV_AM) FROM #EVAL)

    -- 재공 실사
    ,재공_장부품목수 = (SELECT COUNT(*) FROM #WIP  WHERE BOOK_QT <> 0)
    ,재공_실사품목수 = (SELECT COUNT(*) FROM #INSP WHERE INSP_QT <> 0)
    ,재공_차이품목수 = (SELECT COUNT(*) FROM #WIP W
                        FULL JOIN #INSP S ON S.WH_CD = W.WH_CD AND S.ITEM_CD = W.ITEM_CD
                        WHERE @HAS_INSP = 1
                          AND ABS(ISNULL(S.INSP_QT,0) - ISNULL(W.BOOK_QT,0)) >= @TH_QT)

    ,판정 = CASE
         WHEN @HAS_WK = 0 AND @HAS_FIFO = 0
              THEN N'9.★평가 테이블 없음 - 재고평가 미운영 또는 미실행'
         WHEN ABS(ISNULL((SELECT SUM(TOT_GAP) FROM #GAP), 0)) >= @TH_AM
              THEN N'1.★평가 차이금액 존재 - 재고평가 재실행 필요. 이 상태로 원가 마감 금지'
         WHEN (SELECT COUNT(*) FROM #EVAL WHERE @HAS_FIFO = 1
                 AND ABS(RAW_INV - EV_INV) >= @TH_QT) > 0
              THEN N'2.★평가 전후 수량 불일치 - 평가 대상 누락 의심'
         WHEN (SELECT COUNT(*) FROM #WIP W
               FULL JOIN #INSP S ON S.WH_CD = W.WH_CD AND S.ITEM_CD = W.ITEM_CD
               WHERE @HAS_INSP = 1
                 AND ABS(ISNULL(S.INSP_QT,0) - ISNULL(W.BOOK_QT,0)) >= @TH_QT) > 0
              THEN N'3.★재공 실사 차이 존재 - 재공 조정(LWIPIO) 후 마감할 것'
         ELSE N'0.정상 - 원가 마감 가능' END
;


/*==============================================================================================
  ** 쿼리 B : 평가 차이금액 상세  (P-09 핵심)
     ─ GAP 이 0 이 아니면 평가가 완결되지 않은 것이다. 금액순으로 원인을 잡는다.
==============================================================================================*/
SELECT
     N'[B] 평가 차이금액 상세'                      AS REPORT_NM
    ,G.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
    ,G.GISU                                         AS 기수
    ,G.SMM                                          AS 시작월
    ,G.FMM                                          AS 종료월
    ,G.OPEN_GAP                                     AS 기초차이금액
    ,G.RCV_GAP                                      AS 입고차이금액
    ,G.RCVT_GAP                                     AS 대체입고차이금액
    ,G.TOT_GAP                                      AS 차이합계
    ,E.EV_INV                                       AS 평가후_재고수량
    ,E.EV_INV_AM                                    AS 평가후_재고금액
    ,차이비율_PCT = CAST(CASE WHEN ISNULL(E.EV_INV_AM, 0) <> 0
                              THEN G.TOT_GAP / E.EV_INV_AM * 100 END AS DECIMAL(9,2))
    ,주차이항목 = CASE
         WHEN ABS(G.OPEN_GAP) >= ABS(G.RCV_GAP) AND ABS(G.OPEN_GAP) >= ABS(G.RCVT_GAP)
              THEN N'기초 (전기 이월 금액 불일치)'
         WHEN ABS(G.RCV_GAP) >= ABS(G.RCVT_GAP)
              THEN N'입고 (매입단가 또는 입고금액 불일치)'
         ELSE N'대체입고 (생산입고·재고이동 금액 불일치)' END
    ,조치 = CASE
         WHEN ABS(G.OPEN_GAP) >= @TH_AM
              THEN N'★ 전기 마감 금액 확인 → 기초 이월 재처리'
         WHEN ABS(G.RCV_GAP) >= @TH_AM
              THEN N'★ 매입마감 금액 vs 입고 금액 대사 (P-01 확인)'
         ELSE N'★ 생산입고 단가 확인 → 재고평가 재실행' END
FROM       #GAP  G
LEFT  JOIN #EVAL E ON E.ITEM_CD = G.ITEM_CD
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = G.ITEM_CD
WHERE  ABS(G.TOT_GAP) >= @TH_AM
ORDER BY ABS(G.TOT_GAP) DESC
;


/*==============================================================================================
  ** 쿼리 C : 평가 전 vs 평가 후 수량 대사
     ─ 수량은 평가로 바뀌지 않는다. 다르면 평가 대상에서 빠졌거나 범위가 어긋난 것이다.
==============================================================================================*/
SELECT
     N'[C] 평가 전후 수량 대사'                     AS REPORT_NM
    ,E.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
    ,E.RAW_OPEN                                     AS 평가전_기초
    ,E.EV_OPEN                                      AS 평가후_기초
    ,E.RAW_RCV                                      AS 평가전_입고
    ,E.EV_RCV                                       AS 평가후_입고
    ,E.RAW_ISU                                      AS 평가전_출고
    ,E.EV_ISU                                       AS 평가후_출고
    ,E.RAW_INV                                      AS 평가전_재고
    ,E.EV_INV                                       AS 평가후_재고
    ,재고차이 = E.RAW_INV - E.EV_INV
    ,E.EV_INV_AM                                    AS 평가후_재고금액
    ,판정 = CASE
         WHEN E.EV_INV IS NULL OR (E.EV_OPEN = 0 AND E.EV_RCV = 0 AND E.EV_ISU = 0)
              THEN N'1.★평가 대상에서 누락 (평가 후 데이터 없음)'
         WHEN E.RAW_INV = 0 AND E.EV_INV <> 0
              THEN N'2.★평가 전 없는데 평가 후 존재 - 범위 불일치'
         WHEN ABS(E.RAW_INV - E.EV_INV) >= @TH_QT
              THEN N'3.★수량 불일치 - 평가 범위(GISU/SMM~FMM) 확인'
         ELSE N'0.일치' END
FROM       #EVAL E
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = E.ITEM_CD
WHERE  @HAS_FIFO = 1
  AND  (ABS(E.RAW_INV - ISNULL(E.EV_INV, 0)) >= @TH_QT
     OR (E.RAW_INV <> 0 AND E.EV_INV IS NULL))
ORDER BY ABS(E.RAW_INV - ISNULL(E.EV_INV, 0)) DESC
;


/*==============================================================================================
  ** 쿼리 D : 재공 실사 대비 현황  (M-09 핵심)
==============================================================================================*/
SELECT
     N'[D] 재공 실사 대비'                          AS REPORT_NM
    ,공정코드 = ISNULL(W.WH_CD, S.WH_CD)
    ,H.WH_NM                                        AS 공정명
    ,품번 = ISNULL(W.ITEM_CD, S.ITEM_CD)
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,ISNULL(W.BOOK_QT, 0)                           AS 장부재공
    ,ISNULL(S.INSP_QT, 0)                           AS 실사재공
    ,차이수량 = ISNULL(S.INSP_QT, 0) - ISNULL(W.BOOK_QT, 0)
    ,차이율_PCT = CAST(CASE WHEN ISNULL(W.BOOK_QT, 0) <> 0
                            THEN (ISNULL(S.INSP_QT,0) - W.BOOK_QT) / W.BOOK_QT * 100
                            END AS DECIMAL(9,2))
    ,S.INSP_DT                                      AS 실사일
    ,W.LAST_DT                                      AS 최종수불일
    ,실사후경과일 = CASE WHEN S.INSP_DT IS NOT NULL
                         THEN DATEDIFF(DAY, CONVERT(DATE,S.INSP_DT), CONVERT(DATE,@BASE_DT)) END
    ,판정 = CASE
         WHEN W.ITEM_CD IS NULL
              THEN N'1.★장부에 없는 재공이 실사됨 - 재공입고 누락'
         WHEN S.ITEM_CD IS NULL
              THEN N'2.★실사되지 않은 장부 재공 - 실물 확인 필요'
         WHEN ABS(ISNULL(S.INSP_QT,0) - W.BOOK_QT) < @TH_QT
              THEN N'0.일치'
         WHEN ISNULL(S.INSP_QT,0) > W.BOOK_QT
              THEN N'3.★실사 과다 (실물 > 장부) - 재공입고 등록 누락'
         ELSE N'4.★장부 과다 (장부 > 실물) - 재공출고 등록 누락 또는 분실' END
    ,조치 = CASE
         WHEN ABS(ISNULL(S.INSP_QT,0) - ISNULL(W.BOOK_QT,0)) < @TH_QT THEN N'-'
         ELSE N'재공조정(LWIPIO, WIP_NB=WA) 으로 장부를 실물에 맞춘 뒤 원가 마감' END
FROM       #WIP  W
FULL  JOIN #INSP S ON S.WH_CD = W.WH_CD AND S.ITEM_CD = W.ITEM_CD
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = ISNULL(W.ITEM_CD, S.ITEM_CD)
LEFT  JOIN SWH   H WITH (NOLOCK) ON H.CO_CD = @CO_CD AND H.WH_CD   = ISNULL(W.WH_CD, S.WH_CD)
WHERE  @HAS_INSP = 1
  AND  ABS(ISNULL(S.INSP_QT, 0) - ISNULL(W.BOOK_QT, 0)) >= @TH_QT
ORDER BY ABS(ISNULL(S.INSP_QT, 0) - ISNULL(W.BOOK_QT, 0)) DESC
;


/*==============================================================================================
  ** 쿼리 E : 재공 실사 요약 (공정별)
==============================================================================================*/
SELECT
     N'[E] 재공 실사 요약'                          AS REPORT_NM
    ,공정코드 = ISNULL(W.WH_CD, S.WH_CD)
    ,H.WH_NM                                        AS 공정명
    ,품목수 = COUNT(*)
    ,장부재공계 = SUM(ISNULL(W.BOOK_QT, 0))
    ,실사재공계 = SUM(ISNULL(S.INSP_QT, 0))
    ,차이계 = SUM(ISNULL(S.INSP_QT,0) - ISNULL(W.BOOK_QT,0))
    ,차이품목수 = SUM(CASE WHEN ABS(ISNULL(S.INSP_QT,0)-ISNULL(W.BOOK_QT,0)) >= @TH_QT
                           THEN 1 ELSE 0 END)
    ,일치율_PCT = CAST(SUM(CASE WHEN ABS(ISNULL(S.INSP_QT,0)-ISNULL(W.BOOK_QT,0)) < @TH_QT
                                THEN 1.0 ELSE 0 END) / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
    ,실사누락품목수 = SUM(CASE WHEN S.ITEM_CD IS NULL THEN 1 ELSE 0 END)
    ,장부누락품목수 = SUM(CASE WHEN W.ITEM_CD IS NULL THEN 1 ELSE 0 END)
    ,판정 = CASE
         WHEN SUM(CASE WHEN ABS(ISNULL(S.INSP_QT,0)-ISNULL(W.BOOK_QT,0)) < @TH_QT THEN 1.0 ELSE 0 END)
              / NULLIF(COUNT(*), 0) >= 0.95                                  THEN N'0.양호 (95% 이상 일치)'
         WHEN SUM(CASE WHEN ABS(ISNULL(S.INSP_QT,0)-ISNULL(W.BOOK_QT,0)) < @TH_QT THEN 1.0 ELSE 0 END)
              / NULLIF(COUNT(*), 0) >= 0.80                                  THEN N'1.주의 (80% 이상)'
         ELSE N'2.★재공 관리 부실 - 현장 등록 프로세스 점검 필요' END
FROM       #WIP  W
FULL  JOIN #INSP S ON S.WH_CD = W.WH_CD AND S.ITEM_CD = W.ITEM_CD
LEFT  JOIN SWH   H WITH (NOLOCK) ON H.CO_CD = @CO_CD AND H.WH_CD = ISNULL(W.WH_CD, S.WH_CD)
WHERE  @HAS_INSP = 1
GROUP BY ISNULL(W.WH_CD, S.WH_CD), H.WH_NM
ORDER BY 판정 DESC, ABS(차이계) DESC
;


/*==============================================================================================
  ** 쿼리 F : 데이터 점검 / 실행 가이드
==============================================================================================*/
SELECT
     N'[F] 점검 실행 가이드'                        AS REPORT_NM
    ,항목, 상태, 다음조치
FROM (VALUES
     (1, N'LINV_MVFIFO_WK (평가 차이)'
        ,CASE WHEN OBJECT_ID(N'dbo.LINV_MVFIFO_WK', N'U') IS NULL THEN N'★ 테이블 없음'
              WHEN (SELECT COUNT(*) FROM #GAP) = 0 THEN N'데이터 없음'
              WHEN ABS(ISNULL((SELECT SUM(TOT_GAP) FROM #GAP),0)) >= 1 THEN N'★ 차이 존재'
              ELSE N'정상' END
        ,N'쿼리 B 에서 금액순 확인 → 재고평가 재실행 → 다시 이 파일 실행')
    ,(2, N'LINV_MVFIFO (평가 결과)'
        ,CASE WHEN OBJECT_ID(N'dbo.LINV_MVFIFO', N'U') IS NULL THEN N'★ 테이블 없음'
              WHEN (SELECT COUNT(*) FROM #EVAL WHERE EV_INV IS NOT NULL) = 0 THEN N'★ 평가 미실행'
              ELSE N'정상' END
        ,N'쿼리 C 로 평가 전후 수량 대사. 불일치면 평가 범위(GISU/SMM~FMM) 확인')
    ,(3, N'LINVINSP_WIP (재공 실사)'
        ,CASE WHEN OBJECT_ID(N'dbo.LINVINSP_WIP', N'U') IS NULL THEN N'★ 테이블 없음'
              WHEN (SELECT COUNT(*) FROM #INSP) = 0 THEN N'실사 데이터 없음'
              ELSE N'정상' END
        ,N'쿼리 D·E 로 차이 확인 → 재공조정(LWIPIO) → 원가 마감')
    ,(4, N'원가 마감 가능 여부'
        ,CASE WHEN ABS(ISNULL((SELECT SUM(TOT_GAP) FROM #GAP),0)) >= 1 THEN N'★ 불가'
              ELSE N'가능' END
        ,N'차이가 남은 상태로 마감하면 그 달 원가가 통째로 틀린다')
) V(순서, 항목, 상태, 다음조치)
ORDER BY 순서
;


DROP TABLE #GAP, #EVAL, #WIP, #INSP;
GO


/*==============================================================================================
  [ 상시 점검 운영 ]
  ----------------------------------------------------------------------------------------------
  실행 시점 : **원가 마감 직전** (월 1회) + 재고·재공 실사 직후
  실행 순서 : ① 이 파일 실행 → ② 쿼리 A 판정 확인
              → ③ '1.평가 차이' 면 재고평가 재실행 후 ① 부터 다시
              → ④ '3.재공 차이' 면 재공조정(LWIPIO) 후 ① 부터 다시
              → ⑤ '0.정상' 이 나온 뒤에 원가계산 SP 실행

  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 평가 테이블 실존
     SELECT name FROM sys.tables
     WHERE name IN ('LINV_MVFIFO','LINV_MVFIFO_WK','LINV_TAV','LINVINSP_WIP','LINV_WIP');

  -- (2) GAP 컬럼 실존  ★ P-09 의 핵심
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('LINV_MVFIFO_WK')
       AND name LIKE '%GAP%';
     --> OPEN_AM_GAP / RCV_AM_GAP / RCVT_AM_GAP 이 없으면 사이트가 다른 방식으로 검증한다.
        컬럼명이 다르면 1번 블록을 수정할 것.

  -- (3) 기수(GISU) 확인  ★ 평가 범위의 핵심 키
     SELECT GISU, SMM, FMM, COUNT(*) FROM LINV_MVFIFO
     WHERE CO_CD='1000' GROUP BY GISU, SMM, FMM ORDER BY GISU DESC;

  -- (4) 재공 실사 컬럼  ★ 본 쿼리는 자동 탐색한다
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('LINVINSP_WIP') ORDER BY column_id;
     --> 실사수량 후보 : INSP_QT, REAL_QT, MGMT_QT, ITEM_QT
        실사일자 후보 : INSP_DT, IO_DT, CHK_DT, REG_DT

  -- (5) 재공 실사 운영 여부
     SELECT COUNT(*) FROM LINVINSP_WIP WHERE CO_CD='1000';
     --> 0 이면 재공 실사를 하지 않는 사이트다. M-09(쿼리 D·E)는 건너뛰고 P-09 만 쓸 것.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **GAP 컬럼의 의미는 사이트 원가 담당자에게 확인해야 한다.** 본 쿼리는
     `OPEN_AM_GAP + RCV_AM_GAP + RCVT_AM_GAP` 을 차이합계로 본다. 평가 로직에 따라
     일부 GAP 이 정상 값(의도된 조정)일 수 있으므로, 처음 도입할 때 담당자와 함께
     쿼리 B 의 상위 몇 건을 확인해 임계값(@TH_AM)을 조정할 것.

  2) **평가 전후 수량 대사(쿼리 C)는 범위가 정확히 맞아야 의미가 있다.**
     `LINVTORY` 는 `P_YR` 기준, `LINV_MVFIFO` 는 `GISU`+`SMM~FMM` 기준이라 기간 정의가 다르다.
     연 단위로 전 기간을 평가하는 사이트가 아니면 불일치가 대량으로 나온다.
     그 경우 @SMM/@FMM 을 평가 범위에 맞춰 지정하고, `LINVTORY` 쪽도 같은 기간으로 좁혀야 한다.

  3) 재공 실사는 **공정(WH_CD) + 품목** 단위로만 비교한다. 작업장(LC_CD)이나 지시(WO_CD)
     단위로 실사하는 사이트는 그 축을 추가해야 한다.

  4) 이 리포트는 차이를 **찾기만 한다.** 조정 전표를 만들지 않는다. 재공조정은
     `LWIPIO`(WIP_NB='WA'), 재고조정은 `LADJUST` 로 현업이 직접 처리해야 한다.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   C07_원가차수_마감점검.sql    : 이 점검을 통과한 뒤 차수를 마감한다
   M04_공정별재공_현황.sql      : 재공 상세 (쿼리 G 에 간이 실사 대비 포함)
   P03_실시간재고_추적.sql      : 평가 전 재고 (마이너스 재고 점검)
   C03_제품별_원가구성.sql      : 평가 결과가 반영되는 곳
   재고수불_뷰테이블_레퍼런스.md : 평가 계열 테이블 컬럼 명세
==============================================================================================*/
