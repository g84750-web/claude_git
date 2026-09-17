/*==============================================================================================
  [ iCUBE ] B-02 / B-04 / B-05 / B-06  마스터 점검팩                                 (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : **상시 점검 리포트.** 마스터가 틀어지면 그 위에 올린 모든 리포트가 틀린다.
         네 가지를 한 번에 본다.

           B-02  코드값 분포 점검     EXPIRE_YN / DOC_ST / SO_FG / RCPAM_FG / GRP_FG 실분포
           B-04  BOM 등록·순환참조    지시품목 중 BOM 미등록, 레벨 과다, 순환참조
           B-05  단종품 사용 점검     S_CD='Z00' 이 수주·지시·BOM 에 남아있는지
           B-06  기초데이터 이관 검증 채권/채무 기초 vs 전표 대사

         ※ B-01(마스터 스코어카드)은 `B01_마스터품질_스코어카드.sql`,
           B-03(미등록 코드 추출)은 `전표_관리항목_검증.sql` 쿼리 B 에서 이미 다룬다.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ ★ B-02 가 가장 먼저인 이유 ]
  ----------------------------------------------------------------------------------------------
     이 산출물군 전체가 `EXPIRE_YN='1' = 진행` 이라는 전제 위에 서 있다. 반대로 걸면
     **결과가 통째로 비어버린다.** 실제로 개발 중 두 번 반대로 걸어 전 건이 사라진 적이 있다.
     `DOC_ST` 도 API 규약(0미처리/1처리)과 UDR(0계획/1확정/2마감)로 갈린다.

     그래서 쿼리 A 는 단순 분포가 아니라 **"이 값이 진행인가"를 데이터로 역추적**한다.
     예: `EXPIRE_YN` 별로 "미출고 잔량이 남아있는 비율"을 보면 어느 쪽이 진행인지 드러난다.
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
    ,@FR_DT    NVARCHAR(8)  = N'20260101'
    ,@TO_DT    NVARCHAR(8)  = N'20261231'
    ,@MAX_LVL  INT          = 15               -- BOM 레벨 경고 기준
    ,@AR_ACCT  NVARCHAR(10) = N'10800'         -- 외상매출금 계정 ★ 사이트 확인 필수
    ,@AP_ACCT  NVARCHAR(10) = N'25100'         -- 외상매입금 계정 ★ 사이트 확인 필수
;

DECLARE @BOM NVARCHAR(30) = NULL;
DECLARE @SQL NVARCHAR(MAX);

-- BOM 테이블 결정 (SBOM_WF 우선, 없으면 SBOM)
IF    OBJECT_ID(N'dbo.SBOM_WF', N'U') IS NOT NULL SET @BOM = N'SBOM_WF';
ELSE IF OBJECT_ID(N'dbo.SBOM'  , N'U') IS NOT NULL SET @BOM = N'SBOM';
PRINT N'[0] BOM 테이블 = ' + ISNULL(@BOM, N'없음');


/*==============================================================================================
  ** 쿼리 A : 코드값 분포 점검  (B-02)  ★ 산출물 전체의 전제를 검증한다
     ─ 단순 COUNT 가 아니라 "이 값이 진행인가"를 데이터로 역추적한다.
==============================================================================================*/
SELECT N'[A] 코드값 분포 — EXPIRE_YN' AS REPORT_NM, * FROM (
    -- 수주 : 미출고 잔량이 남은 쪽이 '진행'
    SELECT
         테이블 = N'LSO_D (수주)'
        ,코드값 = ISNULL(D.EXPIRE_YN, N'(NULL)')
        ,건수   = COUNT(*)
        ,잔량있음 = SUM(CASE WHEN ISNULL(D.SO_QT,0) - ISNULL(D.ISU_QT,0) > 0 THEN 1 ELSE 0 END)
        ,잔량비율_PCT = CAST(SUM(CASE WHEN ISNULL(D.SO_QT,0)-ISNULL(D.ISU_QT,0) > 0 THEN 1.0 ELSE 0 END)
                             / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
        ,해석 = CASE WHEN SUM(CASE WHEN ISNULL(D.SO_QT,0)-ISNULL(D.ISU_QT,0) > 0 THEN 1.0 ELSE 0 END)
                          / NULLIF(COUNT(*), 0) > 0.3
                     THEN N'★ 미출고 잔량이 많다 → 이 값이 진행'
                     ELSE N'대부분 완결 → 이 값이 마감/만료' END
    FROM   LSO_D D WITH (NOLOCK)
    WHERE  D.CO_CD = @CO_CD AND ISNULL(D.USE_YN, N'1') = N'1'
    GROUP BY D.EXPIRE_YN
    UNION ALL
    -- 발주 : 미입고 잔량이 남은 쪽이 '진행'
    SELECT
         N'LPO_D (발주)'
        ,ISNULL(D.EXPIRE_YN, N'(NULL)')
        ,COUNT(*)
        ,SUM(CASE WHEN ISNULL(D.PO_QT,0) - ISNULL(R.RCV,0) > 0 THEN 1 ELSE 0 END)
        ,CAST(SUM(CASE WHEN ISNULL(D.PO_QT,0)-ISNULL(R.RCV,0) > 0 THEN 1.0 ELSE 0 END)
              / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
        ,CASE WHEN SUM(CASE WHEN ISNULL(D.PO_QT,0)-ISNULL(R.RCV,0) > 0 THEN 1.0 ELSE 0 END)
                   / NULLIF(COUNT(*), 0) > 0.3
              THEN N'★ 미입고 잔량이 많다 → 이 값이 진행'
              ELSE N'대부분 완결 → 이 값이 마감/만료' END
    FROM   LPO_D D WITH (NOLOCK)
    OUTER APPLY (SELECT RCV = SUM(CAST(ISNULL(S.RCV_QT,0) AS DECIMAL(19,6)))
                 FROM LSTOCK_D S WITH (NOLOCK)
                 WHERE S.CO_CD=D.CO_CD AND S.PO_NB=D.PO_NB AND S.PO_SQ=D.PO_SQ
                   AND ISNULL(S.USE_YN,N'1')=N'1') R
    WHERE  D.CO_CD = @CO_CD AND ISNULL(D.USE_YN, N'1') = N'1'
    GROUP BY D.EXPIRE_YN
    UNION ALL
    -- 작업지시 : 미완료 잔량이 남은 쪽이 '진행'
    SELECT
         N'LWO_WF (작업지시)'
        ,ISNULL(W.EXPIRE_YN, N'(NULL)')
        ,COUNT(*)
        ,SUM(CASE WHEN CAST(ISNULL(W.ITEM_QT,0) AS DECIMAL(19,6)) - ISNULL(G.GOOD,0) > 0 THEN 1 ELSE 0 END)
        ,CAST(SUM(CASE WHEN CAST(ISNULL(W.ITEM_QT,0) AS DECIMAL(19,6)) - ISNULL(G.GOOD,0) > 0
                       THEN 1.0 ELSE 0 END) / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
        ,CASE WHEN SUM(CASE WHEN CAST(ISNULL(W.ITEM_QT,0) AS DECIMAL(19,6)) - ISNULL(G.GOOD,0) > 0
                            THEN 1.0 ELSE 0 END) / NULLIF(COUNT(*), 0) > 0.3
              THEN N'★ 미완료가 많다 → 이 값이 생산진행'
              ELSE N'대부분 완료 → 이 값이 생산마감' END
    FROM   LWO_WF W WITH (NOLOCK)
    OUTER APPLY (SELECT GOOD = SUM(CASE WHEN ISNULL(R.SUB_TP,N'0')=N'0' AND ISNULL(R.BAD_YN,N'0')=N'0'
                                        THEN CAST(ISNULL(R.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
                 FROM LORCV_H R WITH (NOLOCK)
                 WHERE R.CO_CD=W.CO_CD AND R.WO_CD=W.WO_CD AND ISNULL(R.USE_YN,N'1')=N'1') G
    WHERE  W.CO_CD = @CO_CD AND ISNULL(W.USE_YN, N'1') = N'1'
    GROUP BY W.EXPIRE_YN
) X
ORDER BY 테이블, 코드값
;

-- 그 외 핵심 코드값 분포
SELECT N'[A-2] 코드값 분포 — 기타' AS REPORT_NM, * FROM (
    SELECT 순서=1, 테이블=N'LWO_WF.DOC_ST', 코드값=ISNULL(DOC_ST,N'(NULL)'), 건수=COUNT(*)
          ,해석=N'0/1 만 → API 해석(0미처리/1처리). 0/1/2 → UDR 해석(0계획/1확정/2마감)'
    FROM LWO_WF WITH (NOLOCK) WHERE CO_CD=@CO_CD GROUP BY DOC_ST
    UNION ALL
    SELECT 2, N'LDELIVER.SO_FG', ISNULL(SO_FG,N'(NULL)'), COUNT(*)
          ,N'채권 대상은 표준적으로 0/2/7. 다른 값이 많으면 무슨 거래인지 확인'
    FROM LDELIVER WITH (NOLOCK) WHERE CO_CD=@CO_CD GROUP BY SO_FG
    UNION ALL
    SELECT 3, N'LRCP_D.RCPAM_FG', ISNULL(RCPAM_FG,N'(NULL)'), COUNT(*)
          ,N'0=영업모듈 수금. 다른 값은 회계 직접수금 등'
    FROM LRCP_D WITH (NOLOCK) WHERE CO_CD=@CO_CD GROUP BY RCPAM_FG
    UNION ALL
    SELECT 4, N'LINVTORY.GRP_FG', ISNULL(GRP_FG,N'(NULL)'), COUNT(*)
          ,N'0생산 2구매입고 3매출출고 5재고이동 6조정/해체/이월'
    FROM LINVTORY WITH (NOLOCK) WHERE CO_CD=@CO_CD AND P_YR=@P_YR GROUP BY GRP_FG
    UNION ALL
    SELECT 5, N'LORCV_H.SUB_TP', ISNULL(SUB_TP,N'(NULL)'), COUNT(*)
          ,N'0=주산물 1=부산물. 부산물을 양품에 합산하면 수율이 부풀려진다'
    FROM LORCV_H WITH (NOLOCK) WHERE CO_CD=@CO_CD GROUP BY SUB_TP
    UNION ALL
    SELECT 6, N'LORCV_H.BAD_YN', ISNULL(BAD_YN,N'(NULL)'), COUNT(*)
          ,N'0=적합 1=부적합. 1 이 전혀 없으면 불량을 다른 방식으로 관리하는 사이트'
    FROM LORCV_H WITH (NOLOCK) WHERE CO_CD=@CO_CD GROUP BY BAD_YN
    UNION ALL
    SELECT 7, N'SITEM.ACCT_FG', ISNULL(ACCT_FG,N'(NULL)'), COUNT(*)
          ,N'0원재료 1부재료 2제품 4반제품 5상품 (3 미사용)'
    FROM SITEM WITH (NOLOCK) WHERE CO_CD=@CO_CD AND ISNULL(USE_YN,N'1')=N'1' GROUP BY ACCT_FG
    UNION ALL
    SELECT 8, N'SITEM.S_CD', ISNULL(S_CD,N'(NULL)'), COUNT(*)
          ,N'Z00 = 단종품. 실무 쿼리 다수가 공통으로 제외한다'
    FROM SITEM WITH (NOLOCK) WHERE CO_CD=@CO_CD GROUP BY S_CD
) X
ORDER BY 순서, 코드값
;


/*==============================================================================================
  ** 쿼리 B : BOM 미등록 점검  (B-04)
     ─ 생산품목인데 BOM 이 없으면 소요량 전개(MRP)와 표준원가가 산출되지 않는다.
==============================================================================================*/
IF @BOM IS NOT NULL
BEGIN
    SET @SQL = N'
    SELECT
         N''[B] BOM 미등록 점검'' AS REPORT_NM
        ,구분 = CASE WHEN W.WO_CNT > 0 THEN N''1.★지시 이력 있는데 BOM 없음''
                     WHEN S.SO_CNT > 0 THEN N''2.★수주 이력 있는데 BOM 없음''
                     ELSE N''3.BOM 없음 (거래 이력도 없음)'' END
        ,I.ITEM_CD                  AS 품번
        ,I.ITEM_NM                  AS 품명
        ,I.SPEC                     AS 규격
        ,계정구분 = CASE I.ACCT_FG WHEN N''2'' THEN N''제품'' WHEN N''4'' THEN N''반제품''
                                   ELSE I.ACCT_FG END
        ,ISNULL(W.WO_CNT, 0)        AS 작업지시건수
        ,ISNULL(W.WO_QT , 0)        AS 지시수량계
        ,ISNULL(S.SO_CNT, 0)        AS 수주건수
        ,I.LEAD_DT                  AS 리드타임
        ,영향 = N''MRP 소요량 전개 불가 + 표준원가 산출 불가 (C-04 에서 표준 0 으로 나온다)''
    FROM       SITEM I WITH (NOLOCK)
    OUTER APPLY (SELECT WO_CNT = COUNT(*), WO_QT = SUM(CAST(ISNULL(X.ITEM_QT,0) AS DECIMAL(19,6)))
                 FROM LWO_WF X WITH (NOLOCK)
                 WHERE X.CO_CD=I.CO_CD AND X.ITEM_CD=I.ITEM_CD
                   AND X.ORD_DT BETWEEN @p_FR AND @p_TO AND ISNULL(X.USE_YN,N''1'')=N''1'') W
    OUTER APPLY (SELECT SO_CNT = COUNT(*)
                 FROM LSO_D X WITH (NOLOCK)
                 WHERE X.CO_CD=I.CO_CD AND X.ITEM_CD=I.ITEM_CD
                   AND ISNULL(X.USE_YN,N''1'')=N''1'') S
    WHERE  I.CO_CD = @p_CO
      AND  ISNULL(I.USE_YN, N''1'') = N''1''
      AND  I.ACCT_FG IN (N''2'', N''4'')              -- 제품·반제품만 BOM 대상
      AND  ISNULL(I.S_CD, N'''') <> N''Z00''
      AND  NOT EXISTS (SELECT 1 FROM dbo.' + @BOM + N' B WITH (NOLOCK)
                       WHERE B.CO_CD = I.CO_CD AND B.ITEM_CD = I.ITEM_CD
                         AND ISNULL(B.USE_YN, N''1'') = N''1'')
    ORDER BY 구분, ISNULL(W.WO_CNT,0) DESC';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_FR NVARCHAR(8), @p_TO NVARCHAR(8)'
            ,@p_CO=@CO_CD, @p_FR=@FR_DT, @p_TO=@TO_DT;
    END TRY
    BEGIN CATCH
        SELECT N'[B] BOM 미등록 점검' AS REPORT_NM, N'조회 실패 : ' + ERROR_MESSAGE() AS 결과;
    END CATCH
END
ELSE
    SELECT N'[B] BOM 미등록 점검' AS REPORT_NM, N'BOM 테이블(SBOM_WF/SBOM) 없음 - 생략' AS 결과;


/*==============================================================================================
  ** 쿼리 C : BOM 순환참조 · 레벨 과다 점검  (B-04)
     ─ PATH 문자열로 순환을 차단하면서 전개한다. 순환이 있으면 MRP 가 무한 루프에 빠진다.
==============================================================================================*/
IF @BOM IS NOT NULL
BEGIN
    SET @SQL = N'
    ;WITH X AS (
        -- 최상위 (모품목으로만 쓰이는 품목)
        SELECT
             ROOT_CD = B.ITEM_CD
            ,B.ITEM_CD
            ,B.CITEM_CD
            ,LVL  = 1
            ,PATH = CAST(N''|'' + B.ITEM_CD + N''|'' + B.CITEM_CD + N''|'' AS NVARCHAR(4000))
            ,CYCLE = CAST(0 AS INT)
        FROM   dbo.' + @BOM + N' B WITH (NOLOCK)
        WHERE  B.CO_CD = @p_CO
          AND  ISNULL(B.USE_YN, N''1'') = N''1''
          AND  NOT EXISTS (SELECT 1 FROM dbo.' + @BOM + N' P WITH (NOLOCK)
                           WHERE P.CO_CD = B.CO_CD AND P.CITEM_CD = B.ITEM_CD
                             AND ISNULL(P.USE_YN, N''1'') = N''1'')
        UNION ALL
        -- 하위 전개
        SELECT
             X.ROOT_CD
            ,B.ITEM_CD
            ,B.CITEM_CD
            ,X.LVL + 1
            ,CAST(X.PATH + B.CITEM_CD + N''|'' AS NVARCHAR(4000))
            ,CASE WHEN X.PATH LIKE N''%|'' + B.CITEM_CD + N''|%'' THEN 1 ELSE 0 END
        FROM       X
        INNER JOIN dbo.' + @BOM + N' B WITH (NOLOCK)
                ON B.CO_CD = @p_CO AND B.ITEM_CD = X.CITEM_CD
               AND ISNULL(B.USE_YN, N''1'') = N''1''
        WHERE  X.LVL < 30
          AND  X.CYCLE = 0
          AND  X.PATH NOT LIKE N''%|'' + B.CITEM_CD + N''|%''   -- ★ 순환 차단
    )
    SELECT
         N''[C] BOM 구조 점검'' AS REPORT_NM
        ,구분 = CASE WHEN MAX(X.CYCLE) = 1        THEN N''1.★순환참조''
                     WHEN MAX(X.LVL) > @p_LVL      THEN N''2.★레벨 과다''
                     ELSE N''0.정상'' END
        ,X.ROOT_CD                  AS 최상위품번
        ,I.ITEM_NM                  AS 품명
        ,최대레벨   = MAX(X.LVL)
        ,전개행수   = COUNT(*)
        ,자품목수   = COUNT(DISTINCT X.CITEM_CD)
        ,순환참조   = MAX(X.CYCLE)
        ,순환경로   = MAX(CASE WHEN X.CYCLE = 1 THEN X.PATH END)
        ,영향 = CASE WHEN MAX(X.CYCLE) = 1
                     THEN N''★ MRP 소요량 전개가 무한 루프에 빠진다. BOM 을 즉시 수정할 것''
                     WHEN MAX(X.LVL) > @p_LVL
                     THEN N''레벨이 깊어 전개 성능이 떨어진다. 구조 단순화 검토''
                     ELSE N''-'' END
    FROM       X
    LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @p_CO AND I.ITEM_CD = X.ROOT_CD
    GROUP BY X.ROOT_CD, I.ITEM_NM
    HAVING MAX(X.CYCLE) = 1 OR MAX(X.LVL) > @p_LVL
    ORDER BY 구분, 최대레벨 DESC
    OPTION (MAXRECURSION 100)';
    BEGIN TRY
        EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_LVL INT', @p_CO=@CO_CD, @p_LVL=@MAX_LVL;
    END TRY
    BEGIN CATCH
        SELECT N'[C] BOM 구조 점검' AS REPORT_NM
              ,N'조회 실패 : ' + ERROR_MESSAGE() AS 결과
              ,N'순환참조가 있으면 MAXRECURSION 오류가 날 수 있다. 그 자체가 순환의 증거다' AS 비고;
    END CATCH
END
ELSE
    SELECT N'[C] BOM 구조 점검' AS REPORT_NM, N'BOM 테이블 없음 - 생략' AS 결과;


/*==============================================================================================
  ** 쿼리 D : 단종품 사용 점검  (B-05)
     ─ S_CD='Z00' 인 품목이 진행 중인 수주·지시·BOM 에 남아 있으면 안 된다.
==============================================================================================*/
SELECT
     N'[D] 단종품 사용 점검'                        AS REPORT_NM
    ,사용처, 품번, 품명, 계정구분, 건수, 수량, 최근일자, 영향
FROM (
    -- 진행 중 수주
    SELECT
         순서 = 1
        ,사용처 = N'1.★진행 중 수주 (LSO_D)'
        ,품번 = D.ITEM_CD
        ,품명 = I.ITEM_NM
        ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                                   WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                                   WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
        ,건수 = COUNT(*)
        ,수량 = SUM(CAST(ISNULL(D.SO_QT,0) - ISNULL(D.ISU_QT,0) AS DECIMAL(19,6)))
        ,최근일자 = MAX(H.SO_DT)
        ,영향 = N'단종품을 팔기로 되어 있다. 대체품 확인 또는 수주 취소 필요'
    FROM       LSO   H WITH (NOLOCK)
    INNER JOIN LSO_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.SO_NB = H.SO_NB
    INNER JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = D.CO_CD AND I.ITEM_CD = D.ITEM_CD
    WHERE  H.CO_CD = @CO_CD
      AND  ISNULL(I.S_CD, N'') = N'Z00'
      AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
      AND  ISNULL(D.SO_QT,0) - ISNULL(D.ISU_QT,0) > 0
    GROUP BY D.ITEM_CD, I.ITEM_NM, I.ACCT_FG

    UNION ALL
    -- 진행 중 작업지시
    SELECT
         2, N'2.★진행 중 작업지시 (LWO_WF)', W.ITEM_CD, I.ITEM_NM
        ,CASE I.ACCT_FG WHEN N'2' THEN N'제품' WHEN N'4' THEN N'반제품' ELSE I.ACCT_FG END
        ,COUNT(*), SUM(CAST(ISNULL(W.ITEM_QT,0) AS DECIMAL(19,6))), MAX(W.ORD_DT)
        ,N'단종품을 생산하려 한다. 지시 취소 또는 대체품 전환 필요'
    FROM       LWO_WF W WITH (NOLOCK)
    INNER JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = W.CO_CD AND I.ITEM_CD = W.ITEM_CD
    WHERE  W.CO_CD = @CO_CD
      AND  ISNULL(I.S_CD, N'') = N'Z00'
      AND  ISNULL(W.USE_YN, N'1') = N'1' AND ISNULL(W.EXPIRE_YN, N'1') = N'1'
    GROUP BY W.ITEM_CD, I.ITEM_NM, I.ACCT_FG

    UNION ALL
    -- 진행 중 발주
    SELECT
         3, N'3.★진행 중 발주 (LPO_D)', D.ITEM_CD, I.ITEM_NM
        ,CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                        WHEN N'5' THEN N'상품' ELSE I.ACCT_FG END
        ,COUNT(*), SUM(CAST(ISNULL(D.PO_QT,0) AS DECIMAL(19,6))), MAX(H.PO_DT)
        ,N'단종품을 사려 한다. 발주 취소 검토'
    FROM       LPO   H WITH (NOLOCK)
    INNER JOIN LPO_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.PO_NB = H.PO_NB
    INNER JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = D.CO_CD AND I.ITEM_CD = D.ITEM_CD
    WHERE  H.CO_CD = @CO_CD
      AND  ISNULL(I.S_CD, N'') = N'Z00'
      AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
    GROUP BY D.ITEM_CD, I.ITEM_NM, I.ACCT_FG

    UNION ALL
    -- 재고 보유
    SELECT
         4, N'4.단종품 재고 보유 (LINVTORY)', V.ITEM_CD, I.ITEM_NM
        ,CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                        WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                        WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
        ,COUNT(DISTINCT V.WH_CD)
        ,SUM(CAST(ISNULL(V.IOPEN_QT,0)+ISNULL(V.IRCV_QT,0)-ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)))
        ,MAX(V.IO_DT)
        ,N'단종품 재고가 남아 있다. 처분 또는 대체 사용 검토 (P-05 체화재고)'
    FROM       LINVTORY V WITH (NOLOCK)
    INNER JOIN SITEM    I WITH (NOLOCK) ON I.CO_CD = V.CO_CD AND I.ITEM_CD = V.ITEM_CD
    WHERE  V.CO_CD = @CO_CD AND V.P_YR = @P_YR
      AND  ISNULL(I.S_CD, N'') = N'Z00'
      AND  ISNULL(V.USE_YN, N'1') = N'1' AND ISNULL(V.EXPIRE_YN, N'1') = N'1'
    GROUP BY V.ITEM_CD, I.ITEM_NM, I.ACCT_FG
    HAVING SUM(CAST(ISNULL(V.IOPEN_QT,0)+ISNULL(V.IRCV_QT,0)-ISNULL(V.IISU_QT,0) AS DECIMAL(19,6))) <> 0
) X
ORDER BY 순서, 수량 DESC
;

-- 단종품이 BOM 자재로 남아 있는지 (별도 조회 — 동적)
IF @BOM IS NOT NULL
BEGIN
    SET @SQL = N'
    SELECT
         N''[D-2] 단종품이 BOM 자재로 등록됨'' AS REPORT_NM
        ,B.ITEM_CD                  AS 모품번
        ,PI.ITEM_NM                 AS 모품명
        ,B.CITEM_CD                 AS 단종_자품번
        ,CI.ITEM_NM                 AS 자품명
        ,B.' + CASE WHEN EXISTS (SELECT 1 FROM sys.columns
                                 WHERE object_id = OBJECT_ID(N'dbo.' + @BOM) AND name = N'USE_QT')
                    THEN N'USE_QT' ELSE N'CITEM_QT' END + N' AS 소요량
        ,모품_사용여부 = CASE WHEN EXISTS (SELECT 1 FROM LWO_WF W WITH (NOLOCK)
                                           WHERE W.CO_CD=@p_CO AND W.ITEM_CD=B.ITEM_CD
                                             AND ISNULL(W.EXPIRE_YN,N''1'')=N''1'')
                              THEN N''★ 모품목이 생산 진행 중 - 즉시 대체 필요''
                              ELSE N''모품목 생산 없음'' END
        ,영향 = N''생산 시 단종 자재를 청구하게 된다. BOM 을 대체품으로 교체할 것''
    FROM       dbo.' + @BOM + N' B WITH (NOLOCK)
    INNER JOIN SITEM CI WITH (NOLOCK) ON CI.CO_CD = B.CO_CD AND CI.ITEM_CD = B.CITEM_CD
    LEFT  JOIN SITEM PI WITH (NOLOCK) ON PI.CO_CD = B.CO_CD AND PI.ITEM_CD = B.ITEM_CD
    WHERE  B.CO_CD = @p_CO
      AND  ISNULL(B.USE_YN, N''1'') = N''1''
      AND  ISNULL(CI.S_CD, N'''') = N''Z00''
    ORDER BY 모품_사용여부 DESC, B.ITEM_CD';
    BEGIN TRY
        EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4)', @p_CO=@CO_CD;
    END TRY
    BEGIN CATCH
        SELECT N'[D-2] 단종품 BOM 점검' AS REPORT_NM, N'조회 실패 : ' + ERROR_MESSAGE() AS 결과;
    END CATCH
END


/*==============================================================================================
  ** 쿼리 E : 기초데이터 이관 검증  (B-06)
     ─ 채권/채무 기초가 전표(장부)와 맞는지 본다. 이관 직후 반드시 확인해야 한다.
       ★ 계정과목 코드(@AR_ACCT/@AP_ACCT)는 사이트마다 다르다. 반드시 먼저 확인할 것.
==============================================================================================*/
SELECT
     N'[E] 기초데이터 이관 검증'                    AS REPORT_NM
    ,구분, 물류기초, 전표기초, 차이, 판정
FROM (
    -- 채권 (출고기준)
    SELECT
         순서 = 1
        ,구분 = N'1.채권 기초 (출고기준 LOPN_CRISU)'
        ,물류기초 = ISNULL((SELECT SUM(CAST(ISNULL(OPEN_AM,0) AS DECIMAL(19,4)))
                            FROM LOPN_CRISU WITH (NOLOCK)
                            WHERE CO_CD=@CO_CD AND P_YR=@P_YR
                              AND (@DIV_CD IS NULL OR DIV_CD=@DIV_CD)), 0)
        ,전표기초 = ISNULL((SELECT SUM(CAST(ISNULL(D.DR_AM,0)-ISNULL(D.CR_AM,0) AS DECIMAL(19,4)))
                            FROM ADOCUD D WITH (NOLOCK)
                            WHERE D.CO_CD=@CO_CD AND LEFT(D.DOCU_DT,4)=@P_YR
                              AND D.ACCT_CD = @AR_ACCT
                              AND (@DIV_CD IS NULL OR D.DIV_CD=@DIV_CD)), 0)
    UNION ALL
    -- 채무
    SELECT
         2, N'2.채무 기초 (LOPN_PAY)'
        ,ISNULL((SELECT SUM(CAST(ISNULL(OPEN_AM,0) AS DECIMAL(19,4)))
                 FROM LOPN_PAY WITH (NOLOCK)
                 WHERE CO_CD=@CO_CD AND P_YR=@P_YR
                   AND (@DIV_CD IS NULL OR DIV_CD=@DIV_CD)), 0)
        ,ISNULL((SELECT SUM(CAST(ISNULL(D.CR_AM,0)-ISNULL(D.DR_AM,0) AS DECIMAL(19,4)))
                 FROM ADOCUD D WITH (NOLOCK)
                 WHERE D.CO_CD=@CO_CD AND LEFT(D.DOCU_DT,4)=@P_YR
                   AND D.ACCT_CD = @AP_ACCT
                   AND (@DIV_CD IS NULL OR D.DIV_CD=@DIV_CD)), 0)
) X
CROSS APPLY (SELECT 차이 = X.물류기초 - X.전표기초) C
CROSS APPLY (SELECT 판정 = CASE
                 WHEN X.물류기초 = 0 AND X.전표기초 = 0 THEN N'9.양쪽 다 0 - 이관 미실행 또는 해당 없음'
                 WHEN X.물류기초 = 0                    THEN N'1.★물류 기초 없음 - LOPN_* 이관 누락'
                 WHEN X.전표기초 = 0                    THEN N'2.★전표 없음 - 계정코드 확인 또는 개시전표 누락'
                 WHEN ABS(C.차이) < 1                    THEN N'0.일치'
                 ELSE N'3.★차이 존재 - 이관 데이터 재검증 필요' END) P
ORDER BY X.순서
;

-- 기초 테이블 4종 존재/건수
SELECT
     N'[E-2] 기초 테이블 현황'                      AS REPORT_NM
    ,테이블, 역할
    ,존재 = CASE WHEN OBJECT_ID(N'dbo.' + 테이블, N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,비고
FROM (VALUES
     (1, N'LOPN_CRISU'    , N'채권 기초 (출고기준)', N'선행 지표')
    ,(2, N'LOPN_CRISU_CLS', N'채권 기초 (마감기준)', N'★ 최종 채권의 기초')
    ,(3, N'LOPN_PAY'      , N'채무 기초'           , N'')
    ,(4, N'LOPN_PAY_CLS'  , N'채무 기초 (마감기준)', N'')
    ,(5, N'LCR_ADJUST'    , N'채권 조정'           , N'기초 이후 조정분')
    ,(6, N'LCR_LIMIT'     , N'여신한도'            , N'S-06 에서 사용')
) V(순서, 테이블, 역할, 비고)
ORDER BY 순서
;


/*==============================================================================================
  ** 쿼리 F : 종합 판정
==============================================================================================*/
SELECT
     N'[F] 마스터 점검 종합'                        AS REPORT_NM
    ,@CO_CD                                         AS 회사
    ,@P_YR                                          AS 회계연도
    ,BOM_테이블 = ISNULL(@BOM, N'★없음')
    -- B-04
    ,BOM_미등록_생산품목 = CASE WHEN @BOM IS NULL THEN NULL ELSE
         (SELECT COUNT(*) FROM SITEM I WITH (NOLOCK)
          WHERE I.CO_CD=@CO_CD AND ISNULL(I.USE_YN,N'1')=N'1'
            AND I.ACCT_FG IN (N'2',N'4') AND ISNULL(I.S_CD,N'')<>N'Z00'
            AND EXISTS (SELECT 1 FROM LWO_WF W WITH (NOLOCK)
                        WHERE W.CO_CD=I.CO_CD AND W.ITEM_CD=I.ITEM_CD
                          AND W.ORD_DT BETWEEN @FR_DT AND @TO_DT)) END
    -- B-05
    ,단종품_진행수주 = (SELECT COUNT(*) FROM LSO_D D WITH (NOLOCK)
                        INNER JOIN SITEM I WITH (NOLOCK) ON I.CO_CD=D.CO_CD AND I.ITEM_CD=D.ITEM_CD
                        WHERE D.CO_CD=@CO_CD AND ISNULL(I.S_CD,N'')=N'Z00'
                          AND ISNULL(D.EXPIRE_YN,N'1')=N'1'
                          AND ISNULL(D.SO_QT,0)-ISNULL(D.ISU_QT,0) > 0)
    ,단종품_진행지시 = (SELECT COUNT(*) FROM LWO_WF W WITH (NOLOCK)
                        INNER JOIN SITEM I WITH (NOLOCK) ON I.CO_CD=W.CO_CD AND I.ITEM_CD=W.ITEM_CD
                        WHERE W.CO_CD=@CO_CD AND ISNULL(I.S_CD,N'')=N'Z00'
                          AND ISNULL(W.EXPIRE_YN,N'1')=N'1')
    ,단종품_총수 = (SELECT COUNT(*) FROM SITEM WITH (NOLOCK)
                    WHERE CO_CD=@CO_CD AND ISNULL(S_CD,N'')=N'Z00')
    -- B-06
    ,채권기초_등록 = CASE WHEN EXISTS (SELECT 1 FROM LOPN_CRISU WITH (NOLOCK)
                                       WHERE CO_CD=@CO_CD AND P_YR=@P_YR) THEN N'O' ELSE N'X' END
    ,채무기초_등록 = CASE WHEN EXISTS (SELECT 1 FROM LOPN_PAY WITH (NOLOCK)
                                       WHERE CO_CD=@CO_CD AND P_YR=@P_YR) THEN N'O' ELSE N'X' END
    ,권장조치 = N'쿼리 A 로 코드값 해석을 먼저 확정한 뒤 나머지 점검 결과를 해석할 것'
;


GO


/*==============================================================================================
  [ 상시 점검 운영 ]
  ----------------------------------------------------------------------------------------------
  실행 시점 : **사이트 첫 적용 시 반드시 1회** + 이후 분기 1회 (또는 마스터 대량 변경 후)
  실행 순서 : ① 쿼리 A 로 코드값 해석 확정  ★ 가장 먼저. 다른 모든 리포트의 전제
              ② 결과가 이 산출물군의 전제(EXPIRE_YN='1'=진행)와 다르면
                 전 파일의 필터를 일괄 수정해야 한다
              ③ 쿼리 B·C 로 BOM 정비 → MRP·표준원가가 비로소 동작
              ④ 쿼리 D 로 단종품 정리
              ⑤ 쿼리 E 는 **이관 직후 1회**만 의미가 있다

  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) BOM 테이블명  ★ SBOM 과 SBOM_WF 가 다르다
     SELECT name FROM sys.tables WHERE name IN ('SBOM','SBOM_WF','SBOM_WF_B');
     --> SBOM_WF 가 작업지시용 BOM, SBOM_WF_B 가 BATCH BOM 이다.

  -- (2) BOM 컬럼명  ★ 쿼리 C 는 ITEM_CD(모) / CITEM_CD(자) 를 전제한다
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('SBOM_WF') ORDER BY column_id;

  -- (3) 계정과목 코드  ★ 쿼리 E 의 전제. 기본값(10800/25100)은 일반적인 예시일 뿐이다
     SELECT ACCT_CD, ACCT_NM FROM SACCT
     WHERE CO_CD='1000' AND (ACCT_NM LIKE '%외상매출%' OR ACCT_NM LIKE '%외상매입%');
     --> 여기서 나온 코드를 @AR_ACCT / @AP_ACCT 에 넣을 것. 안 바꾸면 쿼리 E 가 전부 0 이다.

  -- (4) 전표 테이블 컬럼  ★ 차변/대변 컬럼명
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('ADOCUD')
       AND name IN ('DR_AM','CR_AM','ACCT_CD','DOCU_DT','DIV_CD');

  -- (5) 단종 코드 확인  ★ Z00 이 맞는지
     SELECT S_CD, COUNT(*) FROM SITEM WHERE CO_CD='1000' GROUP BY S_CD ORDER BY COUNT(*) DESC;
     --> 'Z00' 이 없고 다른 코드를 쓰면 전 산출물의 단종품 제외 조건을 바꿔야 한다.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **쿼리 A 의 '해석' 은 추론이다.** 잔량 비율로 어느 코드값이 진행인지 역추적하지만,
     데이터가 적거나 운영 패턴이 특이하면 틀릴 수 있다. 최종 확인은 ERP 화면에서
     진행 중인 건 하나를 열어 실제 값을 보는 것이다.

  2) **쿼리 C 는 BOM 레벨 30, MAXRECURSION 100 으로 제한**했다. 순환참조가 심하면
     그 전에 오류가 날 수 있는데, **오류 자체가 순환의 증거**이므로 그때는 BOM 을
     먼저 수정해야 한다. CATCH 블록에 이 안내를 넣어 두었다.

  3) **쿼리 E(B-06)는 단순 총액 비교**다. 계정과목을 하나씩만 보므로, 채권을 여러 계정으로
     나눠 관리하는 사이트(외상매출금/받을어음/미수금)에서는 차이가 크게 난다.
     그 경우 @AR_ACCT 를 `IN (...)` 으로 바꿔야 한다. 그리고 물류 기초와 전표 기초의
     **집계 기간 정의가 다르면** 비교 자체가 성립하지 않으므로, 이관 담당자와 기준을
     맞춘 뒤에 쓸 것.

  4) 이 파일은 마스터를 **고치지 않는다.** 문제를 찾아 목록으로 낼 뿐이며,
     수정은 ERP 마스터 화면에서 해야 한다.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   B01_마스터품질_스코어카드.sql : 마스터 등록률 계량화 (B-01)
   전표_관리항목_검증.sql        : 미등록 코드 추출 (B-03)
   원자재수급총괄현황_MRP.sql    : BOM 이 정비되어야 동작 (쿼리 B·C 의 수요처)
   P05_재고알람_KPI.sql          : 단종품 재고 = 체화재고 (쿼리 D 연계)
   S06_채권여신_관리현황.sql     : 기초채권이 맞아야 채권 잔액이 맞는다 (쿼리 E 연계)
==============================================================================================*/
