/*==============================================================================================
  [ iCUBE ] P-01  청구 → 발주 → 입고 진행현황                                       (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 구매 요청(청구)이 발주되었는지, 입고되었는지, **어디서 막혔는지**를 한 화면에서.
         구매팀 처리속도(발주소요일)와 협력사 납기(입고지연일)를 분리해 책임 소재를 가른다.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 소스 체인 ]
  ----------------------------------------------------------------------------------------------
     LPUR_REQ / LPUR_REQ_D   청구   REQ_NB + REQ_SQ
       └→ LPO / LPO_D        발주   (LPO_D 가 REQ_NB + REQ_SQ 보유)
            └→ LSTOCK_D      입고   PO_NB + PO_SQ
                 └→ LPURCLS_D 매입마감  RCV_NB + RCV_SQ

  ----------------------------------------------------------------------------------------------
  [ 산식 ]
  ----------------------------------------------------------------------------------------------
     진행단계 = CASE WHEN 마감량 >= 입고량 AND 입고량>0   THEN '4.마감'
                     WHEN 입고량 >= 발주량 AND 발주량>0   THEN '3.입고완료'
                     WHEN 입고량 > 0                      THEN '2.부분입고'
                     WHEN 발주량 > 0                      THEN '1.발주'
                     ELSE                                      '0.미발주' END

     미발주수량 = PREQ_QT - 발주합계          ← 구매팀 미처리
     미입고수량 = PO_QT   - 입고합계          ← 협력사 미납
     발주소요일 = DATEDIFF(DAY, REQ_DT, PO_DT)        구매팀 처리속도 KPI
     입고지연일 = DATEDIFF(DAY, LPO_D.DUE_DT, RCV_DT) 협력사 납기 KPI

  ----------------------------------------------------------------------------------------------
  [ 설계상 반드시 지킨 것 ]
  ----------------------------------------------------------------------------------------------
   1. **집계 후 조인.** 청구 1건 → 발주 N건, 발주 1건 → 입고 N건이 흔하다. 원장을 직접 조인하면
      행이 증식(fan-out)해 금액이 부풀려진다. 발주/입고/마감을 각각 임시테이블에 미리 집계한 뒤
      LEFT JOIN 한다.
   2. **긴급발주 분리.** 청구 없이 바로 발주한 건(`REQ_NB` 없음)은 `발주소요일` 분모를 왜곡하므로
      쿼리 C 에서 `직발주` 로 따로 집계한다.
   3. **수입 건 분리.** `LSTOCK.LC_YN='1'` 은 입고 시점이 통관 기준이라 국내와 성격이 다르다.
      쿼리 G 에서 별도 조회.
   4. `EXPIRE_YN='1'` 이 **진행**. 반대로 걸면 결과가 비어버린다.
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@BASE_DT  NVARCHAR(8)  = N'20260915'     -- 기준일 (경과일 산정)
    ,@FR_DT    NVARCHAR(8)  = N'20260101'     -- 청구일/발주일 FROM
    ,@TO_DT    NVARCHAR(8)  = N'20261231'
    ,@TR_CD    NVARCHAR(10) = NULL            -- 특정 거래처
    ,@ITEM_CD  NVARCHAR(25) = NULL
    ,@PJT_CD   NVARCHAR(10) = NULL
    ,@DEPT_CD  NVARCHAR(10) = NULL            -- 청구부서
    ,@EXC_Z00  NCHAR(1)     = N'1'            -- 단종품 제외
    ,@ONLY_OPEN NCHAR(1)    = N'0'            -- 1 = 미완결(미발주/미입고)만
;

IF OBJECT_ID('tempdb..#REQ')  IS NOT NULL DROP TABLE #REQ;
IF OBJECT_ID('tempdb..#POR')  IS NOT NULL DROP TABLE #POR;
IF OBJECT_ID('tempdb..#PO')   IS NOT NULL DROP TABLE #PO;
IF OBJECT_ID('tempdb..#RCVP') IS NOT NULL DROP TABLE #RCVP;
IF OBJECT_ID('tempdb..#CLSR') IS NOT NULL DROP TABLE #CLSR;


/*==============================================================================================
  1. #REQ : 청구 라인
==============================================================================================*/
SELECT
     H.REQ_NB
    ,D.REQ_SQ
    ,H.REQ_DT
    ,H.DIV_CD
    ,DEPT_CD = ISNULL(NULLIF(D.DEPT_CD, N''), H.DEPT_CD)
    ,EMP_CD  = ISNULL(NULLIF(D.EMP_CD , N''), H.EMP_CD)
    ,D.ITEM_CD
    ,D.TR_CD
    ,D.DUE_DT
    ,D.PJT_CD
    ,REQODR_FG = ISNULL(D.REQODR_FG, N'0')                  -- 0.구매 1.생산
    ,REQ_QT  = CAST(ISNULL(D.PREQ_QT, 0) AS DECIMAL(19,6))
    ,REQ_UM  = CAST(ISNULL(D.UM     , 0) AS DECIMAL(19,6))
    ,REQ_AM  = CAST(ISNULL(D.PREQ_QT,0) * ISNULL(D.UM,0) AS DECIMAL(19,4))
INTO #REQ
FROM       LPUR_REQ   H WITH (NOLOCK)
INNER JOIN LPUR_REQ_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.REQ_NB = H.REQ_NB
LEFT  JOIN SITEM      I WITH (NOLOCK) ON I.CO_CD = D.CO_CD AND I.ITEM_CD = D.ITEM_CD
WHERE  H.CO_CD  = @CO_CD
  AND  H.REQ_DT BETWEEN @FR_DT AND @TO_DT
  AND  ISNULL(D.USE_YN   , N'1') = N'1'
  AND  ISNULL(D.EXPIRE_YN, N'1') = N'1'                     -- ★ '1' = 진행
  AND  (@DIV_CD  IS NULL OR H.DIV_CD  = @DIV_CD)
  AND  (@TR_CD   IS NULL OR D.TR_CD   = @TR_CD)
  AND  (@ITEM_CD IS NULL OR D.ITEM_CD = @ITEM_CD)
  AND  (@PJT_CD  IS NULL OR D.PJT_CD  = @PJT_CD)
  AND  (@DEPT_CD IS NULL OR ISNULL(NULLIF(D.DEPT_CD,N''), H.DEPT_CD) = @DEPT_CD)
  AND  (@EXC_Z00 = N'0' OR ISNULL(I.S_CD, N'') <> N'Z00')
;
CREATE CLUSTERED INDEX IX_REQ ON #REQ (REQ_NB, REQ_SQ);
PRINT N'[1] 청구 라인 : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 건';


/*==============================================================================================
  2. #PO : 발주 라인  (직발주 포함)
==============================================================================================*/
SELECT
     H.PO_NB
    ,D.PO_SQ
    ,H.PO_DT
    ,H.TR_CD
    ,H.DIV_CD
    ,EMP_CD = ISNULL(NULLIF(D.EMP_CD, N''), H.EMP_CD)
    ,D.ITEM_CD
    ,D.DUE_DT
    ,D.PJT_CD
    ,REQ_NB = NULLIF(D.REQ_NB, N'')
    ,REQ_SQ = D.REQ_SQ
    ,PO_QT  = CAST(ISNULL(D.PO_QT, 0) AS DECIMAL(19,6))
    ,PO_UM  = CAST(ISNULL(D.UM   , 0) AS DECIMAL(19,6))
    ,PO_AM  = CAST(ISNULL(D.PO_AM, 0) AS DECIMAL(19,4))
INTO #PO
FROM       LPO   H WITH (NOLOCK)
INNER JOIN LPO_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.PO_NB = H.PO_NB
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = D.CO_CD AND I.ITEM_CD = D.ITEM_CD
WHERE  H.CO_CD = @CO_CD
  AND  H.PO_DT BETWEEN @FR_DT AND @TO_DT
  AND  ISNULL(D.USE_YN   , N'1') = N'1'
  AND  ISNULL(D.EXPIRE_YN, N'1') = N'1'
  AND  (@DIV_CD  IS NULL OR H.DIV_CD  = @DIV_CD)
  AND  (@TR_CD   IS NULL OR H.TR_CD   = @TR_CD)
  AND  (@ITEM_CD IS NULL OR D.ITEM_CD = @ITEM_CD)
  AND  (@PJT_CD  IS NULL OR D.PJT_CD  = @PJT_CD)
  AND  (@EXC_Z00 = N'0' OR ISNULL(I.S_CD, N'') <> N'Z00')
;
CREATE CLUSTERED INDEX IX_PO ON #PO (PO_NB, PO_SQ);
PRINT N'[2] 발주 라인 : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 건';


/*==============================================================================================
  3. #RCVP : 발주별 입고 집계   ★ 집계 후 조인 (fan-out 차단)
==============================================================================================*/
SELECT
     D.PO_NB
    ,D.PO_SQ
    ,RCV_QT   = SUM(CAST(ISNULL(D.RCV_QT ,0) AS DECIMAL(19,6)))
    ,RCV_AM   = SUM(CAST(ISNULL(D.RCV_AM ,0) AS DECIMAL(19,4)))
    ,RCV_CNT  = COUNT(*)
    ,FIRST_DT = MIN(H.RCV_DT)
    ,LAST_DT  = MAX(H.RCV_DT)
    ,LC_CNT   = SUM(CASE WHEN ISNULL(H.LC_YN, N'0') = N'1' THEN 1 ELSE 0 END)
INTO #RCVP
FROM       LSTOCK   H WITH (NOLOCK)
INNER JOIN LSTOCK_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.RCV_NB = H.RCV_NB
WHERE  H.CO_CD = @CO_CD
  AND  ISNULL(D.USE_YN   , N'1') = N'1'
  AND  ISNULL(D.EXPIRE_YN, N'1') = N'1'
  AND  ISNULL(D.PO_NB, N'') <> N''
  AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
GROUP BY D.PO_NB, D.PO_SQ;
CREATE CLUSTERED INDEX IX_RCVP ON #RCVP (PO_NB, PO_SQ);


/*==============================================================================================
  4. #CLSR : 발주별 매입마감 집계 (입고 경유)
==============================================================================================*/
SELECT
     S.PO_NB
    ,S.PO_SQ
    ,CLS_QT  = SUM(CAST(ISNULL(CD.CLS_QT ,0) AS DECIMAL(19,6)))
    ,CLS_AM  = SUM(CAST(ISNULL(CD.CLSH_AM,0) AS DECIMAL(19,4)))
    ,CLS_CNT = COUNT(*)
    ,LAST_DT = MAX(CH.CLS_DT)
INTO #CLSR
FROM       LPURCLS   CH WITH (NOLOCK)
INNER JOIN LPURCLS_D CD WITH (NOLOCK) ON CD.CO_CD = CH.CO_CD AND CD.CLS_NB = CH.CLS_NB
INNER JOIN LSTOCK_D  S  WITH (NOLOCK) ON S.CO_CD  = CD.CO_CD
                                     AND S.RCV_NB = CD.RCV_NB AND S.RCV_SQ = CD.RCV_SQ
WHERE  CH.CO_CD = @CO_CD
  AND  ISNULL(CD.USE_YN   , N'1') = N'1'
  AND  ISNULL(CD.EXPIRE_YN, N'1') = N'1'
  AND  ISNULL(S.PO_NB, N'') <> N''
  AND  (@DIV_CD IS NULL OR CH.DIV_CD = @DIV_CD)
GROUP BY S.PO_NB, S.PO_SQ;
CREATE CLUSTERED INDEX IX_CLSR ON #CLSR (PO_NB, PO_SQ);


/*==============================================================================================
  5. #POR : 청구별 발주 집계   ★ 집계 후 조인
     발주에 딸린 입고/마감까지 여기서 미리 합산해 청구 1행에 붙일 수 있게 만든다.
==============================================================================================*/
SELECT
     P.REQ_NB
    ,P.REQ_SQ
    ,PO_QT   = SUM(P.PO_QT)
    ,PO_AM   = SUM(P.PO_AM)
    ,PO_CNT  = COUNT(*)
    ,FIRST_DT= MIN(P.PO_DT)
    ,LAST_DT = MAX(P.PO_DT)
    ,DUE_DT  = MIN(P.DUE_DT)
    ,RCV_QT  = SUM(ISNULL(R.RCV_QT, 0))
    ,RCV_AM  = SUM(ISNULL(R.RCV_AM, 0))
    ,RCV_LAST= MAX(R.LAST_DT)
    ,CLS_QT  = SUM(ISNULL(C.CLS_QT, 0))
    ,CLS_AM  = SUM(ISNULL(C.CLS_AM, 0))
INTO #POR
FROM       #PO   P
LEFT  JOIN #RCVP R ON R.PO_NB = P.PO_NB AND R.PO_SQ = P.PO_SQ
LEFT  JOIN #CLSR C ON C.PO_NB = P.PO_NB AND C.PO_SQ = P.PO_SQ
WHERE  P.REQ_NB IS NOT NULL
GROUP BY P.REQ_NB, P.REQ_SQ;
CREATE CLUSTERED INDEX IX_POR ON #POR (REQ_NB, REQ_SQ);


/*==============================================================================================
  ** 쿼리 A : 청구 라인별 진행현황  (메인)
==============================================================================================*/
SELECT
     N'[A] 청구→발주→입고 진행'                    AS REPORT_NM
    ,진행단계 = CASE
         WHEN ISNULL(O.CLS_QT,0) > 0 AND ISNULL(O.CLS_QT,0) >= ISNULL(O.RCV_QT,0) THEN N'4.마감'
         WHEN ISNULL(O.RCV_QT,0) > 0 AND ISNULL(O.RCV_QT,0) >= ISNULL(O.PO_QT ,0) THEN N'3.입고완료'
         WHEN ISNULL(O.RCV_QT,0) > 0                                              THEN N'2.부분입고'
         WHEN ISNULL(O.PO_QT ,0) > 0                                              THEN N'1.발주'
         ELSE                                                                          N'0.★미발주' END
    ,R.REQ_NB                                       AS 청구번호
    ,R.REQ_SQ                                       AS 청구순번
    ,R.REQ_DT                                       AS 청구일
    ,R.DUE_DT                                       AS 입고요청일
    ,조달구분 = CASE R.REQODR_FG WHEN N'0' THEN N'구매' WHEN N'1' THEN N'생산' ELSE R.REQODR_FG END
    ,R.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,R.TR_CD                                        AS 청구거래처
    ,T.TR_NM                                        AS 거래처명
    ,R.DEPT_CD                                      AS 청구부서
    ,P.DEPT_NM                                      AS 부서명

    -- 청구
    ,R.REQ_QT                                       AS 청구수량
    ,R.REQ_AM                                       AS 청구금액
    -- 발주
    ,ISNULL(O.PO_QT , 0)                            AS 발주수량
    ,ISNULL(O.PO_AM , 0)                            AS 발주금액
    ,ISNULL(O.PO_CNT, 0)                            AS 발주건수
    ,O.FIRST_DT                                     AS 최초발주일
    ,O.DUE_DT                                       AS 발주납기
    ,R.REQ_QT - ISNULL(O.PO_QT, 0)                  AS 미발주수량
    -- 입고
    ,ISNULL(O.RCV_QT, 0)                            AS 입고수량
    ,ISNULL(O.RCV_AM, 0)                            AS 입고금액
    ,O.RCV_LAST                                     AS 최종입고일
    ,ISNULL(O.PO_QT,0) - ISNULL(O.RCV_QT,0)         AS 미입고수량
    -- 마감
    ,ISNULL(O.CLS_QT, 0)                            AS 마감수량
    ,ISNULL(O.CLS_AM, 0)                            AS 마감금액

    -- KPI
    ,발주소요일 = DATEDIFF(DAY, CONVERT(DATE,R.REQ_DT), CONVERT(DATE,O.FIRST_DT))
    ,입고지연일 = DATEDIFF(DAY, CONVERT(DATE,O.DUE_DT), CONVERT(DATE,O.RCV_LAST))
    ,청구경과일 = DATEDIFF(DAY, CONVERT(DATE,R.REQ_DT), CONVERT(DATE,@BASE_DT))
    ,요청일경과 = CASE WHEN R.DUE_DT IS NOT NULL
                       THEN DATEDIFF(DAY, CONVERT(DATE,R.DUE_DT), CONVERT(DATE,@BASE_DT)) END
    ,병목 = CASE
         WHEN ISNULL(O.PO_QT,0) = 0 AND DATEDIFF(DAY,CONVERT(DATE,R.REQ_DT),CONVERT(DATE,@BASE_DT)) > 7
              THEN N'1.★구매팀 (7일 이상 미발주)'
         WHEN ISNULL(O.PO_QT,0) = 0
              THEN N'2.구매팀 (발주 대기)'
         WHEN ISNULL(O.RCV_QT,0) < ISNULL(O.PO_QT,0)
              AND DATEDIFF(DAY,CONVERT(DATE,O.DUE_DT),CONVERT(DATE,@BASE_DT)) > 0
              THEN N'3.★협력사 (납기 경과)'
         WHEN ISNULL(O.RCV_QT,0) < ISNULL(O.PO_QT,0)
              THEN N'4.협력사 (입고 대기)'
         WHEN ISNULL(O.CLS_QT,0) < ISNULL(O.RCV_QT,0)
              THEN N'5.구매마감 미처리'
         ELSE N'0.완료' END
    ,R.PJT_CD                                       AS 프로젝트
FROM       #REQ  R
LEFT  JOIN #POR  O ON O.REQ_NB = R.REQ_NB AND O.REQ_SQ = R.REQ_SQ
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = R.ITEM_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD  = R.TR_CD
LEFT  JOIN SDEPT P WITH (NOLOCK) ON P.CO_CD = @CO_CD AND P.DEPT_CD = R.DEPT_CD
WHERE  @ONLY_OPEN = N'0'
   OR  R.REQ_QT - ISNULL(O.PO_QT,0) <> 0
   OR  ISNULL(O.PO_QT,0) - ISNULL(O.RCV_QT,0) <> 0
ORDER BY 병목, R.REQ_DT
;


/*==============================================================================================
  ** 쿼리 B : 진행단계별 집계 (대시보드 상단)
==============================================================================================*/
;WITH X AS (
    SELECT
         R.REQ_QT, R.REQ_AM
        ,PO_QT  = ISNULL(O.PO_QT ,0), PO_AM  = ISNULL(O.PO_AM ,0)
        ,RCV_QT = ISNULL(O.RCV_QT,0), RCV_AM = ISNULL(O.RCV_AM,0)
        ,CLS_QT = ISNULL(O.CLS_QT,0)
        ,STG = CASE
             WHEN ISNULL(O.CLS_QT,0) > 0 AND ISNULL(O.CLS_QT,0) >= ISNULL(O.RCV_QT,0) THEN N'4.마감'
             WHEN ISNULL(O.RCV_QT,0) > 0 AND ISNULL(O.RCV_QT,0) >= ISNULL(O.PO_QT ,0) THEN N'3.입고완료'
             WHEN ISNULL(O.RCV_QT,0) > 0                                              THEN N'2.부분입고'
             WHEN ISNULL(O.PO_QT ,0) > 0                                              THEN N'1.발주'
             ELSE                                                                          N'0.미발주' END
    FROM      #REQ R
    LEFT JOIN #POR O ON O.REQ_NB = R.REQ_NB AND O.REQ_SQ = R.REQ_SQ
)
SELECT
     N'[B] 진행단계별 집계'                         AS REPORT_NM
    ,X.STG                                          AS 진행단계
    ,COUNT(*)                                       AS 청구라인수
    ,SUM(X.REQ_QT)                                  AS 청구수량
    ,SUM(X.REQ_AM)                                  AS 청구금액
    ,SUM(X.PO_QT)                                   AS 발주수량
    ,SUM(X.PO_AM)                                   AS 발주금액
    ,SUM(X.RCV_QT)                                  AS 입고수량
    ,SUM(X.RCV_AM)                                  AS 입고금액
    ,SUM(X.REQ_QT - X.PO_QT)                        AS 미발주수량
    ,SUM(X.PO_QT  - X.RCV_QT)                       AS 미입고수량
    ,구성비_PCT = CAST(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0) AS DECIMAL(5,1))
FROM   X
GROUP BY X.STG
ORDER BY X.STG
;


/*==============================================================================================
  ** 쿼리 C : 발주 라인별 입고현황 (직발주 포함)
     ─ `발주경로` 로 청구경유/직발주를 구분한다. 직발주를 섞으면 발주소요일 KPI 가 왜곡된다.
==============================================================================================*/
SELECT
     N'[C] 발주별 입고현황'                         AS REPORT_NM
    ,발주경로 = CASE WHEN P.REQ_NB IS NULL THEN N'2.직발주(긴급)' ELSE N'1.청구경유' END
    ,입고상태 = CASE WHEN ISNULL(R.RCV_QT,0) >= P.PO_QT AND P.PO_QT > 0 THEN N'3.입고완료'
                     WHEN ISNULL(R.RCV_QT,0) > 0                        THEN N'2.부분입고'
                     ELSE                                                    N'1.미입고' END
    ,P.PO_NB                                        AS 발주번호
    ,P.PO_SQ                                        AS 발주순번
    ,P.PO_DT                                        AS 발주일
    ,P.DUE_DT                                       AS 발주납기
    ,P.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,P.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.UNIT_CD                                      AS 단위
    ,P.PO_QT                                        AS 발주수량
    ,P.PO_UM                                        AS 발주단가
    ,P.PO_AM                                        AS 발주금액
    ,ISNULL(R.RCV_QT , 0)                           AS 입고수량
    ,ISNULL(R.RCV_AM , 0)                           AS 입고금액
    ,ISNULL(R.RCV_CNT, 0)                           AS 입고건수
    ,P.PO_QT - ISNULL(R.RCV_QT, 0)                  AS 미입고수량
    ,(P.PO_QT - ISNULL(R.RCV_QT,0)) * P.PO_UM       AS 미입고금액
    ,입고율_PCT = CAST(CASE WHEN P.PO_QT <> 0
                            THEN ISNULL(R.RCV_QT,0)/P.PO_QT*100 END AS DECIMAL(19,2))
    ,R.FIRST_DT                                     AS 최초입고일
    ,R.LAST_DT                                      AS 최종입고일
    ,ISNULL(C.CLS_QT, 0)                            AS 마감수량
    ,ISNULL(C.CLS_AM, 0)                            AS 마감금액
    ,납기경과일 = DATEDIFF(DAY, CONVERT(DATE,P.DUE_DT), CONVERT(DATE,@BASE_DT))
    ,입고지연일 = DATEDIFF(DAY, CONVERT(DATE,P.DUE_DT), CONVERT(DATE,R.LAST_DT))
    ,발주소요일 = CASE WHEN P.REQ_NB IS NOT NULL
                       THEN DATEDIFF(DAY, CONVERT(DATE,Q.REQ_DT), CONVERT(DATE,P.PO_DT)) END
    ,납기리스크 = CASE
         WHEN ISNULL(R.RCV_QT,0) >= P.PO_QT                                          THEN N'0.완료'
         WHEN DATEDIFF(DAY,CONVERT(DATE,P.DUE_DT),CONVERT(DATE,@BASE_DT)) > 30        THEN N'1.★30일 초과'
         WHEN DATEDIFF(DAY,CONVERT(DATE,P.DUE_DT),CONVERT(DATE,@BASE_DT)) > 0         THEN N'2.납기경과'
         WHEN DATEDIFF(DAY,CONVERT(DATE,@BASE_DT),CONVERT(DATE,P.DUE_DT)) <= 7        THEN N'3.납기임박(7일)'
         ELSE N'4.정상' END
    ,P.PJT_CD                                       AS 프로젝트
FROM       #PO    P
LEFT  JOIN #RCVP  R ON R.PO_NB = P.PO_NB AND R.PO_SQ = P.PO_SQ
LEFT  JOIN #CLSR  C ON C.PO_NB = P.PO_NB AND C.PO_SQ = P.PO_SQ
LEFT  JOIN #REQ   Q ON Q.REQ_NB = P.REQ_NB AND Q.REQ_SQ = P.REQ_SQ
LEFT  JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = P.ITEM_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = P.TR_CD
WHERE  @ONLY_OPEN = N'0' OR P.PO_QT - ISNULL(R.RCV_QT,0) <> 0
ORDER BY 납기리스크, 미입고금액 DESC
;


/*==============================================================================================
  ** 쿼리 D : 미발주 청구  (구매팀 작업지시서)
==============================================================================================*/
SELECT
     N'[D] 미발주 청구'                             AS REPORT_NM
    ,긴급도 = CASE WHEN DATEDIFF(DAY,CONVERT(DATE,R.REQ_DT),CONVERT(DATE,@BASE_DT)) > 14 THEN N'1.★14일 경과'
                   WHEN DATEDIFF(DAY,CONVERT(DATE,R.REQ_DT),CONVERT(DATE,@BASE_DT)) >  7 THEN N'2.7일 경과'
                   WHEN R.DUE_DT IS NOT NULL
                    AND DATEDIFF(DAY,CONVERT(DATE,@BASE_DT),CONVERT(DATE,R.DUE_DT))
                        < ISNULL(CAST(NULLIF(I.LEAD_DT,0) AS INT), 0)                    THEN N'3.리드타임 부족'
                   ELSE N'4.정상' END
    ,R.REQ_NB                                       AS 청구번호
    ,R.REQ_SQ                                       AS 청구순번
    ,R.REQ_DT                                       AS 청구일
    ,R.DUE_DT                                       AS 입고요청일
    ,경과일 = DATEDIFF(DAY, CONVERT(DATE,R.REQ_DT), CONVERT(DATE,@BASE_DT))
    ,R.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,R.REQ_QT                                       AS 청구수량
    ,ISNULL(O.PO_QT, 0)                             AS 기발주수량
    ,R.REQ_QT - ISNULL(O.PO_QT, 0)                  AS 미발주수량
    ,(R.REQ_QT - ISNULL(O.PO_QT,0)) * R.REQ_UM      AS 미발주금액
    ,R.TR_CD                                        AS 권장거래처
    ,T.TR_NM                                        AS 거래처명
    ,I.LEAD_DT                                      AS 리드타임일
    ,발주마감일 = CASE WHEN R.DUE_DT IS NOT NULL AND I.LEAD_DT IS NOT NULL
                       THEN CONVERT(NVARCHAR(8), DATEADD(DAY, -CAST(I.LEAD_DT AS INT),
                                                         CONVERT(DATE, R.DUE_DT)), 112) END
    ,R.DEPT_CD                                      AS 청구부서
    ,P.DEPT_NM                                      AS 부서명
    ,R.EMP_CD                                       AS 청구자
    ,R.PJT_CD                                       AS 프로젝트
FROM       #REQ   R
LEFT  JOIN #POR   O ON O.REQ_NB = R.REQ_NB AND O.REQ_SQ = R.REQ_SQ
LEFT  JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = R.ITEM_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = R.TR_CD
LEFT  JOIN SDEPT  P WITH (NOLOCK) ON P.CO_CD = @CO_CD AND P.DEPT_CD = R.DEPT_CD
WHERE  R.REQ_QT - ISNULL(O.PO_QT, 0) > 0
ORDER BY 긴급도, 미발주금액 DESC
;


/*==============================================================================================
  ** 쿼리 E : 거래처별 납기 KPI
     ─ 발주소요일(구매팀) 과 입고지연일(협력사) 을 분리해 책임을 가른다.
==============================================================================================*/
SELECT
     N'[E] 거래처별 납기 KPI'                       AS REPORT_NM
    ,P.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,COUNT(*)                                       AS 발주라인수
    ,COUNT(DISTINCT P.ITEM_CD)                      AS 품목수
    ,SUM(P.PO_QT)                                   AS 발주수량계
    ,SUM(P.PO_AM)                                   AS 발주금액계
    ,SUM(ISNULL(R.RCV_QT,0))                        AS 입고수량계
    ,SUM(P.PO_QT - ISNULL(R.RCV_QT,0))              AS 미입고수량계
    ,입고완료건수 = SUM(CASE WHEN ISNULL(R.RCV_QT,0) >= P.PO_QT THEN 1 ELSE 0 END)
    ,납기준수건수 = SUM(CASE WHEN ISNULL(R.RCV_QT,0) >= P.PO_QT
                              AND DATEDIFF(DAY,CONVERT(DATE,P.DUE_DT),CONVERT(DATE,R.LAST_DT)) <= 0
                             THEN 1 ELSE 0 END)
    ,납기준수율_PCT = CAST(
         SUM(CASE WHEN ISNULL(R.RCV_QT,0) >= P.PO_QT
                   AND DATEDIFF(DAY,CONVERT(DATE,P.DUE_DT),CONVERT(DATE,R.LAST_DT)) <= 0
                  THEN 1.0 ELSE 0 END)
         / NULLIF(SUM(CASE WHEN ISNULL(R.RCV_QT,0) >= P.PO_QT THEN 1.0 ELSE 0 END), 0) * 100
         AS DECIMAL(5,1))
    ,평균입고지연일 = CAST(AVG(CASE WHEN ISNULL(R.RCV_QT,0) >= P.PO_QT
                                     AND DATEDIFF(DAY,CONVERT(DATE,P.DUE_DT),CONVERT(DATE,R.LAST_DT)) > 0
                                    THEN CAST(DATEDIFF(DAY,CONVERT(DATE,P.DUE_DT),CONVERT(DATE,R.LAST_DT)) AS DECIMAL(9,2))
                                    END) AS DECIMAL(9,1))
    ,최대입고지연일 = MAX(CASE WHEN ISNULL(R.RCV_QT,0) >= P.PO_QT
                               THEN DATEDIFF(DAY,CONVERT(DATE,P.DUE_DT),CONVERT(DATE,R.LAST_DT)) END)
    ,평균발주소요일 = CAST(AVG(CASE WHEN P.REQ_NB IS NOT NULL
                                    THEN CAST(DATEDIFF(DAY,CONVERT(DATE,Q.REQ_DT),CONVERT(DATE,P.PO_DT)) AS DECIMAL(9,2))
                                    END) AS DECIMAL(9,1))
    ,직발주건수 = SUM(CASE WHEN P.REQ_NB IS NULL THEN 1 ELSE 0 END)
    ,등급 = CASE
         WHEN SUM(CASE WHEN ISNULL(R.RCV_QT,0) >= P.PO_QT THEN 1 ELSE 0 END) = 0 THEN N'9.입고완료 없음'
         WHEN SUM(CASE WHEN ISNULL(R.RCV_QT,0) >= P.PO_QT
                        AND DATEDIFF(DAY,CONVERT(DATE,P.DUE_DT),CONVERT(DATE,R.LAST_DT)) <= 0
                       THEN 1.0 ELSE 0 END)
              / NULLIF(SUM(CASE WHEN ISNULL(R.RCV_QT,0) >= P.PO_QT THEN 1.0 ELSE 0 END),0) >= 0.95
                                                                                  THEN N'1.우수(95%+)'
         WHEN SUM(CASE WHEN ISNULL(R.RCV_QT,0) >= P.PO_QT
                        AND DATEDIFF(DAY,CONVERT(DATE,P.DUE_DT),CONVERT(DATE,R.LAST_DT)) <= 0
                       THEN 1.0 ELSE 0 END)
              / NULLIF(SUM(CASE WHEN ISNULL(R.RCV_QT,0) >= P.PO_QT THEN 1.0 ELSE 0 END),0) >= 0.80
                                                                                  THEN N'2.보통(80%+)'
         ELSE N'3.★개선필요' END
FROM       #PO    P
LEFT  JOIN #RCVP  R ON R.PO_NB = P.PO_NB AND R.PO_SQ = P.PO_SQ
LEFT  JOIN #REQ   Q ON Q.REQ_NB = P.REQ_NB AND Q.REQ_SQ = P.REQ_SQ
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD = P.TR_CD
GROUP BY P.TR_CD, T.TR_NM
ORDER BY 등급, 발주금액계 DESC
;


/*==============================================================================================
  ** 쿼리 F : 수입(L/C) 건 분리  ─ 통관 기준이라 국내와 성격이 다르다
==============================================================================================*/
SELECT
     N'[F] 수입 입고 건'                            AS REPORT_NM
    ,H.RCV_NB                                       AS 입고번호
    ,D.RCV_SQ                                       AS 입고순번
    ,H.RCV_DT                                       AS 입고일
    ,H.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,D.PO_NB                                        AS 발주번호
    ,D.PO_SQ                                        AS 발주순번
    ,P.PO_DT                                        AS 발주일
    ,P.DUE_DT                                       AS 발주납기
    ,D.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,D.RCV_QT                                       AS 입고수량
    ,D.RCV_AM                                       AS 입고금액
    ,조달소요일 = DATEDIFF(DAY, CONVERT(DATE,P.PO_DT), CONVERT(DATE,H.RCV_DT))
    ,통관지연일 = DATEDIFF(DAY, CONVERT(DATE,P.DUE_DT), CONVERT(DATE,H.RCV_DT))
FROM       LSTOCK   H WITH (NOLOCK)
INNER JOIN LSTOCK_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.RCV_NB = H.RCV_NB
LEFT  JOIN #PO      P ON P.PO_NB = D.PO_NB AND P.PO_SQ = D.PO_SQ
LEFT  JOIN SITEM    I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = D.ITEM_CD
LEFT  JOIN STRADE   T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = H.TR_CD
WHERE  H.CO_CD  = @CO_CD
  AND  H.RCV_DT BETWEEN @FR_DT AND @TO_DT
  AND  ISNULL(H.LC_YN, N'0') = N'1'
  AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
  AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
ORDER BY 통관지연일 DESC
;


/*==============================================================================================
  ** 쿼리 G : 전체 요약 (경영 보고 1행)
==============================================================================================*/
SELECT
     N'[G] 구매 진행 요약'                          AS REPORT_NM
    ,@FR_DT + N' ~ ' + @TO_DT                       AS 기간
    ,@BASE_DT                                       AS 기준일
    ,(SELECT COUNT(*) FROM #REQ)                    AS 청구라인수
    ,(SELECT SUM(REQ_AM) FROM #REQ)                 AS 청구금액계
    ,(SELECT COUNT(*) FROM #PO)                     AS 발주라인수
    ,(SELECT SUM(PO_AM) FROM #PO)                   AS 발주금액계
    ,(SELECT SUM(CASE WHEN REQ_NB IS NULL THEN 1 ELSE 0 END) FROM #PO) AS 직발주건수
    ,미발주라인수 = (SELECT COUNT(*) FROM #REQ R
                     LEFT JOIN #POR O ON O.REQ_NB=R.REQ_NB AND O.REQ_SQ=R.REQ_SQ
                     WHERE R.REQ_QT - ISNULL(O.PO_QT,0) > 0)
    ,미발주금액   = (SELECT SUM((R.REQ_QT - ISNULL(O.PO_QT,0)) * R.REQ_UM) FROM #REQ R
                     LEFT JOIN #POR O ON O.REQ_NB=R.REQ_NB AND O.REQ_SQ=R.REQ_SQ
                     WHERE R.REQ_QT - ISNULL(O.PO_QT,0) > 0)
    ,미입고라인수 = (SELECT COUNT(*) FROM #PO P
                     LEFT JOIN #RCVP R ON R.PO_NB=P.PO_NB AND R.PO_SQ=P.PO_SQ
                     WHERE P.PO_QT - ISNULL(R.RCV_QT,0) > 0)
    ,미입고금액   = (SELECT SUM((P.PO_QT - ISNULL(R.RCV_QT,0)) * P.PO_UM) FROM #PO P
                     LEFT JOIN #RCVP R ON R.PO_NB=P.PO_NB AND R.PO_SQ=P.PO_SQ
                     WHERE P.PO_QT - ISNULL(R.RCV_QT,0) > 0)
    ,납기경과_미입고건수 = (SELECT COUNT(*) FROM #PO P
                            LEFT JOIN #RCVP R ON R.PO_NB=P.PO_NB AND R.PO_SQ=P.PO_SQ
                            WHERE P.PO_QT - ISNULL(R.RCV_QT,0) > 0
                              AND DATEDIFF(DAY,CONVERT(DATE,P.DUE_DT),CONVERT(DATE,@BASE_DT)) > 0)
    ,평균발주소요일 = (SELECT CAST(AVG(CAST(DATEDIFF(DAY,CONVERT(DATE,Q.REQ_DT),CONVERT(DATE,P.PO_DT)) AS DECIMAL(9,2))) AS DECIMAL(9,1))
                       FROM #PO P INNER JOIN #REQ Q ON Q.REQ_NB=P.REQ_NB AND Q.REQ_SQ=P.REQ_SQ)
;


DROP TABLE #REQ, #POR, #PO, #RCVP, #CLSR;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 청구 사용 여부  ★ 청구를 안 쓰는 사이트면 쿼리 A/B/D 가 무의미하다
     SELECT COUNT(*) FROM LPUR_REQ WHERE CO_CD='1000' AND REQ_DT LIKE '2026%';
     --> 0 이면 쿼리 C(발주별 입고현황) 중심으로 운영할 것.

  -- (2) 청구↔발주 연결률  ★ LPO_D.REQ_NB 가 채워져 있어야 체인이 성립한다
     SELECT COUNT(*) 전체,
            SUM(CASE WHEN ISNULL(REQ_NB,'')='' THEN 1 ELSE 0 END) 직발주
     FROM   LPO_D WHERE CO_CD='1000';
     --> 직발주 비중이 절반을 넘으면 '발주소요일' KPI 는 대표성이 없다.

  -- (3) 발주↔입고 연결률
     SELECT COUNT(*) 전체,
            SUM(CASE WHEN ISNULL(PO_NB,'')='' THEN 1 ELSE 0 END) 발주없는입고
     FROM   LSTOCK_D WHERE CO_CD='1000';

  -- (4) EXPIRE_YN 분포 (청구/발주)
     SELECT 'REQ' T, EXPIRE_YN, COUNT(*) FROM LPUR_REQ_D WHERE CO_CD='1000' GROUP BY EXPIRE_YN
     UNION ALL
     SELECT 'PO' , EXPIRE_YN, COUNT(*) FROM LPO_D      WHERE CO_CD='1000' GROUP BY EXPIRE_YN;

  -- (5) 수입 건 비중
     SELECT LC_YN, COUNT(*) FROM LSTOCK WHERE CO_CD='1000' GROUP BY LC_YN;

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **청구 1건이 여러 발주로 분할될 때, 각 발주의 납기가 다르면** 쿼리 A 의 `발주납기`는
     가장 이른 납기(`MIN`)를 쓴다. 분할 발주의 납기를 개별로 봐야 하면 쿼리 C 를 볼 것.

  2) `입고지연일`은 **최종 입고일 기준**이다. 분할 입고에서 마지막 한 건만 늦어도 지연으로
     잡힌다. 첫 입고 기준 평가가 필요하면 `R.FIRST_DT` 로 바꿀 것 (실무 정의는 최종 기준).

  3) 발주 취소/변경 이력은 추적하지 않는다. `EXPIRE_YN='0'` 으로 마감된 건은 아예 빠지므로,
     "취소된 발주가 얼마나 되는가"를 보려면 필터를 풀고 별도 조회해야 한다.

  4) 마감(`LPURCLS_D`)은 입고를 경유해 발주에 매핑한다. 입고 없이 직접 마감하는 사이트가 있다면
     `#CLSR` 집계가 비어 진행단계가 '4.마감'까지 올라가지 않는다. 확인 쿼리:
        SELECT COUNT(*) FROM LPURCLS_D WHERE CO_CD='1000' AND ISNULL(RCV_NB,'')='';

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   원자재수급총괄현황_MRP.sql : 소요량 산정 → 청구 발생 단계 (본 리포트의 상류)
   수주진행총괄현황.sql       : 수주 기준 구매 경로 추적
   A02_기표파이프라인_현황.sql : 매입마감 → 전표 (본 리포트의 하류)
==============================================================================================*/
