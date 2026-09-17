/*==============================================================================================
  [ iCUBE ] C-06  재고평가 현황 (평가 전 / 후 비교)                                  (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 재고평가로 **금액이 어떻게 확정되었는가**를 본다.
         평가 전(수량만) → 평가 후(금액 확정) → 경리수불집계(회계 반영) 3단계를 나란히 놓는다.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ P-09 와의 차이 ]
  ----------------------------------------------------------------------------------------------
     `P09_재고정합성_점검.sql` 은 **점검**이다 — 틀린 곳을 찾아 마감을 막는다.
     이 파일은 **현황**이다 — 평가 결과를 읽고 단가·금액이 어떻게 정해졌는지 설명한다.
     평가가 끝난 뒤(P-09 통과 후) 결과를 보는 용도다.

  ----------------------------------------------------------------------------------------------
  [ 3계층 ]
  ----------------------------------------------------------------------------------------------
     LINVTORY      평가 전   수량만 확정. 금액 없음
     LINV_MVFIFO   평가 후   OPEN/RCV/RCVT/ISU/TRNS/INV 각각 QT·UM·AM
     LINV_TAV      기간 평가 GISU + SMM~FMM + ITEM_CD → ISU_UM (출고단가)
     CIV_TAV       경리수불  원가모듈이 회계에 넘기는 집계
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
    ,@GISU     INT          = NULL
    ,@ITEM_CD  NVARCHAR(25) = NULL
    ,@ACCT_FG  NVARCHAR(1)  = NULL
    ,@TH_AM    DECIMAL(19,4) = 1.0
;

DECLARE @SQL NVARCHAR(MAX);
DECLARE @HAS_FIFO BIT = 0, @HAS_TAV BIT = 0, @HAS_CIV BIT = 0;

IF OBJECT_ID('tempdb..#EV') IS NOT NULL DROP TABLE #EV;

CREATE TABLE #EV (
     ITEM_CD  NVARCHAR(25)
    -- 평가 전
    ,RAW_OPEN DECIMAL(19,6), RAW_RCV DECIMAL(19,6), RAW_ISU DECIMAL(19,6), RAW_INV DECIMAL(19,6)
    -- 평가 후
    ,EV_OPEN_QT DECIMAL(19,6), EV_OPEN_AM DECIMAL(19,4)
    ,EV_RCV_QT  DECIMAL(19,6), EV_RCV_AM  DECIMAL(19,4)
    ,EV_ISU_QT  DECIMAL(19,6), EV_ISU_AM  DECIMAL(19,4), EV_ISU_UM DECIMAL(19,6)
    ,EV_INV_QT  DECIMAL(19,6), EV_INV_AM  DECIMAL(19,4)
    -- 기간 평가단가
    ,TAV_UM   DECIMAL(19,6)
    -- 경리수불
    ,CIV_INV_AM DECIMAL(19,4)
);


/*==============================================================================================
  1. 적재
==============================================================================================*/
-- 평가 전
INSERT INTO #EV (ITEM_CD, RAW_OPEN, RAW_RCV, RAW_ISU, RAW_INV)
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
CREATE CLUSTERED INDEX IX_EV ON #EV (ITEM_CD);

-- 평가 후
IF OBJECT_ID(N'dbo.LINV_MVFIFO', N'U') IS NOT NULL
BEGIN
    IF @GISU IS NULL
    BEGIN
        SET @SQL = N'SELECT @o = MAX(GISU) FROM dbo.LINV_MVFIFO WITH (NOLOCK)
                     WHERE CO_CD = @p_CO AND (@p_DIV IS NULL OR DIV_CD = @p_DIV)';
        BEGIN TRY EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @o INT OUTPUT'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @o=@GISU OUTPUT; END TRY BEGIN CATCH END CATCH
    END

    SET @SQL = N'
        MERGE #EV AS T
        USING ( SELECT F.ITEM_CD
                      ,OQ=SUM(CAST(ISNULL(F.OPEN_QT,0) AS DECIMAL(19,6)))
                      ,OA=SUM(CAST(ISNULL(F.OPEN_AM,0) AS DECIMAL(19,4)))
                      ,RQ=SUM(CAST(ISNULL(F.RCV_QT ,0) AS DECIMAL(19,6)))
                      ,RA=SUM(CAST(ISNULL(F.RCV_AM ,0) AS DECIMAL(19,4)))
                      ,IQ=SUM(CAST(ISNULL(F.ISU_QT ,0) AS DECIMAL(19,6)))
                      ,IA=SUM(CAST(ISNULL(F.ISU_AM ,0) AS DECIMAL(19,4)))
                      ,IU=CAST(AVG(CAST(NULLIF(F.ISU_UM,0) AS DECIMAL(19,6))) AS DECIMAL(19,6))
                      ,NQ=SUM(CAST(ISNULL(F.INV_QT ,0) AS DECIMAL(19,6)))
                      ,NA=SUM(CAST(ISNULL(F.INV_AM ,0) AS DECIMAL(19,4)))
                FROM   dbo.LINV_MVFIFO F WITH (NOLOCK)
                WHERE  F.CO_CD = @p_CO
                  AND  (@p_GI   IS NULL OR F.GISU    = @p_GI)
                  AND  (@p_DIV  IS NULL OR F.DIV_CD  = @p_DIV)
                  AND  (@p_ITEM IS NULL OR F.ITEM_CD = @p_ITEM)
                GROUP BY F.ITEM_CD ) AS S ON S.ITEM_CD = T.ITEM_CD
        WHEN MATCHED THEN UPDATE SET
             EV_OPEN_QT=S.OQ, EV_OPEN_AM=S.OA, EV_RCV_QT=S.RQ, EV_RCV_AM=S.RA
            ,EV_ISU_QT =S.IQ, EV_ISU_AM =S.IA, EV_ISU_UM=S.IU
            ,EV_INV_QT =S.NQ, EV_INV_AM =S.NA
        WHEN NOT MATCHED THEN
             INSERT (ITEM_CD, RAW_OPEN, RAW_RCV, RAW_ISU, RAW_INV
                    ,EV_OPEN_QT, EV_OPEN_AM, EV_RCV_QT, EV_RCV_AM
                    ,EV_ISU_QT, EV_ISU_AM, EV_ISU_UM, EV_INV_QT, EV_INV_AM)
             VALUES (S.ITEM_CD, 0,0,0,0, S.OQ,S.OA,S.RQ,S.RA,S.IQ,S.IA,S.IU,S.NQ,S.NA);';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_GI INT, @p_ITEM NVARCHAR(25)'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_GI=@GISU, @p_ITEM=@ITEM_CD;
        SET @HAS_FIFO = 1;
        PRINT N'[1] LINV_MVFIFO 적재 (GISU=' + ISNULL(CAST(@GISU AS NVARCHAR(10)),N'전체') + N')';
    END TRY BEGIN CATCH PRINT N'[1] ★ LINV_MVFIFO 실패 : ' + ERROR_MESSAGE(); END CATCH
END

-- 기간 평가단가
IF OBJECT_ID(N'dbo.LINV_TAV', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
        UPDATE E SET TAV_UM = S.UM
        FROM #EV E
        INNER JOIN ( SELECT T.ITEM_CD
                          ,UM = CAST(AVG(CAST(NULLIF(T.ISU_UM,0) AS DECIMAL(19,6))) AS DECIMAL(19,6))
                     FROM   dbo.LINV_TAV T WITH (NOLOCK)
                     WHERE  T.CO_CD = @p_CO
                       AND  (@p_GI  IS NULL OR T.GISU   = @p_GI)
                       AND  (@p_DIV IS NULL OR T.DIV_CD = @p_DIV)
                     GROUP BY T.ITEM_CD ) S ON S.ITEM_CD = E.ITEM_CD';
    BEGIN TRY
        EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_GI INT'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_GI=@GISU;
        SET @HAS_TAV = 1;
    END TRY BEGIN CATCH END CATCH
END

-- 경리수불집계
IF OBJECT_ID(N'dbo.CIV_TAV', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
        UPDATE E SET CIV_INV_AM = S.AM
        FROM #EV E
        INNER JOIN ( SELECT C.ITEM_CD, AM = SUM(CAST(ISNULL(C.INV_AM,0) AS DECIMAL(19,4)))
                     FROM   dbo.CIV_TAV C WITH (NOLOCK)
                     WHERE  C.CO_CD = @p_CO AND C.P_YR = @p_YR
                       AND  (@p_DIV IS NULL OR C.DIV_CD = @p_DIV)
                     GROUP BY C.ITEM_CD ) S ON S.ITEM_CD = E.ITEM_CD';
    BEGIN TRY
        EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YR NVARCHAR(4)'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_YR=@P_YR;
        SET @HAS_CIV = 1;
    END TRY BEGIN CATCH END CATCH
END

-- 계정 필터 / 단종품 제외
DELETE E FROM #EV E
LEFT JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = E.ITEM_CD
WHERE ISNULL(I.S_CD, N'') = N'Z00'
   OR (@ACCT_FG IS NOT NULL AND ISNULL(I.ACCT_FG, N'') <> @ACCT_FG);


/*==============================================================================================
  ** 쿼리 A : 평가 전 / 후 비교  (메인)
==============================================================================================*/
SELECT
     N'[A] 평가 전 / 후 비교'                       AS REPORT_NM
    ,E.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
    -- 평가 전 (수량만)
    ,E.RAW_INV                                      AS 평가전_재고수량
    -- 평가 후
    ,E.EV_INV_QT                                    AS 평가후_재고수량
    ,E.EV_INV_AM                                    AS 평가후_재고금액
    ,평가단가 = CAST(E.EV_INV_AM / NULLIF(E.EV_INV_QT, 0) AS DECIMAL(19,4))
    ,E.EV_ISU_QT                                    AS 출고수량
    ,E.EV_ISU_AM                                    AS 출고금액
    ,E.EV_ISU_UM                                    AS 출고단가
    ,E.EV_RCV_QT                                    AS 입고수량
    ,E.EV_RCV_AM                                    AS 입고금액
    ,입고단가 = CAST(E.EV_RCV_AM / NULLIF(E.EV_RCV_QT, 0) AS DECIMAL(19,4))
    -- 기간 평가단가
    ,E.TAV_UM                                       AS 기간평가단가
    ,단가차이_PCT = CAST(CASE WHEN ISNULL(E.TAV_UM, 0) <> 0 AND E.EV_ISU_UM IS NOT NULL
                              THEN (E.EV_ISU_UM / E.TAV_UM - 1) * 100 END AS DECIMAL(9,2))
    -- 경리수불
    ,E.CIV_INV_AM                                   AS 경리수불_재고금액
    ,회계차이 = E.EV_INV_AM - ISNULL(E.CIV_INV_AM, 0)
    -- 마스터 단가 비교
    ,I.STD_UM                                       AS 마스터_표준단가
    ,표준대비_PCT = CAST(CASE WHEN ISNULL(I.STD_UM, 0) <> 0 AND E.EV_INV_QT <> 0
                              THEN (E.EV_INV_AM / E.EV_INV_QT / I.STD_UM - 1) * 100 END AS DECIMAL(9,1))
    ,판정 = CASE
         WHEN @HAS_FIFO = 0                                          THEN N'9.평가 미실행'
         WHEN E.EV_INV_QT IS NULL OR E.EV_INV_QT = 0
              AND E.RAW_INV <> 0                                     THEN N'1.★평가 대상에서 누락'
         WHEN ABS(E.RAW_INV - ISNULL(E.EV_INV_QT, 0)) > 0.000001      THEN N'2.★평가 전후 수량 불일치'
         WHEN E.EV_INV_QT <> 0 AND E.EV_INV_AM = 0                    THEN N'3.★수량은 있는데 금액 0'
         WHEN @HAS_CIV = 1
          AND ABS(E.EV_INV_AM - ISNULL(E.CIV_INV_AM, 0)) > @TH_AM     THEN N'4.★경리수불과 금액 불일치'
         ELSE N'0.정상' END
FROM       #EV   E
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = E.ITEM_CD
WHERE  E.RAW_INV <> 0 OR ISNULL(E.EV_INV_QT, 0) <> 0
ORDER BY 판정, E.EV_INV_AM DESC
;


/*==============================================================================================
  ** 쿼리 B : 계정구분별 재고자산 요약  (재무제표 대사용)
==============================================================================================*/
SELECT
     N'[B] 계정구분별 재고자산'                     AS REPORT_NM
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'1.원재료' WHEN N'1' THEN N'2.부재료'
                               WHEN N'2' THEN N'3.제품'   WHEN N'4' THEN N'4.반제품'
                               WHEN N'5' THEN N'5.상품'   ELSE N'9.' + ISNULL(I.ACCT_FG,N'?') END
    ,품목수 = COUNT(*)
    ,평가전_수량 = SUM(E.RAW_INV)
    ,평가후_수량 = SUM(ISNULL(E.EV_INV_QT, 0))
    ,수량차이 = SUM(E.RAW_INV) - SUM(ISNULL(E.EV_INV_QT, 0))
    ,기초금액 = SUM(ISNULL(E.EV_OPEN_AM, 0))
    ,입고금액 = SUM(ISNULL(E.EV_RCV_AM , 0))
    ,출고금액 = SUM(ISNULL(E.EV_ISU_AM , 0))
    ,기말금액 = SUM(ISNULL(E.EV_INV_AM , 0))
    ,경리수불금액 = SUM(ISNULL(E.CIV_INV_AM, 0))
    ,회계차이 = SUM(ISNULL(E.EV_INV_AM,0)) - SUM(ISNULL(E.CIV_INV_AM,0))
    ,금액구성비_PCT = CAST(SUM(ISNULL(E.EV_INV_AM,0)) * 100.0
                           / NULLIF(SUM(SUM(ISNULL(E.EV_INV_AM,0))) OVER (), 0) AS DECIMAL(5,1))
    ,수불검증 = SUM(ISNULL(E.EV_OPEN_AM,0)) + SUM(ISNULL(E.EV_RCV_AM,0))
              - SUM(ISNULL(E.EV_ISU_AM,0)) - SUM(ISNULL(E.EV_INV_AM,0))
    ,판정 = CASE
         WHEN ABS(SUM(E.RAW_INV) - SUM(ISNULL(E.EV_INV_QT,0))) > 0.001
              THEN N'1.★평가 전후 수량 불일치'
         WHEN @HAS_CIV = 1
          AND ABS(SUM(ISNULL(E.EV_INV_AM,0)) - SUM(ISNULL(E.CIV_INV_AM,0))) > @TH_AM
              THEN N'2.★경리수불과 불일치 - 회계 반영 확인'
         ELSE N'0.정상' END
FROM       #EV   E
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = E.ITEM_CD
GROUP BY I.ACCT_FG
ORDER BY 계정구분
;


/*==============================================================================================
  ** 쿼리 C : 평가단가 이상  ★ 단가가 튄 품목
==============================================================================================*/
SELECT
     N'[C] 평가단가 이상'                           AS REPORT_NM
    ,이상유형 = CASE
         WHEN E.EV_INV_QT <> 0 AND E.EV_INV_AM = 0        THEN N'1.★재고 있는데 금액 0'
         WHEN E.EV_INV_QT = 0 AND E.EV_INV_AM <> 0        THEN N'2.★수량 0 인데 금액 존재'
         WHEN E.EV_INV_AM < 0                             THEN N'3.★재고금액 음수'
         WHEN E.EV_INV_QT < 0                             THEN N'4.★재고수량 음수'
         WHEN ISNULL(I.STD_UM,0) <> 0 AND E.EV_INV_QT <> 0
          AND E.EV_INV_AM / E.EV_INV_QT > I.STD_UM * 3    THEN N'5.표준단가의 3배 초과'
         WHEN ISNULL(I.STD_UM,0) <> 0 AND E.EV_INV_QT <> 0
          AND E.EV_INV_AM / E.EV_INV_QT < I.STD_UM * 0.3  THEN N'6.표준단가의 30% 미만'
         ELSE N'7.기타' END
    ,E.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
    ,E.EV_INV_QT                                    AS 재고수량
    ,E.EV_INV_AM                                    AS 재고금액
    ,평가단가 = CAST(E.EV_INV_AM / NULLIF(E.EV_INV_QT, 0) AS DECIMAL(19,4))
    ,I.STD_UM                                       AS 표준단가
    ,E.EV_ISU_UM                                    AS 출고단가
    ,E.TAV_UM                                       AS 기간평가단가
    ,E.EV_RCV_QT                                    AS 입고수량
    ,입고단가 = CAST(E.EV_RCV_AM / NULLIF(E.EV_RCV_QT, 0) AS DECIMAL(19,4))
    ,원인추정 = CASE
         WHEN E.EV_INV_QT <> 0 AND E.EV_INV_AM = 0
              THEN N'입고 금액이 0 으로 등록됨 - 매입마감 확인 (P-01)'
         WHEN E.EV_INV_QT < 0
              THEN N'마이너스 재고 - 출고가 입고보다 먼저 (P-03)'
         WHEN E.EV_RCV_QT = 0 AND E.EV_INV_QT > 0
              THEN N'당기 입고 없이 기초 재고만 - 기초 금액 확인'
         ELSE N'입고 단가 이상 - 매입 단가 확인 (P-07)' END
FROM       #EV   E
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = E.ITEM_CD
WHERE  @HAS_FIFO = 1
  AND  ( (E.EV_INV_QT <> 0 AND E.EV_INV_AM = 0)
      OR (E.EV_INV_QT = 0 AND E.EV_INV_AM <> 0)
      OR E.EV_INV_AM < 0
      OR E.EV_INV_QT < 0
      OR (ISNULL(I.STD_UM,0) <> 0 AND E.EV_INV_QT <> 0
          AND (E.EV_INV_AM / E.EV_INV_QT > I.STD_UM * 3
            OR E.EV_INV_AM / E.EV_INV_QT < I.STD_UM * 0.3)) )
ORDER BY 이상유형, ABS(E.EV_INV_AM) DESC
;


/*==============================================================================================
  ** 쿼리 D : 전사 요약 + 데이터 점검
==============================================================================================*/
SELECT
     N'[D] 재고평가 요약'                           AS REPORT_NM
    ,@P_YR                                          AS 회계연도
    ,기수 = ISNULL(CAST(@GISU AS NVARCHAR(10)), N'전체')
    ,LINV_MVFIFO = CASE WHEN @HAS_FIFO = 1 THEN N'O' ELSE N'★X' END
    ,LINV_TAV    = CASE WHEN @HAS_TAV  = 1 THEN N'O' ELSE N'X' END
    ,CIV_TAV     = CASE WHEN @HAS_CIV  = 1 THEN N'O' ELSE N'X' END
    ,품목수 = COUNT(*)
    ,평가전_수량계 = SUM(E.RAW_INV)
    ,평가후_수량계 = SUM(ISNULL(E.EV_INV_QT, 0))
    ,기초금액계 = SUM(ISNULL(E.EV_OPEN_AM, 0))
    ,입고금액계 = SUM(ISNULL(E.EV_RCV_AM , 0))
    ,출고금액계 = SUM(ISNULL(E.EV_ISU_AM , 0))
    ,기말금액계 = SUM(ISNULL(E.EV_INV_AM , 0))
    ,경리수불계 = SUM(ISNULL(E.CIV_INV_AM, 0))
    ,회계차이   = SUM(ISNULL(E.EV_INV_AM,0)) - SUM(ISNULL(E.CIV_INV_AM,0))
    ,수불등식검증 = SUM(ISNULL(E.EV_OPEN_AM,0)) + SUM(ISNULL(E.EV_RCV_AM,0))
                  - SUM(ISNULL(E.EV_ISU_AM,0)) - SUM(ISNULL(E.EV_INV_AM,0))
    ,평가누락품목수 = SUM(CASE WHEN E.RAW_INV <> 0 AND ISNULL(E.EV_INV_QT,0) = 0 THEN 1 ELSE 0 END)
    ,금액0품목수    = SUM(CASE WHEN ISNULL(E.EV_INV_QT,0) <> 0 AND ISNULL(E.EV_INV_AM,0) = 0 THEN 1 ELSE 0 END)
    ,음수금액품목수 = SUM(CASE WHEN ISNULL(E.EV_INV_AM,0) < 0 THEN 1 ELSE 0 END)
    ,판정 = CASE
         WHEN @HAS_FIFO = 0
              THEN N'1.★LINV_MVFIFO 없음 - 재고평가 미운영 또는 미실행'
         WHEN SUM(CASE WHEN E.RAW_INV <> 0 AND ISNULL(E.EV_INV_QT,0) = 0 THEN 1 ELSE 0 END) > 0
              THEN N'2.★평가 누락 품목 존재 - 평가 범위 확인'
         WHEN ABS(SUM(ISNULL(E.EV_OPEN_AM,0)) + SUM(ISNULL(E.EV_RCV_AM,0))
                - SUM(ISNULL(E.EV_ISU_AM,0)) - SUM(ISNULL(E.EV_INV_AM,0))) > @TH_AM
              THEN N'3.★수불 등식 불성립 (기초+입고-출고≠기말) - 평가 재실행'
         WHEN @HAS_CIV = 1
          AND ABS(SUM(ISNULL(E.EV_INV_AM,0)) - SUM(ISNULL(E.CIV_INV_AM,0))) > @TH_AM
              THEN N'4.★경리수불과 불일치 - 회계 반영 확인'
         ELSE N'0.정상' END
FROM   #EV E
;


DROP TABLE #EV;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 평가 계열 테이블
     SELECT name FROM sys.tables WHERE name IN ('LINV_MVFIFO','LINV_MVFIFO_WK','LINV_TAV','CIV_TAV');

  -- (2) 평가 정합성  ★ 이 파일 실행 전에 P-09 를 먼저 돌릴 것
     --> P09_재고정합성_점검.sql 의 GAP 이 0 이어야 여기 숫자가 의미를 갖는다.

  -- (3) 기수(GISU) / 평가 기간
     SELECT GISU, SMM, FMM, COUNT(*) FROM LINV_MVFIFO
     WHERE CO_CD='1000' GROUP BY GISU, SMM, FMM ORDER BY GISU DESC;

  -- (4) CIV_TAV 컬럼  ★ 경리수불 대사의 전제
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('CIV_TAV') ORDER BY column_id;
     --> 본 쿼리는 INV_AM 을 전제한다. 다르면 1번 블록의 CIV_TAV 부분을 수정할 것.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **LINVTORY 는 `P_YR` 기준, LINV_MVFIFO 는 `GISU`+`SMM~FMM` 기준**이라 기간 정의가 다르다.
     연 단위로 평가하지 않는 사이트면 쿼리 A 의 '평가 전후 수량 불일치'가 대량 발생한다.
     그 경우 평가 범위에 맞춰 `LINVTORY` 쪽도 기간을 좁혀야 한다.

  2) **기간 평가단가(`LINV_TAV`)는 GISU 로만 필터**하고 `SMM~FMM` 을 구분하지 않아 평균을 낸다.
     월별 단가 변동이 큰 품목은 `단가차이_PCT` 가 크게 나오는데, 이는 오류가 아니라
     기간 평균과 개별 출고단가의 차이다.

  3) 이 파일은 **현황**이다. 틀린 곳을 막는 것은 `P09_재고정합성_점검.sql` 의 역할이다.
     쿼리 C 에서 이상이 많이 나오면 P-09 를 먼저 돌려 평가를 재실행할 것.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   P09_재고정합성_점검.sql     : 평가 정합성 점검 (이 파일의 선행)
   P04_재고수불_회전율분석.sql : 평가 후 금액 기준 수불부·회전율
   C03_제품별_원가구성.sql     : 평가 단가가 원가에 반영된 결과
   재고수불_뷰테이블_레퍼런스.md : 평가 계열 컬럼 명세
==============================================================================================*/
