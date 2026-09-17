/*==============================================================================================
  [ iCUBE ] S-12  거래처별 단가 이력                                                 (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 거래처별 품목 단가가 **언제 어떻게 바뀌었는가**, 그리고 **실제 거래단가가 등록단가와
         맞는가**. 단가 관리가 느슨하면 이익이 조용히 새어 나간다.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ ★ LCUSTM_UM 의 핵심 규칙 ]
  ----------------------------------------------------------------------------------------------
     **`NO_SQ = 999` 가 현재 단가**다. 나머지 순번은 과거 이력이다.
     이 규칙을 모르고 전체를 집계하면 과거 단가가 섞여 값이 틀어진다.
     본 쿼리는 `999` 를 현재단가로, `< 999` 를 이력으로 명확히 구분한다.

  ----------------------------------------------------------------------------------------------
  [ 구성 ]
  ----------------------------------------------------------------------------------------------
     쿼리 A  현재 단가 목록 (NO_SQ=999)
     쿼리 B  단가 변경 이력 (순번 순서대로 → 변동률)
     쿼리 C  최근 변동 큰 품목
     쿼리 D  **실제 거래단가 vs 등록단가 괴리**   ← 이 파일의 핵심
     쿼리 E  단가 미등록 (거래는 있는데 마스터 없음)
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@FR_DT    NVARCHAR(8)  = N'20260101'     -- 거래 비교 기간
    ,@TO_DT    NVARCHAR(8)  = N'20261231'
    ,@TR_CD    NVARCHAR(10) = NULL
    ,@ITEM_CD  NVARCHAR(25) = NULL
    ,@TH_GAP   DECIMAL(5,1) = 5.0             -- 등록단가 대비 괴리 경고 (%)
    ,@TH_CHG   DECIMAL(5,1) = 10.0            -- 단가 변동 경고 (%)
;

DECLARE @HAS_UM BIT = 0;
IF OBJECT_ID(N'dbo.LCUSTM_UM', N'U') IS NOT NULL SET @HAS_UM = 1;

IF OBJECT_ID('tempdb..#UM')  IS NOT NULL DROP TABLE #UM;
IF OBJECT_ID('tempdb..#ACT') IS NOT NULL DROP TABLE #ACT;


/*==============================================================================================
  1. #UM : 단가 마스터 (현재 + 이력)
==============================================================================================*/
CREATE TABLE #UM (
     TR_CD   NVARCHAR(10)
    ,ITEM_CD NVARCHAR(25)
    ,NO_SQ   INT
    ,UM      DECIMAL(19,6)
    ,ST_DT   NVARCHAR(8)
    ,IS_CUR  NCHAR(1)
);

IF @HAS_UM = 1
BEGIN
    DECLARE @SQL NVARCHAR(MAX), @DTCOL NVARCHAR(30);
    SELECT TOP 1 @DTCOL = name FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.LCUSTM_UM')
      AND name IN (N'ST_DT', N'APP_DT', N'FR_DT', N'REG_DT', N'UM_DT')
    ORDER BY CASE name WHEN N'ST_DT' THEN 1 WHEN N'APP_DT' THEN 2 ELSE 3 END;

    SET @SQL = N'
        INSERT INTO #UM (TR_CD, ITEM_CD, NO_SQ, UM, ST_DT, IS_CUR)
        SELECT U.TR_CD, U.ITEM_CD, CAST(ISNULL(U.NO_SQ, 0) AS INT)
              ,CAST(ISNULL(U.UM, 0) AS DECIMAL(19,6))
              ,' + CASE WHEN @DTCOL IS NOT NULL THEN N'U.' + QUOTENAME(@DTCOL) ELSE N'NULL' END + N'
              ,CASE WHEN ISNULL(U.NO_SQ, 0) = 999 THEN N''1'' ELSE N''0'' END
        FROM   dbo.LCUSTM_UM U WITH (NOLOCK)
        WHERE  U.CO_CD = @p_CO
          AND  ISNULL(U.USE_YN, N''1'') = N''1''
          AND  (@p_TR   IS NULL OR U.TR_CD   = @p_TR)
          AND  (@p_ITEM IS NULL OR U.ITEM_CD = @p_ITEM)';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_TR NVARCHAR(10), @p_ITEM NVARCHAR(25)'
            ,@p_CO=@CO_CD, @p_TR=@TR_CD, @p_ITEM=@ITEM_CD;
        PRINT N'[1] LCUSTM_UM : ' + CAST((SELECT COUNT(*) FROM #UM) AS NVARCHAR(20)) + N' 행 (현재단가 '
              + CAST((SELECT COUNT(*) FROM #UM WHERE IS_CUR = N'1') AS NVARCHAR(20)) + N')';
    END TRY
    BEGIN CATCH
        SET @HAS_UM = 0;
        PRINT N'[1] ★ LCUSTM_UM 조회 실패 : ' + ERROR_MESSAGE();
    END CATCH
END
ELSE PRINT N'[1] LCUSTM_UM 없음 - 거래처별 단가 미운영';

CREATE CLUSTERED INDEX IX_UM ON #UM (TR_CD, ITEM_CD, NO_SQ);


/*==============================================================================================
  2. #ACT : 실제 거래단가 (매출마감 기준)
==============================================================================================*/
SELECT
     H.TR_CD
    ,D.ITEM_CD
    ,CNT     = COUNT(*)
    ,QT      = SUM(CAST(ISNULL(D.CLS_QT, 0) AS DECIMAL(19,6)))
    ,AM      = SUM(CAST(ISNULL(D.CLSG_AM, D.CLSH_AM) AS DECIMAL(19,4)))
    ,AVG_UM  = CAST(SUM(CAST(ISNULL(D.CLSG_AM, D.CLSH_AM) AS DECIMAL(19,4)))
                    / NULLIF(SUM(CAST(ISNULL(D.CLS_QT,0) AS DECIMAL(19,6))), 0) AS DECIMAL(19,6))
    ,MIN_UM  = MIN(CAST(NULLIF(D.UM, 0) AS DECIMAL(19,6)))
    ,MAX_UM  = MAX(CAST(NULLIF(D.UM, 0) AS DECIMAL(19,6)))
    ,LAST_DT = MAX(H.CLS_DT)
INTO #ACT
FROM       LSALECLS   H WITH (NOLOCK)
INNER JOIN LSALECLS_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.CLS_NB = H.CLS_NB
WHERE  H.CO_CD  = @CO_CD
  AND  H.CLS_DT BETWEEN @FR_DT AND @TO_DT
  AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
  AND  ISNULL(D.CLS_QT, 0) > 0
  AND  (@DIV_CD  IS NULL OR H.DIV_CD  = @DIV_CD)
  AND  (@TR_CD   IS NULL OR H.TR_CD   = @TR_CD)
  AND  (@ITEM_CD IS NULL OR D.ITEM_CD = @ITEM_CD)
GROUP BY H.TR_CD, D.ITEM_CD;
CREATE CLUSTERED INDEX IX_ACT ON #ACT (TR_CD, ITEM_CD);


/*==============================================================================================
  ** 쿼리 A : 현재 단가 목록  (NO_SQ = 999)
==============================================================================================*/
SELECT
     N'[A] 현재 단가 (NO_SQ=999)'                   AS REPORT_NM
    ,U.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,U.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,U.UM                                           AS 현재단가
    ,U.ST_DT                                        AS 적용일
    ,경과일 = CASE WHEN U.ST_DT IS NOT NULL
                   THEN DATEDIFF(DAY, CONVERT(DATE,U.ST_DT), CONVERT(DATE,@TO_DT)) END
    ,이력건수 = (SELECT COUNT(*) FROM #UM X
                 WHERE X.TR_CD=U.TR_CD AND X.ITEM_CD=U.ITEM_CD AND X.IS_CUR=N'0')
    ,직전단가 = (SELECT TOP 1 X.UM FROM #UM X
                 WHERE X.TR_CD=U.TR_CD AND X.ITEM_CD=U.ITEM_CD AND X.IS_CUR=N'0'
                 ORDER BY X.NO_SQ DESC)
    ,변동률_PCT = CAST(CASE WHEN (SELECT TOP 1 X.UM FROM #UM X
                                  WHERE X.TR_CD=U.TR_CD AND X.ITEM_CD=U.ITEM_CD AND X.IS_CUR=N'0'
                                  ORDER BY X.NO_SQ DESC) > 0
                            THEN (U.UM / (SELECT TOP 1 X.UM FROM #UM X
                                          WHERE X.TR_CD=U.TR_CD AND X.ITEM_CD=U.ITEM_CD AND X.IS_CUR=N'0'
                                          ORDER BY X.NO_SQ DESC) - 1) * 100 END AS DECIMAL(9,1))
    ,A.AVG_UM                                       AS 실거래_평균단가
    ,A.CNT                                          AS 거래건수
    ,A.LAST_DT                                      AS 최종거래일
    ,괴리율_PCT = CAST(CASE WHEN U.UM <> 0 AND A.AVG_UM IS NOT NULL
                            THEN (A.AVG_UM / U.UM - 1) * 100 END AS DECIMAL(9,1))
    ,판정 = CASE
         WHEN A.AVG_UM IS NULL                                        THEN N'9.거래 없음'
         WHEN U.UM = 0                                                THEN N'8.★단가 0 등록'
         WHEN ABS(A.AVG_UM / U.UM - 1) * 100 > @TH_GAP                THEN N'1.★실거래가 등록단가와 괴리'
         ELSE N'0.일치' END
FROM       #UM    U
LEFT  JOIN #ACT   A ON A.TR_CD = U.TR_CD AND A.ITEM_CD = U.ITEM_CD
LEFT  JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = U.ITEM_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = U.TR_CD
WHERE  U.IS_CUR = N'1'
ORDER BY 판정, ABS(ISNULL(괴리율_PCT, 0)) DESC
;


/*==============================================================================================
  ** 쿼리 B : 단가 변경 이력  (순번 순서 → 변동률)
==============================================================================================*/
SELECT
     N'[B] 단가 변경 이력'                          AS REPORT_NM
    ,U.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,U.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,U.NO_SQ                                        AS 순번
    ,구분 = CASE U.IS_CUR WHEN N'1' THEN N'★현재단가' ELSE N'이력' END
    ,U.UM                                           AS 단가
    ,U.ST_DT                                        AS 적용일
    ,직전단가 = LAG(U.UM) OVER (PARTITION BY U.TR_CD, U.ITEM_CD ORDER BY U.NO_SQ)
    ,변동액 = U.UM - LAG(U.UM) OVER (PARTITION BY U.TR_CD, U.ITEM_CD ORDER BY U.NO_SQ)
    ,변동률_PCT = CAST(CASE WHEN LAG(U.UM) OVER (PARTITION BY U.TR_CD, U.ITEM_CD ORDER BY U.NO_SQ) > 0
                            THEN (U.UM / LAG(U.UM) OVER (PARTITION BY U.TR_CD, U.ITEM_CD ORDER BY U.NO_SQ) - 1) * 100
                            END AS DECIMAL(9,1))
    ,변경간격일 = DATEDIFF(DAY,
                    CONVERT(DATE, LAG(U.ST_DT) OVER (PARTITION BY U.TR_CD, U.ITEM_CD ORDER BY U.NO_SQ)),
                    CONVERT(DATE, U.ST_DT))
FROM       #UM    U
LEFT  JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = U.ITEM_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = U.TR_CD
WHERE  EXISTS (SELECT 1 FROM #UM X
               WHERE X.TR_CD = U.TR_CD AND X.ITEM_CD = U.ITEM_CD AND X.IS_CUR = N'0')
ORDER BY U.TR_CD, U.ITEM_CD, U.NO_SQ
;


/*==============================================================================================
  ** 쿼리 C : 단가 변동 큰 품목  (최근 변경 기준)
==============================================================================================*/
;WITH X AS (
    SELECT
         U.TR_CD, U.ITEM_CD
        ,CUR_UM = MAX(CASE WHEN U.IS_CUR = N'1' THEN U.UM END)
        ,PRV_UM = MAX(CASE WHEN U.IS_CUR = N'0' THEN U.UM END)
        ,CNT    = COUNT(*)
        ,MIN_UM = MIN(U.UM)
        ,MAX_UM = MAX(U.UM)
        ,LAST_DT= MAX(U.ST_DT)
    FROM   #UM U
    GROUP BY U.TR_CD, U.ITEM_CD
    HAVING COUNT(*) > 1
)
SELECT
     N'[C] 단가 변동 큰 품목'                       AS REPORT_NM
    ,방향 = CASE WHEN X.CUR_UM > X.PRV_UM THEN N'1.인상' ELSE N'2.★인하' END
    ,X.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,X.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,X.PRV_UM                                       AS 직전단가
    ,X.CUR_UM                                       AS 현재단가
    ,변동액 = X.CUR_UM - X.PRV_UM
    ,변동률_PCT = CAST(CASE WHEN X.PRV_UM <> 0
                            THEN (X.CUR_UM / X.PRV_UM - 1) * 100 END AS DECIMAL(9,1))
    ,X.CNT                                          AS 이력건수
    ,X.MIN_UM                                       AS 최저단가
    ,X.MAX_UM                                       AS 최고단가
    ,전체변동폭_PCT = CAST(CASE WHEN X.MIN_UM <> 0
                                THEN (X.MAX_UM / X.MIN_UM - 1) * 100 END AS DECIMAL(9,1))
    ,X.LAST_DT                                      AS 최종적용일
    ,A.QT                                           AS 거래수량
    ,A.AM                                           AS 거래금액
    ,영향금액 = CAST((X.CUR_UM - X.PRV_UM) * ISNULL(A.QT, 0) AS DECIMAL(19,4))
    ,비고 = CASE
         WHEN X.PRV_UM <> 0 AND ABS(X.CUR_UM / X.PRV_UM - 1) * 100 > @TH_CHG * 3
              THEN N'★ 변동폭 30% 초과 - 단가 등록 오류 가능성 확인'
         WHEN X.CUR_UM < X.PRV_UM AND ISNULL(A.QT, 0) > 0
              THEN N'인하 - 이익률 영향 확인 (C-05)'
         ELSE N'-' END
FROM       X
LEFT  JOIN #ACT   A ON A.TR_CD = X.TR_CD AND A.ITEM_CD = X.ITEM_CD
LEFT  JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = X.ITEM_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = X.TR_CD
WHERE  X.PRV_UM IS NOT NULL AND X.CUR_UM IS NOT NULL
  AND  X.PRV_UM <> 0
  AND  ABS(X.CUR_UM / X.PRV_UM - 1) * 100 > @TH_CHG
ORDER BY ABS(영향금액) DESC
;


/*==============================================================================================
  ** 쿼리 D : 실거래단가 vs 등록단가 괴리  ★ 이 파일의 핵심
     ─ 등록단가와 다르게 팔리고 있다면 단가 관리가 통제되지 않는 것이다.
==============================================================================================*/
SELECT
     N'[D] 실거래 vs 등록단가 괴리'                 AS REPORT_NM
    ,구분 = CASE
         WHEN U.UM IS NULL                            THEN N'1.★단가 미등록'
         WHEN A.AVG_UM < U.UM * (1 - @TH_GAP/100)      THEN N'2.★등록단가보다 싸게 판매'
         WHEN A.AVG_UM > U.UM * (1 + @TH_GAP/100)      THEN N'3.등록단가보다 비싸게 판매'
         ELSE N'0.일치' END
    ,A.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,A.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.UNIT_CD                                      AS 단위
    ,U.UM                                           AS 등록단가
    ,A.AVG_UM                                       AS 실거래_평균단가
    ,A.MIN_UM                                       AS 실거래_최저
    ,A.MAX_UM                                       AS 실거래_최고
    ,단가편차_PCT = CAST(CASE WHEN A.MIN_UM <> 0
                              THEN (A.MAX_UM / A.MIN_UM - 1) * 100 END AS DECIMAL(9,1))
    ,괴리액 = CAST(A.AVG_UM - ISNULL(U.UM, 0) AS DECIMAL(19,4))
    ,괴리율_PCT = CAST(CASE WHEN ISNULL(U.UM, 0) <> 0
                            THEN (A.AVG_UM / U.UM - 1) * 100 END AS DECIMAL(9,1))
    ,A.CNT                                          AS 거래건수
    ,A.QT                                           AS 거래수량
    ,A.AM                                           AS 거래금액
    ,손익영향 = CAST((A.AVG_UM - ISNULL(U.UM, A.AVG_UM)) * A.QT AS DECIMAL(19,4))
    ,A.LAST_DT                                      AS 최종거래일
    ,조치 = CASE
         WHEN U.UM IS NULL
              THEN N'★ 단가 마스터 등록 - 실거래 평균 '
                   + CAST(CAST(A.AVG_UM AS DECIMAL(19,0)) AS NVARCHAR(30)) + N' 참고'
         WHEN A.AVG_UM < U.UM * (1 - @TH_GAP/100)
              THEN N'★ 할인 판매 중 - 승인 여부 확인 또는 단가 현실화'
         WHEN A.MIN_UM <> 0 AND (A.MAX_UM / A.MIN_UM - 1) * 100 > 20
              THEN N'★ 건별 단가 편차 20% 초과 - 단가 적용 일관성 없음'
         ELSE N'-' END
FROM       #ACT   A
LEFT  JOIN #UM    U ON U.TR_CD = A.TR_CD AND U.ITEM_CD = A.ITEM_CD AND U.IS_CUR = N'1'
LEFT  JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = A.ITEM_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = A.TR_CD
WHERE  U.UM IS NULL
   OR  ABS(A.AVG_UM / NULLIF(U.UM, 0) - 1) * 100 > @TH_GAP
ORDER BY 구분, ABS(손익영향) DESC
;


/*==============================================================================================
  ** 쿼리 E : 요약 + 데이터 점검
==============================================================================================*/
SELECT
     N'[E] 단가 관리 요약'                          AS REPORT_NM
    ,@FR_DT + N' ~ ' + @TO_DT                       AS 거래기간
    ,LCUSTM_UM_존재 = CASE WHEN @HAS_UM = 1 THEN N'O' ELSE N'X' END
    ,현재단가_건수 = (SELECT COUNT(*) FROM #UM WHERE IS_CUR = N'1')
    ,이력_건수     = (SELECT COUNT(*) FROM #UM WHERE IS_CUR = N'0')
    ,거래조합수    = (SELECT COUNT(*) FROM #ACT)
    ,단가등록된_거래조합 = (SELECT COUNT(*) FROM #ACT A
                            WHERE EXISTS (SELECT 1 FROM #UM U
                                          WHERE U.TR_CD=A.TR_CD AND U.ITEM_CD=A.ITEM_CD AND U.IS_CUR=N'1'))
    ,단가등록률_PCT = CAST((SELECT COUNT(*) FROM #ACT A
                            WHERE EXISTS (SELECT 1 FROM #UM U
                                          WHERE U.TR_CD=A.TR_CD AND U.ITEM_CD=A.ITEM_CD AND U.IS_CUR=N'1'))
                           * 100.0 / NULLIF((SELECT COUNT(*) FROM #ACT), 0) AS DECIMAL(5,1))
    ,괴리_조합수 = (SELECT COUNT(*) FROM #ACT A
                    INNER JOIN #UM U ON U.TR_CD=A.TR_CD AND U.ITEM_CD=A.ITEM_CD AND U.IS_CUR=N'1'
                    WHERE U.UM <> 0 AND ABS(A.AVG_UM / U.UM - 1) * 100 > @TH_GAP)
    ,NO_SQ_999_사용 = CASE WHEN (SELECT COUNT(*) FROM #UM WHERE NO_SQ = 999) > 0
                           THEN N'O (규칙대로 운영)' ELSE N'★X - 다른 방식으로 현재단가 관리' END
    ,판정 = CASE
         WHEN @HAS_UM = 0
              THEN N'1.★LCUSTM_UM 없음 - 거래처별 단가 미운영. 수주 시 단가 직접 입력 방식'
         WHEN (SELECT COUNT(*) FROM #UM WHERE NO_SQ = 999) = 0
              THEN N'2.★NO_SQ=999 가 없다 - 현재단가 판정 규칙을 확인할 것'
         WHEN (SELECT COUNT(*) FROM #ACT A
               WHERE EXISTS (SELECT 1 FROM #UM U
                             WHERE U.TR_CD=A.TR_CD AND U.ITEM_CD=A.ITEM_CD AND U.IS_CUR=N'1'))
              * 100.0 / NULLIF((SELECT COUNT(*) FROM #ACT), 0) < 50
              THEN N'3.★단가 등록률 50% 미만 - 단가 통제가 되지 않는다'
         ELSE N'0.정상' END
;


DROP TABLE #UM, #ACT;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) NO_SQ 규칙 확인  ★ 이 파일의 전제
     SELECT NO_SQ, COUNT(*) FROM LCUSTM_UM WHERE CO_CD='1000' GROUP BY NO_SQ ORDER BY NO_SQ;
     --> 999 가 있어야 정상. 없으면 다른 방식(적용일자 최신 등)으로 현재단가를 관리하는
        사이트이므로 1번 블록의 IS_CUR 판정을 수정할 것.

  -- (2) 적용일자 컬럼  ★ 본 쿼리는 자동 탐색한다
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('LCUSTM_UM') ORDER BY column_id;
     --> 후보 : ST_DT, APP_DT, FR_DT, REG_DT, UM_DT

  -- (3) 단가 적용 방식  ★ 거래처별 단가를 실제로 쓰는지
     SELECT COUNT(*) FROM LCUSTM_UM WHERE CO_CD='1000';
     --> 0 이면 수주 화면에서 단가를 직접 입력하는 사이트다. 이 경우 쿼리 D 의
        '단가 미등록' 이 전부 잡히므로, 쿼리 D 는 실거래 단가 편차만 보는 용도로 쓸 것.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **실거래 단가는 매출마감 기준 가중평균**이다. 기간 내 단가가 바뀌었으면 평균이 중간값이
     되어 등록단가 어느 쪽과도 맞지 않는다. 쿼리 D 의 `단가편차_PCT`(최고/최저)가 크면
     기간을 좁혀 다시 볼 것.

  2) **할인·판촉 단가를 구분하지 않는다.** 정당한 할인도 '등록단가보다 싸게 판매'로 잡힌다.
     할인 사유를 관리항목으로 남기는 사이트라면 그 축을 추가해야 한다.

  3) 단가 이력의 **적용 기간(종료일)을 보지 않는다.** 순번 순서만으로 시계열을 구성하므로,
     순번과 적용일 순서가 어긋난 데이터가 있으면 변동률이 잘못 나온다. 쿼리 B 의
     `변경간격일` 이 음수면 그 경우다.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   C05_매출이익_분석.sql   : 단가 괴리가 이익에 미친 영향
   S05_판매분석_다축.sql   : 품목군별 평균단가 추이
   P07_매입단가_추이분석.sql : 반대 방향 (매입단가)
==============================================================================================*/
