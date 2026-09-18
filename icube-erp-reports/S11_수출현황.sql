/*==============================================================================================
  [ iCUBE ] S-11  수출 현황 (직수출)                                                 (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : **선적(B/L) 기준** 수출 실적을 본다. 국내 매출과 성격이 달라 따로 봐야 한다.
         환종·환율이 개입하고, 출고일과 선적일이 다르며, 수금 조건(L/C·T/T)도 다르다.

  DBMS : MS-SQL Server 2012 이상 (T-SQL)   ★ 2008 R2 불가 : LAG()

  ----------------------------------------------------------------------------------------------
  [ 소스 ]
  ----------------------------------------------------------------------------------------------
     LEBL / LEBL_D    선적 등록 (B/L)   ★ 명세서 미등재 — 컬럼 자동 탐색
     LDELIVER_D       출고 (선적 대상)
     LSALECLS_D       매출마감 (회계 확정)

     ※ 선적 테이블이 없는 사이트는 **`LDELIVER.SO_FG` 로 수출 거래를 구분**한다.
       @FALLBACK='1' 이면 선적 테이블 없이 출고 기준으로 동작한다 (기본값).

  ----------------------------------------------------------------------------------------------
  [ 국내와 다른 점 — 반드시 구분해야 하는 것 ]
  ----------------------------------------------------------------------------------------------
   1. **선적일 ≠ 출고일.** 창고에서 나간 날과 배가 뜬 날이 다르다. 매출 인식 시점은 선적일이다.
   2. **외화 금액과 원화 금액이 따로 있다.** 환율 변동으로 두 값의 비율이 달라진다.
   3. **수금 리드타임이 길다.** L/C 네고, T/T 등 조건에 따라 회수 기간이 국내와 크게 다르다.
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@FR_DT    NVARCHAR(8)  = N'20260101'
    ,@TO_DT    NVARCHAR(8)  = N'20261231'
    ,@TR_CD    NVARCHAR(10) = NULL
    ,@EXCH_FG  NVARCHAR(3)  = NULL            -- 환종 (USD/JPY/EUR …)
    ,@FALLBACK NCHAR(1)     = N'1'            -- 1 = 선적 테이블 없으면 출고 기준으로 대체
    ,@EXP_SOFG NVARCHAR(20) = N'1,3,4'        -- 수출로 보는 SO_FG 값 (콤마 구분) ★ 확인 필수
;

DECLARE @SQL NVARCHAR(MAX);
DECLARE @HAS_BL BIT = 0, @SRC NVARCHAR(20) = N'LDELIVER(대체)';
DECLARE @BL_DT NVARCHAR(30), @BL_AM NVARCHAR(30), @BL_FAM NVARCHAR(30);

IF OBJECT_ID('tempdb..#EXP') IS NOT NULL DROP TABLE #EXP;

CREATE TABLE #EXP (
     DOC_NB   NVARCHAR(30)
    ,SHIP_DT  NVARCHAR(8)        -- 선적일 (또는 출고일)
    ,ISU_DT   NVARCHAR(8)        -- 출고일
    ,TR_CD    NVARCHAR(10)
    ,ITEM_CD  NVARCHAR(25)
    ,QT       DECIMAL(19,6)
    ,FOR_AM   DECIMAL(19,4)      -- 외화 금액
    ,KRW_AM   DECIMAL(19,4)      -- 원화 금액
    ,EXCH_FG  NVARCHAR(3)
    ,EXCH_RT  DECIMAL(19,6)
    ,SO_FG    NVARCHAR(1)
);


/*==============================================================================================
  1. 선적(LEBL) 적재  ─ 컬럼 자동 탐색. 없으면 출고 기준으로 대체
==============================================================================================*/
IF OBJECT_ID(N'dbo.LEBL', N'U') IS NOT NULL AND OBJECT_ID(N'dbo.LEBL_D', N'U') IS NOT NULL
BEGIN
    SELECT TOP 1 @BL_DT = name FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.LEBL')
      AND name IN (N'BL_DT', N'SHIP_DT', N'EBL_DT', N'ONBOARD_DT', N'ISU_DT')
    ORDER BY CASE name WHEN N'BL_DT' THEN 1 WHEN N'SHIP_DT' THEN 2 ELSE 3 END;

    SELECT TOP 1 @BL_FAM = name FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.LEBL_D')
      AND name IN (N'FOR_AM', N'EXP_AM', N'BL_AM', N'ISUF_AM')
    ORDER BY CASE name WHEN N'FOR_AM' THEN 1 WHEN N'EXP_AM' THEN 2 ELSE 3 END;

    SELECT TOP 1 @BL_AM = name FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.LEBL_D')
      AND name IN (N'KRW_AM', N'ISUH_AM', N'ISUG_AM', N'WON_AM')
    ORDER BY CASE name WHEN N'KRW_AM' THEN 1 WHEN N'ISUH_AM' THEN 2 ELSE 3 END;

    IF @BL_DT IS NOT NULL
    BEGIN
        SET @SQL = N'
            INSERT INTO #EXP (DOC_NB, SHIP_DT, ISU_DT, TR_CD, ITEM_CD, QT, FOR_AM, KRW_AM, EXCH_FG, EXCH_RT, SO_FG)
            SELECT H.BL_NB
                  ,H.' + QUOTENAME(@BL_DT) + N'
                  ,D2.ISU_DT
                  ,H.TR_CD
                  ,D.ITEM_CD
                  ,CAST(ISNULL(D.ISU_QT, 0) AS DECIMAL(19,6))
                  ,' + CASE WHEN @BL_FAM IS NOT NULL
                            THEN N'CAST(ISNULL(D.' + QUOTENAME(@BL_FAM) + N', 0) AS DECIMAL(19,4))'
                            ELSE N'0' END + N'
                  ,' + CASE WHEN @BL_AM IS NOT NULL
                            THEN N'CAST(ISNULL(D.' + QUOTENAME(@BL_AM) + N', 0) AS DECIMAL(19,4))'
                            ELSE N'0' END + N'
                  ,ISNULL(H.EXCH_FG, N'''')
                  ,CAST(ISNULL(H.EXCH_RT, 0) AS DECIMAL(19,6))
                  ,N''''
            FROM       dbo.LEBL   H WITH (NOLOCK)
            INNER JOIN dbo.LEBL_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.BL_NB = H.BL_NB
            LEFT  JOIN LDELIVER  D2 WITH (NOLOCK) ON D2.CO_CD = D.CO_CD AND D2.ISU_NB = D.ISU_NB
            WHERE  H.CO_CD = @p_CO
              AND  H.' + QUOTENAME(@BL_DT) + N' BETWEEN @p_FR AND @p_TO
              AND  ISNULL(D.USE_YN, N''1'') = N''1''
              AND  (@p_DIV IS NULL OR H.DIV_CD = @p_DIV)
              AND  (@p_TR  IS NULL OR H.TR_CD  = @p_TR)';
        BEGIN TRY
            EXEC sp_executesql @SQL
                ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_FR NVARCHAR(8), @p_TO NVARCHAR(8), @p_TR NVARCHAR(10)'
                ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_FR=@FR_DT, @p_TO=@TO_DT, @p_TR=@TR_CD;
            SET @HAS_BL = 1;
            SET @SRC = N'LEBL(선적)';
            PRINT N'[1] LEBL (' + @BL_DT + N') : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 행';
        END TRY
        BEGIN CATCH PRINT N'[1] ★ LEBL 조회 실패 : ' + ERROR_MESSAGE(); END CATCH
    END
END

-- 대체 : 출고 기준 (SO_FG 로 수출 구분)
IF @HAS_BL = 0 AND @FALLBACK = N'1'
BEGIN
    INSERT INTO #EXP (DOC_NB, SHIP_DT, ISU_DT, TR_CD, ITEM_CD, QT, FOR_AM, KRW_AM, EXCH_FG, EXCH_RT, SO_FG)
    SELECT
         H.ISU_NB
        ,H.ISU_DT                                   -- 선적일 대신 출고일
        ,H.ISU_DT
        ,H.TR_CD
        ,D.ITEM_CD
        ,CAST(ISNULL(D.ISU_QT, 0) AS DECIMAL(19,6))
        ,0
        ,CAST(ISNULL(D.ISUH_AM, 0) AS DECIMAL(19,4))
        ,ISNULL(H.EXCH_FG, N'')
        ,CAST(ISNULL(H.EXCH_RT, 0) AS DECIMAL(19,6))
        ,ISNULL(H.SO_FG, N'')
    FROM       LDELIVER   H WITH (NOLOCK)
    INNER JOIN LDELIVER_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.ISU_NB = H.ISU_NB
    WHERE  H.CO_CD  = @CO_CD
      AND  H.ISU_DT BETWEEN @FR_DT AND @TO_DT
      AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
      AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
      AND  (@TR_CD  IS NULL OR H.TR_CD  = @TR_CD)
      AND  ( ISNULL(H.EXCH_FG, N'') NOT IN (N'', N'KRW')          -- 외화 거래
          OR N',' + @EXP_SOFG + N',' LIKE N'%,' + ISNULL(H.SO_FG, N'') + N',%' );
    PRINT N'[1] 대체 : LDELIVER 기준 ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 행';
END

CREATE CLUSTERED INDEX IX_EXP ON #EXP (TR_CD, ITEM_CD);

-- 환종 필터
IF @EXCH_FG IS NOT NULL DELETE FROM #EXP WHERE EXCH_FG <> @EXCH_FG;


/*==============================================================================================
  ** 쿼리 A : 수출 현황 요약
==============================================================================================*/
SELECT
     N'[A] 수출 현황 요약'                          AS REPORT_NM
    ,@FR_DT + N' ~ ' + @TO_DT                       AS 기간
    ,소스 = @SRC
    ,선적건수 = COUNT(DISTINCT E.DOC_NB)
    ,거래처수 = COUNT(DISTINCT E.TR_CD)
    ,품목수   = COUNT(DISTINCT E.ITEM_CD)
    ,수량계   = SUM(E.QT)
    ,외화금액계 = SUM(E.FOR_AM)
    ,원화금액계 = SUM(E.KRW_AM)
    ,평균환율 = CAST(CASE WHEN SUM(E.FOR_AM) <> 0
                          THEN SUM(E.KRW_AM) / SUM(E.FOR_AM) END AS DECIMAL(19,2))
    ,환종수 = COUNT(DISTINCT NULLIF(E.EXCH_FG, N''))
    ,평균_출고선적간격 = CAST(AVG(CASE WHEN E.ISU_DT IS NOT NULL AND E.SHIP_DT IS NOT NULL
                                       THEN CAST(DATEDIFF(DAY, CONVERT(DATE,E.ISU_DT),
                                                          CONVERT(DATE,E.SHIP_DT)) AS DECIMAL(9,2))
                                       END) AS DECIMAL(9,1))
    ,판정 = CASE
         WHEN COUNT(*) = 0             THEN N'1.★수출 실적 없음 - @EXP_SOFG / 환종 조건 확인'
         WHEN @HAS_BL = 0              THEN N'2.선적 테이블(LEBL) 없음 - 출고 기준 대체 사용 중'
         WHEN SUM(E.FOR_AM) = 0        THEN N'3.★외화 금액이 전부 0 - LEBL_D 금액 컬럼 확인'
         ELSE N'0.정상' END
FROM   #EXP E
;


/*==============================================================================================
  ** 쿼리 B : 환종별 수출
==============================================================================================*/
SELECT
     N'[B] 환종별 수출'                             AS REPORT_NM
    ,환종 = CASE WHEN ISNULL(E.EXCH_FG, N'') = N'' THEN N'(미지정)' ELSE E.EXCH_FG END
    ,선적건수 = COUNT(DISTINCT E.DOC_NB)
    ,거래처수 = COUNT(DISTINCT E.TR_CD)
    ,수량계   = SUM(E.QT)
    ,외화금액 = SUM(E.FOR_AM)
    ,원화금액 = SUM(E.KRW_AM)
    ,평균환율 = CAST(CASE WHEN SUM(E.FOR_AM) <> 0
                          THEN SUM(E.KRW_AM) / SUM(E.FOR_AM) END AS DECIMAL(19,2))
    ,최저환율 = MIN(NULLIF(E.EXCH_RT, 0))
    ,최고환율 = MAX(NULLIF(E.EXCH_RT, 0))
    ,환율변동폭_PCT = CAST(CASE WHEN MIN(NULLIF(E.EXCH_RT,0)) <> 0
                                THEN (MAX(NULLIF(E.EXCH_RT,0)) / MIN(NULLIF(E.EXCH_RT,0)) - 1) * 100
                                END AS DECIMAL(9,1))
    ,원화비중_PCT = CAST(SUM(E.KRW_AM) * 100.0
                         / NULLIF(SUM(SUM(E.KRW_AM)) OVER (), 0) AS DECIMAL(5,1))
    ,비고 = CASE WHEN MIN(NULLIF(E.EXCH_RT,0)) <> 0
                  AND (MAX(NULLIF(E.EXCH_RT,0)) / MIN(NULLIF(E.EXCH_RT,0)) - 1) * 100 > 10
                 THEN N'★ 환율 변동폭 10% 초과 - 환리스크 확인'
                 ELSE N'-' END
FROM   #EXP E
GROUP BY CASE WHEN ISNULL(E.EXCH_FG, N'') = N'' THEN N'(미지정)' ELSE E.EXCH_FG END
ORDER BY 원화금액 DESC
;


/*==============================================================================================
  ** 쿼리 C : 거래처(바이어)별 수출
==============================================================================================*/
SELECT
     N'[C] 거래처별 수출'                           AS REPORT_NM
    ,E.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,주환종 = MAX(E.EXCH_FG)
    ,선적건수 = COUNT(DISTINCT E.DOC_NB)
    ,품목수   = COUNT(DISTINCT E.ITEM_CD)
    ,수량계   = SUM(E.QT)
    ,외화금액 = SUM(E.FOR_AM)
    ,원화금액 = SUM(E.KRW_AM)
    ,최초선적일 = MIN(E.SHIP_DT)
    ,최종선적일 = MAX(E.SHIP_DT)
    ,평균_출고선적간격 = CAST(AVG(CASE WHEN E.ISU_DT IS NOT NULL
                                       THEN CAST(DATEDIFF(DAY, CONVERT(DATE,E.ISU_DT),
                                                          CONVERT(DATE,E.SHIP_DT)) AS DECIMAL(9,2))
                                       END) AS DECIMAL(9,1))
    ,매출비중_PCT = CAST(SUM(E.KRW_AM) * 100.0
                         / NULLIF(SUM(SUM(E.KRW_AM)) OVER (), 0) AS DECIMAL(5,1))
    ,채권잔액 = (SELECT SUM(CAST(ISNULL(X.OPEN_AM,0) AS DECIMAL(19,4)))
                 FROM LOPN_CRISU X WITH (NOLOCK)
                 WHERE X.CO_CD=@CO_CD AND X.TR_CD=E.TR_CD)
FROM       #EXP   E
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD = E.TR_CD
GROUP BY E.TR_CD, T.TR_NM
ORDER BY 원화금액 DESC
;


/*==============================================================================================
  ** 쿼리 D : 품목별 수출
==============================================================================================*/
SELECT
     N'[D] 품목별 수출'                             AS REPORT_NM
    ,E.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'2' THEN N'제품' WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품' ELSE I.ACCT_FG END
    ,거래처수 = COUNT(DISTINCT E.TR_CD)
    ,선적건수 = COUNT(DISTINCT E.DOC_NB)
    ,수량계   = SUM(E.QT)
    ,외화금액 = SUM(E.FOR_AM)
    ,원화금액 = SUM(E.KRW_AM)
    ,평균단가_외화 = CAST(SUM(E.FOR_AM) / NULLIF(SUM(E.QT), 0) AS DECIMAL(19,4))
    ,평균단가_원화 = CAST(SUM(E.KRW_AM) / NULLIF(SUM(E.QT), 0) AS DECIMAL(19,2))
    ,매출비중_PCT = CAST(SUM(E.KRW_AM) * 100.0
                         / NULLIF(SUM(SUM(E.KRW_AM)) OVER (), 0) AS DECIMAL(5,1))
FROM       #EXP  E
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = E.ITEM_CD
GROUP BY E.ITEM_CD, I.ITEM_NM, I.SPEC, I.UNIT_CD, I.ACCT_FG
ORDER BY 원화금액 DESC
;


/*==============================================================================================
  ** 쿼리 E : 월별 수출 추이
==============================================================================================*/
SELECT
     N'[E] 월별 수출 추이'                          AS REPORT_NM
    ,LEFT(E.SHIP_DT, 6)                             AS 선적월
    ,선적건수 = COUNT(DISTINCT E.DOC_NB)
    ,거래처수 = COUNT(DISTINCT E.TR_CD)
    ,수량계   = SUM(E.QT)
    ,외화금액 = SUM(E.FOR_AM)
    ,원화금액 = SUM(E.KRW_AM)
    ,평균환율 = CAST(CASE WHEN SUM(E.FOR_AM) <> 0
                          THEN SUM(E.KRW_AM) / SUM(E.FOR_AM) END AS DECIMAL(19,2))
    ,전월대비_원화_PCT = CAST(
         (SUM(E.KRW_AM) / NULLIF(LAG(SUM(E.KRW_AM)) OVER (ORDER BY LEFT(E.SHIP_DT,6)), 0) - 1) * 100
         AS DECIMAL(9,1))
    ,전월대비_외화_PCT = CAST(
         (SUM(E.FOR_AM) / NULLIF(LAG(SUM(E.FOR_AM)) OVER (ORDER BY LEFT(E.SHIP_DT,6)), 0) - 1) * 100
         AS DECIMAL(9,1))
FROM   #EXP E
GROUP BY LEFT(E.SHIP_DT, 6)
ORDER BY 선적월
;


/*==============================================================================================
  ** 쿼리 F : 선적 상세 + 데이터 점검
==============================================================================================*/
SELECT TOP 200
     N'[F] 선적 상세'                               AS REPORT_NM
    ,E.DOC_NB                                       AS 문서번호
    ,E.SHIP_DT                                      AS 선적일
    ,E.ISU_DT                                       AS 출고일
    ,출고_선적간격 = CASE WHEN E.ISU_DT IS NOT NULL
                          THEN DATEDIFF(DAY, CONVERT(DATE,E.ISU_DT), CONVERT(DATE,E.SHIP_DT)) END
    ,E.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,E.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,E.QT                                           AS 수량
    ,E.EXCH_FG                                      AS 환종
    ,E.EXCH_RT                                      AS 환율
    ,E.FOR_AM                                       AS 외화금액
    ,E.KRW_AM                                       AS 원화금액
    ,검증 = CASE
         WHEN E.FOR_AM <> 0 AND E.EXCH_RT <> 0
          AND ABS(E.FOR_AM * E.EXCH_RT - E.KRW_AM) > 1
              THEN N'★ 외화×환율 ≠ 원화 - 환산 확인'
         WHEN E.ISU_DT IS NOT NULL
          AND DATEDIFF(DAY, CONVERT(DATE,E.ISU_DT), CONVERT(DATE,E.SHIP_DT)) < 0
              THEN N'★ 선적일이 출고일보다 빠름'
         WHEN E.ISU_DT IS NOT NULL
          AND DATEDIFF(DAY, CONVERT(DATE,E.ISU_DT), CONVERT(DATE,E.SHIP_DT)) > 30
              THEN N'출고 후 30일 초과 선적 - 재고 체류'
         ELSE N'-' END
FROM       #EXP   E
LEFT  JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = E.ITEM_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = E.TR_CD
ORDER BY E.SHIP_DT DESC, E.KRW_AM DESC
;

SELECT
     N'[F-2] 데이터 점검'                           AS REPORT_NM
    ,LEBL_존재   = CASE WHEN OBJECT_ID(N'dbo.LEBL'  ,N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,LEBL_D_존재 = CASE WHEN OBJECT_ID(N'dbo.LEBL_D',N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,사용소스 = @SRC
    ,선적일컬럼 = ISNULL(@BL_DT , N'(미확인)')
    ,외화금액컬럼 = ISNULL(@BL_FAM, N'(미확인)')
    ,원화금액컬럼 = ISNULL(@BL_AM , N'(미확인)')
    ,적재행수 = (SELECT COUNT(*) FROM #EXP)
    ,판정 = CASE
         WHEN (SELECT COUNT(*) FROM #EXP) = 0
              THEN N'1.★수출 데이터 없음 - @EXP_SOFG 값 또는 환종 운영 확인'
         WHEN @HAS_BL = 0
              THEN N'2.선적 테이블 미사용 - 출고 기준이므로 선적일=출고일 이다'
         WHEN (SELECT SUM(FOR_AM) FROM #EXP) = 0
              THEN N'3.★외화 금액 없음 - LEBL_D 금액 컬럼을 확인해 1번 블록에 추가'
         ELSE N'0.정상' END
;


DROP TABLE #EXP;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 선적 테이블 실존 / 컬럼  ★ 명세서 미등재
     SELECT name FROM sys.tables WHERE name LIKE 'LEBL%' OR name LIKE '%EXP%';
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('LEBL')   ORDER BY column_id;
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('LEBL_D') ORDER BY column_id;
     --> 선적일 후보 : BL_DT, SHIP_DT, EBL_DT, ONBOARD_DT
        외화 후보   : FOR_AM, EXP_AM, BL_AM, ISUF_AM
        원화 후보   : KRW_AM, ISUH_AM, ISUG_AM, WON_AM

  -- (2) 수출 거래 구분  ★ @EXP_SOFG 의 근거. 기본값 '1,3,4' 는 추정치다
     SELECT SO_FG, EXCH_FG, COUNT(*) 건수, SUM(ISUH_AM) 금액
     FROM   LDELIVER H INNER JOIN LDELIVER_D D ON D.CO_CD=H.CO_CD AND D.ISU_NB=H.ISU_NB
     WHERE  H.CO_CD='1000' GROUP BY SO_FG, EXCH_FG ORDER BY 건수 DESC;
     --> 외화(EXCH_FG<>'KRW')가 붙은 SO_FG 가 수출 구분이다. 그 값을 @EXP_SOFG 에 넣을 것.

  -- (3) 환종 운영
     SELECT EXCH_FG, COUNT(*), MIN(EXCH_RT), MAX(EXCH_RT) FROM LDELIVER
     WHERE CO_CD='1000' GROUP BY EXCH_FG;

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **선적 테이블이 없으면 출고 기준으로 대체**한다(@FALLBACK='1'). 이 경우 선적일 = 출고일이
     되어 **실제 선적 시점과 다르다.** 매출 인식 시점 분석에는 쓸 수 없고, 물량 추이만 볼 것.

  2) `@EXP_SOFG` 기본값 `'1,3,4'` 는 **추정치**다. 확인 (2)번을 먼저 돌려 실제 값으로 바꾸지
     않으면 수출 건이 누락되거나 국내 건이 섞인다. 이 파일에서 가장 먼저 확인할 항목이다.

  3) **통관·관세·운임(CIF/FOB)을 반영하지 않는다.** 수출 원가와 이익을 보려면 수입원가 계산과
     같은 별도 처리가 필요하다. 여기서는 매출 실적만 본다.

  4) L/C 네고·T/T 등 수금 조건별 회수 기간을 구분하지 않는다. 수출 채권 회수는
     `S04_매출수금_채권KPI.sql` 에서 거래처별로 볼 것 (국내와 회수 리드타임이 크게 다르다).

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   S05_판매분석_다축.sql    : 국내 포함 전체 판매 추이
   S04_매출수금_채권KPI.sql : 수출 채권 회수
   P01_청구발주입고_진행현황.sql : 쿼리 F(수입 L/C 건) — 반대 방향
==============================================================================================*/
