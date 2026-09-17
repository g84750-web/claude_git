/*==============================================================================================
  [ iCUBE ] M-04  공정별 재공 실시간 현황                                            (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 지금 각 공정/작업장에 재공이 얼마나 쌓여 있는가. **생산 병목의 직접 지표**이자,
         장기 체류 재공(사장재공)을 금액 기준으로 잡아내는 리포트.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 소스 ]
  ----------------------------------------------------------------------------------------------
     LINV_WIP     재공수불부   IOPEN_QT / IRCV_QT / IISU_QT, WH_CD(공정), LC_CD(작업장)
     LWIPIO       재공처리     WIP_NB : WI 재공입고 / WM 재공이동 / WA 재공조정
                               MAP_FG : 1~3 실적별, 4~6 지시별(투입자재), 7~9 예외
     LX_WH_W      공정별 현재공 집계   ★ 있으면 우선 사용 (iCUBE 표준 제공 집계)
     LX_LC_W      작업장별 현재공 집계
     LX_PJT_W     프로젝트별 현재공 집계
     LINVINSP_WIP 재공 실사

  ----------------------------------------------------------------------------------------------
  [ 산식 ]
  ----------------------------------------------------------------------------------------------
     현재공   = SUM(IOPEN_QT) + SUM(IRCV_QT) - SUM(IISU_QT)     -- 공정/작업장/품목별
     체류일수 = DATEDIFF(DAY, MIN(최초 재공입고일), 기준일)
     재공금액 = 현재공 × 단가 (LINV_TAV.ISU_UM 우선, 없으면 SITEM 표준단가)
     병목지수 = 공정별 현재공 / 공정별 일평균 처리량(출고)
                → 1.0 = 하루치 재공, 5.0 = 닷새치가 쌓여 있음

  ----------------------------------------------------------------------------------------------
  [ 반드시 지킨 것 ]
  ----------------------------------------------------------------------------------------------
   1. **재공은 창고재고(`LINVTORY`)와 별도 테이블이다.** 통합 재고를 볼 때는
      `BASELOC_FG`(0.창고 / 1.공정)로 구분해야 중복되지 않는다. → P-03 쿼리 F 참조.
   2. **`LX_WH_W` / `LX_LC_W` 가 있으면 그걸 쓴다.** iCUBE 표준 집계이므로 재계산보다 빠르고
      정합성도 보장된다. 본 쿼리는 `OBJECT_ID` 가드로 존재 시 쿼리 G 에서 대사한다.
   3. **`LINV_TAV` 조인키에 `GISU`(기수)를 반드시 포함**한다. 빼면 다른 기수의 단가가 섞인다.
   4. 체류일수가 긴 재공 = 사장재공. **금액 기준 상위만 봐도 개선 효과가 크다** → 쿼리 C.
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@BASE_DT  NVARCHAR(8)  = N'20260915'     -- 기준일
    ,@AS_OF_YN NCHAR(1)     = N'0'            -- 0 현재 / 1 특정일 기준 (IO_DT <= @BASE_DT)
    ,@ITEM_CD  NVARCHAR(25) = NULL
    ,@WH_CD    NVARCHAR(10) = NULL            -- 특정 공정
    ,@LC_CD    NVARCHAR(10) = NULL            -- 특정 작업장
    ,@PJT_CD   NVARCHAR(10) = NULL
    ,@GISU     INT          = NULL            -- 기수 (LINV_TAV 단가 조회용. NULL=자동)
    ,@THR_DAY  INT          = 30              -- 장기체류 판정 기준일
    ,@AVG_MM   INT          = 3               -- 일평균 처리량 산정 개월수
    ,@EXC_ZERO NCHAR(1)     = N'1'            -- 재공 0 행 제외
;

DECLARE @P_YR NVARCHAR(4) = LEFT(@BASE_DT, 4);
DECLARE @AVG_FR NVARCHAR(8) =
        CONVERT(NVARCHAR(8), DATEADD(MONTH, -@AVG_MM, CONVERT(DATE, @BASE_DT)), 112);
DECLARE @AVG_DAYS INT = DATEDIFF(DAY, CONVERT(DATE, @AVG_FR), CONVERT(DATE, @BASE_DT));
DECLARE @SQL NVARCHAR(MAX);

IF OBJECT_ID('tempdb..#WIP') IS NOT NULL DROP TABLE #WIP;
IF OBJECT_ID('tempdb..#UM')  IS NOT NULL DROP TABLE #UM;
IF OBJECT_ID('tempdb..#FLW') IS NOT NULL DROP TABLE #FLW;


/*==============================================================================================
  1. #WIP : 공정 × 작업장 × 품목 × 지시별 재공
==============================================================================================*/
SELECT
     WH_CD   = ISNULL(V.WH_CD, N'')
    ,LC_CD   = ISNULL(V.LC_CD, N'')
    ,V.ITEM_CD
    ,WO_CD   = ISNULL(V.WO_CD , N'')
    ,PJT_CD  = ISNULL(V.PJT_CD, N'')
    ,OPEN_QT = SUM(CAST(ISNULL(V.IOPEN_QT,0) AS DECIMAL(19,6)))
    ,RCV_QT  = SUM(CAST(ISNULL(V.IRCV_QT ,0) AS DECIMAL(19,6)))
    ,ISU_QT  = SUM(CAST(ISNULL(V.IISU_QT ,0) AS DECIMAL(19,6)))
    ,WIP_QT  = SUM(CAST(ISNULL(V.IOPEN_QT,0)+ISNULL(V.IRCV_QT,0)-ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)))
    ,IO_CNT  = COUNT(*)
    ,FIRST_DT= MIN(CASE WHEN V.IO_FG IN (N'0', N'1') THEN V.IO_DT END)
    ,LAST_DT = MAX(V.IO_DT)
INTO #WIP
FROM   LINV_WIP V WITH (NOLOCK)
WHERE  V.CO_CD = @CO_CD AND V.P_YR = @P_YR
  AND  ISNULL(V.USE_YN   , N'1') = N'1'
  AND  ISNULL(V.EXPIRE_YN, N'1') = N'1'
  AND  (@AS_OF_YN = N'0' OR V.IO_DT <= @BASE_DT)
  AND  (@DIV_CD  IS NULL OR V.DIV_CD  = @DIV_CD)
  AND  (@ITEM_CD IS NULL OR V.ITEM_CD = @ITEM_CD)
  AND  (@WH_CD   IS NULL OR V.WH_CD   = @WH_CD)
  AND  (@LC_CD   IS NULL OR V.LC_CD   = @LC_CD)
  AND  (@PJT_CD  IS NULL OR V.PJT_CD  = @PJT_CD)
GROUP BY V.WH_CD, V.LC_CD, V.ITEM_CD, V.WO_CD, V.PJT_CD;
CREATE CLUSTERED INDEX IX_WIP ON #WIP (ITEM_CD, WH_CD, LC_CD);

PRINT N'[1] 재공 행 : ' + CAST(@@ROWCOUNT AS NVARCHAR(20));


/*==============================================================================================
  2. #UM : 품목 단가  (LINV_TAV 우선 — ★ GISU 포함 조인. 없으면 SITEM 표준단가)
==============================================================================================*/
CREATE TABLE #UM (ITEM_CD NVARCHAR(25), UM DECIMAL(19,6), UM_SRC NVARCHAR(20));

IF OBJECT_ID(N'dbo.LINV_TAV', N'U') IS NOT NULL
BEGIN
    -- 기수 자동 결정 : 해당 연도 데이터가 있는 최대 기수
    IF @GISU IS NULL
        SELECT @GISU = MAX(GISU) FROM LINV_TAV WITH (NOLOCK)
        WHERE CO_CD = @CO_CD AND (@DIV_CD IS NULL OR DIV_CD = @DIV_CD);

    SET @SQL = N'
        INSERT INTO #UM (ITEM_CD, UM, UM_SRC)
        SELECT T.ITEM_CD
              ,CAST(AVG(CAST(NULLIF(T.ISU_UM,0) AS DECIMAL(19,6))) AS DECIMAL(19,6))
              ,N''LINV_TAV''
        FROM   dbo.LINV_TAV T WITH (NOLOCK)
        WHERE  T.CO_CD = @p_CO
          AND  T.GISU  = @p_GISU
          AND  (@p_DIV IS NULL OR T.DIV_CD = @p_DIV)
          AND  ISNULL(T.ISU_UM, 0) <> 0
        GROUP BY T.ITEM_CD';
    EXEC sp_executesql @SQL
        ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_GISU INT'
        ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_GISU=@GISU;
    PRINT N'[2] 단가 : LINV_TAV (GISU=' + ISNULL(CAST(@GISU AS NVARCHAR(10)),N'?') + N') '
          + CAST((SELECT COUNT(*) FROM #UM) AS NVARCHAR(20)) + N' 품목';
END

-- 보완 : LINV_TAV 에 없는 품목은 SITEM 표준단가로
INSERT INTO #UM (ITEM_CD, UM, UM_SRC)
SELECT I.ITEM_CD, CAST(ISNULL(NULLIF(I.STD_UM,0), I.PUR_UM) AS DECIMAL(19,6)), N'SITEM(대체)'
FROM   SITEM I WITH (NOLOCK)
WHERE  I.CO_CD = @CO_CD
  AND  NOT EXISTS (SELECT 1 FROM #UM U WHERE U.ITEM_CD = I.ITEM_CD)
  AND  ISNULL(NULLIF(I.STD_UM,0), I.PUR_UM) IS NOT NULL;

CREATE CLUSTERED INDEX IX_UM ON #UM (ITEM_CD);


/*==============================================================================================
  3. #FLW : 공정별 일평균 처리량 (병목지수 분모)
     ─ 최근 @AVG_MM 개월 재공 출고량 / 일수
==============================================================================================*/
SELECT
     WH_CD = ISNULL(V.WH_CD, N'')
    ,OUT_QT = SUM(CAST(ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)))
    ,DAY_QT = CAST(SUM(CAST(ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)))
                   / NULLIF(@AVG_DAYS, 0) AS DECIMAL(19,6))
INTO #FLW
FROM   LINV_WIP V WITH (NOLOCK)
WHERE  V.CO_CD = @CO_CD
  AND  V.IO_DT BETWEEN @AVG_FR AND @BASE_DT
  AND  V.IO_FG = N'2'
  AND  ISNULL(V.USE_YN, N'1') = N'1' AND ISNULL(V.EXPIRE_YN, N'1') = N'1'
  AND  (@DIV_CD IS NULL OR V.DIV_CD = @DIV_CD)
GROUP BY V.WH_CD;
CREATE CLUSTERED INDEX IX_FLW ON #FLW (WH_CD);


/*==============================================================================================
  ** 쿼리 A : 공정 × 작업장 × 품목 재공  (메인)
==============================================================================================*/
SELECT
     N'[A] 공정별 재공 현황'                        AS REPORT_NM
    ,CASE @AS_OF_YN WHEN N'1' THEN @BASE_DT ELSE N'현재' END AS 기준
    ,W.WH_CD                                        AS 공정코드
    ,H.WH_NM                                        AS 공정명
    ,W.LC_CD                                        AS 작업장코드
    ,L.LC_NM                                        AS 작업장명
    ,W.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
    ,W.WO_CD                                        AS 지시번호
    ,W.PJT_CD                                       AS 프로젝트
    ,W.OPEN_QT                                      AS 기초재공
    ,W.RCV_QT                                       AS 재공입고
    ,W.ISU_QT                                       AS 재공출고
    ,W.WIP_QT                                       AS 현재공
    ,U.UM                                           AS 단가
    ,U.UM_SRC                                       AS 단가출처
    ,재공금액 = CAST(W.WIP_QT * ISNULL(U.UM, 0) AS DECIMAL(19,4))
    ,W.FIRST_DT                                     AS 최초재공입고일
    ,W.LAST_DT                                      AS 최종수불일
    ,체류일수 = CASE WHEN W.FIRST_DT IS NOT NULL
                     THEN DATEDIFF(DAY, CONVERT(DATE,W.FIRST_DT), CONVERT(DATE,@BASE_DT)) END
    ,무이동일수 = CASE WHEN W.LAST_DT IS NOT NULL
                       THEN DATEDIFF(DAY, CONVERT(DATE,W.LAST_DT), CONVERT(DATE,@BASE_DT)) END
    ,재공상태 = CASE
         WHEN W.WIP_QT < 0                                                        THEN N'1.★마이너스 재공'
         WHEN W.WIP_QT = 0                                                        THEN N'9.소진'
         WHEN W.FIRST_DT IS NOT NULL
          AND DATEDIFF(DAY,CONVERT(DATE,W.FIRST_DT),CONVERT(DATE,@BASE_DT)) > @THR_DAY * 6
                                                                                  THEN N'2.★사장재공 (6배 초과)'
         WHEN W.FIRST_DT IS NOT NULL
          AND DATEDIFF(DAY,CONVERT(DATE,W.FIRST_DT),CONVERT(DATE,@BASE_DT)) > @THR_DAY
                                                                                  THEN N'3.장기체류'
         ELSE N'0.정상' END
FROM       #WIP  W
LEFT  JOIN #UM   U ON U.ITEM_CD = W.ITEM_CD
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = W.ITEM_CD
LEFT  JOIN SWH   H WITH (NOLOCK) ON H.CO_CD = @CO_CD AND H.WH_CD   = W.WH_CD
LEFT  JOIN SLC   L WITH (NOLOCK) ON L.CO_CD = @CO_CD AND L.WH_CD   = W.WH_CD AND L.LC_CD = W.LC_CD
WHERE  @EXC_ZERO = N'0' OR W.WIP_QT <> 0
ORDER BY 재공상태, 재공금액 DESC
;


/*==============================================================================================
  ** 쿼리 B : 공정별 요약 + 병목지수  ★ 생산 병목의 직접 지표
     ─ 병목지수 = 현재공 / 일평균 처리량. 값이 클수록 그 공정 앞에 물량이 쌓여 있다.
==============================================================================================*/
SELECT
     N'[B] 공정별 병목 분석'                        AS REPORT_NM
    ,W.WH_CD                                        AS 공정코드
    ,H.WH_NM                                        AS 공정명
    ,COUNT(DISTINCT W.ITEM_CD)                      AS 재공품목수
    ,COUNT(DISTINCT NULLIF(W.WO_CD, N''))           AS 재공지시수
    ,COUNT(DISTINCT W.LC_CD)                        AS 작업장수
    ,SUM(W.WIP_QT)                                  AS 현재공계
    ,재공금액계 = CAST(SUM(W.WIP_QT * ISNULL(U.UM,0)) AS DECIMAL(19,4))
    ,ISNULL(F.DAY_QT, 0)                            AS 일평균처리량
    ,병목지수 = CAST(CASE WHEN ISNULL(F.DAY_QT,0) <> 0
                          THEN SUM(W.WIP_QT) / F.DAY_QT END AS DECIMAL(19,2))
    ,평균체류일 = CAST(AVG(CASE WHEN W.FIRST_DT IS NOT NULL AND W.WIP_QT > 0
                                THEN CAST(DATEDIFF(DAY,CONVERT(DATE,W.FIRST_DT),CONVERT(DATE,@BASE_DT)) AS DECIMAL(9,2))
                                END) AS DECIMAL(9,1))
    ,최장체류일 = MAX(CASE WHEN W.WIP_QT > 0
                           THEN DATEDIFF(DAY,CONVERT(DATE,W.FIRST_DT),CONVERT(DATE,@BASE_DT)) END)
    ,장기체류금액 = CAST(SUM(CASE WHEN W.FIRST_DT IS NOT NULL
                                   AND DATEDIFF(DAY,CONVERT(DATE,W.FIRST_DT),CONVERT(DATE,@BASE_DT)) > @THR_DAY
                                  THEN W.WIP_QT * ISNULL(U.UM,0) ELSE 0 END) AS DECIMAL(19,4))
    ,마이너스행수 = SUM(CASE WHEN W.WIP_QT < 0 THEN 1 ELSE 0 END)
    ,판정 = CASE
         WHEN ISNULL(F.DAY_QT,0) = 0                                    THEN N'9.처리이력 없음'
         WHEN SUM(W.WIP_QT) / NULLIF(F.DAY_QT,0) > 10                   THEN N'1.★심각 병목 (10일치 초과)'
         WHEN SUM(W.WIP_QT) / NULLIF(F.DAY_QT,0) > 5                    THEN N'2.병목 (5일치 초과)'
         WHEN SUM(W.WIP_QT) / NULLIF(F.DAY_QT,0) > 2                    THEN N'3.주의 (2일치 초과)'
         ELSE N'0.정상' END
FROM       #WIP  W
LEFT  JOIN #UM   U ON U.ITEM_CD = W.ITEM_CD
LEFT  JOIN #FLW  F ON F.WH_CD   = W.WH_CD
LEFT  JOIN SWH   H WITH (NOLOCK) ON H.CO_CD = @CO_CD AND H.WH_CD = W.WH_CD
GROUP BY W.WH_CD, H.WH_NM, F.DAY_QT
ORDER BY 판정, 병목지수 DESC
;


/*==============================================================================================
  ** 쿼리 C : 장기 체류 재공 (금액 기준)  ★ 개선 효과가 가장 큰 목록
==============================================================================================*/
SELECT TOP 100
     N'[C] 장기체류 재공'                           AS REPORT_NM
    ,체류등급 = CASE
         WHEN DATEDIFF(DAY,CONVERT(DATE,W.FIRST_DT),CONVERT(DATE,@BASE_DT)) > 365          THEN N'1.★1년 초과'
         WHEN DATEDIFF(DAY,CONVERT(DATE,W.FIRST_DT),CONVERT(DATE,@BASE_DT)) > 180          THEN N'2.180일 초과'
         WHEN DATEDIFF(DAY,CONVERT(DATE,W.FIRST_DT),CONVERT(DATE,@BASE_DT)) > 90           THEN N'3.90일 초과'
         ELSE N'4.' + CAST(@THR_DAY AS NVARCHAR(5)) + N'일 초과' END
    ,W.WH_CD                                        AS 공정코드
    ,H.WH_NM                                        AS 공정명
    ,W.LC_CD                                        AS 작업장코드
    ,W.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,W.WO_CD                                        AS 지시번호
    ,지시상태 = CASE ISNULL(O.EXPIRE_YN, N'') WHEN N'1' THEN N'생산진행'
                                              WHEN N'0' THEN N'생산마감'
                                              ELSE N'지시 없음' END
    ,O.ORD_DT                                       AS 지시일
    ,O.COMP_DT                                      AS 완료예정일
    ,W.WIP_QT                                       AS 현재공
    ,U.UM                                           AS 단가
    ,재공금액 = CAST(W.WIP_QT * ISNULL(U.UM,0) AS DECIMAL(19,4))
    ,W.FIRST_DT                                     AS 최초재공입고일
    ,W.LAST_DT                                      AS 최종수불일
    ,체류일수   = DATEDIFF(DAY, CONVERT(DATE,W.FIRST_DT), CONVERT(DATE,@BASE_DT))
    ,무이동일수 = DATEDIFF(DAY, CONVERT(DATE,W.LAST_DT) , CONVERT(DATE,@BASE_DT))
    ,W.PJT_CD                                       AS 프로젝트
    ,조치 = CASE
         WHEN ISNULL(O.EXPIRE_YN, N'') = N'0'
              THEN N'★ 지시는 마감인데 재공이 남음 - 재공 정리(LWIPIO 조정) 필요'
         WHEN O.WO_CD IS NULL
              THEN N'★ 연결 지시 없음 - 재공 출처 확인 필요'
         WHEN DATEDIFF(DAY,CONVERT(DATE,W.LAST_DT),CONVERT(DATE,@BASE_DT)) > 90
              THEN N'90일 무이동 - 실물 확인 후 폐기/재투입 판단'
         ELSE N'생산 재개 또는 사유 확인' END
FROM       #WIP  W
LEFT  JOIN #UM   U ON U.ITEM_CD = W.ITEM_CD
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = W.ITEM_CD
LEFT  JOIN SWH   H WITH (NOLOCK) ON H.CO_CD = @CO_CD AND H.WH_CD   = W.WH_CD
LEFT  JOIN LWO_WF O WITH (NOLOCK) ON O.CO_CD = @CO_CD AND O.WO_CD  = NULLIF(W.WO_CD, N'')
WHERE  W.WIP_QT > 0
  AND  W.FIRST_DT IS NOT NULL
  AND  DATEDIFF(DAY, CONVERT(DATE,W.FIRST_DT), CONVERT(DATE,@BASE_DT)) > @THR_DAY
ORDER BY 재공금액 DESC
;


/*==============================================================================================
  ** 쿼리 D : 지시별 재공  ─ 어느 작업지시가 재공을 물고 있는가
==============================================================================================*/
SELECT
     N'[D] 지시별 재공'                             AS REPORT_NM
    ,W.WO_CD                                        AS 지시번호
    ,O.ORD_DT                                       AS 지시일
    ,O.COMP_DT                                      AS 완료예정일
    ,지시상태 = CASE ISNULL(O.EXPIRE_YN, N'') WHEN N'1' THEN N'생산진행'
                                              WHEN N'0' THEN N'생산마감'
                                              ELSE N'지시 없음' END
    ,O.ITEM_CD                                      AS 지시품번
    ,P.ITEM_NM                                      AS 지시품명
    ,O.ITEM_QT                                      AS 지시수량
    ,COUNT(DISTINCT W.ITEM_CD)                      AS 재공품목수
    ,COUNT(DISTINCT W.WH_CD)                        AS 재공공정수
    ,SUM(W.WIP_QT)                                  AS 재공수량계
    ,재공금액계 = CAST(SUM(W.WIP_QT * ISNULL(U.UM,0)) AS DECIMAL(19,4))
    ,MIN(W.FIRST_DT)                                AS 최초재공일
    ,MAX(W.LAST_DT)                                 AS 최종수불일
    ,최장체류일 = MAX(DATEDIFF(DAY, CONVERT(DATE,W.FIRST_DT), CONVERT(DATE,@BASE_DT)))
    ,O.PJT_CD                                       AS 프로젝트
    ,판정 = CASE
         WHEN O.WO_CD IS NULL                       THEN N'1.★지시 미연결 재공'
         WHEN ISNULL(O.EXPIRE_YN,N'') = N'0'        THEN N'2.★마감 지시에 재공 잔존'
         WHEN O.COMP_DT IS NOT NULL
          AND DATEDIFF(DAY,CONVERT(DATE,O.COMP_DT),CONVERT(DATE,@BASE_DT)) > 0
                                                    THEN N'3.납기경과 지시의 재공'
         ELSE N'0.정상 (진행 중)' END
FROM       #WIP  W
LEFT  JOIN #UM   U ON U.ITEM_CD = W.ITEM_CD
LEFT  JOIN LWO_WF O WITH (NOLOCK) ON O.CO_CD = @CO_CD AND O.WO_CD = NULLIF(W.WO_CD, N'')
LEFT  JOIN SITEM  P WITH (NOLOCK) ON P.CO_CD = @CO_CD AND P.ITEM_CD = O.ITEM_CD
WHERE  W.WIP_QT <> 0
GROUP BY W.WO_CD, O.WO_CD, O.ORD_DT, O.COMP_DT, O.EXPIRE_YN, O.ITEM_CD, P.ITEM_NM, O.ITEM_QT, O.PJT_CD
ORDER BY 판정, 재공금액계 DESC
;


/*==============================================================================================
  ** 쿼리 E : 재공처리 유형 분석 (LWIPIO)
     ─ WIP_NB 접두 : WI 재공입고 / WM 재공이동 / WA 재공조정
       MAP_FG      : 1~3 실적별 / 4~6 지시별(투입자재) / 7~9 예외
       ★ 조정(WA)·예외(7~9)가 많으면 재공 데이터 신뢰도가 낮다는 신호다.
==============================================================================================*/
IF OBJECT_ID(N'dbo.LWIPIO', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
    SELECT
         N''[E] 재공처리 유형'' AS REPORT_NM
        ,처리구분 = CASE LEFT(X.WIP_NB, 2) WHEN N''WI'' THEN N''1.재공입고''
                                           WHEN N''WM'' THEN N''2.재공이동''
                                           WHEN N''WA'' THEN N''3.★재공조정''
                                           ELSE N''9.'' + LEFT(X.WIP_NB, 2) END
        ,매핑구분 = CASE WHEN X.MAP_FG BETWEEN N''1'' AND N''3'' THEN N''1.실적별''
                         WHEN X.MAP_FG BETWEEN N''4'' AND N''6'' THEN N''2.지시별(투입자재)''
                         WHEN X.MAP_FG BETWEEN N''7'' AND N''9'' THEN N''3.★예외''
                         ELSE N''9.'' + ISNULL(X.MAP_FG, N''?'') END
        ,X.MAP_FG                    AS 매핑코드
        ,COUNT(*)                    AS 처리건수
        ,COUNT(DISTINCT X.ITEM_CD)   AS 품목수
        ,COUNT(DISTINCT NULLIF(X.WO_CD, N'''')) AS 지시수
        ,MIN(X.WIP_DT)               AS 최초처리일
        ,MAX(X.WIP_DT)               AS 최종처리일
        ,구성비_PCT = CAST(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0) AS DECIMAL(5,1))
    FROM   dbo.LWIPIO X WITH (NOLOCK)
    WHERE  X.CO_CD = @p_CO
      AND  X.WIP_DT <= @p_DT
      AND  ISNULL(X.USE_YN, N''1'') = N''1''
      AND  (@p_DIV IS NULL OR X.DIV_CD = @p_DIV)
    GROUP BY LEFT(X.WIP_NB, 2), X.MAP_FG
    ORDER BY 처리구분, 매핑구분';
    EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_DT NVARCHAR(8)'
        ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_DT=@BASE_DT;
END
ELSE
    SELECT N'[E] 재공처리 유형' AS REPORT_NM, N'LWIPIO 테이블 없음 - 건너뜀' AS 결과;


/*==============================================================================================
  ** 쿼리 F : LX_* 표준 집계 대사  ★ 있으면 본 쿼리 결과와 일치해야 한다
     ─ LX_WH_W(공정별) / LX_LC_W(작업장별) 는 iCUBE 표준 제공 집계다.
       차이가 나면 집계 배치 시점 또는 필터 조건이 다른 것이므로 원인을 먼저 잡아야 한다.
==============================================================================================*/
IF OBJECT_ID(N'dbo.LX_WH_W', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
    SELECT
         N''[F] LX_WH_W 대사'' AS REPORT_NM
        ,공정코드 = ISNULL(X.WH_CD, W.WH_CD)
        ,LX집계   = SUM(ISNULL(X.QT, 0))
        ,본쿼리   = SUM(ISNULL(W.QT, 0))
        ,차이     = SUM(ISNULL(X.QT,0)) - SUM(ISNULL(W.QT,0))
        ,판정 = CASE WHEN ABS(SUM(ISNULL(X.QT,0)) - SUM(ISNULL(W.QT,0))) < 0.001 THEN N''0.일치''
                     WHEN X.WH_CD IS NULL THEN N''1.★본쿼리에만 존재''
                     WHEN W.WH_CD IS NULL THEN N''2.★LX에만 존재''
                     ELSE N''3.★수량 불일치 - 집계 시점/필터 확인'' END
    FROM      ( SELECT WH_CD, QT = SUM(CAST(ISNULL(WIP_QT,0) AS DECIMAL(19,6)))
                FROM dbo.LX_WH_W WITH (NOLOCK)
                WHERE CO_CD = @p_CO AND (@p_DIV IS NULL OR DIV_CD = @p_DIV)
                GROUP BY WH_CD ) X
    FULL JOIN ( SELECT WH_CD, QT = SUM(WIP_QT) FROM #WIP GROUP BY WH_CD ) W
           ON W.WH_CD = X.WH_CD
    GROUP BY X.WH_CD, W.WH_CD
    ORDER BY 판정, 공정코드';
    EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4)'
        ,@p_CO=@CO_CD, @p_DIV=@DIV_CD;
END
ELSE
    SELECT N'[F] LX_WH_W 대사' AS REPORT_NM
          ,N'LX_WH_W 없음 - LINV_WIP 직접 집계 사용 중 (정상)' AS 결과;


/*==============================================================================================
  ** 쿼리 G : 재공 실사 대비  (LINVINSP_WIP)  ─ 데이터 신뢰도 점검
==============================================================================================*/
IF OBJECT_ID(N'dbo.LINVINSP_WIP', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
    SELECT
         N''[G] 재공 실사 대비'' AS REPORT_NM
        ,S.WH_CD                 AS 공정코드
        ,S.ITEM_CD               AS 품번
        ,I.ITEM_NM               AS 품명
        ,실사수량 = SUM(CAST(ISNULL(S.INSP_QT, 0) AS DECIMAL(19,6)))
        ,장부수량 = MAX(ISNULL(W.QT, 0))
        ,차이     = SUM(CAST(ISNULL(S.INSP_QT,0) AS DECIMAL(19,6))) - MAX(ISNULL(W.QT, 0))
        ,차이율_PCT = CAST(CASE WHEN MAX(ISNULL(W.QT,0)) <> 0
                                THEN (SUM(CAST(ISNULL(S.INSP_QT,0) AS DECIMAL(19,6))) - MAX(ISNULL(W.QT,0)))
                                     / MAX(ISNULL(W.QT,0)) * 100 END AS DECIMAL(19,2))
        ,MAX(S.INSP_DT)          AS 실사일
        ,판정 = CASE WHEN ABS(SUM(CAST(ISNULL(S.INSP_QT,0) AS DECIMAL(19,6))) - MAX(ISNULL(W.QT,0))) < 0.001
                     THEN N''0.일치''
                     WHEN SUM(CAST(ISNULL(S.INSP_QT,0) AS DECIMAL(19,6))) > MAX(ISNULL(W.QT,0))
                     THEN N''1.★실사 과다 (미등록 재공 입고)''
                     ELSE N''2.★장부 과다 (실물 없음 - 출고 누락)'' END
    FROM       dbo.LINVINSP_WIP S WITH (NOLOCK)
    LEFT  JOIN ( SELECT WH_CD, ITEM_CD, QT = SUM(WIP_QT) FROM #WIP GROUP BY WH_CD, ITEM_CD ) W
           ON W.WH_CD = S.WH_CD AND W.ITEM_CD = S.ITEM_CD
    LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = S.CO_CD AND I.ITEM_CD = S.ITEM_CD
    WHERE  S.CO_CD = @p_CO
      AND  ISNULL(S.USE_YN, N''1'') = N''1''
      AND  (@p_DIV IS NULL OR S.DIV_CD = @p_DIV)
    GROUP BY S.WH_CD, S.ITEM_CD, I.ITEM_NM
    HAVING ABS(SUM(CAST(ISNULL(S.INSP_QT,0) AS DECIMAL(19,6))) - MAX(ISNULL(W.QT,0))) >= 0.001
    ORDER BY ABS(SUM(CAST(ISNULL(S.INSP_QT,0) AS DECIMAL(19,6))) - MAX(ISNULL(W.QT,0))) DESC';
    EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4)'
        ,@p_CO=@CO_CD, @p_DIV=@DIV_CD;
END
ELSE
    SELECT N'[G] 재공 실사 대비' AS REPORT_NM, N'LINVINSP_WIP 테이블 없음 - 건너뜀' AS 결과;


/*==============================================================================================
  ** 쿼리 H : 전체 요약 (경영 보고 1행)
==============================================================================================*/
SELECT
     N'[H] 재공 요약'                               AS REPORT_NM
    ,CASE @AS_OF_YN WHEN N'1' THEN @BASE_DT ELSE N'현재' END AS 기준
    ,COUNT(DISTINCT W.WH_CD)                        AS 공정수
    ,COUNT(DISTINCT W.LC_CD)                        AS 작업장수
    ,COUNT(DISTINCT W.ITEM_CD)                      AS 재공품목수
    ,COUNT(DISTINCT NULLIF(W.WO_CD, N''))           AS 재공지시수
    ,SUM(W.WIP_QT)                                  AS 총재공수량
    ,총재공금액 = CAST(SUM(W.WIP_QT * ISNULL(U.UM,0)) AS DECIMAL(19,4))
    ,장기체류금액 = CAST(SUM(CASE WHEN W.FIRST_DT IS NOT NULL
                                   AND DATEDIFF(DAY,CONVERT(DATE,W.FIRST_DT),CONVERT(DATE,@BASE_DT)) > @THR_DAY
                                  THEN W.WIP_QT * ISNULL(U.UM,0) ELSE 0 END) AS DECIMAL(19,4))
    ,장기체류비율_PCT = CAST(CASE WHEN SUM(W.WIP_QT * ISNULL(U.UM,0)) <> 0
                                  THEN SUM(CASE WHEN W.FIRST_DT IS NOT NULL
                                                 AND DATEDIFF(DAY,CONVERT(DATE,W.FIRST_DT),CONVERT(DATE,@BASE_DT)) > @THR_DAY
                                                THEN W.WIP_QT * ISNULL(U.UM,0) ELSE 0 END)
                                       / SUM(W.WIP_QT * ISNULL(U.UM,0)) * 100 END AS DECIMAL(19,2))
    ,평균체류일 = CAST(AVG(CASE WHEN W.WIP_QT > 0 AND W.FIRST_DT IS NOT NULL
                                THEN CAST(DATEDIFF(DAY,CONVERT(DATE,W.FIRST_DT),CONVERT(DATE,@BASE_DT)) AS DECIMAL(9,2))
                                END) AS DECIMAL(9,1))
    ,마이너스행수 = SUM(CASE WHEN W.WIP_QT < 0 THEN 1 ELSE 0 END)
    ,지시미연결행수 = SUM(CASE WHEN ISNULL(W.WO_CD, N'') = N'' AND W.WIP_QT <> 0 THEN 1 ELSE 0 END)
    ,판정 = CASE
         WHEN SUM(CASE WHEN W.WIP_QT < 0 THEN 1 ELSE 0 END) > 0
              THEN N'1.★마이너스 재공 존재 - 데이터 점검 필요'
         WHEN SUM(W.WIP_QT * ISNULL(U.UM,0)) <> 0
          AND SUM(CASE WHEN W.FIRST_DT IS NOT NULL
                        AND DATEDIFF(DAY,CONVERT(DATE,W.FIRST_DT),CONVERT(DATE,@BASE_DT)) > @THR_DAY
                       THEN W.WIP_QT * ISNULL(U.UM,0) ELSE 0 END)
              / SUM(W.WIP_QT * ISNULL(U.UM,0)) > 0.3
              THEN N'2.★장기체류 재공 30% 초과 - 사장재공 정리 필요'
         ELSE N'0.정상' END
FROM       #WIP W
LEFT  JOIN #UM  U ON U.ITEM_CD = W.ITEM_CD
;


DROP TABLE #WIP, #UM, #FLW;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 재공 관련 테이블 실존  ★ LX_* 가 있으면 그쪽이 표준
     SELECT name FROM sys.objects
     WHERE name IN ('LINV_WIP','VL_LINV_WIP_ALL','LWIPIO','LINVINSP_WIP',
                    'LX_WH_W','LX_LC_W','LX_PJT_W','LINV_TAV');

  -- (2) 재공 사용 여부  ★ 재공을 안 쓰는 사이트면 이 리포트 전체가 무의미하다
     SELECT COUNT(*) 수불건수, COUNT(DISTINCT ITEM_CD) 품목수
     FROM   LINV_WIP WHERE CO_CD='1000' AND P_YR='2026';
     --> 0 이면 공정 재고를 창고(LINVTORY)로만 관리하는 사이트다. P-03 을 쓸 것.

  -- (3) WH_CD 가 공정인지 창고인지  ★ 사이트마다 운용이 다르다
     SELECT TOP 20 W.WH_CD, H.WH_NM, COUNT(*) 건수
     FROM   LINV_WIP W LEFT JOIN SWH H ON H.CO_CD=W.CO_CD AND H.WH_CD=W.WH_CD
     WHERE  W.CO_CD='1000' GROUP BY W.WH_CD, H.WH_NM ORDER BY 건수 DESC;
     --> 창고명이 공정명이면 정상. 일반 창고명이 나오면 공정 구분이 LC_CD 에 있을 수 있다.

  -- (4) 지시 연결률  ★ WO_CD 가 비면 쿼리 D 가 무의미
     SELECT COUNT(*) 전체, SUM(CASE WHEN ISNULL(WO_CD,'')='' THEN 1 ELSE 0 END) 지시없음
     FROM   LINV_WIP WHERE CO_CD='1000' AND P_YR='2026';

  -- (5) LINV_TAV 기수(GISU) 확인  ★ 단가 조인의 핵심 키
     SELECT GISU, COUNT(*), MIN(SMM), MAX(FMM) FROM LINV_TAV
     WHERE CO_CD='1000' GROUP BY GISU ORDER BY GISU DESC;
     --> @GISU 파라미터를 여기서 나온 값으로 고정하는 편이 안전하다.

  -- (6) 재공조정(WA) 비중  ★ 높으면 재공 데이터 신뢰도가 낮다
     SELECT LEFT(WIP_NB,2) 구분, COUNT(*) FROM LWIPIO WHERE CO_CD='1000' GROUP BY LEFT(WIP_NB,2);

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **재공금액은 근사치다.** 재공은 원재료비만이 아니라 진행된 공정까지의 가공비를 포함해야
     정확하지만, 본 쿼리는 품목 단가(`LINV_TAV.ISU_UM`)만 곱한다. 정식 재공 평가액은
     원가계산 SP(`USP_COT0010_CALC_COST_TAV`) 결과를 봐야 한다. 여기서는 **상대 비교와
     우선순위 판단용**으로만 쓸 것.

  2) **병목지수(쿼리 B)의 분모는 최근 @AVG_MM 개월 평균**이다. 신규 공정이나 계절 변동이 큰
     공정은 왜곡된다. 값이 이상하면 `일평균처리량` 컬럼을 먼저 볼 것.

  3) `체류일수`는 해당 공정/품목/지시 조합의 **최초 재공입고일** 기준이다. 같은 조합에 새 물량이
     계속 들어오면 실제보다 길게 나온다. LOT 단위 추적이 필요하면 `LOT_NB` 를 그룹에 추가할 것.

  4) `P_YR` 파티션이므로 **연초 조회 시 전년 재공이 이월되었는지 확인**해야 한다.
     P-03 쿼리 G 와 같은 점검을 재공에도 적용할 것.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   P03_실시간재고_추적.sql        : 창고재고 (쿼리 F 에서 재공과 통합)
   M01_작업지시_진행현황.sql      : 지시 진척 (재공이 쌓인 지시의 진행 상태)
   생산지시별_작업수율현황.sql    : 공정수율 (재공이 쌓이는 원인 분석)
   재고수불_뷰테이블_레퍼런스.md  : LINV_WIP 컬럼 명세
==============================================================================================*/
