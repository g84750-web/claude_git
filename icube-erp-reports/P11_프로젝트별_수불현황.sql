/*==============================================================================================
  [ iCUBE ] P-11  프로젝트별 수불 현황                                               (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 프로젝트에 무엇이 얼마나 들어가고 나갔는가. **프로젝트 단위로 재고를 묶어 보는**
         유일한 물류 리포트다 (원가모듈에는 프로젝트 축이 없다).

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 소스 — VL_PJT 뷰 우선 ]
  ----------------------------------------------------------------------------------------------
     `VL_PJT` 가 있으면 그것을 쓴다 (iCUBE 제공 집계, 빠르고 정합성 보장).
     없으면 `LINVTORY.PJT_CD` 를 직접 집계한다. 어느 쪽을 썼는지 `소스` 컬럼에 표시된다.

  ----------------------------------------------------------------------------------------------
  [ ★ 프로젝트 원가와의 관계 ]
  ----------------------------------------------------------------------------------------------
     원가모듈(`CIV_*`)에는 **프로젝트 축이 없다.** 따라서 프로젝트 원가는
       ① 이 리포트 — 프로젝트에 투입된 **물량과 금액**(물류 관점)
       ② `PJT_생산원가_보고서.sql` — 지시·BOM 기반 **제조원가**(생산 관점)
       ③ `A06_프로젝트별손익_회계.sql` — 전표 기반 **회계 손익**(회계 관점)
     세 가지를 각각 보고 대사해야 한다. 하나로 통합된 숫자는 ERP 에 존재하지 않는다.
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
    ,@BASE_DT  NVARCHAR(8)  = N'20260916'
    ,@PJT_CD   NVARCHAR(10) = NULL
    ,@ITEM_CD  NVARCHAR(25) = NULL
;

DECLARE @SQL NVARCHAR(MAX);
DECLARE @SRC NVARCHAR(20) = N'LINVTORY';

IF OBJECT_ID('tempdb..#PJ') IS NOT NULL DROP TABLE #PJ;
IF OBJECT_ID('tempdb..#UM') IS NOT NULL DROP TABLE #UM;

CREATE TABLE #PJ (
     PJT_CD   NVARCHAR(10)
    ,ITEM_CD  NVARCHAR(25)
    ,OPEN_QT  DECIMAL(19,6)
    ,RCV_QT   DECIMAL(19,6)
    ,ISU_QT   DECIMAL(19,6)
    ,PISU_QT  DECIMAL(19,6)   -- 생산출고 (자재 투입)
    ,SISU_QT  DECIMAL(19,6)   -- 매출출고 (납품)
    ,INV_QT   DECIMAL(19,6)
    ,FIRST_DT NVARCHAR(8)
    ,LAST_DT  NVARCHAR(8)
    ,IO_CNT   INT
);


/*==============================================================================================
  1. #PJ : 프로젝트별 수불 적재 (VL_PJT 우선)
==============================================================================================*/
IF OBJECT_ID(N'dbo.VL_PJT') IS NOT NULL
BEGIN
    SET @SQL = N'
        INSERT INTO #PJ (PJT_CD, ITEM_CD, OPEN_QT, RCV_QT, ISU_QT, PISU_QT, SISU_QT, INV_QT, IO_CNT)
        SELECT V.PJT_CD, V.ITEM_CD
              ,SUM(CAST(ISNULL(V.IOPEN,0) AS DECIMAL(19,6)))
              ,SUM(CAST(ISNULL(V.IRCV ,0) AS DECIMAL(19,6)))
              ,SUM(CAST(ISNULL(V.IISU ,0) AS DECIMAL(19,6)))
              ,0, 0
              ,SUM(CAST(ISNULL(V.IOPEN,0)+ISNULL(V.IRCV,0)-ISNULL(V.IISU,0) AS DECIMAL(19,6)))
              ,COUNT(*)
        FROM   dbo.VL_PJT V
        WHERE  V.CO_CD = @p_CO AND V.P_YR = @p_YR
          AND  (@p_DIV  IS NULL OR V.DIV_CD  = @p_DIV)
          AND  (@p_PJT  IS NULL OR V.PJT_CD  = @p_PJT)
          AND  (@p_ITEM IS NULL OR V.ITEM_CD = @p_ITEM)
        GROUP BY V.PJT_CD, V.ITEM_CD';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YR NVARCHAR(4)
              ,@p_PJT NVARCHAR(10), @p_ITEM NVARCHAR(25)'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_YR=@P_YR, @p_PJT=@PJT_CD, @p_ITEM=@ITEM_CD;
        SET @SRC = N'VL_PJT';
        PRINT N'[1] VL_PJT : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 행';
    END TRY
    BEGIN CATCH PRINT N'[1] VL_PJT 조회 실패 - 원장으로 전환 : ' + ERROR_MESSAGE(); END CATCH
END

IF (SELECT COUNT(*) FROM #PJ) = 0
BEGIN
    INSERT INTO #PJ (PJT_CD, ITEM_CD, OPEN_QT, RCV_QT, ISU_QT, PISU_QT, SISU_QT, INV_QT,
                     FIRST_DT, LAST_DT, IO_CNT)
    SELECT
         V.PJT_CD
        ,V.ITEM_CD
        ,SUM(CAST(ISNULL(V.IOPEN_QT,0) AS DECIMAL(19,6)))
        ,SUM(CAST(ISNULL(V.IRCV_QT ,0) AS DECIMAL(19,6)))
        ,SUM(CAST(ISNULL(V.IISU_QT ,0) AS DECIMAL(19,6)))
        ,SUM(CASE WHEN V.GRP_FG=N'0' AND V.IO_FG=N'2'
                  THEN CAST(ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
        ,SUM(CASE WHEN V.GRP_FG=N'3' AND V.IO_FG=N'2'
                  THEN CAST(ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)) ELSE 0 END)
        ,SUM(CAST(ISNULL(V.IOPEN_QT,0)+ISNULL(V.IRCV_QT,0)-ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)))
        ,MIN(V.IO_DT)
        ,MAX(V.IO_DT)
        ,COUNT(*)
    FROM   LINVTORY V WITH (NOLOCK)
    WHERE  V.CO_CD = @CO_CD AND V.P_YR = @P_YR AND V.IO_DT <= @BASE_DT
      AND  ISNULL(V.PJT_CD, N'') <> N''
      AND  ISNULL(V.USE_YN, N'1') = N'1' AND ISNULL(V.EXPIRE_YN, N'1') = N'1'
      AND  (@DIV_CD  IS NULL OR V.DIV_CD  = @DIV_CD)
      AND  (@PJT_CD  IS NULL OR V.PJT_CD  = @PJT_CD)
      AND  (@ITEM_CD IS NULL OR V.ITEM_CD = @ITEM_CD)
    GROUP BY V.PJT_CD, V.ITEM_CD;
    PRINT N'[1] LINVTORY.PJT_CD : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 행';
END

CREATE CLUSTERED INDEX IX_PJ ON #PJ (PJT_CD, ITEM_CD);

-- 단가 (금액 환산)
SELECT I.ITEM_CD, UM = CAST(ISNULL(NULLIF(I.STD_UM,0), I.PUR_UM) AS DECIMAL(19,6))
INTO #UM FROM SITEM I WITH (NOLOCK) WHERE I.CO_CD = @CO_CD;
CREATE CLUSTERED INDEX IX_UM ON #UM (ITEM_CD);


/*==============================================================================================
  ** 쿼리 A : 프로젝트별 요약
==============================================================================================*/
SELECT
     N'[A] 프로젝트별 수불 요약'                    AS REPORT_NM
    ,소스 = @SRC
    ,P.PJT_CD                                       AS 프로젝트코드
    ,J.PJT_NM                                       AS 프로젝트명
    ,품목수 = COUNT(*)
    ,기초수량 = SUM(P.OPEN_QT)
    ,입고수량 = SUM(P.RCV_QT)
    ,출고수량 = SUM(P.ISU_QT)
    ,생산출고 = SUM(P.PISU_QT)
    ,매출출고 = SUM(P.SISU_QT)
    ,잔여수량 = SUM(P.INV_QT)
    ,입고금액 = CAST(SUM(P.RCV_QT * ISNULL(U.UM, 0)) AS DECIMAL(19,4))
    ,출고금액 = CAST(SUM(P.ISU_QT * ISNULL(U.UM, 0)) AS DECIMAL(19,4))
    ,잔여금액 = CAST(SUM(P.INV_QT * ISNULL(U.UM, 0)) AS DECIMAL(19,4))
    ,최초수불일 = MIN(P.FIRST_DT)
    ,최종수불일 = MAX(P.LAST_DT)
    ,경과일 = CASE WHEN MIN(P.FIRST_DT) IS NOT NULL
                   THEN DATEDIFF(DAY, CONVERT(DATE,MIN(P.FIRST_DT)), CONVERT(DATE,@BASE_DT)) END
    ,무이동일수 = CASE WHEN MAX(P.LAST_DT) IS NOT NULL
                       THEN DATEDIFF(DAY, CONVERT(DATE,MAX(P.LAST_DT)), CONVERT(DATE,@BASE_DT)) END
    ,판정 = CASE
         WHEN SUM(P.INV_QT) = 0                                              THEN N'0.정리 완료'
         WHEN MAX(P.LAST_DT) IS NOT NULL
          AND DATEDIFF(DAY, CONVERT(DATE,MAX(P.LAST_DT)), CONVERT(DATE,@BASE_DT)) > 180
              THEN N'1.★180일 무이동 - 프로젝트 종료 후 잔여재고 정리 필요'
         WHEN SUM(P.INV_QT) < 0                                              THEN N'2.★마이너스 잔여'
         ELSE N'3.진행 중' END
FROM       #PJ  P
LEFT  JOIN #UM  U ON U.ITEM_CD = P.ITEM_CD
LEFT  JOIN SPJT J WITH (NOLOCK) ON J.CO_CD = @CO_CD AND J.PJT_CD = P.PJT_CD
GROUP BY P.PJT_CD, J.PJT_NM
ORDER BY 판정, 잔여금액 DESC
;


/*==============================================================================================
  ** 쿼리 B : 프로젝트 × 품목 상세
==============================================================================================*/
SELECT
     N'[B] 프로젝트 × 품목'                         AS REPORT_NM
    ,P.PJT_CD                                       AS 프로젝트코드
    ,J.PJT_NM                                       AS 프로젝트명
    ,P.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
    ,P.OPEN_QT                                      AS 기초
    ,P.RCV_QT                                       AS 입고
    ,P.ISU_QT                                       AS 출고
    ,P.PISU_QT                                      AS 생산출고
    ,P.SISU_QT                                      AS 매출출고
    ,P.INV_QT                                       AS 잔여
    ,U.UM                                           AS 단가
    ,입고금액 = CAST(P.RCV_QT * ISNULL(U.UM, 0) AS DECIMAL(19,4))
    ,출고금액 = CAST(P.ISU_QT * ISNULL(U.UM, 0) AS DECIMAL(19,4))
    ,잔여금액 = CAST(P.INV_QT * ISNULL(U.UM, 0) AS DECIMAL(19,4))
    ,P.IO_CNT                                       AS 수불건수
    ,P.FIRST_DT                                     AS 최초수불일
    ,P.LAST_DT                                      AS 최종수불일
    ,판정 = CASE WHEN P.INV_QT < 0 THEN N'1.★마이너스'
                 WHEN P.INV_QT = 0 THEN N'0.소진'
                 ELSE N'2.잔여 있음' END
FROM       #PJ   P
LEFT  JOIN #UM   U ON U.ITEM_CD = P.ITEM_CD
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = P.ITEM_CD
LEFT  JOIN SPJT  J WITH (NOLOCK) ON J.CO_CD = @CO_CD AND J.PJT_CD  = P.PJT_CD
ORDER BY P.PJT_CD, 잔여금액 DESC
;


/*==============================================================================================
  ** 쿼리 C : 프로젝트 투입 대비 산출  (자재 투입 vs 제품 납품)
==============================================================================================*/
SELECT
     N'[C] 투입 대비 산출'                          AS REPORT_NM
    ,P.PJT_CD                                       AS 프로젝트코드
    ,J.PJT_NM                                       AS 프로젝트명
    -- 투입 (원부재료)
    ,투입품목수 = COUNT(DISTINCT CASE WHEN I.ACCT_FG IN (N'0',N'1') THEN P.ITEM_CD END)
    ,투입수량   = SUM(CASE WHEN I.ACCT_FG IN (N'0',N'1') THEN P.PISU_QT ELSE 0 END)
    ,투입금액   = CAST(SUM(CASE WHEN I.ACCT_FG IN (N'0',N'1')
                                THEN P.PISU_QT * ISNULL(U.UM,0) ELSE 0 END) AS DECIMAL(19,4))
    -- 산출 (제품·반제품)
    ,산출품목수 = COUNT(DISTINCT CASE WHEN I.ACCT_FG IN (N'2',N'4') THEN P.ITEM_CD END)
    ,생산입고   = SUM(CASE WHEN I.ACCT_FG IN (N'2',N'4') THEN P.RCV_QT ELSE 0 END)
    ,납품수량   = SUM(CASE WHEN I.ACCT_FG IN (N'2',N'4') THEN P.SISU_QT ELSE 0 END)
    ,납품금액   = CAST(SUM(CASE WHEN I.ACCT_FG IN (N'2',N'4')
                                THEN P.SISU_QT * ISNULL(U.UM,0) ELSE 0 END) AS DECIMAL(19,4))
    -- 잔여
    ,자재잔여금액 = CAST(SUM(CASE WHEN I.ACCT_FG IN (N'0',N'1')
                                  THEN P.INV_QT * ISNULL(U.UM,0) ELSE 0 END) AS DECIMAL(19,4))
    ,제품잔여금액 = CAST(SUM(CASE WHEN I.ACCT_FG IN (N'2',N'4')
                                  THEN P.INV_QT * ISNULL(U.UM,0) ELSE 0 END) AS DECIMAL(19,4))
    ,납품률_PCT = CAST(SUM(CASE WHEN I.ACCT_FG IN (N'2',N'4') THEN P.SISU_QT ELSE 0 END)
                       / NULLIF(SUM(CASE WHEN I.ACCT_FG IN (N'2',N'4') THEN P.RCV_QT ELSE 0 END), 0)
                       * 100 AS DECIMAL(5,1))
    ,판정 = CASE
         WHEN SUM(CASE WHEN I.ACCT_FG IN (N'2',N'4') THEN P.RCV_QT ELSE 0 END) = 0
              THEN N'1.생산 산출 없음 (자재만 투입)'
         WHEN SUM(CASE WHEN I.ACCT_FG IN (N'2',N'4') THEN P.SISU_QT ELSE 0 END)
              >= SUM(CASE WHEN I.ACCT_FG IN (N'2',N'4') THEN P.RCV_QT ELSE 0 END)
              THEN N'0.납품 완료'
         WHEN SUM(CASE WHEN I.ACCT_FG IN (N'0',N'1') THEN P.INV_QT * ISNULL(U.UM,0) ELSE 0 END) > 0
              THEN N'2.★자재 잔여 있음 - 프로젝트 종료 시 정리 필요'
         ELSE N'3.진행 중' END
FROM       #PJ   P
LEFT  JOIN #UM   U ON U.ITEM_CD = P.ITEM_CD
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = P.ITEM_CD
LEFT  JOIN SPJT  J WITH (NOLOCK) ON J.CO_CD = @CO_CD AND J.PJT_CD  = P.PJT_CD
GROUP BY P.PJT_CD, J.PJT_NM
ORDER BY 판정, 자재잔여금액 DESC
;


/*==============================================================================================
  ** 쿼리 D : 프로젝트 미지정 수불  ★ 프로젝트 관리의 사각지대
     ─ 프로젝트를 운영하는데 PJT_CD 가 비어 있는 수불이 많으면 집계가 반쪽이 된다.
==============================================================================================*/
SELECT
     N'[D] 프로젝트 미지정 수불'                    AS REPORT_NM
    ,수불유형 = CASE
         WHEN V.GRP_FG = N'2' AND V.IO_FG = N'1' THEN N'구매입고'
         WHEN V.GRP_FG = N'0' AND V.IO_FG = N'1' THEN N'생산입고'
         WHEN V.GRP_FG = N'0' AND V.IO_FG = N'2' THEN N'생산출고'
         WHEN V.GRP_FG = N'3' AND V.IO_FG = N'2' THEN N'매출출고'
         WHEN V.GRP_FG = N'5'                    THEN N'재고이동'
         WHEN V.GRP_FG = N'6'                    THEN N'조정·이월'
         ELSE N'기타' END
    ,전체건수 = COUNT(*)
    ,프로젝트지정 = SUM(CASE WHEN ISNULL(V.PJT_CD, N'') <> N'' THEN 1 ELSE 0 END)
    ,프로젝트미지정 = SUM(CASE WHEN ISNULL(V.PJT_CD, N'') = N'' THEN 1 ELSE 0 END)
    ,지정률_PCT = CAST(SUM(CASE WHEN ISNULL(V.PJT_CD,N'')<>N'' THEN 1.0 ELSE 0 END)
                       / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
    ,미지정수량 = SUM(CASE WHEN ISNULL(V.PJT_CD, N'') = N''
                           THEN CAST(ISNULL(V.IRCV_QT,0)+ISNULL(V.IISU_QT,0) AS DECIMAL(19,6))
                           ELSE 0 END)
    ,판정 = CASE
         WHEN SUM(CASE WHEN ISNULL(V.PJT_CD,N'')<>N'' THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0) < 0.3
              THEN N'★ 지정률 30% 미만 - 프로젝트 집계가 전체를 대표하지 못한다'
         WHEN SUM(CASE WHEN ISNULL(V.PJT_CD,N'')<>N'' THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0) < 0.7
              THEN N'지정률 70% 미만 - 누락분 확인 필요'
         ELSE N'양호' END
FROM   LINVTORY V WITH (NOLOCK)
WHERE  V.CO_CD = @CO_CD AND V.P_YR = @P_YR AND V.IO_DT <= @BASE_DT
  AND  ISNULL(V.USE_YN, N'1') = N'1' AND ISNULL(V.EXPIRE_YN, N'1') = N'1'
  AND  (@DIV_CD IS NULL OR V.DIV_CD = @DIV_CD)
GROUP BY CASE
         WHEN V.GRP_FG = N'2' AND V.IO_FG = N'1' THEN N'구매입고'
         WHEN V.GRP_FG = N'0' AND V.IO_FG = N'1' THEN N'생산입고'
         WHEN V.GRP_FG = N'0' AND V.IO_FG = N'2' THEN N'생산출고'
         WHEN V.GRP_FG = N'3' AND V.IO_FG = N'2' THEN N'매출출고'
         WHEN V.GRP_FG = N'5'                    THEN N'재고이동'
         WHEN V.GRP_FG = N'6'                    THEN N'조정·이월'
         ELSE N'기타' END
ORDER BY 전체건수 DESC
;


/*==============================================================================================
  ** 쿼리 E : 전사 요약 + 데이터 점검
==============================================================================================*/
SELECT
     N'[E] 프로젝트 수불 요약'                      AS REPORT_NM
    ,소스 = @SRC
    ,VL_PJT_존재 = CASE WHEN OBJECT_ID(N'dbo.VL_PJT') IS NOT NULL THEN N'O' ELSE N'X' END
    ,프로젝트수 = COUNT(DISTINCT P.PJT_CD)
    ,품목조합수 = COUNT(*)
    ,입고수량계 = SUM(P.RCV_QT)
    ,출고수량계 = SUM(P.ISU_QT)
    ,잔여수량계 = SUM(P.INV_QT)
    ,잔여금액계 = CAST(SUM(P.INV_QT * ISNULL(U.UM, 0)) AS DECIMAL(19,4))
    ,마이너스조합수 = SUM(CASE WHEN P.INV_QT < 0 THEN 1 ELSE 0 END)
    ,장기무이동_프로젝트수 = COUNT(DISTINCT CASE
         WHEN P.LAST_DT IS NOT NULL AND P.INV_QT <> 0
          AND DATEDIFF(DAY, CONVERT(DATE,P.LAST_DT), CONVERT(DATE,@BASE_DT)) > 180
         THEN P.PJT_CD END)
    ,판정 = CASE
         WHEN COUNT(*) = 0
              THEN N'1.★프로젝트 수불 없음 - PJT_CD 미사용 사이트'
         WHEN @SRC = N'LINVTORY'
              THEN N'2.VL_PJT 없음 - 원장 직접 집계 사용 중 (정상, 다소 느림)'
         ELSE N'0.정상' END
FROM       #PJ P
LEFT  JOIN #UM U ON U.ITEM_CD = P.ITEM_CD
;


DROP TABLE #PJ, #UM;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) VL_PJT 뷰 실존 / 컬럼
     SELECT name, type_desc FROM sys.objects WHERE name = 'VL_PJT';
     SELECT name FROM sys.columns WHERE object_id = OBJECT_ID('VL_PJT') ORDER BY column_id;
     --> 본 쿼리는 IOPEN/IRCV/IISU 컬럼을 전제한다 (VL_INVLC 계열과 동일 구조).
        다르면 1번 블록을 수정하거나 @SRC 를 원장으로 고정할 것.

  -- (2) PJT_CD 지정률  ★ 쿼리 D 와 같은 목적. 이 리포트의 대표성을 좌우
     SELECT COUNT(*) 전체, SUM(CASE WHEN ISNULL(PJT_CD,'')='' THEN 1 ELSE 0 END) 미지정
     FROM   LINVTORY WHERE CO_CD='1000' AND P_YR='2026';
     --> 미지정이 대부분이면 프로젝트 관리를 하지 않는 사이트다.

  -- (3) 프로젝트 마스터
     SELECT name FROM sys.tables WHERE name IN ('SPJT','APJT');
     --> 프로젝트명 조인 테이블이 SPJT 가 아니면 쿼리 A~C 의 조인을 수정할 것.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **금액은 마스터 표준단가 기준 근사치**다. 원가모듈에 프로젝트 축이 없어 평가 단가를
     프로젝트별로 배부할 수 없기 때문이다. 정확한 프로젝트 원가는
     `PJT_생산원가_보고서.sql`(생산 관점) 또는 `A06_프로젝트별손익_회계.sql`(회계 관점)을 볼 것.

  2) **`VL_PJT` 사용 시 생산출고/매출출고 분할이 안 된다.** 뷰에 `GRP_FG` 가 없기 때문이며,
     그 경우 쿼리 A·C 의 `생산출고`/`매출출고` 가 0 으로 나온다. 용도별 분할이 필요하면
     `VL_PJT` 가 있어도 원장(`LINVTORY`)을 쓰도록 1번 블록의 IF 조건을 조정할 것.

  3) `P_YR` 파티션이므로 **연도를 넘어가는 장기 프로젝트는 연도별로 따로 나온다.**
     프로젝트 전체 누계를 보려면 연도별로 실행해 합산해야 한다.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   PJT_생산원가_보고서.sql       : 프로젝트 제조원가 (생산 관점)
   A06_프로젝트별손익_회계.sql   : 프로젝트 손익 (회계 관점)
   P03_실시간재고_추적.sql       : 창고·장소별 재고
==============================================================================================*/
