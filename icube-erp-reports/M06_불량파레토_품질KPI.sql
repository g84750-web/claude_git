/*==============================================================================================
  [ iCUBE ] M-06  불량 Pareto · 품질 KPI                                             (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 양품률/불량률을 KPI 로 확정하고, 불량을 **코드별 Pareto(누적구성비)** 로 분해해
         "무엇부터 고칠 것인가"를 숫자로 정한다.

  DBMS : MS-SQL Server 2012 이상 (T-SQL)   ★ 2008 R2 불가 : LAG(), OVER 프레임 (ROWS/RANGE BETWEEN), 집계 SUM() OVER(ORDER BY …)

  ----------------------------------------------------------------------------------------------
  [ 소스 — 2계통을 구분해서 쓴다 ]
  ----------------------------------------------------------------------------------------------
     (계통 1) 실적 기준      LORCV_H            BAD_YN='1' 인 실적 = 불량
                             → 항상 존재. **KPI 산출의 기준 소스**
     (계통 2) 검사 기준      LQC_INSP_D         불량내역 (불량코드별 수량)
                             LQC_INSP_DOCU      검사내역
                             LBAD / LBADGRP     불량유형 / 불량그룹  ※ 명세서 누락
                             → **불량 원인 분해(Pareto)의 유일한 소스**. 없으면 쿼리 C·D 생략

     계통 2 가 없는 사이트가 많다. 그래서 KPI(쿼리 A·B·F·G)는 계통 1 만으로 동작하게 했고,
     Pareto(쿼리 C·D)만 `OBJECT_ID` + `sys.columns` 가드로 분리했다.

  ----------------------------------------------------------------------------------------------
  [ 산식 ]
  ----------------------------------------------------------------------------------------------
     양품수량 = SUM(ITEM_QT) WHERE SUB_TP='0' AND BAD_YN='0'
     불량수량 = SUM(ITEM_QT) WHERE BAD_YN='1'
     재작업   = SUM(ITEM_QT) WHERE REWORK_YN='1'

     양품률 = 양품수량 / (양품수량 + 불량수량) * 100          ← ★ KPI (목표 97%)
     불량률 = 불량수량 / (양품수량 + 불량수량) * 100
     직행률(FTT) = (양품수량 - 재작업수량) / (양품수량 + 불량수량) * 100

     Pareto  구성비   = 코드별 불량수량 / 전체 불량수량 * 100
             누적구성비 = 내림차순 누적 합계        ← 80% 선까지가 '핵심 소수'

  ----------------------------------------------------------------------------------------------
  [ 반드시 지킨 것 ]
  ----------------------------------------------------------------------------------------------
   1. **부산물(`SUB_TP='1'`)을 양품에 넣지 않는다.** 넣으면 양품률이 부풀려진다.
   2. **재작업(`REWORK_YN='1'`)은 양품이지만 직행이 아니다.** 양품률과 직행률을 분리한다.
      양품률만 보면 "고쳐서 통과시킨" 물량이 품질 문제로 보이지 않는다.
   3. 불량코드가 없으면 개선 대상을 특정할 수 없다. 쿼리 H 가 **검사 등록률을 먼저 측정**한다.
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터   ─ 목표선은 EIS 기본값(양품률 97%)을 채웠다.
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@FR_DT    NVARCHAR(8)  = N'20260101'     -- 실적일 FROM
    ,@TO_DT    NVARCHAR(8)  = N'20261231'
    ,@ITEM_CD  NVARCHAR(25) = NULL
    ,@WO_CD    NVARCHAR(20) = NULL
    ,@PROC_CD  NVARCHAR(10) = NULL            -- 특정 공정
    ,@DEPT_CD  NVARCHAR(10) = NULL

    ,@TARGET   DECIMAL(5,1) = 97.0            -- ★ 목표 양품률 (%)  [EIS 기본값]
    ,@PARETO   DECIMAL(5,1) = 80.0            -- Pareto 핵심 소수 기준 누적구성비 (%)
    ,@MIN_QT   DECIMAL(19,6) = 0              -- 품목별 분석 최소 생산량 (표본 확보)
;

DECLARE @SQL NVARCHAR(MAX);
DECLARE @HAS_INSP BIT = 0, @HAS_BAD BIT = 0, @BADCOL NVARCHAR(30) = NULL, @QTCOL NVARCHAR(30) = NULL;

IF OBJECT_ID('tempdb..#RCV') IS NOT NULL DROP TABLE #RCV;
IF OBJECT_ID('tempdb..#BAD') IS NOT NULL DROP TABLE #BAD;


/*==============================================================================================
  1. #RCV : 생산실적  (계통 1 — KPI 기준 소스)
==============================================================================================*/
SELECT
     R.WR_CD
    ,WO_CD   = ISNULL(R.WO_CD  , N'')
    ,PROC_CD = ISNULL(R.PROC_CD, N'')
    ,WC_CD   = ISNULL(R.WC_CD  , N'')
    ,R.ITEM_CD
    ,R.WR_DT
    ,R.DEPT_CD
    ,R.EMP_CD
    ,SUB_TP    = ISNULL(R.SUB_TP   , N'0')
    ,BAD_YN    = ISNULL(R.BAD_YN   , N'0')
    ,REWORK_YN = ISNULL(R.REWORK_YN, N'0')
    ,ITEM_QT   = CAST(ISNULL(R.ITEM_QT, 0) AS DECIMAL(19,6))
INTO #RCV
FROM       LORCV_H R WITH (NOLOCK)
LEFT  JOIN SITEM   I WITH (NOLOCK) ON I.CO_CD = R.CO_CD AND I.ITEM_CD = R.ITEM_CD
WHERE  R.CO_CD = @CO_CD
  AND  R.WR_DT BETWEEN @FR_DT AND @TO_DT
  AND  ISNULL(R.USE_YN, N'1') = N'1'
  AND  (@DIV_CD  IS NULL OR R.DIV_CD  = @DIV_CD)
  AND  (@ITEM_CD IS NULL OR R.ITEM_CD = @ITEM_CD)
  AND  (@WO_CD   IS NULL OR R.WO_CD   = @WO_CD)
  AND  (@PROC_CD IS NULL OR R.PROC_CD = @PROC_CD)
  AND  (@DEPT_CD IS NULL OR R.DEPT_CD = @DEPT_CD)
  AND  ISNULL(I.S_CD, N'') <> N'Z00'
;
CREATE CLUSTERED INDEX IX_RCV ON #RCV (ITEM_CD, WR_DT);
PRINT N'[1] 생산실적 : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 건';


/*==============================================================================================
  2. #BAD : 불량내역 (계통 2 — 있을 때만)
     ─ LQC_INSP_D 는 명세서상 '실적검사 디테일(불량내역)'. 컬럼명이 사이트/버전에 따라
       다를 수 있어 sys.columns 로 실제 컬럼을 찾아 동적으로 조립한다.
==============================================================================================*/
CREATE TABLE #BAD (
     WR_CD   NVARCHAR(20)
    ,BAD_CD  NVARCHAR(20)
    ,BAD_QT  DECIMAL(19,6)
);

IF OBJECT_ID(N'dbo.LQC_INSP_D', N'U') IS NOT NULL
BEGIN
    -- 불량코드 컬럼 찾기
    SELECT TOP 1 @BADCOL = name FROM sys.columns
    WHERE  object_id = OBJECT_ID(N'dbo.LQC_INSP_D')
      AND  name IN (N'BAD_CD', N'BADCD', N'BAD_TP', N'BADITEM_CD')
    ORDER BY CASE name WHEN N'BAD_CD' THEN 1 WHEN N'BADCD' THEN 2 ELSE 3 END;

    -- 불량수량 컬럼 찾기
    SELECT TOP 1 @QTCOL = name FROM sys.columns
    WHERE  object_id = OBJECT_ID(N'dbo.LQC_INSP_D')
      AND  name IN (N'BAD_QT', N'INSP_QT', N'QT', N'ITEM_QT')
    ORDER BY CASE name WHEN N'BAD_QT' THEN 1 WHEN N'INSP_QT' THEN 2 ELSE 3 END;

    IF @BADCOL IS NOT NULL AND @QTCOL IS NOT NULL
    BEGIN
        SET @HAS_INSP = 1;
        SET @SQL = N'
            INSERT INTO #BAD (WR_CD, BAD_CD, BAD_QT)
            SELECT D.WR_CD, D.' + QUOTENAME(@BADCOL) + N'
                  ,SUM(CAST(ISNULL(D.' + QUOTENAME(@QTCOL) + N', 0) AS DECIMAL(19,6)))
            FROM   dbo.LQC_INSP_D D WITH (NOLOCK)
            WHERE  D.CO_CD = @p_CO
              AND  ISNULL(D.USE_YN, N''1'') = N''1''
              AND  EXISTS (SELECT 1 FROM #RCV R WHERE R.WR_CD = D.WR_CD)
            GROUP BY D.WR_CD, D.' + QUOTENAME(@BADCOL);
        BEGIN TRY
            EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4)', @p_CO = @CO_CD;
            PRINT N'[2] 불량내역 : LQC_INSP_D (' + @BADCOL + N'/' + @QTCOL + N') '
                  + CAST((SELECT COUNT(*) FROM #BAD) AS NVARCHAR(20)) + N' 행';
        END TRY
        BEGIN CATCH
            SET @HAS_INSP = 0;
            PRINT N'[2] LQC_INSP_D 조회 실패 (' + ERROR_MESSAGE() + N') - Pareto 생략';
        END CATCH
    END
    ELSE
        PRINT N'[2] LQC_INSP_D 에 불량코드/수량 컬럼을 찾지 못함 - Pareto 생략';
END
ELSE
    PRINT N'[2] LQC_INSP_D 없음 - Pareto 생략 (KPI 는 정상 동작)';

CREATE CLUSTERED INDEX IX_BAD ON #BAD (BAD_CD);

IF OBJECT_ID(N'dbo.LBAD', N'U') IS NOT NULL SET @HAS_BAD = 1;


/*==============================================================================================
  ** 쿼리 A : 전사 품질 KPI 요약  ★ 목표 대비 판정
==============================================================================================*/
SELECT
     N'[A] 품질 KPI 요약'                           AS REPORT_NM
    ,@FR_DT + N' ~ ' + @TO_DT                       AS 기간
    ,@TARGET                                        AS 목표_양품률_PCT
    ,COUNT(*)                                       AS 실적건수
    ,COUNT(DISTINCT R.ITEM_CD)                      AS 생산품목수
    ,COUNT(DISTINCT NULLIF(R.WO_CD, N''))           AS 지시수

    ,양품수량 = SUM(CASE WHEN R.SUB_TP = N'0' AND R.BAD_YN = N'0' THEN R.ITEM_QT ELSE 0 END)
    ,불량수량 = SUM(CASE WHEN R.BAD_YN = N'1' THEN R.ITEM_QT ELSE 0 END)
    ,부산물수량 = SUM(CASE WHEN R.SUB_TP = N'1' THEN R.ITEM_QT ELSE 0 END)
    ,재작업수량 = SUM(CASE WHEN R.REWORK_YN = N'1' THEN R.ITEM_QT ELSE 0 END)
    ,검사대상계 = SUM(CASE WHEN R.SUB_TP = N'0' THEN R.ITEM_QT ELSE 0 END)

    ,양품률_PCT = CAST(SUM(CASE WHEN R.SUB_TP=N'0' AND R.BAD_YN=N'0' THEN R.ITEM_QT ELSE 0 END)
                       / NULLIF(SUM(CASE WHEN R.SUB_TP=N'0' THEN R.ITEM_QT ELSE 0 END), 0) * 100
                       AS DECIMAL(5,2))
    ,불량률_PCT = CAST(SUM(CASE WHEN R.BAD_YN=N'1' THEN R.ITEM_QT ELSE 0 END)
                       / NULLIF(SUM(CASE WHEN R.SUB_TP=N'0' THEN R.ITEM_QT ELSE 0 END), 0) * 100
                       AS DECIMAL(5,2))
    ,직행률_PCT = CAST((SUM(CASE WHEN R.SUB_TP=N'0' AND R.BAD_YN=N'0' THEN R.ITEM_QT ELSE 0 END)
                        - SUM(CASE WHEN R.REWORK_YN=N'1' THEN R.ITEM_QT ELSE 0 END))
                       / NULLIF(SUM(CASE WHEN R.SUB_TP=N'0' THEN R.ITEM_QT ELSE 0 END), 0) * 100
                       AS DECIMAL(5,2))
    ,재작업률_PCT = CAST(SUM(CASE WHEN R.REWORK_YN=N'1' THEN R.ITEM_QT ELSE 0 END)
                         / NULLIF(SUM(CASE WHEN R.SUB_TP=N'0' THEN R.ITEM_QT ELSE 0 END), 0) * 100
                         AS DECIMAL(5,2))
    ,불량발생건수 = SUM(CASE WHEN R.BAD_YN = N'1' THEN 1 ELSE 0 END)
    ,불량발생품목수 = COUNT(DISTINCT CASE WHEN R.BAD_YN = N'1' THEN R.ITEM_CD END)

    ,판정 = CASE
         WHEN CAST(SUM(CASE WHEN R.SUB_TP=N'0' AND R.BAD_YN=N'0' THEN R.ITEM_QT ELSE 0 END)
                   / NULLIF(SUM(CASE WHEN R.SUB_TP=N'0' THEN R.ITEM_QT ELSE 0 END),0) * 100
                   AS DECIMAL(5,2)) >= @TARGET                              THEN N'0.목표 달성'
         WHEN CAST(SUM(CASE WHEN R.SUB_TP=N'0' AND R.BAD_YN=N'0' THEN R.ITEM_QT ELSE 0 END)
                   / NULLIF(SUM(CASE WHEN R.SUB_TP=N'0' THEN R.ITEM_QT ELSE 0 END),0) * 100
                   AS DECIMAL(5,2)) >= @TARGET - 2                          THEN N'1.목표 근접(2%p 이내)'
         ELSE N'2.★목표 미달' END
    ,목표대비_PCTP = CAST(SUM(CASE WHEN R.SUB_TP=N'0' AND R.BAD_YN=N'0' THEN R.ITEM_QT ELSE 0 END)
                          / NULLIF(SUM(CASE WHEN R.SUB_TP=N'0' THEN R.ITEM_QT ELSE 0 END),0) * 100
                          - @TARGET AS DECIMAL(5,2))
    ,불량코드분석 = CASE WHEN @HAS_INSP = 1 THEN N'가능 (쿼리 C·D 참조)'
                         ELSE N'★ 불가 - LQC_INSP_D 없음. 원인 분해 불가' END
FROM   #RCV R
;


/*==============================================================================================
  ** 쿼리 B : 월별 품질 추이  (대시보드 라인 차트)
==============================================================================================*/
SELECT
     N'[B] 월별 품질 추이'                          AS REPORT_NM
    ,LEFT(R.WR_DT, 6)                               AS 실적월
    ,COUNT(*)                                       AS 실적건수
    ,양품수량 = SUM(CASE WHEN R.SUB_TP=N'0' AND R.BAD_YN=N'0' THEN R.ITEM_QT ELSE 0 END)
    ,불량수량 = SUM(CASE WHEN R.BAD_YN=N'1' THEN R.ITEM_QT ELSE 0 END)
    ,재작업수량 = SUM(CASE WHEN R.REWORK_YN=N'1' THEN R.ITEM_QT ELSE 0 END)
    ,양품률_PCT = CAST(SUM(CASE WHEN R.SUB_TP=N'0' AND R.BAD_YN=N'0' THEN R.ITEM_QT ELSE 0 END)
                       / NULLIF(SUM(CASE WHEN R.SUB_TP=N'0' THEN R.ITEM_QT ELSE 0 END),0) * 100
                       AS DECIMAL(5,2))
    ,직행률_PCT = CAST((SUM(CASE WHEN R.SUB_TP=N'0' AND R.BAD_YN=N'0' THEN R.ITEM_QT ELSE 0 END)
                        - SUM(CASE WHEN R.REWORK_YN=N'1' THEN R.ITEM_QT ELSE 0 END))
                       / NULLIF(SUM(CASE WHEN R.SUB_TP=N'0' THEN R.ITEM_QT ELSE 0 END),0) * 100
                       AS DECIMAL(5,2))
    ,@TARGET                                        AS 목표_PCT
    ,목표달성 = CASE WHEN CAST(SUM(CASE WHEN R.SUB_TP=N'0' AND R.BAD_YN=N'0' THEN R.ITEM_QT ELSE 0 END)
                               / NULLIF(SUM(CASE WHEN R.SUB_TP=N'0' THEN R.ITEM_QT ELSE 0 END),0) * 100
                               AS DECIMAL(5,2)) >= @TARGET
                     THEN N'O' ELSE N'X' END
    ,전월대비_PCTP = CAST(
         SUM(CASE WHEN R.SUB_TP=N'0' AND R.BAD_YN=N'0' THEN R.ITEM_QT ELSE 0 END)
             / NULLIF(SUM(CASE WHEN R.SUB_TP=N'0' THEN R.ITEM_QT ELSE 0 END),0) * 100
       - LAG(SUM(CASE WHEN R.SUB_TP=N'0' AND R.BAD_YN=N'0' THEN R.ITEM_QT ELSE 0 END)
             / NULLIF(SUM(CASE WHEN R.SUB_TP=N'0' THEN R.ITEM_QT ELSE 0 END),0) * 100)
             OVER (ORDER BY LEFT(R.WR_DT, 6))
         AS DECIMAL(5,2))
FROM   #RCV R
GROUP BY LEFT(R.WR_DT, 6)
ORDER BY 실적월
;


/*==============================================================================================
  ** 쿼리 C : 불량 Pareto (코드별)  ★ 개선 우선순위의 근거
     ─ 누적구성비 @PARETO(80%) 선까지가 '핵심 소수'. 이 항목부터 고친다.
==============================================================================================*/
IF @HAS_INSP = 1
BEGIN
    SET @SQL = N'
    ;WITH T AS (
        SELECT B.BAD_CD, QT = SUM(B.BAD_QT), CNT = COUNT(*)
        FROM   #BAD B GROUP BY B.BAD_CD
    )
    SELECT
         N''[C] 불량 Pareto (코드별)'' AS REPORT_NM
        ,순위 = ROW_NUMBER() OVER (ORDER BY T.QT DESC)
        ,T.BAD_CD                AS 불량코드
        ,' + CASE WHEN @HAS_BAD = 1 THEN N'D.BAD_NM' ELSE N'NULL' END + N' AS 불량명
        ,' + CASE WHEN @HAS_BAD = 1 THEN N'D.BADGRP_CD' ELSE N'NULL' END + N' AS 불량그룹
        ,T.QT                    AS 불량수량
        ,T.CNT                   AS 발생건수
        ,구성비_PCT   = CAST(T.QT * 100.0 / NULLIF(SUM(T.QT) OVER (), 0) AS DECIMAL(5,1))
        ,누적구성비_PCT = CAST(SUM(T.QT) OVER (ORDER BY T.QT DESC
                                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                               * 100.0 / NULLIF(SUM(T.QT) OVER (), 0) AS DECIMAL(5,1))
        ,구분 = CASE WHEN SUM(T.QT) OVER (ORDER BY T.QT DESC
                                          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                          * 100.0 / NULLIF(SUM(T.QT) OVER (), 0) <= @p_PAR
                     THEN N''1.★핵심 소수 (우선 개선)''
                     ELSE N''2.기타 다수'' END
    FROM      T
    ' + CASE WHEN @HAS_BAD = 1
             THEN N'LEFT JOIN dbo.LBAD D WITH (NOLOCK) ON D.CO_CD = @p_CO AND D.BAD_CD = T.BAD_CD'
             ELSE N'' END + N'
    ORDER BY T.QT DESC';
    EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_PAR DECIMAL(5,1)'
        ,@p_CO = @CO_CD, @p_PAR = @PARETO;
END
ELSE
    SELECT N'[C] 불량 Pareto (코드별)' AS REPORT_NM
          ,N'LQC_INSP_D 없음 또는 불량코드 컬럼 미확인 - 생략' AS 결과
          ,N'불량 원인을 코드로 분해하려면 실적검사 등록 운영이 먼저 필요하다' AS 비고;


/*==============================================================================================
  ** 쿼리 D : 불량그룹별 집계  (LBADGRP 있을 때)
==============================================================================================*/
IF @HAS_INSP = 1 AND @HAS_BAD = 1 AND OBJECT_ID(N'dbo.LBADGRP', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
    SELECT
         N''[D] 불량그룹별 집계'' AS REPORT_NM
        ,ISNULL(D.BADGRP_CD, N''(미분류)'') AS 불량그룹코드
        ,G.BADGRP_NM                        AS 불량그룹명
        ,COUNT(DISTINCT B.BAD_CD)           AS 불량코드수
        ,SUM(B.BAD_QT)                      AS 불량수량
        ,COUNT(*)                           AS 발생건수
        ,구성비_PCT = CAST(SUM(B.BAD_QT) * 100.0
                           / NULLIF(SUM(SUM(B.BAD_QT)) OVER (), 0) AS DECIMAL(5,1))
        ,누적구성비_PCT = CAST(SUM(SUM(B.BAD_QT)) OVER (ORDER BY SUM(B.BAD_QT) DESC
                                                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                               * 100.0 / NULLIF(SUM(SUM(B.BAD_QT)) OVER (), 0) AS DECIMAL(5,1))
    FROM       #BAD B
    LEFT  JOIN dbo.LBAD    D WITH (NOLOCK) ON D.CO_CD = @p_CO AND D.BAD_CD    = B.BAD_CD
    LEFT  JOIN dbo.LBADGRP G WITH (NOLOCK) ON G.CO_CD = @p_CO AND G.BADGRP_CD = D.BADGRP_CD
    GROUP BY D.BADGRP_CD, G.BADGRP_NM
    ORDER BY 불량수량 DESC';
    BEGIN TRY
        EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4)', @p_CO = @CO_CD;
    END TRY
    BEGIN CATCH
        SELECT N'[D] 불량그룹별 집계' AS REPORT_NM
              ,N'LBADGRP 컬럼 구조 상이 - 생략 (' + ERROR_MESSAGE() + N')' AS 결과;
    END CATCH
END
ELSE
    SELECT N'[D] 불량그룹별 집계' AS REPORT_NM, N'LBAD/LBADGRP 없음 - 생략' AS 결과;


/*==============================================================================================
  ** 쿼리 E : 품목별 품질  (어느 품목이 문제인가)
==============================================================================================*/
SELECT
     N'[E] 품목별 품질'                             AS REPORT_NM
    ,R.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'2' THEN N'제품' WHEN N'4' THEN N'반제품' ELSE I.ACCT_FG END
    ,COUNT(*)                                       AS 실적건수
    ,COUNT(DISTINCT NULLIF(R.WO_CD, N''))           AS 지시수
    ,양품수량 = SUM(CASE WHEN R.SUB_TP=N'0' AND R.BAD_YN=N'0' THEN R.ITEM_QT ELSE 0 END)
    ,불량수량 = SUM(CASE WHEN R.BAD_YN=N'1' THEN R.ITEM_QT ELSE 0 END)
    ,재작업수량 = SUM(CASE WHEN R.REWORK_YN=N'1' THEN R.ITEM_QT ELSE 0 END)
    ,양품률_PCT = CAST(SUM(CASE WHEN R.SUB_TP=N'0' AND R.BAD_YN=N'0' THEN R.ITEM_QT ELSE 0 END)
                       / NULLIF(SUM(CASE WHEN R.SUB_TP=N'0' THEN R.ITEM_QT ELSE 0 END),0) * 100
                       AS DECIMAL(5,2))
    ,직행률_PCT = CAST((SUM(CASE WHEN R.SUB_TP=N'0' AND R.BAD_YN=N'0' THEN R.ITEM_QT ELSE 0 END)
                        - SUM(CASE WHEN R.REWORK_YN=N'1' THEN R.ITEM_QT ELSE 0 END))
                       / NULLIF(SUM(CASE WHEN R.SUB_TP=N'0' THEN R.ITEM_QT ELSE 0 END),0) * 100
                       AS DECIMAL(5,2))
    ,불량기여도_PCT = CAST(SUM(CASE WHEN R.BAD_YN=N'1' THEN R.ITEM_QT ELSE 0 END) * 100.0
                           / NULLIF(SUM(SUM(CASE WHEN R.BAD_YN=N'1' THEN R.ITEM_QT ELSE 0 END)) OVER (), 0)
                           AS DECIMAL(5,1))
    ,판정 = CASE
         WHEN SUM(CASE WHEN R.SUB_TP=N'0' THEN R.ITEM_QT ELSE 0 END) < @MIN_QT THEN N'9.표본 부족'
         WHEN SUM(CASE WHEN R.SUB_TP=N'0' AND R.BAD_YN=N'0' THEN R.ITEM_QT ELSE 0 END)
              / NULLIF(SUM(CASE WHEN R.SUB_TP=N'0' THEN R.ITEM_QT ELSE 0 END),0) * 100 >= @TARGET
                                                                               THEN N'0.목표 달성'
         WHEN SUM(CASE WHEN R.SUB_TP=N'0' AND R.BAD_YN=N'0' THEN R.ITEM_QT ELSE 0 END)
              / NULLIF(SUM(CASE WHEN R.SUB_TP=N'0' THEN R.ITEM_QT ELSE 0 END),0) * 100 >= @TARGET - 5
                                                                               THEN N'1.주의'
         ELSE N'2.★개선 필요' END
FROM       #RCV  R
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = R.ITEM_CD
GROUP BY R.ITEM_CD, I.ITEM_NM, I.SPEC, I.UNIT_CD, I.ACCT_FG
HAVING SUM(CASE WHEN R.SUB_TP = N'0' THEN R.ITEM_QT ELSE 0 END) > 0
ORDER BY 판정 DESC, 불량수량 DESC
;


/*==============================================================================================
  ** 쿼리 F : 공정 · 작업장별 품질  (어디서 불량이 나는가)
==============================================================================================*/
SELECT
     N'[F] 공정·작업장별 품질'                      AS REPORT_NM
    ,R.PROC_CD                                      AS 공정코드
    ,C.PROC_NM                                      AS 공정명
    ,R.WC_CD                                        AS 작업장코드
    ,K.WC_NM                                        AS 작업장명
    ,COUNT(*)                                       AS 실적건수
    ,COUNT(DISTINCT R.ITEM_CD)                      AS 품목수
    ,양품수량 = SUM(CASE WHEN R.SUB_TP=N'0' AND R.BAD_YN=N'0' THEN R.ITEM_QT ELSE 0 END)
    ,불량수량 = SUM(CASE WHEN R.BAD_YN=N'1' THEN R.ITEM_QT ELSE 0 END)
    ,재작업수량 = SUM(CASE WHEN R.REWORK_YN=N'1' THEN R.ITEM_QT ELSE 0 END)
    ,양품률_PCT = CAST(SUM(CASE WHEN R.SUB_TP=N'0' AND R.BAD_YN=N'0' THEN R.ITEM_QT ELSE 0 END)
                       / NULLIF(SUM(CASE WHEN R.SUB_TP=N'0' THEN R.ITEM_QT ELSE 0 END),0) * 100
                       AS DECIMAL(5,2))
    ,직행률_PCT = CAST((SUM(CASE WHEN R.SUB_TP=N'0' AND R.BAD_YN=N'0' THEN R.ITEM_QT ELSE 0 END)
                        - SUM(CASE WHEN R.REWORK_YN=N'1' THEN R.ITEM_QT ELSE 0 END))
                       / NULLIF(SUM(CASE WHEN R.SUB_TP=N'0' THEN R.ITEM_QT ELSE 0 END),0) * 100
                       AS DECIMAL(5,2))
    ,불량기여도_PCT = CAST(SUM(CASE WHEN R.BAD_YN=N'1' THEN R.ITEM_QT ELSE 0 END) * 100.0
                           / NULLIF(SUM(SUM(CASE WHEN R.BAD_YN=N'1' THEN R.ITEM_QT ELSE 0 END)) OVER (), 0)
                           AS DECIMAL(5,1))
    ,판정 = CASE
         WHEN R.PROC_CD = N''                                                  THEN N'9.공정 미등록'
         WHEN SUM(CASE WHEN R.SUB_TP=N'0' AND R.BAD_YN=N'0' THEN R.ITEM_QT ELSE 0 END)
              / NULLIF(SUM(CASE WHEN R.SUB_TP=N'0' THEN R.ITEM_QT ELSE 0 END),0) * 100 >= @TARGET
                                                                               THEN N'0.목표 달성'
         ELSE N'1.★개선 필요' END
FROM       #RCV  R
LEFT  JOIN SPROC C WITH (NOLOCK) ON C.CO_CD = @CO_CD AND C.PROC_CD = NULLIF(R.PROC_CD, N'')
LEFT  JOIN SWC   K WITH (NOLOCK) ON K.CO_CD = @CO_CD AND K.WC_CD   = NULLIF(R.WC_CD  , N'')
GROUP BY R.PROC_CD, C.PROC_NM, R.WC_CD, K.WC_NM
HAVING SUM(CASE WHEN R.SUB_TP = N'0' THEN R.ITEM_QT ELSE 0 END) > 0
ORDER BY 판정 DESC, 불량수량 DESC
;


/*==============================================================================================
  ** 쿼리 G : 불량 발생 실적 상세  (현장 확인용)
==============================================================================================*/
SELECT
     N'[G] 불량 발생 상세'                          AS REPORT_NM
    ,R.WR_DT                                        AS 실적일
    ,R.WR_CD                                        AS 실적번호
    ,R.WO_CD                                        AS 지시번호
    ,R.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,R.PROC_CD                                      AS 공정코드
    ,C.PROC_NM                                      AS 공정명
    ,R.WC_CD                                        AS 작업장코드
    ,R.ITEM_QT                                      AS 불량수량
    ,불량코드 = STUFF((SELECT N', ' + B.BAD_CD FROM #BAD B
                       WHERE B.WR_CD = R.WR_CD
                       FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N'')
    ,코드별불량수량 = (SELECT SUM(B.BAD_QT) FROM #BAD B WHERE B.WR_CD = R.WR_CD)
    ,R.DEPT_CD                                      AS 생산부서
    ,P.DEPT_NM                                      AS 부서명
    ,R.EMP_CD                                       AS 작업자
    ,E.EMP_NM                                       AS 작업자명
    ,코드등록 = CASE WHEN EXISTS (SELECT 1 FROM #BAD B WHERE B.WR_CD = R.WR_CD)
                     THEN N'등록' ELSE N'★미등록 (원인 불명)' END
FROM       #RCV  R
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = R.ITEM_CD
LEFT  JOIN SPROC C WITH (NOLOCK) ON C.CO_CD = @CO_CD AND C.PROC_CD = NULLIF(R.PROC_CD, N'')
LEFT  JOIN SDEPT P WITH (NOLOCK) ON P.CO_CD = @CO_CD AND P.DEPT_CD = R.DEPT_CD
LEFT  JOIN SEMP  E WITH (NOLOCK) ON E.CO_CD = @CO_CD AND E.EMP_CD  = R.EMP_CD
WHERE  R.BAD_YN = N'1'
ORDER BY R.ITEM_QT DESC, R.WR_DT DESC
;


/*==============================================================================================
  ** 쿼리 H : 데이터 점검  ★ 이 리포트를 믿어도 되는지 판단하는 선행 지표
==============================================================================================*/
SELECT
     N'[H] 데이터 점검'                             AS REPORT_NM
    ,LQC_INSP_D_존재 = CASE WHEN OBJECT_ID(N'dbo.LQC_INSP_D', N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,LBAD_존재       = CASE WHEN OBJECT_ID(N'dbo.LBAD'      , N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,LBADGRP_존재    = CASE WHEN OBJECT_ID(N'dbo.LBADGRP'   , N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,불량코드컬럼    = ISNULL(@BADCOL, N'(미확인)')
    ,불량수량컬럼    = ISNULL(@QTCOL , N'(미확인)')
    ,불량실적건수    = (SELECT COUNT(*) FROM #RCV WHERE BAD_YN = N'1')
    ,코드등록건수    = (SELECT COUNT(DISTINCT WR_CD) FROM #BAD)
    ,코드등록률_PCT  = CAST((SELECT COUNT(DISTINCT WR_CD) FROM #BAD) * 100.0
                            / NULLIF((SELECT COUNT(*) FROM #RCV WHERE BAD_YN = N'1'), 0) AS DECIMAL(5,1))
    ,공정등록률_PCT  = CAST((SELECT COUNT(*) FROM #RCV WHERE PROC_CD <> N'') * 100.0
                            / NULLIF((SELECT COUNT(*) FROM #RCV), 0) AS DECIMAL(5,1))
    ,판정 = CASE
         WHEN OBJECT_ID(N'dbo.LQC_INSP_D', N'U') IS NULL
              THEN N'1.★실적검사 테이블 없음 - 불량 원인 분해 불가. KPI(A·B·E·F)만 사용'
         WHEN (SELECT COUNT(*) FROM #RCV WHERE BAD_YN = N'1') = 0
              THEN N'2.기간 내 불량 실적 없음 - BAD_YN 운영 여부 확인 필요'
         WHEN (SELECT COUNT(DISTINCT WR_CD) FROM #BAD) * 100.0
              / NULLIF((SELECT COUNT(*) FROM #RCV WHERE BAD_YN = N'1'), 0) < 50
              THEN N'3.★불량코드 등록률 50% 미만 - Pareto 결과가 전체를 대표하지 못함'
         WHEN (SELECT COUNT(*) FROM #RCV WHERE PROC_CD <> N'') * 100.0
              / NULLIF((SELECT COUNT(*) FROM #RCV), 0) < 50
              THEN N'4.공정 등록률 50% 미만 - 쿼리 F(공정별) 신뢰도 낮음'
         ELSE N'0.정상 - 전 쿼리 사용 가능' END
;


DROP TABLE #RCV, #BAD;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 품질 테이블 실존  ★ Pareto 가능 여부를 가른다
     SELECT name FROM sys.tables
     WHERE name IN ('LQC_INSP','LQC_INSP_D','LQC_INSP_DOCU','LBAD','LBADGRP');

  -- (2) LQC_INSP_D 실제 컬럼  ★ 본 쿼리는 sys.columns 로 자동 탐색하지만 직접 확인이 확실하다
     SELECT name, TYPE_NAME(user_type_id) FROM sys.columns
     WHERE object_id = OBJECT_ID('LQC_INSP_D') ORDER BY column_id;
     --> 불량코드/불량수량 컬럼명이 BAD_CD/BAD_QT 가 아니면 쿼리 2번 블록의 후보 목록에 추가할 것.

  -- (3) BAD_YN 운영 여부  ★ 불량을 별도 실적으로 찍는지, 수량 컬럼으로 관리하는지
     SELECT BAD_YN, SUB_TP, REWORK_YN, COUNT(*) 건수, SUM(ITEM_QT) 수량
     FROM   LORCV_H WHERE CO_CD='1000' AND WR_DT LIKE '2026%'
     GROUP BY BAD_YN, SUB_TP, REWORK_YN;
     --> BAD_YN='1' 이 전혀 없으면 불량을 다른 방식으로 관리하는 사이트다. 운영 방식을 먼저 확인.

  -- (4) 현재 양품률 실측  ★ 목표선(97%)이 현실적인지 판단
     SELECT CAST(SUM(CASE WHEN SUB_TP='0' AND BAD_YN='0' THEN ITEM_QT ELSE 0 END)
                 / NULLIF(SUM(CASE WHEN SUB_TP='0' THEN ITEM_QT ELSE 0 END),0) * 100 AS DECIMAL(5,2))
     FROM   LORCV_H WHERE CO_CD='1000' AND WR_DT LIKE '2026%';
     --> 현재가 90%대 초반이면 97%는 당장 의미가 없다. @TARGET 을 단계적으로 올릴 것.

  -- (5) 공정 등록률  ★ 쿼리 F 의 신뢰도
     SELECT COUNT(*) 전체, SUM(CASE WHEN ISNULL(PROC_CD,'')='' THEN 1 ELSE 0 END) 공정없음
     FROM   LORCV_H WHERE CO_CD='1000';

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **불량 원인 분해(쿼리 C·D)는 실적검사 운영이 전제다.** `LQC_INSP_D` 가 없거나 불량코드
     등록률이 낮으면 Pareto 결과가 전체를 대표하지 못한다. 쿼리 H 의 `코드등록률` 을 먼저 볼 것.
     50% 미만이면 "등록된 것 중에서의 순위"일 뿐이므로 개선 우선순위 근거로 쓰면 안 된다.

  2) **불량 금액을 내지 않았다.** 개선 우선순위는 수량보다 금액이 타당한 경우가 많다
     (저가품 불량 1000개 < 고가품 불량 10개). 금액 기준이 필요하면 `LINV_TAV.ISU_UM` 또는
     표준원가를 곱할 것. (M-04 쿼리 A 의 단가 조회 패턴 참조)

  3) `LQC_INSP_D` 의 컬럼명을 `sys.columns` 로 자동 탐색한다. 후보에 없는 이름을 쓰는
     사이트에서는 Pareto 가 조용히 생략되고 쿼리 H 에 `(미확인)` 으로 표시된다.
     결과가 비면 먼저 확인 (2)번을 돌려볼 것.

  4) 재작업을 양품에 포함해 양품률을 낸다. 재작업 물량까지 불량으로 볼지는 회사 정책이므로,
     그 정의를 쓰려면 **직행률(FTT)** 컬럼을 KPI 로 삼으면 된다. 둘 다 산출해 두었다.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   생산지시별_작업수율현황.sql : 수율 5축 분해 (양품률/직행률/자재수율/공정수율)
   M01_작업지시_진행현황.sql   : 지시별 양품률 + 납기 영향
   M04_공정별재공_현황.sql     : 불량이 쌓이는 공정의 재공 상태
==============================================================================================*/
