/*==============================================================================================
  [ iCUBE ] S-09  영업계획 대비 실적                                                 (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 영업계획(Forecast)대로 팔았는가. 고객·담당·부서·품목 축으로 달성률을 본다.
         + **계획 없이 판 것 / 계획했는데 못 판 것** 을 양방향으로 잡는다.

  DBMS : MS-SQL Server 2012 이상 (T-SQL)   ★ 2008 R2 불가 : OVER 프레임 (ROWS/RANGE BETWEEN), 집계 SUM() OVER(ORDER BY …)

  ----------------------------------------------------------------------------------------------
  [ 소스 ]
  ----------------------------------------------------------------------------------------------
     LFORECST / LFORECST_D       영업계획 (수량·금액)
     LFORECST_SLS_D              영업계획 판매 상세
     실적 : LSALECLS_D (마감 기준 = 회계 확정)  ※ 수주 기준을 쓰려면 @ACT_SRC='SO'

     ※ 계획 테이블은 컬럼 구성이 사이트마다 크게 다르다. `sys.columns` 로 탐색하며,
       실제로 어느 컬럼을 썼는지는 **쿼리 F** 에 표시된다.

  ----------------------------------------------------------------------------------------------
  [ 산식 ]
  ----------------------------------------------------------------------------------------------
     달성률   = 실적 / 계획 * 100
     계획준수 = 달성률이 [100-@TOL, 100+@TOL] 범위
     미달성액 = 계획 - 실적  (양수면 미달)
     계획외   = 계획에 없는 거래처·품목의 실적
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@FR_YM    NVARCHAR(6)  = N'202601'
    ,@TO_YM    NVARCHAR(6)  = N'202612'
    ,@TR_CD    NVARCHAR(10) = NULL
    ,@EMP_CD   NVARCHAR(10) = NULL
    ,@ACT_SRC  NVARCHAR(3)  = N'CLS'          -- CLS 매출마감 / SO 수주
    ,@BASE     NVARCHAR(3)  = N'AM'           -- AM 금액 / QT 수량
    ,@TARGET   DECIMAL(5,1) = 100.0           -- 목표 달성률 (%)
    ,@TOL      DECIMAL(5,1) = 10.0            -- 계획준수 허용 오차 (±%)
;

DECLARE @SQL NVARCHAR(MAX);
DECLARE @FTBL NVARCHAR(30) = NULL, @FQT NVARCHAR(30), @FAM NVARCHAR(30), @FDT NVARCHAR(30);
DECLARE @HAS_PLN BIT = 0;

IF OBJECT_ID('tempdb..#PLN') IS NOT NULL DROP TABLE #PLN;
IF OBJECT_ID('tempdb..#ACT') IS NOT NULL DROP TABLE #ACT;
IF OBJECT_ID('tempdb..#CMP') IS NOT NULL DROP TABLE #CMP;

CREATE TABLE #PLN (
     PER_YM NVARCHAR(6), TR_CD NVARCHAR(10), EMP_CD NVARCHAR(10)
    ,ITEM_CD NVARCHAR(25), PLN_QT DECIMAL(19,6), PLN_AM DECIMAL(19,4), CNT INT
);


/*==============================================================================================
  1. #PLN : 영업계획 적재  ─ 테이블/컬럼 자동 탐색
==============================================================================================*/
IF    OBJECT_ID(N'dbo.LFORECST_SLS_D', N'U') IS NOT NULL SET @FTBL = N'LFORECST_SLS_D';
ELSE IF OBJECT_ID(N'dbo.LFORECST_D'  , N'U') IS NOT NULL SET @FTBL = N'LFORECST_D';

IF @FTBL IS NOT NULL
BEGIN
    SELECT TOP 1 @FQT = name FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.' + @FTBL)
      AND name IN (N'PLAN_QT', N'FORE_QT', N'SLS_QT', N'ITEM_QT', N'QT')
    ORDER BY CASE name WHEN N'PLAN_QT' THEN 1 WHEN N'FORE_QT' THEN 2 ELSE 3 END;

    SELECT TOP 1 @FAM = name FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.' + @FTBL)
      AND name IN (N'PLAN_AM', N'FORE_AM', N'SLS_AM', N'ITEM_AM', N'AM')
    ORDER BY CASE name WHEN N'PLAN_AM' THEN 1 WHEN N'FORE_AM' THEN 2 ELSE 3 END;

    SELECT TOP 1 @FDT = name FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.' + @FTBL)
      AND name IN (N'PLAN_DT', N'FORE_DT', N'PLAN_YM', N'SMM', N'P_MM', N'YM')
    ORDER BY CASE name WHEN N'PLAN_DT' THEN 1 WHEN N'FORE_DT' THEN 2
                       WHEN N'PLAN_YM' THEN 3 ELSE 4 END;

    IF @FDT IS NOT NULL AND (@FQT IS NOT NULL OR @FAM IS NOT NULL)
    BEGIN
        SET @SQL = N'
            INSERT INTO #PLN (PER_YM, TR_CD, EMP_CD, ITEM_CD, PLN_QT, PLN_AM, CNT)
            SELECT LEFT(F.' + QUOTENAME(@FDT) + N', 6)
                  ,ISNULL(F.TR_CD, N'''')
                  ,' + CASE WHEN EXISTS (SELECT 1 FROM sys.columns
                                         WHERE object_id=OBJECT_ID(N'dbo.'+@FTBL) AND name=N'EMP_CD')
                            THEN N'ISNULL(F.EMP_CD, N'''')' ELSE N'N''''' END + N'
                  ,ISNULL(F.ITEM_CD, N'''')
                  ,' + CASE WHEN @FQT IS NOT NULL
                            THEN N'SUM(CAST(ISNULL(F.' + QUOTENAME(@FQT) + N',0) AS DECIMAL(19,6)))'
                            ELSE N'0' END + N'
                  ,' + CASE WHEN @FAM IS NOT NULL
                            THEN N'SUM(CAST(ISNULL(F.' + QUOTENAME(@FAM) + N',0) AS DECIMAL(19,4)))'
                            ELSE N'0' END + N'
                  ,COUNT(*)
            FROM   dbo.' + @FTBL + N' F WITH (NOLOCK)
            WHERE  F.CO_CD = @p_CO
              AND  LEFT(F.' + QUOTENAME(@FDT) + N', 6) BETWEEN @p_FR AND @p_TO
              AND  ISNULL(F.USE_YN, N''1'') = N''1''
              AND  (@p_DIV IS NULL OR F.DIV_CD = @p_DIV)
              AND  (@p_TR  IS NULL OR F.TR_CD  = @p_TR)
            GROUP BY LEFT(F.' + QUOTENAME(@FDT) + N', 6), F.TR_CD
                    ,' + CASE WHEN EXISTS (SELECT 1 FROM sys.columns
                                           WHERE object_id=OBJECT_ID(N'dbo.'+@FTBL) AND name=N'EMP_CD')
                              THEN N'F.EMP_CD' ELSE N'N''''' END + N'
                    ,F.ITEM_CD';
        BEGIN TRY
            EXEC sp_executesql @SQL
                ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_FR NVARCHAR(6), @p_TO NVARCHAR(6)
                  ,@p_TR NVARCHAR(10)'
                ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_FR=@FR_YM, @p_TO=@TO_YM, @p_TR=@TR_CD;
            SET @HAS_PLN = 1;
            PRINT N'[1] ' + @FTBL + N' (' + ISNULL(@FDT,N'?') + N'/' + ISNULL(@FAM,@FQT) + N') : '
                  + CAST((SELECT COUNT(*) FROM #PLN) AS NVARCHAR(20)) + N' 행';
        END TRY
        BEGIN CATCH PRINT N'[1] ★ 계획 조회 실패 : ' + ERROR_MESSAGE(); END CATCH
    END
    ELSE PRINT N'[1] ' + @FTBL + N' 에 계획수량/금액/일자 컬럼을 찾지 못함';
END
ELSE PRINT N'[1] LFORECST_SLS_D / LFORECST_D 없음 - 영업계획 미운영';

CREATE CLUSTERED INDEX IX_PLN ON #PLN (PER_YM, TR_CD, ITEM_CD);


/*==============================================================================================
  2. #ACT : 실적 (매출마감 또는 수주)
==============================================================================================*/
IF @ACT_SRC = N'SO'
    SELECT
         PER_YM  = LEFT(H.SO_DT, 6)
        ,H.TR_CD
        ,EMP_CD  = ISNULL(NULLIF(D.EMP_CD, N''), ISNULL(H.EMP_CD, N''))
        ,D.ITEM_CD
        ,ACT_QT  = SUM(CAST(ISNULL(D.SO_QT, 0) AS DECIMAL(19,6)))
        ,ACT_AM  = SUM(CAST(ISNULL(D.SOG_AM, D.SO_AM) AS DECIMAL(19,4)))
        ,CNT     = COUNT(*)
    INTO #ACT
    FROM       LSO   H WITH (NOLOCK)
    INNER JOIN LSO_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.SO_NB = H.SO_NB
    WHERE  H.CO_CD = @CO_CD
      AND  LEFT(H.SO_DT, 6) BETWEEN @FR_YM AND @TO_YM
      AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
      AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
      AND  (@TR_CD  IS NULL OR H.TR_CD  = @TR_CD)
    GROUP BY LEFT(H.SO_DT, 6), H.TR_CD, ISNULL(NULLIF(D.EMP_CD,N''), ISNULL(H.EMP_CD,N'')), D.ITEM_CD;
ELSE
    SELECT
         PER_YM  = LEFT(H.CLS_DT, 6)
        ,H.TR_CD
        ,EMP_CD  = ISNULL(NULLIF(D.EMP_CD, N''), ISNULL(H.EMP_CD, N''))
        ,D.ITEM_CD
        ,ACT_QT  = SUM(CAST(ISNULL(D.CLS_QT, 0) AS DECIMAL(19,6)))
        ,ACT_AM  = SUM(CAST(ISNULL(D.CLSG_AM, D.CLSH_AM) AS DECIMAL(19,4)))
        ,CNT     = COUNT(*)
    INTO #ACT
    FROM       LSALECLS   H WITH (NOLOCK)
    INNER JOIN LSALECLS_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.CLS_NB = H.CLS_NB
    WHERE  H.CO_CD = @CO_CD
      AND  LEFT(H.CLS_DT, 6) BETWEEN @FR_YM AND @TO_YM
      AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
      AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
      AND  (@TR_CD  IS NULL OR H.TR_CD  = @TR_CD)
    GROUP BY LEFT(H.CLS_DT, 6), H.TR_CD, ISNULL(NULLIF(D.EMP_CD,N''), ISNULL(H.EMP_CD,N'')), D.ITEM_CD;

CREATE CLUSTERED INDEX IX_ACT ON #ACT (PER_YM, TR_CD, ITEM_CD);


/*==============================================================================================
  3. #CMP : 계획 × 실적 대사 (FULL JOIN)
==============================================================================================*/
SELECT
     PER_YM  = ISNULL(P.PER_YM , A.PER_YM )
    ,TR_CD   = ISNULL(P.TR_CD  , A.TR_CD  )
    ,EMP_CD  = ISNULL(NULLIF(A.EMP_CD, N''), P.EMP_CD)
    ,ITEM_CD = ISNULL(P.ITEM_CD, A.ITEM_CD)
    ,PLN_QT  = ISNULL(P.PLN_QT, 0)
    ,PLN_AM  = ISNULL(P.PLN_AM, 0)
    ,ACT_QT  = ISNULL(A.ACT_QT, 0)
    ,ACT_AM  = ISNULL(A.ACT_AM, 0)
    ,ACT_CNT = ISNULL(A.CNT, 0)
    ,MATCH_FG = CASE WHEN P.PER_YM IS NULL THEN N'A'       -- 계획외 실적
                     WHEN A.PER_YM IS NULL THEN N'P'       -- 미달성 계획
                     ELSE N'B' END
    -- 평가 기준값
    ,PLN_V = CASE @BASE WHEN N'QT' THEN ISNULL(P.PLN_QT,0) ELSE ISNULL(P.PLN_AM,0) END
    ,ACT_V = CASE @BASE WHEN N'QT' THEN ISNULL(A.ACT_QT,0) ELSE ISNULL(A.ACT_AM,0) END
INTO #CMP
FROM      #PLN P
FULL JOIN #ACT A ON A.PER_YM = P.PER_YM AND A.TR_CD = P.TR_CD AND A.ITEM_CD = P.ITEM_CD
WHERE  @EMP_CD IS NULL OR ISNULL(NULLIF(A.EMP_CD,N''), P.EMP_CD) = @EMP_CD;
CREATE CLUSTERED INDEX IX_CMP ON #CMP (PER_YM, TR_CD);


/*==============================================================================================
  ** 쿼리 A : 전사 계획 대비 실적 요약
==============================================================================================*/
SELECT
     N'[A] 영업계획 대비 실적 요약'                 AS REPORT_NM
    ,@FR_YM + N' ~ ' + @TO_YM                       AS 기간
    ,실적기준 = CASE @ACT_SRC WHEN N'SO' THEN N'수주' ELSE N'매출마감' END
    ,평가기준 = CASE @BASE WHEN N'QT' THEN N'수량' ELSE N'금액' END
    ,@TARGET                                        AS 목표달성률_PCT
    ,계획거래처수 = COUNT(DISTINCT CASE WHEN C.MATCH_FG IN (N'B',N'P') THEN C.TR_CD END)
    ,실적거래처수 = COUNT(DISTINCT CASE WHEN C.MATCH_FG IN (N'B',N'A') THEN C.TR_CD END)
    ,계획수량 = SUM(C.PLN_QT)
    ,실적수량 = SUM(C.ACT_QT)
    ,계획금액 = SUM(C.PLN_AM)
    ,실적금액 = SUM(C.ACT_AM)
    ,달성률_PCT = CAST(SUM(C.ACT_V) / NULLIF(SUM(C.PLN_V), 0) * 100 AS DECIMAL(9,1))
    ,미달성액 = SUM(C.PLN_V) - SUM(C.ACT_V)
    ,계획외실적 = SUM(CASE WHEN C.MATCH_FG = N'A' THEN C.ACT_V ELSE 0 END)
    ,미달성계획 = SUM(CASE WHEN C.MATCH_FG = N'P' THEN C.PLN_V ELSE 0 END)
    ,계획외비율_PCT = CAST(SUM(CASE WHEN C.MATCH_FG=N'A' THEN C.ACT_V ELSE 0 END) * 100.0
                           / NULLIF(SUM(C.ACT_V), 0) AS DECIMAL(5,1))
    ,판정 = CASE
         WHEN @HAS_PLN = 0
              THEN N'9.★영업계획 미운영 또는 컬럼 미확인 - 쿼리 F 확인'
         WHEN SUM(C.PLN_V) = 0
              THEN N'8.★기간 내 계획 없음'
         WHEN SUM(CASE WHEN C.MATCH_FG=N'A' THEN C.ACT_V ELSE 0 END)
              / NULLIF(SUM(C.ACT_V), 0) > 0.5
              THEN N'1.★계획외 실적이 절반 초과 - 계획 수립이 형해화됨'
         WHEN SUM(C.ACT_V) / NULLIF(SUM(C.PLN_V), 0) * 100 >= @TARGET
              THEN N'0.목표 달성'
         WHEN SUM(C.ACT_V) / NULLIF(SUM(C.PLN_V), 0) * 100 >= @TARGET - 10
              THEN N'2.목표 근접'
         ELSE N'3.★목표 미달' END
FROM   #CMP C
;


/*==============================================================================================
  ** 쿼리 B : 월별 계획 대비 실적 추이
==============================================================================================*/
SELECT
     N'[B] 월별 계획 대비 실적'                     AS REPORT_NM
    ,C.PER_YM                                       AS 기간월
    ,계획 = SUM(C.PLN_V)
    ,실적 = SUM(C.ACT_V)
    ,차이 = SUM(C.ACT_V) - SUM(C.PLN_V)
    ,달성률_PCT = CAST(SUM(C.ACT_V) / NULLIF(SUM(C.PLN_V), 0) * 100 AS DECIMAL(9,1))
    ,누계계획 = SUM(SUM(C.PLN_V)) OVER (ORDER BY C.PER_YM ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
    ,누계실적 = SUM(SUM(C.ACT_V)) OVER (ORDER BY C.PER_YM ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
    ,누계달성률_PCT = CAST(SUM(SUM(C.ACT_V)) OVER (ORDER BY C.PER_YM ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                           / NULLIF(SUM(SUM(C.PLN_V)) OVER (ORDER BY C.PER_YM ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 0)
                           * 100 AS DECIMAL(9,1))
    ,계획외실적 = SUM(CASE WHEN C.MATCH_FG = N'A' THEN C.ACT_V ELSE 0 END)
    ,거래처수 = COUNT(DISTINCT C.TR_CD)
    ,목표달성 = CASE WHEN SUM(C.ACT_V)/NULLIF(SUM(C.PLN_V),0)*100 >= @TARGET THEN N'O' ELSE N'X' END
FROM   #CMP C
GROUP BY C.PER_YM
ORDER BY 기간월
;


/*==============================================================================================
  ** 쿼리 C : 거래처별 달성률
==============================================================================================*/
SELECT
     N'[C] 거래처별 달성률'                         AS REPORT_NM
    ,상태 = CASE
         WHEN SUM(C.PLN_V) = 0                                        THEN N'1.★계획외 거래처'
         WHEN SUM(C.ACT_V) = 0                                        THEN N'2.★실적 전무'
         WHEN SUM(C.ACT_V) / NULLIF(SUM(C.PLN_V),0) * 100 < 100-@TOL   THEN N'3.미달'
         WHEN SUM(C.ACT_V) / NULLIF(SUM(C.PLN_V),0) * 100 > 100+@TOL   THEN N'4.초과'
         ELSE N'0.계획 준수' END
    ,C.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,품목수 = COUNT(DISTINCT C.ITEM_CD)
    ,계획 = SUM(C.PLN_V)
    ,실적 = SUM(C.ACT_V)
    ,차이 = SUM(C.ACT_V) - SUM(C.PLN_V)
    ,달성률_PCT = CAST(SUM(C.ACT_V) / NULLIF(SUM(C.PLN_V), 0) * 100 AS DECIMAL(9,1))
    ,계획금액 = SUM(C.PLN_AM)
    ,실적금액 = SUM(C.ACT_AM)
    ,계획수량 = SUM(C.PLN_QT)
    ,실적수량 = SUM(C.ACT_QT)
    ,실적기여도_PCT = CAST(SUM(C.ACT_V) * 100.0
                           / NULLIF(SUM(SUM(C.ACT_V)) OVER (), 0) AS DECIMAL(5,1))
FROM       #CMP   C
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD = C.TR_CD
GROUP BY C.TR_CD, T.TR_NM
ORDER BY 상태, ABS(차이) DESC
;


/*==============================================================================================
  ** 쿼리 D : 담당자·부서별 달성률
==============================================================================================*/
SELECT
     N'[D] 담당자별 달성률'                         AS REPORT_NM
    ,C.EMP_CD                                       AS 담당자코드
    ,E.EMP_NM                                       AS 담당자명
    ,P.DEPT_NM                                      AS 부서명
    ,거래처수 = COUNT(DISTINCT C.TR_CD)
    ,품목수 = COUNT(DISTINCT C.ITEM_CD)
    ,계획 = SUM(C.PLN_V)
    ,실적 = SUM(C.ACT_V)
    ,차이 = SUM(C.ACT_V) - SUM(C.PLN_V)
    ,달성률_PCT = CAST(SUM(C.ACT_V) / NULLIF(SUM(C.PLN_V), 0) * 100 AS DECIMAL(9,1))
    ,계획외실적 = SUM(CASE WHEN C.MATCH_FG = N'A' THEN C.ACT_V ELSE 0 END)
    ,미달성계획 = SUM(CASE WHEN C.MATCH_FG = N'P' THEN C.PLN_V ELSE 0 END)
    ,판정 = CASE
         WHEN SUM(C.PLN_V) = 0                                          THEN N'9.계획 없음'
         WHEN SUM(C.ACT_V) / NULLIF(SUM(C.PLN_V),0) * 100 >= @TARGET     THEN N'0.목표 달성'
         WHEN SUM(C.ACT_V) / NULLIF(SUM(C.PLN_V),0) * 100 >= @TARGET-20  THEN N'1.주의'
         ELSE N'2.★목표 미달' END
FROM       #CMP  C
LEFT  JOIN SEMP  E WITH (NOLOCK) ON E.CO_CD = @CO_CD AND E.EMP_CD  = C.EMP_CD
LEFT  JOIN SDEPT P WITH (NOLOCK) ON P.CO_CD = @CO_CD AND P.DEPT_CD = E.DEPT_CD
GROUP BY C.EMP_CD, E.EMP_NM, P.DEPT_NM
ORDER BY 판정 DESC, 달성률_PCT
;


/*==============================================================================================
  ** 쿼리 E : 미달성 계획 / 계획외 실적 상세
==============================================================================================*/
SELECT
     N'[E] 계획 이탈 상세'                          AS REPORT_NM
    ,구분 = CASE C.MATCH_FG WHEN N'P' THEN N'1.★미달성 계획 (계획만 있음)'
                            WHEN N'A' THEN N'2.★계획외 실적 (실적만 있음)'
                            ELSE N'3.차이 큼' END
    ,C.PER_YM                                       AS 기간월
    ,C.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,C.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.UNIT_CD                                      AS 단위
    ,C.PLN_QT                                       AS 계획수량
    ,C.ACT_QT                                       AS 실적수량
    ,C.PLN_AM                                       AS 계획금액
    ,C.ACT_AM                                       AS 실적금액
    ,차이 = C.ACT_V - C.PLN_V
    ,달성률_PCT = CAST(CASE WHEN C.PLN_V <> 0 THEN C.ACT_V / C.PLN_V * 100 END AS DECIMAL(9,1))
    ,C.EMP_CD                                       AS 담당자
    ,E.EMP_NM                                       AS 담당자명
    ,확인사항 = CASE C.MATCH_FG
         WHEN N'P' THEN N'계획 미달성 사유 확인 - 수주 실패 / 납기 이월 / 계획 과다'
         WHEN N'A' THEN N'계획에 없던 판매 - 계획 누락인지 신규 기회인지 확인'
         ELSE N'계획 정확도 개선 대상' END
FROM       #CMP   C
LEFT  JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = C.ITEM_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = C.TR_CD
LEFT  JOIN SEMP   E WITH (NOLOCK) ON E.CO_CD = @CO_CD AND E.EMP_CD  = C.EMP_CD
WHERE  C.MATCH_FG IN (N'P', N'A')
   OR  (C.PLN_V <> 0 AND ABS(C.ACT_V / NULLIF(C.PLN_V,0) * 100 - 100) > @TOL * 2)
ORDER BY 구분, ABS(차이) DESC
;


/*==============================================================================================
  ** 쿼리 F : 데이터 점검  ★ 실행 전 반드시 확인
==============================================================================================*/
SELECT
     N'[F] 데이터 점검'                             AS REPORT_NM
    ,계획테이블  = ISNULL(@FTBL, N'★없음')
    ,계획일자컬럼 = ISNULL(@FDT, N'(미확인)')
    ,계획수량컬럼 = ISNULL(@FQT, N'(미확인)')
    ,계획금액컬럼 = ISNULL(@FAM, N'(미확인)')
    ,적재성공 = CASE WHEN @HAS_PLN = 1 THEN N'O' ELSE N'X' END
    ,계획행수 = (SELECT COUNT(*) FROM #PLN)
    ,실적행수 = (SELECT COUNT(*) FROM #ACT)
    ,LFORECST     = CASE WHEN OBJECT_ID(N'dbo.LFORECST'    ,N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,LFORECST_D   = CASE WHEN OBJECT_ID(N'dbo.LFORECST_D'  ,N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,LFORECST_SLS_D = CASE WHEN OBJECT_ID(N'dbo.LFORECST_SLS_D',N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,판정 = CASE
         WHEN @FTBL IS NULL
              THEN N'1.★영업계획 테이블 없음 - 계획 미운영. 본 리포트 사용 불가'
         WHEN @HAS_PLN = 0
              THEN N'2.★컬럼 자동 탐색 실패 - 아래 확인 쿼리로 실제 컬럼을 확인하고 후보에 추가'
         WHEN (SELECT COUNT(*) FROM #PLN) = 0
              THEN N'3.★기간 내 계획 없음 - 기간을 넓혀 재조회'
         WHEN (SELECT SUM(PLN_AM) FROM #PLN) = 0 AND @BASE = N'AM'
              THEN N'4.★계획 금액이 전부 0 - @BASE=''QT''(수량) 로 바꿔 조회할 것'
         ELSE N'0.정상' END
;


DROP TABLE #PLN, #ACT, #CMP;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 영업계획 테이블/컬럼  ★ 본 쿼리는 자동 탐색하지만 직접 확인이 확실하다
     SELECT name FROM sys.tables WHERE name LIKE 'LFORECST%';
     SELECT name, TYPE_NAME(user_type_id) FROM sys.columns
     WHERE object_id = OBJECT_ID('LFORECST_SLS_D') ORDER BY column_id;
     --> 수량 후보 : PLAN_QT, FORE_QT, SLS_QT, ITEM_QT, QT
        금액 후보 : PLAN_AM, FORE_AM, SLS_AM, ITEM_AM, AM
        일자 후보 : PLAN_DT, FORE_DT, PLAN_YM, SMM, P_MM, YM
        없으면 1번 블록의 IN (...) 에 실제 컬럼명을 추가할 것.

  -- (2) 계획 운영 여부
     SELECT COUNT(*) FROM LFORECST_SLS_D WHERE CO_CD='1000';
     --> 0 이면 영업계획 미운영. 이 경우 S-10(판매추이)의 전년 대비가 사실상의 기준선이다.

  -- (3) 계획 입도 확인  ★ 월 단위인지 일 단위인지, 품목까지 있는지
     SELECT TOP 20 * FROM LFORECST_SLS_D WHERE CO_CD='1000' ORDER BY 1 DESC;
     --> 본 쿼리는 월 × 거래처 × 품목 으로 집계한다. 품목 없이 거래처만 계획하는 사이트는
        `ITEM_CD` 가 공백이 되어 실적과 매칭되지 않는다. 그 경우 쿼리 C(거래처별)만 쓸 것.

  -- (4) 실적 기준 선택  ★ 계획을 수주 기준으로 세우는지 매출 기준으로 세우는지
     --> 수주 기준이면 @ACT_SRC='SO'. 기본값은 매출마감(CLS)이다.
        계획 수립 기준과 다르면 달성률이 구조적으로 어긋난다.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **계획과 실적의 매칭 입도가 맞아야 한다.** 계획을 거래처 단위로만 세우는데 실적을
     품목까지 나눠 비교하면 전부 '계획외 실적'으로 잡힌다. 확인 (3)번으로 입도를 먼저 볼 것.

  2) **계획 변경 이력을 추적하지 않는다.** 기중에 계획을 하향하면 달성률이 좋아진다.
     M-11(생산계획 대비)과 동일한 구조적 약점이다.

  3) 계획 금액과 실적 금액의 **부가세 포함 여부**가 다를 수 있다. 실적은 공급가액(CLSG_AM)을
     우선 쓰므로, 계획이 부가세 포함이면 달성률이 낮게 나온다. 확인 후 기준을 맞출 것.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   S05_판매분석_다축.sql   : 전년 동기 대비 (계획이 없을 때의 대안 기준선)
   C05_매출이익_분석.sql   : 계획 달성이 이익으로 이어졌는가
   M11_생산계획대비실적.sql : 같은 구조의 생산 버전
==============================================================================================*/
