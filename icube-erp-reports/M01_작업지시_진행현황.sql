/*==============================================================================================
  [ iCUBE ] M-01  작업지시 진행 현황                                                 (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 작업지시가 계획/확정/진행/완료/마감 중 어디인지, 잔량이 얼마인지, 납기를 지킬 수
         있는지를 지시 1행으로 판정한다. 다공정 지시는 공정별 진척(쿼리 C)으로 병목을 짚는다.

  DBMS : MS-SQL Server 2012 이상 (T-SQL)   ★ 2008 R2 불가 : LAG()

  ----------------------------------------------------------------------------------------------
  [ 소스 체인 ]
  ----------------------------------------------------------------------------------------------
     LWO_WF        작업지시 (WO_CD)
       ├→ LWO_WF_D     공정 (WO_CD + WOOP_SQ)
       ├→ LWO_REQ_WF   자재청구 (WO_CD + WOBOM_SQ)
       └→ LORCV_H      생산실적 (WR_CD, WO_CD 보유)
             └→ LPRDINWH   실적입고 (WR_CD)

  ----------------------------------------------------------------------------------------------
  [ 산식 ]
  ----------------------------------------------------------------------------------------------
     실적수량 = SUM(LORCV_H.ITEM_QT)  WHERE SUB_TP='0' AND BAD_YN='0'   ← ★ 주산물·적합만
     불량수량 = SUM(LORCV_H.ITEM_QT)  WHERE BAD_YN='1'
     부산물   = SUM(LORCV_H.ITEM_QT)  WHERE SUB_TP='1'
     지시잔량 = LWO_WF.ITEM_QT - 실적수량
     진척률   = 실적수량 / ITEM_QT * 100
     입고율   = SUM(LPRDINWH.INWH_QT) / 실적수량 * 100
     양품률   = 실적수량 / (실적수량 + 불량수량) * 100

  ----------------------------------------------------------------------------------------------
  [ 반드시 지킨 것 ]
  ----------------------------------------------------------------------------------------------
   1. **부산물(`SUB_TP='1'`)·부적합(`BAD_YN='1'`)을 실적수량에 합산하지 않는다.** 합산하면
      진척률이 부풀려져 "다 됐다"고 오판한다. 별도 컬럼으로만 표시.
   2. **`DOC_ST` 코드가 사이트마다 갈린다** — API 규약(0.미처리/1.처리) vs UDR(0.계획/1.확정/2.마감).
      쿼리 G 로 실측 분포를 먼저 뽑아 라벨을 확정할 것. 본 쿼리는 UDR 해석을 기본값으로 쓰되
      원본 코드값을 항상 같이 출력한다.
   3. `EXPIRE_YN='1'` = 생산진행, `'0'` = 생산마감. (전 테이블 공통 규칙)
   4. 실적/입고는 **집계 후 조인**. 지시 1건에 실적 N건이므로 직접 조인하면 행이 증식한다.
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
    ,@FR_DT    NVARCHAR(8)  = N'20260101'     -- 지시일 FROM
    ,@TO_DT    NVARCHAR(8)  = N'20261231'
    ,@WO_CD    NVARCHAR(20) = NULL            -- 특정 지시
    ,@ITEM_CD  NVARCHAR(25) = NULL
    ,@PJT_CD   NVARCHAR(10) = NULL
    ,@DEPT_CD  NVARCHAR(10) = NULL            -- 생산부서
    ,@DOC_FG   NVARCHAR(1)  = NULL            -- 0생산 1외주 5재고이동
    ,@ONLY_OPEN NCHAR(1)    = N'0'            -- 1 = 진행분(EXPIRE_YN='1')만
;

IF OBJECT_ID('tempdb..#WO')   IS NOT NULL DROP TABLE #WO;
IF OBJECT_ID('tempdb..#RCV')  IS NOT NULL DROP TABLE #RCV;
IF OBJECT_ID('tempdb..#INW')  IS NOT NULL DROP TABLE #INW;
IF OBJECT_ID('tempdb..#MTL')  IS NOT NULL DROP TABLE #MTL;


/*==============================================================================================
  1. #WO : 작업지시 헤더
==============================================================================================*/
SELECT
     W.WO_CD
    ,W.ORD_DT
    ,W.COMP_DT
    ,W.ITEM_CD
    ,ITEM_QT = CAST(ISNULL(W.ITEM_QT, 0) AS DECIMAL(19,6))
    ,W.DOC_ST
    ,W.EXPIRE_YN
    ,W.DOC_FG
    ,W.WOC_FG
    ,W.DIV_CD
    ,W.DEPT_CD
    ,W.WH_CD
    ,W.PJT_CD
    ,W.SO_NB
    ,W.LN_SQ
    ,W.EMP_CD
INTO #WO
FROM       LWO_WF W WITH (NOLOCK)
LEFT  JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = W.CO_CD AND I.ITEM_CD = W.ITEM_CD
WHERE  W.CO_CD  = @CO_CD
  AND  W.ORD_DT BETWEEN @FR_DT AND @TO_DT
  AND  ISNULL(W.USE_YN, N'1') = N'1'
  AND  (@DIV_CD   IS NULL OR W.DIV_CD  = @DIV_CD)
  AND  (@WO_CD    IS NULL OR W.WO_CD   = @WO_CD)
  AND  (@ITEM_CD  IS NULL OR W.ITEM_CD = @ITEM_CD)
  AND  (@PJT_CD   IS NULL OR W.PJT_CD  = @PJT_CD)
  AND  (@DEPT_CD  IS NULL OR W.DEPT_CD = @DEPT_CD)
  AND  (@DOC_FG   IS NULL OR W.DOC_FG  = @DOC_FG)
  AND  (@ONLY_OPEN = N'0' OR ISNULL(W.EXPIRE_YN, N'1') = N'1')
;
CREATE CLUSTERED INDEX IX_WO ON #WO (WO_CD);
PRINT N'[1] 작업지시 : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 건';


/*==============================================================================================
  2. #RCV : 지시별 생산실적 집계   ★ 주산물/부산물, 적합/부적합 분리
==============================================================================================*/
SELECT
     R.WO_CD
    ,GOOD_QT  = SUM(CASE WHEN ISNULL(R.SUB_TP,N'0') = N'0' AND ISNULL(R.BAD_YN,N'0') = N'0'
                         THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
    ,BAD_QT   = SUM(CASE WHEN ISNULL(R.BAD_YN,N'0') = N'1'
                         THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
    ,SUB_QT   = SUM(CASE WHEN ISNULL(R.SUB_TP,N'0') = N'1'
                         THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
    ,RWK_QT   = SUM(CASE WHEN ISNULL(R.REWORK_YN,N'0') = N'1'
                         THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
    ,RCV_CNT  = COUNT(*)
    ,FIRST_DT = MIN(R.WR_DT)
    ,LAST_DT  = MAX(R.WR_DT)
INTO #RCV
FROM   LORCV_H R WITH (NOLOCK)
WHERE  R.CO_CD = @CO_CD
  AND  ISNULL(R.USE_YN, N'1') = N'1'
  AND  ISNULL(R.WO_CD, N'') <> N''
  AND  (@DIV_CD IS NULL OR R.DIV_CD = @DIV_CD)
GROUP BY R.WO_CD;
CREATE CLUSTERED INDEX IX_RCV ON #RCV (WO_CD);


/*==============================================================================================
  3. #INW : 지시별 실적입고 집계 (LPRDINWH 는 WR_CD 키 → LORCV_H 경유해 WO_CD 로 환산)
==============================================================================================*/
SELECT
     R.WO_CD
    ,INWH_QT  = SUM(CAST(ISNULL(N.INWH_QT,0) AS DECIMAL(19,6)))
    ,INWH_CNT = COUNT(*)
    ,LAST_DT  = MAX(N.INWH_DT)
INTO #INW
FROM       LPRDINWH N WITH (NOLOCK)
INNER JOIN LORCV_H  R WITH (NOLOCK) ON R.CO_CD = N.CO_CD AND R.WR_CD = N.WR_CD
WHERE  N.CO_CD = @CO_CD
  AND  ISNULL(N.USE_YN, N'1') = N'1'
  AND  ISNULL(R.WO_CD, N'') <> N''
GROUP BY R.WO_CD;
CREATE CLUSTERED INDEX IX_INW ON #INW (WO_CD);


/*==============================================================================================
  4. #MTL : 지시별 자재 청구 요약 (자재 준비 상태 — 납기 리스크 판정 보조)
     ※ 정밀한 청구/출고/사용 4단계 추적은 M05_자재_청구출고사용_현황.sql 참조
==============================================================================================*/
SELECT
     Q.WO_CD
    ,MTL_CNT = COUNT(*)
    ,REQ_QT  = SUM(CAST(ISNULL(Q.REQ_QT, 0) AS DECIMAL(19,6)))
    ,ISU_QT  = SUM(CAST(ISNULL(Q.ISU_QT, 0) AS DECIMAL(19,6)))
    ,SHORT_CNT = SUM(CASE WHEN ISNULL(Q.ISU_QT,0) < ISNULL(Q.REQ_QT,0) THEN 1 ELSE 0 END)
INTO #MTL
FROM   LWO_REQ_WF Q WITH (NOLOCK)
WHERE  Q.CO_CD = @CO_CD
  AND  ISNULL(Q.USE_YN, N'1') = N'1'
GROUP BY Q.WO_CD;
CREATE CLUSTERED INDEX IX_MTL ON #MTL (WO_CD);


/*==============================================================================================
  ** 쿼리 A : 작업지시별 진행현황  (메인)
==============================================================================================*/
SELECT
     N'[A] 작업지시 진행현황'                       AS REPORT_NM
    ,진행단계 = CASE
         WHEN ISNULL(W.EXPIRE_YN, N'1') = N'0'                       THEN N'5.생산마감'
         WHEN ISNULL(N.INWH_QT,0) > 0
          AND ISNULL(N.INWH_QT,0) >= ISNULL(R.GOOD_QT,0)             THEN N'4.입고완료'
         WHEN ISNULL(N.INWH_QT,0) > 0                                THEN N'3.부분입고'
         WHEN ISNULL(R.GOOD_QT,0) >= W.ITEM_QT AND W.ITEM_QT > 0     THEN N'2.생산완료'
         WHEN ISNULL(R.GOOD_QT,0) > 0                                THEN N'1.생산중'
         ELSE                                                             N'0.미착수' END
    ,W.WO_CD                                        AS 지시번호
    ,W.ORD_DT                                       AS 지시일
    ,W.COMP_DT                                      AS 완료예정일
    ,지시구분 = CASE W.DOC_FG WHEN N'0' THEN N'생산' WHEN N'1' THEN N'외주'
                              WHEN N'5' THEN N'재고이동' ELSE W.DOC_FG END
    ,지시유형 = CASE W.WOC_FG WHEN N'0' THEN N'생산지시' WHEN N'2' THEN N'임가공'
                              WHEN N'4' THEN N'외주발주' WHEN N'5' THEN N'작업지시'
                              ELSE W.WOC_FG END
    ,W.DOC_ST                                       AS 문서상태_코드
    ,문서상태 = CASE W.DOC_ST WHEN N'0' THEN N'계획' WHEN N'1' THEN N'확정'
                              WHEN N'2' THEN N'마감' ELSE W.DOC_ST END   -- ★ 쿼리 G 로 검증
    ,생산상태 = CASE ISNULL(W.EXPIRE_YN,N'1') WHEN N'1' THEN N'진행' ELSE N'마감' END
    ,W.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'2' THEN N'제품' WHEN N'4' THEN N'반제품' ELSE I.ACCT_FG END

    -- 수량
    ,W.ITEM_QT                                      AS 지시수량
    ,ISNULL(R.GOOD_QT, 0)                           AS 실적수량_양품
    ,ISNULL(R.BAD_QT , 0)                           AS 불량수량
    ,ISNULL(R.SUB_QT , 0)                           AS 부산물수량
    ,ISNULL(R.RWK_QT , 0)                           AS 재작업수량
    ,W.ITEM_QT - ISNULL(R.GOOD_QT, 0)               AS 지시잔량
    ,ISNULL(N.INWH_QT, 0)                           AS 입고수량
    ,ISNULL(R.GOOD_QT,0) - ISNULL(N.INWH_QT,0)      AS 미입고수량

    -- 비율
    ,진척률_PCT = CAST(CASE WHEN W.ITEM_QT <> 0
                            THEN ISNULL(R.GOOD_QT,0)/W.ITEM_QT*100 END AS DECIMAL(19,2))
    ,입고율_PCT = CAST(CASE WHEN ISNULL(R.GOOD_QT,0) <> 0
                            THEN ISNULL(N.INWH_QT,0)/R.GOOD_QT*100 END AS DECIMAL(19,2))
    ,양품률_PCT = CAST(CASE WHEN ISNULL(R.GOOD_QT,0)+ISNULL(R.BAD_QT,0) <> 0
                            THEN ISNULL(R.GOOD_QT,0)/(ISNULL(R.GOOD_QT,0)+ISNULL(R.BAD_QT,0))*100
                            END AS DECIMAL(19,2))

    -- 일정
    ,ISNULL(R.RCV_CNT, 0)                           AS 실적건수
    ,R.FIRST_DT                                     AS 최초실적일
    ,R.LAST_DT                                      AS 최종실적일
    ,N.LAST_DT                                      AS 최종입고일
    ,경과일 = DATEDIFF(DAY, CONVERT(DATE, W.ORD_DT),
                       CONVERT(DATE, ISNULL(R.LAST_DT, @BASE_DT)))
    ,납기경과일 = CASE WHEN W.COMP_DT IS NOT NULL
                       THEN DATEDIFF(DAY, CONVERT(DATE,W.COMP_DT), CONVERT(DATE,@BASE_DT)) END
    ,납기리스크 = CASE
         WHEN ISNULL(R.GOOD_QT,0) >= W.ITEM_QT                                       THEN N'0.완료'
         WHEN W.COMP_DT IS NULL                                                      THEN N'9.완료예정일 미등록'
         WHEN DATEDIFF(DAY,CONVERT(DATE,W.COMP_DT),CONVERT(DATE,@BASE_DT)) > 7        THEN N'1.★7일 이상 지연'
         WHEN DATEDIFF(DAY,CONVERT(DATE,W.COMP_DT),CONVERT(DATE,@BASE_DT)) > 0        THEN N'2.납기경과'
         WHEN DATEDIFF(DAY,CONVERT(DATE,@BASE_DT),CONVERT(DATE,W.COMP_DT)) <= 3       THEN N'3.납기임박(3일)'
         ELSE N'4.정상' END

    -- 자재 준비
    ,ISNULL(M.MTL_CNT  , 0)                         AS 청구자재품목수
    ,ISNULL(M.SHORT_CNT, 0)                         AS 자재부족품목수
    ,자재준비 = CASE WHEN M.MTL_CNT IS NULL      THEN N'9.자재청구 없음'
                     WHEN ISNULL(M.SHORT_CNT,0) = 0 THEN N'0.준비완료'
                     ELSE N'1.★자재 부족' END

    ,W.SO_NB                                        AS 수주번호
    ,W.LN_SQ                                        AS 수주순번
    ,W.PJT_CD                                       AS 프로젝트
    ,W.DEPT_CD                                      AS 생산부서
    ,P.DEPT_NM                                      AS 부서명
    ,W.WH_CD                                        AS 입고창고
FROM       #WO   W
LEFT  JOIN #RCV  R ON R.WO_CD = W.WO_CD
LEFT  JOIN #INW  N ON N.WO_CD = W.WO_CD
LEFT  JOIN #MTL  M ON M.WO_CD = W.WO_CD
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = W.ITEM_CD
LEFT  JOIN SDEPT P WITH (NOLOCK) ON P.CO_CD = @CO_CD AND P.DEPT_CD = W.DEPT_CD
ORDER BY 납기리스크, W.COMP_DT, W.WO_CD
;


/*==============================================================================================
  ** 쿼리 B : 진행단계별 집계 (대시보드 상단)
==============================================================================================*/
;WITH X AS (
    SELECT
         W.ITEM_QT
        ,GOOD_QT = ISNULL(R.GOOD_QT,0)
        ,BAD_QT  = ISNULL(R.BAD_QT ,0)
        ,INWH_QT = ISNULL(N.INWH_QT,0)
        ,STG = CASE
             WHEN ISNULL(W.EXPIRE_YN, N'1') = N'0'                        THEN N'5.생산마감'
             WHEN ISNULL(N.INWH_QT,0) > 0
              AND ISNULL(N.INWH_QT,0) >= ISNULL(R.GOOD_QT,0)              THEN N'4.입고완료'
             WHEN ISNULL(N.INWH_QT,0) > 0                                 THEN N'3.부분입고'
             WHEN ISNULL(R.GOOD_QT,0) >= W.ITEM_QT AND W.ITEM_QT > 0      THEN N'2.생산완료'
             WHEN ISNULL(R.GOOD_QT,0) > 0                                 THEN N'1.생산중'
             ELSE                                                              N'0.미착수' END
    FROM      #WO W
    LEFT JOIN #RCV R ON R.WO_CD = W.WO_CD
    LEFT JOIN #INW N ON N.WO_CD = W.WO_CD
)
SELECT
     N'[B] 진행단계별 집계'                         AS REPORT_NM
    ,X.STG                                          AS 진행단계
    ,COUNT(*)                                       AS 지시건수
    ,SUM(X.ITEM_QT)                                 AS 지시수량
    ,SUM(X.GOOD_QT)                                 AS 실적수량
    ,SUM(X.BAD_QT)                                  AS 불량수량
    ,SUM(X.INWH_QT)                                 AS 입고수량
    ,SUM(X.ITEM_QT - X.GOOD_QT)                     AS 지시잔량
    ,진척률_PCT = CAST(CASE WHEN SUM(X.ITEM_QT) <> 0
                            THEN SUM(X.GOOD_QT)/SUM(X.ITEM_QT)*100 END AS DECIMAL(19,2))
    ,구성비_PCT = CAST(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0) AS DECIMAL(5,1))
FROM   X
GROUP BY X.STG
ORDER BY X.STG
;


/*==============================================================================================
  ** 쿼리 C : 공정별 진척  ★ 다공정 지시의 병목 규명
     ─ LWO_WF_D.WOOP_SQ 순서로 공정을 나열하고, 각 공정의 실적을 붙인다.
       앞 공정은 끝났는데 뒤 공정이 안 돈다 = 그 공정이 병목.
==============================================================================================*/
SELECT
     N'[C] 공정별 진척'                             AS REPORT_NM
    ,W.WO_CD                                        AS 지시번호
    ,W.ORD_DT                                       AS 지시일
    ,W.COMP_DT                                      AS 완료예정일
    ,W.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,W.ITEM_QT                                      AS 지시수량
    ,D.WOOP_SQ                                      AS 공정순번
    ,D.PROC_CD                                      AS 공정코드
    ,C.PROC_NM                                      AS 공정명
    ,D.WC_CD                                        AS 작업장코드
    ,K.WC_NM                                        AS 작업장명
    ,공정실적 = ISNULL(O.OP_GOOD, 0)
    ,공정불량 = ISNULL(O.OP_BAD , 0)
    ,공정잔량 = W.ITEM_QT - ISNULL(O.OP_GOOD, 0)
    ,공정진척률_PCT = CAST(CASE WHEN W.ITEM_QT <> 0
                                THEN ISNULL(O.OP_GOOD,0)/W.ITEM_QT*100 END AS DECIMAL(19,2))
    ,공정양품률_PCT = CAST(CASE WHEN ISNULL(O.OP_GOOD,0)+ISNULL(O.OP_BAD,0) <> 0
                                THEN ISNULL(O.OP_GOOD,0)/(ISNULL(O.OP_GOOD,0)+ISNULL(O.OP_BAD,0))*100
                                END AS DECIMAL(19,2))
    ,O.FIRST_DT                                     AS 최초실적일
    ,O.LAST_DT                                      AS 최종실적일
    ,직전공정실적 = LAG(ISNULL(O.OP_GOOD,0)) OVER (PARTITION BY W.WO_CD ORDER BY D.WOOP_SQ)
    ,공정상태 = CASE
         WHEN ISNULL(O.OP_GOOD,0) >= W.ITEM_QT                    THEN N'3.완료'
         WHEN ISNULL(O.OP_GOOD,0) > 0                             THEN N'2.진행'
         WHEN LAG(ISNULL(O.OP_GOOD,0)) OVER (PARTITION BY W.WO_CD ORDER BY D.WOOP_SQ) > 0
                                                                  THEN N'1.★대기 (직전공정 완료)'
         ELSE N'0.미착수' END
FROM       #WO      W
INNER JOIN LWO_WF_D D WITH (NOLOCK) ON D.CO_CD = @CO_CD AND D.WO_CD = W.WO_CD
LEFT  JOIN SITEM    I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = W.ITEM_CD
LEFT  JOIN SPROC    C WITH (NOLOCK) ON C.CO_CD = @CO_CD AND C.PROC_CD = D.PROC_CD
LEFT  JOIN SWC      K WITH (NOLOCK) ON K.CO_CD = @CO_CD AND K.WC_CD   = D.WC_CD
OUTER APPLY (
    SELECT
         OP_GOOD = SUM(CASE WHEN ISNULL(R.SUB_TP,N'0')=N'0' AND ISNULL(R.BAD_YN,N'0')=N'0'
                            THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
        ,OP_BAD  = SUM(CASE WHEN ISNULL(R.BAD_YN,N'0')=N'1'
                            THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
        ,FIRST_DT= MIN(R.WR_DT)
        ,LAST_DT = MAX(R.WR_DT)
    FROM   LORCV_H R WITH (NOLOCK)
    WHERE  R.CO_CD = @CO_CD AND R.WO_CD = W.WO_CD
      AND  ISNULL(R.USE_YN, N'1') = N'1'
      AND  ISNULL(R.PROC_CD, N'') = ISNULL(D.PROC_CD, N'')
) O
WHERE  ISNULL(D.USE_YN, N'1') = N'1'
ORDER BY W.WO_CD, D.WOOP_SQ
;


/*==============================================================================================
  ** 쿼리 D : 납기 리스크 지시  (생산관리 조치 대상)
==============================================================================================*/
SELECT
     N'[D] 납기 리스크'                             AS REPORT_NM
    ,리스크 = CASE
         WHEN DATEDIFF(DAY,CONVERT(DATE,W.COMP_DT),CONVERT(DATE,@BASE_DT)) > 7  THEN N'1.★7일 이상 지연'
         WHEN DATEDIFF(DAY,CONVERT(DATE,W.COMP_DT),CONVERT(DATE,@BASE_DT)) > 0  THEN N'2.납기경과'
         ELSE N'3.납기임박(3일)' END
    ,W.WO_CD                                        AS 지시번호
    ,W.ORD_DT                                       AS 지시일
    ,W.COMP_DT                                      AS 완료예정일
    ,납기경과일 = DATEDIFF(DAY, CONVERT(DATE,W.COMP_DT), CONVERT(DATE,@BASE_DT))
    ,W.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,W.ITEM_QT                                      AS 지시수량
    ,ISNULL(R.GOOD_QT, 0)                           AS 실적수량
    ,W.ITEM_QT - ISNULL(R.GOOD_QT, 0)               AS 잔량
    ,진척률_PCT = CAST(CASE WHEN W.ITEM_QT <> 0
                            THEN ISNULL(R.GOOD_QT,0)/W.ITEM_QT*100 END AS DECIMAL(19,2))
    ,ISNULL(M.SHORT_CNT, 0)                         AS 자재부족품목수
    ,R.LAST_DT                                      AS 최종실적일
    ,무실적일수 = CASE WHEN R.LAST_DT IS NOT NULL
                       THEN DATEDIFF(DAY, CONVERT(DATE,R.LAST_DT), CONVERT(DATE,@BASE_DT))
                       ELSE DATEDIFF(DAY, CONVERT(DATE,W.ORD_DT), CONVERT(DATE,@BASE_DT)) END
    ,추정원인 = CASE
         WHEN ISNULL(M.SHORT_CNT,0) > 0                 THEN N'1.자재 미출고'
         WHEN ISNULL(R.GOOD_QT,0) = 0
          AND DATEDIFF(DAY,CONVERT(DATE,W.ORD_DT),CONVERT(DATE,@BASE_DT)) > 7
                                                        THEN N'2.착수 지연'
         WHEN ISNULL(R.BAD_QT,0) > ISNULL(R.GOOD_QT,0) * 0.1
                                                        THEN N'3.품질 문제 (불량 10% 초과)'
         WHEN R.LAST_DT IS NOT NULL
          AND DATEDIFF(DAY,CONVERT(DATE,R.LAST_DT),CONVERT(DATE,@BASE_DT)) > 7
                                                        THEN N'4.진행 중단 (7일 무실적)'
         ELSE N'5.진행 중 (속도 부족)' END
    ,W.SO_NB                                        AS 수주번호
    ,W.PJT_CD                                       AS 프로젝트
    ,W.DEPT_CD                                      AS 생산부서
    ,P.DEPT_NM                                      AS 부서명
FROM       #WO   W
LEFT  JOIN #RCV  R ON R.WO_CD = W.WO_CD
LEFT  JOIN #MTL  M ON M.WO_CD = W.WO_CD
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = W.ITEM_CD
LEFT  JOIN SDEPT P WITH (NOLOCK) ON P.CO_CD = @CO_CD AND P.DEPT_CD = W.DEPT_CD
WHERE  ISNULL(W.EXPIRE_YN, N'1') = N'1'                 -- 진행분만
  AND  W.ITEM_QT - ISNULL(R.GOOD_QT, 0) > 0             -- 잔량 있는 건만
  AND  W.COMP_DT IS NOT NULL
  AND  DATEDIFF(DAY, CONVERT(DATE,@BASE_DT), CONVERT(DATE,W.COMP_DT)) <= 3
ORDER BY 리스크, 납기경과일 DESC
;


/*==============================================================================================
  ** 쿼리 E : 품목별 지시 요약
==============================================================================================*/
SELECT
     N'[E] 품목별 지시 요약'                        AS REPORT_NM
    ,W.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'2' THEN N'제품' WHEN N'4' THEN N'반제품' ELSE I.ACCT_FG END
    ,COUNT(*)                                       AS 지시건수
    ,SUM(W.ITEM_QT)                                 AS 지시수량계
    ,SUM(ISNULL(R.GOOD_QT,0))                       AS 실적수량계
    ,SUM(ISNULL(R.BAD_QT ,0))                       AS 불량수량계
    ,SUM(ISNULL(N.INWH_QT,0))                       AS 입고수량계
    ,SUM(W.ITEM_QT - ISNULL(R.GOOD_QT,0))           AS 잔량계
    ,진척률_PCT = CAST(CASE WHEN SUM(W.ITEM_QT) <> 0
                            THEN SUM(ISNULL(R.GOOD_QT,0))/SUM(W.ITEM_QT)*100 END AS DECIMAL(19,2))
    ,양품률_PCT = CAST(CASE WHEN SUM(ISNULL(R.GOOD_QT,0))+SUM(ISNULL(R.BAD_QT,0)) <> 0
                            THEN SUM(ISNULL(R.GOOD_QT,0))
                                 /(SUM(ISNULL(R.GOOD_QT,0))+SUM(ISNULL(R.BAD_QT,0)))*100
                            END AS DECIMAL(19,2))
    ,진행중건수 = SUM(CASE WHEN ISNULL(W.EXPIRE_YN,N'1')=N'1' THEN 1 ELSE 0 END)
    ,납기경과건수 = SUM(CASE WHEN W.COMP_DT IS NOT NULL
                              AND ISNULL(W.EXPIRE_YN,N'1')=N'1'
                              AND W.ITEM_QT - ISNULL(R.GOOD_QT,0) > 0
                              AND DATEDIFF(DAY,CONVERT(DATE,W.COMP_DT),CONVERT(DATE,@BASE_DT)) > 0
                             THEN 1 ELSE 0 END)
FROM       #WO   W
LEFT  JOIN #RCV  R ON R.WO_CD = W.WO_CD
LEFT  JOIN #INW  N ON N.WO_CD = W.WO_CD
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = W.ITEM_CD
GROUP BY W.ITEM_CD, I.ITEM_NM, I.SPEC, I.UNIT_CD, I.ACCT_FG
ORDER BY 잔량계 DESC
;


/*==============================================================================================
  ** 쿼리 F : 실적 대비 입고 누락  (실적은 났는데 창고 입고가 안 된 건)
     ★ 이 상태로 원가 마감하면 제품 재고가 과소, 재공이 과대 계상된다.
==============================================================================================*/
SELECT
     N'[F] 실적입고 누락'                           AS REPORT_NM
    ,W.WO_CD                                        AS 지시번호
    ,W.ORD_DT                                       AS 지시일
    ,W.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,W.ITEM_QT                                      AS 지시수량
    ,ISNULL(R.GOOD_QT, 0)                           AS 실적수량
    ,ISNULL(N.INWH_QT, 0)                           AS 입고수량
    ,ISNULL(R.GOOD_QT,0) - ISNULL(N.INWH_QT,0)      AS 미입고수량
    ,입고율_PCT = CAST(CASE WHEN ISNULL(R.GOOD_QT,0) <> 0
                            THEN ISNULL(N.INWH_QT,0)/R.GOOD_QT*100 END AS DECIMAL(19,2))
    ,R.LAST_DT                                      AS 최종실적일
    ,N.LAST_DT                                      AS 최종입고일
    ,실적후경과일 = DATEDIFF(DAY, CONVERT(DATE,R.LAST_DT), CONVERT(DATE,@BASE_DT))
    ,생산상태 = CASE ISNULL(W.EXPIRE_YN,N'1') WHEN N'1' THEN N'진행' ELSE N'마감' END
    ,판정 = CASE
         WHEN ISNULL(N.INWH_QT,0) = 0 AND ISNULL(W.EXPIRE_YN,N'1') = N'0'
              THEN N'1.★생산마감인데 입고 전무'
         WHEN DATEDIFF(DAY,CONVERT(DATE,R.LAST_DT),CONVERT(DATE,@BASE_DT)) > 7
              THEN N'2.★실적 후 7일 경과'
         ELSE N'3.입고 대기' END
    ,W.WH_CD                                        AS 입고창고
    ,W.DEPT_CD                                      AS 생산부서
FROM       #WO   W
LEFT  JOIN #RCV  R ON R.WO_CD = W.WO_CD
LEFT  JOIN #INW  N ON N.WO_CD = W.WO_CD
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = W.ITEM_CD
WHERE  ISNULL(R.GOOD_QT, 0) > 0
  AND  ISNULL(R.GOOD_QT, 0) - ISNULL(N.INWH_QT, 0) > 0
ORDER BY 판정, 미입고수량 DESC
;


/*==============================================================================================
  ** 쿼리 G : DOC_ST 코드값 실측  ★ 라벨 확정 전 반드시 먼저 실행
     ─ API 규약(0.미처리/1.처리) 과 UDR(0.계획/1.확정/2.마감) 이 갈린다.
       값이 0/1 만 나오면 API 해석, 0/1/2 가 나오면 UDR 해석이다.
==============================================================================================*/
SELECT
     N'[G] DOC_ST 코드값 실측'                      AS REPORT_NM
    ,W.DOC_ST                                       AS 문서상태_코드
    ,W.EXPIRE_YN                                    AS 진행여부_코드
    ,COUNT(*)                                       AS 지시건수
    ,SUM(W.ITEM_QT)                                 AS 지시수량
    ,실적있음 = SUM(CASE WHEN ISNULL(R.GOOD_QT,0) > 0 THEN 1 ELSE 0 END)
    ,실적완료 = SUM(CASE WHEN ISNULL(R.GOOD_QT,0) >= W.ITEM_QT THEN 1 ELSE 0 END)
    ,입고있음 = SUM(CASE WHEN ISNULL(N.INWH_QT,0) > 0 THEN 1 ELSE 0 END)
    ,최초지시일 = MIN(W.ORD_DT)
    ,최종지시일 = MAX(W.ORD_DT)
    ,해석힌트 = CASE
         WHEN W.DOC_ST = N'2' THEN N'DOC_ST=2 존재 → UDR 해석(0계획/1확정/2마감)'
         ELSE N'실적/입고 분포로 판단. 실적완료가 몰린 코드가 마감/처리일 가능성 높음' END
FROM       #WO   W
LEFT  JOIN #RCV  R ON R.WO_CD = W.WO_CD
LEFT  JOIN #INW  N ON N.WO_CD = W.WO_CD
GROUP BY W.DOC_ST, W.EXPIRE_YN
ORDER BY W.DOC_ST, W.EXPIRE_YN
;


/*==============================================================================================
  ** 쿼리 H : 전체 요약 (경영 보고 1행)
==============================================================================================*/
SELECT
     N'[H] 작업지시 요약'                           AS REPORT_NM
    ,@FR_DT + N' ~ ' + @TO_DT                       AS 기간
    ,@BASE_DT                                       AS 기준일
    ,COUNT(*)                                       AS 총지시건수
    ,SUM(W.ITEM_QT)                                 AS 총지시수량
    ,SUM(ISNULL(R.GOOD_QT,0))                       AS 총실적수량
    ,SUM(ISNULL(R.BAD_QT ,0))                       AS 총불량수량
    ,SUM(ISNULL(N.INWH_QT,0))                       AS 총입고수량
    ,전체진척률_PCT = CAST(CASE WHEN SUM(W.ITEM_QT) <> 0
                                THEN SUM(ISNULL(R.GOOD_QT,0))/SUM(W.ITEM_QT)*100 END AS DECIMAL(19,2))
    ,전체양품률_PCT = CAST(CASE WHEN SUM(ISNULL(R.GOOD_QT,0))+SUM(ISNULL(R.BAD_QT,0)) <> 0
                                THEN SUM(ISNULL(R.GOOD_QT,0))
                                     /(SUM(ISNULL(R.GOOD_QT,0))+SUM(ISNULL(R.BAD_QT,0)))*100
                                END AS DECIMAL(19,2))
    ,진행중건수   = SUM(CASE WHEN ISNULL(W.EXPIRE_YN,N'1')=N'1' THEN 1 ELSE 0 END)
    ,미착수건수   = SUM(CASE WHEN ISNULL(R.GOOD_QT,0) = 0 THEN 1 ELSE 0 END)
    ,납기경과건수 = SUM(CASE WHEN W.COMP_DT IS NOT NULL
                              AND ISNULL(W.EXPIRE_YN,N'1')=N'1'
                              AND W.ITEM_QT - ISNULL(R.GOOD_QT,0) > 0
                              AND DATEDIFF(DAY,CONVERT(DATE,W.COMP_DT),CONVERT(DATE,@BASE_DT)) > 0
                             THEN 1 ELSE 0 END)
    ,입고누락건수 = SUM(CASE WHEN ISNULL(R.GOOD_QT,0) > ISNULL(N.INWH_QT,0) THEN 1 ELSE 0 END)
    ,완료예정일_미등록 = SUM(CASE WHEN W.COMP_DT IS NULL THEN 1 ELSE 0 END)
    ,판정 = CASE
         WHEN SUM(CASE WHEN W.COMP_DT IS NOT NULL AND ISNULL(W.EXPIRE_YN,N'1')=N'1'
                        AND W.ITEM_QT - ISNULL(R.GOOD_QT,0) > 0
                        AND DATEDIFF(DAY,CONVERT(DATE,W.COMP_DT),CONVERT(DATE,@BASE_DT)) > 0
                       THEN 1 ELSE 0 END) > 0                          THEN N'1.★납기경과 지시 존재'
         WHEN SUM(CASE WHEN ISNULL(R.GOOD_QT,0) > ISNULL(N.INWH_QT,0) THEN 1 ELSE 0 END) > 0
                                                                       THEN N'2.★실적입고 누락 존재'
         ELSE N'0.정상' END
FROM       #WO  W
LEFT  JOIN #RCV R ON R.WO_CD = W.WO_CD
LEFT  JOIN #INW N ON N.WO_CD = W.WO_CD
;


DROP TABLE #WO, #RCV, #INW, #MTL;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) DOC_ST 코드 체계  ★ 쿼리 G 와 같은 목적. 라벨 확정 전 필수
     SELECT DOC_ST, COUNT(*) FROM LWO_WF WHERE CO_CD='1000' GROUP BY DOC_ST;
     --> 0/1 만 → API 해석(0미처리/1처리). 0/1/2 → UDR 해석(0계획/1확정/2마감).
        쿼리 A 의 `문서상태` CASE 를 실측에 맞게 고칠 것.

  -- (2) EXPIRE_YN 분포
     SELECT EXPIRE_YN, COUNT(*) FROM LWO_WF WHERE CO_CD='1000' GROUP BY EXPIRE_YN;
     --> '1'(진행)에 미완료 지시가 몰려야 정상.

  -- (3) 실적의 부산물/부적합 비중  ★ 분리하지 않으면 진척률이 부풀려진다
     SELECT SUB_TP, BAD_YN, COUNT(*) 건수, SUM(ITEM_QT) 수량
     FROM   LORCV_H WHERE CO_CD='1000' GROUP BY SUB_TP, BAD_YN;

  -- (4) 다공정 사용 여부  ★ 쿼리 C 의 의미를 좌우
     SELECT 공정수, COUNT(*) 지시건수 FROM (
       SELECT WO_CD, COUNT(*) 공정수 FROM LWO_WF_D WHERE CO_CD='1000' GROUP BY WO_CD
     ) X GROUP BY 공정수 ORDER BY 공정수;
     --> 대부분 1공정이면 쿼리 C 는 불필요하다.

  -- (5) LORCV_H.PROC_CD 채움률  ★ 쿼리 C 는 이 값으로 공정을 매칭한다
     SELECT COUNT(*) 전체, SUM(CASE WHEN ISNULL(PROC_CD,'')='' THEN 1 ELSE 0 END) 공정없음
     FROM   LORCV_H WHERE CO_CD='1000';
     --> '공정없음'이 많으면 쿼리 C 의 공정별 실적이 0 으로 나온다. 이때는 쿼리 C 를 쓰지 말 것.

  -- (6) 공정/작업장 마스터 테이블명 확인 (사이트별 상이 가능)
     SELECT name FROM sys.tables WHERE name IN ('SPROC','SWC','LWO_WF_D','LPRDINWH');

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **쿼리 C(공정별 진척)는 `LORCV_H.PROC_CD` 가 채워져 있어야 동작한다.** 공정 실적을 따로
     찍지 않고 최종 공정에서만 실적을 내는 사이트가 많다. 확인 (5)번이 0 에 가까우면 쿼리 C 는
     전 공정이 0 으로 나오므로 사용하지 말 것.

  2) `자재준비` 판정은 `LWO_REQ_WF.ISU_QT`(청구 대비 출고) 요약 필드에 의존한다. 정밀한
     청구/출고/사용 4단계 추적은 `M05_자재_청구출고사용_현황.sql` 을 쓸 것.

  3) 재작업(`REWORK_YN='1'`) 수량은 표시만 하고 진척률에서 제외하지 않는다. 재작업을 실적으로
     인정할지는 회사 정책이므로, 제외해야 하면 `#RCV` 의 `GOOD_QT` 조건에
     `AND ISNULL(R.REWORK_YN,N'0')=N'0'` 을 추가할 것.

  4) `경과일`은 최종 실적일 기준이다. 실적이 없는 지시는 기준일까지의 경과일로 대체한다.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   생산지시별_작업수율현황.sql      : 수율 5축 분해 (양품률/직행률/자재수율/공정수율)
   M05_자재_청구출고사용_현황.sql   : 지시별 자재 4단계 추적
   PJT_생산원가_보고서.sql          : 지시 원가 집계
   수주진행총괄현황.sql             : 수주 → 지시 연결 추적
==============================================================================================*/
