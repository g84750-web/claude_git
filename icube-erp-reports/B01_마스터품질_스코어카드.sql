/*==============================================================================================
  [ iCUBE ] B-01  기준정보 마스터 품질 스코어카드                                    (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : KPI·EIS 리포트를 개발하기 **전에** 마스터 등록 상태를 계량화한다.
         등록률이 낮으면 리포트를 만들어도 숫자가 비거나 왜곡되어 아무도 쓰지 않는다.

         "리포트보다 마스터 정비가 먼저"인지 여부를 30초 만에 판정하는 것이 이 쿼리의 목적.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 판정 기준 ]
  ----------------------------------------------------------------------------------------------
     등록률 90% 이상  ->  정상. 리포트 개발 진행
     등록률 70~90%    ->  주의. 미등록 건 목록을 현업에 전달하고 병행 진행
     등록률 70% 미만  ->  **해당 KPI 개발 보류.** 마스터 정비가 선행되어야 함

  ----------------------------------------------------------------------------------------------
  [ 점검 항목 ]
  ----------------------------------------------------------------------------------------------
   A. 품목 마스터    SITEM     조달일수/안전재고/구매단가/최소발주량/표준원가/품목군/단위
   B. 거래처·여신    STRADE / LCR_LIMIT
   C. BOM            SBOM_WF   생산품목 BOM 등록률, 순환참조
   D. 조직·프로젝트  SDEPT / SEMP / SPJT
   E. 코드값 분포    EXPIRE_YN / DOC_ST / SO_FG / RCPAM_FG / ACCT_FG / ODR_FG / PJTCD_TY
   F. 테이블 실존    명세서 누락 테이블 30종
   G. 종합 스코어

  ----------------------------------------------------------------------------------------------
  [ 연계 KPI ]  등록률이 낮으면 아래 리포트가 무의미해진다
  ----------------------------------------------------------------------------------------------
     LEAD_DT       -> P-08 MRP 예정발주일, E-02 리드타임 분석
     SAFESTOCK_QT  -> P-05 안전재고 알람
     PURCH_UM      -> C-01/C-04 표준원가 차이분석
     LOT_QT        -> P-08 MRP 발주권고량
     LCR_LIMIT     -> S-06 여신한도 관리
     SBOM_WF       -> C-01 표준사용량, M-03 자재수율, P-08 총소요량
==============================================================================================*/

SET NOCOUNT ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD   NVARCHAR(4) = N'1000'        -- 회사코드
    ,@DIV_CD  NVARCHAR(4) = NULL           -- 사업장 (NULL = 전체)
    ,@FR_DT   NVARCHAR(8) = N'20260101'    -- 트랜잭션 점검 기간 FROM
    ,@TO_DT   NVARCHAR(8) = N'20261231'    -- 트랜잭션 점검 기간 TO
    ,@TH_OK   DECIMAL(5,1) = 90.0          -- 정상 기준 %
    ,@TH_WARN DECIMAL(5,1) = 70.0          -- 주의 기준 %
;

DECLARE @SQL NVARCHAR(MAX), @YR NVARCHAR(4) = LEFT(@TO_DT, 4);

IF OBJECT_ID('tempdb..#SCORE') IS NOT NULL DROP TABLE #SCORE;
CREATE TABLE #SCORE (
     SEQ      INT IDENTITY
    ,영역     NVARCHAR(20)
    ,항목     NVARCHAR(60)
    ,전체     INT
    ,미등록   INT
    ,연계KPI  NVARCHAR(80)
);


/*==============================================================================================
  A. 품목 마스터 (SITEM)
     원자재·부재료(ACCT_FG '0','1') 와 생산품(제품 '2', 반제품 '4') 를 나눠서 본다.
==============================================================================================*/
-- 구매품 (원재료·부재료) : 조달·발주 관련 필드
INSERT INTO #SCORE (영역, 항목, 전체, 미등록, 연계KPI)
SELECT N'A.품목(구매품)', N'조달일수 LEAD_DT'
      ,COUNT(*), SUM(CASE WHEN ISNULL(I.LEAD_DT,0) = 0 THEN 1 ELSE 0 END)
      ,N'P-08 MRP 예정발주일 / E-02 리드타임'
FROM   SITEM I WITH (NOLOCK)
WHERE  I.CO_CD = @CO_CD AND I.USE_YN = N'1' AND I.ACCT_FG IN (N'0', N'1')
  AND  ISNULL(I.S_CD, N'') <> N'Z00'
UNION ALL
SELECT N'A.품목(구매품)', N'안전재고 SAFESTOCK_QT'
      ,COUNT(*), SUM(CASE WHEN ISNULL(I.SAFESTOCK_QT,0) = 0 THEN 1 ELSE 0 END)
      ,N'P-05 안전재고 알람'
FROM   SITEM I WITH (NOLOCK)
WHERE  I.CO_CD = @CO_CD AND I.USE_YN = N'1' AND I.ACCT_FG IN (N'0', N'1')
  AND  ISNULL(I.S_CD, N'') <> N'Z00'
UNION ALL
SELECT N'A.품목(구매품)', N'구매단가 PURCH_UM'
      ,COUNT(*), SUM(CASE WHEN ISNULL(I.PURCH_UM,0) = 0 THEN 1 ELSE 0 END)
      ,N'C-01/C-04 표준원가 차이분석'
FROM   SITEM I WITH (NOLOCK)
WHERE  I.CO_CD = @CO_CD AND I.USE_YN = N'1' AND I.ACCT_FG IN (N'0', N'1')
  AND  ISNULL(I.S_CD, N'') <> N'Z00'
UNION ALL
SELECT N'A.품목(구매품)', N'최소발주량 LOT_QT'
      ,COUNT(*), SUM(CASE WHEN ISNULL(I.LOT_QT,0) = 0 THEN 1 ELSE 0 END)
      ,N'P-08 MRP 발주권고량 (LOT 절상)'
FROM   SITEM I WITH (NOLOCK)
WHERE  I.CO_CD = @CO_CD AND I.USE_YN = N'1' AND I.ACCT_FG IN (N'0', N'1')
  AND  ISNULL(I.S_CD, N'') <> N'Z00'
UNION ALL
SELECT N'A.품목(구매품)', N'주거래처 TRMAIN_CD'
      ,COUNT(*), SUM(CASE WHEN ISNULL(I.TRMAIN_CD, N'') = N'' THEN 1 ELSE 0 END)
      ,N'P-07 거래처 단가비교 / 발주 자동화'
FROM   SITEM I WITH (NOLOCK)
WHERE  I.CO_CD = @CO_CD AND I.USE_YN = N'1' AND I.ACCT_FG IN (N'0', N'1')
  AND  ISNULL(I.S_CD, N'') <> N'Z00';

-- 생산품 (제품·반제품)
INSERT INTO #SCORE (영역, 항목, 전체, 미등록, 연계KPI)
SELECT N'A.품목(생산품)', N'표준원가 STANDARD_UM'
      ,COUNT(*), SUM(CASE WHEN ISNULL(I.STANDARD_UM,0) = 0 THEN 1 ELSE 0 END)
      ,N'C-03 원가구성 / C-04 차이분석'
FROM   SITEM I WITH (NOLOCK)
WHERE  I.CO_CD = @CO_CD AND I.USE_YN = N'1' AND I.ACCT_FG IN (N'2', N'4')
  AND  ISNULL(I.S_CD, N'') <> N'Z00'
UNION ALL
SELECT N'A.품목(생산품)', N'판매단가 SALE_UM'
      ,COUNT(*), SUM(CASE WHEN ISNULL(I.SALE_UM,0) = 0 THEN 1 ELSE 0 END)
      ,N'S-05 매출이익 분석'
FROM   SITEM I WITH (NOLOCK)
WHERE  I.CO_CD = @CO_CD AND I.USE_YN = N'1' AND I.ACCT_FG = N'2'
  AND  ISNULL(I.S_CD, N'') <> N'Z00';

-- 전 품목 공통
INSERT INTO #SCORE (영역, 항목, 전체, 미등록, 연계KPI)
SELECT N'A.품목(전체)', N'품목군 ITEMGRP_CD'
      ,COUNT(*), SUM(CASE WHEN ISNULL(I.ITEMGRP_CD, N'') = N'' THEN 1 ELSE 0 END)
      ,N'S-10 판매추이 / P-06 ABC 분석'
FROM   SITEM I WITH (NOLOCK)
WHERE  I.CO_CD = @CO_CD AND I.USE_YN = N'1' AND ISNULL(I.S_CD, N'') <> N'Z00'
UNION ALL
SELECT N'A.품목(전체)', N'재고단위 UNIT_DC'
      ,COUNT(*), SUM(CASE WHEN ISNULL(I.UNIT_DC, N'') = N'' THEN 1 ELSE 0 END)
      ,N'전 수량 리포트'
FROM   SITEM I WITH (NOLOCK)
WHERE  I.CO_CD = @CO_CD AND I.USE_YN = N'1' AND ISNULL(I.S_CD, N'') <> N'Z00'
UNION ALL
SELECT N'A.품목(전체)', N'계정구분 ACCT_FG'
      ,COUNT(*), SUM(CASE WHEN ISNULL(I.ACCT_FG, N'') NOT IN (N'0',N'1',N'2',N'4',N'5',N'6') THEN 1 ELSE 0 END)
      ,N'원가대상 판정 전반'
FROM   SITEM I WITH (NOLOCK)
WHERE  I.CO_CD = @CO_CD AND I.USE_YN = N'1' AND ISNULL(I.S_CD, N'') <> N'Z00'
UNION ALL
SELECT N'A.품목(전체)', N'조달구분 ODR_FG'
      ,COUNT(*), SUM(CASE WHEN ISNULL(I.ODR_FG, N'') NOT IN (N'0', N'1') THEN 1 ELSE 0 END)
      ,N'P-08 MRP 구매/생산 분기'
FROM   SITEM I WITH (NOLOCK)
WHERE  I.CO_CD = @CO_CD AND I.USE_YN = N'1' AND ISNULL(I.S_CD, N'') <> N'Z00';


/*==============================================================================================
  B. 거래처 · 여신한도
==============================================================================================*/
INSERT INTO #SCORE (영역, 항목, 전체, 미등록, 연계KPI)
SELECT N'B.거래처', N'거래처명 TR_NM'
      ,COUNT(*), SUM(CASE WHEN ISNULL(T.TR_NM, N'') = N'' THEN 1 ELSE 0 END), N'전 영업/구매 리포트'
FROM   STRADE T WITH (NOLOCK) WHERE T.CO_CD = @CO_CD AND ISNULL(T.USE_YN, N'1') = N'1'
UNION ALL
SELECT N'B.거래처', N'사업자등록번호 REG_NB'
      ,COUNT(*), SUM(CASE WHEN ISNULL(T.REG_NB, N'') = N'' THEN 1 ELSE 0 END), N'세금계산서 / 전자세금'
FROM   STRADE T WITH (NOLOCK) WHERE T.CO_CD = @CO_CD AND ISNULL(T.USE_YN, N'1') = N'1';

-- 여신한도 : 전용 테이블 LCR_LIMIT 우선, 없으면 STRADE.CREDIT_AM
IF OBJECT_ID(N'dbo.LCR_LIMIT', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
      INSERT INTO #SCORE (영역, 항목, 전체, 미등록, 연계KPI)
      SELECT N''B.여신'', N''여신한도 LCR_LIMIT.YUSIN_AM''
            ,(SELECT COUNT(*) FROM STRADE WITH (NOLOCK) WHERE CO_CD=@p_CO AND ISNULL(USE_YN,N''1'')=N''1'' AND TR_FG IN (N''0'',N''2''))
            ,(SELECT COUNT(*) FROM STRADE S WITH (NOLOCK) WHERE S.CO_CD=@p_CO AND ISNULL(S.USE_YN,N''1'')=N''1'' AND S.TR_FG IN (N''0'',N''2'')
               AND NOT EXISTS (SELECT 1 FROM dbo.LCR_LIMIT L WITH (NOLOCK)
                               WHERE L.CO_CD=S.CO_CD AND L.TR_CD=S.TR_CD
                                 AND ISNULL(L.YUSIN_AM,0) > 0
                                 AND (@p_DIV IS NULL OR L.DIV_CD=@p_DIV)))
            ,N''S-06 여신한도 관리 / S-01 여신상태''';
    EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4)', @p_CO=@CO_CD, @p_DIV=@DIV_CD;
END
ELSE
BEGIN
    INSERT INTO #SCORE (영역, 항목, 전체, 미등록, 연계KPI)
    SELECT N'B.여신', N'여신한도 STRADE.CREDIT_AM (LCR_LIMIT 없음)'
          ,COUNT(*), SUM(CASE WHEN ISNULL(T.CREDIT_AM,0) = 0 THEN 1 ELSE 0 END)
          ,N'S-06 여신한도 관리'
    FROM   STRADE T WITH (NOLOCK)
    WHERE  T.CO_CD = @CO_CD AND ISNULL(T.USE_YN, N'1') = N'1' AND T.TR_FG IN (N'0', N'2');
END


/*==============================================================================================
  C. BOM 등록률
     기간 내 작업지시가 발생한 생산품목 중 BOM 이 없는 비율
==============================================================================================*/
DECLARE @BOM_TB SYSNAME =
        CASE WHEN OBJECT_ID(N'dbo.SBOM_WF', N'U') IS NOT NULL THEN N'SBOM_WF'
             WHEN OBJECT_ID(N'dbo.SBOM'   , N'U') IS NOT NULL THEN N'SBOM'
             ELSE NULL END;

IF @BOM_TB IS NOT NULL
BEGIN
    SET @SQL = N'
      INSERT INTO #SCORE (영역, 항목, 전체, 미등록, 연계KPI)
      SELECT N''C.BOM'', N''지시품목 BOM 등록 (' + @BOM_TB + N')''
            ,COUNT(DISTINCT W.ITEM_CD)
            ,COUNT(DISTINCT CASE WHEN NOT EXISTS (
                 SELECT 1 FROM dbo.' + QUOTENAME(@BOM_TB) + N' B
                 WHERE B.CO_CD = W.CO_CD AND B.ITEMPARENT_CD = W.ITEM_CD AND B.USE_YN = N''1'')
                 THEN W.ITEM_CD END)
            ,N''C-01 표준사용량 / M-03 자재수율 / P-08 총소요량''
      FROM   LWO_WF W WITH (NOLOCK)
      WHERE  W.CO_CD = @p_CO AND W.USE_YN = N''1''
        AND  W.ORD_DT BETWEEN @p_FR AND @p_TO
        AND  (@p_DIV IS NULL OR W.DIV_CD = @p_DIV)';
    EXEC sp_executesql @SQL
        ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_FR NVARCHAR(8), @p_TO NVARCHAR(8)'
        ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_FR=@FR_DT, @p_TO=@TO_DT;

    -- 수주품목 BOM (MRP 전개 대상)
    SET @SQL = N'
      INSERT INTO #SCORE (영역, 항목, 전체, 미등록, 연계KPI)
      SELECT N''C.BOM'', N''수주품목 BOM 등록''
            ,COUNT(DISTINCT D.ITEM_CD)
            ,COUNT(DISTINCT CASE WHEN NOT EXISTS (
                 SELECT 1 FROM dbo.' + QUOTENAME(@BOM_TB) + N' B
                 WHERE B.CO_CD = D.CO_CD AND B.ITEMPARENT_CD = D.ITEM_CD AND B.USE_YN = N''1'')
                 THEN D.ITEM_CD END)
            ,N''P-08 MRP 총소요량 전개''
      FROM   LSO H WITH (NOLOCK)
      INNER JOIN LSO_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.SO_NB = H.SO_NB
      WHERE  H.CO_CD = @p_CO AND ISNULL(D.USE_YN, N''1'') = N''1''
        AND  D.DUE_DT BETWEEN @p_FR AND @p_TO
        AND  (@p_DIV IS NULL OR H.DIV_CD = @p_DIV)';
    EXEC sp_executesql @SQL
        ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_FR NVARCHAR(8), @p_TO NVARCHAR(8)'
        ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_FR=@FR_DT, @p_TO=@TO_DT;
END


/*==============================================================================================
  D. 조직 · 프로젝트
==============================================================================================*/
INSERT INTO #SCORE (영역, 항목, 전체, 미등록, 연계KPI)
SELECT N'D.조직', N'부서명 DEPT_NM'
      ,COUNT(*), SUM(CASE WHEN ISNULL(D.DEPT_NM, N'') = N'' THEN 1 ELSE 0 END), N'부서별 전 리포트'
FROM   SDEPT D WITH (NOLOCK) WHERE D.CO_CD = @CO_CD
UNION ALL
SELECT N'D.조직', N'사원명 KOR_NM'
      ,COUNT(*), SUM(CASE WHEN ISNULL(E.KOR_NM, N'') = N'' THEN 1 ELSE 0 END), N'담당자별 전 리포트'
FROM   SEMP E WITH (NOLOCK) WHERE E.CO_CD = @CO_CD
UNION ALL
SELECT N'D.프로젝트', N'프로젝트명 PJT_NM'
      ,COUNT(*), SUM(CASE WHEN ISNULL(P.PJT_NM, N'') = N'' THEN 1 ELSE 0 END), N'C-01 프로젝트별 원가'
FROM   SPJT P WITH (NOLOCK) WHERE P.CO_CD = @CO_CD
UNION ALL
SELECT N'D.프로젝트', N'프로젝트분류 PJTGRP_CD'
      ,COUNT(*), SUM(CASE WHEN ISNULL(P.PJTGRP_CD, N'') = N'' THEN 1 ELSE 0 END), N'C-01 분류별 집계'
FROM   SPJT P WITH (NOLOCK) WHERE P.CO_CD = @CO_CD;

-- 트랜잭션의 프로젝트 부여율 (프로젝트별 원가의 전제)
INSERT INTO #SCORE (영역, 항목, 전체, 미등록, 연계KPI)
SELECT N'D.프로젝트', N'생산실적 PJT_CD 부여'
      ,COUNT(*)
      ,SUM(CASE WHEN ISNULL(NULLIF(H.PJT_CD, N''), W.PJT_CD) IS NULL THEN 1 ELSE 0 END)
      ,N'C-01 프로젝트별 생산원가'
FROM        LORCV_H H WITH (NOLOCK)
LEFT  JOIN  LWO_WF  W WITH (NOLOCK) ON W.CO_CD = H.CO_CD AND W.WO_CD = H.WO_CD
WHERE  H.CO_CD = @CO_CD AND H.USE_YN = N'1' AND H.EXPIRE_YN = N'1'
  AND  H.DOC_DT BETWEEN @FR_DT AND @TO_DT
  AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
UNION ALL
SELECT N'D.수주연결', N'작업지시 SO_NB 연결'
      ,COUNT(*), SUM(CASE WHEN ISNULL(W.SO_NB, N'') = N'' THEN 1 ELSE 0 END)
      ,N'S-01 수주진행총괄 (②~⑦ 단계)'
FROM   LWO_WF W WITH (NOLOCK)
WHERE  W.CO_CD = @CO_CD AND W.USE_YN = N'1'
  AND  W.ORD_DT BETWEEN @FR_DT AND @TO_DT
  AND  (@DIV_CD IS NULL OR W.DIV_CD = @DIV_CD)
UNION ALL
SELECT N'D.수금연결', N'수금 ISU_NB(출고) 연결'
      ,COUNT(*), SUM(CASE WHEN ISNULL(D.ISU_NB, N'') = N'' THEN 1 ELSE 0 END)
      ,N'S-01 수주단위 채권추적'
FROM        LRCP   H WITH (NOLOCK)
INNER JOIN  LRCP_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.RCP_NB = H.RCP_NB
WHERE  H.CO_CD = @CO_CD AND ISNULL(D.USE_YN, N'1') = N'1'
  AND  H.RCP_DT BETWEEN @FR_DT AND @TO_DT
  AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD);


/*==============================================================================================
  ** 쿼리 A : 마스터 품질 스코어카드 (메인)
==============================================================================================*/
SELECT
     N'[A] 마스터 품질 스코어카드'                  AS REPORT_NM
    ,S.영역
    ,S.항목
    ,S.전체                                         AS 전체건수
    ,S.전체 - S.미등록                              AS 등록건수
    ,S.미등록                                       AS 미등록건수
    ,등록률_PCT = CAST(CASE WHEN S.전체 <> 0
                            THEN 100.0 * (S.전체 - S.미등록) / S.전체 END AS DECIMAL(5,1))
    ,판정 = CASE WHEN S.전체 = 0 THEN N'-데이터없음'
                 WHEN 100.0*(S.전체-S.미등록)/S.전체 >= @TH_OK   THEN N'1.정상'
                 WHEN 100.0*(S.전체-S.미등록)/S.전체 >= @TH_WARN THEN N'2.주의'
                 ELSE N'3.★개발보류 (마스터 정비 선행)' END
    ,S.연계KPI
FROM   #SCORE S
ORDER BY CASE WHEN S.전체 = 0 THEN 9
              WHEN 100.0*(S.전체-S.미등록)/S.전체 >= @TH_OK THEN 3
              WHEN 100.0*(S.전체-S.미등록)/S.전체 >= @TH_WARN THEN 2
              ELSE 1 END
        ,S.영역, S.SEQ
;


/*==============================================================================================
  ** 쿼리 B : 영역별 종합 (경영 보고용)
==============================================================================================*/
SELECT
     N'[B] 영역별 종합'                             AS REPORT_NM
    ,S.영역
    ,COUNT(*)                                       AS 점검항목수
    ,SUM(CASE WHEN S.전체 <> 0 AND 100.0*(S.전체-S.미등록)/S.전체 >= @TH_OK   THEN 1 ELSE 0 END) AS 정상
    ,SUM(CASE WHEN S.전체 <> 0 AND 100.0*(S.전체-S.미등록)/S.전체 <  @TH_OK
                             AND 100.0*(S.전체-S.미등록)/S.전체 >= @TH_WARN THEN 1 ELSE 0 END) AS 주의
    ,SUM(CASE WHEN S.전체 <> 0 AND 100.0*(S.전체-S.미등록)/S.전체 <  @TH_WARN THEN 1 ELSE 0 END) AS 보류
    ,평균등록률_PCT = CAST(AVG(CASE WHEN S.전체 <> 0
                                    THEN 100.0*(S.전체-S.미등록)/S.전체 END) AS DECIMAL(5,1))
FROM   #SCORE S
GROUP BY S.영역
ORDER BY 평균등록률_PCT
;


/*==============================================================================================
  ** 쿼리 C : 코드값 실제 분포  ★ 리포트 조건절 확정용
==============================================================================================*/
SELECT N'[C] 코드값 분포' AS REPORT_NM, N'LORCV_H.EXPIRE_YN' AS 대상, EXPIRE_YN AS 값
      ,COUNT(*) AS 건수, N'1=유효가 다수여야 정상' AS 기대
FROM   LORCV_H WITH (NOLOCK)
WHERE  CO_CD = @CO_CD AND DOC_DT BETWEEN @FR_DT AND @TO_DT
GROUP BY EXPIRE_YN
UNION ALL
SELECT N'[C] 코드값 분포', N'LSO_D.EXPIRE_YN', EXPIRE_YN, COUNT(*), N'1=진행, 0=마감'
FROM   LSO_D WITH (NOLOCK) WHERE CO_CD = @CO_CD GROUP BY EXPIRE_YN
UNION ALL
SELECT N'[C] 코드값 분포', N'LPO_D.EXPIRE_YN', EXPIRE_YN, COUNT(*), N'1=진행, 0=마감'
FROM   LPO_D WITH (NOLOCK) WHERE CO_CD = @CO_CD GROUP BY EXPIRE_YN
UNION ALL
SELECT N'[C] 코드값 분포', N'LWO_WF.DOC_ST', DOC_ST, COUNT(*), N'API:0미처리/1처리 vs UDR:0계획/1확정/2마감'
FROM   LWO_WF WITH (NOLOCK)
WHERE  CO_CD = @CO_CD AND ORD_DT BETWEEN @FR_DT AND @TO_DT GROUP BY DOC_ST
UNION ALL
SELECT N'[C] 코드값 분포', N'LORCV_H.BAD_YN', BAD_YN, COUNT(*), N'0적합/1부적합. 전부 0이면 불량 미구분'
FROM   LORCV_H WITH (NOLOCK)
WHERE  CO_CD = @CO_CD AND DOC_DT BETWEEN @FR_DT AND @TO_DT GROUP BY BAD_YN
UNION ALL
SELECT N'[C] 코드값 분포', N'LORCV_H.SUB_TP', SUB_TP, COUNT(*), N'0주산물/1부산물'
FROM   LORCV_H WITH (NOLOCK)
WHERE  CO_CD = @CO_CD AND DOC_DT BETWEEN @FR_DT AND @TO_DT GROUP BY SUB_TP
UNION ALL
SELECT N'[C] 코드값 분포', N'LORCV_H.REWORK_YN', REWORK_YN, COUNT(*), N'0정상/1재작업. 전부 0이면 직행률=양품률'
FROM   LORCV_H WITH (NOLOCK)
WHERE  CO_CD = @CO_CD AND DOC_DT BETWEEN @FR_DT AND @TO_DT GROUP BY REWORK_YN
UNION ALL
SELECT N'[C] 코드값 분포', N'LDELIVER.SO_FG', SO_FG, COUNT(*), N'채권대상은 0,2,7'
FROM   LDELIVER WITH (NOLOCK)
WHERE  CO_CD = @CO_CD AND ISU_DT BETWEEN @FR_DT AND @TO_DT GROUP BY SO_FG
UNION ALL
SELECT N'[C] 코드값 분포', N'LRCP_D.RCPAM_FG', RCPAM_FG, COUNT(*), N'0=영업모듈 수금만 채권 대상'
FROM   LRCP_D WITH (NOLOCK) WHERE CO_CD = @CO_CD GROUP BY RCPAM_FG
UNION ALL
SELECT N'[C] 코드값 분포', N'SITEM.ACCT_FG', ACCT_FG, COUNT(*), N'0원재료1부재료2제품4반제품5상품'
FROM   SITEM WITH (NOLOCK) WHERE CO_CD = @CO_CD AND USE_YN = N'1' GROUP BY ACCT_FG
UNION ALL
SELECT N'[C] 코드값 분포', N'SITEM.ODR_FG', ODR_FG, COUNT(*), N'0구매/1생산'
FROM   SITEM WITH (NOLOCK) WHERE CO_CD = @CO_CD AND USE_YN = N'1' GROUP BY ODR_FG
UNION ALL
SELECT N'[C] 코드값 분포', N'ADOCUD.PJTCD_TY', PJTCD_TY, COUNT(*), N'★D1=프로젝트/D4=사원. 혼재 시 조건 필수'
FROM   ADOCUD WITH (NOLOCK)
WHERE  CO_CD = @CO_CD AND ISU_DT BETWEEN @FR_DT AND @TO_DT AND ISNULL(PJT_CD, N'') <> N''
GROUP BY PJTCD_TY
ORDER BY 대상, 값
;


/*==============================================================================================
  ** 쿼리 D : 테이블 실존 확인  ★ 명세서 누락 30종
==============================================================================================*/
;WITH T (구분, 테이블, 용도) AS (
    SELECT N'재고', N'LINVTORY',        N'창고 재고수불부 (평가 전)'         UNION ALL
    SELECT N'재고', N'LINVTORY_D',      N'창고+실적입고 통합'                UNION ALL
    SELECT N'재고', N'LINV_WIP',        N'재공수불부'                        UNION ALL
    SELECT N'재고', N'LINV_MVFIFO',     N'재고자산수불부 (평가 후)'          UNION ALL
    SELECT N'재고', N'LINV_MVFIFO_WK',  N'평가 작업본 (*_AM_GAP)'            UNION ALL
    SELECT N'재고', N'LINV_TAV',        N'기간 재고평가 (GISU 키)'           UNION ALL
    SELECT N'재고', N'LX_LINVTORY',     N'재고조정+실수불 (창고/장소)'       UNION ALL
    SELECT N'재고', N'L_INVSUM_LC',     N'집계 (GRP_FG 포함)'                UNION ALL
    SELECT N'재고', N'LWIPIO',          N'재공처리'                          UNION ALL
    SELECT N'재고', N'LSTKMOVE',        N'생산자재출고 헤더'                 UNION ALL
    SELECT N'재고', N'LSTKMOVE_D',      N'생산자재출고 디테일'               UNION ALL
    SELECT N'생산', N'LWO_REQ_WF',      N'★작업지시 소요자재(청구)'          UNION ALL
    SELECT N'생산', N'LPRODUCTION',     N'일괄생산실적 헤더'                 UNION ALL
    SELECT N'생산', N'LOCLS_H',         N'외주마감 헤더'                     UNION ALL
    SELECT N'생산', N'LOCLS_D',         N'외주마감 디테일'                   UNION ALL
    SELECT N'생산', N'SBOM_WF',         N'★BOM'                              UNION ALL
    SELECT N'생산', N'SBOM_WF_B',       N'BATCH BOM'                         UNION ALL
    SELECT N'생산', N'LBAD',            N'불량유형'                          UNION ALL
    SELECT N'생산', N'LBADGRP',         N'불량그룹'                          UNION ALL
    SELECT N'영업', N'LOPN_CRISU_CLS',  N'★기초채권 (마감기준)'              UNION ALL
    SELECT N'영업', N'LOPN_PAY',        N'기초채무'                          UNION ALL
    SELECT N'영업', N'LCR_LIMIT',       N'★여신한도등록'                     UNION ALL
    SELECT N'영업', N'LEBL',            N'수출선적'                          UNION ALL
    SELECT N'영업', N'LEBL_D',          N'수출선적 디테일'                   UNION ALL
    SELECT N'영업', N'LTRADEMGM',       N'물류실적담당자'                    UNION ALL
    SELECT N'영업', N'LPLNNERCD',       N'실적담당자 명칭'                   UNION ALL
    SELECT N'영업', N'LCUSTM_UM',       N'거래처별 단가 (NO_SQ=999)'         UNION ALL
    SELECT N'구매', N'LPO',             N'발주 헤더'                         UNION ALL
    SELECT N'구매', N'LPURCLS',         N'매입마감 헤더'                     UNION ALL
    SELECT N'기준', N'LCTRL_MGM_D',     N'관리내역 (CTRL_CD)'                UNION ALL
    SELECT N'원가', N'CIV_CHASU',       N'원가계산 차수'                     UNION ALL
    SELECT N'원가', N'CIV_TAV',         N'경리수불집계'                      UNION ALL
    SELECT N'원가', N'CIV_PUR_TAV',     N'★재료비 출고단가'                  UNION ALL
    SELECT N'원가', N'CIV_PRD_TAV',     N'당기 제조원가분석'                 UNION ALL
    SELECT N'원가', N'CIV_PRD_TAV_D',   N'당기 재료비분석'                   UNION ALL
    SELECT N'원가', N'CIV_LBR_AM',      N'당기 외주비'                       UNION ALL
    SELECT N'집계', N'LX_WH_W',         N'공정별 현재공 집계'                UNION ALL
    SELECT N'집계', N'LX_LC_W',         N'작업장별 현재공 집계'              UNION ALL
    SELECT N'집계', N'LX_PJT_W',        N'프로젝트별 현재공 집계'
)
SELECT
     N'[D] 테이블 실존 확인'                        AS REPORT_NM
    ,T.구분, T.테이블, T.용도
    ,존재 = CASE WHEN O.object_id IS NOT NULL THEN N'O' ELSE N'X' END
    ,종류 = CASE O.type WHEN N'U' THEN N'테이블' WHEN N'V' THEN N'뷰' END
FROM        T
LEFT  JOIN  sys.objects O ON O.name = T.테이블 AND O.type IN (N'U', N'V')
ORDER BY 존재, T.구분, T.테이블
;


/*==============================================================================================
  ** 쿼리 E : 제공 뷰 확인  (있으면 원장 직접집계보다 우선 사용)
==============================================================================================*/
SELECT
     N'[E] 제공 뷰 확인'                            AS REPORT_NM
    ,V.name                                         AS 뷰명
    ,V.create_date                                  AS 생성일
FROM   sys.views V
WHERE  V.name LIKE N'VL\_%' ESCAPE N'\'
   OR  V.name LIKE N'VC\_%' ESCAPE N'\'
   OR  V.name LIKE N'CX\_%' ESCAPE N'\'
ORDER BY V.name
;


/*==============================================================================================
  ** 쿼리 F : 미등록 상세 (조치 대상 리스트) — 등록률 낮은 항목의 실제 품목
==============================================================================================*/
SELECT TOP 200
     N'[F] 미등록 품목 상세'                        AS REPORT_NM
    ,I.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.ITEM_DC                                      AS 규격
    ,I.ACCT_FG                                      AS 계정구분
    ,I.UNIT_DC                                      AS 단위
    ,I.ITEMGRP_CD                                   AS 품목군
    ,CASE WHEN ISNULL(I.LEAD_DT,0)      = 0 THEN N'X' ELSE N'O' END AS 조달일수
    ,CASE WHEN ISNULL(I.SAFESTOCK_QT,0) = 0 THEN N'X' ELSE N'O' END AS 안전재고
    ,CASE WHEN ISNULL(I.PURCH_UM,0)     = 0 THEN N'X' ELSE N'O' END AS 구매단가
    ,CASE WHEN ISNULL(I.LOT_QT,0)       = 0 THEN N'X' ELSE N'O' END AS 최소발주량
    ,CASE WHEN ISNULL(I.TRMAIN_CD,N'')  = N'' THEN N'X' ELSE N'O' END AS 주거래처
    ,미등록항목수 = CASE WHEN ISNULL(I.LEAD_DT,0)=0      THEN 1 ELSE 0 END
                  + CASE WHEN ISNULL(I.SAFESTOCK_QT,0)=0 THEN 1 ELSE 0 END
                  + CASE WHEN ISNULL(I.PURCH_UM,0)=0     THEN 1 ELSE 0 END
                  + CASE WHEN ISNULL(I.LOT_QT,0)=0       THEN 1 ELSE 0 END
                  + CASE WHEN ISNULL(I.TRMAIN_CD,N'')=N'' THEN 1 ELSE 0 END
    ,최근사용일 = (SELECT MAX(U.USE_DT) FROM LMTL_USE U WITH (NOLOCK)
                   WHERE U.CO_CD = I.CO_CD AND U.ITEM_CD = I.ITEM_CD)
FROM   SITEM I WITH (NOLOCK)
WHERE  I.CO_CD = @CO_CD AND I.USE_YN = N'1'
  AND  I.ACCT_FG IN (N'0', N'1')
  AND  ISNULL(I.S_CD, N'') <> N'Z00'
  AND  (   ISNULL(I.LEAD_DT,0) = 0 OR ISNULL(I.SAFESTOCK_QT,0) = 0
        OR ISNULL(I.PURCH_UM,0) = 0 OR ISNULL(I.LOT_QT,0) = 0
        OR ISNULL(I.TRMAIN_CD,N'') = N'' )
ORDER BY 미등록항목수 DESC, 최근사용일 DESC
;


DROP TABLE #SCORE;
GO


/*==============================================================================================
  [ 활용 ]
  ----------------------------------------------------------------------------------------------
  1) **리포트 개발 착수 전 필수 실행.** 쿼리 A 의 '3.★개발보류' 항목에 걸린 KPI 는
     만들어도 숫자가 비거나 왜곡되므로 마스터 정비를 먼저 요청한다.

  2) 쿼리 F 는 **조치 대상 리스트**다. `미등록항목수` 내림차순 + `최근사용일` 내림차순이므로
     상단 품목부터 정비하면 가장 빨리 등록률이 올라간다. 최근 사용이 없는 품목은
     실질적으로 단종이므로 `S_CD='Z00'` 처리를 검토한다.

  3) 쿼리 C 의 결과로 각 리포트의 조건절을 확정한다.
     - `BAD_YN`/`REWORK_YN` 이 전부 '0' 이면 불량·재작업을 실적에 구분 입력하지 않는 사이트다.
       이 경우 M-03 양품률·직행률은 항상 100% 가 되므로 `LQC_INSP`(검사) 기준으로 대체한다.
     - `DOC_ST` 가 0/1 만 있으면 API 체계(0미처리/1처리), 0/1/2 면 UDR 체계(계획/확정/마감)다.
     - `PJTCD_TY` 에 'D4' 가 있으면 회계 프로젝트 집계에 `='D1'` 조건이 **반드시** 필요하다.

  4) 쿼리 D/E 로 확인된 미존재 테이블은 관련 리포트에서 해당 블록을 제거하거나
     `OBJECT_ID` 가드를 유지한 채 대체 경로를 쓴다.

  [ 정기 운영 ]
  ----------------------------------------------------------------------------------------------
  월 1회 실행하여 영역별 평균등록률(쿼리 B)을 추이로 관리하는 것을 권장한다.
  등록률이 떨어지면 신규 품목·거래처 등록 프로세스에 누락이 생긴 것이다.

  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------

  -- (1) 모수가 유의미한지 먼저 본다. 건수가 적으면 등록률 %는 의미가 없다
     SELECT N'품목' 구분, COUNT(*) FROM SITEM  WHERE CO_CD='1000'
     UNION ALL SELECT N'거래처', COUNT(*) FROM STRADE WHERE CO_CD='1000';

  -- (2) 등록률의 분모에 단종품을 넣을지 결정한다
     SELECT S_CD, COUNT(*) FROM SITEM WHERE CO_CD='1000' GROUP BY S_CD ORDER BY 2 DESC;
     --> 'Z00'(단종)이 많으면 분모에서 빼야 등록률이 현실을 반영한다.

  -- (3) 코드값 전제 실측  ★ 쿼리 E 와 같은 내용. 여기서 어긋나면 전 파일을 고쳐야 한다
     SELECT EXPIRE_YN, COUNT(*) FROM LSO_D WHERE CO_CD='1000' GROUP BY EXPIRE_YN;
     --> '1' 이 압도적으로 많고 진행 건이면 전제가 맞다. 반대면 CLAUDE.md 2장부터 고칠 것.

  -- (4) 명세서 누락 테이블 실존 여부는 쿼리 F 가 판정한다. 'X' 가 많으면 해당 KPI 는 보류.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------

  1) **"값이 채워졌는가"만 본다. 값이 맞는지는 모른다.** 조달일수가 전 품목 `1` 로 일괄
     입력된 사이트도 등록률 100%로 나온다. 등록률이 높다고 품질이 좋은 것은 아니다.

  2) **90 / 70% 임계치는 일반 기준**이다. 품목 수가 적거나 수기 관리 비중이 큰 사이트에서는
     기준을 낮춰야 현실적이다.

  3) **BOM 점검은 `SBOM_WF` 기준**이다. BATCH BOM(`SBOM_WF_B`)을 쓰는 품목은 일반 BOM 이
     없어 미등록으로 잡힐 수 있다. M-10 의 BATCH BOM 정합성 점검과 함께 볼 것.

  4) **`SDEPT` 에는 `USE_YN` 이 없다.** 유효성은 `REG_DT`/`TO_DT` 로 판단하므로 기준일을
     무엇으로 두느냐에 따라 부서 등록률이 달라진다.

==============================================================================================*/
