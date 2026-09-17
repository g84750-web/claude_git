/*==============================================================================================
  [ iCUBE ] S-02  주문 미납 현황 (납기경과 구간)                                     (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 수주 라인별 미납 잔량을 납기 경과 구간으로 나눠, "지금 무엇이 얼마나 밀려 있는가"를
         영업·생산·구매가 같은 숫자로 보게 한다. 2차 현황 리포트의 출발점.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 산식 ]
  ----------------------------------------------------------------------------------------------
     미납수량 = LSO_D.SO_QT - LSO_D.ISU_QT
        ※ `LSO_D.ISU_QT` 는 **주문등록 대비 출고현황을 위한 정식 출고수량 필드**다.
          표준 산식은 이 필드를 쓴다. 출고 원장(`LDELIVER_D`) 집계는 쿼리 G 에서 대사용으로만
          쓴다 (두 값이 벌어지면 데이터 이상이지 산식 문제가 아니다).

     경과일 = DATEDIFF(DAY, LSO_D.DUE_DT, @BASE_DT)
     구간   = 납기미도래 / 당일(0) / 1~7 / 8~30 / 31일 이상

     대상   = EXPIRE_YN = '1' (진행분) AND USE_YN = '1'
     반품   = SO_QT < 0 → 별도 분리 (미납으로 섞으면 잔량이 상계되어 숨는다)

  ----------------------------------------------------------------------------------------------
  [ 주의 ]
  ----------------------------------------------------------------------------------------------
   · `EXPIRE_YN='1'` 이 **진행**이다. 반대로 걸면 결과가 비어버린다. (전 테이블 공통)
   · 반품 수주(음수)를 합산하면 거래처 미납액이 과소 표시된다 → @INC_RTN 으로 분리 제어.
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@BASE_DT  NVARCHAR(8)  = N'20260915'     -- 기준일 (경과일 산정 기준)
    ,@FR_DT    NVARCHAR(8)  = N'20260101'     -- 수주일 FROM
    ,@TO_DT    NVARCHAR(8)  = N'20261231'
    ,@TR_CD    NVARCHAR(10) = NULL            -- 특정 거래처
    ,@ITEM_CD  NVARCHAR(25) = NULL            -- 특정 품목
    ,@EMP_CD   NVARCHAR(10) = NULL            -- 영업담당
    ,@PJT_CD   NVARCHAR(10) = NULL            -- 프로젝트
    ,@INC_RTN  NCHAR(1)     = N'0'            -- 반품(음수 수주) 포함 : 0 제외 / 1 포함
    ,@EXC_Z00  NCHAR(1)     = N'1'            -- 단종품(S_CD='Z00') 제외

    ,@D1       INT = 7                        -- 경과 구간
    ,@D2       INT = 30
;

IF OBJECT_ID('tempdb..#SO')  IS NOT NULL DROP TABLE #SO;
IF OBJECT_ID('tempdb..#DLV') IS NOT NULL DROP TABLE #DLV;


/*==============================================================================================
  1. #SO : 수주 라인 + 미납 산정
==============================================================================================*/
SELECT
     H.SO_NB
    ,D.SO_SQ
    ,H.SO_DT
    ,H.TR_CD
    ,H.DIV_CD
    ,EMP_CD  = ISNULL(NULLIF(D.EMP_CD, N''), H.EMP_CD)
    ,PJT_CD  = ISNULL(NULLIF(D.PJT_CD, N''), H.PJT_CD)
    ,D.ITEM_CD
    ,D.DUE_DT
    ,SO_QT   = CAST(ISNULL(D.SO_QT , 0) AS DECIMAL(19,6))
    ,ISU_QT  = CAST(ISNULL(D.ISU_QT, 0) AS DECIMAL(19,6))
    ,BAL_QT  = CAST(ISNULL(D.SO_QT,0) - ISNULL(D.ISU_QT,0) AS DECIMAL(19,6))
    ,UM      = CAST(ISNULL(D.UM    , 0) AS DECIMAL(19,6))
    ,SO_AM   = CAST(ISNULL(D.SO_AM , 0) AS DECIMAL(19,4))
    ,BAL_AM  = CAST((ISNULL(D.SO_QT,0) - ISNULL(D.ISU_QT,0)) * ISNULL(D.UM,0) AS DECIMAL(19,4))
    ,RTN_YN  = CASE WHEN ISNULL(D.SO_QT,0) < 0 THEN N'1' ELSE N'0' END
    ,DAYS    = DATEDIFF(DAY, CONVERT(DATE, D.DUE_DT), CONVERT(DATE, @BASE_DT))
INTO #SO
FROM       LSO   H WITH (NOLOCK)
INNER JOIN LSO_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.SO_NB = H.SO_NB
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = D.CO_CD AND I.ITEM_CD = D.ITEM_CD
WHERE  H.CO_CD  = @CO_CD
  AND  H.SO_DT  BETWEEN @FR_DT AND @TO_DT
  AND  ISNULL(D.USE_YN   , N'1') = N'1'
  AND  ISNULL(D.EXPIRE_YN, N'1') = N'1'                     -- ★ '1' = 진행
  AND  ISNULL(D.SO_QT,0) - ISNULL(D.ISU_QT,0) <> 0          -- 미납 잔량 있는 건만
  AND  (@DIV_CD  IS NULL OR H.DIV_CD  = @DIV_CD)
  AND  (@TR_CD   IS NULL OR H.TR_CD   = @TR_CD)
  AND  (@ITEM_CD IS NULL OR D.ITEM_CD = @ITEM_CD)
  AND  (@PJT_CD  IS NULL OR ISNULL(NULLIF(D.PJT_CD,N''), H.PJT_CD) = @PJT_CD)
  AND  (@EMP_CD  IS NULL OR ISNULL(NULLIF(D.EMP_CD,N''), H.EMP_CD) = @EMP_CD)
  AND  (@INC_RTN = N'1' OR ISNULL(D.SO_QT,0) > 0)           -- 반품 분리
  AND  (@EXC_Z00 = N'0' OR ISNULL(I.S_CD, N'') <> N'Z00')   -- 단종품 제외
;
CREATE CLUSTERED INDEX IX_SO ON #SO (SO_NB, SO_SQ);

PRINT N'[1] 미납 수주 라인 : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 건';


/*==============================================================================================
  2. #DLV : 출고 원장 집계 (대사 및 최종출고일 산출용)
==============================================================================================*/
SELECT
     D.SO_NB
    ,D.SO_SQ
    ,DLV_QT  = SUM(CAST(ISNULL(D.ISU_QT ,0) AS DECIMAL(19,6)))
    ,DLV_AM  = SUM(CAST(ISNULL(D.ISUH_AM,0) AS DECIMAL(19,4)))
    ,DLV_CNT = COUNT(*)
    ,FIRST_DT= MIN(H.ISU_DT)
    ,LAST_DT = MAX(H.ISU_DT)
INTO #DLV
FROM       LDELIVER   H WITH (NOLOCK)
INNER JOIN LDELIVER_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.ISU_NB = H.ISU_NB
WHERE  H.CO_CD = @CO_CD
  AND  ISNULL(D.USE_YN, N'1') = N'1'
  AND  ISNULL(D.EXPIRE_YN, N'1') = N'1'
  AND  ISNULL(D.SO_NB, N'') <> N''
  AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
GROUP BY D.SO_NB, D.SO_SQ;
CREATE CLUSTERED INDEX IX_DLV ON #DLV (SO_NB, SO_SQ);


/*==============================================================================================
  ** 쿼리 A : 수주 라인별 미납 상세  (메인)
==============================================================================================*/
SELECT
     N'[A] 주문 미납 상세'                          AS REPORT_NM
    ,경과구간 = CASE WHEN S.DAYS <  0      THEN N'0.납기미도래'
                     WHEN S.DAYS =  0      THEN N'1.당일'
                     WHEN S.DAYS <= @D1    THEN N'2.1~'  + CAST(@D1 AS NVARCHAR(5)) + N'일'
                     WHEN S.DAYS <= @D2    THEN N'3.'    + CAST(@D1+1 AS NVARCHAR(5)) + N'~' + CAST(@D2 AS NVARCHAR(5)) + N'일'
                     ELSE                       N'4.★'  + CAST(@D2 AS NVARCHAR(5)) + N'일 초과' END
    ,S.SO_NB                                        AS 수주번호
    ,S.SO_SQ                                        AS 수주순번
    ,S.SO_DT                                        AS 수주일
    ,S.DUE_DT                                       AS 납기일
    ,S.DAYS                                         AS 납기경과일
    ,S.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,S.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
    ,S.SO_QT                                        AS 수주수량
    ,S.ISU_QT                                       AS 출고수량
    ,S.BAL_QT                                       AS 미납수량
    ,출고율_PCT = CAST(CASE WHEN S.SO_QT <> 0 THEN S.ISU_QT/S.SO_QT*100 END AS DECIMAL(19,2))
    ,S.UM                                           AS 단가
    ,S.SO_AM                                        AS 수주금액
    ,S.BAL_AM                                       AS 미납금액
    ,V.DLV_CNT                                      AS 출고건수
    ,V.LAST_DT                                      AS 최종출고일
    ,출고상태 = CASE WHEN ISNULL(S.ISU_QT,0) = 0 THEN N'1.미출고'
                     WHEN S.BAL_QT > 0            THEN N'2.부분출고'
                     ELSE                              N'3.초과출고' END
    ,S.PJT_CD                                       AS 프로젝트
    ,S.EMP_CD                                       AS 영업담당
    ,E.EMP_NM                                       AS 담당자명
    ,I.LEAD_DT                                      AS 리드타임일
    ,대응필요일 = CASE WHEN I.LEAD_DT IS NOT NULL
                       THEN CONVERT(NVARCHAR(8), DATEADD(DAY, -CAST(I.LEAD_DT AS INT),
                                                         CONVERT(DATE, S.DUE_DT)), 112) END
    ,S.RTN_YN                                       AS 반품여부
FROM       #SO    S
LEFT  JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = S.ITEM_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = S.TR_CD
LEFT  JOIN SEMP   E WITH (NOLOCK) ON E.CO_CD = @CO_CD AND E.EMP_CD  = S.EMP_CD
LEFT  JOIN #DLV   V ON V.SO_NB = S.SO_NB AND V.SO_SQ = S.SO_SQ
ORDER BY 경과구간 DESC, S.BAL_AM DESC
;


/*==============================================================================================
  ** 쿼리 B : 경과 구간별 집계 (피벗 — 대시보드 상단 카드)
==============================================================================================*/
SELECT
     N'[B] 경과구간별 집계'                         AS REPORT_NM
    ,@BASE_DT                                       AS 기준일
    ,건수_납기미도래 = SUM(CASE WHEN S.DAYS <  0   THEN 1 ELSE 0 END)
    ,건수_당일       = SUM(CASE WHEN S.DAYS =  0   THEN 1 ELSE 0 END)
    ,건수_1_7일      = SUM(CASE WHEN S.DAYS BETWEEN 1 AND @D1 THEN 1 ELSE 0 END)
    ,건수_8_30일     = SUM(CASE WHEN S.DAYS BETWEEN @D1+1 AND @D2 THEN 1 ELSE 0 END)
    ,건수_31일초과   = SUM(CASE WHEN S.DAYS >  @D2 THEN 1 ELSE 0 END)
    ,금액_납기미도래 = SUM(CASE WHEN S.DAYS <  0   THEN S.BAL_AM ELSE 0 END)
    ,금액_당일       = SUM(CASE WHEN S.DAYS =  0   THEN S.BAL_AM ELSE 0 END)
    ,금액_1_7일      = SUM(CASE WHEN S.DAYS BETWEEN 1 AND @D1 THEN S.BAL_AM ELSE 0 END)
    ,금액_8_30일     = SUM(CASE WHEN S.DAYS BETWEEN @D1+1 AND @D2 THEN S.BAL_AM ELSE 0 END)
    ,금액_31일초과   = SUM(CASE WHEN S.DAYS >  @D2 THEN S.BAL_AM ELSE 0 END)
    ,총건수          = COUNT(*)
    ,총미납금액      = SUM(S.BAL_AM)
    ,지연건수        = SUM(CASE WHEN S.DAYS > 0 THEN 1 ELSE 0 END)
    ,지연금액        = SUM(CASE WHEN S.DAYS > 0 THEN S.BAL_AM ELSE 0 END)
    ,지연금액비율_PCT = CAST(CASE WHEN SUM(S.BAL_AM) <> 0
                                  THEN SUM(CASE WHEN S.DAYS > 0 THEN S.BAL_AM ELSE 0 END)
                                       / SUM(S.BAL_AM) * 100 END AS DECIMAL(19,2))
    ,최장경과일      = MAX(S.DAYS)
FROM   #SO S
;


/*==============================================================================================
  ** 쿼리 C : 거래처별 미납 요약  (영업 협의용)
==============================================================================================*/
SELECT
     N'[C] 거래처별 미납'                           AS REPORT_NM
    ,S.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,COUNT(*)                                       AS 미납라인수
    ,COUNT(DISTINCT S.SO_NB)                        AS 미납수주건수
    ,COUNT(DISTINCT S.ITEM_CD)                      AS 품목수
    ,SUM(S.SO_QT)                                   AS 수주수량계
    ,SUM(S.ISU_QT)                                  AS 출고수량계
    ,SUM(S.BAL_QT)                                  AS 미납수량계
    ,SUM(S.SO_AM)                                   AS 수주금액계
    ,SUM(S.BAL_AM)                                  AS 미납금액계
    ,출고율_PCT = CAST(CASE WHEN SUM(S.SO_QT) <> 0
                            THEN SUM(S.ISU_QT)/SUM(S.SO_QT)*100 END AS DECIMAL(19,2))
    ,지연건수    = SUM(CASE WHEN S.DAYS > 0 THEN 1 ELSE 0 END)
    ,지연금액    = SUM(CASE WHEN S.DAYS > 0 THEN S.BAL_AM ELSE 0 END)
    ,장기지연금액 = SUM(CASE WHEN S.DAYS > @D2 THEN S.BAL_AM ELSE 0 END)
    ,최장경과일  = MAX(S.DAYS)
    ,최빈납기    = MIN(S.DUE_DT)
    ,등급 = CASE WHEN SUM(CASE WHEN S.DAYS > @D2 THEN S.BAL_AM ELSE 0 END) > 0 THEN N'1.★장기지연'
                 WHEN SUM(CASE WHEN S.DAYS >   0 THEN S.BAL_AM ELSE 0 END) > 0 THEN N'2.지연'
                 ELSE N'3.정상(납기내)' END
FROM       #SO    S
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD = S.TR_CD
GROUP BY S.TR_CD, T.TR_NM
ORDER BY 등급, 미납금액계 DESC
;


/*==============================================================================================
  ** 쿼리 D : 품목별 미납 요약  (생산·구매 대응 판단)
     ─ 계정구분으로 조달 경로를 구분한다. 제품/반제품 = 생산, 상품/원부재료 = 구매.
==============================================================================================*/
SELECT
     N'[D] 품목별 미납'                             AS REPORT_NM
    ,조달경로 = CASE WHEN I.ACCT_FG IN (N'2', N'4') THEN N'생산'
                     WHEN I.ACCT_FG IN (N'0', N'1', N'5') THEN N'구매'
                     ELSE N'미분류' END
    ,S.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
    ,COUNT(*)                                       AS 미납라인수
    ,COUNT(DISTINCT S.TR_CD)                        AS 거래처수
    ,SUM(S.BAL_QT)                                  AS 미납수량계
    ,SUM(S.BAL_AM)                                  AS 미납금액계
    ,MIN(S.DUE_DT)                                  AS 최단납기
    ,MAX(S.DAYS)                                    AS 최장경과일
    ,I.LEAD_DT                                      AS 리드타임일
    ,I.SAFESTOCK_QT                                 AS 안전재고
    ,조달판정 = CASE
         WHEN I.LEAD_DT IS NULL                            THEN N'9.리드타임 미등록'
         WHEN MAX(S.DAYS) > 0                              THEN N'1.★이미 납기경과 - 즉시 조치'
         WHEN MIN(DATEDIFF(DAY, CONVERT(DATE,@BASE_DT), CONVERT(DATE,S.DUE_DT)))
              < CAST(I.LEAD_DT AS INT)                     THEN N'2.리드타임 부족 - 조달 불가'
         ELSE N'3.조달 가능' END
FROM       #SO   S
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = S.ITEM_CD
GROUP BY S.ITEM_CD, I.ITEM_NM, I.SPEC, I.UNIT_CD, I.ACCT_FG, I.LEAD_DT, I.SAFESTOCK_QT
ORDER BY 조달판정, 미납금액계 DESC
;


/*==============================================================================================
  ** 쿼리 E : 납기 스케줄 전망 (월별)  — 향후 출하 부하 파악
==============================================================================================*/
SELECT
     N'[E] 납기월별 미납 전망'                      AS REPORT_NM
    ,납기월 = CASE WHEN S.DAYS > 0 THEN N'0.경과분' ELSE LEFT(S.DUE_DT, 6) END
    ,COUNT(*)                                       AS 라인수
    ,COUNT(DISTINCT S.TR_CD)                        AS 거래처수
    ,COUNT(DISTINCT S.ITEM_CD)                      AS 품목수
    ,SUM(S.BAL_QT)                                  AS 미납수량
    ,SUM(S.BAL_AM)                                  AS 미납금액
    ,생산품목_금액 = SUM(CASE WHEN I.ACCT_FG IN (N'2',N'4') THEN S.BAL_AM ELSE 0 END)
    ,구매품목_금액 = SUM(CASE WHEN I.ACCT_FG IN (N'0',N'1',N'5') THEN S.BAL_AM ELSE 0 END)
FROM       #SO   S
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = S.ITEM_CD
GROUP BY CASE WHEN S.DAYS > 0 THEN N'0.경과분' ELSE LEFT(S.DUE_DT, 6) END
ORDER BY 납기월
;


/*==============================================================================================
  ** 쿼리 F : 반품(음수 수주) 분리 조회
     ─ @INC_RTN='1' 로 실행해야 데이터가 나온다. 미납과 섞이면 잔량이 상계되어 숨는다.
==============================================================================================*/
SELECT
     N'[F] 반품 수주'                               AS REPORT_NM
    ,S.SO_NB                                        AS 수주번호
    ,S.SO_SQ                                        AS 수주순번
    ,S.SO_DT                                        AS 수주일
    ,S.DUE_DT                                       AS 납기일
    ,S.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,S.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,S.SO_QT                                        AS 수주수량_음수
    ,S.ISU_QT                                       AS 처리수량
    ,S.BAL_QT                                       AS 미처리수량
    ,S.BAL_AM                                       AS 미처리금액
    ,S.DAYS                                         AS 경과일
FROM       #SO    S
LEFT  JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = S.ITEM_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = S.TR_CD
WHERE  S.RTN_YN = N'1'
ORDER BY S.DAYS DESC
;


/*==============================================================================================
  ** 쿼리 G : ERP 대사  ─ LSO_D.ISU_QT vs 출고원장(LDELIVER_D) 집계
     ★ 두 값은 일치해야 정상이다. 차이가 나면 데이터 이상이므로 원인을 먼저 잡아야 한다.
==============================================================================================*/
SELECT
     N'[G] 출고수량 대사'                           AS REPORT_NM
    ,S.SO_NB                                        AS 수주번호
    ,S.SO_SQ                                        AS 수주순번
    ,S.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,S.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,S.SO_QT                                        AS 수주수량
    ,S.ISU_QT                                       AS 수주상세_출고수량
    ,ISNULL(V.DLV_QT, 0)                            AS 출고원장_합계
    ,S.ISU_QT - ISNULL(V.DLV_QT, 0)                 AS 차이
    ,ISNULL(V.DLV_CNT, 0)                           AS 출고건수
    ,V.LAST_DT                                      AS 최종출고일
    ,판정 = CASE
         WHEN ABS(S.ISU_QT - ISNULL(V.DLV_QT,0)) < 0.000001 THEN N'0.일치'
         WHEN V.DLV_QT IS NULL AND S.ISU_QT <> 0            THEN N'1.★출고원장 없음 (SO_NB 연결 끊김)'
         WHEN S.ISU_QT > ISNULL(V.DLV_QT,0)                 THEN N'2.★상세 > 원장 (출고 취소분 미반영 의심)'
         ELSE                                                    N'3.★원장 > 상세 (요약 갱신 누락 의심)' END
FROM       #SO    S
LEFT  JOIN #DLV   V ON V.SO_NB = S.SO_NB AND V.SO_SQ = S.SO_SQ
LEFT  JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = S.ITEM_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = S.TR_CD
WHERE  ABS(S.ISU_QT - ISNULL(V.DLV_QT, 0)) >= 0.000001
ORDER BY ABS(S.ISU_QT - ISNULL(V.DLV_QT, 0)) DESC
;


DROP TABLE #SO, #DLV;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) EXPIRE_YN 분포  ★ 이 쿼리 전체의 전제
     SELECT EXPIRE_YN, COUNT(*) 건수, SUM(SO_QT-ISNULL(ISU_QT,0)) 잔량
     FROM   LSO_D WHERE CO_CD='1000' GROUP BY EXPIRE_YN;
     --> '1'(진행) 쪽에 미출고 잔량이 몰려 있어야 정상.

  -- (2) LSO_D.ISU_QT 갱신 정합성  ★ 쿼리 G 를 먼저 돌려보는 것과 같은 목적
     SELECT COUNT(*) FROM LSO_D D WHERE CO_CD='1000'
      AND  ISNULL(D.ISU_QT,0) <> (SELECT ISNULL(SUM(X.ISU_QT),0) FROM LDELIVER_D X
                                  WHERE X.CO_CD=D.CO_CD AND X.SO_NB=D.SO_NB AND X.SO_SQ=D.SO_SQ);
     --> 0 이면 이상적. 건수가 많으면 쿼리 G 로 원인 유형을 먼저 분류할 것.

  -- (3) 납기일(DUE_DT) 미등록 건
     SELECT COUNT(*) FROM LSO_D WHERE CO_CD='1000' AND ISNULL(DUE_DT,'')='';
     --> 미등록이면 경과일이 NULL 이 되어 구간 분류에서 빠진다. 등록 독려 필요.

  -- (4) 반품(음수 수주) 규모
     SELECT COUNT(*) 건수, SUM(SO_QT) 수량 FROM LSO_D WHERE CO_CD='1000' AND SO_QT < 0;

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) 납기 변경 이력은 추적하지 않는다. `DUE_DT` 는 **현재 납기**이므로, 고객이 납기를 미뤄준
     건은 지연으로 잡히지 않는다. 원납기 대비 평가가 필요하면 관리항목 또는 `DUMMY*` 컬럼에
     원납기를 보관하는지 먼저 확인할 것.

  2) `BAL_AM`(미납금액)은 **수주 단가 기준**이다. 환종 수주(`LSO.EXCH_FG`)가 있는 사이트는
     원화 환산이 필요하므로 `EXCH_RT` 를 곱하는 로직을 추가해야 한다.

  3) 미납 원인(자재 결품 / 생산 지연 / 고객 요청 보류)은 이 쿼리로 구분되지 않는다.
     원인까지 보려면 S-01 수주진행총괄(`수주진행총괄현황.sql`)의 진행단계와 붙여야 한다.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   수주진행총괄현황.sql : 수주 1건의 전 단계 추적 (미납 원인 규명)
   S06_채권여신_관리현황.sql : 출고 이후 채권 단계
==============================================================================================*/
