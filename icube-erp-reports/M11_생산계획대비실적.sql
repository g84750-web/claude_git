/*==============================================================================================
  [ iCUBE ] M-11  생산계획 대비 실적 KPI                                             (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 주계획(MPS)대로 생산했는가. 달성률뿐 아니라 **계획 자체의 정확도**까지 본다.
         - 계획했는데 안 만든 것 (미실행 계획)
         - 계획 없이 만든 것 (계획외 생산)   ← 이쪽이 크면 MPS 운영이 형해화된 것이다

  DBMS : MS-SQL Server 2012 이상 (T-SQL)   ★ 2008 R2 불가 : LAG()

  ----------------------------------------------------------------------------------------------
  [ 소스 ]
  ----------------------------------------------------------------------------------------------
     LMPS      주계획작성등록      ★ `EXP_FG` 0.판매 / 1.수주 / 2.모의 / 3.생산
     LORCV_H   생산실적            SUB_TP='0' AND BAD_YN='0' 인 양품만

     ※ `LMPS` 는 컬럼 구성이 사이트/버전에 따라 달라질 수 있어, 계획수량·계획일자 컬럼을
       `sys.columns` 로 자동 탐색한다. 실제 컬럼명은 쿼리 G 에 표시된다.

  ----------------------------------------------------------------------------------------------
  [ 산식 ]
  ----------------------------------------------------------------------------------------------
     달성률     = 실적수량 / 계획수량 * 100
     계획준수율 = (달성률이 [100-@TOL, 100+@TOL] 범위인 건수) / 전체 계획건수 * 100
     차이수량   = 실적수량 - 계획수량
     계획외생산 = 계획에 없는 품목·기간의 실적
     미실행계획 = 실적이 전혀 없는 계획

  ----------------------------------------------------------------------------------------------
  [ ★ EXP_FG 를 반드시 구분해야 하는 이유 ]
  ----------------------------------------------------------------------------------------------
     `EXP_FG='2'`(모의)는 **시뮬레이션용 계획**이다. 실적과 비교하면 안 된다.
     기본값은 `@EXP_FG='3'`(생산계획)만 평가하도록 했다. 사이트에 따라 판매계획(0)이나
     수주계획(1)을 실행 기준으로 쓰기도 하므로, 쿼리 G 의 분포를 먼저 확인하고 정할 것.
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터   ─ 목표선은 EIS 기본값(생산달성률 95%)을 채웠다.
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@FR_YM    NVARCHAR(6)  = N'202601'       -- 계획월 FROM
    ,@TO_YM    NVARCHAR(6)  = N'202612'
    ,@ITEM_CD  NVARCHAR(25) = NULL
    ,@EXP_FG   NVARCHAR(1)  = N'3'            -- ★ 0판매 1수주 2모의 3생산 (NULL=전체)

    ,@TARGET   DECIMAL(5,1) = 95.0            -- ★ 목표 생산달성률 (%)  [EIS 기본값]
    ,@TOL      DECIMAL(5,1) = 10.0            -- 계획준수 허용 오차 (±%)
;

DECLARE @SQL NVARCHAR(MAX);
DECLARE @QTCOL NVARCHAR(30), @DTCOL NVARCHAR(30), @DTTYPE NVARCHAR(10), @HAS_MPS BIT = 0;

IF OBJECT_ID('tempdb..#PLN') IS NOT NULL DROP TABLE #PLN;
IF OBJECT_ID('tempdb..#ACT') IS NOT NULL DROP TABLE #ACT;
IF OBJECT_ID('tempdb..#CMP') IS NOT NULL DROP TABLE #CMP;


/*==============================================================================================
  1. #PLN : 주계획 (LMPS)  ─ 컬럼명 자동 탐색
==============================================================================================*/
CREATE TABLE #PLN (
     ITEM_CD NVARCHAR(25)
    ,PLAN_YM NVARCHAR(6)
    ,EXP_FG  NVARCHAR(1)
    ,PLAN_QT DECIMAL(19,6)
    ,PLAN_CNT INT
);

IF OBJECT_ID(N'dbo.LMPS', N'U') IS NOT NULL
BEGIN
    -- 계획수량 컬럼
    SELECT TOP 1 @QTCOL = name FROM sys.columns
    WHERE  object_id = OBJECT_ID(N'dbo.LMPS')
      AND  name IN (N'PLAN_QT', N'MPS_QT', N'ITEM_QT', N'EXP_QT', N'QT')
    ORDER BY CASE name WHEN N'PLAN_QT' THEN 1 WHEN N'MPS_QT' THEN 2
                       WHEN N'EXP_QT'  THEN 3 WHEN N'ITEM_QT' THEN 4 ELSE 5 END;

    -- 계획일자/월 컬럼
    SELECT TOP 1 @DTCOL = name, @DTTYPE = CASE WHEN max_length >= 16 THEN N'DT' ELSE N'YM' END
    FROM   sys.columns
    WHERE  object_id = OBJECT_ID(N'dbo.LMPS')
      AND  name IN (N'PLAN_DT', N'MPS_DT', N'EXP_DT', N'PLAN_YM', N'SMM', N'P_MM')
    ORDER BY CASE name WHEN N'PLAN_DT' THEN 1 WHEN N'MPS_DT'  THEN 2 WHEN N'EXP_DT' THEN 3
                       WHEN N'PLAN_YM' THEN 4 WHEN N'SMM'     THEN 5 ELSE 6 END;

    IF @QTCOL IS NOT NULL AND @DTCOL IS NOT NULL
    BEGIN
        SET @SQL = N'
            INSERT INTO #PLN (ITEM_CD, PLAN_YM, EXP_FG, PLAN_QT, PLAN_CNT)
            SELECT M.ITEM_CD
                  ,LEFT(M.' + QUOTENAME(@DTCOL) + N', 6)
                  ,ISNULL(M.EXP_FG, N''9'')
                  ,SUM(CAST(ISNULL(M.' + QUOTENAME(@QTCOL) + N', 0) AS DECIMAL(19,6)))
                  ,COUNT(*)
            FROM   dbo.LMPS M WITH (NOLOCK)
            WHERE  M.CO_CD = @p_CO
              AND  LEFT(M.' + QUOTENAME(@DTCOL) + N', 6) BETWEEN @p_FR AND @p_TO
              AND  ISNULL(M.USE_YN, N''1'') = N''1''
              AND  (@p_DIV  IS NULL OR M.DIV_CD  = @p_DIV)
              AND  (@p_ITEM IS NULL OR M.ITEM_CD = @p_ITEM)
              AND  (@p_EXP  IS NULL OR ISNULL(M.EXP_FG, N''9'') = @p_EXP)
            GROUP BY M.ITEM_CD, LEFT(M.' + QUOTENAME(@DTCOL) + N', 6), ISNULL(M.EXP_FG, N''9'')';
        BEGIN TRY
            EXEC sp_executesql @SQL
                ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_FR NVARCHAR(6), @p_TO NVARCHAR(6)
                  ,@p_ITEM NVARCHAR(25), @p_EXP NVARCHAR(1)'
                ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_FR=@FR_YM, @p_TO=@TO_YM
                ,@p_ITEM=@ITEM_CD, @p_EXP=@EXP_FG;
            SET @HAS_MPS = 1;
            PRINT N'[1] 주계획 : LMPS (' + @QTCOL + N'/' + @DTCOL + N') '
                  + CAST((SELECT COUNT(*) FROM #PLN) AS NVARCHAR(20)) + N' 행';
        END TRY
        BEGIN CATCH
            PRINT N'[1] LMPS 조회 실패 (' + ERROR_MESSAGE() + N')';
        END CATCH
    END
    ELSE
        PRINT N'[1] LMPS 에 계획수량/계획일자 컬럼을 찾지 못함 - 쿼리 G 확인 필요';
END
ELSE
    PRINT N'[1] LMPS 없음 - 생산계획 미운영 사이트';

CREATE CLUSTERED INDEX IX_PLN ON #PLN (ITEM_CD, PLAN_YM);


/*==============================================================================================
  2. #ACT : 생산실적 (양품만)
==============================================================================================*/
SELECT
     R.ITEM_CD
    ,ACT_YM  = LEFT(R.WR_DT, 6)
    ,ACT_QT  = SUM(CASE WHEN ISNULL(R.SUB_TP,N'0')=N'0' AND ISNULL(R.BAD_YN,N'0')=N'0'
                        THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
    ,BAD_QT  = SUM(CASE WHEN ISNULL(R.BAD_YN,N'0')=N'1'
                        THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
    ,ACT_CNT = COUNT(*)
    ,WO_CNT  = COUNT(DISTINCT NULLIF(R.WO_CD, N''))
    ,FIRST_DT= MIN(R.WR_DT)
    ,LAST_DT = MAX(R.WR_DT)
INTO #ACT
FROM       LORCV_H R WITH (NOLOCK)
LEFT  JOIN SITEM   I WITH (NOLOCK) ON I.CO_CD = R.CO_CD AND I.ITEM_CD = R.ITEM_CD
WHERE  R.CO_CD = @CO_CD
  AND  LEFT(R.WR_DT, 6) BETWEEN @FR_YM AND @TO_YM
  AND  ISNULL(R.USE_YN, N'1') = N'1'
  AND  (@DIV_CD  IS NULL OR R.DIV_CD  = @DIV_CD)
  AND  (@ITEM_CD IS NULL OR R.ITEM_CD = @ITEM_CD)
  AND  ISNULL(I.S_CD, N'') <> N'Z00'
GROUP BY R.ITEM_CD, LEFT(R.WR_DT, 6);
CREATE CLUSTERED INDEX IX_ACT ON #ACT (ITEM_CD, ACT_YM);


/*==============================================================================================
  3. #CMP : 계획 × 실적 대사 (FULL JOIN — 계획외생산/미실행계획까지 포착)
==============================================================================================*/
SELECT
     ITEM_CD = ISNULL(P.ITEM_CD, A.ITEM_CD)
    ,PER_YM  = ISNULL(P.PLAN_YM, A.ACT_YM)
    ,EXP_FG  = P.EXP_FG
    ,PLAN_QT = ISNULL(P.PLAN_QT , 0)
    ,PLAN_CNT= ISNULL(P.PLAN_CNT, 0)
    ,ACT_QT  = ISNULL(A.ACT_QT  , 0)
    ,BAD_QT  = ISNULL(A.BAD_QT  , 0)
    ,ACT_CNT = ISNULL(A.ACT_CNT , 0)
    ,WO_CNT  = ISNULL(A.WO_CNT  , 0)
    ,A.FIRST_DT
    ,A.LAST_DT
    ,GAP_QT  = ISNULL(A.ACT_QT,0) - ISNULL(P.PLAN_QT,0)
    ,MATCH_FG = CASE WHEN P.ITEM_CD IS NULL THEN N'A'      -- 계획외 생산
                     WHEN A.ITEM_CD IS NULL THEN N'P'      -- 미실행 계획
                     ELSE N'B' END                          -- 양쪽 존재
INTO #CMP
FROM      #PLN P
FULL JOIN #ACT A ON A.ITEM_CD = P.ITEM_CD AND A.ACT_YM = P.PLAN_YM;
CREATE CLUSTERED INDEX IX_CMP ON #CMP (ITEM_CD, PER_YM);

PRINT N'[3] 대사 : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 행';


/*==============================================================================================
  ** 쿼리 A : 계획 대비 실적 요약  ★ 목표 대비 판정
==============================================================================================*/
SELECT
     N'[A] 생산계획 대비 실적 요약'                 AS REPORT_NM
    ,@FR_YM + N' ~ ' + @TO_YM                       AS 기간
    ,계획유형 = CASE @EXP_FG WHEN N'0' THEN N'판매계획' WHEN N'1' THEN N'수주계획'
                             WHEN N'2' THEN N'모의계획' WHEN N'3' THEN N'생산계획'
                             ELSE N'전체' END
    ,@TARGET                                        AS 목표_달성률_PCT

    ,계획품목수 = COUNT(DISTINCT CASE WHEN C.MATCH_FG IN (N'B',N'P') THEN C.ITEM_CD END)
    ,실적품목수 = COUNT(DISTINCT CASE WHEN C.MATCH_FG IN (N'B',N'A') THEN C.ITEM_CD END)
    ,계획수량계 = SUM(C.PLAN_QT)
    ,실적수량계 = SUM(C.ACT_QT)
    ,불량수량계 = SUM(C.BAD_QT)
    ,차이수량계 = SUM(C.ACT_QT) - SUM(C.PLAN_QT)

    ,달성률_PCT = CAST(SUM(C.ACT_QT) / NULLIF(SUM(C.PLAN_QT), 0) * 100 AS DECIMAL(5,1))

    ,계획준수건수 = SUM(CASE WHEN C.MATCH_FG = N'B' AND C.PLAN_QT > 0
                              AND C.ACT_QT / C.PLAN_QT * 100 BETWEEN 100 - @TOL AND 100 + @TOL
                             THEN 1 ELSE 0 END)
    ,계획건수     = SUM(CASE WHEN C.MATCH_FG IN (N'B', N'P') THEN 1 ELSE 0 END)
    ,계획준수율_PCT = CAST(SUM(CASE WHEN C.MATCH_FG = N'B' AND C.PLAN_QT > 0
                                     AND C.ACT_QT / C.PLAN_QT * 100 BETWEEN 100 - @TOL AND 100 + @TOL
                                    THEN 1.0 ELSE 0 END)
                           / NULLIF(SUM(CASE WHEN C.MATCH_FG IN (N'B',N'P') THEN 1.0 ELSE 0 END), 0)
                           * 100 AS DECIMAL(5,1))

    ,미실행계획건수 = SUM(CASE WHEN C.MATCH_FG = N'P' THEN 1 ELSE 0 END)
    ,미실행계획수량 = SUM(CASE WHEN C.MATCH_FG = N'P' THEN C.PLAN_QT ELSE 0 END)
    ,계획외생산건수 = SUM(CASE WHEN C.MATCH_FG = N'A' THEN 1 ELSE 0 END)
    ,계획외생산수량 = SUM(CASE WHEN C.MATCH_FG = N'A' THEN C.ACT_QT ELSE 0 END)
    ,계획외생산비율_PCT = CAST(SUM(CASE WHEN C.MATCH_FG = N'A' THEN C.ACT_QT ELSE 0 END)
                               / NULLIF(SUM(C.ACT_QT), 0) * 100 AS DECIMAL(5,1))

    ,판정 = CASE
         WHEN @HAS_MPS = 0
              THEN N'9.★LMPS 미운영 또는 컬럼 미확인 - 쿼리 G 확인'
         WHEN SUM(C.PLAN_QT) = 0
              THEN N'8.★기간 내 계획 없음'
         WHEN SUM(CASE WHEN C.MATCH_FG = N'A' THEN C.ACT_QT ELSE 0 END)
              / NULLIF(SUM(C.ACT_QT), 0) * 100 > 50
              THEN N'1.★계획외 생산이 절반 초과 - MPS 운영이 형해화됨'
         WHEN CAST(SUM(C.ACT_QT) / NULLIF(SUM(C.PLAN_QT),0) * 100 AS DECIMAL(5,1)) >= @TARGET
              THEN N'0.목표 달성'
         WHEN CAST(SUM(C.ACT_QT) / NULLIF(SUM(C.PLAN_QT),0) * 100 AS DECIMAL(5,1)) >= @TARGET - 5
              THEN N'2.목표 근접(5%p 이내)'
         ELSE N'3.★목표 미달' END
    ,목표대비_PCTP = CAST(SUM(C.ACT_QT) / NULLIF(SUM(C.PLAN_QT),0) * 100 - @TARGET AS DECIMAL(5,1))
FROM   #CMP C
;


/*==============================================================================================
  ** 쿼리 B : 월별 계획 대비 실적 추이
==============================================================================================*/
SELECT
     N'[B] 월별 계획 대비 실적'                     AS REPORT_NM
    ,C.PER_YM                                       AS 기간월
    ,계획품목수 = COUNT(DISTINCT CASE WHEN C.MATCH_FG IN (N'B',N'P') THEN C.ITEM_CD END)
    ,실적품목수 = COUNT(DISTINCT CASE WHEN C.MATCH_FG IN (N'B',N'A') THEN C.ITEM_CD END)
    ,계획수량 = SUM(C.PLAN_QT)
    ,실적수량 = SUM(C.ACT_QT)
    ,차이수량 = SUM(C.ACT_QT) - SUM(C.PLAN_QT)
    ,달성률_PCT = CAST(SUM(C.ACT_QT) / NULLIF(SUM(C.PLAN_QT), 0) * 100 AS DECIMAL(5,1))
    ,미실행계획수량 = SUM(CASE WHEN C.MATCH_FG = N'P' THEN C.PLAN_QT ELSE 0 END)
    ,계획외생산수량 = SUM(CASE WHEN C.MATCH_FG = N'A' THEN C.ACT_QT ELSE 0 END)
    ,불량수량 = SUM(C.BAD_QT)
    ,@TARGET                                        AS 목표_PCT
    ,목표달성 = CASE WHEN CAST(SUM(C.ACT_QT)/NULLIF(SUM(C.PLAN_QT),0)*100 AS DECIMAL(5,1)) >= @TARGET
                     THEN N'O' ELSE N'X' END
    ,전월대비_PCTP = CAST(
         SUM(C.ACT_QT) / NULLIF(SUM(C.PLAN_QT),0) * 100
       - LAG(SUM(C.ACT_QT) / NULLIF(SUM(C.PLAN_QT),0) * 100) OVER (ORDER BY C.PER_YM)
         AS DECIMAL(5,1))
FROM   #CMP C
GROUP BY C.PER_YM
ORDER BY 기간월
;


/*==============================================================================================
  ** 쿼리 C : 품목 × 월별 상세  (메인)
==============================================================================================*/
SELECT
     N'[C] 품목별 계획 대비 실적'                   AS REPORT_NM
    ,상태 = CASE C.MATCH_FG
         WHEN N'P' THEN N'1.★미실행 계획 (계획만 있고 실적 없음)'
         WHEN N'A' THEN N'2.★계획외 생산 (실적만 있고 계획 없음)'
         ELSE CASE
             WHEN C.PLAN_QT > 0 AND C.ACT_QT / C.PLAN_QT * 100 < 100 - @TOL THEN N'3.미달'
             WHEN C.PLAN_QT > 0 AND C.ACT_QT / C.PLAN_QT * 100 > 100 + @TOL THEN N'4.초과'
             ELSE N'0.계획 준수' END
         END
    ,C.PER_YM                                       AS 기간월
    ,C.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'2' THEN N'제품' WHEN N'4' THEN N'반제품' ELSE I.ACCT_FG END
    ,계획유형 = CASE C.EXP_FG WHEN N'0' THEN N'판매' WHEN N'1' THEN N'수주'
                              WHEN N'2' THEN N'모의' WHEN N'3' THEN N'생산' ELSE C.EXP_FG END
    ,C.PLAN_QT                                      AS 계획수량
    ,C.ACT_QT                                       AS 실적수량
    ,C.BAD_QT                                       AS 불량수량
    ,C.GAP_QT                                       AS 차이수량
    ,달성률_PCT = CAST(CASE WHEN C.PLAN_QT > 0 THEN C.ACT_QT / C.PLAN_QT * 100 END AS DECIMAL(9,1))
    ,C.PLAN_CNT                                     AS 계획건수
    ,C.WO_CNT                                       AS 지시수
    ,C.ACT_CNT                                      AS 실적건수
    ,C.FIRST_DT                                     AS 최초실적일
    ,C.LAST_DT                                      AS 최종실적일
    ,조치 = CASE C.MATCH_FG
         WHEN N'P' THEN N'계획 미실행 사유 확인 (자재/설비/수요 취소)'
         WHEN N'A' THEN N'계획 누락인지 긴급 대응인지 확인 - MPS 반영 필요'
         ELSE CASE
             WHEN C.PLAN_QT > 0 AND C.ACT_QT / C.PLAN_QT * 100 < 100 - @TOL
                  THEN N'생산 부족 - M-01 작업지시 진행현황 확인'
             WHEN C.PLAN_QT > 0 AND C.ACT_QT / C.PLAN_QT * 100 > 100 + @TOL
                  THEN N'과잉 생산 - 재고 부담 확인 (P-05)'
             ELSE N'-' END
         END
FROM       #CMP  C
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = C.ITEM_CD
ORDER BY 상태, ABS(C.GAP_QT) DESC
;


/*==============================================================================================
  ** 쿼리 D : 품목별 누계 (기간 합산)  ─ 월 단위 편차를 상쇄한 뒤의 실력
==============================================================================================*/
SELECT
     N'[D] 품목별 누계 달성률'                      AS REPORT_NM
    ,C.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'2' THEN N'제품' WHEN N'4' THEN N'반제품' ELSE I.ACCT_FG END
    ,COUNT(*)                                       AS 대상월수
    ,계획수량계 = SUM(C.PLAN_QT)
    ,실적수량계 = SUM(C.ACT_QT)
    ,차이수량계 = SUM(C.ACT_QT) - SUM(C.PLAN_QT)
    ,누계달성률_PCT = CAST(SUM(C.ACT_QT) / NULLIF(SUM(C.PLAN_QT), 0) * 100 AS DECIMAL(9,1))
    ,미실행월수 = SUM(CASE WHEN C.MATCH_FG = N'P' THEN 1 ELSE 0 END)
    ,계획외월수 = SUM(CASE WHEN C.MATCH_FG = N'A' THEN 1 ELSE 0 END)
    ,준수월수   = SUM(CASE WHEN C.MATCH_FG = N'B' AND C.PLAN_QT > 0
                            AND C.ACT_QT / C.PLAN_QT * 100 BETWEEN 100-@TOL AND 100+@TOL
                           THEN 1 ELSE 0 END)
    ,불량수량계 = SUM(C.BAD_QT)
    ,판정 = CASE
         WHEN SUM(C.PLAN_QT) = 0                                              THEN N'9.계획 없음 (전량 계획외)'
         WHEN SUM(C.ACT_QT) / NULLIF(SUM(C.PLAN_QT),0) * 100 >= @TARGET        THEN N'0.목표 달성'
         WHEN SUM(C.ACT_QT) / NULLIF(SUM(C.PLAN_QT),0) * 100 >= @TARGET - 10   THEN N'1.주의'
         ELSE N'2.★개선 필요' END
FROM       #CMP  C
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = C.ITEM_CD
GROUP BY C.ITEM_CD, I.ITEM_NM, I.SPEC, I.UNIT_CD, I.ACCT_FG
ORDER BY 판정 DESC, ABS(차이수량계) DESC
;


/*==============================================================================================
  ** 쿼리 E : 미실행 계획  ★ 계획했는데 안 만든 것
==============================================================================================*/
SELECT
     N'[E] 미실행 계획'                             AS REPORT_NM
    ,C.PER_YM                                       AS 계획월
    ,C.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계획유형 = CASE C.EXP_FG WHEN N'0' THEN N'판매' WHEN N'1' THEN N'수주'
                              WHEN N'2' THEN N'모의' WHEN N'3' THEN N'생산' ELSE C.EXP_FG END
    ,C.PLAN_QT                                      AS 미실행_계획수량
    ,C.PLAN_CNT                                     AS 계획건수
    ,지시존재 = CASE WHEN EXISTS (
         SELECT 1 FROM LWO_WF W WITH (NOLOCK)
         WHERE W.CO_CD = @CO_CD AND W.ITEM_CD = C.ITEM_CD
           AND LEFT(W.ORD_DT, 6) = C.PER_YM AND ISNULL(W.USE_YN, N'1') = N'1')
         THEN N'지시 있음 (실적 미등록)' ELSE N'★ 지시조차 없음' END
    ,추정원인 = CASE
         WHEN NOT EXISTS (SELECT 1 FROM LWO_WF W WITH (NOLOCK)
                          WHERE W.CO_CD=@CO_CD AND W.ITEM_CD=C.ITEM_CD
                            AND LEFT(W.ORD_DT,6)=C.PER_YM AND ISNULL(W.USE_YN,N'1')=N'1')
              THEN N'1.★계획이 지시로 전개되지 않음 - MPS→작업지시 연계 확인'
         ELSE N'2.지시는 났으나 실적 없음 - 자재/설비 확인 (M-01)' END
    ,I.LEAD_DT                                      AS 리드타임일
FROM       #CMP  C
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = C.ITEM_CD
WHERE  C.MATCH_FG = N'P'
ORDER BY C.PLAN_QT DESC
;


/*==============================================================================================
  ** 쿼리 F : 계획외 생산  ★ 계획 없이 만든 것 — MPS 운영 실태의 지표
==============================================================================================*/
SELECT
     N'[F] 계획외 생산'                             AS REPORT_NM
    ,C.PER_YM                                       AS 실적월
    ,C.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'2' THEN N'제품' WHEN N'4' THEN N'반제품' ELSE I.ACCT_FG END
    ,C.ACT_QT                                       AS 계획외_실적수량
    ,C.BAD_QT                                       AS 불량수량
    ,C.WO_CNT                                       AS 지시수
    ,C.ACT_CNT                                      AS 실적건수
    ,C.FIRST_DT                                     AS 최초실적일
    ,C.LAST_DT                                      AS 최종실적일
    ,타월계획존재 = CASE WHEN EXISTS (
         SELECT 1 FROM #PLN P WHERE P.ITEM_CD = C.ITEM_CD)
         THEN N'있음 (시기 불일치)' ELSE N'★ 전 기간 계획 없음' END
    ,수주연계 = CASE WHEN EXISTS (
         SELECT 1 FROM LWO_WF W WITH (NOLOCK)
         WHERE W.CO_CD = @CO_CD AND W.ITEM_CD = C.ITEM_CD
           AND LEFT(W.ORD_DT, 6) = C.PER_YM
           AND ISNULL(W.SO_NB, N'') <> N'' AND ISNULL(W.USE_YN, N'1') = N'1')
         THEN N'수주 연계 (긴급 대응)' ELSE N'수주 무관' END
    ,판정 = CASE
         WHEN NOT EXISTS (SELECT 1 FROM #PLN P WHERE P.ITEM_CD = C.ITEM_CD)
              THEN N'1.★MPS 에 아예 없는 품목 - 계획 대상 누락'
         ELSE N'2.계획 시기 불일치 - 계획 정확도 문제' END
FROM       #CMP  C
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = C.ITEM_CD
WHERE  C.MATCH_FG = N'A'
ORDER BY 판정, C.ACT_QT DESC
;


/*==============================================================================================
  ** 쿼리 G : 데이터 점검  ★ 실행 전 반드시 먼저 볼 것
     ─ LMPS 컬럼 구성과 EXP_FG 분포를 확인해야 @EXP_FG 를 제대로 고를 수 있다.
==============================================================================================*/
SELECT
     N'[G] 데이터 점검'                             AS REPORT_NM
    ,LMPS_존재    = CASE WHEN OBJECT_ID(N'dbo.LMPS', N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,계획수량컬럼 = ISNULL(@QTCOL, N'(미확인)')
    ,계획일자컬럼 = ISNULL(@DTCOL, N'(미확인)')
    ,적재성공     = CASE WHEN @HAS_MPS = 1 THEN N'O' ELSE N'X' END
    ,계획행수     = (SELECT COUNT(*) FROM #PLN)
    ,실적행수     = (SELECT COUNT(*) FROM #ACT)
    ,판정 = CASE
         WHEN OBJECT_ID(N'dbo.LMPS', N'U') IS NULL
              THEN N'1.★LMPS 없음 - 생산계획 미운영. 본 리포트 사용 불가'
         WHEN @HAS_MPS = 0
              THEN N'2.★컬럼명 자동 탐색 실패 - 아래 확인 쿼리로 실제 컬럼을 확인하고 후보에 추가할 것'
         WHEN (SELECT COUNT(*) FROM #PLN) = 0
              THEN N'3.★기간/계획유형 조건에 해당하는 계획 없음 - @EXP_FG 를 NULL 로 바꿔 재조회'
         ELSE N'0.정상' END
;

-- EXP_FG 분포  ★ @EXP_FG 선택의 근거
IF OBJECT_ID(N'dbo.LMPS', N'U') IS NOT NULL AND @DTCOL IS NOT NULL AND @QTCOL IS NOT NULL
BEGIN
    SET @SQL = N'
    SELECT
         N''[G-2] EXP_FG 분포'' AS REPORT_NM
        ,ISNULL(M.EXP_FG, N''(NULL)'') AS 계획유형코드
        ,계획유형 = CASE M.EXP_FG WHEN N''0'' THEN N''판매계획'' WHEN N''1'' THEN N''수주계획''
                                  WHEN N''2'' THEN N''모의계획'' WHEN N''3'' THEN N''생산계획''
                                  ELSE N''(미정의)'' END
        ,COUNT(*)                     AS 계획건수
        ,COUNT(DISTINCT M.ITEM_CD)    AS 품목수
        ,SUM(CAST(ISNULL(M.' + QUOTENAME(@QTCOL) + N',0) AS DECIMAL(19,6))) AS 계획수량
        ,MIN(LEFT(M.' + QUOTENAME(@DTCOL) + N',6)) AS 최초계획월
        ,MAX(LEFT(M.' + QUOTENAME(@DTCOL) + N',6)) AS 최종계획월
        ,비고 = CASE WHEN M.EXP_FG = N''2''
                     THEN N''★ 모의계획 - 실적 비교 대상 아님''
                     ELSE N''-'' END
    FROM   dbo.LMPS M WITH (NOLOCK)
    WHERE  M.CO_CD = @p_CO AND ISNULL(M.USE_YN, N''1'') = N''1''
      AND  (@p_DIV IS NULL OR M.DIV_CD = @p_DIV)
    GROUP BY M.EXP_FG
    ORDER BY 계획유형코드';
    BEGIN TRY
        EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4)'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD;
    END TRY
    BEGIN CATCH
        SELECT N'[G-2] EXP_FG 분포' AS REPORT_NM, ERROR_MESSAGE() AS 오류;
    END CATCH
END


DROP TABLE #PLN, #ACT, #CMP;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) LMPS 실제 컬럼  ★ 본 쿼리는 자동 탐색하지만 직접 확인이 확실하다
     SELECT name, TYPE_NAME(user_type_id) 타입, max_length FROM sys.columns
     WHERE object_id = OBJECT_ID('LMPS') ORDER BY column_id;
     --> 계획수량/계획일자 컬럼명이 후보 목록에 없으면 쿼리 1번 블록의 IN (...) 에 추가할 것.
        수량 후보 : PLAN_QT, MPS_QT, ITEM_QT, EXP_QT, QT
        일자 후보 : PLAN_DT, MPS_DT, EXP_DT, PLAN_YM, SMM, P_MM

  -- (2) EXP_FG 분포  ★ 쿼리 G-2 와 같은 목적. @EXP_FG 선택의 근거
     SELECT EXP_FG, COUNT(*) FROM LMPS WHERE CO_CD='1000' GROUP BY EXP_FG;
     --> '3'(생산)이 없고 '0'(판매)만 쓰는 사이트면 @EXP_FG='0' 으로 바꿀 것.
        '2'(모의)는 절대 평가 대상에 넣지 말 것.

  -- (3) 계획 운영 여부
     SELECT COUNT(*) FROM LMPS WHERE CO_CD='1000';
     --> 0 이면 MPS 미운영. 이 경우 M-01(작업지시 진행현황)이 사실상의 생산 계획 관리 도구다.

  -- (4) 계획 입도 확인  ★ 월 단위인지 일 단위인지
     SELECT TOP 20 * FROM LMPS WHERE CO_CD='1000' ORDER BY 1 DESC;
     --> 본 쿼리는 **월 단위로 집계**한다. 주 단위 계획을 운영하면 입도가 맞지 않으므로
        비교 단위를 주로 바꿔야 한다 (LEFT(...,6) 부분 수정).

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **비교 입도가 월 단위다.** MPS 를 주 단위나 일 단위로 운영하는 사이트에서는 월로 뭉치면서
     "월 안에서의 일정 지연"이 보이지 않는다. 월 달성률 100%여도 전부 월말에 몰아서 만들었을 수
     있다. 일정 준수까지 보려면 M-01 의 납기리스크와 함께 볼 것.

  2) **계획 변경 이력을 추적하지 않는다.** 월중에 계획을 하향 조정하면 달성률이 좋아진다.
     이것이 이 KPI 의 가장 흔한 왜곡 경로다. 계획 확정 시점의 스냅샷을 별도 보관하지 않는
     사이트에서는 달성률을 "최종 계획 대비"로만 해석해야 한다.

  3) `LMPS` 컬럼명을 `sys.columns` 로 자동 탐색한다. 후보에 없는 이름을 쓰면 계획이 비어
     전량 '계획외 생산'으로 나온다. **결과가 이상하면 쿼리 G 를 먼저 볼 것.**

  4) 실적은 **양품만**(`SUB_TP='0' AND BAD_YN='0'`) 센다. 불량까지 생산량으로 인정하는
     정의를 쓰려면 `#ACT` 의 `ACT_QT` 조건을 바꿀 것. 불량 수량은 별도 컬럼으로 제공한다.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   M01_작업지시_진행현황.sql   : 계획 → 지시 → 실적의 중간 단계
   M06_불량파레토_품질KPI.sql  : 실적 중 불량 비중
   원자재수급총괄현황_MRP.sql  : 계획 → 소요량 전개 (MPS 의 하류)
   P05_재고알람_KPI.sql        : 과잉 생산이 재고로 쌓이는지
==============================================================================================*/
