/*==============================================================================================
  [ iCUBE ] C-07  원가차수 마감 현황 점검                                            (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : **상시 점검 리포트.** 원가를 마감해도 되는 상태인가를 한 번에 판정한다.
         + 미마감 차수가 어느 리포트에 영향을 주는지 명시한다.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 왜 이 점검이 중요한가 ]
  ----------------------------------------------------------------------------------------------
     **원가 KPI 는 미마감 차수에서 값이 튄다.** 자재가 덜 투입된 상태, 실적입고가 덜 된 상태에서
     원가계산을 돌리면 단위원가가 비정상적으로 높거나 낮게 나온다. 그 숫자가 대시보드에 뜨면
     월초마다 원가가 급변해 신뢰가 무너진다.

     그래서 모든 원가 리포트(C-03/C-04/C-05/E-01)는 상단에 **"기준 차수 / 마감여부"** 를 표시하고
     미마감이면 '집계중' 으로 표기하도록 만들었다. 이 파일은 그 판정의 **원천**이다.

  ----------------------------------------------------------------------------------------------
  [ 마감 전 선행 조건 — 쿼리 B 가 한 번에 점검한다 ]
  ----------------------------------------------------------------------------------------------
     ① 자재 출고 후 미사용   출고했는데 사용보고가 없으면 원가에 안 잡힌다      → M-05
     ② 실적 후 미입고        실적은 났는데 창고 입고가 없으면 제품 재고가 과소  → M-01
     ③ 재공 실사 차이        장부와 실물이 다르면 재공 평가액이 틀린다          → M-09
     ④ 재고평가 차이금액     평가가 완결되지 않은 상태                          → P-09
     ⑤ 마이너스 재고         음수 재고는 평가 단가를 왜곡한다                   → P-03
     ⑥ 매입마감 미처리       입고했는데 마감이 없으면 매입단가가 확정되지 않음  → P-01
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)   = N'1000'
    ,@DIV_CD   NVARCHAR(4)   = N'1000'
    ,@P_YR     NVARCHAR(4)   = N'2026'
    ,@CHASU    INT           = NULL           -- 점검 대상 차수 (NULL = 최신)
    ,@TH_AM    DECIMAL(19,4) = 1.0            -- 평가 차이 임계 (원)
;

DECLARE @SMM NVARCHAR(6), @FMM NVARCHAR(6), @CLS_YN NCHAR(1);
DECLARE @FR_DT NVARCHAR(8), @TO_DT NVARCHAR(8);
DECLARE @SQL NVARCHAR(MAX);

IF OBJECT_ID('tempdb..#CHK') IS NOT NULL DROP TABLE #CHK;

CREATE TABLE #CHK (
     SEQ    INT
    ,ITEM   NVARCHAR(40)
    ,CNT    INT
    ,AMT    DECIMAL(19,4)
    ,LEVEL  NVARCHAR(10)          -- 차단 / 경고 / 정보
    ,RESULT NVARCHAR(20)
    ,DETAIL NVARCHAR(200)
    ,DRILL  NVARCHAR(60)
);


/*==============================================================================================
  1. 차수 확정
==============================================================================================*/
IF OBJECT_ID(N'dbo.CIV_CHASU', N'U') IS NULL
    PRINT N'[1] ★ CIV_CHASU 없음 - 원가모듈 미운영';
ELSE
BEGIN
    IF @CHASU IS NULL
        SELECT TOP 1 @CHASU = CHASU
        FROM   CIV_CHASU WITH (NOLOCK)
        WHERE  CO_CD = @CO_CD AND P_YR = @P_YR
        ORDER BY CHASU DESC;

    SELECT @SMM = SMM, @FMM = FMM, @CLS_YN = ISNULL(CLS_YN, N'0')
    FROM   CIV_CHASU WITH (NOLOCK)
    WHERE  CO_CD = @CO_CD AND P_YR = @P_YR AND CHASU = @CHASU;

    SET @FR_DT = ISNULL(@SMM, @P_YR + N'01') + N'01';
    SET @TO_DT = CONVERT(NVARCHAR(8),
                     EOMONTH(CONVERT(DATE, ISNULL(@FMM, @P_YR + N'12') + N'01')), 112);

    PRINT N'[1] 차수 ' + ISNULL(CAST(@CHASU AS NVARCHAR(10)), N'없음')
        + N' / 기간 ' + ISNULL(@FR_DT, N'?') + N'~' + ISNULL(@TO_DT, N'?')
        + N' / ' + CASE @CLS_YN WHEN N'1' THEN N'마감' ELSE N'미마감' END;
END


/*==============================================================================================
  2. 선행 조건 점검 6종  → #CHK 적재
==============================================================================================*/
IF @CHASU IS NOT NULL
BEGIN

    -- ① 자재 출고 후 미사용 (M-05)
    INSERT INTO #CHK (SEQ, ITEM, CNT, AMT, LEVEL, RESULT, DETAIL, DRILL)
    SELECT 1, N'자재 출고 후 미사용'
          ,COUNT(*)
          ,NULL
          ,N'차단'
          ,CASE WHEN COUNT(*) = 0 THEN N'통과' ELSE N'★ 미처리' END
          ,CASE WHEN COUNT(*) = 0 THEN N'출고 자재가 모두 사용보고 되었다'
                ELSE N'출고했으나 사용보고가 없는 자재 - 원가에 반영되지 않는다' END
          ,N'M05_자재_청구출고사용_현황.sql'
    FROM   LWO_REQ_WF Q WITH (NOLOCK)
    INNER JOIN LWO_WF W WITH (NOLOCK) ON W.CO_CD = Q.CO_CD AND W.WO_CD = Q.WO_CD
    WHERE  Q.CO_CD = @CO_CD
      AND  W.ORD_DT BETWEEN @FR_DT AND @TO_DT
      AND  ISNULL(Q.USE_YN, N'1') = N'1'
      AND  ISNULL(Q.ISU_QT, 0) > ISNULL(Q.USE_QT, 0)
      AND  (@DIV_CD IS NULL OR W.DIV_CD = @DIV_CD);

    -- ② 실적 후 미입고 (M-01)
    INSERT INTO #CHK (SEQ, ITEM, CNT, AMT, LEVEL, RESULT, DETAIL, DRILL)
    SELECT 2, N'생산실적 후 미입고'
          ,COUNT(*)
          ,NULL
          ,N'차단'
          ,CASE WHEN COUNT(*) = 0 THEN N'통과' ELSE N'★ 미처리' END
          ,CASE WHEN COUNT(*) = 0 THEN N'실적이 모두 창고 입고되었다'
                ELSE N'실적은 났으나 입고가 없는 지시 - 제품재고 과소, 재공 과대 계상' END
          ,N'M01_작업지시_진행현황.sql'
    FROM   LWO_WF W WITH (NOLOCK)
    OUTER APPLY (SELECT GOOD = SUM(CASE WHEN ISNULL(R.SUB_TP,N'0')=N'0' AND ISNULL(R.BAD_YN,N'0')=N'0'
                                        THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
                 FROM LORCV_H R WITH (NOLOCK)
                 WHERE R.CO_CD=W.CO_CD AND R.WO_CD=W.WO_CD AND ISNULL(R.USE_YN,N'1')=N'1') G
    OUTER APPLY (SELECT INW = SUM(CAST(ISNULL(N.INWH_QT,0) AS DECIMAL(19,6)))
                 FROM LPRDINWH N WITH (NOLOCK)
                 INNER JOIN LORCV_H R2 WITH (NOLOCK) ON R2.CO_CD=N.CO_CD AND R2.WR_CD=N.WR_CD
                 WHERE N.CO_CD=W.CO_CD AND R2.WO_CD=W.WO_CD AND ISNULL(N.USE_YN,N'1')=N'1') N
    WHERE  W.CO_CD = @CO_CD
      AND  W.ORD_DT BETWEEN @FR_DT AND @TO_DT
      AND  ISNULL(W.USE_YN, N'1') = N'1'
      AND  ISNULL(G.GOOD, 0) > ISNULL(N.INW, 0)
      AND  (@DIV_CD IS NULL OR W.DIV_CD = @DIV_CD);

    -- ③ 재공 실사 차이 (M-09)
    IF OBJECT_ID(N'dbo.LINVINSP_WIP', N'U') IS NOT NULL
        INSERT INTO #CHK (SEQ, ITEM, CNT, AMT, LEVEL, RESULT, DETAIL, DRILL)
        SELECT 3, N'재공 실사 차이', 0, NULL, N'경고', N'확인 필요'
              ,N'LINVINSP_WIP 존재. P09 쿼리 D 로 장부 vs 실사 차이를 직접 확인할 것'
              ,N'P09_재고정합성_점검.sql';
    ELSE
        INSERT INTO #CHK (SEQ, ITEM, CNT, AMT, LEVEL, RESULT, DETAIL, DRILL)
        VALUES (3, N'재공 실사 차이', 0, NULL, N'정보', N'해당 없음'
               ,N'LINVINSP_WIP 없음 - 재공 실사 미운영', N'-');

    -- ④ 재고평가 차이금액 (P-09)
    IF OBJECT_ID(N'dbo.LINV_MVFIFO_WK', N'U') IS NOT NULL
    BEGIN
        SET @SQL = N'
            INSERT INTO #CHK (SEQ, ITEM, CNT, AMT, LEVEL, RESULT, DETAIL, DRILL)
            SELECT 4, N''재고평가 차이금액''
                  ,COUNT(*)
                  ,SUM(CAST(ISNULL(W.OPEN_AM_GAP,0)+ISNULL(W.RCV_AM_GAP,0)+ISNULL(W.RCVT_AM_GAP,0)
                            AS DECIMAL(19,4)))
                  ,N''차단''
                  ,CASE WHEN COUNT(*) = 0 THEN N''통과'' ELSE N''★ 차이 존재'' END
                  ,CASE WHEN COUNT(*) = 0 THEN N''평가가 완결되었다''
                        ELSE N''평가 차이금액이 남아 있다. 재고평가 재실행 필요'' END
                  ,N''P09_재고정합성_점검.sql''
            FROM   dbo.LINV_MVFIFO_WK W WITH (NOLOCK)
            WHERE  W.CO_CD = @p_CO
              AND  (@p_DIV IS NULL OR W.DIV_CD = @p_DIV)
              AND  ABS(ISNULL(W.OPEN_AM_GAP,0)+ISNULL(W.RCV_AM_GAP,0)+ISNULL(W.RCVT_AM_GAP,0)) >= @p_TH';
        BEGIN TRY
            EXEC sp_executesql @SQL
                ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_TH DECIMAL(19,4)'
                ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_TH=@TH_AM;
        END TRY
        BEGIN CATCH
            INSERT INTO #CHK (SEQ, ITEM, CNT, AMT, LEVEL, RESULT, DETAIL, DRILL)
            VALUES (4, N'재고평가 차이금액', 0, NULL, N'경고', N'조회 실패'
                   ,N'LINV_MVFIFO_WK 컬럼 구조 확인 필요', N'P09_재고정합성_점검.sql');
        END CATCH
    END
    ELSE
        INSERT INTO #CHK (SEQ, ITEM, CNT, AMT, LEVEL, RESULT, DETAIL, DRILL)
        VALUES (4, N'재고평가 차이금액', 0, NULL, N'정보', N'해당 없음'
               ,N'LINV_MVFIFO_WK 없음 - 평가 검증 테이블 미운영', N'-');

    -- ⑤ 마이너스 재고 (P-03)
    INSERT INTO #CHK (SEQ, ITEM, CNT, AMT, LEVEL, RESULT, DETAIL, DRILL)
    SELECT 5, N'마이너스 재고'
          ,COUNT(*)
          ,NULL
          ,N'경고'
          ,CASE WHEN COUNT(*) = 0 THEN N'통과' ELSE N'★ 존재' END
          ,CASE WHEN COUNT(*) = 0 THEN N'음수 재고 없음'
                ELSE N'음수 재고가 평가 단가를 왜곡한다. SYSCFG 모듈S/코드13 확인' END
          ,N'P03_실시간재고_추적.sql'
    FROM ( SELECT V.ITEM_CD
           FROM   LINVTORY V WITH (NOLOCK)
           WHERE  V.CO_CD = @CO_CD AND V.P_YR = @P_YR
             AND  ISNULL(V.USE_YN, N'1') = N'1' AND ISNULL(V.EXPIRE_YN, N'1') = N'1'
             AND  (@DIV_CD IS NULL OR V.DIV_CD = @DIV_CD)
           GROUP BY V.ITEM_CD
           HAVING SUM(CAST(ISNULL(V.IOPEN_QT,0)+ISNULL(V.IRCV_QT,0)-ISNULL(V.IISU_QT,0)
                           AS DECIMAL(19,6))) < 0 ) X;

    -- ⑥ 매입마감 미처리 (P-01)
    INSERT INTO #CHK (SEQ, ITEM, CNT, AMT, LEVEL, RESULT, DETAIL, DRILL)
    SELECT 6, N'입고 후 매입마감 미처리'
          ,COUNT(*)
          ,SUM(CAST(ISNULL(D.RCV_AM, 0) AS DECIMAL(19,4)))
          ,N'차단'
          ,CASE WHEN COUNT(*) = 0 THEN N'통과' ELSE N'★ 미처리' END
          ,CASE WHEN COUNT(*) = 0 THEN N'입고분이 모두 매입마감 되었다'
                ELSE N'매입단가가 확정되지 않아 재료비가 틀어진다' END
          ,N'P01_청구발주입고_진행현황.sql'
    FROM       LSTOCK   H WITH (NOLOCK)
    INNER JOIN LSTOCK_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.RCV_NB = H.RCV_NB
    WHERE  H.CO_CD = @CO_CD
      AND  H.RCV_DT BETWEEN @FR_DT AND @TO_DT
      AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
      AND  ISNULL(D.RCV_QT, 0) > ISNULL(D.CLS_QT, 0)
      AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD);

END


/*==============================================================================================
  ** 쿼리 A : 마감 가능 판정  ★ 이 파일의 결론
==============================================================================================*/
SELECT
     N'[A] 원가 마감 가능 판정'                     AS REPORT_NM
    ,@P_YR                                          AS 회계연도
    ,@CHASU                                         AS 대상차수
    ,@SMM + N' ~ ' + ISNULL(@FMM, N'?')             AS 차수기간
    ,ISNULL(@FR_DT, N'?') + N' ~ ' + ISNULL(@TO_DT, N'?') AS 실일자범위
    ,현재상태 = CASE @CLS_YN WHEN N'1' THEN N'마감' ELSE N'★미마감(집계중)' END
    ,차단항목수 = (SELECT COUNT(*) FROM #CHK WHERE LEVEL = N'차단' AND RESULT LIKE N'★%')
    ,경고항목수 = (SELECT COUNT(*) FROM #CHK WHERE LEVEL = N'경고' AND RESULT LIKE N'★%')
    ,통과항목수 = (SELECT COUNT(*) FROM #CHK WHERE RESULT = N'통과')
    ,판정 = CASE
         WHEN @CHASU IS NULL
              THEN N'9.★차수 없음 - CIV_CHASU 에 차수를 먼저 등록할 것'
         WHEN @CLS_YN = N'1'
              THEN N'0.이미 마감된 차수 (재마감하려면 마감 해제 후 진행)'
         WHEN (SELECT COUNT(*) FROM #CHK WHERE LEVEL = N'차단' AND RESULT LIKE N'★%') > 0
              THEN N'1.★마감 불가 - 차단 항목을 먼저 처리할 것 (쿼리 B)'
         WHEN (SELECT COUNT(*) FROM #CHK WHERE LEVEL = N'경고' AND RESULT LIKE N'★%') > 0
              THEN N'2.조건부 가능 - 경고 항목을 확인한 뒤 판단'
         ELSE N'3.마감 가능 - 원가계산 SP(USP_COT0010_CALC_COST_TAV) 실행' END
;


/*==============================================================================================
  ** 쿼리 B : 선행 조건 점검 상세  ★ 마감 전 체크리스트
==============================================================================================*/
SELECT
     N'[B] 마감 전 선행 점검'                       AS REPORT_NM
    ,C.SEQ                                          AS 순서
    ,C.ITEM                                         AS 점검항목
    ,C.LEVEL                                        AS 등급
    ,C.RESULT                                       AS 결과
    ,C.CNT                                          AS 건수
    ,C.AMT                                          AS 금액
    ,C.DETAIL                                       AS 설명
    ,C.DRILL                                        AS 확인_리포트
FROM   #CHK C
ORDER BY CASE WHEN C.RESULT LIKE N'★%' THEN 0 ELSE 1 END
        ,CASE C.LEVEL WHEN N'차단' THEN 1 WHEN N'경고' THEN 2 ELSE 3 END
        ,C.SEQ
;


/*==============================================================================================
  ** 쿼리 C : 원가차수 전체 목록 / 상태
==============================================================================================*/
IF OBJECT_ID(N'dbo.CIV_CHASU', N'U') IS NOT NULL
    SELECT
         N'[C] 원가차수 목록'                       AS REPORT_NM
        ,H.P_YR                                     AS 회계연도
        ,H.CHASU                                    AS 차수
        ,H.SMM                                      AS 시작월
        ,H.FMM                                      AS 종료월
        ,개월수 = CASE WHEN H.SMM IS NOT NULL AND H.FMM IS NOT NULL
                       THEN DATEDIFF(MONTH, CONVERT(DATE, H.SMM + N'01'),
                                             CONVERT(DATE, H.FMM + N'01')) + 1 END
        ,H.CLS_YN                                   AS 마감코드
        ,상태 = CASE ISNULL(H.CLS_YN, N'0') WHEN N'1' THEN N'마감' ELSE N'★미마감' END
        ,적용 = CASE WHEN H.CHASU = @CHASU THEN N'◀ 점검 대상' ELSE N'' END
        ,원가데이터 = CASE WHEN OBJECT_ID(N'dbo.CIV_PRD_TAV', N'U') IS NULL THEN N'-'
                           ELSE N'쿼리 D 참조' END
        -- 기간 연속성
        ,직전차수_종료월 = LAG(H.FMM) OVER (PARTITION BY H.P_YR ORDER BY H.CHASU)
        ,기간연속성 = CASE
             WHEN LAG(H.FMM) OVER (PARTITION BY H.P_YR ORDER BY H.CHASU) IS NULL THEN N'첫 차수'
             WHEN CONVERT(DATE, H.SMM + N'01')
                  = DATEADD(MONTH, 1, CONVERT(DATE, LAG(H.FMM) OVER (PARTITION BY H.P_YR ORDER BY H.CHASU) + N'01'))
                  THEN N'연속'
             WHEN H.SMM <= LAG(H.FMM) OVER (PARTITION BY H.P_YR ORDER BY H.CHASU)
                  THEN N'★기간 중복'
             ELSE N'★기간 공백' END
        ,판정 = CASE
             WHEN ISNULL(H.CLS_YN, N'0') <> N'1'
                  THEN N'미마감 - 이 차수 데이터를 쓰는 리포트는 ''집계중'' 으로 표기됨'
             ELSE N'-' END
    FROM   CIV_CHASU H WITH (NOLOCK)
    WHERE  H.CO_CD = @CO_CD
      AND  (@P_YR IS NULL OR H.P_YR = @P_YR)
    ORDER BY H.P_YR DESC, H.CHASU DESC;
ELSE
    SELECT N'[C] 원가차수 목록' AS REPORT_NM, N'CIV_CHASU 없음 - 원가모듈 미운영' AS 결과;


/*==============================================================================================
  ** 쿼리 D : 차수별 원가 산출 결과 존재 여부
     ─ 원가계산 SP 가 실행되었는지, 어느 결과 테이블까지 채워졌는지 본다.
==============================================================================================*/
IF OBJECT_ID(N'dbo.CIV_PRD_TAV', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
    SELECT
         N''[D] 차수별 원가 산출 결과'' AS REPORT_NM
        ,P.CHASU                       AS 차수
        ,품목수     = COUNT(DISTINCT P.ITEM_CD)
        ,생산수량계 = SUM(CAST(ISNULL(P.PRD_QT ,0) AS DECIMAL(19,6)))
        ,재료비계   = SUM(CAST(ISNULL(P.MTL_AM ,0) AS DECIMAL(19,4)))
        ,외주비계   = SUM(CAST(ISNULL(P.LBR_AM ,0) AS DECIMAL(19,4)))
        ,가공비계   = SUM(CAST(ISNULL(P.CONV_AM,0) AS DECIMAL(19,4)))
        ,제조원가계 = SUM(CAST(ISNULL(P.PRD_AM ,0) AS DECIMAL(19,4)))
        ,단가0_품목수 = SUM(CASE WHEN ISNULL(P.PRD_UM, 0) = 0 THEN 1 ELSE 0 END)
        ,수량0_품목수 = SUM(CASE WHEN ISNULL(P.PRD_QT, 0) = 0 THEN 1 ELSE 0 END)
        ,판정 = CASE
             WHEN SUM(CAST(ISNULL(P.PRD_AM,0) AS DECIMAL(19,4))) = 0
                  THEN N''1.★원가 금액이 전부 0 - 원가계산 미실행 또는 실패''
             WHEN SUM(CASE WHEN ISNULL(P.PRD_UM,0) = 0 THEN 1 ELSE 0 END) > COUNT(*) * 0.1
                  THEN N''2.★단가 0 품목이 10% 초과 - 자재 사용보고 누락 의심''
             WHEN SUM(CAST(ISNULL(P.CONV_AM,0) AS DECIMAL(19,4))) = 0
                  THEN N''3.가공비가 0 - 가공비 배부 미실행 확인''
             ELSE N''0.정상'' END
    FROM   dbo.CIV_PRD_TAV P WITH (NOLOCK)
    WHERE  P.CO_CD = @p_CO AND P.P_YR = @p_YR
      AND  (@p_DIV IS NULL OR P.DIV_CD = @p_DIV)
    GROUP BY P.CHASU
    ORDER BY P.CHASU DESC';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YR NVARCHAR(4)'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_YR=@P_YR;
    END TRY
    BEGIN CATCH
        SELECT N'[D] 차수별 원가 산출 결과' AS REPORT_NM
              ,N'조회 실패 : ' + ERROR_MESSAGE() AS 결과;
    END CATCH
END
ELSE
    SELECT N'[D] 차수별 원가 산출 결과' AS REPORT_NM, N'CIV_PRD_TAV 없음' AS 결과;


/*==============================================================================================
  ** 쿼리 E : 원가모듈 테이블 채움 현황
     ─ 원가계산 SP 가 어느 단계까지 돌았는지 테이블 단위로 확인한다.
==============================================================================================*/
SELECT
     N'[E] 원가모듈 테이블 현황'                    AS REPORT_NM
    ,순서, 테이블, 역할
    ,존재 = CASE WHEN OBJECT_ID(N'dbo.' + 테이블, N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,비고
FROM (VALUES
     (1, N'CIV_CHASU'    , N'원가차수 (P_YR + CHASU, SMM~FMM, CLS_YN)', N'★ 없으면 원가모듈 미운영')
    ,(2, N'CIV_PUR_TAV'  , N'구매단가 집계'                            , N'재료비 단가의 원천')
    ,(3, N'CIV_PRD_TAV'  , N'당기 제조원가분석 (결과)'                  , N'★ C-03/C-05 의 소스')
    ,(4, N'CIV_PRD_TAV_D', N'당기 재료비분석 (원단위)'                  , N'C-03 쿼리 D')
    ,(5, N'CIV_LBR_AM'   , N'당기 외주비'                              , N'외주가공비')
    ,(6, N'CIV_CONVCST'  , N'가공비 배부 (METHOD_FG)'                   , N'배부기준 확인 필수')
    ,(7, N'CIV_OE'       , N'가공비 총액'                              , N'배부 전 총액')
    ,(8, N'CIV_TAV'      , N'경리수불집계'                             , N'평가 결과 반영')
    ,(9, N'LINV_MVFIFO'  , N'평가 후 재고자산수불부'                    , N'P-09 점검 대상')
    ,(10,N'LINV_MVFIFO_WK',N'평가 작업본 (*_AM_GAP)'                   , N'★ P-09 차이금액')
    ,(11,N'LINV_TAV'     , N'기간 평가단가 (GISU 키)'                   , N'M-04/C-05 단가 소스')
) V(순서, 테이블, 역할, 비고)
ORDER BY 순서
;


/*==============================================================================================
  ** 쿼리 F : 미마감 차수의 영향 범위
     ─ 미마감이면 어느 리포트가 '집계중' 으로 표시되는지 명시한다.
==============================================================================================*/
SELECT
     N'[F] 미마감 영향 범위'                        AS REPORT_NM
    ,현재차수상태 = CASE @CLS_YN WHEN N'1' THEN N'마감' ELSE N'★미마감' END
    ,리포트, 영향, 동작
FROM (VALUES
     (1, N'C03_제품별_원가구성.sql'   , N'원가 구성·전차수 대비'
       , N'@ONLY_CLS=1 이면 미마감 차수를 건너뛴다. 조회되면 상태에 ★미마감 표시')
    ,(2, N'C04_표준원가_차이분석.sql' , N'실제원가 단가'
       , N'미마감 단가로 차이 분석 시 단가차이가 왜곡된다')
    ,(3, N'C05_매출이익_분석.sql'     , N'매출원가 (@UM_SRC=PRD)'
       , N'미마감이면 이익률이 튄다. FIFO/TAV 로 대체 권장')
    ,(4, N'E01_경영KPI_대시보드.sql'  , N'원가 타일'
       , N'미마감이면 값 대신 ''집계중'' 으로 표기한다 (의도된 동작)')
    ,(5, N'PJT_생산원가_보고서.sql'   , N'프로젝트 원가'
       , N'원가모듈과 별도 산출이라 직접 영향 없음')
) V(순서, 리포트, 영향, 동작)
ORDER BY 순서
;


DROP TABLE #CHK;
GO


/*==============================================================================================
  [ 상시 점검 운영 ]
  ----------------------------------------------------------------------------------------------
  실행 시점 : **매월 원가 마감 직전** (원가계산 SP 실행 전)
  실행 순서 : ① P09_재고정합성_점검.sql 실행 → 평가·재공 정합성 확보
              ② 이 파일 실행 → 쿼리 A 판정 확인
              ③ '1.마감 불가' 면 쿼리 B 의 차단 항목을 해당 리포트로 드릴다운해 처리
              ④ 처리 후 ② 부터 다시 → '3.마감 가능' 확인
              ⑤ 원가계산 SP(USP_COT0010_CALC_COST_TAV) 실행
              ⑥ CIV_CHASU.CLS_YN = '1' 로 마감
              ⑦ C03/C04/C05/E01 조회 (이제 '집계중' 이 사라진다)

  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 원가차수 운영 주기  ★ 월 1회인지 수시인지에 따라 점검 주기가 달라진다
     SELECT P_YR, CHASU, SMM, FMM, CLS_YN FROM CIV_CHASU
     WHERE CO_CD='1000' ORDER BY P_YR DESC, CHASU DESC;
     --> 차수가 월 단위(SMM=FMM)면 월 마감, 분기·연 단위면 그 주기에 맞춰 실행.

  -- (2) 마감 여부 컬럼 확인
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('CIV_CHASU');
     --> CLS_YN 이 없으면 다른 컬럼으로 마감을 관리하는 사이트다. 1번 블록을 수정할 것.

  -- (3) 자재 사용보고 컬럼 확인  ★ 점검 ① 의 전제
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('LWO_REQ_WF')
       AND name IN ('REQ_QT','ISU_QT','USE_QT');
     --> USE_QT 가 없으면 사용보고를 LMTL_USE 로만 관리하는 사이트다.
        그 경우 점검 ① 을 M05 의 4단계 추적으로 대체할 것.

  -- (4) 과거 차수의 마감 이력  ★ 마감을 실제로 운영하는지
     SELECT CLS_YN, COUNT(*) FROM CIV_CHASU WHERE CO_CD='1000' GROUP BY CLS_YN;
     --> 전부 '0' 이면 마감 플래그를 쓰지 않는 사이트다. 이 경우 C-07 의 판정은
        선행 점검(쿼리 B)만 의미가 있고, 마감 상태 판정은 무시해야 한다.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **선행 점검 6종은 '차단' 등급이라도 회사 정책에 따라 무시할 수 있다.**
     예를 들어 출고 자재를 월말에 일괄 사용보고하는 사이트는 점검 ① 이 항상 걸린다.
     도입 시 원가 담당자와 함께 각 항목의 등급(차단/경고/정보)을 조정할 것.
     등급은 `#CHK` 적재 시 `N'차단'` 문자열을 바꾸면 된다.

  2) **재공 실사 차이(점검 ③)는 건수를 세지 않는다.** 실사 데이터의 컬럼 구조가 사이트마다
     달라 여기서는 테이블 존재 여부만 확인하고, 실제 차이는 `P09_재고정합성_점검.sql`
     쿼리 D 로 넘긴다. 마감 전에 그 파일을 먼저 돌리는 것이 전제다.

  3) 이 리포트는 **마감을 실행하지 않는다.** `CIV_CHASU.CLS_YN` 을 바꾸는 것은 ERP 화면에서
     해야 한다. 여기서는 마감해도 되는 상태인지만 판정한다.

  4) 차수 기간(`SMM`~`FMM`)을 실일자 범위로 환산해 선행 점검을 돌린다. 차수 기간이
     등록되지 않았으면 연 전체로 점검하므로 건수가 과다하게 나온다. 쿼리 C 로 먼저 확인할 것.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   P09_재고정합성_점검.sql        : 평가·재공 정합성 (이 점검의 선행)
   M05_자재_청구출고사용_현황.sql : 점검 ① 드릴다운
   M01_작업지시_진행현황.sql      : 점검 ② 드릴다운
   P01_청구발주입고_진행현황.sql  : 점검 ⑥ 드릴다운
   C03_제품별_원가구성.sql        : 마감 후 조회 대상
==============================================================================================*/
