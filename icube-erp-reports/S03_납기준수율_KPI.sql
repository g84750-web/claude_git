/*==============================================================================================
  [ iCUBE ] S-03  납기 준수율 KPI                                                    (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 고객에게 약속한 납기를 지켰는가. 영업·생산 공통 최상위 KPI.
         수량기준·건수기준을 함께 내고, 지연 건은 거래처/품목/담당자 축으로 분해한다.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 산식 ]
  ----------------------------------------------------------------------------------------------
     지연일수   = DATEDIFF(DAY, LSO_D.DUE_DT, 최종출고일)
     지연플래그 = CASE WHEN 지연일수 > 0 THEN 1 ELSE 0 END          ← ★ 보정

     납기준수율(수량) = (1 - SUM(지연수량) / SUM(주문량)) * 100
     납기준수율(건수) = COUNT(지연플래그=0) / COUNT(*) * 100
     평균지연일       = AVG(CASE WHEN 지연일수 > 0 THEN 지연일수 END)

  ----------------------------------------------------------------------------------------------
  [ ★ 참조 쿼리의 결함 두 가지를 고쳤다 ]
  ----------------------------------------------------------------------------------------------
   1. **조기납품이 지연으로 계산되던 문제.**
      원본은 `CASE DATEDIFF(...) WHEN '0' THEN '0' ELSE '1'` 이라 납기보다 **이른** 출고
      (음수)까지 지연으로 셌다. `> 0` 으로 바꿔야 정상이다. 조기납품은 쿼리 H 에서 따로 본다.

   2. **미납 건이 분모에 섞이던 문제.**
      아직 출고가 안 끝난 건(`SO_QT - ISU_QT <> 0`)을 포함하면 분모가 왜곡된다.
      **완결 건만** 대상으로 한다 (`@ONLY_CLOSED='1'`, 기본값).

  ----------------------------------------------------------------------------------------------
  [ 그 외 전제 ]
  ----------------------------------------------------------------------------------------------
   · 분할출고 시 **최종 출고일(MAX(ISU_DT)) 기준**이 실무 정의다. 첫 출고 기준 평가가
     필요하면 @BASE_ISU='F' 로 바꾼다.
   · 납기 변경 이력은 추적하지 않는다. `DUE_DT` 는 **현재 납기**다 (아래 [한계] 1 참조).
   · `EXPIRE_YN='1'` 이 진행/유효. 반대로 걸면 결과가 비어버린다.
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터   ─ 목표선은 EIS 기본값(95%)을 채웠다. 고객사 기준이 정해지면 여기만 바꾼다.
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@FR_DT    NVARCHAR(8)  = N'20260101'     -- 납기일 기준 기간 FROM
    ,@TO_DT    NVARCHAR(8)  = N'20261231'
    ,@TR_CD    NVARCHAR(10) = NULL
    ,@ITEM_CD  NVARCHAR(25) = NULL
    ,@EMP_CD   NVARCHAR(10) = NULL            -- 영업담당
    ,@PJT_CD   NVARCHAR(10) = NULL

    ,@TARGET   DECIMAL(5,1) = 95.0            -- ★ 목표 납기준수율 (%)  [EIS 기본값]
    ,@TOL_DAY  INT          = 0               -- 허용 지연일 (0 = 하루라도 늦으면 지연)
    ,@EARLY_DAY INT         = 7               -- 조기납품 경고 기준일 (쿼리 H)
    ,@ONLY_CLOSED NCHAR(1)  = N'1'            -- 1 = 완결 건만 (★ 기본값)
    ,@BASE_ISU NCHAR(1)     = N'L'            -- L 최종출고일 / F 최초출고일
    ,@EXC_RTN  NCHAR(1)     = N'1'            -- 반품(음수 수주) 제외
;

IF OBJECT_ID('tempdb..#DUE') IS NOT NULL DROP TABLE #DUE;


/*==============================================================================================
  1. #DUE : 수주 라인 + 출고 실적 + 지연 판정
==============================================================================================*/
SELECT
     H.SO_NB
    ,D.SO_SQ
    ,H.SO_DT
    ,D.DUE_DT
    ,H.TR_CD
    ,EMP_CD  = ISNULL(NULLIF(D.EMP_CD, N''), H.EMP_CD)
    ,PJT_CD  = ISNULL(NULLIF(D.PJT_CD, N''), H.PJT_CD)
    ,D.ITEM_CD
    ,SO_QT   = CAST(ISNULL(D.SO_QT , 0) AS DECIMAL(19,6))
    ,ISU_QT  = CAST(ISNULL(D.ISU_QT, 0) AS DECIMAL(19,6))
    ,BAL_QT  = CAST(ISNULL(D.SO_QT,0) - ISNULL(D.ISU_QT,0) AS DECIMAL(19,6))
    ,SO_AM   = CAST(ISNULL(D.SO_AM , 0) AS DECIMAL(19,4))
    ,V.FIRST_DT
    ,V.LAST_DT
    ,V.DLV_CNT
    -- 평가 기준 출고일
    ,CHK_DT  = CASE @BASE_ISU WHEN N'F' THEN V.FIRST_DT ELSE V.LAST_DT END
    -- 지연일수 (양수 = 지연, 음수 = 조기)
    ,DELAY   = DATEDIFF(DAY, CONVERT(DATE, D.DUE_DT),
                        CONVERT(DATE, CASE @BASE_ISU WHEN N'F' THEN V.FIRST_DT ELSE V.LAST_DT END))
    ,CLOSED  = CASE WHEN ISNULL(D.SO_QT,0) - ISNULL(D.ISU_QT,0) = 0 THEN N'1' ELSE N'0' END
INTO #DUE
FROM       LSO   H WITH (NOLOCK)
INNER JOIN LSO_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.SO_NB = H.SO_NB
OUTER APPLY (
    SELECT
         FIRST_DT = MIN(X.ISU_DT)
        ,LAST_DT  = MAX(X.ISU_DT)
        ,DLV_CNT  = COUNT(*)
    FROM       LDELIVER   X WITH (NOLOCK)
    INNER JOIN LDELIVER_D Y WITH (NOLOCK) ON Y.CO_CD = X.CO_CD AND Y.ISU_NB = X.ISU_NB
    WHERE  Y.CO_CD = D.CO_CD AND Y.SO_NB = D.SO_NB AND Y.SO_SQ = D.SO_SQ
      AND  ISNULL(Y.USE_YN, N'1') = N'1' AND ISNULL(Y.EXPIRE_YN, N'1') = N'1'
) V
WHERE  H.CO_CD  = @CO_CD
  AND  D.DUE_DT BETWEEN @FR_DT AND @TO_DT                   -- ★ 납기일 기준 기간
  AND  ISNULL(D.USE_YN, N'1') = N'1'
  AND  ISNULL(D.DUE_DT, N'') <> N''                         -- 납기 미등록 건은 평가 불가
  AND  (@DIV_CD  IS NULL OR H.DIV_CD  = @DIV_CD)
  AND  (@TR_CD   IS NULL OR H.TR_CD   = @TR_CD)
  AND  (@ITEM_CD IS NULL OR D.ITEM_CD = @ITEM_CD)
  AND  (@PJT_CD  IS NULL OR ISNULL(NULLIF(D.PJT_CD,N''), H.PJT_CD) = @PJT_CD)
  AND  (@EMP_CD  IS NULL OR ISNULL(NULLIF(D.EMP_CD,N''), H.EMP_CD) = @EMP_CD)
  AND  (@EXC_RTN = N'0' OR ISNULL(D.SO_QT,0) > 0)           -- 반품 제외
;
CREATE CLUSTERED INDEX IX_DUE ON #DUE (SO_NB, SO_SQ);

-- 평가 대상 한정 : 완결 건만 (기본값)
IF @ONLY_CLOSED = N'1'
    DELETE FROM #DUE WHERE CLOSED = N'0' OR CHK_DT IS NULL;

PRINT N'[1] 평가 대상 : ' + CAST((SELECT COUNT(*) FROM #DUE) AS NVARCHAR(20)) + N' 라인';


/*==============================================================================================
  ** 쿼리 A : 전사 납기준수율 요약  ★ 목표 대비 판정
==============================================================================================*/
SELECT
     N'[A] 납기준수율 요약'                         AS REPORT_NM
    ,@FR_DT + N' ~ ' + @TO_DT                       AS 평가기간_납기일기준
    ,CASE @BASE_ISU WHEN N'F' THEN N'최초출고일' ELSE N'최종출고일' END AS 평가기준
    ,@TARGET                                        AS 목표_PCT
    ,COUNT(*)                                       AS 평가건수
    ,SUM(D.SO_QT)                                   AS 주문수량계
    ,SUM(D.ISU_QT)                                  AS 출고수량계
    ,SUM(D.SO_AM)                                   AS 주문금액계

    ,준수건수 = SUM(CASE WHEN D.DELAY <= @TOL_DAY THEN 1 ELSE 0 END)
    ,지연건수 = SUM(CASE WHEN D.DELAY >  @TOL_DAY THEN 1 ELSE 0 END)
    ,지연수량 = SUM(CASE WHEN D.DELAY >  @TOL_DAY THEN D.ISU_QT ELSE 0 END)
    ,지연금액 = SUM(CASE WHEN D.DELAY >  @TOL_DAY THEN D.SO_AM  ELSE 0 END)

    ,납기준수율_건수 = CAST(SUM(CASE WHEN D.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
                            / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
    ,납기준수율_수량 = CAST((1 - SUM(CASE WHEN D.DELAY > @TOL_DAY THEN D.ISU_QT ELSE 0 END)
                                 / NULLIF(SUM(D.SO_QT), 0)) * 100 AS DECIMAL(5,1))
    ,납기준수율_금액 = CAST((1 - SUM(CASE WHEN D.DELAY > @TOL_DAY THEN D.SO_AM ELSE 0 END)
                                 / NULLIF(SUM(D.SO_AM), 0)) * 100 AS DECIMAL(5,1))

    ,평균지연일 = CAST(AVG(CASE WHEN D.DELAY > @TOL_DAY THEN CAST(D.DELAY AS DECIMAL(9,2)) END)
                       AS DECIMAL(9,1))
    ,최대지연일 = MAX(CASE WHEN D.DELAY > @TOL_DAY THEN D.DELAY END)
    ,조기납품건수 = SUM(CASE WHEN D.DELAY < 0 THEN 1 ELSE 0 END)
    ,평균조기일 = CAST(AVG(CASE WHEN D.DELAY < 0 THEN CAST(-D.DELAY AS DECIMAL(9,2)) END)
                       AS DECIMAL(9,1))

    ,판정 = CASE
         WHEN CAST(SUM(CASE WHEN D.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
                   / NULLIF(COUNT(*),0) * 100 AS DECIMAL(5,1)) >= @TARGET       THEN N'0.목표 달성'
         WHEN CAST(SUM(CASE WHEN D.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
                   / NULLIF(COUNT(*),0) * 100 AS DECIMAL(5,1)) >= @TARGET - 5   THEN N'1.목표 근접(5%p 이내)'
         ELSE N'2.★목표 미달' END
    ,목표대비_PCTP = CAST(SUM(CASE WHEN D.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
                          / NULLIF(COUNT(*),0) * 100 - @TARGET AS DECIMAL(5,1))
FROM   #DUE D
;


/*==============================================================================================
  ** 쿼리 B : 월별 추이  (대시보드 라인 차트)
==============================================================================================*/
SELECT
     N'[B] 월별 납기준수율 추이'                    AS REPORT_NM
    ,LEFT(D.DUE_DT, 6)                              AS 납기월
    ,COUNT(*)                                       AS 평가건수
    ,SUM(D.SO_QT)                                   AS 주문수량
    ,SUM(D.SO_AM)                                   AS 주문금액
    ,준수건수 = SUM(CASE WHEN D.DELAY <= @TOL_DAY THEN 1 ELSE 0 END)
    ,지연건수 = SUM(CASE WHEN D.DELAY >  @TOL_DAY THEN 1 ELSE 0 END)
    ,납기준수율_건수 = CAST(SUM(CASE WHEN D.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
                            / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
    ,납기준수율_수량 = CAST((1 - SUM(CASE WHEN D.DELAY > @TOL_DAY THEN D.ISU_QT ELSE 0 END)
                                 / NULLIF(SUM(D.SO_QT), 0)) * 100 AS DECIMAL(5,1))
    ,평균지연일 = CAST(AVG(CASE WHEN D.DELAY > @TOL_DAY THEN CAST(D.DELAY AS DECIMAL(9,2)) END)
                       AS DECIMAL(9,1))
    ,@TARGET                                        AS 목표_PCT
    ,목표달성 = CASE WHEN CAST(SUM(CASE WHEN D.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
                               / NULLIF(COUNT(*),0) * 100 AS DECIMAL(5,1)) >= @TARGET
                     THEN N'O' ELSE N'X' END
    ,전월대비_PCTP = CAST(
         SUM(CASE WHEN D.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END) / NULLIF(COUNT(*),0) * 100
       - LAG(SUM(CASE WHEN D.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END) / NULLIF(COUNT(*),0) * 100)
             OVER (ORDER BY LEFT(D.DUE_DT, 6))
         AS DECIMAL(5,1))
FROM   #DUE D
GROUP BY LEFT(D.DUE_DT, 6)
ORDER BY 납기월
;


/*==============================================================================================
  ** 쿼리 C : 거래처별 납기준수율  (하위부터 — 개선 대상)
==============================================================================================*/
SELECT
     N'[C] 거래처별 납기준수율'                     AS REPORT_NM
    ,D.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,COUNT(*)                                       AS 평가건수
    ,SUM(D.SO_QT)                                   AS 주문수량
    ,SUM(D.SO_AM)                                   AS 주문금액
    ,준수건수 = SUM(CASE WHEN D.DELAY <= @TOL_DAY THEN 1 ELSE 0 END)
    ,지연건수 = SUM(CASE WHEN D.DELAY >  @TOL_DAY THEN 1 ELSE 0 END)
    ,지연금액 = SUM(CASE WHEN D.DELAY >  @TOL_DAY THEN D.SO_AM ELSE 0 END)
    ,납기준수율_건수 = CAST(SUM(CASE WHEN D.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
                            / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
    ,납기준수율_수량 = CAST((1 - SUM(CASE WHEN D.DELAY > @TOL_DAY THEN D.ISU_QT ELSE 0 END)
                                 / NULLIF(SUM(D.SO_QT), 0)) * 100 AS DECIMAL(5,1))
    ,평균지연일 = CAST(AVG(CASE WHEN D.DELAY > @TOL_DAY THEN CAST(D.DELAY AS DECIMAL(9,2)) END)
                       AS DECIMAL(9,1))
    ,최대지연일 = MAX(CASE WHEN D.DELAY > @TOL_DAY THEN D.DELAY END)
    ,등급 = CASE
         WHEN COUNT(*) < 5                                                      THEN N'9.표본 부족(5건 미만)'
         WHEN SUM(CASE WHEN D.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
              / NULLIF(COUNT(*),0) * 100 >= @TARGET                             THEN N'1.목표 달성'
         WHEN SUM(CASE WHEN D.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
              / NULLIF(COUNT(*),0) * 100 >= @TARGET - 10                        THEN N'2.주의'
         ELSE N'3.★개선 필요' END
FROM       #DUE   D
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD = D.TR_CD
GROUP BY D.TR_CD, T.TR_NM
ORDER BY 등급 DESC, 납기준수율_건수, 지연금액 DESC
;


/*==============================================================================================
  ** 쿼리 D : 품목별 납기준수율  (생산/구매 어느 쪽이 문제인가)
==============================================================================================*/
SELECT
     N'[D] 품목별 납기준수율'                       AS REPORT_NM
    ,조달경로 = CASE WHEN I.ACCT_FG IN (N'2', N'4')      THEN N'생산'
                     WHEN I.ACCT_FG IN (N'0', N'1', N'5') THEN N'구매'
                     ELSE N'미분류' END
    ,D.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,I.LEAD_DT                                      AS 리드타임일
    ,COUNT(*)                                       AS 평가건수
    ,COUNT(DISTINCT D.TR_CD)                        AS 거래처수
    ,SUM(D.SO_QT)                                   AS 주문수량
    ,준수건수 = SUM(CASE WHEN D.DELAY <= @TOL_DAY THEN 1 ELSE 0 END)
    ,지연건수 = SUM(CASE WHEN D.DELAY >  @TOL_DAY THEN 1 ELSE 0 END)
    ,납기준수율_건수 = CAST(SUM(CASE WHEN D.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
                            / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
    ,평균지연일 = CAST(AVG(CASE WHEN D.DELAY > @TOL_DAY THEN CAST(D.DELAY AS DECIMAL(9,2)) END)
                       AS DECIMAL(9,1))
    ,평균수주_납기간격 = CAST(AVG(CAST(DATEDIFF(DAY, CONVERT(DATE,D.SO_DT),
                                                    CONVERT(DATE,D.DUE_DT)) AS DECIMAL(9,2)))
                              AS DECIMAL(9,1))
    ,리드타임_판정 = CASE
         WHEN I.LEAD_DT IS NULL                                                 THEN N'9.리드타임 미등록'
         WHEN AVG(CAST(DATEDIFF(DAY,CONVERT(DATE,D.SO_DT),CONVERT(DATE,D.DUE_DT)) AS DECIMAL(9,2)))
              < CAST(I.LEAD_DT AS DECIMAL(9,2))
              THEN N'1.★납기가 리드타임보다 짧음 - 구조적 지연'
         ELSE N'0.여유 있음' END
FROM       #DUE  D
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = D.ITEM_CD
GROUP BY D.ITEM_CD, I.ITEM_NM, I.SPEC, I.UNIT_CD, I.ACCT_FG, I.LEAD_DT
HAVING SUM(CASE WHEN D.DELAY > @TOL_DAY THEN 1 ELSE 0 END) > 0
ORDER BY 지연건수 DESC, 납기준수율_건수
;


/*==============================================================================================
  ** 쿼리 E : 지연 구간 분포  (얼마나 늦는가)
==============================================================================================*/
SELECT
     N'[E] 지연 구간 분포'                          AS REPORT_NM
    ,지연구간 = CASE
         WHEN D.DELAY <  0                THEN N'0.조기납품'
         WHEN D.DELAY =  0                THEN N'1.정시'
         WHEN D.DELAY <= 3                THEN N'2.1~3일'
         WHEN D.DELAY <= 7                THEN N'3.4~7일'
         WHEN D.DELAY <= 15               THEN N'4.8~15일'
         WHEN D.DELAY <= 30               THEN N'5.16~30일'
         ELSE                                  N'6.★30일 초과' END
    ,COUNT(*)                                       AS 건수
    ,SUM(D.SO_QT)                                   AS 주문수량
    ,SUM(D.SO_AM)                                   AS 주문금액
    ,COUNT(DISTINCT D.TR_CD)                        AS 거래처수
    ,COUNT(DISTINCT D.ITEM_CD)                      AS 품목수
    ,구성비_건수 = CAST(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0) AS DECIMAL(5,1))
    ,구성비_금액 = CAST(SUM(D.SO_AM) * 100.0 / NULLIF(SUM(SUM(D.SO_AM)) OVER (), 0) AS DECIMAL(5,1))
    ,누적구성비 = CAST(SUM(COUNT(*)) OVER (ORDER BY CASE
         WHEN D.DELAY <  0 THEN N'0.조기납품' WHEN D.DELAY = 0 THEN N'1.정시'
         WHEN D.DELAY <= 3 THEN N'2.1~3일'    WHEN D.DELAY <= 7 THEN N'3.4~7일'
         WHEN D.DELAY <= 15 THEN N'4.8~15일'  WHEN D.DELAY <= 30 THEN N'5.16~30일'
         ELSE N'6.★30일 초과' END)
         * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0) AS DECIMAL(5,1))
FROM   #DUE D
GROUP BY CASE
         WHEN D.DELAY <  0                THEN N'0.조기납품'
         WHEN D.DELAY =  0                THEN N'1.정시'
         WHEN D.DELAY <= 3                THEN N'2.1~3일'
         WHEN D.DELAY <= 7                THEN N'3.4~7일'
         WHEN D.DELAY <= 15               THEN N'4.8~15일'
         WHEN D.DELAY <= 30               THEN N'5.16~30일'
         ELSE                                  N'6.★30일 초과' END
ORDER BY 지연구간
;


/*==============================================================================================
  ** 쿼리 F : 지연 건 상세  (원인 분석 착수용)
==============================================================================================*/
SELECT
     N'[F] 지연 건 상세'                            AS REPORT_NM
    ,지연구간 = CASE WHEN D.DELAY > 30 THEN N'1.★30일 초과'
                     WHEN D.DELAY > 15 THEN N'2.16~30일'
                     WHEN D.DELAY >  7 THEN N'3.8~15일'
                     ELSE                   N'4.1~7일' END
    ,D.SO_NB                                        AS 수주번호
    ,D.SO_SQ                                        AS 수주순번
    ,D.SO_DT                                        AS 수주일
    ,D.DUE_DT                                       AS 납기일
    ,D.FIRST_DT                                     AS 최초출고일
    ,D.LAST_DT                                      AS 최종출고일
    ,D.DLV_CNT                                      AS 출고건수
    ,D.DELAY                                        AS 지연일수
    ,D.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,D.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,D.SO_QT                                        AS 주문수량
    ,D.ISU_QT                                       AS 출고수량
    ,D.SO_AM                                        AS 주문금액
    ,수주_납기간격 = DATEDIFF(DAY, CONVERT(DATE,D.SO_DT), CONVERT(DATE,D.DUE_DT))
    ,I.LEAD_DT                                      AS 리드타임일
    ,추정원인 = CASE
         WHEN I.LEAD_DT IS NOT NULL
          AND DATEDIFF(DAY,CONVERT(DATE,D.SO_DT),CONVERT(DATE,D.DUE_DT)) < CAST(I.LEAD_DT AS INT)
              THEN N'1.★납기 자체가 리드타임보다 짧음 (영업 수주 조건)'
         WHEN D.DLV_CNT > 1
              THEN N'2.분할출고 - 최종분 지연 (부분 결품)'
         WHEN I.ACCT_FG IN (N'2', N'4')
              THEN N'3.생산 지연 (M-01 작업지시 진행현황 확인)'
         WHEN I.ACCT_FG IN (N'0', N'1', N'5')
              THEN N'4.구매 지연 (P-01 청구발주입고 확인)'
         ELSE N'5.기타' END
    ,D.EMP_CD                                       AS 영업담당
    ,E.EMP_NM                                       AS 담당자명
    ,D.PJT_CD                                       AS 프로젝트
FROM       #DUE   D
LEFT  JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = D.ITEM_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = D.TR_CD
LEFT  JOIN SEMP   E WITH (NOLOCK) ON E.CO_CD = @CO_CD AND E.EMP_CD  = D.EMP_CD
WHERE  D.DELAY > @TOL_DAY
ORDER BY 지연구간, D.DELAY DESC, D.SO_AM DESC
;


/*==============================================================================================
  ** 쿼리 G : 영업담당별 납기준수율
==============================================================================================*/
SELECT
     N'[G] 영업담당별 납기준수율'                   AS REPORT_NM
    ,D.EMP_CD                                       AS 담당자코드
    ,E.EMP_NM                                       AS 담당자명
    ,P.DEPT_NM                                      AS 부서명
    ,COUNT(*)                                       AS 평가건수
    ,COUNT(DISTINCT D.TR_CD)                        AS 담당거래처수
    ,SUM(D.SO_AM)                                   AS 주문금액
    ,준수건수 = SUM(CASE WHEN D.DELAY <= @TOL_DAY THEN 1 ELSE 0 END)
    ,지연건수 = SUM(CASE WHEN D.DELAY >  @TOL_DAY THEN 1 ELSE 0 END)
    ,납기준수율_건수 = CAST(SUM(CASE WHEN D.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
                            / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
    ,평균지연일 = CAST(AVG(CASE WHEN D.DELAY > @TOL_DAY THEN CAST(D.DELAY AS DECIMAL(9,2)) END)
                       AS DECIMAL(9,1))
    ,무리한납기건수 = SUM(CASE WHEN I.LEAD_DT IS NOT NULL
                                AND DATEDIFF(DAY,CONVERT(DATE,D.SO_DT),CONVERT(DATE,D.DUE_DT))
                                    < CAST(I.LEAD_DT AS INT)
                               THEN 1 ELSE 0 END)
    ,판정 = CASE
         WHEN COUNT(*) < 5                                                THEN N'9.표본 부족'
         WHEN SUM(CASE WHEN D.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
              / NULLIF(COUNT(*),0) * 100 >= @TARGET                       THEN N'1.목표 달성'
         WHEN SUM(CASE WHEN I.LEAD_DT IS NOT NULL
                        AND DATEDIFF(DAY,CONVERT(DATE,D.SO_DT),CONVERT(DATE,D.DUE_DT))
                            < CAST(I.LEAD_DT AS INT) THEN 1 ELSE 0 END)
              > COUNT(*) * 0.2
              THEN N'2.★무리한 납기 수주 20% 초과 - 수주 조건 검토'
         ELSE N'3.개선 필요' END
FROM       #DUE  D
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = D.ITEM_CD
LEFT  JOIN SEMP  E WITH (NOLOCK) ON E.CO_CD = @CO_CD AND E.EMP_CD  = D.EMP_CD
LEFT  JOIN SDEPT P WITH (NOLOCK) ON P.CO_CD = @CO_CD AND P.DEPT_CD = E.DEPT_CD
GROUP BY D.EMP_CD, E.EMP_NM, P.DEPT_NM
ORDER BY 판정 DESC, 납기준수율_건수
;


/*==============================================================================================
  ** 쿼리 H : 조기납품 분석  ★ 지연이 아니라고 무시하면 안 되는 항목
     ─ 너무 이른 출고는 고객 창고에 재고 부담을 지우고, 대금 회수도 앞당겨지지 않는다.
       납기 관리가 느슨하다는 신호이기도 하다.
==============================================================================================*/
SELECT
     N'[H] 조기납품 분석'                           AS REPORT_NM
    ,D.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,COUNT(*)                                       AS 조기납품건수
    ,SUM(D.SO_QT)                                   AS 주문수량
    ,SUM(D.SO_AM)                                   AS 주문금액
    ,평균조기일 = CAST(AVG(CAST(-D.DELAY AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,최대조기일 = MAX(-D.DELAY)
    ,경고건수 = SUM(CASE WHEN -D.DELAY > @EARLY_DAY THEN 1 ELSE 0 END)
    ,판정 = CASE
         WHEN AVG(CAST(-D.DELAY AS DECIMAL(9,2))) > @EARLY_DAY * 2
              THEN N'1.★상시 조기출고 - 납기 설정 재검토 (실제 리드타임 반영)'
         WHEN SUM(CASE WHEN -D.DELAY > @EARLY_DAY THEN 1 ELSE 0 END) > COUNT(*) * 0.5
              THEN N'2.조기출고 빈번 - 고객 재고 부담 확인'
         ELSE N'0.정상 범위' END
FROM       #DUE   D
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD = D.TR_CD
WHERE  D.DELAY < 0
GROUP BY D.TR_CD, T.TR_NM
HAVING COUNT(*) >= 3
ORDER BY 판정, 평균조기일 DESC
;


DROP TABLE #DUE;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 납기(DUE_DT) 등록률  ★ 미등록 건은 평가 자체가 불가능하다
     SELECT COUNT(*) 전체, SUM(CASE WHEN ISNULL(DUE_DT,'')='' THEN 1 ELSE 0 END) 납기미등록
     FROM   LSO_D WHERE CO_CD='1000';
     --> 미등록 비중이 크면 KPI 신뢰도가 떨어진다. 등록 독려가 선행되어야 한다.

  -- (2) 평가 모집단 크기  ★ 완결 건만 대상이라 분모가 얼마나 줄어드는지 확인
     SELECT CASE WHEN SO_QT-ISNULL(ISU_QT,0)=0 THEN '완결' ELSE '미완결' END 구분, COUNT(*)
     FROM   LSO_D WHERE CO_CD='1000' AND DUE_DT BETWEEN '20260101' AND '20261231'
     GROUP BY CASE WHEN SO_QT-ISNULL(ISU_QT,0)=0 THEN '완결' ELSE '미완결' END;

  -- (3) 분할출고 비중  ★ '최종출고일 기준'이 타당한지 판단
     SELECT 출고건수, COUNT(*) 수주라인수 FROM (
       SELECT SO_NB, SO_SQ, COUNT(*) 출고건수 FROM LDELIVER_D
       WHERE CO_CD='1000' AND ISNULL(SO_NB,'')<>'' GROUP BY SO_NB, SO_SQ
     ) X GROUP BY 출고건수 ORDER BY 출고건수;

  -- (4) 조기/정시/지연 분포 미리보기  ★ 목표선(95%)이 현실적인지 판단
     SELECT CASE WHEN DATEDIFF(DAY,D.DUE_DT,V.LAST_DT) > 0 THEN '지연'
                 WHEN DATEDIFF(DAY,D.DUE_DT,V.LAST_DT) = 0 THEN '정시' ELSE '조기' END 구분
           ,COUNT(*)
     FROM   LSO_D D
     OUTER APPLY (SELECT MAX(X.ISU_DT) LAST_DT FROM LDELIVER X
                  INNER JOIN LDELIVER_D Y ON Y.CO_CD=X.CO_CD AND Y.ISU_NB=X.ISU_NB
                  WHERE Y.SO_NB=D.SO_NB AND Y.SO_SQ=D.SO_SQ) V
     WHERE  D.CO_CD='1000' AND D.SO_QT-ISNULL(D.ISU_QT,0)=0 AND V.LAST_DT IS NOT NULL
     GROUP BY CASE WHEN DATEDIFF(DAY,D.DUE_DT,V.LAST_DT) > 0 THEN '지연'
                   WHEN DATEDIFF(DAY,D.DUE_DT,V.LAST_DT) = 0 THEN '정시' ELSE '조기' END;
     --> 현재 준수율이 70%대라면 목표 95%는 당장 의미가 없다. @TARGET 을 단계적으로 올릴 것.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **납기 변경 이력을 추적하지 않는다.** `DUE_DT` 는 현재 납기이므로, 고객이 납기를 미뤄준
     건은 지연으로 잡히지 않고 **우리가 늦어서 납기를 고친 건도 지연으로 잡히지 않는다.**
     이것이 이 KPI 의 가장 큰 구조적 약점이다. 원납기 대비 평가가 필요하면 관리항목 또는
     `LSO_D.DUMMY*` 컬럼에 원납기를 보관하는지 먼저 확인할 것. 보관하지 않는 사이트라면
     이 지표는 "최종 합의 납기 기준 준수율"로만 해석해야 한다.

  2) 지연 사유 코드가 없다. 쿼리 F 의 `추정원인` 은 리드타임·분할출고·계정구분으로 **추론**한
     것이며 실제 사유가 아니다. 사유 관리가 필요하면 관리항목(`LCTRL_MGM`, `CTRL_CD='LS'`)에
     지연사유를 등록하는 운영을 먼저 만들어야 한다.

  3) 평가 기간은 **납기일 기준**이다. 출고일 기준으로 보면 결과가 달라진다(납기가 이전 기간인
     건이 이번 달에 출고되는 경우). 월별 추이를 볼 때 이 점을 혼동하지 말 것.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   S02_주문미납_현황.sql        : 아직 안 끝난 건 (본 KPI 의 분모에서 제외된 건)
   M01_작업지시_진행현황.sql    : 생산 지연 원인 추적
   P01_청구발주입고_진행현황.sql : 구매 지연 원인 추적
   P02_발주납기준수_KPI.sql     : 우리가 협력사에 대해 같은 평가를 하는 쪽
==============================================================================================*/
