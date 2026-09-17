/*==============================================================================================
  [ iCUBE ] P-04 재고자산 수불부  +  P-06 재고회전율 · 체화(ABC) 분석                (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : **평가 후 금액 기준** 재고자산 수불부(기초-입고-출고-기말)를 내고,
         그 위에서 회전율·ABC·체화를 분석한다.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ P-03 과의 차이 ]
  ----------------------------------------------------------------------------------------------
     `P03_실시간재고_추적.sql` 은 **수량** 기준 실시간 조회다 (평가 전, 창고·장소·LOT).
     이 파일은 **금액** 기준 회계 관점이다 (평가 후 `LINV_MVFIFO`).
     재고자산 명세서·회전율·ABC 는 금액이 있어야 성립하므로 평가 후 테이블을 쓴다.

  ----------------------------------------------------------------------------------------------
  [ ★ GRP_FG × IO_FG 1차 분류 — 수불부의 뼈대 ]
  ----------------------------------------------------------------------------------------------
     IO_FG   0.기초  1.입고  2.출고
     GRP_FG  0.생산  2.구매입고  3.매출출고  5.재고이동  6.조정/해체/이월

     이 두 축의 조합이 수불 유형이다. 예)
       GRP_FG='2' + IO_FG='1'  구매입고     GRP_FG='0' + IO_FG='2'  생산출고(자재투입)
       GRP_FG='0' + IO_FG='1'  생산입고     GRP_FG='3' + IO_FG='2'  매출출고
       GRP_FG='5'              재고이동(내부 — 총량 불변)  GRP_FG='6'  조정·이월

  ----------------------------------------------------------------------------------------------
  [ 산식 ]
  ----------------------------------------------------------------------------------------------
     기말재고 = 기초 + 입고 - 출고
     재고회전율 = 연환산 출고금액 / 평균재고금액        (회/년)
     재고회전일수 = 365 / 회전율
     ABC 등급 = 출고금액 누적구성비 기준 (A 70%, B 90%, C 나머지)
     체화 = @DEAD_MM 개월 무출고
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
    ,@GISU     INT          = NULL            -- 기수 (NULL = 최신)
    ,@BASE_DT  NVARCHAR(8)  = N'20260916'
    ,@ITEM_CD  NVARCHAR(25) = NULL
    ,@ACCT_FG  NVARCHAR(1)  = NULL
    ,@DEAD_MM  INT          = 6               -- 체화 판정 무출고 개월수
    ,@A_PCT    DECIMAL(5,1) = 70.0            -- ABC A등급 누적구성비
    ,@B_PCT    DECIMAL(5,1) = 90.0            -- B등급
    ,@TGT_TURN DECIMAL(5,1) = 12.0            -- 목표 회전율 (회/년)
;

DECLARE @SQL NVARCHAR(MAX);
DECLARE @HAS_FIFO BIT = 0, @SRC NVARCHAR(20) = N'없음';
DECLARE @DAYS INT = DATEDIFF(DAY, CONVERT(DATE, LEFT(@BASE_DT,4)+N'0101'), CONVERT(DATE,@BASE_DT)) + 1;

IF OBJECT_ID('tempdb..#MV')  IS NOT NULL DROP TABLE #MV;
IF OBJECT_ID('tempdb..#LAST') IS NOT NULL DROP TABLE #LAST;

CREATE TABLE #MV (
     ITEM_CD  NVARCHAR(25)
    ,OPEN_QT  DECIMAL(19,6), OPEN_AM  DECIMAL(19,4)
    ,RCV_QT   DECIMAL(19,6), RCV_AM   DECIMAL(19,4)
    ,RCVT_QT  DECIMAL(19,6), RCVT_AM  DECIMAL(19,4)
    ,ISU_QT   DECIMAL(19,6), ISU_AM   DECIMAL(19,4)
    ,TRNS_QT  DECIMAL(19,6), TRNS_AM  DECIMAL(19,4)
    ,INV_QT   DECIMAL(19,6), INV_AM   DECIMAL(19,4)
);


/*==============================================================================================
  1. #MV : 평가 후 수불 (LINV_MVFIFO)
==============================================================================================*/
IF OBJECT_ID(N'dbo.LINV_MVFIFO', N'U') IS NOT NULL
BEGIN
    IF @GISU IS NULL
    BEGIN
        SET @SQL = N'SELECT @o = MAX(GISU) FROM dbo.LINV_MVFIFO WITH (NOLOCK)
                     WHERE CO_CD = @p_CO AND (@p_DIV IS NULL OR DIV_CD = @p_DIV)';
        BEGIN TRY
            EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @o INT OUTPUT'
                ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @o=@GISU OUTPUT;
        END TRY BEGIN CATCH END CATCH
    END

    SET @SQL = N'
        INSERT INTO #MV (ITEM_CD, OPEN_QT, OPEN_AM, RCV_QT, RCV_AM, RCVT_QT, RCVT_AM,
                         ISU_QT, ISU_AM, TRNS_QT, TRNS_AM, INV_QT, INV_AM)
        SELECT F.ITEM_CD
              ,SUM(CAST(ISNULL(F.OPEN_QT,0) AS DECIMAL(19,6))), SUM(CAST(ISNULL(F.OPEN_AM,0) AS DECIMAL(19,4)))
              ,SUM(CAST(ISNULL(F.RCV_QT ,0) AS DECIMAL(19,6))), SUM(CAST(ISNULL(F.RCV_AM ,0) AS DECIMAL(19,4)))
              ,SUM(CAST(ISNULL(F.RCVT_QT,0) AS DECIMAL(19,6))), SUM(CAST(ISNULL(F.RCVT_AM,0) AS DECIMAL(19,4)))
              ,SUM(CAST(ISNULL(F.ISU_QT ,0) AS DECIMAL(19,6))), SUM(CAST(ISNULL(F.ISU_AM ,0) AS DECIMAL(19,4)))
              ,SUM(CAST(ISNULL(F.TRNS_QT,0) AS DECIMAL(19,6))), SUM(CAST(ISNULL(F.TRNS_AM,0) AS DECIMAL(19,4)))
              ,SUM(CAST(ISNULL(F.INV_QT ,0) AS DECIMAL(19,6))), SUM(CAST(ISNULL(F.INV_AM ,0) AS DECIMAL(19,4)))
        FROM   dbo.LINV_MVFIFO F WITH (NOLOCK)
        WHERE  F.CO_CD = @p_CO
          AND  (@p_GI   IS NULL OR F.GISU    = @p_GI)
          AND  (@p_DIV  IS NULL OR F.DIV_CD  = @p_DIV)
          AND  (@p_ITEM IS NULL OR F.ITEM_CD = @p_ITEM)
        GROUP BY F.ITEM_CD';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_GI INT, @p_ITEM NVARCHAR(25)'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_GI=@GISU, @p_ITEM=@ITEM_CD;
        SET @HAS_FIFO = 1;
        SET @SRC = N'LINV_MVFIFO';
        PRINT N'[1] LINV_MVFIFO (GISU=' + ISNULL(CAST(@GISU AS NVARCHAR(10)),N'전체') + N') : '
              + CAST((SELECT COUNT(*) FROM #MV) AS NVARCHAR(20)) + N' 품목';
    END TRY
    BEGIN CATCH PRINT N'[1] ★ LINV_MVFIFO 조회 실패 : ' + ERROR_MESSAGE(); END CATCH
END

-- 대체 : 평가 전 원장 + 단가 (금액 근사)
IF @HAS_FIFO = 0
BEGIN
    INSERT INTO #MV (ITEM_CD, OPEN_QT, OPEN_AM, RCV_QT, RCV_AM, RCVT_QT, RCVT_AM,
                     ISU_QT, ISU_AM, TRNS_QT, TRNS_AM, INV_QT, INV_AM)
    SELECT
         V.ITEM_CD
        ,SUM(CAST(ISNULL(V.IOPEN_QT,0) AS DECIMAL(19,6))), 0
        ,SUM(CASE WHEN V.IO_FG=N'1' AND ISNULL(V.GRP_FG,N'')<>N'5'
                  THEN CAST(ISNULL(V.IRCV_QT,0) AS DECIMAL(19,6)) ELSE 0 END), 0
        ,SUM(CASE WHEN V.IO_FG=N'1' AND ISNULL(V.GRP_FG,N'')=N'5'
                  THEN CAST(ISNULL(V.IRCV_QT,0) AS DECIMAL(19,6)) ELSE 0 END), 0
        ,SUM(CASE WHEN V.IO_FG=N'2' AND ISNULL(V.GRP_FG,N'')<>N'5'
                  THEN CAST(ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)) ELSE 0 END), 0
        ,SUM(CASE WHEN V.IO_FG=N'2' AND ISNULL(V.GRP_FG,N'')=N'5'
                  THEN CAST(ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)) ELSE 0 END), 0
        ,SUM(CAST(ISNULL(V.IOPEN_QT,0)+ISNULL(V.IRCV_QT,0)-ISNULL(V.IISU_QT,0) AS DECIMAL(19,6))), 0
    FROM   LINVTORY V WITH (NOLOCK)
    WHERE  V.CO_CD = @CO_CD AND V.P_YR = @P_YR AND V.IO_DT <= @BASE_DT
      AND  ISNULL(V.USE_YN, N'1') = N'1' AND ISNULL(V.EXPIRE_YN, N'1') = N'1'
      AND  (@DIV_CD  IS NULL OR V.DIV_CD  = @DIV_CD)
      AND  (@ITEM_CD IS NULL OR V.ITEM_CD = @ITEM_CD)
    GROUP BY V.ITEM_CD;

    -- 금액은 단가를 곱해 근사
    UPDATE M SET
         OPEN_AM = CAST(M.OPEN_QT * ISNULL(U.UM,0) AS DECIMAL(19,4))
        ,RCV_AM  = CAST(M.RCV_QT  * ISNULL(U.UM,0) AS DECIMAL(19,4))
        ,ISU_AM  = CAST(M.ISU_QT  * ISNULL(U.UM,0) AS DECIMAL(19,4))
        ,INV_AM  = CAST(M.INV_QT  * ISNULL(U.UM,0) AS DECIMAL(19,4))
    FROM #MV M
    LEFT JOIN ( SELECT I.ITEM_CD, UM = CAST(ISNULL(NULLIF(I.STD_UM,0), I.PUR_UM) AS DECIMAL(19,6))
                FROM SITEM I WITH (NOLOCK) WHERE I.CO_CD = @CO_CD ) U ON U.ITEM_CD = M.ITEM_CD;

    SET @SRC = N'LINVTORY(금액 근사)';
    PRINT N'[1] 대체 : LINVTORY + 마스터 단가 (금액은 근사치)';
END

CREATE CLUSTERED INDEX IX_MV ON #MV (ITEM_CD);

-- 계정 필터
IF @ACCT_FG IS NOT NULL
    DELETE M FROM #MV M
    LEFT JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = M.ITEM_CD
    WHERE ISNULL(I.ACCT_FG, N'') <> @ACCT_FG;

-- 단종품 제외
DELETE M FROM #MV M
LEFT JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = M.ITEM_CD
WHERE ISNULL(I.S_CD, N'') = N'Z00';


/*==============================================================================================
  2. #LAST : 최종 출고일 (체화 판정)
==============================================================================================*/
SELECT
     V.ITEM_CD
    ,LAST_ISU = MAX(CASE WHEN V.IO_FG = N'2' AND ISNULL(V.GRP_FG,N'') <> N'5' THEN V.IO_DT END)
    ,LAST_RCV = MAX(CASE WHEN V.IO_FG = N'1' THEN V.IO_DT END)
    ,ISU6_QT  = SUM(CASE WHEN V.IO_FG = N'2' AND ISNULL(V.GRP_FG,N'') <> N'5'
                          AND V.IO_DT >= CONVERT(NVARCHAR(8), DATEADD(MONTH,-@DEAD_MM,CONVERT(DATE,@BASE_DT)), 112)
                         THEN CAST(ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
INTO #LAST
FROM   LINVTORY V WITH (NOLOCK)
WHERE  V.CO_CD = @CO_CD AND V.IO_DT <= @BASE_DT
  AND  ISNULL(V.USE_YN, N'1') = N'1' AND ISNULL(V.EXPIRE_YN, N'1') = N'1'
  AND  (@DIV_CD IS NULL OR V.DIV_CD = @DIV_CD)
GROUP BY V.ITEM_CD;
CREATE CLUSTERED INDEX IX_LAST ON #LAST (ITEM_CD);


/*==============================================================================================
  ** 쿼리 A : 재고자산 수불부  (P-04 메인)
==============================================================================================*/
SELECT
     N'[A] 재고자산 수불부'                         AS REPORT_NM
    ,소스 = @SRC
    ,M.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
    -- 기초
    ,M.OPEN_QT                                      AS 기초수량
    ,M.OPEN_AM                                      AS 기초금액
    ,기초단가 = CAST(M.OPEN_AM / NULLIF(M.OPEN_QT, 0) AS DECIMAL(19,4))
    -- 입고
    ,M.RCV_QT                                       AS 입고수량
    ,M.RCV_AM                                       AS 입고금액
    ,입고단가 = CAST(M.RCV_AM / NULLIF(M.RCV_QT, 0) AS DECIMAL(19,4))
    ,M.RCVT_QT                                      AS 대체입고수량
    ,M.RCVT_AM                                      AS 대체입고금액
    -- 출고
    ,M.ISU_QT                                       AS 출고수량
    ,M.ISU_AM                                       AS 출고금액
    ,출고단가 = CAST(M.ISU_AM / NULLIF(M.ISU_QT, 0) AS DECIMAL(19,4))
    ,M.TRNS_QT                                      AS 대체출고수량
    ,M.TRNS_AM                                      AS 대체출고금액
    -- 기말
    ,M.INV_QT                                       AS 기말수량
    ,M.INV_AM                                       AS 기말금액
    ,기말단가 = CAST(M.INV_AM / NULLIF(M.INV_QT, 0) AS DECIMAL(19,4))
    -- 검증
    ,수량검증 = M.OPEN_QT + M.RCV_QT + M.RCVT_QT - M.ISU_QT - M.TRNS_QT - M.INV_QT
    ,금액검증 = M.OPEN_AM + M.RCV_AM + M.RCVT_AM - M.ISU_AM - M.TRNS_AM - M.INV_AM
    ,판정 = CASE
         WHEN ABS(M.OPEN_QT + M.RCV_QT + M.RCVT_QT - M.ISU_QT - M.TRNS_QT - M.INV_QT) > 0.000001
              THEN N'1.★수량 불일치 (기초+입고-출고 ≠ 기말)'
         WHEN @HAS_FIFO = 1
          AND ABS(M.OPEN_AM + M.RCV_AM + M.RCVT_AM - M.ISU_AM - M.TRNS_AM - M.INV_AM) > 1
              THEN N'2.★금액 불일치 - 평가 재실행 필요 (P-09)'
         WHEN M.INV_QT < 0                                   THEN N'3.★마이너스 재고'
         ELSE N'0.정상' END
FROM       #MV   M
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = M.ITEM_CD
WHERE  M.OPEN_QT <> 0 OR M.RCV_QT <> 0 OR M.ISU_QT <> 0 OR M.INV_QT <> 0
ORDER BY 판정, M.INV_AM DESC
;


/*==============================================================================================
  ** 쿼리 B : 수불 유형별 집계  (GRP_FG × IO_FG)  ★ 수불부의 뼈대
==============================================================================================*/
SELECT
     N'[B] 수불유형별 집계'                         AS REPORT_NM
    ,수불유형 = CASE
         WHEN V.IO_FG = N'0'                          THEN N'0.기초'
         WHEN V.GRP_FG = N'2' AND V.IO_FG = N'1'      THEN N'1.구매입고'
         WHEN V.GRP_FG = N'0' AND V.IO_FG = N'1'      THEN N'2.생산입고'
         WHEN V.GRP_FG = N'0' AND V.IO_FG = N'2'      THEN N'3.생산출고(자재투입)'
         WHEN V.GRP_FG = N'3' AND V.IO_FG = N'2'      THEN N'4.매출출고'
         WHEN V.GRP_FG = N'5'                         THEN N'5.재고이동(내부)'
         WHEN V.GRP_FG = N'6'                         THEN N'6.조정·해체·이월'
         ELSE N'9.기타 GRP_FG=' + ISNULL(V.GRP_FG,N'?') + N'/IO_FG=' + ISNULL(V.IO_FG,N'?') END
    ,V.GRP_FG                                       AS 수불그룹코드
    ,V.IO_FG                                        AS 입출구분코드
    ,건수 = COUNT(*)
    ,품목수 = COUNT(DISTINCT V.ITEM_CD)
    ,입고수량 = SUM(CAST(ISNULL(V.IRCV_QT,0) AS DECIMAL(19,6)))
    ,출고수량 = SUM(CAST(ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)))
    ,기초수량 = SUM(CAST(ISNULL(V.IOPEN_QT,0) AS DECIMAL(19,6)))
    ,최초일자 = MIN(V.IO_DT)
    ,최종일자 = MAX(V.IO_DT)
    ,비고 = CASE
         WHEN V.GRP_FG = N'5' THEN N'내부 이동 - 총 재고량은 변하지 않는다'
         WHEN V.GRP_FG = N'6' THEN N'조정/이월 - 원인 확인 필요 (P-10)'
         ELSE N'-' END
FROM   LINVTORY V WITH (NOLOCK)
WHERE  V.CO_CD = @CO_CD AND V.P_YR = @P_YR AND V.IO_DT <= @BASE_DT
  AND  ISNULL(V.USE_YN, N'1') = N'1' AND ISNULL(V.EXPIRE_YN, N'1') = N'1'
  AND  (@DIV_CD  IS NULL OR V.DIV_CD  = @DIV_CD)
  AND  (@ITEM_CD IS NULL OR V.ITEM_CD = @ITEM_CD)
GROUP BY V.GRP_FG, V.IO_FG
ORDER BY 수불유형
;


/*==============================================================================================
  ** 쿼리 C : 재고회전율 · ABC 등급  (P-06 메인)
==============================================================================================*/
;WITH X AS (
    SELECT
         M.ITEM_CD
        ,M.OPEN_AM, M.INV_AM, M.ISU_AM, M.ISU_QT, M.INV_QT
        ,AVG_AM = (M.OPEN_AM + M.INV_AM) / 2.0
        ,TURN = CASE WHEN (M.OPEN_AM + M.INV_AM) / 2.0 <> 0
                     THEN M.ISU_AM * (365.0 / NULLIF(@DAYS, 0)) / ((M.OPEN_AM + M.INV_AM) / 2.0) END
        ,CUM = SUM(M.ISU_AM) OVER (ORDER BY M.ISU_AM DESC
                                   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        ,TOT = SUM(M.ISU_AM) OVER ()
    FROM   #MV M
)
SELECT
     N'[C] 재고회전율 · ABC'                        AS REPORT_NM
    ,ABC등급 = CASE
         WHEN X.TOT = 0                          THEN N'C'
         WHEN X.CUM / X.TOT * 100 <= @A_PCT      THEN N'A'
         WHEN X.CUM / X.TOT * 100 <= @B_PCT      THEN N'B'
         ELSE N'C' END
    ,X.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
    ,X.OPEN_AM                                      AS 기초금액
    ,X.INV_AM                                       AS 기말금액
    ,평균재고금액 = CAST(X.AVG_AM AS DECIMAL(19,4))
    ,X.ISU_AM                                       AS 출고금액
    ,X.ISU_QT                                       AS 출고수량
    ,X.INV_QT                                       AS 기말수량
    ,회전율 = CAST(X.TURN AS DECIMAL(9,2))
    ,회전일수 = CAST(CASE WHEN X.TURN > 0 THEN 365.0 / X.TURN END AS DECIMAL(9,1))
    ,출고금액구성비_PCT = CAST(X.ISU_AM * 100.0 / NULLIF(X.TOT, 0) AS DECIMAL(5,1))
    ,누적구성비_PCT = CAST(X.CUM * 100.0 / NULLIF(X.TOT, 0) AS DECIMAL(5,1))
    ,L.LAST_ISU                                     AS 최종출고일
    ,무출고일수 = CASE WHEN L.LAST_ISU IS NOT NULL
                       THEN DATEDIFF(DAY, CONVERT(DATE,L.LAST_ISU), CONVERT(DATE,@BASE_DT))
                       ELSE 9999 END
    ,판정 = CASE
         WHEN X.INV_AM = 0                                                THEN N'9.재고 없음'
         WHEN ISNULL(L.ISU6_QT, 0) = 0
              THEN N'1.★체화 (' + CAST(@DEAD_MM AS NVARCHAR(5)) + N'개월 무출고)'
         WHEN X.TURN IS NULL                                              THEN N'8.회전율 산출 불가'
         WHEN X.TURN < 1                                                  THEN N'2.★회전 1회 미만 (1년치 초과 보유)'
         WHEN X.TURN < @TGT_TURN / 2                                      THEN N'3.회전 부진'
         WHEN X.TURN >= @TGT_TURN                                         THEN N'0.양호'
         ELSE N'4.보통' END
FROM       X
LEFT  JOIN #LAST L ON L.ITEM_CD = X.ITEM_CD
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = X.ITEM_CD
ORDER BY ABC등급, X.ISU_AM DESC
;


/*==============================================================================================
  ** 쿼리 D : ABC 등급별 요약  (파레토)
==============================================================================================*/
;WITH X AS (
    SELECT
         M.ITEM_CD, M.ISU_AM, M.INV_AM
        ,CUM = SUM(M.ISU_AM) OVER (ORDER BY M.ISU_AM DESC
                                   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        ,TOT = SUM(M.ISU_AM) OVER ()
    FROM #MV M
), G AS (
    SELECT
         GRD = CASE WHEN X.TOT = 0 THEN N'C'
                    WHEN X.CUM / X.TOT * 100 <= @A_PCT THEN N'A'
                    WHEN X.CUM / X.TOT * 100 <= @B_PCT THEN N'B' ELSE N'C' END
        ,X.*
    FROM X
)
SELECT
     N'[D] ABC 등급별 요약'                         AS REPORT_NM
    ,G.GRD                                          AS 등급
    ,품목수 = COUNT(*)
    ,품목수비중_PCT = CAST(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0) AS DECIMAL(5,1))
    ,출고금액 = SUM(G.ISU_AM)
    ,출고금액비중_PCT = CAST(SUM(G.ISU_AM) * 100.0
                             / NULLIF(SUM(SUM(G.ISU_AM)) OVER (), 0) AS DECIMAL(5,1))
    ,기말재고금액 = SUM(G.INV_AM)
    ,재고금액비중_PCT = CAST(SUM(G.INV_AM) * 100.0
                             / NULLIF(SUM(SUM(G.INV_AM)) OVER (), 0) AS DECIMAL(5,1))
    ,관리방침 = CASE G.GRD
         WHEN N'A' THEN N'중점 관리 - 안전재고 정밀 설정, 발주 주기 단축, 결품 절대 방지'
         WHEN N'B' THEN N'표준 관리 - 정기 발주, 안전재고 유지'
         ELSE           N'간소 관리 - 일괄 발주, 재고 축소 검토' END
    ,비고 = CASE WHEN G.GRD = N'C'
                  AND SUM(G.INV_AM) * 100.0 / NULLIF(SUM(SUM(G.INV_AM)) OVER (), 0) > 30
                 THEN N'★ C등급이 재고금액의 30% 초과 - 자금이 저회전 품목에 묶여 있다'
                 ELSE N'-' END
FROM   G
GROUP BY G.GRD
ORDER BY G.GRD
;


/*==============================================================================================
  ** 쿼리 E : 체화 재고 (금액순)  ★ 자금이 잠긴 곳
==============================================================================================*/
SELECT TOP 100
     N'[E] 체화 재고'                               AS REPORT_NM
    ,체화등급 = CASE
         WHEN ISNULL(L.LAST_ISU, N'') = N''                                   THEN N'1.★출고 이력 없음'
         WHEN DATEDIFF(DAY,CONVERT(DATE,L.LAST_ISU),CONVERT(DATE,@BASE_DT)) > 730 THEN N'2.★2년 초과'
         WHEN DATEDIFF(DAY,CONVERT(DATE,L.LAST_ISU),CONVERT(DATE,@BASE_DT)) > 365 THEN N'3.★1년 초과'
         ELSE N'4.' + CAST(@DEAD_MM AS NVARCHAR(5)) + N'개월 초과' END
    ,M.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
    ,M.INV_QT                                       AS 기말수량
    ,M.INV_AM                                       AS 기말금액
    ,단가 = CAST(M.INV_AM / NULLIF(M.INV_QT, 0) AS DECIMAL(19,4))
    ,L.LAST_ISU                                     AS 최종출고일
    ,L.LAST_RCV                                     AS 최종입고일
    ,무출고일수 = CASE WHEN L.LAST_ISU IS NOT NULL
                       THEN DATEDIFF(DAY, CONVERT(DATE,L.LAST_ISU), CONVERT(DATE,@BASE_DT)) END
    ,입고후경과일 = CASE WHEN L.LAST_RCV IS NOT NULL
                         THEN DATEDIFF(DAY, CONVERT(DATE,L.LAST_RCV), CONVERT(DATE,@BASE_DT)) END
    ,단종여부 = CASE WHEN ISNULL(I.S_CD, N'') = N'Z00' THEN N'★단종품' ELSE N'-' END
    ,조치 = CASE
         WHEN ISNULL(I.S_CD, N'') = N'Z00'
              THEN N'★ 단종품 재고 - 폐기 또는 대체 사용 검토'
         WHEN ISNULL(L.LAST_ISU, N'') = N''
              THEN N'★ 한 번도 나간 적 없음 - 구매 사유 확인'
         WHEN L.LAST_RCV > L.LAST_ISU
              THEN N'★ 안 나가는데 또 샀다 - 발주 통제 필요 (P-05)'
         ELSE N'실사 확인 후 처분/재사용 판단' END
FROM       #MV   M
LEFT  JOIN #LAST L ON L.ITEM_CD = M.ITEM_CD
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = M.ITEM_CD
WHERE  M.INV_QT > 0
  AND  ISNULL(L.ISU6_QT, 0) = 0
ORDER BY M.INV_AM DESC
;


/*==============================================================================================
  ** 쿼리 F : 전사 요약
==============================================================================================*/
SELECT
     N'[F] 재고자산 요약'                           AS REPORT_NM
    ,@P_YR                                          AS 회계연도
    ,소스 = @SRC
    ,기수 = ISNULL(CAST(@GISU AS NVARCHAR(10)), N'전체')
    ,@TGT_TURN                                      AS 목표회전율
    ,품목수 = COUNT(*)
    ,기초금액계 = SUM(M.OPEN_AM)
    ,입고금액계 = SUM(M.RCV_AM)
    ,출고금액계 = SUM(M.ISU_AM)
    ,기말금액계 = SUM(M.INV_AM)
    ,평균재고금액 = CAST((SUM(M.OPEN_AM) + SUM(M.INV_AM)) / 2.0 AS DECIMAL(19,4))
    ,전사회전율 = CAST(SUM(M.ISU_AM) * (365.0 / NULLIF(@DAYS,0))
                       / NULLIF((SUM(M.OPEN_AM) + SUM(M.INV_AM)) / 2.0, 0) AS DECIMAL(9,2))
    ,전사회전일수 = CAST(365.0 / NULLIF(SUM(M.ISU_AM) * (365.0 / NULLIF(@DAYS,0))
                         / NULLIF((SUM(M.OPEN_AM)+SUM(M.INV_AM))/2.0, 0), 0) AS DECIMAL(9,1))
    ,체화품목수 = SUM(CASE WHEN M.INV_QT > 0 AND ISNULL(L.ISU6_QT,0) = 0 THEN 1 ELSE 0 END)
    ,체화금액   = SUM(CASE WHEN M.INV_QT > 0 AND ISNULL(L.ISU6_QT,0) = 0 THEN M.INV_AM ELSE 0 END)
    ,체화비율_PCT = CAST(SUM(CASE WHEN M.INV_QT > 0 AND ISNULL(L.ISU6_QT,0) = 0
                                  THEN M.INV_AM ELSE 0 END) * 100.0
                         / NULLIF(SUM(M.INV_AM), 0) AS DECIMAL(5,1))
    ,마이너스품목수 = SUM(CASE WHEN M.INV_QT < 0 THEN 1 ELSE 0 END)
    ,판정 = CASE
         WHEN @HAS_FIFO = 0
              THEN N'9.★평가 후 테이블 없음 - 금액은 마스터 단가 근사치다'
         WHEN SUM(CASE WHEN M.INV_QT > 0 AND ISNULL(L.ISU6_QT,0) = 0 THEN M.INV_AM ELSE 0 END)
              / NULLIF(SUM(M.INV_AM), 0) > 0.3
              THEN N'1.★체화 재고가 30% 초과 - 자금 효율 저하'
         WHEN SUM(M.ISU_AM) * (365.0/NULLIF(@DAYS,0))
              / NULLIF((SUM(M.OPEN_AM)+SUM(M.INV_AM))/2.0, 0) < @TGT_TURN
              THEN N'2.목표 회전율 미달'
         ELSE N'0.정상' END
FROM       #MV   M
LEFT  JOIN #LAST L ON L.ITEM_CD = M.ITEM_CD
;


DROP TABLE #MV, #LAST;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 평가 후 테이블  ★ 금액 기준 분석의 전제
     SELECT name FROM sys.tables WHERE name IN ('LINV_MVFIFO','LINV_MVFIFO_WK','CIV_TAV');
     SELECT GISU, COUNT(*), SUM(INV_AM) FROM LINV_MVFIFO
     WHERE CO_CD='1000' GROUP BY GISU ORDER BY GISU DESC;
     --> 없으면 금액이 마스터 단가 근사치가 되어 회전율·ABC 가 부정확하다.

  -- (2) 평가 정합성  ★ 금액을 믿어도 되는지
     --> P09_재고정합성_점검.sql 을 먼저 돌려 GAP 이 0 인지 확인할 것.
        GAP 이 남은 상태의 금액으로 ABC 를 매기면 등급이 틀어진다.

  -- (3) GRP_FG × IO_FG 실분포  ★ 쿼리 B 의 라벨이 맞는지
     SELECT GRP_FG, IO_FG, COUNT(*) FROM LINVTORY
     WHERE CO_CD='1000' AND P_YR='2026' GROUP BY GRP_FG, IO_FG ORDER BY 1,2;
     --> '9.기타' 로 빠지는 조합이 많으면 쿼리 B 의 CASE 를 보강할 것.

  -- (4) 목표 회전율  ★ @TGT_TURN(12회) 은 EIS 기본값이다
     --> 업종별로 크게 다르다. 쿼리 F 로 현재 전사 회전율을 먼저 보고 조정할 것.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **평균재고를 (기초+기말)/2 로 계산**한다. 월별 잔고의 평균이 더 정확하지만, 그러려면
     월별 스냅샷이 필요하다. 계절 변동이 큰 품목은 회전율이 실제와 다를 수 있다.

  2) **평가 후 테이블이 없으면 금액이 근사치**다(`@SRC` 컬럼에 표시). 마스터 표준단가를
     곱한 값이라 실제 취득원가와 다르다. 이 상태의 금액은 **상대 비교(ABC 순위)에만** 쓰고
     절대 금액은 재무제표에 쓰지 말 것.

  3) ABC 는 **출고금액 기준**이다. 출고 빈도 기준(횟수)으로 매기는 방식도 있으며 결과가
     다르다. 저가·고빈도 품목은 금액 기준에서 C 로 밀리지만 관리는 자주 해야 한다.

  4) `체화` 판정은 출고 이력만 본다. 계절 상품(여름/겨울)은 비수기에 전부 체화로 잡히므로
     품목 특성을 감안해 해석할 것.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   P03_실시간재고_추적.sql   : 수량 기준 실시간 (평가 전, 창고·LOT)
   P09_재고정합성_점검.sql   : 평가 금액을 믿어도 되는지
   P05_재고알람_KPI.sql      : 체화와 과잉의 조치 (권장발주수량)
   C06_재고평가_현황.sql     : 평가 전/후 금액 비교
==============================================================================================*/
