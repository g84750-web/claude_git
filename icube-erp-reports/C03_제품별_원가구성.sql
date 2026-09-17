/*==============================================================================================
  [ iCUBE ] C-03  제품별 원가 구성 (재료비 / 외주비 / 가공비)                        (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 제품 1단위 원가가 **무엇으로 이루어졌는가**. 판가 결정과 원가절감 과제 도출의 기초.
         + **전차수 대비 증감**을 처음부터 구조에 넣었다 (실무에서 가장 많이 보는 컬럼).

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 소스 — 원가모듈 결과 테이블 (전부 명세서 미등재. OBJECT_ID 가드 필수) ]
  ----------------------------------------------------------------------------------------------
     CIV_CHASU       원가차수        P_YR + CHASU, SMM~FMM, CLS_YN
     CIV_PRD_TAV     당기 제조원가분석  ITEM_CD, PRD_QT, MTL_AM(재료), LBR_AM(외주),
                                        CONV_AM(가공), PRD_AM, PRD_UM
     CIV_PRD_TAV_D   당기 재료비분석    PITEM_CD, CITEM_CD, USE_QT, REAL_QT(원단위), USE_AM
     CIV_LBR_AM      당기 외주비        ITEM_CD, LBR_AM
     CIV_CONVCST     가공비 배부        METHOD_FG (배부기준 7종)
     CIV_OE          가공비 총액

  ----------------------------------------------------------------------------------------------
  [ 산식 ]
  ----------------------------------------------------------------------------------------------
     제품단위원가 = (MTL_AM + LBR_AM + CONV_AM) / PRD_QT
     재료비율 = MTL_AM  / NULLIF(PRD_AM, 0) * 100
     외주비율 = LBR_AM  / NULLIF(PRD_AM, 0) * 100
     가공비율 = CONV_AM / NULLIF(PRD_AM, 0) * 100
     전차수대비 = 당차수 PRD_UM / 전차수 PRD_UM - 1

  ----------------------------------------------------------------------------------------------
  [ ★ 반드시 지킨 것 ]
  ----------------------------------------------------------------------------------------------
   1. **원가계산 SP(`USP_COT0010_CALC_COST_TAV`)가 실행된 차수만 데이터가 있다.**
      `CIV_CHASU.CLS_YN='1'`(마감) 차수를 기본으로 쓴다. 미마감 차수는 값이 불완전하므로
      조회는 되게 하되 **쿼리 F 에 '미마감' 을 명시**한다.
   2. **원가모듈에는 프로젝트 축이 없다.** 프로젝트별 원가는 `PJT_생산원가_보고서.sql` 로
      별도 산출해야 한다. 여기서 프로젝트를 찾지 말 것.
   3. **가공비 배부방법(`CIV_CONVCST.METHOD_FG`)이 사이트마다 다르다** (수량/금액/시간/중량 등).
      배부기준을 같이 보여주지 않으면 현업이 숫자를 납득하지 않는다 → 쿼리 E.
   4. **차수 2개 self-join 구조를 처음부터 넣었다.** `@CHASU`(당차수) / `@PREV`(전차수).
      `@PREV` 를 비우면 당차수 직전의 마감 차수를 자동으로 찾는다.
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@P_YR     NVARCHAR(4)  = N'2026'
    ,@CHASU    INT          = NULL            -- 당차수 (NULL = 최신 마감차수 자동)
    ,@PREV     INT          = NULL            -- 전차수 (NULL = 당차수 직전 마감차수 자동)
    ,@ITEM_CD  NVARCHAR(25) = NULL
    ,@ACCT_FG  NVARCHAR(1)  = NULL            -- 2제품 4반제품
    ,@ONLY_CLS NCHAR(1)     = N'1'            -- 1 = 마감 차수만 사용 (★ 기본값)
    ,@TH_CHG   DECIMAL(5,1) = 10.0            -- 전차수 대비 변동 경고 기준 (%)
;

DECLARE @SQL NVARCHAR(MAX);
DECLARE @CH_ST NVARCHAR(20) = N'없음', @PV_ST NVARCHAR(20) = N'없음';
DECLARE @HAS_PRD BIT = 0;

IF OBJECT_ID('tempdb..#CST') IS NOT NULL DROP TABLE #CST;

CREATE TABLE #CST (
     CHASU   INT
    ,TAG     NCHAR(1)                -- C 당차수 / P 전차수
    ,ITEM_CD NVARCHAR(25)
    ,PRD_QT  DECIMAL(19,6)
    ,MTL_AM  DECIMAL(19,4)
    ,LBR_AM  DECIMAL(19,4)
    ,CONV_AM DECIMAL(19,4)
    ,PRD_AM  DECIMAL(19,4)
    ,PRD_UM  DECIMAL(19,6)
);


/*==============================================================================================
  1. 차수 결정
==============================================================================================*/
IF OBJECT_ID(N'dbo.CIV_CHASU', N'U') IS NULL
    PRINT N'[1] ★ CIV_CHASU 없음 - 원가모듈 미운영. 본 리포트 사용 불가';
ELSE
BEGIN
    -- 당차수
    IF @CHASU IS NULL
        SELECT TOP 1 @CHASU = CHASU
        FROM   CIV_CHASU WITH (NOLOCK)
        WHERE  CO_CD = @CO_CD AND P_YR = @P_YR
          AND  (@ONLY_CLS = N'0' OR ISNULL(CLS_YN, N'0') = N'1')
        ORDER BY CHASU DESC;

    SELECT @CH_ST = CASE WHEN ISNULL(CLS_YN, N'0') = N'1' THEN N'마감' ELSE N'★미마감' END
    FROM   CIV_CHASU WITH (NOLOCK)
    WHERE  CO_CD = @CO_CD AND P_YR = @P_YR AND CHASU = @CHASU;

    -- 전차수 (당차수 직전)
    IF @PREV IS NULL AND @CHASU IS NOT NULL
        SELECT TOP 1 @PREV = CHASU
        FROM   CIV_CHASU WITH (NOLOCK)
        WHERE  CO_CD = @CO_CD AND P_YR = @P_YR AND CHASU < @CHASU
          AND  (@ONLY_CLS = N'0' OR ISNULL(CLS_YN, N'0') = N'1')
        ORDER BY CHASU DESC;

    SELECT @PV_ST = CASE WHEN ISNULL(CLS_YN, N'0') = N'1' THEN N'마감' ELSE N'★미마감' END
    FROM   CIV_CHASU WITH (NOLOCK)
    WHERE  CO_CD = @CO_CD AND P_YR = @P_YR AND CHASU = @PREV;

    PRINT N'[1] 당차수 ' + ISNULL(CAST(@CHASU AS NVARCHAR(10)), N'없음') + N'(' + @CH_ST + N')'
        + N' / 전차수 ' + ISNULL(CAST(@PREV AS NVARCHAR(10)), N'없음') + N'(' + @PV_ST + N')';
END


/*==============================================================================================
  2. #CST : 제조원가 적재 (당차수 + 전차수)
==============================================================================================*/
IF OBJECT_ID(N'dbo.CIV_PRD_TAV', N'U') IS NOT NULL AND @CHASU IS NOT NULL
BEGIN
    SET @SQL = N'
        INSERT INTO #CST (CHASU, TAG, ITEM_CD, PRD_QT, MTL_AM, LBR_AM, CONV_AM, PRD_AM, PRD_UM)
        SELECT P.CHASU
              ,CASE WHEN P.CHASU = @p_CH THEN N''C'' ELSE N''P'' END
              ,P.ITEM_CD
              ,SUM(CAST(ISNULL(P.PRD_QT ,0) AS DECIMAL(19,6)))
              ,SUM(CAST(ISNULL(P.MTL_AM ,0) AS DECIMAL(19,4)))
              ,SUM(CAST(ISNULL(P.LBR_AM ,0) AS DECIMAL(19,4)))
              ,SUM(CAST(ISNULL(P.CONV_AM,0) AS DECIMAL(19,4)))
              ,SUM(CAST(ISNULL(P.PRD_AM ,0) AS DECIMAL(19,4)))
              ,CAST(SUM(CAST(ISNULL(P.PRD_AM,0) AS DECIMAL(19,4)))
                    / NULLIF(SUM(CAST(ISNULL(P.PRD_QT,0) AS DECIMAL(19,6))), 0) AS DECIMAL(19,6))
        FROM   dbo.CIV_PRD_TAV P WITH (NOLOCK)
        WHERE  P.CO_CD = @p_CO AND P.P_YR = @p_YR
          AND  P.CHASU IN (@p_CH, @p_PV)
          AND  (@p_DIV  IS NULL OR P.DIV_CD  = @p_DIV)
          AND  (@p_ITEM IS NULL OR P.ITEM_CD = @p_ITEM)
        GROUP BY P.CHASU, P.ITEM_CD';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YR NVARCHAR(4)
              ,@p_CH INT, @p_PV INT, @p_ITEM NVARCHAR(25)'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_YR=@P_YR
            ,@p_CH=@CHASU, @p_PV=@PREV, @p_ITEM=@ITEM_CD;
        SET @HAS_PRD = 1;
        PRINT N'[2] CIV_PRD_TAV 적재 ' + CAST((SELECT COUNT(*) FROM #CST) AS NVARCHAR(20)) + N' 행';
    END TRY
    BEGIN CATCH
        PRINT N'[2] ★ CIV_PRD_TAV 조회 실패 : ' + ERROR_MESSAGE();
    END CATCH
END
ELSE
    PRINT N'[2] CIV_PRD_TAV 없음 또는 차수 미확정';

CREATE CLUSTERED INDEX IX_CST ON #CST (ITEM_CD, TAG);

-- 계정 필터
IF @ACCT_FG IS NOT NULL
    DELETE C FROM #CST C
    LEFT JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = C.ITEM_CD
    WHERE ISNULL(I.ACCT_FG, N'') <> @ACCT_FG;


/*==============================================================================================
  ** 쿼리 A : 제품별 원가 구성  (메인)  ★ 전차수 대비 포함
==============================================================================================*/
SELECT
     N'[A] 제품별 원가 구성'                        AS REPORT_NM
    ,@P_YR                                          AS 회계연도
    ,@CHASU                                         AS 당차수
    ,@CH_ST                                         AS 당차수상태
    ,C.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'2' THEN N'제품' WHEN N'4' THEN N'반제품' ELSE I.ACCT_FG END

    -- 당차수
    ,C.PRD_QT                                       AS 생산수량
    ,C.MTL_AM                                       AS 재료비
    ,C.LBR_AM                                       AS 외주비
    ,C.CONV_AM                                      AS 가공비
    ,C.PRD_AM                                       AS 제조원가계
    ,C.PRD_UM                                       AS 단위원가

    -- 구성비
    ,재료비율_PCT = CAST(C.MTL_AM  / NULLIF(C.PRD_AM, 0) * 100 AS DECIMAL(5,1))
    ,외주비율_PCT = CAST(C.LBR_AM  / NULLIF(C.PRD_AM, 0) * 100 AS DECIMAL(5,1))
    ,가공비율_PCT = CAST(C.CONV_AM / NULLIF(C.PRD_AM, 0) * 100 AS DECIMAL(5,1))
    ,주원가요소 = CASE
         WHEN C.MTL_AM  >= C.LBR_AM AND C.MTL_AM  >= C.CONV_AM THEN N'재료비'
         WHEN C.LBR_AM  >= C.CONV_AM                           THEN N'외주비'
         ELSE N'가공비' END

    -- 단위당
    ,단위재료비 = CAST(C.MTL_AM  / NULLIF(C.PRD_QT, 0) AS DECIMAL(19,4))
    ,단위외주비 = CAST(C.LBR_AM  / NULLIF(C.PRD_QT, 0) AS DECIMAL(19,4))
    ,단위가공비 = CAST(C.CONV_AM / NULLIF(C.PRD_QT, 0) AS DECIMAL(19,4))

    -- 전차수 대비  ★ 실무에서 가장 많이 보는 컬럼
    ,@PREV                                          AS 전차수
    ,P.PRD_QT                                       AS 전차수_생산수량
    ,P.PRD_UM                                       AS 전차수_단위원가
    ,단위원가_증감 = CAST(C.PRD_UM - P.PRD_UM AS DECIMAL(19,4))
    ,단위원가_증감률_PCT = CAST(CASE WHEN ISNULL(P.PRD_UM, 0) <> 0
                                     THEN (C.PRD_UM / P.PRD_UM - 1) * 100 END AS DECIMAL(9,1))
    ,재료비율_증감_PCTP = CAST(C.MTL_AM /NULLIF(C.PRD_AM,0)*100
                              - P.MTL_AM /NULLIF(P.PRD_AM,0)*100 AS DECIMAL(5,1))
    ,외주비율_증감_PCTP = CAST(C.LBR_AM /NULLIF(C.PRD_AM,0)*100
                              - P.LBR_AM /NULLIF(P.PRD_AM,0)*100 AS DECIMAL(5,1))
    ,가공비율_증감_PCTP = CAST(C.CONV_AM/NULLIF(C.PRD_AM,0)*100
                              - P.CONV_AM/NULLIF(P.PRD_AM,0)*100 AS DECIMAL(5,1))

    ,판정 = CASE
         WHEN P.ITEM_CD IS NULL                                                THEN N'9.전차수 없음 (신규)'
         WHEN ISNULL(P.PRD_UM, 0) = 0                                          THEN N'9.전차수 단가 0'
         WHEN ABS((C.PRD_UM / P.PRD_UM - 1) * 100) > @TH_CHG * 3               THEN N'1.★급변 (30% 초과)'
         WHEN ABS((C.PRD_UM / P.PRD_UM - 1) * 100) > @TH_CHG                   THEN N'2.★변동 큼'
         ELSE N'0.안정' END
FROM       #CST  C
LEFT  JOIN #CST  P ON P.ITEM_CD = C.ITEM_CD AND P.TAG = N'P'
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = C.ITEM_CD
WHERE  C.TAG = N'C'
ORDER BY 판정, ABS(ISNULL(단위원가_증감률_PCT, 0)) DESC, C.PRD_AM DESC
;


/*==============================================================================================
  ** 쿼리 B : 전사 원가 구성 요약  (경영 보고 1행)
==============================================================================================*/
SELECT
     N'[B] 전사 원가 구성'                          AS REPORT_NM
    ,@P_YR                                          AS 회계연도
    ,@CHASU                                         AS 당차수
    ,@CH_ST                                         AS 당차수상태
    ,COUNT(*)                                       AS 대상품목수
    ,SUM(C.PRD_QT)                                  AS 생산수량계
    ,SUM(C.MTL_AM)                                  AS 재료비계
    ,SUM(C.LBR_AM)                                  AS 외주비계
    ,SUM(C.CONV_AM)                                 AS 가공비계
    ,SUM(C.PRD_AM)                                  AS 제조원가계
    ,재료비율_PCT = CAST(SUM(C.MTL_AM)  / NULLIF(SUM(C.PRD_AM), 0) * 100 AS DECIMAL(5,1))
    ,외주비율_PCT = CAST(SUM(C.LBR_AM)  / NULLIF(SUM(C.PRD_AM), 0) * 100 AS DECIMAL(5,1))
    ,가공비율_PCT = CAST(SUM(C.CONV_AM) / NULLIF(SUM(C.PRD_AM), 0) * 100 AS DECIMAL(5,1))
    -- 전차수
    ,전차수_제조원가계 = (SELECT SUM(PRD_AM) FROM #CST WHERE TAG = N'P')
    ,제조원가_증감률_PCT = CAST(CASE WHEN (SELECT SUM(PRD_AM) FROM #CST WHERE TAG=N'P') <> 0
                                     THEN (SUM(C.PRD_AM) / (SELECT SUM(PRD_AM) FROM #CST WHERE TAG=N'P') - 1) * 100
                                     END AS DECIMAL(9,1))
    ,전차수_재료비율_PCT = (SELECT CAST(SUM(MTL_AM)/NULLIF(SUM(PRD_AM),0)*100 AS DECIMAL(5,1))
                            FROM #CST WHERE TAG = N'P')
    ,급변품목수 = SUM(CASE WHEN EXISTS (
         SELECT 1 FROM #CST X WHERE X.ITEM_CD = C.ITEM_CD AND X.TAG = N'P'
           AND ISNULL(X.PRD_UM,0) <> 0 AND ABS((C.PRD_UM / X.PRD_UM - 1) * 100) > @TH_CHG * 3)
         THEN 1 ELSE 0 END)
    ,판정 = CASE
         WHEN @CH_ST <> N'마감'  THEN N'1.★미마감 차수 - 값이 불완전하다. 마감 후 재조회할 것'
         WHEN @PREV IS NULL      THEN N'2.전차수 없음 - 증감 비교 불가'
         ELSE N'0.정상' END
FROM   #CST C
WHERE  C.TAG = N'C'
;


/*==============================================================================================
  ** 쿼리 C : 전차수 대비 변동 상위  ★ 원가절감/이상 추적 대상
==============================================================================================*/
SELECT TOP 100
     N'[C] 전차수 대비 변동 상위'                   AS REPORT_NM
    ,변동구분 = CASE WHEN C.PRD_UM > P.PRD_UM THEN N'1.★상승' ELSE N'2.하락' END
    ,C.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,P.PRD_UM                                       AS 전차수_단위원가
    ,C.PRD_UM                                       AS 당차수_단위원가
    ,증감액 = CAST(C.PRD_UM - P.PRD_UM AS DECIMAL(19,4))
    ,증감률_PCT = CAST((C.PRD_UM / P.PRD_UM - 1) * 100 AS DECIMAL(9,1))
    ,영향금액 = CAST((C.PRD_UM - P.PRD_UM) * C.PRD_QT AS DECIMAL(19,4))   -- 당차수 생산량 기준
    -- 요소별 단위원가 증감 (어느 요소가 올렸는가)
    ,단위재료비_증감 = CAST(C.MTL_AM /NULLIF(C.PRD_QT,0) - P.MTL_AM /NULLIF(P.PRD_QT,0) AS DECIMAL(19,4))
    ,단위외주비_증감 = CAST(C.LBR_AM /NULLIF(C.PRD_QT,0) - P.LBR_AM /NULLIF(P.PRD_QT,0) AS DECIMAL(19,4))
    ,단위가공비_증감 = CAST(C.CONV_AM/NULLIF(C.PRD_QT,0) - P.CONV_AM/NULLIF(P.PRD_QT,0) AS DECIMAL(19,4))
    ,주원인 = CASE
         WHEN ABS(C.MTL_AM /NULLIF(C.PRD_QT,0) - P.MTL_AM /NULLIF(P.PRD_QT,0))
              >= ABS(C.LBR_AM /NULLIF(C.PRD_QT,0) - P.LBR_AM /NULLIF(P.PRD_QT,0))
          AND ABS(C.MTL_AM /NULLIF(C.PRD_QT,0) - P.MTL_AM /NULLIF(P.PRD_QT,0))
              >= ABS(C.CONV_AM/NULLIF(C.PRD_QT,0) - P.CONV_AM/NULLIF(P.PRD_QT,0))
              THEN N'재료비 (단가 또는 사용량 - C-04 확인)'
         WHEN ABS(C.LBR_AM /NULLIF(C.PRD_QT,0) - P.LBR_AM /NULLIF(P.PRD_QT,0))
              >= ABS(C.CONV_AM/NULLIF(C.PRD_QT,0) - P.CONV_AM/NULLIF(P.PRD_QT,0))
              THEN N'외주비 (외주단가 또는 외주물량)'
         ELSE N'가공비 (배부기준 또는 조업도 - 쿼리 E 확인)' END
    ,P.PRD_QT                                       AS 전차수_생산수량
    ,C.PRD_QT                                       AS 당차수_생산수량
    ,생산량_증감률_PCT = CAST(CASE WHEN ISNULL(P.PRD_QT,0) <> 0
                                   THEN (C.PRD_QT / P.PRD_QT - 1) * 100 END AS DECIMAL(9,1))
    ,비고 = CASE
         WHEN ISNULL(P.PRD_QT,0) <> 0 AND C.PRD_QT / P.PRD_QT < 0.5
              THEN N'★ 생산량이 절반 이하 - 고정비 배부로 단위원가가 오른 것일 수 있음'
         WHEN ISNULL(P.PRD_QT,0) <> 0 AND C.PRD_QT / P.PRD_QT > 2
              THEN N'생산량 2배 초과 - 규모의 경제로 단위원가 하락'
         ELSE N'-' END
FROM       #CST  C
INNER JOIN #CST  P ON P.ITEM_CD = C.ITEM_CD AND P.TAG = N'P'
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = C.ITEM_CD
WHERE  C.TAG = N'C'
  AND  ISNULL(P.PRD_UM, 0) <> 0
  AND  ABS((C.PRD_UM / P.PRD_UM - 1) * 100) > @TH_CHG
ORDER BY ABS((C.PRD_UM - P.PRD_UM) * C.PRD_QT) DESC
;


/*==============================================================================================
  ** 쿼리 D : 재료비 상세 (원단위)  ─ CIV_PRD_TAV_D
     ─ 모품목(PITEM_CD) × 자품목(CITEM_CD) 의 실제 사용량과 원단위(REAL_QT).
       BOM 표준 대비 비교는 C-04(표준원가 차이분석)에서 한다.
==============================================================================================*/
IF OBJECT_ID(N'dbo.CIV_PRD_TAV_D', N'U') IS NOT NULL AND @CHASU IS NOT NULL
BEGIN
    SET @SQL = N'
    SELECT
         N''[D] 재료비 상세 (원단위)'' AS REPORT_NM
        ,D.PITEM_CD                  AS 모품번
        ,PI.ITEM_NM                  AS 모품명
        ,D.CITEM_CD                  AS 자품번
        ,CI.ITEM_NM                  AS 자품명
        ,CI.SPEC                     AS 자품규격
        ,CI.UNIT_CD                  AS 단위
        ,자계정 = CASE CI.ACCT_FG WHEN N''0'' THEN N''원재료'' WHEN N''1'' THEN N''부재료''
                                  WHEN N''4'' THEN N''반제품'' ELSE CI.ACCT_FG END
        ,사용수량 = SUM(CAST(ISNULL(D.USE_QT ,0) AS DECIMAL(19,6)))
        ,원단위   = CAST(AVG(CAST(ISNULL(D.REAL_QT,0) AS DECIMAL(19,6))) AS DECIMAL(19,6))
        ,단가     = CAST(AVG(CAST(NULLIF(D.MTL_UM,0) AS DECIMAL(19,6))) AS DECIMAL(19,6))
        ,사용금액 = SUM(CAST(ISNULL(D.USE_AM ,0) AS DECIMAL(19,4)))
        ,모품_재료비계 = MAX(C.MTL_AM)
        ,기여도_PCT = CAST(SUM(CAST(ISNULL(D.USE_AM,0) AS DECIMAL(19,4)))
                           / NULLIF(MAX(C.MTL_AM), 0) * 100 AS DECIMAL(5,1))
        ,누적기여도_PCT = CAST(SUM(SUM(CAST(ISNULL(D.USE_AM,0) AS DECIMAL(19,4))))
                               OVER (PARTITION BY D.PITEM_CD
                                     ORDER BY SUM(CAST(ISNULL(D.USE_AM,0) AS DECIMAL(19,4))) DESC
                                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                               / NULLIF(MAX(C.MTL_AM), 0) * 100 AS DECIMAL(5,1))
    FROM       dbo.CIV_PRD_TAV_D D WITH (NOLOCK)
    LEFT  JOIN #CST  C  ON C.ITEM_CD = D.PITEM_CD AND C.TAG = N''C''
    LEFT  JOIN SITEM PI WITH (NOLOCK) ON PI.CO_CD = @p_CO AND PI.ITEM_CD = D.PITEM_CD
    LEFT  JOIN SITEM CI WITH (NOLOCK) ON CI.CO_CD = @p_CO AND CI.ITEM_CD = D.CITEM_CD
    WHERE  D.CO_CD = @p_CO AND D.P_YR = @p_YR AND D.CHASU = @p_CH
      AND  (@p_DIV  IS NULL OR D.DIV_CD   = @p_DIV)
      AND  (@p_ITEM IS NULL OR D.PITEM_CD = @p_ITEM)
    GROUP BY D.PITEM_CD, PI.ITEM_NM, D.CITEM_CD, CI.ITEM_NM, CI.SPEC, CI.UNIT_CD, CI.ACCT_FG
    ORDER BY D.PITEM_CD, 사용금액 DESC';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YR NVARCHAR(4), @p_CH INT, @p_ITEM NVARCHAR(25)'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_YR=@P_YR, @p_CH=@CHASU, @p_ITEM=@ITEM_CD;
    END TRY
    BEGIN CATCH
        SELECT N'[D] 재료비 상세' AS REPORT_NM, N'조회 실패 : ' + ERROR_MESSAGE() AS 결과;
    END CATCH
END
ELSE
    SELECT N'[D] 재료비 상세' AS REPORT_NM, N'CIV_PRD_TAV_D 없음 또는 차수 미확정 - 생략' AS 결과;


/*==============================================================================================
  ** 쿼리 E : 가공비 배부 기준  ★ 현업 납득의 근거
     ─ METHOD_FG 가 사이트마다 다르다. 배부기준을 보여주지 않으면 숫자를 믿지 않는다.
==============================================================================================*/
IF OBJECT_ID(N'dbo.CIV_CONVCST', N'U') IS NOT NULL AND @CHASU IS NOT NULL
BEGIN
    SET @SQL = N'
    SELECT
         N''[E] 가공비 배부 기준'' AS REPORT_NM
        ,V.METHOD_FG              AS 배부기준코드
        ,배부기준 = CASE V.METHOD_FG
             WHEN N''0'' THEN N''0.수량기준''   WHEN N''1'' THEN N''1.금액기준''
             WHEN N''2'' THEN N''2.시간기준''   WHEN N''3'' THEN N''3.중량기준''
             WHEN N''4'' THEN N''4.직접노무비'' WHEN N''5'' THEN N''5.기계시간''
             WHEN N''6'' THEN N''6.직접재료비''
             ELSE N''9.'' + ISNULL(V.METHOD_FG, N''?'') END
        ,COUNT(*)                 AS 배부건수
        ,COUNT(DISTINCT V.ITEM_CD) AS 품목수
        ,배부금액 = SUM(CAST(ISNULL(V.CONV_AM, 0) AS DECIMAL(19,4)))
        ,구성비_PCT = CAST(SUM(CAST(ISNULL(V.CONV_AM,0) AS DECIMAL(19,4))) * 100.0
                           / NULLIF(SUM(SUM(CAST(ISNULL(V.CONV_AM,0) AS DECIMAL(19,4)))) OVER (), 0)
                           AS DECIMAL(5,1))
        ,비고 = N''배부기준이 바뀌면 품목별 단위원가가 통째로 달라진다. 전차수와 동일한지 확인할 것''
    FROM   dbo.CIV_CONVCST V WITH (NOLOCK)
    WHERE  V.CO_CD = @p_CO AND V.P_YR = @p_YR AND V.CHASU = @p_CH
      AND  (@p_DIV IS NULL OR V.DIV_CD = @p_DIV)
    GROUP BY V.METHOD_FG
    ORDER BY 배부금액 DESC';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YR NVARCHAR(4), @p_CH INT'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_YR=@P_YR, @p_CH=@CHASU;
    END TRY
    BEGIN CATCH
        SELECT N'[E] 가공비 배부 기준' AS REPORT_NM
              ,N'CIV_CONVCST 컬럼 구조 상이 - 생략 (' + ERROR_MESSAGE() + N')' AS 결과;
    END CATCH
END
ELSE
    SELECT N'[E] 가공비 배부 기준' AS REPORT_NM, N'CIV_CONVCST 없음 - 생략' AS 결과;


/*==============================================================================================
  ** 쿼리 F : 원가차수 목록 / 상태  ★ 조회 전 반드시 확인
==============================================================================================*/
IF OBJECT_ID(N'dbo.CIV_CHASU', N'U') IS NOT NULL
    SELECT
         N'[F] 원가차수 상태'                       AS REPORT_NM
        ,H.P_YR                                     AS 회계연도
        ,H.CHASU                                    AS 차수
        ,H.SMM                                      AS 시작월
        ,H.FMM                                      AS 종료월
        ,H.CLS_YN                                   AS 마감여부코드
        ,상태 = CASE ISNULL(H.CLS_YN, N'0') WHEN N'1' THEN N'마감' ELSE N'★미마감(집계중)' END
        ,적용 = CASE WHEN H.CHASU = @CHASU THEN N'◀ 당차수'
                     WHEN H.CHASU = @PREV  THEN N'◀ 전차수'
                     ELSE N'' END
        ,원가데이터건수 = (SELECT COUNT(*) FROM #CST X WHERE X.CHASU = H.CHASU)
        ,판정 = CASE WHEN ISNULL(H.CLS_YN, N'0') <> N'1'
                     THEN N'미마감 차수는 값이 불완전하다. 원가계산 SP 실행 후 조회할 것'
                     ELSE N'-' END
    FROM   CIV_CHASU H WITH (NOLOCK)
    WHERE  H.CO_CD = @CO_CD AND H.P_YR = @P_YR
    ORDER BY H.CHASU DESC;
ELSE
    SELECT N'[F] 원가차수 상태' AS REPORT_NM, N'CIV_CHASU 없음 - 원가모듈 미운영' AS 결과;


/*==============================================================================================
  ** 쿼리 G : 데이터 점검
==============================================================================================*/
SELECT
     N'[G] 데이터 점검'                             AS REPORT_NM
    ,CIV_CHASU      = CASE WHEN OBJECT_ID(N'dbo.CIV_CHASU'    , N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,CIV_PRD_TAV    = CASE WHEN OBJECT_ID(N'dbo.CIV_PRD_TAV'  , N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,CIV_PRD_TAV_D  = CASE WHEN OBJECT_ID(N'dbo.CIV_PRD_TAV_D', N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,CIV_LBR_AM     = CASE WHEN OBJECT_ID(N'dbo.CIV_LBR_AM'   , N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,CIV_CONVCST    = CASE WHEN OBJECT_ID(N'dbo.CIV_CONVCST'  , N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,CIV_OE         = CASE WHEN OBJECT_ID(N'dbo.CIV_OE'       , N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,당차수 = ISNULL(CAST(@CHASU AS NVARCHAR(10)), N'없음')
    ,당차수상태 = @CH_ST
    ,전차수 = ISNULL(CAST(@PREV AS NVARCHAR(10)), N'없음')
    ,전차수상태 = @PV_ST
    ,당차수품목수 = (SELECT COUNT(*) FROM #CST WHERE TAG = N'C')
    ,전차수품목수 = (SELECT COUNT(*) FROM #CST WHERE TAG = N'P')
    ,판정 = CASE
         WHEN OBJECT_ID(N'dbo.CIV_PRD_TAV', N'U') IS NULL
              THEN N'1.★CIV_PRD_TAV 없음 - 원가모듈 미운영. 본 리포트 사용 불가'
         WHEN @CHASU IS NULL
              THEN N'2.★마감된 원가차수 없음 - 원가계산 SP(USP_COT0010_CALC_COST_TAV) 실행 필요'
         WHEN @HAS_PRD = 0
              THEN N'3.★CIV_PRD_TAV 조회 실패 - 컬럼 구조 확인 필요'
         WHEN (SELECT COUNT(*) FROM #CST WHERE TAG = N'C') = 0
              THEN N'4.★당차수에 원가 데이터 없음'
         WHEN @PREV IS NULL
              THEN N'5.전차수 없음 - 증감 비교 컬럼이 전부 NULL 로 나온다 (정상)'
         WHEN @CH_ST <> N'마감'
              THEN N'6.★미마감 차수 사용 중 - 값이 불완전하다'
         ELSE N'0.정상' END
;


DROP TABLE #CST;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 원가모듈 테이블 실존  ★ 전부 명세서 미등재. 없으면 본 리포트 사용 불가
     SELECT name FROM sys.tables WHERE name LIKE 'CIV_%' ORDER BY name;

  -- (2) 원가차수 운영 상태  ★ 쿼리 F 와 같은 목적
     SELECT P_YR, CHASU, SMM, FMM, CLS_YN FROM CIV_CHASU
     WHERE CO_CD='1000' ORDER BY P_YR DESC, CHASU DESC;
     --> CLS_YN='1' 인 차수가 없으면 원가계산이 한 번도 마감되지 않은 것이다.

  -- (3) CIV_PRD_TAV 실제 컬럼  ★ 금액 컬럼명이 다르면 2번 블록 수정
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('CIV_PRD_TAV') ORDER BY column_id;
     --> 본 쿼리 전제 : PRD_QT, MTL_AM, LBR_AM, CONV_AM, PRD_AM, PRD_UM, CHASU, P_YR, DIV_CD

  -- (4) 가공비 배부방법 확인  ★ 배부기준 코드값이 사이트마다 다르다
     SELECT METHOD_FG, COUNT(*) FROM CIV_CONVCST WHERE CO_CD='1000' GROUP BY METHOD_FG;
     --> 쿼리 E 의 CASE 라벨을 실제 코드 체계에 맞게 수정할 것.

  -- (5) 차수별 원가 총액 추이  ★ 급변하면 배부기준 변경을 의심
     SELECT CHASU, SUM(PRD_AM) 제조원가, SUM(MTL_AM) 재료비, SUM(CONV_AM) 가공비
     FROM   CIV_PRD_TAV WHERE CO_CD='1000' AND P_YR='2026' GROUP BY CHASU ORDER BY CHASU;

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **원가모듈에는 프로젝트 축이 없다.** 프로젝트별 원가가 필요하면
     `PJT_생산원가_보고서.sql` 을 쓸 것. 여기서 프로젝트로 나눌 수 없다.

  2) **미마감 차수의 값은 불완전하다.** 기본값(`@ONLY_CLS='1'`)은 마감 차수만 잡지만,
     `'0'` 으로 바꾸면 미마감도 조회된다. 그 경우 쿼리 B·F·G 의 `상태` 가 '★미마감' 으로
     표시되므로, 그 표시가 있는 결과는 대외 보고에 쓰지 말 것.

  3) **가공비 배부기준이 전차수와 다르면 증감 비교가 무의미하다.** 쿼리 C 의 `주원인` 이
     '가공비'로 몰리면 먼저 쿼리 E 로 배부기준이 바뀌지 않았는지 확인할 것. 이것이
     전차수 대비 분석에서 가장 흔한 착오다.

  4) 본 리포트는 **원가가 왜 그렇게 나왔는지**(표준 대비 차이)를 설명하지 않는다.
     그건 `C04_표준원가_차이분석.sql` 의 수량차이/단가차이 분해가 담당한다.
     C-03 으로 "무엇이 비싼가"를 찾고, C-04 로 "왜 비싼가"를 본다.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   C04_표준원가_차이분석.sql       : 표준 대비 수량차이/단가차이 분해 (왜 비싼가)
   PJT_생산원가_보고서.sql         : 프로젝트별 원가 (원가모듈에 없는 축)
   M05_자재_청구출고사용_현황.sql  : 원가 마감 전 자재 4단계 점검
   C05_매출이익_분석.sql           : 이 원가를 매출에 붙여 이익을 본다
==============================================================================================*/
