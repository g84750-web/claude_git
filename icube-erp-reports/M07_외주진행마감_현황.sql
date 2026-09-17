/*==============================================================================================
  [ iCUBE ] M-07  외주 진행 · 마감 현황                                              (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 외주 지시 → 자재 출고(사급) → 입고 → 외주마감 → 외주비 확정까지의 전 과정을 추적한다.
         외주비는 **제조원가의 주요 구성요소**이므로 마감이 누락되면 원가가 통째로 틀어진다.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 소스 체인 ]
  ----------------------------------------------------------------------------------------------
     LWO_WF (DOC_FG='1' 외주 / WOC_FG='4' 외주발주)   외주 지시
       ├→ LWO_REQ_WF + LSTKMOVE                       사급 자재 출고 (무상/유상)
       ├→ LORCV_H                                     외주 실적 (가공 완료)
       ├→ LPRDINWH                                    외주품 입고
       └→ LOCLS_H / LOCLS_D                           **외주마감 = 외주비 확정**  ★

  ----------------------------------------------------------------------------------------------
  [ ★ 외주비 소스는 LOCLS_H / LOCLS_D 다 ]
  ----------------------------------------------------------------------------------------------
     원가계산 SP(`USP_COT0010_CALC_COST_TAV`)가 외주비를 집계할 때 쓰는 테이블이 이것이다.
     `LWO_WF_D.LBR_AM`(지시상의 예정 가공비)이 아니다. 지시 금액은 **예정치**이고,
     마감 금액이 **확정치**이므로 원가에는 마감이 들어간다.

  ----------------------------------------------------------------------------------------------
  [ 사급 구분 ]
  ----------------------------------------------------------------------------------------------
     UMU_FG / OUT_FG  0.무상 / 1.유상
     무상사급 — 자재를 대주고 가공비만 지급. 자재는 우리 재고로 남는다.
     유상사급 — 자재를 팔고 완제품을 되산다. 매출·매입이 동시에 발생한다.
     **둘을 섞으면 외주비와 재고가 모두 틀어진다.**
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@FR_DT    NVARCHAR(8)  = N'20260101'
    ,@TO_DT    NVARCHAR(8)  = N'20261231'
    ,@TR_CD    NVARCHAR(10) = NULL            -- 외주처
    ,@ITEM_CD  NVARCHAR(25) = NULL
    ,@BASE_DT  NVARCHAR(8)  = N'20260916'
    ,@DOC_FG   NVARCHAR(1)  = N'1'            -- 1 = 외주 (사이트 확인 필요)
;

DECLARE @HAS_OCLS BIT = 0;
IF OBJECT_ID(N'dbo.LOCLS_H', N'U') IS NOT NULL AND OBJECT_ID(N'dbo.LOCLS_D', N'U') IS NOT NULL
    SET @HAS_OCLS = 1;

IF OBJECT_ID('tempdb..#OW')  IS NOT NULL DROP TABLE #OW;
IF OBJECT_ID('tempdb..#CLS') IS NOT NULL DROP TABLE #CLS;


/*==============================================================================================
  1. #OW : 외주 지시 + 실적 + 입고
==============================================================================================*/
SELECT
     W.WO_CD
    ,W.ORD_DT
    ,W.COMP_DT
    ,W.ITEM_CD
    ,W.TR_CD
    ,W.DOC_FG
    ,W.WOC_FG
    ,W.EXPIRE_YN
    ,W.DOC_ST
    ,W.PJT_CD
    ,W.DEPT_CD
    ,ORD_QT  = CAST(ISNULL(W.ITEM_QT, 0) AS DECIMAL(19,6))
    ,GOOD_QT = ISNULL(R.GOOD_QT, 0)
    ,BAD_QT  = ISNULL(R.BAD_QT , 0)
    ,RCV_CNT = ISNULL(R.CNT, 0)
    ,LAST_WR = R.LAST_DT
    ,INWH_QT = ISNULL(N.INW, 0)
    ,LAST_IN = N.LAST_DT
    ,MTL_REQ = ISNULL(M.REQ_QT, 0)
    ,MTL_ISU = ISNULL(M.ISU_QT, 0)
    ,MTL_CNT = ISNULL(M.CNT, 0)
INTO #OW
FROM   LWO_WF W WITH (NOLOCK)
OUTER APPLY (
    SELECT
         GOOD_QT = SUM(CASE WHEN ISNULL(X.SUB_TP,N'0')=N'0' AND ISNULL(X.BAD_YN,N'0')=N'0'
                            THEN CAST(ISNULL(X.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
        ,BAD_QT  = SUM(CASE WHEN ISNULL(X.BAD_YN,N'0')=N'1'
                            THEN CAST(ISNULL(X.ITEM_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
        ,CNT = COUNT(*), LAST_DT = MAX(X.WR_DT)
    FROM   LORCV_H X WITH (NOLOCK)
    WHERE  X.CO_CD = W.CO_CD AND X.WO_CD = W.WO_CD AND ISNULL(X.USE_YN, N'1') = N'1'
) R
OUTER APPLY (
    SELECT INW = SUM(CAST(ISNULL(P.INWH_QT,0) AS DECIMAL(19,6))), LAST_DT = MAX(P.INWH_DT)
    FROM       LPRDINWH P WITH (NOLOCK)
    INNER JOIN LORCV_H  X WITH (NOLOCK) ON X.CO_CD = P.CO_CD AND X.WR_CD = P.WR_CD
    WHERE  P.CO_CD = W.CO_CD AND X.WO_CD = W.WO_CD AND ISNULL(P.USE_YN, N'1') = N'1'
) N
OUTER APPLY (
    SELECT REQ_QT = SUM(CAST(ISNULL(Q.REQ_QT,0) AS DECIMAL(19,6)))
          ,ISU_QT = SUM(CAST(ISNULL(Q.ISU_QT,0) AS DECIMAL(19,6)))
          ,CNT = COUNT(*)
    FROM   LWO_REQ_WF Q WITH (NOLOCK)
    WHERE  Q.CO_CD = W.CO_CD AND Q.WO_CD = W.WO_CD AND ISNULL(Q.USE_YN, N'1') = N'1'
) M
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = W.CO_CD AND I.ITEM_CD = W.ITEM_CD
WHERE  W.CO_CD  = @CO_CD
  AND  W.ORD_DT BETWEEN @FR_DT AND @TO_DT
  AND  ISNULL(W.USE_YN, N'1') = N'1'
  AND  ( ISNULL(W.DOC_FG, N'') = @DOC_FG          -- 외주 구분
      OR ISNULL(W.WOC_FG, N'') = N'4' )           -- 또는 외주발주
  AND  (@DIV_CD  IS NULL OR W.DIV_CD  = @DIV_CD)
  AND  (@TR_CD   IS NULL OR W.TR_CD   = @TR_CD)
  AND  (@ITEM_CD IS NULL OR W.ITEM_CD = @ITEM_CD)
  AND  ISNULL(I.S_CD, N'') <> N'Z00';
CREATE CLUSTERED INDEX IX_OW ON #OW (WO_CD);
PRINT N'[1] 외주 지시 : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 건';


/*==============================================================================================
  2. #CLS : 외주마감 (외주비 확정)  ★ 원가에 들어가는 금액
==============================================================================================*/
CREATE TABLE #CLS (
     WO_CD   NVARCHAR(20)
    ,TR_CD   NVARCHAR(10)
    ,CLS_QT  DECIMAL(19,6)
    ,CLS_AM  DECIMAL(19,4)
    ,CLS_CNT INT
    ,LAST_DT NVARCHAR(8)
);

IF @HAS_OCLS = 1
BEGIN
    DECLARE @SQL NVARCHAR(MAX), @AMCOL NVARCHAR(30), @QTCOL NVARCHAR(30);
    SELECT TOP 1 @AMCOL = name FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.LOCLS_D')
      AND name IN (N'LBR_AM', N'CLS_AM', N'CLSG_AM', N'CLSH_AM', N'OUT_AM')
    ORDER BY CASE name WHEN N'LBR_AM' THEN 1 WHEN N'CLSG_AM' THEN 2
                       WHEN N'CLS_AM' THEN 3 ELSE 4 END;
    SELECT TOP 1 @QTCOL = name FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.LOCLS_D')
      AND name IN (N'CLS_QT', N'ITEM_QT', N'OUT_QT', N'QT')
    ORDER BY CASE name WHEN N'CLS_QT' THEN 1 WHEN N'ITEM_QT' THEN 2 ELSE 3 END;

    IF @AMCOL IS NOT NULL
    BEGIN
        SET @SQL = N'
            INSERT INTO #CLS (WO_CD, TR_CD, CLS_QT, CLS_AM, CLS_CNT, LAST_DT)
            SELECT ISNULL(D.WO_CD, N'''')
                  ,MAX(ISNULL(H.TR_CD, N''''))
                  ,' + CASE WHEN @QTCOL IS NOT NULL
                            THEN N'SUM(CAST(ISNULL(D.' + QUOTENAME(@QTCOL) + N',0) AS DECIMAL(19,6)))'
                            ELSE N'0' END + N'
                  ,SUM(CAST(ISNULL(D.' + QUOTENAME(@AMCOL) + N',0) AS DECIMAL(19,4)))
                  ,COUNT(*)
                  ,MAX(H.CLS_DT)
            FROM       dbo.LOCLS_H H WITH (NOLOCK)
            INNER JOIN dbo.LOCLS_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.CLS_NB = H.CLS_NB
            WHERE  H.CO_CD = @p_CO
              AND  ISNULL(D.USE_YN, N''1'') = N''1''
              AND  ISNULL(D.WO_CD, N'''') <> N''''
              AND  (@p_DIV IS NULL OR H.DIV_CD = @p_DIV)
            GROUP BY D.WO_CD';
        BEGIN TRY
            EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4)'
                ,@p_CO=@CO_CD, @p_DIV=@DIV_CD;
            PRINT N'[2] LOCLS_D (' + @AMCOL + N') : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 행';
        END TRY
        BEGIN CATCH
            SET @HAS_OCLS = 0;
            PRINT N'[2] ★ LOCLS 조회 실패 : ' + ERROR_MESSAGE();
        END CATCH
    END
    ELSE
    BEGIN
        SET @HAS_OCLS = 0;
        PRINT N'[2] LOCLS_D 에 금액 컬럼을 찾지 못함';
    END
END
ELSE PRINT N'[2] LOCLS_H/D 없음 - 외주비 확정액 조회 불가';

CREATE CLUSTERED INDEX IX_CLS ON #CLS (WO_CD);


/*==============================================================================================
  ** 쿼리 A : 외주 지시별 진행현황  (메인)
==============================================================================================*/
SELECT
     N'[A] 외주 진행현황'                           AS REPORT_NM
    ,진행단계 = CASE
         WHEN ISNULL(C.CLS_AM, 0) > 0                                   THEN N'5.마감(외주비 확정)'
         WHEN O.INWH_QT > 0 AND O.INWH_QT >= O.GOOD_QT                  THEN N'4.입고완료'
         WHEN O.INWH_QT > 0                                             THEN N'3.부분입고'
         WHEN O.GOOD_QT > 0                                             THEN N'2.가공중'
         WHEN O.MTL_ISU > 0                                             THEN N'1.자재출고(사급)'
         ELSE                                                                N'0.★미착수' END
    ,O.WO_CD                                        AS 지시번호
    ,O.ORD_DT                                       AS 지시일
    ,O.COMP_DT                                      AS 완료예정일
    ,O.TR_CD                                        AS 외주처코드
    ,T.TR_NM                                        AS 외주처명
    ,O.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,O.ORD_QT                                       AS 지시수량
    ,O.GOOD_QT                                      AS 가공완료
    ,O.BAD_QT                                       AS 불량
    ,O.INWH_QT                                      AS 입고수량
    ,미입고수량 = O.GOOD_QT - O.INWH_QT
    ,잔량 = O.ORD_QT - O.GOOD_QT
    ,진척률_PCT = CAST(O.GOOD_QT / NULLIF(O.ORD_QT, 0) * 100 AS DECIMAL(5,1))
    -- 사급 자재
    ,O.MTL_CNT                                      AS 사급품목수
    ,O.MTL_REQ                                      AS 사급청구
    ,O.MTL_ISU                                      AS 사급출고
    ,사급미출고 = O.MTL_REQ - O.MTL_ISU
    -- 외주비
    ,ISNULL(C.CLS_QT, 0)                            AS 마감수량
    ,ISNULL(C.CLS_AM, 0)                            AS 외주비_확정
    ,단위외주비 = CAST(ISNULL(C.CLS_AM,0) / NULLIF(NULLIF(C.CLS_QT,0), 0) AS DECIMAL(19,4))
    ,C.LAST_DT                                      AS 마감일
    -- 일정
    ,O.LAST_WR                                      AS 최종실적일
    ,O.LAST_IN                                      AS 최종입고일
    ,납기경과일 = CASE WHEN O.COMP_DT IS NOT NULL
                       THEN DATEDIFF(DAY, CONVERT(DATE,O.COMP_DT), CONVERT(DATE,@BASE_DT)) END
    ,생산상태 = CASE ISNULL(O.EXPIRE_YN, N'1') WHEN N'1' THEN N'진행' ELSE N'마감' END
    ,리스크 = CASE
         WHEN O.MTL_REQ > O.MTL_ISU AND O.GOOD_QT = 0
              THEN N'1.★사급 자재 미출고 - 외주처가 시작 못 함'
         WHEN O.COMP_DT IS NOT NULL
          AND DATEDIFF(DAY,CONVERT(DATE,O.COMP_DT),CONVERT(DATE,@BASE_DT)) > 0
          AND O.ORD_QT - O.GOOD_QT > 0
              THEN N'2.★납기 경과'
         WHEN O.GOOD_QT > O.INWH_QT
              THEN N'3.★가공 완료했으나 미입고'
         WHEN O.INWH_QT > 0 AND ISNULL(C.CLS_AM, 0) = 0
              THEN N'4.★입고했으나 외주마감 미처리 - 원가 누락'
         ELSE N'0.정상' END
    ,O.PJT_CD                                       AS 프로젝트
FROM       #OW    O
LEFT  JOIN #CLS   C ON C.WO_CD = O.WO_CD
LEFT  JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = O.ITEM_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = O.TR_CD
ORDER BY 리스크, O.COMP_DT, O.WO_CD
;


/*==============================================================================================
  ** 쿼리 B : 외주처별 집계
==============================================================================================*/
SELECT
     N'[B] 외주처별 집계'                           AS REPORT_NM
    ,O.TR_CD                                        AS 외주처코드
    ,T.TR_NM                                        AS 외주처명
    ,지시건수 = COUNT(*)
    ,품목수   = COUNT(DISTINCT O.ITEM_CD)
    ,지시수량 = SUM(O.ORD_QT)
    ,가공완료 = SUM(O.GOOD_QT)
    ,불량     = SUM(O.BAD_QT)
    ,입고수량 = SUM(O.INWH_QT)
    ,잔량     = SUM(O.ORD_QT - O.GOOD_QT)
    ,진척률_PCT = CAST(SUM(O.GOOD_QT) / NULLIF(SUM(O.ORD_QT), 0) * 100 AS DECIMAL(5,1))
    ,양품률_PCT = CAST(SUM(O.GOOD_QT)
                       / NULLIF(SUM(O.GOOD_QT) + SUM(O.BAD_QT), 0) * 100 AS DECIMAL(5,2))
    ,외주비계 = SUM(ISNULL(C.CLS_AM, 0))
    ,마감건수 = SUM(CASE WHEN ISNULL(C.CLS_AM, 0) > 0 THEN 1 ELSE 0 END)
    ,미마감건수 = SUM(CASE WHEN O.INWH_QT > 0 AND ISNULL(C.CLS_AM, 0) = 0 THEN 1 ELSE 0 END)
    ,납기경과건수 = SUM(CASE WHEN O.COMP_DT IS NOT NULL
                              AND DATEDIFF(DAY,CONVERT(DATE,O.COMP_DT),CONVERT(DATE,@BASE_DT)) > 0
                              AND O.ORD_QT - O.GOOD_QT > 0 THEN 1 ELSE 0 END)
    ,평균가공일 = CAST(AVG(CASE WHEN O.LAST_WR IS NOT NULL
                                THEN CAST(DATEDIFF(DAY,CONVERT(DATE,O.ORD_DT),CONVERT(DATE,O.LAST_WR)) AS DECIMAL(9,2))
                                END) AS DECIMAL(9,1))
    ,판정 = CASE
         WHEN SUM(CASE WHEN O.INWH_QT > 0 AND ISNULL(C.CLS_AM,0) = 0 THEN 1 ELSE 0 END) > 0
              THEN N'1.★외주마감 미처리 존재 - 원가 누락'
         WHEN SUM(CASE WHEN O.COMP_DT IS NOT NULL
                        AND DATEDIFF(DAY,CONVERT(DATE,O.COMP_DT),CONVERT(DATE,@BASE_DT)) > 0
                        AND O.ORD_QT - O.GOOD_QT > 0 THEN 1 ELSE 0 END) > 0
              THEN N'2.★납기 경과 건 존재'
         WHEN SUM(O.GOOD_QT)/NULLIF(SUM(O.GOOD_QT)+SUM(O.BAD_QT), 0) * 100 < 95
              THEN N'3.★외주 품질 부진 (양품률 95% 미만)'
         ELSE N'0.정상' END
FROM       #OW    O
LEFT  JOIN #CLS   C ON C.WO_CD = O.WO_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD = O.TR_CD
GROUP BY O.TR_CD, T.TR_NM
ORDER BY 판정, 외주비계 DESC
;


/*==============================================================================================
  ** 쿼리 C : 외주마감 미처리  ★ 원가 누락 — 마감 전 반드시 처리
==============================================================================================*/
SELECT
     N'[C] 외주마감 미처리'                         AS REPORT_NM
    ,긴급도 = CASE
         WHEN O.LAST_IN IS NOT NULL
          AND DATEDIFF(DAY,CONVERT(DATE,O.LAST_IN),CONVERT(DATE,@BASE_DT)) > 30 THEN N'1.★30일 경과'
         WHEN O.LAST_IN IS NOT NULL
          AND DATEDIFF(DAY,CONVERT(DATE,O.LAST_IN),CONVERT(DATE,@BASE_DT)) > 7  THEN N'2.7일 경과'
         ELSE N'3.최근 입고' END
    ,O.WO_CD                                        AS 지시번호
    ,O.ORD_DT                                       AS 지시일
    ,O.TR_CD                                        AS 외주처코드
    ,T.TR_NM                                        AS 외주처명
    ,O.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,O.ORD_QT                                       AS 지시수량
    ,O.GOOD_QT                                      AS 가공완료
    ,O.INWH_QT                                      AS 입고수량
    ,ISNULL(C.CLS_QT, 0)                            AS 마감수량
    ,미마감수량 = O.INWH_QT - ISNULL(C.CLS_QT, 0)
    ,ISNULL(C.CLS_AM, 0)                            AS 마감금액
    ,O.LAST_IN                                      AS 최종입고일
    ,입고후경과일 = CASE WHEN O.LAST_IN IS NOT NULL
                         THEN DATEDIFF(DAY, CONVERT(DATE,O.LAST_IN), CONVERT(DATE,@BASE_DT)) END
    ,생산상태 = CASE ISNULL(O.EXPIRE_YN, N'1') WHEN N'1' THEN N'진행' ELSE N'★마감' END
    ,영향 = CASE
         WHEN ISNULL(O.EXPIRE_YN, N'1') = N'0'
              THEN N'★ 생산 마감인데 외주비 미확정 - 원가계산 시 외주비가 0 으로 들어간다'
         ELSE N'외주마감 처리 후 원가계산할 것' END
FROM       #OW    O
LEFT  JOIN #CLS   C ON C.WO_CD = O.WO_CD
LEFT  JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = O.ITEM_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = O.TR_CD
WHERE  O.INWH_QT > ISNULL(C.CLS_QT, 0)
ORDER BY 긴급도, O.INWH_QT DESC
;


/*==============================================================================================
  ** 쿼리 D : 사급 자재 현황  ★ 외주처에 나가 있는 우리 재고
     ─ 무상사급은 소유권이 우리에게 있다. 회수되지 않으면 재고 손실이다.
==============================================================================================*/
SELECT
     N'[D] 사급 자재 현황'                          AS REPORT_NM
    ,O.WO_CD                                        AS 지시번호
    ,O.ORD_DT                                       AS 지시일
    ,O.TR_CD                                        AS 외주처코드
    ,T.TR_NM                                        AS 외주처명
    ,O.ITEM_CD                                      AS 외주품번
    ,PI.ITEM_NM                                     AS 외주품명
    ,Q.ITEM_CD                                      AS 사급자재품번
    ,MI.ITEM_NM                                     AS 사급자재품명
    ,MI.UNIT_CD                                     AS 단위
    ,사급구분 = CASE ISNULL(Q.ODR_FG, N'') WHEN N'0' THEN N'재고(무상사급)'
                                           WHEN N'1' THEN N'사급(유상)'
                                           ELSE N'미지정' END
    ,Q.REQ_QT                                       AS 청구수량
    ,Q.ISU_QT                                       AS 출고수량
    ,미출고 = CAST(ISNULL(Q.REQ_QT,0) - ISNULL(Q.ISU_QT,0) AS DECIMAL(19,6))
    ,O.GOOD_QT                                      AS 외주_가공완료
    ,O.INWH_QT                                      AS 외주_입고
    ,잔여사급 = CASE WHEN O.ORD_QT > 0
                     THEN CAST(ISNULL(Q.ISU_QT,0) * (1 - O.GOOD_QT / O.ORD_QT) AS DECIMAL(19,6)) END
    ,판정 = CASE
         WHEN ISNULL(Q.REQ_QT,0) > ISNULL(Q.ISU_QT,0) AND O.GOOD_QT = 0
              THEN N'1.★자재 미출고 - 외주 착수 불가'
         WHEN O.GOOD_QT = 0 AND ISNULL(Q.ISU_QT,0) > 0
          AND DATEDIFF(DAY, CONVERT(DATE,O.ORD_DT), CONVERT(DATE,@BASE_DT)) > 30
              THEN N'2.★자재 나간 지 30일 경과했는데 실적 없음 - 회수 확인'
         WHEN ISNULL(O.EXPIRE_YN,N'1') = N'0' AND O.ORD_QT > O.GOOD_QT
              THEN N'3.★지시 마감인데 미완료 - 잔여 사급자재 회수 필요'
         ELSE N'0.정상' END
FROM       #OW        O
INNER JOIN LWO_REQ_WF Q WITH (NOLOCK) ON Q.CO_CD = @CO_CD AND Q.WO_CD = O.WO_CD
                                     AND ISNULL(Q.USE_YN, N'1') = N'1'
LEFT  JOIN SITEM     PI WITH (NOLOCK) ON PI.CO_CD = @CO_CD AND PI.ITEM_CD = O.ITEM_CD
LEFT  JOIN SITEM     MI WITH (NOLOCK) ON MI.CO_CD = @CO_CD AND MI.ITEM_CD = Q.ITEM_CD
LEFT  JOIN STRADE     T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = O.TR_CD
ORDER BY 판정, O.ORD_DT
;


/*==============================================================================================
  ** 쿼리 E : 품목별 외주비 단가 비교  (같은 품목을 어디에 맡기는 게 싼가)
==============================================================================================*/
;WITH X AS (
    SELECT
         O.ITEM_CD, O.TR_CD
        ,QT = SUM(ISNULL(C.CLS_QT, 0))
        ,AM = SUM(ISNULL(C.CLS_AM, 0))
        ,CNT = COUNT(*)
    FROM       #OW  O
    INNER JOIN #CLS C ON C.WO_CD = O.WO_CD
    WHERE  ISNULL(C.CLS_AM, 0) > 0
    GROUP BY O.ITEM_CD, O.TR_CD
    HAVING SUM(ISNULL(C.CLS_QT, 0)) > 0
)
SELECT
     N'[E] 외주비 단가 비교'                        AS REPORT_NM
    ,X.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.UNIT_CD                                      AS 단위
    ,X.TR_CD                                        AS 외주처코드
    ,T.TR_NM                                        AS 외주처명
    ,X.QT                                           AS 마감수량
    ,X.AM                                           AS 외주비
    ,X.CNT                                          AS 마감건수
    ,단위외주비 = CAST(X.AM / NULLIF(X.QT, 0) AS DECIMAL(19,4))
    ,최저단가 = MIN(CAST(X.AM / NULLIF(X.QT,0) AS DECIMAL(19,4))) OVER (PARTITION BY X.ITEM_CD)
    ,외주처수 = COUNT(*) OVER (PARTITION BY X.ITEM_CD)
    ,최저대비_PCT = CAST(CASE WHEN MIN(X.AM/NULLIF(X.QT,0)) OVER (PARTITION BY X.ITEM_CD) <> 0
                              THEN ((X.AM/NULLIF(X.QT,0))
                                    / MIN(X.AM/NULLIF(X.QT,0)) OVER (PARTITION BY X.ITEM_CD) - 1) * 100
                              END AS DECIMAL(9,1))
    ,절감가능액 = CAST(((X.AM/NULLIF(X.QT,0))
                        - MIN(X.AM/NULLIF(X.QT,0)) OVER (PARTITION BY X.ITEM_CD)) * X.QT
                       AS DECIMAL(19,4))
    ,판정 = CASE
         WHEN COUNT(*) OVER (PARTITION BY X.ITEM_CD) = 1              THEN N'9.단독 외주 (비교 불가)'
         WHEN (X.AM/NULLIF(X.QT,0))
              = MIN(X.AM/NULLIF(X.QT,0)) OVER (PARTITION BY X.ITEM_CD) THEN N'0.최저가'
         ELSE N'1.★단가 협상 대상' END
FROM       X
LEFT  JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = X.ITEM_CD
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD   = X.TR_CD
ORDER BY 절감가능액 DESC, X.ITEM_CD
;


/*==============================================================================================
  ** 쿼리 F : 요약 + 데이터 점검
==============================================================================================*/
SELECT
     N'[F] 외주 요약'                               AS REPORT_NM
    ,@FR_DT + N' ~ ' + @TO_DT                       AS 기간
    ,LOCLS_존재 = CASE WHEN @HAS_OCLS = 1 THEN N'O' ELSE N'★X' END
    ,외주지시건수 = COUNT(*)
    ,외주처수 = COUNT(DISTINCT NULLIF(O.TR_CD, N''))
    ,품목수   = COUNT(DISTINCT O.ITEM_CD)
    ,지시수량계 = SUM(O.ORD_QT)
    ,가공완료계 = SUM(O.GOOD_QT)
    ,입고수량계 = SUM(O.INWH_QT)
    ,외주비계   = SUM(ISNULL(C.CLS_AM, 0))
    ,전체진척률_PCT = CAST(SUM(O.GOOD_QT) / NULLIF(SUM(O.ORD_QT), 0) * 100 AS DECIMAL(5,1))
    ,마감처리건수 = SUM(CASE WHEN ISNULL(C.CLS_AM, 0) > 0 THEN 1 ELSE 0 END)
    ,마감미처리건수 = SUM(CASE WHEN O.INWH_QT > ISNULL(C.CLS_QT, 0) THEN 1 ELSE 0 END)
    ,마감처리율_PCT = CAST(SUM(CASE WHEN ISNULL(C.CLS_AM,0) > 0 THEN 1.0 ELSE 0 END)
                           / NULLIF(SUM(CASE WHEN O.INWH_QT > 0 THEN 1.0 ELSE 0 END), 0)
                           * 100 AS DECIMAL(5,1))
    ,사급미출고건수 = SUM(CASE WHEN O.MTL_REQ > O.MTL_ISU THEN 1 ELSE 0 END)
    ,납기경과건수 = SUM(CASE WHEN O.COMP_DT IS NOT NULL
                              AND DATEDIFF(DAY,CONVERT(DATE,O.COMP_DT),CONVERT(DATE,@BASE_DT)) > 0
                              AND O.ORD_QT - O.GOOD_QT > 0 THEN 1 ELSE 0 END)
    ,판정 = CASE
         WHEN COUNT(*) = 0
              THEN N'1.★외주 지시 없음 - @DOC_FG 값 확인 (아래 확인 쿼리)'
         WHEN @HAS_OCLS = 0
              THEN N'2.★LOCLS 없음 또는 금액 컬럼 미확인 - 외주비 확정액을 알 수 없다'
         WHEN SUM(CASE WHEN O.INWH_QT > ISNULL(C.CLS_QT, 0) THEN 1 ELSE 0 END) > 0
              THEN N'3.★외주마감 미처리 존재 - 원가 마감 전 처리 필요 (C-07)'
         ELSE N'0.정상' END
FROM       #OW  O
LEFT  JOIN #CLS C ON C.WO_CD = O.WO_CD
;


DROP TABLE #OW, #CLS;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 외주 구분 코드  ★ @DOC_FG 의 근거. 이게 틀리면 결과가 비어버린다
     SELECT DOC_FG, WOC_FG, COUNT(*) FROM LWO_WF WHERE CO_CD='1000' GROUP BY DOC_FG, WOC_FG;
     --> 표준은 DOC_FG='1'(외주), WOC_FG='4'(외주발주). 실제 분포를 보고 @DOC_FG 를 맞출 것.
        외주처(TR_CD)가 채워진 지시가 어느 조합인지 확인하는 것이 가장 확실하다.

  -- (2) 외주마감 테이블/컬럼  ★ 외주비의 원천
     SELECT name FROM sys.tables WHERE name LIKE 'LOCLS%';
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('LOCLS_D') ORDER BY column_id;
     --> 금액 후보 : LBR_AM, CLS_AM, CLSG_AM, CLSH_AM, OUT_AM
        수량 후보 : CLS_QT, ITEM_QT, OUT_QT, QT
        없으면 2번 블록의 IN (...) 에 추가할 것.

  -- (3) 사급 구분  ★ 무상/유상을 섞으면 재고와 원가가 모두 틀어진다
     SELECT ODR_FG, COUNT(*) FROM LWO_REQ_WF WHERE CO_CD='1000' GROUP BY ODR_FG;
     --> 0=재고(무상사급), 1=사급(유상). 유상사급 비중이 크면 매출·매입도 함께 봐야 한다.

  -- (4) 외주비가 원가에 반영되는지
     SELECT SUM(LBR_AM) FROM CIV_PRD_TAV WHERE CO_CD='1000' AND P_YR='2026';
     --> 외주마감 금액 합계와 대략 맞아야 한다. 0 이면 원가계산이 외주비를 못 잡고 있다.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **외주 구분 판정이 사이트 의존적이다.** `DOC_FG='1' OR WOC_FG='4'` 로 넓게 잡았으므로
     일반 생산지시가 섞일 수 있다. 확인 (1)번으로 실제 코드 체계를 보고 조건을 좁힐 것.

  2) **사급 자재 잔여(쿼리 D)는 비례 추정**이다. 진척률만큼 소비됐다고 보고 계산하므로
     실제 외주처 보유량과 다르다. 정확한 잔여는 외주처 재고 실사로만 알 수 있다.

  3) **유상사급은 매출·매입이 동시에 발생**한다. 이 리포트는 생산 관점만 보므로,
     유상사급 비중이 크면 `S05_판매분석_다축.sql`(매출)과 `P07_매입단가_추이분석.sql`(매입)을
     함께 봐야 전체 그림이 나온다.

  4) 외주 불량(`BAD_YN='1'`)의 책임 소재(외주처 귀책 / 사급자재 귀책)를 구분하지 않는다.
     구분이 필요하면 불량 코드(`M06`)를 함께 볼 것.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   C07_원가차수_마감점검.sql  : 외주마감 미처리는 원가 마감의 차단 항목
   C03_제품별_원가구성.sql    : 외주비(LBR_AM)가 원가에 반영된 결과
   M01_작업지시_진행현황.sql  : 자사 생산 지시
   M06_불량파레토_품질KPI.sql : 외주 불량 원인
==============================================================================================*/
