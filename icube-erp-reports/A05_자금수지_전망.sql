/*==============================================================================================
  [ iCUBE ] A-05  자금수지 전망 (수금 / 지급 예정)                                   (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 앞으로 **언제 얼마가 들어오고 나가는가**. 자금 부족 시점을 미리 잡는다.
         어음 만기를 반드시 포함한다 — 어음은 날짜가 확정된 현금 흐름이라 가장 중요하다.

  DBMS : MS-SQL Server 2012 이상 (T-SQL)   ★ 2008 R2 불가 : OVER 프레임 (ROWS/RANGE BETWEEN), PERCENTILE_CONT(), 집계 SUM() OVER(ORDER BY …)

  ----------------------------------------------------------------------------------------------
  [ ★ 두 종류의 흐름을 구분한다 — 이것이 이 리포트의 핵심 설계 ]
  ----------------------------------------------------------------------------------------------
     (확정) 어음 만기      SBILL(받을어음) / ABILLDEB(지급어음)
                           → **날짜가 확정**되어 있다. 자금 계획의 뼈대.

     (추정) 채권·채무 회수  마감 잔액 + 결제조건(평균 회수일/지급일)
                           → **날짜가 추정치**다. @COL_DAY / @PAY_DAY 로 조정한다.
                             거래처별 실제 회수 패턴이 다르므로 쿼리 F 로 실측해 보정할 것.

     결과 행마다 `확실도` 컬럼으로 (확정) / (추정) 을 표시한다. 섞어서 합계만 보면
     "확정된 지출"과 "들어올지 모르는 수입"이 상계되어 위험이 가려진다.

  ----------------------------------------------------------------------------------------------
  [ 산식 ]
  ----------------------------------------------------------------------------------------------
     수입 = 받을어음 만기액 + (미회수 채권 × 예상 회수일)
     지출 = 지급어음 만기액 + (미지급 채무 × 예상 지급일)
     기간 순수지 = 수입 - 지출
     누적 자금잔고 = @OPEN_CASH + Σ(기간 순수지)        ← 음수가 되는 시점이 자금 부족 시점
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD     NVARCHAR(4)  = N'1000'
    ,@DIV_CD    NVARCHAR(4)  = N'1000'
    ,@BASE_DT   NVARCHAR(8)  = N'20260915'     -- 기준일 (오늘)
    ,@TO_DT     NVARCHAR(8)  = N'20261231'     -- 전망 종료일
    ,@TR_CD     NVARCHAR(10) = NULL
    ,@BUCKET    NVARCHAR(1)  = N'W'            -- W 주별 / M 월별
    ,@OPEN_CASH DECIMAL(19,4) = 0              -- 기초 자금잔고 (수기 입력)

    ,@COL_DAY   INT = 30                       -- 채권 평균 회수일 (마감일 + N일)
    ,@PAY_DAY   INT = 30                       -- 채무 평균 지급일 (마감일 + N일)
    ,@INC_EST   NCHAR(1) = N'1'                -- 추정 흐름 포함 (0 = 확정 어음만)
;

DECLARE @P_YR NVARCHAR(4) = LEFT(@BASE_DT, 4);
DECLARE @SQL NVARCHAR(MAX);
DECLARE @HAS_SB BIT = 0, @HAS_AB BIT = 0;
DECLARE @SB_DUE NVARCHAR(30), @SB_AM NVARCHAR(30), @AB_DUE NVARCHAR(30), @AB_AM NVARCHAR(30);

IF OBJECT_ID('tempdb..#CF') IS NOT NULL DROP TABLE #CF;

CREATE TABLE #CF (
     FLOW_DT  NVARCHAR(8)           -- 예상/확정 일자
    ,IO_FG    NCHAR(1)              -- I 수입 / O 지출
    ,SRC      NVARCHAR(20)          -- 구분
    ,CERT     NVARCHAR(10)          -- 확정 / 추정
    ,TR_CD    NVARCHAR(10)
    ,DOC_NB   NVARCHAR(30)
    ,AMT      DECIMAL(19,4)
    ,REMARK   NVARCHAR(100)
);


/*==============================================================================================
  1. 확정 흐름 : 받을어음 만기 (SBILL)
     ─ 컬럼명이 사이트별로 달라 sys.columns 로 만기일/금액 컬럼을 탐색한다.
==============================================================================================*/
IF OBJECT_ID(N'dbo.SBILL', N'U') IS NOT NULL
BEGIN
    SELECT TOP 1 @SB_DUE = name FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.SBILL') AND name IN (N'DUE_DT', N'EXP_DT', N'MAT_DT', N'END_DT')
    ORDER BY CASE name WHEN N'DUE_DT' THEN 1 WHEN N'EXP_DT' THEN 2 ELSE 3 END;

    SELECT TOP 1 @SB_AM = name FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.SBILL') AND name IN (N'BILL_AM', N'AMT', N'RCP_AM', N'BILL_AMT')
    ORDER BY CASE name WHEN N'BILL_AM' THEN 1 WHEN N'AMT' THEN 2 ELSE 3 END;

    IF @SB_DUE IS NOT NULL AND @SB_AM IS NOT NULL
    BEGIN
        SET @SQL = N'
            INSERT INTO #CF (FLOW_DT, IO_FG, SRC, CERT, TR_CD, DOC_NB, AMT, REMARK)
            SELECT B.' + QUOTENAME(@SB_DUE) + N'
                  ,N''I'', N''1.받을어음'', N''확정''
                  ,B.TR_CD, NULL
                  ,CAST(ISNULL(B.' + QUOTENAME(@SB_AM) + N', 0) AS DECIMAL(19,4))
                  ,N''어음 만기''
            FROM   dbo.SBILL B WITH (NOLOCK)
            WHERE  B.CO_CD = @p_CO
              AND  B.' + QUOTENAME(@SB_DUE) + N' BETWEEN @p_FR AND @p_TO
              AND  ISNULL(B.USE_YN, N''1'') = N''1''
              AND  ISNULL(B.' + QUOTENAME(@SB_AM) + N', 0) <> 0
              AND  (@p_DIV IS NULL OR B.DIV_CD = @p_DIV)
              AND  (@p_TR  IS NULL OR B.TR_CD  = @p_TR)';
        BEGIN TRY
            EXEC sp_executesql @SQL
                ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_FR NVARCHAR(8), @p_TO NVARCHAR(8), @p_TR NVARCHAR(10)'
                ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_FR=@BASE_DT, @p_TO=@TO_DT, @p_TR=@TR_CD;
            SET @HAS_SB = 1;
            PRINT N'[1] 받을어음 (' + @SB_DUE + N'/' + @SB_AM + N') : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 건';
        END TRY BEGIN CATCH PRINT N'[1] SBILL 조회 실패 : ' + ERROR_MESSAGE(); END CATCH
    END
    ELSE PRINT N'[1] SBILL 에 만기일/금액 컬럼을 찾지 못함';
END
ELSE PRINT N'[1] SBILL 없음 - 받을어음 미운영';


/*==============================================================================================
  2. 확정 흐름 : 지급어음 만기 (ABILLDEB)
==============================================================================================*/
IF OBJECT_ID(N'dbo.ABILLDEB', N'U') IS NOT NULL
BEGIN
    SELECT TOP 1 @AB_DUE = name FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.ABILLDEB') AND name IN (N'DUE_DT', N'EXP_DT', N'MAT_DT', N'END_DT')
    ORDER BY CASE name WHEN N'DUE_DT' THEN 1 WHEN N'EXP_DT' THEN 2 ELSE 3 END;

    SELECT TOP 1 @AB_AM = name FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.ABILLDEB') AND name IN (N'BILL_AM', N'AMT', N'PAY_AM', N'BILL_AMT')
    ORDER BY CASE name WHEN N'BILL_AM' THEN 1 WHEN N'AMT' THEN 2 ELSE 3 END;

    IF @AB_DUE IS NOT NULL AND @AB_AM IS NOT NULL
    BEGIN
        SET @SQL = N'
            INSERT INTO #CF (FLOW_DT, IO_FG, SRC, CERT, TR_CD, DOC_NB, AMT, REMARK)
            SELECT B.' + QUOTENAME(@AB_DUE) + N'
                  ,N''O'', N''1.지급어음'', N''확정''
                  ,B.TR_CD, NULL
                  ,CAST(ISNULL(B.' + QUOTENAME(@AB_AM) + N', 0) AS DECIMAL(19,4))
                  ,N''어음 만기''
            FROM   dbo.ABILLDEB B WITH (NOLOCK)
            WHERE  B.CO_CD = @p_CO
              AND  B.' + QUOTENAME(@AB_DUE) + N' BETWEEN @p_FR AND @p_TO
              AND  ISNULL(B.USE_YN, N''1'') = N''1''
              AND  ISNULL(B.' + QUOTENAME(@AB_AM) + N', 0) <> 0
              AND  (@p_DIV IS NULL OR B.DIV_CD = @p_DIV)
              AND  (@p_TR  IS NULL OR B.TR_CD  = @p_TR)';
        BEGIN TRY
            EXEC sp_executesql @SQL
                ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_FR NVARCHAR(8), @p_TO NVARCHAR(8), @p_TR NVARCHAR(10)'
                ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_FR=@BASE_DT, @p_TO=@TO_DT, @p_TR=@TR_CD;
            SET @HAS_AB = 1;
            PRINT N'[2] 지급어음 (' + @AB_DUE + N'/' + @AB_AM + N') : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 건';
        END TRY BEGIN CATCH PRINT N'[2] ABILLDEB 조회 실패 : ' + ERROR_MESSAGE(); END CATCH
    END
    ELSE PRINT N'[2] ABILLDEB 에 만기일/금액 컬럼을 찾지 못함';
END
ELSE PRINT N'[2] ABILLDEB 없음 - 지급어음 미운영';


/*==============================================================================================
  3. 추정 흐름 : 미회수 채권  (매출마감 - 수금)
     ─ 거래처별 잔액을 마감일 기준 @COL_DAY 후에 회수된다고 본다.
==============================================================================================*/
IF @INC_EST = N'1'
BEGIN
    ;WITH CLS AS (
        SELECT
             H.TR_CD
            ,H.CLS_DT
            ,AM = SUM(CAST(ISNULL(D.CLSH_AM, 0) AS DECIMAL(19,4)))
        FROM       LSALECLS   H WITH (NOLOCK)
        INNER JOIN LSALECLS_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.CLS_NB = H.CLS_NB
        WHERE  H.CO_CD = @CO_CD
          AND  H.CLS_DT BETWEEN @P_YR + N'0101' AND @BASE_DT
          AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
          AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
          AND  (@TR_CD  IS NULL OR H.TR_CD  = @TR_CD)
        GROUP BY H.TR_CD, H.CLS_DT
    ), RCP AS (
        SELECT
             H.TR_CD
            ,AM = SUM(CAST(ISNULL(D.NORMAL_AM,0) + ISNULL(D.BEFORE_AM,0) AS DECIMAL(19,4)))
        FROM       LRCP   H WITH (NOLOCK)
        INNER JOIN LRCP_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.RCP_NB = H.RCP_NB
        WHERE  H.CO_CD = @CO_CD
          AND  H.RCP_DT BETWEEN @P_YR + N'0101' AND @BASE_DT
          AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
          AND  ISNULL(D.RCPAM_FG, N'0') = N'0'
          AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
        GROUP BY H.TR_CD
    ), BAL AS (
        -- 거래처별 총 잔액
        SELECT
             C.TR_CD
            ,BAL_AM = SUM(C.AM) - ISNULL(MAX(R.AM), 0)
        FROM      CLS C
        LEFT JOIN RCP R ON R.TR_CD = C.TR_CD
        GROUP BY C.TR_CD
        HAVING SUM(C.AM) - ISNULL(MAX(R.AM), 0) > 0
    ), ALLOC AS (
        -- 잔액을 마감건에 최신순으로 배분 (선입선출 회수 가정)
        SELECT
             C.TR_CD, C.CLS_DT, C.AM
            ,B.BAL_AM
            ,RUNNING = SUM(C.AM) OVER (PARTITION BY C.TR_CD ORDER BY C.CLS_DT DESC
                                       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        FROM       CLS C
        INNER JOIN BAL B ON B.TR_CD = C.TR_CD
    )
    INSERT INTO #CF (FLOW_DT, IO_FG, SRC, CERT, TR_CD, DOC_NB, AMT, REMARK)
    SELECT
         CONVERT(NVARCHAR(8), DATEADD(DAY, @COL_DAY, CONVERT(DATE, A.CLS_DT)), 112)
        ,N'I', N'2.채권회수', N'추정'
        ,A.TR_CD, NULL
        ,CASE WHEN A.RUNNING <= A.BAL_AM THEN A.AM
              ELSE A.AM - (A.RUNNING - A.BAL_AM) END
        ,N'마감 ' + A.CLS_DT + N' + ' + CAST(@COL_DAY AS NVARCHAR(5)) + N'일'
    FROM   ALLOC A
    WHERE  A.RUNNING - A.AM < A.BAL_AM                      -- 잔액 범위 내 마감건만
      AND  CASE WHEN A.RUNNING <= A.BAL_AM THEN A.AM
                ELSE A.AM - (A.RUNNING - A.BAL_AM) END > 0
      AND  CONVERT(NVARCHAR(8), DATEADD(DAY, @COL_DAY, CONVERT(DATE, A.CLS_DT)), 112)
           BETWEEN @BASE_DT AND @TO_DT;

    PRINT N'[3] 채권 회수 예정 : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 건';
END


/*==============================================================================================
  4. 추정 흐름 : 미지급 채무  (매입마감 - 지급)
==============================================================================================*/
IF @INC_EST = N'1'
BEGIN
    ;WITH CLS AS (
        SELECT
             H.TR_CD
            ,H.CLS_DT
            ,AM = SUM(CAST(ISNULL(D.CLSH_AM, 0) AS DECIMAL(19,4)))
        FROM       LPURCLS   H WITH (NOLOCK)
        INNER JOIN LPURCLS_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.CLS_NB = H.CLS_NB
        WHERE  H.CO_CD = @CO_CD
          AND  H.CLS_DT BETWEEN @P_YR + N'0101' AND @BASE_DT
          AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
          AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
          AND  (@TR_CD  IS NULL OR H.TR_CD  = @TR_CD)
        GROUP BY H.TR_CD, H.CLS_DT
    ), PAY AS (
        SELECT
             H.TR_CD
            ,AM = SUM(CAST(ISNULL(D.NORMAL_AM, 0) + ISNULL(D.BEFORE_AM, 0) AS DECIMAL(19,4)))
        FROM       LPAY   H WITH (NOLOCK)
        INNER JOIN LPAY_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.PAY_NB = H.PAY_NB
        WHERE  H.CO_CD = @CO_CD
          AND  H.PAY_DT BETWEEN @P_YR + N'0101' AND @BASE_DT
          AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
          AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
        GROUP BY H.TR_CD
    ), BAL AS (
        SELECT
             C.TR_CD
            ,BAL_AM = SUM(C.AM) - ISNULL(MAX(P.AM), 0)
        FROM      CLS C
        LEFT JOIN PAY P ON P.TR_CD = C.TR_CD
        GROUP BY C.TR_CD
        HAVING SUM(C.AM) - ISNULL(MAX(P.AM), 0) > 0
    ), ALLOC AS (
        SELECT
             C.TR_CD, C.CLS_DT, C.AM
            ,B.BAL_AM
            ,RUNNING = SUM(C.AM) OVER (PARTITION BY C.TR_CD ORDER BY C.CLS_DT DESC
                                       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        FROM       CLS C
        INNER JOIN BAL B ON B.TR_CD = C.TR_CD
    )
    INSERT INTO #CF (FLOW_DT, IO_FG, SRC, CERT, TR_CD, DOC_NB, AMT, REMARK)
    SELECT
         CONVERT(NVARCHAR(8), DATEADD(DAY, @PAY_DAY, CONVERT(DATE, A.CLS_DT)), 112)
        ,N'O', N'2.채무지급', N'추정'
        ,A.TR_CD, NULL
        ,CASE WHEN A.RUNNING <= A.BAL_AM THEN A.AM
              ELSE A.AM - (A.RUNNING - A.BAL_AM) END
        ,N'마감 ' + A.CLS_DT + N' + ' + CAST(@PAY_DAY AS NVARCHAR(5)) + N'일'
    FROM   ALLOC A
    WHERE  A.RUNNING - A.AM < A.BAL_AM
      AND  CASE WHEN A.RUNNING <= A.BAL_AM THEN A.AM
                ELSE A.AM - (A.RUNNING - A.BAL_AM) END > 0
      AND  CONVERT(NVARCHAR(8), DATEADD(DAY, @PAY_DAY, CONVERT(DATE, A.CLS_DT)), 112)
           BETWEEN @BASE_DT AND @TO_DT;

    PRINT N'[4] 채무 지급 예정 : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 건';
END

CREATE CLUSTERED INDEX IX_CF ON #CF (FLOW_DT, IO_FG);


/*==============================================================================================
  ** 쿼리 A : 기간별 자금수지 전망  (메인)  ★ 누적 잔고가 음수가 되는 시점을 본다
==============================================================================================*/
;WITH B AS (
    SELECT
         BUCKET = CASE @BUCKET
             WHEN N'M' THEN LEFT(F.FLOW_DT, 6)
             ELSE CONVERT(NVARCHAR(8),
                          DATEADD(DAY, -(DATEPART(WEEKDAY, CONVERT(DATE, F.FLOW_DT)) - 1),
                                  CONVERT(DATE, F.FLOW_DT)), 112)      -- 주 시작일(일요일)
             END
        ,F.*
    FROM #CF F
), G AS (
    SELECT
         B.BUCKET
        ,IN_FIX  = SUM(CASE WHEN B.IO_FG=N'I' AND B.CERT=N'확정' THEN B.AMT ELSE 0 END)
        ,IN_EST  = SUM(CASE WHEN B.IO_FG=N'I' AND B.CERT=N'추정' THEN B.AMT ELSE 0 END)
        ,OUT_FIX = SUM(CASE WHEN B.IO_FG=N'O' AND B.CERT=N'확정' THEN B.AMT ELSE 0 END)
        ,OUT_EST = SUM(CASE WHEN B.IO_FG=N'O' AND B.CERT=N'추정' THEN B.AMT ELSE 0 END)
        ,CNT     = COUNT(*)
    FROM   B
    GROUP BY B.BUCKET
)
SELECT
     N'[A] 자금수지 전망'                           AS REPORT_NM
    ,CASE @BUCKET WHEN N'M' THEN N'월별' ELSE N'주별' END AS 집계단위
    ,G.BUCKET                                       AS 기간
    ,G.IN_FIX                                       AS 수입_확정_어음
    ,G.IN_EST                                       AS 수입_추정_채권
    ,수입계 = G.IN_FIX + G.IN_EST
    ,G.OUT_FIX                                      AS 지출_확정_어음
    ,G.OUT_EST                                      AS 지출_추정_채무
    ,지출계 = G.OUT_FIX + G.OUT_EST
    ,순수지 = (G.IN_FIX + G.IN_EST) - (G.OUT_FIX + G.OUT_EST)
    ,누적잔고 = @OPEN_CASH + SUM((G.IN_FIX + G.IN_EST) - (G.OUT_FIX + G.OUT_EST))
                             OVER (ORDER BY G.BUCKET ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
    -- 확정분만으로 본 보수적 전망
    ,순수지_확정만 = G.IN_FIX - G.OUT_FIX
    ,누적잔고_확정만 = @OPEN_CASH + SUM(G.IN_FIX - G.OUT_FIX)
                                    OVER (ORDER BY G.BUCKET ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
    ,G.CNT                                          AS 건수
    ,판정 = CASE
         WHEN @OPEN_CASH + SUM((G.IN_FIX+G.IN_EST)-(G.OUT_FIX+G.OUT_EST))
                           OVER (ORDER BY G.BUCKET ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) < 0
              THEN N'1.★자금 부족 예상'
         WHEN @OPEN_CASH + SUM(G.IN_FIX - G.OUT_FIX)
                           OVER (ORDER BY G.BUCKET ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) < 0
              THEN N'2.★확정분만으로는 부족 - 채권 회수가 늦어지면 위험'
         WHEN (G.IN_FIX + G.IN_EST) - (G.OUT_FIX + G.OUT_EST) < 0
              THEN N'3.기간 적자 (누적은 양호)'
         ELSE N'0.정상' END
FROM   G
ORDER BY G.BUCKET
;


/*==============================================================================================
  ** 쿼리 B : 어음 만기 스케줄  ★ 날짜가 확정된 현금 흐름 — 자금 계획의 뼈대
==============================================================================================*/
SELECT
     N'[B] 어음 만기 스케줄'                        AS REPORT_NM
    ,F.SRC                                          AS 구분
    ,구분명 = CASE F.IO_FG WHEN N'I' THEN N'수입(받을어음)' ELSE N'지출(지급어음)' END
    ,F.FLOW_DT                                      AS 만기일
    ,잔여일 = DATEDIFF(DAY, CONVERT(DATE, @BASE_DT), CONVERT(DATE, F.FLOW_DT))
    ,F.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,F.AMT                                          AS 금액
    ,긴급도 = CASE
         WHEN DATEDIFF(DAY, CONVERT(DATE,@BASE_DT), CONVERT(DATE,F.FLOW_DT)) <= 7  THEN N'1.★7일 이내'
         WHEN DATEDIFF(DAY, CONVERT(DATE,@BASE_DT), CONVERT(DATE,F.FLOW_DT)) <= 30 THEN N'2.30일 이내'
         ELSE N'3.30일 초과' END
    ,F.REMARK                                       AS 비고
FROM       #CF    F
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD = F.TR_CD
WHERE  F.CERT = N'확정'
ORDER BY F.FLOW_DT, F.IO_FG DESC
;


/*==============================================================================================
  ** 쿼리 C : 거래처별 수금 · 지급 예정
==============================================================================================*/
SELECT
     N'[C] 거래처별 자금 예정'                      AS REPORT_NM
    ,F.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,수입_어음 = SUM(CASE WHEN F.IO_FG=N'I' AND F.CERT=N'확정' THEN F.AMT ELSE 0 END)
    ,수입_채권 = SUM(CASE WHEN F.IO_FG=N'I' AND F.CERT=N'추정' THEN F.AMT ELSE 0 END)
    ,수입계   = SUM(CASE WHEN F.IO_FG=N'I' THEN F.AMT ELSE 0 END)
    ,지출_어음 = SUM(CASE WHEN F.IO_FG=N'O' AND F.CERT=N'확정' THEN F.AMT ELSE 0 END)
    ,지출_채무 = SUM(CASE WHEN F.IO_FG=N'O' AND F.CERT=N'추정' THEN F.AMT ELSE 0 END)
    ,지출계   = SUM(CASE WHEN F.IO_FG=N'O' THEN F.AMT ELSE 0 END)
    ,순액     = SUM(CASE WHEN F.IO_FG=N'I' THEN F.AMT ELSE -F.AMT END)
    ,최단수입일 = MIN(CASE WHEN F.IO_FG=N'I' THEN F.FLOW_DT END)
    ,최단지출일 = MIN(CASE WHEN F.IO_FG=N'O' THEN F.FLOW_DT END)
    ,판정 = CASE
         WHEN SUM(CASE WHEN F.IO_FG=N'I' THEN F.AMT ELSE -F.AMT END) < 0
              THEN N'1.순지출 거래처 (매입처)'
         WHEN SUM(CASE WHEN F.IO_FG=N'I' AND F.CERT=N'추정' THEN F.AMT ELSE 0 END)
              > SUM(CASE WHEN F.IO_FG=N'I' THEN F.AMT ELSE 0 END) * 0.8
              THEN N'2.★수입이 대부분 추정분 - 회수 지연 시 자금 계획 흔들림'
         ELSE N'0.정상' END
FROM       #CF    F
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD = F.TR_CD
GROUP BY F.TR_CD, T.TR_NM
ORDER BY 순액
;


/*==============================================================================================
  ** 쿼리 D : 흐름 상세 (일자별 전체)
==============================================================================================*/
SELECT
     N'[D] 자금 흐름 상세'                          AS REPORT_NM
    ,F.FLOW_DT                                      AS 예정일
    ,잔여일 = DATEDIFF(DAY, CONVERT(DATE, @BASE_DT), CONVERT(DATE, F.FLOW_DT))
    ,구분 = CASE F.IO_FG WHEN N'I' THEN N'수입' ELSE N'지출' END
    ,F.SRC                                          AS 유형
    ,F.CERT                                         AS 확실도
    ,F.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,F.AMT                                          AS 금액
    ,부호금액 = CASE F.IO_FG WHEN N'I' THEN F.AMT ELSE -F.AMT END
    ,F.REMARK                                       AS 산출근거
FROM       #CF    F
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD = F.TR_CD
ORDER BY F.FLOW_DT, F.IO_FG DESC, F.AMT DESC
;


/*==============================================================================================
  ** 쿼리 E : 전체 요약 (경영 보고 1행)
==============================================================================================*/
SELECT
     N'[E] 자금수지 요약'                           AS REPORT_NM
    ,@BASE_DT + N' ~ ' + @TO_DT                     AS 전망기간
    ,@OPEN_CASH                                     AS 기초자금
    ,수입_확정 = SUM(CASE WHEN F.IO_FG=N'I' AND F.CERT=N'확정' THEN F.AMT ELSE 0 END)
    ,수입_추정 = SUM(CASE WHEN F.IO_FG=N'I' AND F.CERT=N'추정' THEN F.AMT ELSE 0 END)
    ,수입계   = SUM(CASE WHEN F.IO_FG=N'I' THEN F.AMT ELSE 0 END)
    ,지출_확정 = SUM(CASE WHEN F.IO_FG=N'O' AND F.CERT=N'확정' THEN F.AMT ELSE 0 END)
    ,지출_추정 = SUM(CASE WHEN F.IO_FG=N'O' AND F.CERT=N'추정' THEN F.AMT ELSE 0 END)
    ,지출계   = SUM(CASE WHEN F.IO_FG=N'O' THEN F.AMT ELSE 0 END)
    ,순수지   = SUM(CASE WHEN F.IO_FG=N'I' THEN F.AMT ELSE -F.AMT END)
    ,기말예상자금 = @OPEN_CASH + SUM(CASE WHEN F.IO_FG=N'I' THEN F.AMT ELSE -F.AMT END)
    ,기말예상자금_확정만 = @OPEN_CASH
                          + SUM(CASE WHEN F.CERT=N'확정'
                                     THEN CASE WHEN F.IO_FG=N'I' THEN F.AMT ELSE -F.AMT END
                                     ELSE 0 END)
    ,추정의존도_PCT = CAST(SUM(CASE WHEN F.IO_FG=N'I' AND F.CERT=N'추정' THEN F.AMT ELSE 0 END) * 100.0
                           / NULLIF(SUM(CASE WHEN F.IO_FG=N'I' THEN F.AMT ELSE 0 END), 0) AS DECIMAL(5,1))
    ,판정 = CASE
         WHEN @OPEN_CASH + SUM(CASE WHEN F.IO_FG=N'I' THEN F.AMT ELSE -F.AMT END) < 0
              THEN N'1.★기간 말 자금 부족 예상 - 자금 조달 계획 필요'
         WHEN @OPEN_CASH + SUM(CASE WHEN F.CERT=N'확정'
                                    THEN CASE WHEN F.IO_FG=N'I' THEN F.AMT ELSE -F.AMT END
                                    ELSE 0 END) < 0
              THEN N'2.★확정분만으로는 부족 - 채권 회수에 의존. 회수 관리 강화 필요'
         WHEN SUM(CASE WHEN F.IO_FG=N'I' AND F.CERT=N'추정' THEN F.AMT ELSE 0 END)
              / NULLIF(SUM(CASE WHEN F.IO_FG=N'I' THEN F.AMT ELSE 0 END), 0) > 0.7
              THEN N'3.수입의 70% 초과가 추정분 - 전망 신뢰도 낮음'
         ELSE N'0.정상' END
FROM   #CF F
;


/*==============================================================================================
  ** 쿼리 F : 실제 회수/지급 리드타임 실측  ★ @COL_DAY / @PAY_DAY 보정 근거
     ─ 추정 흐름의 날짜는 이 값에 달려 있다. 기본값 30일을 실측으로 바꿔야 전망이 맞는다.
==============================================================================================*/
SELECT
     N'[F] 회수·지급 리드타임 실측'                 AS REPORT_NM
    ,구분 = N'1.채권 회수'
    ,COUNT(*)                                       AS 표본건수
    ,평균일 = CAST(AVG(CAST(X.DAYS AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,중앙값 = CAST(MAX(X.MED) AS DECIMAL(9,1))
    ,최소일 = MIN(X.DAYS)
    ,최대일 = MAX(X.DAYS)
    ,현재설정 = @COL_DAY
    ,권장값 = CAST(MAX(X.MED) AS INT)
    ,판정 = CASE WHEN ABS(MAX(X.MED) - @COL_DAY) > 10
                 THEN N'★ 설정값과 실측 중앙값이 10일 이상 차이 - @COL_DAY 를 권장값으로 바꿀 것'
                 ELSE N'적정' END
FROM (
    SELECT DISTINCT
         DAYS = DATEDIFF(DAY, CONVERT(DATE, C.CLS_DT), CONVERT(DATE, R.RCP_DT))
        ,MED  = PERCENTILE_CONT(0.5) WITHIN GROUP (
                    ORDER BY CAST(DATEDIFF(DAY, CONVERT(DATE,C.CLS_DT), CONVERT(DATE,R.RCP_DT)) AS FLOAT))
                OVER (PARTITION BY (SELECT NULL))
    FROM       LSALECLS C WITH (NOLOCK)
    INNER JOIN LRCP_D   D WITH (NOLOCK) ON D.CO_CD = C.CO_CD
                                       AND ISNULL(D.CLS_NB, N'') = C.CLS_NB
    INNER JOIN LRCP     R WITH (NOLOCK) ON R.CO_CD = D.CO_CD AND R.RCP_NB = D.RCP_NB
    WHERE  C.CO_CD = @CO_CD
      AND  C.CLS_DT >= @P_YR + N'0101'
      AND  ISNULL(D.USE_YN, N'1') = N'1'
      AND  DATEDIFF(DAY, CONVERT(DATE,C.CLS_DT), CONVERT(DATE,R.RCP_DT)) BETWEEN 0 AND 365
) X
HAVING COUNT(*) > 0
;


/*==============================================================================================
  ** 쿼리 G : 데이터 점검
==============================================================================================*/
SELECT
     N'[G] 데이터 점검'                             AS REPORT_NM
    ,SBILL_존재    = CASE WHEN OBJECT_ID(N'dbo.SBILL'   , N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,ABILLDEB_존재 = CASE WHEN OBJECT_ID(N'dbo.ABILLDEB', N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,LPAY_존재     = CASE WHEN OBJECT_ID(N'dbo.LPAY'    , N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,받을어음_적재 = CASE WHEN @HAS_SB = 1 THEN N'O' ELSE N'X' END
    ,지급어음_적재 = CASE WHEN @HAS_AB = 1 THEN N'O' ELSE N'X' END
    ,받을어음_컬럼 = ISNULL(@SB_DUE, N'(미확인)') + N' / ' + ISNULL(@SB_AM, N'(미확인)')
    ,지급어음_컬럼 = ISNULL(@AB_DUE, N'(미확인)') + N' / ' + ISNULL(@AB_AM, N'(미확인)')
    ,확정흐름건수 = (SELECT COUNT(*) FROM #CF WHERE CERT = N'확정')
    ,추정흐름건수 = (SELECT COUNT(*) FROM #CF WHERE CERT = N'추정')
    ,판정 = CASE
         WHEN (SELECT COUNT(*) FROM #CF) = 0
              THEN N'1.★흐름 데이터 없음 - 기간 또는 파라미터 확인'
         WHEN @HAS_SB = 0 AND @HAS_AB = 0
              THEN N'2.★어음 데이터 없음 - 전망이 전부 추정치다. 신뢰도 낮음'
         WHEN @OPEN_CASH = 0
              THEN N'3.★기초자금(@OPEN_CASH)이 0 - 누적잔고가 의미 없다. 실제 잔고를 입력할 것'
         ELSE N'0.정상' END
;


DROP TABLE #CF;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 어음 테이블 컬럼  ★ 본 쿼리는 자동 탐색하지만 직접 확인이 확실하다
     SELECT name, TYPE_NAME(user_type_id) FROM sys.columns
     WHERE object_id = OBJECT_ID('SBILL') ORDER BY column_id;
     SELECT name, TYPE_NAME(user_type_id) FROM sys.columns
     WHERE object_id = OBJECT_ID('ABILLDEB') ORDER BY column_id;
     --> 만기일 후보 : DUE_DT, EXP_DT, MAT_DT, END_DT
        금액   후보 : BILL_AM, AMT, RCP_AM/PAY_AM, BILL_AMT
        없으면 1·2번 블록의 IN (...) 에 실제 컬럼명을 추가할 것.

  -- (2) 어음 운영 여부  ★ 없으면 전망이 전부 추정치가 된다
     SELECT COUNT(*) FROM SBILL    WHERE CO_CD='1000';
     SELECT COUNT(*) FROM ABILLDEB WHERE CO_CD='1000';

  -- (3) 실제 회수 리드타임  ★ 쿼리 F 와 같은 목적. @COL_DAY 보정의 근거
     --> 쿼리 F 를 먼저 돌려 중앙값을 확인하고 @COL_DAY 를 그 값으로 바꿀 것.
        기본값 30일을 그대로 쓰면 전망이 실제와 어긋난다.

  -- (4) LRCP_D 의 마감 연결(CLS_NB) 채움률  ★ 쿼리 F 의 표본 확보 여부
     SELECT COUNT(*) 전체, SUM(CASE WHEN ISNULL(CLS_NB,'')='' THEN 1 ELSE 0 END) 마감미연결
     FROM   LRCP_D WHERE CO_CD='1000';
     --> 미연결이 대부분이면 쿼리 F 가 표본 부족으로 나온다. 이 경우 회수 리드타임은
        경리 담당자에게 실무 값을 받아 @COL_DAY 에 넣을 것.

  -- (5) 기초 자금잔고  ★ @OPEN_CASH 는 수기 입력이다
     --> 회계모듈의 현금·예금 계정 잔액을 조회해 넣어야 누적잔고가 의미를 갖는다.
        본 쿼리는 자금 계정을 자동 조회하지 않는다 (계정과목 체계가 사이트마다 달라서).

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **추정 흐름의 날짜는 근사치다.** 거래처별 결제조건(월말 마감 후 익월 말 지급 등)을
     반영하지 않고 `마감일 + N일` 단일 규칙을 쓴다. 거래처별로 결제조건이 크게 다른 사이트는
     전망 오차가 커진다. `STRADE` 에 결제조건 컬럼이 있으면 거래처별로 적용하도록 고칠 것.
     **쿼리 A 의 `누적잔고_확정만` 컬럼이 보수적 하한선**이므로 그쪽을 먼저 보는 편이 안전하다.

  2) **급여·세금·차입금 상환·고정비는 포함하지 않았다.** 물류/영업 모듈 데이터만 쓰기 때문이다.
     실제 자금계획에 쓰려면 회계모듈의 고정 지출 일정을 별도로 더해야 한다.
     따라서 이 리포트는 **영업 활동에서 발생하는 자금 흐름**만 본다.

  3) 채권/채무 잔액을 마감건에 **최신순으로 배분**한다(선입선출 회수 가정). 건별 소거
     데이터가 있으면 그쪽이 정확하다. `LRCP_D.CLS_NB` 채움률을 확인 (4)번으로 볼 것.

  4) `@OPEN_CASH` 는 수기 입력이다. 0 으로 두면 `누적잔고` 는 상대적 증감만 의미가 있다.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   S06_채권여신_관리현황.sql    : 채권 잔액·연령분석 (수입 추정의 근거)
   A02_기표파이프라인_현황.sql  : 마감 → 전표 → 장부 (자금 흐름의 회계 반영)
   P01_청구발주입고_진행현황.sql : 향후 발생할 채무의 선행 지표
   E01_경영KPI_대시보드.sql     : 미수채권 타일과 연결
==============================================================================================*/
