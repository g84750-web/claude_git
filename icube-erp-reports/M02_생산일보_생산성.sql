/*==============================================================================================
  [ iCUBE ] M-02 생산 일보 · 월보  +  M-08 설비 · 작업팀별 생산성                    (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 현장이 매일 보는 생산 일보와, 그것을 설비·작업팀·교대조 축으로 갈라 본 생산성 분석.
         같은 `LORCV_H` 를 다른 축으로 집계하는 것이므로 한 파일에 담았다.

  DBMS : MS-SQL Server 2012 이상 (T-SQL)   ★ 2008 R2 불가 : LAG(), OVER 프레임 (ROWS/RANGE BETWEEN), 집계 SUM() OVER(ORDER BY …)

  ----------------------------------------------------------------------------------------------
  [ 산출 축 ]
  ----------------------------------------------------------------------------------------------
     일보/월보 : 일자 → 품목 → 공정
     생산성    : 설비(EQUIP_CD) / 작업팀(WTEAM_CD) / 교대조(WSHFT_CD) / 작업자(EMP_CD)

     ※ 설비·작업팀·교대조 컬럼은 사이트마다 운영 여부가 다르다.
       `sys.columns` 로 존재를 확인해 있는 축만 집계한다 (쿼리 F 에 표시).

  ----------------------------------------------------------------------------------------------
  [ 산식 ]
  ----------------------------------------------------------------------------------------------
     양품수량 = SUM(ITEM_QT) WHERE SUB_TP='0' AND BAD_YN='0'
     불량수량 = SUM(ITEM_QT) WHERE BAD_YN='1'
     양품률   = 양품 / (양품+불량) * 100
     일평균생산 = 양품수량 / 가동일수
     인당생산성 = 양품수량 / 작업자수
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@FR_DT    NVARCHAR(8)  = N'20260901'
    ,@TO_DT    NVARCHAR(8)  = N'20260930'
    ,@ITEM_CD  NVARCHAR(25) = NULL
    ,@PROC_CD  NVARCHAR(10) = NULL
    ,@DEPT_CD  NVARCHAR(10) = NULL
    ,@TGT_QC   DECIMAL(5,1) = 97.0            -- 목표 양품률 (%)
;

DECLARE @SQL NVARCHAR(MAX);
DECLARE @HAS_EQ BIT = 0, @HAS_TM BIT = 0, @HAS_SH BIT = 0;

-- 축 컬럼 존재 확인
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID(N'dbo.LORCV_H') AND name=N'EQUIP_CD') SET @HAS_EQ = 1;
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID(N'dbo.LORCV_H') AND name=N'WTEAM_CD') SET @HAS_TM = 1;
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID(N'dbo.LORCV_H') AND name=N'WSHFT_CD') SET @HAS_SH = 1;
PRINT N'[0] 축 : 설비=' + CAST(@HAS_EQ AS NVARCHAR(1))
    + N' 작업팀=' + CAST(@HAS_TM AS NVARCHAR(1))
    + N' 교대조=' + CAST(@HAS_SH AS NVARCHAR(1));

IF OBJECT_ID('tempdb..#R') IS NOT NULL DROP TABLE #R;


/*==============================================================================================
  1. #R : 생산실적  ─ 있는 축만 동적으로 가져온다
==============================================================================================*/
SET @SQL = N'
    SELECT
         R.WR_DT
        ,R.WR_CD
        ,WO_CD   = ISNULL(R.WO_CD  , N'''')
        ,R.ITEM_CD
        ,PROC_CD = ISNULL(R.PROC_CD, N'''')
        ,WC_CD   = ISNULL(R.WC_CD  , N'''')
        ,DEPT_CD = ISNULL(R.DEPT_CD, N'''')
        ,EMP_CD  = ISNULL(R.EMP_CD , N'''')
        ,EQUIP_CD = ' + CASE WHEN @HAS_EQ=1 THEN N'ISNULL(R.EQUIP_CD, N'''')' ELSE N'N''''' END + N'
        ,WTEAM_CD = ' + CASE WHEN @HAS_TM=1 THEN N'ISNULL(R.WTEAM_CD, N'''')' ELSE N'N''''' END + N'
        ,WSHFT_CD = ' + CASE WHEN @HAS_SH=1 THEN N'ISNULL(R.WSHFT_CD, N'''')' ELSE N'N''''' END + N'
        ,GOOD_QT = CASE WHEN ISNULL(R.SUB_TP,N''0'')=N''0'' AND ISNULL(R.BAD_YN,N''0'')=N''0''
                        THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END
        ,BAD_QT  = CASE WHEN ISNULL(R.BAD_YN,N''0'')=N''1''
                        THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END
        ,SUB_QT  = CASE WHEN ISNULL(R.SUB_TP,N''0'')=N''1''
                        THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END
        ,RWK_QT  = CASE WHEN ISNULL(R.REWORK_YN,N''0'')=N''1''
                        THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END
        ,BASE_QT = CASE WHEN ISNULL(R.SUB_TP,N''0'')=N''0''
                        THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END
    INTO #R
    FROM       LORCV_H R WITH (NOLOCK)
    LEFT  JOIN SITEM   I WITH (NOLOCK) ON I.CO_CD = R.CO_CD AND I.ITEM_CD = R.ITEM_CD
    WHERE  R.CO_CD = @p_CO
      AND  R.WR_DT BETWEEN @p_FR AND @p_TO
      AND  ISNULL(R.USE_YN, N''1'') = N''1''
      AND  (@p_DIV  IS NULL OR R.DIV_CD  = @p_DIV)
      AND  (@p_ITEM IS NULL OR R.ITEM_CD = @p_ITEM)
      AND  (@p_PROC IS NULL OR R.PROC_CD = @p_PROC)
      AND  (@p_DEPT IS NULL OR R.DEPT_CD = @p_DEPT)
      AND  ISNULL(I.S_CD, N'''') <> N''Z00''';
EXEC sp_executesql @SQL
    ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_FR NVARCHAR(8), @p_TO NVARCHAR(8)
      ,@p_ITEM NVARCHAR(25), @p_PROC NVARCHAR(10), @p_DEPT NVARCHAR(10)'
    ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_FR=@FR_DT, @p_TO=@TO_DT
    ,@p_ITEM=@ITEM_CD, @p_PROC=@PROC_CD, @p_DEPT=@DEPT_CD;

CREATE CLUSTERED INDEX IX_R ON #R (WR_DT, ITEM_CD);
PRINT N'[1] 생산실적 : ' + CAST((SELECT COUNT(*) FROM #R) AS NVARCHAR(20)) + N' 건';


/*==============================================================================================
  ** 쿼리 A : 생산 일보  (일자별)  ★ 현장이 매일 보는 화면
==============================================================================================*/
SELECT
     N'[A] 생산 일보'                               AS REPORT_NM
    ,R.WR_DT                                        AS 생산일
    ,요일 = CASE DATEPART(WEEKDAY, CONVERT(DATE, R.WR_DT))
                 WHEN 1 THEN N'일' WHEN 2 THEN N'월' WHEN 3 THEN N'화' WHEN 4 THEN N'수'
                 WHEN 5 THEN N'목' WHEN 6 THEN N'금' ELSE N'토' END
    ,실적건수 = COUNT(*)
    ,지시수   = COUNT(DISTINCT NULLIF(R.WO_CD, N''))
    ,품목수   = COUNT(DISTINCT R.ITEM_CD)
    ,작업자수 = COUNT(DISTINCT NULLIF(R.EMP_CD, N''))
    ,양품수량 = SUM(R.GOOD_QT)
    ,불량수량 = SUM(R.BAD_QT)
    ,부산물   = SUM(R.SUB_QT)
    ,재작업   = SUM(R.RWK_QT)
    ,생산합계 = SUM(R.BASE_QT)
    ,양품률_PCT = CAST(SUM(R.GOOD_QT) / NULLIF(SUM(R.BASE_QT), 0) * 100 AS DECIMAL(5,2))
    ,직행률_PCT = CAST((SUM(R.GOOD_QT) - SUM(R.RWK_QT))
                       / NULLIF(SUM(R.BASE_QT), 0) * 100 AS DECIMAL(5,2))
    ,전일대비_양품 = SUM(R.GOOD_QT) - LAG(SUM(R.GOOD_QT)) OVER (ORDER BY R.WR_DT)
    ,누계양품 = SUM(SUM(R.GOOD_QT)) OVER (ORDER BY R.WR_DT
                 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
    ,@TGT_QC                                        AS 목표양품률
    ,목표달성 = CASE WHEN SUM(R.GOOD_QT)/NULLIF(SUM(R.BASE_QT),0)*100 >= @TGT_QC
                     THEN N'O' ELSE N'X' END
FROM   #R R
GROUP BY R.WR_DT
ORDER BY 생산일
;


/*==============================================================================================
  ** 쿼리 B : 생산 월보  (월별 + 일평균)
==============================================================================================*/
SELECT
     N'[B] 생산 월보'                               AS REPORT_NM
    ,LEFT(R.WR_DT, 6)                               AS 생산월
    ,가동일수 = COUNT(DISTINCT R.WR_DT)
    ,실적건수 = COUNT(*)
    ,지시수   = COUNT(DISTINCT NULLIF(R.WO_CD, N''))
    ,품목수   = COUNT(DISTINCT R.ITEM_CD)
    ,양품수량 = SUM(R.GOOD_QT)
    ,불량수량 = SUM(R.BAD_QT)
    ,재작업   = SUM(R.RWK_QT)
    ,생산합계 = SUM(R.BASE_QT)
    ,일평균생산 = CAST(SUM(R.GOOD_QT) / NULLIF(COUNT(DISTINCT R.WR_DT), 0) AS DECIMAL(19,2))
    ,양품률_PCT = CAST(SUM(R.GOOD_QT) / NULLIF(SUM(R.BASE_QT), 0) * 100 AS DECIMAL(5,2))
    ,직행률_PCT = CAST((SUM(R.GOOD_QT) - SUM(R.RWK_QT))
                       / NULLIF(SUM(R.BASE_QT), 0) * 100 AS DECIMAL(5,2))
    ,전월대비_양품_PCT = CAST(
         (SUM(R.GOOD_QT) / NULLIF(LAG(SUM(R.GOOD_QT)) OVER (ORDER BY LEFT(R.WR_DT,6)), 0) - 1) * 100
         AS DECIMAL(9,1))
    ,전월대비_양품률_PCTP = CAST(
         SUM(R.GOOD_QT)/NULLIF(SUM(R.BASE_QT),0)*100
       - LAG(SUM(R.GOOD_QT)/NULLIF(SUM(R.BASE_QT),0)*100) OVER (ORDER BY LEFT(R.WR_DT,6))
         AS DECIMAL(5,2))
FROM   #R R
GROUP BY LEFT(R.WR_DT, 6)
ORDER BY 생산월
;


/*==============================================================================================
  ** 쿼리 C : 품목별 생산 실적
==============================================================================================*/
SELECT
     N'[C] 품목별 생산'                             AS REPORT_NM
    ,R.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'2' THEN N'제품' WHEN N'4' THEN N'반제품' ELSE I.ACCT_FG END
    ,생산일수 = COUNT(DISTINCT R.WR_DT)
    ,실적건수 = COUNT(*)
    ,지시수   = COUNT(DISTINCT NULLIF(R.WO_CD, N''))
    ,양품수량 = SUM(R.GOOD_QT)
    ,불량수량 = SUM(R.BAD_QT)
    ,재작업   = SUM(R.RWK_QT)
    ,양품률_PCT = CAST(SUM(R.GOOD_QT) / NULLIF(SUM(R.BASE_QT), 0) * 100 AS DECIMAL(5,2))
    ,일평균 = CAST(SUM(R.GOOD_QT) / NULLIF(COUNT(DISTINCT R.WR_DT), 0) AS DECIMAL(19,2))
    ,생산비중_PCT = CAST(SUM(R.GOOD_QT) * 100.0
                         / NULLIF(SUM(SUM(R.GOOD_QT)) OVER (), 0) AS DECIMAL(5,1))
    ,판정 = CASE
         WHEN SUM(R.GOOD_QT)/NULLIF(SUM(R.BASE_QT),0)*100 >= @TGT_QC THEN N'0.목표 달성'
         WHEN SUM(R.GOOD_QT)/NULLIF(SUM(R.BASE_QT),0)*100 >= @TGT_QC-5 THEN N'1.주의'
         ELSE N'2.★개선 필요' END
FROM       #R    R
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = R.ITEM_CD
GROUP BY R.ITEM_CD, I.ITEM_NM, I.SPEC, I.UNIT_CD, I.ACCT_FG
ORDER BY 양품수량 DESC
;


/*==============================================================================================
  ** 쿼리 D : 설비 · 작업팀 · 교대조별 생산성  (M-08)
     ─ 운영하지 않는 축은 '(미운영)' 한 줄로 나온다.
==============================================================================================*/
SELECT
     N'[D] 축별 생산성'                             AS REPORT_NM
    ,축, 코드, 가동일수, 실적건수, 품목수, 양품수량, 불량수량, 일평균생산, 양품률_PCT, 판정
FROM (
    -- 설비
    SELECT 순서=1, 축=N'1.설비'
          ,코드 = CASE WHEN R.EQUIP_CD = N'' THEN N'(미지정)' ELSE R.EQUIP_CD END
          ,가동일수 = COUNT(DISTINCT R.WR_DT)
          ,실적건수 = COUNT(*)
          ,품목수   = COUNT(DISTINCT R.ITEM_CD)
          ,양품수량 = SUM(R.GOOD_QT)
          ,불량수량 = SUM(R.BAD_QT)
          ,BASE_QT  = SUM(R.BASE_QT)
    FROM   #R R WHERE @HAS_EQ = 1 GROUP BY R.EQUIP_CD
    UNION ALL
    -- 작업팀
    SELECT 2, N'2.작업팀'
          ,CASE WHEN R.WTEAM_CD = N'' THEN N'(미지정)' ELSE R.WTEAM_CD END
          ,COUNT(DISTINCT R.WR_DT), COUNT(*), COUNT(DISTINCT R.ITEM_CD)
          ,SUM(R.GOOD_QT), SUM(R.BAD_QT), SUM(R.BASE_QT)
    FROM   #R R WHERE @HAS_TM = 1 GROUP BY R.WTEAM_CD
    UNION ALL
    -- 교대조
    SELECT 3, N'3.교대조'
          ,CASE WHEN R.WSHFT_CD = N'' THEN N'(미지정)' ELSE R.WSHFT_CD END
          ,COUNT(DISTINCT R.WR_DT), COUNT(*), COUNT(DISTINCT R.ITEM_CD)
          ,SUM(R.GOOD_QT), SUM(R.BAD_QT), SUM(R.BASE_QT)
    FROM   #R R WHERE @HAS_SH = 1 GROUP BY R.WSHFT_CD
    UNION ALL
    -- 작업장 (항상 있음)
    SELECT 4, N'4.작업장'
          ,CASE WHEN R.WC_CD = N'' THEN N'(미지정)' ELSE R.WC_CD END
          ,COUNT(DISTINCT R.WR_DT), COUNT(*), COUNT(DISTINCT R.ITEM_CD)
          ,SUM(R.GOOD_QT), SUM(R.BAD_QT), SUM(R.BASE_QT)
    FROM   #R R GROUP BY R.WC_CD
    UNION ALL
    -- 공정
    SELECT 5, N'5.공정'
          ,CASE WHEN R.PROC_CD = N'' THEN N'(미지정)' ELSE R.PROC_CD END
          ,COUNT(DISTINCT R.WR_DT), COUNT(*), COUNT(DISTINCT R.ITEM_CD)
          ,SUM(R.GOOD_QT), SUM(R.BAD_QT), SUM(R.BASE_QT)
    FROM   #R R GROUP BY R.PROC_CD
) X
CROSS APPLY (SELECT 일평균생산 = CAST(X.양품수량 / NULLIF(X.가동일수, 0) AS DECIMAL(19,2))
                   ,양품률_PCT = CAST(X.양품수량 / NULLIF(X.BASE_QT, 0) * 100 AS DECIMAL(5,2))) C
CROSS APPLY (SELECT 판정 = CASE
                 WHEN X.코드 = N'(미지정)'                THEN N'9.★코드 미지정 - 집계 불가'
                 WHEN C.양품률_PCT >= @TGT_QC             THEN N'0.양호'
                 WHEN C.양품률_PCT >= @TGT_QC - 5         THEN N'1.주의'
                 ELSE N'2.★개선 필요' END) P
ORDER BY X.순서, 양품수량 DESC
;


/*==============================================================================================
  ** 쿼리 E : 작업자별 생산성
==============================================================================================*/
SELECT
     N'[E] 작업자별 생산성'                         AS REPORT_NM
    ,R.EMP_CD                                       AS 작업자코드
    ,E.EMP_NM                                       AS 작업자명
    ,P.DEPT_NM                                      AS 부서명
    ,가동일수 = COUNT(DISTINCT R.WR_DT)
    ,실적건수 = COUNT(*)
    ,품목수   = COUNT(DISTINCT R.ITEM_CD)
    ,공정수   = COUNT(DISTINCT NULLIF(R.PROC_CD, N''))
    ,양품수량 = SUM(R.GOOD_QT)
    ,불량수량 = SUM(R.BAD_QT)
    ,재작업   = SUM(R.RWK_QT)
    ,일평균생산 = CAST(SUM(R.GOOD_QT) / NULLIF(COUNT(DISTINCT R.WR_DT), 0) AS DECIMAL(19,2))
    ,양품률_PCT = CAST(SUM(R.GOOD_QT) / NULLIF(SUM(R.BASE_QT), 0) * 100 AS DECIMAL(5,2))
    ,직행률_PCT = CAST((SUM(R.GOOD_QT) - SUM(R.RWK_QT))
                       / NULLIF(SUM(R.BASE_QT), 0) * 100 AS DECIMAL(5,2))
    ,생산비중_PCT = CAST(SUM(R.GOOD_QT) * 100.0
                         / NULLIF(SUM(SUM(R.GOOD_QT)) OVER (), 0) AS DECIMAL(5,1))
    ,판정 = CASE
         WHEN R.EMP_CD = N''                                          THEN N'9.★작업자 미지정'
         WHEN COUNT(DISTINCT R.WR_DT) < 3                             THEN N'8.표본 부족'
         WHEN SUM(R.GOOD_QT)/NULLIF(SUM(R.BASE_QT),0)*100 >= @TGT_QC   THEN N'0.양호'
         ELSE N'1.★양품률 목표 미달' END
FROM       #R    R
LEFT  JOIN SEMP  E WITH (NOLOCK) ON E.CO_CD = @CO_CD AND E.EMP_CD  = NULLIF(R.EMP_CD, N'')
LEFT  JOIN SDEPT P WITH (NOLOCK) ON P.CO_CD = @CO_CD AND P.DEPT_CD = E.DEPT_CD
GROUP BY R.EMP_CD, E.EMP_NM, P.DEPT_NM
ORDER BY 판정, 양품수량 DESC
;


/*==============================================================================================
  ** 쿼리 F : 요약 + 축 운영 현황
==============================================================================================*/
SELECT
     N'[F] 생산 요약'                               AS REPORT_NM
    ,@FR_DT + N' ~ ' + @TO_DT                       AS 기간
    ,가동일수 = COUNT(DISTINCT R.WR_DT)
    ,실적건수 = COUNT(*)
    ,지시수   = COUNT(DISTINCT NULLIF(R.WO_CD, N''))
    ,품목수   = COUNT(DISTINCT R.ITEM_CD)
    ,작업자수 = COUNT(DISTINCT NULLIF(R.EMP_CD, N''))
    ,양품수량계 = SUM(R.GOOD_QT)
    ,불량수량계 = SUM(R.BAD_QT)
    ,재작업계   = SUM(R.RWK_QT)
    ,일평균생산 = CAST(SUM(R.GOOD_QT) / NULLIF(COUNT(DISTINCT R.WR_DT), 0) AS DECIMAL(19,2))
    ,전체양품률_PCT = CAST(SUM(R.GOOD_QT) / NULLIF(SUM(R.BASE_QT), 0) * 100 AS DECIMAL(5,2))
    ,전체직행률_PCT = CAST((SUM(R.GOOD_QT)-SUM(R.RWK_QT))
                           / NULLIF(SUM(R.BASE_QT), 0) * 100 AS DECIMAL(5,2))
    -- 축 운영
    ,설비축   = CASE WHEN @HAS_EQ=1 THEN N'운영' ELSE N'미운영(컬럼 없음)' END
    ,작업팀축 = CASE WHEN @HAS_TM=1 THEN N'운영' ELSE N'미운영(컬럼 없음)' END
    ,교대조축 = CASE WHEN @HAS_SH=1 THEN N'운영' ELSE N'미운영(컬럼 없음)' END
    ,공정지정률_PCT = CAST(SUM(CASE WHEN R.PROC_CD <> N'' THEN 1.0 ELSE 0 END)
                           / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
    ,작업자지정률_PCT = CAST(SUM(CASE WHEN R.EMP_CD <> N'' THEN 1.0 ELSE 0 END)
                             / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
    ,판정 = CASE
         WHEN COUNT(*) = 0 THEN N'1.★기간 내 생산실적 없음'
         WHEN SUM(CASE WHEN R.PROC_CD <> N'' THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0) < 0.5
              THEN N'2.★공정 지정률 50% 미만 - 공정별 분석 신뢰도 낮음'
         WHEN @HAS_EQ = 0 AND @HAS_TM = 0 AND @HAS_SH = 0
              THEN N'3.설비·작업팀·교대조 축 미운영 - 작업장/공정 축만 사용'
         ELSE N'0.정상' END
FROM   #R R
;


DROP TABLE #R;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 생산성 축 컬럼 실존  ★ 본 쿼리는 자동 확인한다
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('LORCV_H')
       AND name IN ('EQUIP_CD','WTEAM_CD','WSHFT_CD','WC_CD','PROC_CD','EMP_CD');
     --> 없는 축은 쿼리 D 에서 아예 빠진다 (오류가 아니라 정상 동작).

  -- (2) 축별 채움률  ★ 컬럼이 있어도 안 쓰면 소용없다
     SELECT COUNT(*) 전체
           ,SUM(CASE WHEN ISNULL(EQUIP_CD,'')='' THEN 1 ELSE 0 END) 설비미지정
           ,SUM(CASE WHEN ISNULL(PROC_CD ,'')='' THEN 1 ELSE 0 END) 공정미지정
           ,SUM(CASE WHEN ISNULL(EMP_CD  ,'')='' THEN 1 ELSE 0 END) 작업자미지정
     FROM   LORCV_H WHERE CO_CD='1000';

  -- (3) 실적 등록 방식  ★ 일보의 의미를 좌우
     SELECT WR_DT, COUNT(*) FROM LORCV_H
     WHERE CO_CD='1000' AND WR_DT LIKE '202609%' GROUP BY WR_DT ORDER BY 1;
     --> 매일 등록하면 일보가 의미 있고, 월말 일괄 등록이면 일보는 무의미하다.
        후자면 쿼리 A 를 빼고 쿼리 B(월보)만 쓸 것.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **작업시간을 반영하지 않는다.** 진짜 생산성은 `시간당 생산량`인데 `LORCV_H` 에 작업시간
     컬럼이 표준으로 없다. 여기서는 **일평균 생산량**으로 대신한다. 설비 가동시간을 관리하는
     사이트(`LRESUSE` 등)라면 그 테이블을 조인해 시간당 생산성으로 바꾸는 편이 정확하다.

  2) **품목별 난이도 차이를 보정하지 않는다.** 쉬운 품목만 만든 작업자가 생산성이 높게 나온다.
     작업자 평가에 쓸 때는 `품목수`·`공정수` 를 함께 보고, 같은 품목을 만든 사람끼리
     비교해야 한다.

  3) 일보(쿼리 A)는 **실적 등록일 기준**이다. 실제 작업일과 등록일이 다르면 일자가 밀린다.

  4) 가동일수는 **실적이 있는 날**만 센다. 가동했으나 실적을 등록하지 않은 날은 빠진다.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   M01_작업지시_진행현황.sql   : 지시 단위 진척
   M06_불량파레토_품질KPI.sql  : 불량 원인 분해
   M11_생산계획대비실적.sql    : 계획 대비 달성
   생산지시별_작업수율현황.sql : 수율 5축 분해
==============================================================================================*/
