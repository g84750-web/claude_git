/*==============================================================================================
  [ iCUBE ] P-02  발주 납기 준수 / 지연 현황 KPI                                     (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 협력사가 약속한 납기를 지켰는가. **공급사 평가의 정량 근거**.
         S-03(우리가 고객에게 지키는 납기)의 거울상이며, 산식과 판정 기준을 일부러 맞췄다.

  DBMS : MS-SQL Server 2012 이상 (T-SQL)   ★ 2008 R2 불가 : LAG()

  ----------------------------------------------------------------------------------------------
  [ 산식 ]
  ----------------------------------------------------------------------------------------------
     지연일수   = DATEDIFF(DAY, LPO_D.DUE_DT, 최종입고일)
     지연플래그 = CASE WHEN 지연일수 > @TOL_DAY THEN 1 ELSE 0 END

     납기준수율(건수) = COUNT(지연플래그=0) / COUNT(*) * 100
     납기준수율(수량) = (1 - SUM(지연수량) / SUM(발주량)) * 100
     평균지연일       = AVG(CASE WHEN 지연일수 > 0 THEN 지연일수 END)

  ----------------------------------------------------------------------------------------------
  [ 반드시 지킨 것 ]
  ----------------------------------------------------------------------------------------------
   1. **입고 완결 건만 평가한다** (`RCV_QT >= PO_QT`). 아직 안 들어온 건을 분모에 넣으면
      "늦은 게 아니라 아직 안 온 것"이 지연으로 잡혀 준수율이 왜곡된다.
      미입고 건은 쿼리 G 에서 **별도로** 본다 (이쪽이 더 급한 경우가 많다).
   2. **분할입고는 최종 입고일 기준**이 실무 정의다. 마지막 한 건만 늦어도 지연으로 본다.
      첫 입고 기준 평가가 필요하면 @BASE_RCV='F' 로 바꾼다.
   3. **조기입고(음수)를 지연으로 세지 않는다.** 단, 너무 이른 입고는 우리 창고에 재고
      부담을 지우므로 쿼리 H 에서 따로 본다.
   4. **수입(L/C) 건은 통관 기준이라 국내와 성격이 다르다.** @LC_FG 로 분리 조회한다.
      섞어서 평가하면 국내 협력사가 부당하게 나쁘게 보인다.
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터   ─ 목표선은 S-03 과 동일한 EIS 기본값(95%)을 썼다.
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@BASE_DT  NVARCHAR(8)  = N'20260915'     -- 기준일 (미입고 경과일 산정)
    ,@FR_DT    NVARCHAR(8)  = N'20260101'     -- 발주납기 기준 기간 FROM
    ,@TO_DT    NVARCHAR(8)  = N'20261231'
    ,@TR_CD    NVARCHAR(10) = NULL            -- 특정 거래처
    ,@ITEM_CD  NVARCHAR(25) = NULL
    ,@LC_FG    NCHAR(1)     = N'D'            -- D 국내만 / L 수입만 / A 전체

    ,@TARGET   DECIMAL(5,1) = 95.0            -- ★ 목표 납기준수율 (%)  [EIS 기본값]
    ,@TOL_DAY  INT          = 0               -- 허용 지연일 (0 = 하루라도 늦으면 지연)
    ,@EARLY_DAY INT         = 7               -- 조기입고 경고 기준일
    ,@MIN_CNT  INT          = 5               -- 거래처 평가 최소 표본 건수
;

IF OBJECT_ID('tempdb..#PO') IS NOT NULL DROP TABLE #PO;


/*==============================================================================================
  1. #PO : 발주 라인 + 입고 실적 + 지연 판정
     ─ 입고는 집계 후 붙인다 (발주 1건 → 입고 N건 fan-out 차단)
==============================================================================================*/
SELECT
     H.PO_NB
    ,D.PO_SQ
    ,H.PO_DT
    ,D.DUE_DT
    ,H.TR_CD
    ,EMP_CD  = ISNULL(NULLIF(D.EMP_CD, N''), H.EMP_CD)
    ,D.ITEM_CD
    ,D.PJT_CD
    ,REQ_NB  = NULLIF(D.REQ_NB, N'')
    ,PO_QT   = CAST(ISNULL(D.PO_QT, 0) AS DECIMAL(19,6))
    ,PO_UM   = CAST(ISNULL(D.UM   , 0) AS DECIMAL(19,6))
    ,PO_AM   = CAST(ISNULL(D.PO_AM, 0) AS DECIMAL(19,4))
    ,RCV_QT  = ISNULL(V.RCV_QT , 0)
    ,RCV_AM  = ISNULL(V.RCV_AM , 0)
    ,RCV_CNT = ISNULL(V.RCV_CNT, 0)
    ,V.FIRST_DT
    ,V.LAST_DT
    ,LC_YN   = ISNULL(V.LC_YN, N'0')
    -- 평가 기준 입고일
    ,CHK_DT  = CASE @LC_FG WHEN N'F' THEN V.FIRST_DT ELSE V.LAST_DT END
    -- 지연일수 (양수 = 지연, 음수 = 조기)
    ,DELAY   = DATEDIFF(DAY, CONVERT(DATE, D.DUE_DT), CONVERT(DATE, V.LAST_DT))
    ,CLOSED  = CASE WHEN ISNULL(V.RCV_QT,0) >= CAST(ISNULL(D.PO_QT,0) AS DECIMAL(19,6))
                     AND ISNULL(D.PO_QT,0) > 0 THEN N'1' ELSE N'0' END
INTO #PO
FROM       LPO   H WITH (NOLOCK)
INNER JOIN LPO_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.PO_NB = H.PO_NB
OUTER APPLY (
    SELECT
         RCV_QT  = SUM(CAST(ISNULL(Y.RCV_QT,0) AS DECIMAL(19,6)))
        ,RCV_AM  = SUM(CAST(ISNULL(Y.RCV_AM,0) AS DECIMAL(19,4)))
        ,RCV_CNT = COUNT(*)
        ,FIRST_DT= MIN(X.RCV_DT)
        ,LAST_DT = MAX(X.RCV_DT)
        ,LC_YN   = MAX(ISNULL(X.LC_YN, N'0'))
    FROM       LSTOCK   X WITH (NOLOCK)
    INNER JOIN LSTOCK_D Y WITH (NOLOCK) ON Y.CO_CD = X.CO_CD AND Y.RCV_NB = X.RCV_NB
    WHERE  Y.CO_CD = D.CO_CD AND Y.PO_NB = D.PO_NB AND Y.PO_SQ = D.PO_SQ
      AND  ISNULL(Y.USE_YN, N'1') = N'1' AND ISNULL(Y.EXPIRE_YN, N'1') = N'1'
) V
WHERE  H.CO_CD  = @CO_CD
  AND  D.DUE_DT BETWEEN @FR_DT AND @TO_DT                   -- ★ 발주납기 기준 기간
  AND  ISNULL(D.USE_YN, N'1') = N'1'
  AND  ISNULL(D.DUE_DT, N'') <> N''                         -- 납기 미등록은 평가 불가
  AND  ISNULL(D.PO_QT, 0) > 0
  AND  (@DIV_CD  IS NULL OR H.DIV_CD  = @DIV_CD)
  AND  (@TR_CD   IS NULL OR H.TR_CD   = @TR_CD)
  AND  (@ITEM_CD IS NULL OR D.ITEM_CD = @ITEM_CD)
;
CREATE CLUSTERED INDEX IX_PO ON #PO (PO_NB, PO_SQ);

-- 수입/국내 분리
IF @LC_FG = N'D' DELETE FROM #PO WHERE LC_YN = N'1';
IF @LC_FG = N'L' DELETE FROM #PO WHERE LC_YN <> N'1';

PRINT N'[1] 발주 라인 : ' + CAST((SELECT COUNT(*) FROM #PO) AS NVARCHAR(20))
    + N' (평가대상 완결 ' + CAST((SELECT COUNT(*) FROM #PO WHERE CLOSED = N'1') AS NVARCHAR(20)) + N')';


/*==============================================================================================
  ** 쿼리 A : 전사 발주 납기준수율 요약  ★ 목표 대비 판정
     ─ 평가 모집단은 **입고 완결 건**만. 미입고 건은 쿼리 G 에서 따로 본다.
==============================================================================================*/
SELECT
     N'[A] 발주 납기준수율 요약'                    AS REPORT_NM
    ,@FR_DT + N' ~ ' + @TO_DT                       AS 평가기간_발주납기기준
    ,CASE @LC_FG WHEN N'D' THEN N'국내' WHEN N'L' THEN N'수입' ELSE N'전체' END AS 대상
    ,@TARGET                                        AS 목표_PCT
    ,COUNT(*)                                       AS 평가건수_입고완결
    ,COUNT(DISTINCT P.TR_CD)                        AS 거래처수
    ,SUM(P.PO_QT)                                   AS 발주수량계
    ,SUM(P.RCV_QT)                                  AS 입고수량계
    ,SUM(P.PO_AM)                                   AS 발주금액계

    ,준수건수 = SUM(CASE WHEN P.DELAY <= @TOL_DAY THEN 1 ELSE 0 END)
    ,지연건수 = SUM(CASE WHEN P.DELAY >  @TOL_DAY THEN 1 ELSE 0 END)
    ,지연수량 = SUM(CASE WHEN P.DELAY >  @TOL_DAY THEN P.RCV_QT ELSE 0 END)
    ,지연금액 = SUM(CASE WHEN P.DELAY >  @TOL_DAY THEN P.PO_AM  ELSE 0 END)

    ,납기준수율_건수 = CAST(SUM(CASE WHEN P.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
                            / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
    ,납기준수율_수량 = CAST((1 - SUM(CASE WHEN P.DELAY > @TOL_DAY THEN P.RCV_QT ELSE 0 END)
                                 / NULLIF(SUM(P.PO_QT), 0)) * 100 AS DECIMAL(5,1))
    ,납기준수율_금액 = CAST((1 - SUM(CASE WHEN P.DELAY > @TOL_DAY THEN P.PO_AM ELSE 0 END)
                                 / NULLIF(SUM(P.PO_AM), 0)) * 100 AS DECIMAL(5,1))

    ,평균지연일 = CAST(AVG(CASE WHEN P.DELAY > @TOL_DAY THEN CAST(P.DELAY AS DECIMAL(9,2)) END)
                       AS DECIMAL(9,1))
    ,최대지연일 = MAX(CASE WHEN P.DELAY > @TOL_DAY THEN P.DELAY END)
    ,평균조달일 = CAST(AVG(CAST(DATEDIFF(DAY, CONVERT(DATE,P.PO_DT), CONVERT(DATE,P.LAST_DT))
                                AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,조기입고건수 = SUM(CASE WHEN P.DELAY < 0 THEN 1 ELSE 0 END)
    ,분할입고건수 = SUM(CASE WHEN P.RCV_CNT > 1 THEN 1 ELSE 0 END)

    ,판정 = CASE
         WHEN CAST(SUM(CASE WHEN P.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
                   / NULLIF(COUNT(*),0) * 100 AS DECIMAL(5,1)) >= @TARGET       THEN N'0.목표 달성'
         WHEN CAST(SUM(CASE WHEN P.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
                   / NULLIF(COUNT(*),0) * 100 AS DECIMAL(5,1)) >= @TARGET - 5   THEN N'1.목표 근접(5%p 이내)'
         ELSE N'2.★목표 미달' END
    ,목표대비_PCTP = CAST(SUM(CASE WHEN P.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
                          / NULLIF(COUNT(*),0) * 100 - @TARGET AS DECIMAL(5,1))
FROM   #PO P
WHERE  P.CLOSED = N'1' AND P.LAST_DT IS NOT NULL
;


/*==============================================================================================
  ** 쿼리 B : 월별 추이  (대시보드 라인 차트)
==============================================================================================*/
SELECT
     N'[B] 월별 발주 납기준수율'                    AS REPORT_NM
    ,LEFT(P.DUE_DT, 6)                              AS 납기월
    ,COUNT(*)                                       AS 평가건수
    ,SUM(P.PO_QT)                                   AS 발주수량
    ,SUM(P.PO_AM)                                   AS 발주금액
    ,준수건수 = SUM(CASE WHEN P.DELAY <= @TOL_DAY THEN 1 ELSE 0 END)
    ,지연건수 = SUM(CASE WHEN P.DELAY >  @TOL_DAY THEN 1 ELSE 0 END)
    ,납기준수율_건수 = CAST(SUM(CASE WHEN P.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
                            / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
    ,납기준수율_수량 = CAST((1 - SUM(CASE WHEN P.DELAY > @TOL_DAY THEN P.RCV_QT ELSE 0 END)
                                 / NULLIF(SUM(P.PO_QT), 0)) * 100 AS DECIMAL(5,1))
    ,평균지연일 = CAST(AVG(CASE WHEN P.DELAY > @TOL_DAY THEN CAST(P.DELAY AS DECIMAL(9,2)) END)
                       AS DECIMAL(9,1))
    ,평균조달일 = CAST(AVG(CAST(DATEDIFF(DAY,CONVERT(DATE,P.PO_DT),CONVERT(DATE,P.LAST_DT))
                                AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,@TARGET                                        AS 목표_PCT
    ,목표달성 = CASE WHEN CAST(SUM(CASE WHEN P.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
                               / NULLIF(COUNT(*),0) * 100 AS DECIMAL(5,1)) >= @TARGET
                     THEN N'O' ELSE N'X' END
    ,전월대비_PCTP = CAST(
         SUM(CASE WHEN P.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END) / NULLIF(COUNT(*),0) * 100
       - LAG(SUM(CASE WHEN P.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END) / NULLIF(COUNT(*),0) * 100)
             OVER (ORDER BY LEFT(P.DUE_DT, 6))
         AS DECIMAL(5,1))
FROM   #PO P
WHERE  P.CLOSED = N'1' AND P.LAST_DT IS NOT NULL
GROUP BY LEFT(P.DUE_DT, 6)
ORDER BY 납기월
;


/*==============================================================================================
  ** 쿼리 C : 거래처별 납기준수율  ★ 공급사 평가표
==============================================================================================*/
SELECT
     N'[C] 거래처별 납기 평가'                      AS REPORT_NM
    ,P.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,COUNT(*)                                       AS 평가건수
    ,COUNT(DISTINCT P.ITEM_CD)                      AS 공급품목수
    ,SUM(P.PO_QT)                                   AS 발주수량
    ,SUM(P.PO_AM)                                   AS 발주금액
    ,준수건수 = SUM(CASE WHEN P.DELAY <= @TOL_DAY THEN 1 ELSE 0 END)
    ,지연건수 = SUM(CASE WHEN P.DELAY >  @TOL_DAY THEN 1 ELSE 0 END)
    ,지연금액 = SUM(CASE WHEN P.DELAY >  @TOL_DAY THEN P.PO_AM ELSE 0 END)
    ,납기준수율_건수 = CAST(SUM(CASE WHEN P.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
                            / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
    ,납기준수율_수량 = CAST((1 - SUM(CASE WHEN P.DELAY > @TOL_DAY THEN P.RCV_QT ELSE 0 END)
                                 / NULLIF(SUM(P.PO_QT), 0)) * 100 AS DECIMAL(5,1))
    ,평균지연일 = CAST(AVG(CASE WHEN P.DELAY > @TOL_DAY THEN CAST(P.DELAY AS DECIMAL(9,2)) END)
                       AS DECIMAL(9,1))
    ,최대지연일 = MAX(CASE WHEN P.DELAY > @TOL_DAY THEN P.DELAY END)
    ,평균조달일 = CAST(AVG(CAST(DATEDIFF(DAY,CONVERT(DATE,P.PO_DT),CONVERT(DATE,P.LAST_DT))
                                AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,분할입고율_PCT = CAST(SUM(CASE WHEN P.RCV_CNT > 1 THEN 1.0 ELSE 0 END)
                           / NULLIF(COUNT(*),0) * 100 AS DECIMAL(5,1))
    ,등급 = CASE
         WHEN COUNT(*) < @MIN_CNT                                              THEN N'9.표본 부족'
         WHEN SUM(CASE WHEN P.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
              / NULLIF(COUNT(*),0) * 100 >= @TARGET                            THEN N'1.우수 (목표 달성)'
         WHEN SUM(CASE WHEN P.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
              / NULLIF(COUNT(*),0) * 100 >= 80                                 THEN N'2.보통 (80% 이상)'
         WHEN SUM(CASE WHEN P.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
              / NULLIF(COUNT(*),0) * 100 >= 60                                 THEN N'3.주의 (60% 이상)'
         ELSE N'4.★개선 요구 (60% 미만)' END
    ,조치 = CASE
         WHEN COUNT(*) < @MIN_CNT                                              THEN N'-'
         WHEN SUM(CASE WHEN P.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
              / NULLIF(COUNT(*),0) * 100 < 60                                  THEN N'거래 조건 재협의 또는 대체 공급선 검토'
         WHEN AVG(CASE WHEN P.DELAY > @TOL_DAY THEN CAST(P.DELAY AS DECIMAL(9,2)) END) > 14
                                                                               THEN N'평균 2주 이상 지연 - 리드타임 재설정 협의'
         WHEN SUM(CASE WHEN P.RCV_CNT > 1 THEN 1.0 ELSE 0 END)
              / NULLIF(COUNT(*),0) > 0.5                                       THEN N'분할입고 과다 - 일괄 납품 요청'
         ELSE N'-' END
FROM       #PO    P
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD = P.TR_CD
WHERE  P.CLOSED = N'1' AND P.LAST_DT IS NOT NULL
GROUP BY P.TR_CD, T.TR_NM
ORDER BY 등급 DESC, 납기준수율_건수, 지연금액 DESC
;


/*==============================================================================================
  ** 쿼리 D : 품목별 납기준수율  (품목 자체가 구하기 어려운 것인지 판단)
==============================================================================================*/
SELECT
     N'[D] 품목별 납기준수율'                       AS REPORT_NM
    ,P.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
    ,COUNT(*)                                       AS 평가건수
    ,COUNT(DISTINCT P.TR_CD)                        AS 공급처수
    ,SUM(P.PO_QT)                                   AS 발주수량
    ,준수건수 = SUM(CASE WHEN P.DELAY <= @TOL_DAY THEN 1 ELSE 0 END)
    ,지연건수 = SUM(CASE WHEN P.DELAY >  @TOL_DAY THEN 1 ELSE 0 END)
    ,납기준수율_건수 = CAST(SUM(CASE WHEN P.DELAY <= @TOL_DAY THEN 1.0 ELSE 0 END)
                            / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
    ,평균지연일 = CAST(AVG(CASE WHEN P.DELAY > @TOL_DAY THEN CAST(P.DELAY AS DECIMAL(9,2)) END)
                       AS DECIMAL(9,1))
    ,평균조달일 = CAST(AVG(CAST(DATEDIFF(DAY,CONVERT(DATE,P.PO_DT),CONVERT(DATE,P.LAST_DT))
                                AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,I.LEAD_DT                                      AS 등록리드타임
    ,평균발주_납기간격 = CAST(AVG(CAST(DATEDIFF(DAY,CONVERT(DATE,P.PO_DT),CONVERT(DATE,P.DUE_DT))
                                       AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,리드타임_판정 = CASE
         WHEN I.LEAD_DT IS NULL OR CAST(ISNULL(I.LEAD_DT,0) AS INT) = 0        THEN N'9.리드타임 미등록'
         WHEN AVG(CAST(DATEDIFF(DAY,CONVERT(DATE,P.PO_DT),CONVERT(DATE,P.LAST_DT)) AS DECIMAL(9,2)))
              > CAST(I.LEAD_DT AS DECIMAL(9,2)) * 1.3
              THEN N'1.★실제 조달일이 등록 리드타임의 1.3배 초과 - 마스터 갱신 필요'
         WHEN AVG(CAST(DATEDIFF(DAY,CONVERT(DATE,P.PO_DT),CONVERT(DATE,P.DUE_DT)) AS DECIMAL(9,2)))
              < CAST(I.LEAD_DT AS DECIMAL(9,2))
              THEN N'2.★납기를 리드타임보다 짧게 요구 - 구조적 지연'
         ELSE N'0.정상' END
FROM       #PO   P
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = P.ITEM_CD
WHERE  P.CLOSED = N'1' AND P.LAST_DT IS NOT NULL
GROUP BY P.ITEM_CD, I.ITEM_NM, I.SPEC, I.UNIT_CD, I.ACCT_FG, I.LEAD_DT
HAVING SUM(CASE WHEN P.DELAY > @TOL_DAY THEN 1 ELSE 0 END) > 0
ORDER BY 지연건수 DESC, 납기준수율_건수
;


/*==============================================================================================
  ** 쿼리 E : 지연 구간 분포
==============================================================================================*/
SELECT
     N'[E] 지연 구간 분포'                          AS REPORT_NM
    ,지연구간 = CASE
         WHEN P.DELAY <  0                THEN N'0.조기입고'
         WHEN P.DELAY =  0                THEN N'1.정시'
         WHEN P.DELAY <= 3                THEN N'2.1~3일'
         WHEN P.DELAY <= 7                THEN N'3.4~7일'
         WHEN P.DELAY <= 15               THEN N'4.8~15일'
         WHEN P.DELAY <= 30               THEN N'5.16~30일'
         ELSE                                  N'6.★30일 초과' END
    ,COUNT(*)                                       AS 건수
    ,SUM(P.PO_QT)                                   AS 발주수량
    ,SUM(P.PO_AM)                                   AS 발주금액
    ,COUNT(DISTINCT P.TR_CD)                        AS 거래처수
    ,COUNT(DISTINCT P.ITEM_CD)                      AS 품목수
    ,구성비_건수 = CAST(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0) AS DECIMAL(5,1))
    ,구성비_금액 = CAST(SUM(P.PO_AM) * 100.0 / NULLIF(SUM(SUM(P.PO_AM)) OVER (), 0) AS DECIMAL(5,1))
FROM   #PO P
WHERE  P.CLOSED = N'1' AND P.LAST_DT IS NOT NULL
GROUP BY CASE
         WHEN P.DELAY <  0                THEN N'0.조기입고'
         WHEN P.DELAY =  0                THEN N'1.정시'
         WHEN P.DELAY <= 3                THEN N'2.1~3일'
         WHEN P.DELAY <= 7                THEN N'3.4~7일'
         WHEN P.DELAY <= 15               THEN N'4.8~15일'
         WHEN P.DELAY <= 30               THEN N'5.16~30일'
         ELSE                                  N'6.★30일 초과' END
ORDER BY 지연구간
;


/*==============================================================================================
  ** 쿼리 F : 지연 건 상세  (협력사 협의용)
==============================================================================================*/
SELECT
     N'[F] 지연 건 상세'                            AS REPORT_NM
    ,지연구간 = CASE WHEN P.DELAY > 30 THEN N'1.★30일 초과'
                     WHEN P.DELAY > 15 THEN N'2.16~30일'
                     WHEN P.DELAY >  7 THEN N'3.8~15일'
                     ELSE                   N'4.1~7일' END
    ,P.PO_NB                                        AS 발주번호
    ,P.PO_SQ                                        AS 발주순번
    ,P.PO_DT                                        AS 발주일
    ,P.DUE_DT                                       AS 발주납기
    ,P.FIRST_DT                                     AS 최초입고일
    ,P.LAST_DT                                      AS 최종입고일
    ,P.RCV_CNT                                      AS 입고건수
    ,P.DELAY                                        AS 지연일수
    ,P.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,P.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,P.PO_QT                                        AS 발주수량
    ,P.RCV_QT                                       AS 입고수량
    ,P.PO_AM                                        AS 발주금액
    ,조달소요일 = DATEDIFF(DAY, CONVERT(DATE,P.PO_DT), CONVERT(DATE,P.LAST_DT))
    ,발주_납기간격 = DATEDIFF(DAY, CONVERT(DATE,P.PO_DT), CONVERT(DATE,P.DUE_DT))
    ,I.LEAD_DT                                      AS 등록리드타임
    ,추정원인 = CASE
         WHEN I.LEAD_DT IS NOT NULL AND CAST(ISNULL(I.LEAD_DT,0) AS INT) > 0
          AND DATEDIFF(DAY,CONVERT(DATE,P.PO_DT),CONVERT(DATE,P.DUE_DT)) < CAST(I.LEAD_DT AS INT)
              THEN N'1.★납기 요구 자체가 리드타임보다 짧음 (우리 쪽 원인)'
         WHEN P.RCV_CNT > 1
              THEN N'2.분할입고 - 최종분 지연 (공급사 생산능력 부족)'
         WHEN P.REQ_NB IS NULL
              THEN N'3.직발주(긴급) - 사전 협의 부족 가능성'
         ELSE N'4.공급사 납기 미준수' END
    ,P.REQ_NB                                       AS 청구번호
    ,P.PJT_CD                                       AS 프로젝트
FROM       #PO    P
LEFT  JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = P.ITEM_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = P.TR_CD
WHERE  P.CLOSED = N'1' AND P.LAST_DT IS NOT NULL
  AND  P.DELAY > @TOL_DAY
ORDER BY 지연구간, P.DELAY DESC, P.PO_AM DESC
;


/*==============================================================================================
  ** 쿼리 G : 미입고 발주  ★ 평가 모집단에서 빠진 건 — 이쪽이 더 급한 경우가 많다
     ─ 쿼리 A~F 는 '입고 완결' 건만 평가한다. 아직 안 들어온 건은 여기서 본다.
==============================================================================================*/
SELECT
     N'[G] 미입고 발주'                             AS REPORT_NM
    ,긴급도 = CASE
         WHEN DATEDIFF(DAY,CONVERT(DATE,P.DUE_DT),CONVERT(DATE,@BASE_DT)) > 30 THEN N'1.★30일 초과 미입고'
         WHEN DATEDIFF(DAY,CONVERT(DATE,P.DUE_DT),CONVERT(DATE,@BASE_DT)) >  7 THEN N'2.★7일 초과 미입고'
         WHEN DATEDIFF(DAY,CONVERT(DATE,P.DUE_DT),CONVERT(DATE,@BASE_DT)) >  0 THEN N'3.납기 경과'
         WHEN DATEDIFF(DAY,CONVERT(DATE,@BASE_DT),CONVERT(DATE,P.DUE_DT)) <= 7 THEN N'4.납기 임박(7일)'
         ELSE N'5.정상 (납기 미도래)' END
    ,P.PO_NB                                        AS 발주번호
    ,P.PO_SQ                                        AS 발주순번
    ,P.PO_DT                                        AS 발주일
    ,P.DUE_DT                                       AS 발주납기
    ,납기경과일 = DATEDIFF(DAY, CONVERT(DATE,P.DUE_DT), CONVERT(DATE,@BASE_DT))
    ,P.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,P.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.UNIT_CD                                      AS 단위
    ,P.PO_QT                                        AS 발주수량
    ,P.RCV_QT                                       AS 입고수량
    ,P.PO_QT - P.RCV_QT                             AS 미입고수량
    ,(P.PO_QT - P.RCV_QT) * P.PO_UM                 AS 미입고금액
    ,입고율_PCT = CAST(P.RCV_QT / NULLIF(P.PO_QT,0) * 100 AS DECIMAL(5,1))
    ,P.LAST_DT                                      AS 최종입고일
    ,P.RCV_CNT                                      AS 입고건수
    ,상태 = CASE WHEN P.RCV_CNT = 0 THEN N'미입고' ELSE N'부분입고' END
    ,P.PJT_CD                                       AS 프로젝트
FROM       #PO    P
LEFT  JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = P.ITEM_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = P.TR_CD
WHERE  P.CLOSED = N'0'
ORDER BY 긴급도, 미입고금액 DESC
;


/*==============================================================================================
  ** 쿼리 H : 조기입고 분석  ★ 지연이 아니라고 무시하면 안 되는 항목
     ─ 너무 이른 입고는 우리 창고에 재고 부담과 조기 대금 지급을 유발한다.
==============================================================================================*/
SELECT
     N'[H] 조기입고 분석'                           AS REPORT_NM
    ,P.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,COUNT(*)                                       AS 조기입고건수
    ,SUM(P.PO_QT)                                   AS 발주수량
    ,SUM(P.PO_AM)                                   AS 발주금액
    ,평균조기일 = CAST(AVG(CAST(-P.DELAY AS DECIMAL(9,2))) AS DECIMAL(9,1))
    ,최대조기일 = MAX(-P.DELAY)
    ,경고건수 = SUM(CASE WHEN -P.DELAY > @EARLY_DAY THEN 1 ELSE 0 END)
    ,조기금액 = SUM(CASE WHEN -P.DELAY > @EARLY_DAY THEN P.PO_AM ELSE 0 END)
    ,판정 = CASE
         WHEN AVG(CAST(-P.DELAY AS DECIMAL(9,2))) > @EARLY_DAY * 2
              THEN N'1.★상시 조기입고 - 재고 부담. 납기 재협의 또는 분할 납품 요청'
         WHEN SUM(CASE WHEN -P.DELAY > @EARLY_DAY THEN 1 ELSE 0 END) > COUNT(*) * 0.5
              THEN N'2.조기입고 빈번 - 창고 적재/자금 부담 확인'
         ELSE N'0.정상 범위' END
FROM       #PO    P
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD = P.TR_CD
WHERE  P.CLOSED = N'1' AND P.LAST_DT IS NOT NULL AND P.DELAY < 0
GROUP BY P.TR_CD, T.TR_NM
HAVING COUNT(*) >= 3
ORDER BY 판정, 평균조기일 DESC
;


DROP TABLE #PO;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 발주 납기(DUE_DT) 등록률  ★ 미등록이면 평가 자체가 불가능
     SELECT COUNT(*) 전체, SUM(CASE WHEN ISNULL(DUE_DT,'')='' THEN 1 ELSE 0 END) 납기미등록
     FROM   LPO_D WHERE CO_CD='1000';

  -- (2) 평가 모집단 크기  ★ 입고 완결 건만 대상이라 분모가 얼마나 줄어드는지
     SELECT CASE WHEN ISNULL(V.RCV_QT,0) >= D.PO_QT THEN '완결' ELSE '미완결' END 구분, COUNT(*)
     FROM   LPO_D D
     OUTER APPLY (SELECT SUM(Y.RCV_QT) RCV_QT FROM LSTOCK_D Y
                  WHERE Y.CO_CD=D.CO_CD AND Y.PO_NB=D.PO_NB AND Y.PO_SQ=D.PO_SQ) V
     WHERE  D.CO_CD='1000' AND D.DUE_DT BETWEEN '20260101' AND '20261231'
     GROUP BY CASE WHEN ISNULL(V.RCV_QT,0) >= D.PO_QT THEN '완결' ELSE '미완결' END;

  -- (3) 수입 건 비중  ★ 섞어서 평가하면 국내 협력사가 부당하게 나쁘게 보인다
     SELECT LC_YN, COUNT(*) FROM LSTOCK WHERE CO_CD='1000' GROUP BY LC_YN;
     --> 수입 비중이 크면 @LC_FG='D'(국내) 와 'L'(수입) 을 각각 돌려 따로 평가할 것.

  -- (4) 현재 준수율 실측  ★ 목표선(95%)이 현실적인지 판단
     SELECT CASE WHEN DATEDIFF(DAY,D.DUE_DT,V.LAST_DT) > 0 THEN '지연'
                 WHEN DATEDIFF(DAY,D.DUE_DT,V.LAST_DT) = 0 THEN '정시' ELSE '조기' END 구분
           ,COUNT(*)
     FROM   LPO_D D
     OUTER APPLY (SELECT MAX(X.RCV_DT) LAST_DT, SUM(Y.RCV_QT) RCV_QT
                  FROM LSTOCK X INNER JOIN LSTOCK_D Y ON Y.CO_CD=X.CO_CD AND Y.RCV_NB=X.RCV_NB
                  WHERE Y.PO_NB=D.PO_NB AND Y.PO_SQ=D.PO_SQ) V
     WHERE  D.CO_CD='1000' AND V.LAST_DT IS NOT NULL AND ISNULL(V.RCV_QT,0) >= D.PO_QT
     GROUP BY CASE WHEN DATEDIFF(DAY,D.DUE_DT,V.LAST_DT) > 0 THEN '지연'
                   WHEN DATEDIFF(DAY,D.DUE_DT,V.LAST_DT) = 0 THEN '정시' ELSE '조기' END;

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **발주 납기 변경 이력을 추적하지 않는다.** `DUE_DT` 는 현재 납기이므로, 공급사가 늦어서
     납기를 고쳐 잡은 건은 지연으로 잡히지 않는다. S-03 과 동일한 구조적 약점이며,
     공급사 평가에 쓸 때는 이 점을 양측이 합의한 뒤 사용해야 한다.

  2) **품질 문제로 반품 후 재납품한 건**을 구분하지 않는다. 최종 입고일만 보므로 반품/재납품이
     있으면 지연으로 잡힌다. 공급사 입장에서는 억울할 수 있으니 이의 제기 시 개별 확인이 필요하다.

  3) `평가 모집단은 입고 완결 건`이다. 아예 안 들어온 건(쿼리 G)이 많은 공급사는 준수율이
     오히려 좋게 나올 수 있다. **쿼리 C(평가)와 쿼리 G(미입고)를 반드시 같이 볼 것.**

  4) 발주 취소 건(`EXPIRE_YN='0'`)은 `LPO_D` 필터에서 `USE_YN` 만 걸고 `EXPIRE_YN` 은 걸지
     않았다. 납기 평가는 "취소되지 않은 건"만 봐야 하므로, 취소분이 섞여 보이면
     `AND ISNULL(D.EXPIRE_YN,N'1') = N'1'` 을 #PO 적재 조건에 추가할 것.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   P01_청구발주입고_진행현황.sql : 진행 단계별 병목 (본 KPI 의 상세 추적판)
   P05_재고알람_KPI.sql          : 납기 지연이 결품으로 이어지는지
   S03_납기준수율_KPI.sql        : 우리가 고객에게 지키는 쪽 (거울상)
==============================================================================================*/
