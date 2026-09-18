/*==============================================================================================
  [ iCUBE ] A-06  프로젝트별 손익 (회계)                                             (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 전표에 찍힌 관리항목(프로젝트)을 기준으로 **회계상 프로젝트 손익**을 낸다.
         물류·생산 관점의 프로젝트 원가(P-11, PJT_생산원가)와 대사하는 회계 쪽 숫자다.

  DBMS : MS-SQL Server 2012 이상 (T-SQL)   ★ 2008 R2 불가 : OVER 프레임 (ROWS/RANGE BETWEEN), 집계 SUM() OVER(ORDER BY …)

  ----------------------------------------------------------------------------------------------
  [ ★★ 가장 중요한 전제 — PJTCD_TY = 'D1' 필수 ]
  ----------------------------------------------------------------------------------------------
     `ADOCUD.PJT_CD` 컬럼은 **관리항목 유형(`PJTCD_TY`)에 따라 다른 값이 들어간다.**
         PJTCD_TY = 'D1'  →  PJT_CD 는 **프로젝트 코드**
         PJTCD_TY = 'D4'  →  PJT_CD 는 **사원 코드**   ★ 같은 컬럼, 다른 의미
     `PJTCD_TY='D1'` 을 걸지 않으면 **사원 코드가 프로젝트로 집계된다.**
     이것이 이 리포트에서 가장 흔한 오류이며, 결과를 통째로 못 쓰게 만든다.

  ----------------------------------------------------------------------------------------------
  [ 소스 ]
  ----------------------------------------------------------------------------------------------
     ADOCUH / ADOCUD   전표 헤더 / 상세 (관리항목 포함)
     SACCT             계정과목 (손익 계정 판별)
     APJTDISP          프로젝트 배부 (있으면 공통비 배부 반영)
     SPJT              프로젝트 마스터

  ----------------------------------------------------------------------------------------------
  [ 산식 ]
  ----------------------------------------------------------------------------------------------
     수익 = Σ(CR_AM - DR_AM)  WHERE 계정 = 수익 계정
     비용 = Σ(DR_AM - CR_AM)  WHERE 계정 = 비용 계정
     손익 = 수익 - 비용
     이익률 = 손익 / NULLIF(수익, 0) * 100
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
    ,@PJT_CD   NVARCHAR(10) = NULL
    ,@PJTCD_TY NVARCHAR(2)  = N'D1'           -- ★★ D1 = 프로젝트. 절대 바꾸지 말 것
    ,@APPR_ST  NVARCHAR(1)  = NULL            -- 승인상태 (NULL = 전체)
    -- 손익 계정 판별 : 계정코드 앞자리 (한국 일반 계정체계)
    ,@REV_PFX  NVARCHAR(20) = N'4'            -- 4xxxx 수익
    ,@EXP_PFX  NVARCHAR(20) = N'5,6,7,8'      -- 5~8xxxx 비용 (매출원가·판관비·영업외)
    ,@TH_LOSS  DECIMAL(5,1) = 0.0             -- 적자 판정 기준 이익률 (%)
;

DECLARE @SQL NVARCHAR(MAX);
DECLARE @HAS_DISP BIT = 0, @HAS_TY BIT = 0;

-- PJTCD_TY 컬럼 존재 확인  ★ 없으면 이 리포트를 쓰면 안 된다
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID(N'dbo.ADOCUD') AND name = N'PJTCD_TY') SET @HAS_TY = 1;
IF OBJECT_ID(N'dbo.APJTDISP', N'U') IS NOT NULL SET @HAS_DISP = 1;
PRINT N'[0] PJTCD_TY 컬럼=' + CAST(@HAS_TY AS NVARCHAR(1))
    + N' / APJTDISP=' + CAST(@HAS_DISP AS NVARCHAR(1));

IF OBJECT_ID('tempdb..#PL') IS NOT NULL DROP TABLE #PL;


/*==============================================================================================
  1. #PL : 프로젝트별 전표 집계  ★ PJTCD_TY='D1' 필수
==============================================================================================*/
SET @SQL = N'
    SELECT
         D.PJT_CD
        ,D.ACCT_CD
        ,YM = LEFT(H.DOCU_DT, 6)
        ,DR_AM = SUM(CAST(ISNULL(D.DR_AM, 0) AS DECIMAL(19,4)))
        ,CR_AM = SUM(CAST(ISNULL(D.CR_AM, 0) AS DECIMAL(19,4)))
        ,CNT   = COUNT(*)
    INTO #PL
    FROM       ADOCUH H WITH (NOLOCK)
    INNER JOIN ADOCUD D WITH (NOLOCK) ON D.CO_CD = H.CO_CD
                                     AND D.DOCU_DT = H.DOCU_DT AND D.DOCU_SQ = H.DOCU_SQ
    WHERE  H.CO_CD = @p_CO
      AND  H.DOCU_DT BETWEEN @p_FR AND @p_TO
      AND  ISNULL(D.PJT_CD, N'''') <> N''''
      ' + CASE WHEN @HAS_TY = 1
               THEN N'AND ISNULL(D.PJTCD_TY, N'''') = @p_TY   -- ★★ D1 = 프로젝트'
               ELSE N'-- ★ PJTCD_TY 컬럼 없음 - 사원 코드가 섞일 수 있다' END + N'
      AND  (@p_DIV IS NULL OR D.DIV_CD = @p_DIV)
      AND  (@p_PJT IS NULL OR D.PJT_CD = @p_PJT)
      AND  (@p_ST  IS NULL OR ISNULL(H.APPR_ST, N'''') = @p_ST)
    GROUP BY D.PJT_CD, D.ACCT_CD, LEFT(H.DOCU_DT, 6)';
BEGIN TRY
    EXEC sp_executesql @SQL
        ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_FR NVARCHAR(8), @p_TO NVARCHAR(8)
          ,@p_PJT NVARCHAR(10), @p_TY NVARCHAR(2), @p_ST NVARCHAR(1)'
        ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_FR=@FR_DT, @p_TO=@TO_DT
        ,@p_PJT=@PJT_CD, @p_TY=@PJTCD_TY, @p_ST=@APPR_ST;
    PRINT N'[1] 전표 집계 : ' + CAST((SELECT COUNT(*) FROM #PL) AS NVARCHAR(20)) + N' 행';
END TRY
BEGIN CATCH
    PRINT N'[1] ★ 전표 조회 실패 : ' + ERROR_MESSAGE();
    CREATE TABLE #PL (PJT_CD NVARCHAR(10), ACCT_CD NVARCHAR(10), YM NVARCHAR(6)
                     ,DR_AM DECIMAL(19,4), CR_AM DECIMAL(19,4), CNT INT);
END CATCH
CREATE CLUSTERED INDEX IX_PL ON #PL (PJT_CD, ACCT_CD);


/*==============================================================================================
  ** 쿼리 A : 프로젝트별 손익 요약  (메인)
==============================================================================================*/
;WITH X AS (
    SELECT
         P.PJT_CD
        ,REV = SUM(CASE WHEN N',' + @REV_PFX + N',' LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%'
                        THEN P.CR_AM - P.DR_AM ELSE 0 END)
        ,EXP = SUM(CASE WHEN N',' + @EXP_PFX + N',' LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%'
                        THEN P.DR_AM - P.CR_AM ELSE 0 END)
        ,OTH = SUM(CASE WHEN N',' + @REV_PFX + N',' NOT LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%'
                         AND N',' + @EXP_PFX + N',' NOT LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%'
                        THEN P.DR_AM - P.CR_AM ELSE 0 END)
        ,ACCT_N = COUNT(DISTINCT P.ACCT_CD)
        ,CNT    = SUM(P.CNT)
        ,MM_N   = COUNT(DISTINCT P.YM)
        ,FIRST_YM = MIN(P.YM)
        ,LAST_YM  = MAX(P.YM)
    FROM   #PL P
    GROUP BY P.PJT_CD
)
SELECT
     N'[A] 프로젝트별 손익'                         AS REPORT_NM
    ,관리항목유형 = CASE WHEN @HAS_TY = 1 THEN @PJTCD_TY + N' (프로젝트)'
                         ELSE N'★ PJTCD_TY 없음 - 사원 코드 혼입 가능' END
    ,X.PJT_CD                                       AS 프로젝트코드
    ,J.PJT_NM                                       AS 프로젝트명
    ,X.REV                                          AS 수익
    ,X.EXP                                          AS 비용
    ,손익 = X.REV - X.EXP
    ,이익률_PCT = CAST((X.REV - X.EXP) / NULLIF(X.REV, 0) * 100 AS DECIMAL(9,1))
    ,X.OTH                                          AS 기타계정_순액
    ,X.ACCT_N                                       AS 사용계정수
    ,X.CNT                                          AS 전표행수
    ,X.MM_N                                         AS 발생월수
    ,X.FIRST_YM                                     AS 최초월
    ,X.LAST_YM                                      AS 최종월
    ,수익비중_PCT = CAST(X.REV * 100.0 / NULLIF(SUM(X.REV) OVER (), 0) AS DECIMAL(5,1))
    ,손익기여도_PCT = CAST((X.REV - X.EXP) * 100.0
                           / NULLIF(SUM(X.REV - X.EXP) OVER (), 0) AS DECIMAL(5,1))
    ,판정 = CASE
         WHEN X.REV = 0 AND X.EXP > 0
              THEN N'1.★비용만 발생 (수익 없음) - 진행 중이거나 수익 미인식'
         WHEN X.REV - X.EXP < 0
              THEN N'2.★적자 프로젝트'
         WHEN (X.REV - X.EXP) / NULLIF(X.REV, 0) * 100 < @TH_LOSS
              THEN N'3.★목표 이익률 미달'
         ELSE N'0.흑자' END
FROM       X
LEFT  JOIN SPJT J WITH (NOLOCK) ON J.CO_CD = @CO_CD AND J.PJT_CD = X.PJT_CD
ORDER BY 판정, 손익
;


/*==============================================================================================
  ** 쿼리 B : 프로젝트 × 계정과목 상세  (비용 구성)
==============================================================================================*/
SELECT
     N'[B] 프로젝트 × 계정과목'                     AS REPORT_NM
    ,P.PJT_CD                                       AS 프로젝트코드
    ,J.PJT_NM                                       AS 프로젝트명
    ,P.ACCT_CD                                      AS 계정코드
    ,A.ACCT_NM                                      AS 계정명
    ,계정성격 = CASE
         WHEN N',' + @REV_PFX + N',' LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%' THEN N'1.수익'
         WHEN N',' + @EXP_PFX + N',' LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%' THEN N'2.비용'
         ELSE N'3.기타(자산·부채·자본)' END
    ,차변합계 = SUM(P.DR_AM)
    ,대변합계 = SUM(P.CR_AM)
    ,순액 = CASE
         WHEN N',' + @REV_PFX + N',' LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%'
              THEN SUM(P.CR_AM) - SUM(P.DR_AM)
         ELSE SUM(P.DR_AM) - SUM(P.CR_AM) END
    ,전표행수 = SUM(P.CNT)
    ,발생월수 = COUNT(DISTINCT P.YM)
    ,프로젝트내_비중_PCT = CAST(
         ABS(CASE WHEN N',' + @REV_PFX + N',' LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%'
                  THEN SUM(P.CR_AM) - SUM(P.DR_AM) ELSE SUM(P.DR_AM) - SUM(P.CR_AM) END) * 100.0
         / NULLIF(SUM(ABS(CASE WHEN N',' + @REV_PFX + N',' LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%'
                               THEN SUM(P.CR_AM) - SUM(P.DR_AM)
                               ELSE SUM(P.DR_AM) - SUM(P.CR_AM) END))
                  OVER (PARTITION BY P.PJT_CD), 0) AS DECIMAL(5,1))
FROM       #PL  P
LEFT  JOIN SPJT J WITH (NOLOCK) ON J.CO_CD = @CO_CD AND J.PJT_CD  = P.PJT_CD
LEFT  JOIN SACCT A WITH (NOLOCK) ON A.CO_CD = @CO_CD AND A.ACCT_CD = P.ACCT_CD
GROUP BY P.PJT_CD, J.PJT_NM, P.ACCT_CD, A.ACCT_NM
ORDER BY P.PJT_CD, 계정성격, ABS(순액) DESC
;


/*==============================================================================================
  ** 쿼리 C : 월별 손익 추이 (프로젝트별)
==============================================================================================*/
SELECT
     N'[C] 월별 프로젝트 손익'                      AS REPORT_NM
    ,P.PJT_CD                                       AS 프로젝트코드
    ,J.PJT_NM                                       AS 프로젝트명
    ,P.YM                                           AS 기간월
    ,수익 = SUM(CASE WHEN N',' + @REV_PFX + N',' LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%'
                     THEN P.CR_AM - P.DR_AM ELSE 0 END)
    ,비용 = SUM(CASE WHEN N',' + @EXP_PFX + N',' LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%'
                     THEN P.DR_AM - P.CR_AM ELSE 0 END)
    ,손익 = SUM(CASE WHEN N',' + @REV_PFX + N',' LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%'
                     THEN P.CR_AM - P.DR_AM ELSE 0 END)
          - SUM(CASE WHEN N',' + @EXP_PFX + N',' LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%'
                     THEN P.DR_AM - P.CR_AM ELSE 0 END)
    ,누적손익 = SUM(SUM(CASE WHEN N',' + @REV_PFX + N',' LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%'
                             THEN P.CR_AM - P.DR_AM ELSE 0 END)
                  - SUM(CASE WHEN N',' + @EXP_PFX + N',' LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%'
                             THEN P.DR_AM - P.CR_AM ELSE 0 END))
                OVER (PARTITION BY P.PJT_CD ORDER BY P.YM
                      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
    ,전표행수 = SUM(P.CNT)
FROM       #PL  P
LEFT  JOIN SPJT J WITH (NOLOCK) ON J.CO_CD = @CO_CD AND J.PJT_CD = P.PJT_CD
GROUP BY P.PJT_CD, J.PJT_NM, P.YM
ORDER BY P.PJT_CD, P.YM
;


/*==============================================================================================
  ** 쿼리 D : 물류 · 생산 원가와의 대사  ★ 세 관점이 맞는가
     ─ 회계(이 파일) / 물류(P-11) / 생산(PJT_생산원가) 은 각각 다른 숫자가 나온다.
       어느 쪽이 맞다기보다 **왜 다른지 설명할 수 있어야** 한다.
==============================================================================================*/
;WITH ACC AS (
    SELECT
         P.PJT_CD
        ,EXP = SUM(CASE WHEN N',' + @EXP_PFX + N',' LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%'
                        THEN P.DR_AM - P.CR_AM ELSE 0 END)
        ,REV = SUM(CASE WHEN N',' + @REV_PFX + N',' LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%'
                        THEN P.CR_AM - P.DR_AM ELSE 0 END)
    FROM   #PL P GROUP BY P.PJT_CD
)
SELECT
     N'[D] 회계 vs 물류 대사'                       AS REPORT_NM
    ,A.PJT_CD                                       AS 프로젝트코드
    ,J.PJT_NM                                       AS 프로젝트명
    ,회계_수익 = A.REV
    ,회계_비용 = A.EXP
    ,회계_손익 = A.REV - A.EXP
    ,물류_출고금액 = L.ISU_AM
    ,물류_투입금액 = L.PISU_AM
    ,물류_잔여금액 = L.INV_AM
    ,비용_투입_차이 = A.EXP - ISNULL(L.PISU_AM, 0)
    ,판정 = CASE
         WHEN L.PJT_CD IS NULL
              THEN N'1.★물류 수불 없음 - 회계 전표만 존재 (용역 프로젝트일 수 있음)'
         WHEN A.EXP = 0
              THEN N'2.★회계 비용 없음 - 전표에 프로젝트 미지정'
         WHEN ABS(A.EXP - ISNULL(L.PISU_AM, 0)) / NULLIF(A.EXP, 0) > 0.3
              THEN N'3.★회계 비용과 물류 투입액이 30% 이상 차이'
         ELSE N'0.유사 범위' END
    ,설명 = N'회계는 판관비·간접비를 포함하고 물류는 자재만 본다. 차이가 나는 것이 정상이며, '
          + N'차이의 크기가 간접비 규모와 맞는지 확인하는 용도다'
FROM       ACC A
LEFT  JOIN ( SELECT
                  V.PJT_CD
                 ,ISU_AM  = SUM(CASE WHEN V.GRP_FG=N'3' AND V.IO_FG=N'2'
                                     THEN CAST(ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)) * ISNULL(U.UM,0)
                                     ELSE 0 END)
                 ,PISU_AM = SUM(CASE WHEN V.GRP_FG=N'0' AND V.IO_FG=N'2'
                                     THEN CAST(ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)) * ISNULL(U.UM,0)
                                     ELSE 0 END)
                 ,INV_AM  = SUM(CAST(ISNULL(V.IOPEN_QT,0)+ISNULL(V.IRCV_QT,0)-ISNULL(V.IISU_QT,0)
                                     AS DECIMAL(19,6)) * ISNULL(U.UM,0))
             FROM       LINVTORY V WITH (NOLOCK)
             LEFT  JOIN ( SELECT I.ITEM_CD
                               ,UM = CAST(ISNULL(NULLIF(I.STD_UM,0), I.PUR_UM) AS DECIMAL(19,6))
                          FROM SITEM I WITH (NOLOCK) WHERE I.CO_CD = @CO_CD ) U
                     ON U.ITEM_CD = V.ITEM_CD
             WHERE  V.CO_CD = @CO_CD
               AND  V.IO_DT BETWEEN @FR_DT AND @TO_DT
               AND  ISNULL(V.PJT_CD, N'') <> N''
               AND  ISNULL(V.USE_YN, N'1') = N'1' AND ISNULL(V.EXPIRE_YN, N'1') = N'1'
               AND  (@DIV_CD IS NULL OR V.DIV_CD = @DIV_CD)
             GROUP BY V.PJT_CD ) L ON L.PJT_CD = A.PJT_CD
LEFT  JOIN SPJT J WITH (NOLOCK) ON J.CO_CD = @CO_CD AND J.PJT_CD = A.PJT_CD
ORDER BY 판정, ABS(비용_투입_차이) DESC
;


/*==============================================================================================
  ** 쿼리 E : 관리항목 유형 분포  ★★ 실행 전 반드시 확인 — D1/D4 혼입 여부
==============================================================================================*/
IF @HAS_TY = 1
BEGIN
    SET @SQL = N'
    SELECT
         N''[E] 관리항목 유형 분포'' AS REPORT_NM
        ,ISNULL(D.PJTCD_TY, N''(NULL)'') AS 관리항목유형
        ,유형설명 = CASE D.PJTCD_TY
             WHEN N''D1'' THEN N''★ 프로젝트 (이 리포트의 대상)''
             WHEN N''D4'' THEN N''★★ 사원 - PJT_CD 에 사원코드가 들어있다. 절대 섞으면 안 됨''
             ELSE N''기타 관리항목'' END
        ,전표행수 = COUNT(*)
        ,코드종류수 = COUNT(DISTINCT D.PJT_CD)
        ,차변합계 = SUM(CAST(ISNULL(D.DR_AM,0) AS DECIMAL(19,4)))
        ,대변합계 = SUM(CAST(ISNULL(D.CR_AM,0) AS DECIMAL(19,4)))
        ,구성비_PCT = CAST(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0) AS DECIMAL(5,1))
        ,샘플코드 = MAX(D.PJT_CD)
        ,경고 = CASE WHEN D.PJTCD_TY <> N''D1''
                     THEN N''★ 이 유형을 포함하면 프로젝트 손익이 오염된다''
                     ELSE N''-'' END
    FROM       ADOCUH H WITH (NOLOCK)
    INNER JOIN ADOCUD D WITH (NOLOCK) ON D.CO_CD = H.CO_CD
                                     AND D.DOCU_DT = H.DOCU_DT AND D.DOCU_SQ = H.DOCU_SQ
    WHERE  H.CO_CD = @p_CO
      AND  H.DOCU_DT BETWEEN @p_FR AND @p_TO
      AND  ISNULL(D.PJT_CD, N'''') <> N''''
      AND  (@p_DIV IS NULL OR D.DIV_CD = @p_DIV)
    GROUP BY D.PJTCD_TY
    ORDER BY 전표행수 DESC';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_FR NVARCHAR(8), @p_TO NVARCHAR(8)'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_FR=@FR_DT, @p_TO=@TO_DT;
    END TRY
    BEGIN CATCH
        SELECT N'[E] 관리항목 유형 분포' AS REPORT_NM, N'조회 실패 : ' + ERROR_MESSAGE() AS 결과;
    END CATCH
END
ELSE
    SELECT
         N'[E] 관리항목 유형 분포'                  AS REPORT_NM
        ,N'★★ ADOCUD 에 PJTCD_TY 컬럼이 없다' AS 결과
        ,N'PJT_CD 에 프로젝트와 사원이 섞여 있을 수 있으며, 구분할 방법이 없다. '
       + N'프로젝트 마스터(SPJT)에 있는 코드만 필터하는 방식으로 우회할 것' AS 대응
;


/*==============================================================================================
  ** 쿼리 F : 요약 + 데이터 점검
==============================================================================================*/
SELECT
     N'[F] 프로젝트 손익 요약'                      AS REPORT_NM
    ,@FR_DT + N' ~ ' + @TO_DT                       AS 기간
    ,관리항목유형 = @PJTCD_TY
    ,PJTCD_TY_컬럼 = CASE WHEN @HAS_TY = 1 THEN N'O' ELSE N'★X' END
    ,APJTDISP      = CASE WHEN @HAS_DISP = 1 THEN N'O (공통비 배부 운영)' ELSE N'X' END
    ,프로젝트수 = COUNT(DISTINCT P.PJT_CD)
    ,전표행수   = SUM(P.CNT)
    ,사용계정수 = COUNT(DISTINCT P.ACCT_CD)
    ,수익계 = SUM(CASE WHEN N',' + @REV_PFX + N',' LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%'
                       THEN P.CR_AM - P.DR_AM ELSE 0 END)
    ,비용계 = SUM(CASE WHEN N',' + @EXP_PFX + N',' LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%'
                       THEN P.DR_AM - P.CR_AM ELSE 0 END)
    ,손익계 = SUM(CASE WHEN N',' + @REV_PFX + N',' LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%'
                       THEN P.CR_AM - P.DR_AM ELSE 0 END)
            - SUM(CASE WHEN N',' + @EXP_PFX + N',' LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%'
                       THEN P.DR_AM - P.CR_AM ELSE 0 END)
    ,기타계정_순액 = SUM(CASE WHEN N',' + @REV_PFX + N',' NOT LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%'
                               AND N',' + @EXP_PFX + N',' NOT LIKE N'%,' + LEFT(P.ACCT_CD,1) + N',%'
                              THEN P.DR_AM - P.CR_AM ELSE 0 END)
    ,마스터미등록_프로젝트수 = COUNT(DISTINCT CASE
         WHEN NOT EXISTS (SELECT 1 FROM SPJT J WITH (NOLOCK)
                          WHERE J.CO_CD = @CO_CD AND J.PJT_CD = P.PJT_CD)
         THEN P.PJT_CD END)
    ,판정 = CASE
         WHEN @HAS_TY = 0
              THEN N'1.★★PJTCD_TY 컬럼 없음 - 사원 코드 혼입 가능. 결과를 신뢰할 수 없다'
         WHEN COUNT(*) = 0
              THEN N'2.★프로젝트 전표 없음 - 전표에 프로젝트 관리항목을 입력하지 않는다'
         WHEN COUNT(DISTINCT CASE WHEN NOT EXISTS (SELECT 1 FROM SPJT J WITH (NOLOCK)
                                  WHERE J.CO_CD=@CO_CD AND J.PJT_CD=P.PJT_CD)
                                  THEN P.PJT_CD END) > 0
              THEN N'3.★마스터에 없는 프로젝트 코드 존재 - 사원코드 혼입 의심 (쿼리 E 확인)'
         ELSE N'0.정상' END
FROM   #PL P
;


DROP TABLE #PL;
GO


/*==============================================================================================
  [ 도입 전 확인 — ★ 순서를 지킬 것 ]
  ----------------------------------------------------------------------------------------------
  -- (1) ★★ PJTCD_TY 분포  가장 먼저. 이것을 확인하지 않으면 결과 전체가 무의미하다
     SELECT PJTCD_TY, COUNT(*), COUNT(DISTINCT PJT_CD), MAX(PJT_CD) 샘플
     FROM   ADOCUD WHERE CO_CD='1000' AND ISNULL(PJT_CD,'')<>'' GROUP BY PJTCD_TY;
     --> D1(프로젝트)과 D4(사원)가 같은 PJT_CD 컬럼을 공유한다.
        D4 샘플 코드가 사원번호처럼 보이는지 눈으로 확인할 것.

  -- (2) 계정과목 체계  ★ @REV_PFX / @EXP_PFX 의 근거
     SELECT LEFT(ACCT_CD,1) 앞자리, COUNT(*), MIN(ACCT_NM), MAX(ACCT_NM)
     FROM   SACCT WHERE CO_CD='1000' GROUP BY LEFT(ACCT_CD,1) ORDER BY 1;
     --> 기본값(수익 4, 비용 5~8)은 한국 일반 계정체계 가정이다.
        사이트 계정체계가 다르면 @REV_PFX / @EXP_PFX 를 반드시 수정할 것.
        SACCT 에 손익구분 컬럼이 있으면 앞자리 대신 그 컬럼을 쓰는 편이 정확하다.

  -- (3) 전표 컬럼 확인
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('ADOCUD')
       AND name IN ('PJT_CD','PJTCD_TY','ACCT_CD','DR_AM','CR_AM','DIV_CD','DEPTCD_TY');

  -- (4) 프로젝트 마스터 일치율  ★ 사원코드 혼입의 간접 증거
     SELECT COUNT(DISTINCT D.PJT_CD) 전표프로젝트수
           ,SUM(CASE WHEN J.PJT_CD IS NULL THEN 1 ELSE 0 END) 마스터없음
     FROM  (SELECT DISTINCT PJT_CD FROM ADOCUD WHERE CO_CD='1000' AND ISNULL(PJT_CD,'')<>'') D
     LEFT  JOIN SPJT J ON J.CO_CD='1000' AND J.PJT_CD=D.PJT_CD;
     --> '마스터없음'이 많으면 사원코드가 섞인 것이다.

  -- (5) 공통비 배부 운영 여부
     SELECT COUNT(*) FROM APJTDISP WHERE CO_CD='1000';
     --> 있으면 공통비가 프로젝트에 배부된다. 본 쿼리는 배부 결과를 반영하지 않으므로
        배부를 운영하는 사이트는 APJTDISP 를 UNION 하도록 확장해야 한다.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **`PJTCD_TY='D1'` 필터가 이 리포트의 생명이다.** 컬럼이 없는 사이트에서는 사원 코드가
     프로젝트로 집계되어 결과가 통째로 오염된다. 쿼리 F 의 판정이 '1.★★' 로 나오면
     `SPJT` 에 등록된 코드만 남기는 필터를 추가해 우회할 것.

  2) **손익 계정 판별이 계정코드 앞자리 기준**이다. 이는 관례일 뿐 규칙이 아니다.
     `SACCT` 에 손익구분 컬럼(예: `PL_FG`, `ACCT_TY`)이 있으면 그것을 쓰는 편이 정확하다.

  3) **공통비 배부(`APJTDISP`)를 반영하지 않는다.** 직접 전표에 프로젝트가 찍힌 금액만 본다.
     공통비를 배부하는 사이트에서는 실제 프로젝트 원가가 여기 숫자보다 크다.

  4) **회계·물류·생산 세 관점의 숫자는 다르다**(쿼리 D). 회계는 판관비·간접비를 포함하고,
     물류는 자재 수불만, 생산은 지시 기준 제조원가만 본다. 어느 하나가 '정답'이 아니라
     **차이를 설명할 수 있어야** 한다. 원가모듈에는 프로젝트 축이 아예 없다.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   P11_프로젝트별_수불현황.sql : 물류 관점 프로젝트 투입·산출
   PJT_생산원가_보고서.sql     : 생산 관점 프로젝트 제조원가
   전표_관리항목_검증.sql      : ADOCUD 관리항목 정합성 (PJTCD_TY 포함)
   A02_기표파이프라인_현황.sql : 전표가 제대로 생성되었는지
==============================================================================================*/
