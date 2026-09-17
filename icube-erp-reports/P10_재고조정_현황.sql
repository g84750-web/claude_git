/*==============================================================================================
  [ iCUBE ] P-10  재고조정 내역 현황                                                 (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 장부를 손으로 고친 기록을 전부 드러낸다. **재고조정은 원인이 아니라 결과**이므로,
         조정이 많다는 것은 어딘가에서 등록이 누락되고 있다는 신호다.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 소스 ]
  ----------------------------------------------------------------------------------------------
     LADJUST / LADJUST_D   재고조정 (대체입고 / 대체출고)
     LCTRL_MGM / _D        관리내역  ★ `CTRL_CD = 'LA'` 가 재고조정 사유 코드
     LINVTORY              `GRP_FG='6'` (조정·해체·이월) 수불로도 나타난다

  ----------------------------------------------------------------------------------------------
  [ 왜 중요한가 ]
  ----------------------------------------------------------------------------------------------
     조정은 **회계 손익에 직접 반영**된다(재고자산 증감 = 비용 증감). 그런데 조정 사유가
     기록되지 않으면 감사 대응이 안 되고, 조정이 반복되는 품목은 실물 관리 자체가
     무너져 있다는 뜻이다. 그래서 이 리포트는 **사유 등록률**을 선행 지표로 본다.
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
    ,@ITEM_CD  NVARCHAR(25) = NULL
    ,@WH_CD    NVARCHAR(10) = NULL
    ,@TH_CNT   INT          = 3               -- 반복 조정 경고 기준 (건)
;

DECLARE @SQL NVARCHAR(MAX);
DECLARE @HAS_ADJ BIT = 0, @HAS_CTRL BIT = 0;
DECLARE @QTCOL NVARCHAR(30), @AMCOL NVARCHAR(30), @IOCOL NVARCHAR(30);

IF OBJECT_ID('tempdb..#ADJ') IS NOT NULL DROP TABLE #ADJ;
IF OBJECT_ID('tempdb..#UM')  IS NOT NULL DROP TABLE #UM;

CREATE TABLE #ADJ (
     ADJ_NB   NVARCHAR(30)
    ,ADJ_SQ   INT
    ,ADJ_DT   NVARCHAR(8)
    ,ITEM_CD  NVARCHAR(25)
    ,WH_CD    NVARCHAR(10)
    ,LC_CD    NVARCHAR(10)
    ,IO_FG    NVARCHAR(1)        -- 1 대체입고 / 2 대체출고
    ,QT       DECIMAL(19,6)
    ,AM       DECIMAL(19,4)
    ,CTRL_CD  NVARCHAR(10)       -- 조정사유 코드
    ,EMP_CD   NVARCHAR(10)
    ,REMARK   NVARCHAR(200)
);


/*==============================================================================================
  1. #ADJ : 재고조정 적재  ─ 컬럼 자동 탐색
==============================================================================================*/
IF OBJECT_ID(N'dbo.LADJUST', N'U') IS NOT NULL AND OBJECT_ID(N'dbo.LADJUST_D', N'U') IS NOT NULL
BEGIN
    SELECT TOP 1 @QTCOL = name FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.LADJUST_D')
      AND name IN (N'ADJ_QT', N'IO_QT', N'ITEM_QT', N'MGMT_QT', N'QT')
    ORDER BY CASE name WHEN N'ADJ_QT' THEN 1 WHEN N'IO_QT' THEN 2 ELSE 3 END;

    SELECT TOP 1 @AMCOL = name FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.LADJUST_D')
      AND name IN (N'ADJ_AM', N'IO_AM', N'ITEM_AM', N'INV_AM', N'AM')
    ORDER BY CASE name WHEN N'ADJ_AM' THEN 1 WHEN N'IO_AM' THEN 2 ELSE 3 END;

    SELECT TOP 1 @IOCOL = name FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.LADJUST_D')
      AND name IN (N'IO_FG', N'ADJ_FG', N'INOUT_FG')
    ORDER BY CASE name WHEN N'IO_FG' THEN 1 WHEN N'ADJ_FG' THEN 2 ELSE 3 END;

    IF @QTCOL IS NOT NULL
    BEGIN
        SET @SQL = N'
            INSERT INTO #ADJ (ADJ_NB, ADJ_SQ, ADJ_DT, ITEM_CD, WH_CD, LC_CD, IO_FG, QT, AM, CTRL_CD, EMP_CD, REMARK)
            SELECT H.ADJ_NB
                  ,CAST(ISNULL(D.ADJ_SQ, 0) AS INT)
                  ,H.ADJ_DT
                  ,D.ITEM_CD
                  ,ISNULL(D.WH_CD, N'''')
                  ,ISNULL(D.LC_CD, N'''')
                  ,' + CASE WHEN @IOCOL IS NOT NULL
                            THEN N'ISNULL(D.' + QUOTENAME(@IOCOL) + N', N'''')'
                            ELSE N'CASE WHEN CAST(ISNULL(D.' + QUOTENAME(@QTCOL) + N',0) AS DECIMAL(19,6)) >= 0
                                        THEN N''1'' ELSE N''2'' END' END + N'
                  ,CAST(ISNULL(D.' + QUOTENAME(@QTCOL) + N', 0) AS DECIMAL(19,6))
                  ,' + CASE WHEN @AMCOL IS NOT NULL
                            THEN N'CAST(ISNULL(D.' + QUOTENAME(@AMCOL) + N', 0) AS DECIMAL(19,4))'
                            ELSE N'0' END + N'
                  ,ISNULL(D.CTRL_CD, ISNULL(H.CTRL_CD, N''''))
                  ,ISNULL(H.EMP_CD, N'''')
                  ,ISNULL(D.REMARKS, ISNULL(H.REMARKS, N''''))
            FROM       dbo.LADJUST   H WITH (NOLOCK)
            INNER JOIN dbo.LADJUST_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.ADJ_NB = H.ADJ_NB
            WHERE  H.CO_CD = @p_CO
              AND  H.ADJ_DT BETWEEN @p_FR AND @p_TO
              AND  ISNULL(D.USE_YN, N''1'') = N''1''
              AND  (@p_DIV  IS NULL OR H.DIV_CD  = @p_DIV)
              AND  (@p_ITEM IS NULL OR D.ITEM_CD = @p_ITEM)
              AND  (@p_WH   IS NULL OR D.WH_CD   = @p_WH)';
        BEGIN TRY
            EXEC sp_executesql @SQL
                ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_FR NVARCHAR(8), @p_TO NVARCHAR(8)
                  ,@p_ITEM NVARCHAR(25), @p_WH NVARCHAR(10)'
                ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_FR=@FR_DT, @p_TO=@TO_DT
                ,@p_ITEM=@ITEM_CD, @p_WH=@WH_CD;
            SET @HAS_ADJ = 1;
            PRINT N'[1] LADJUST (' + @QTCOL + N') : ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' 행';
        END TRY
        BEGIN CATCH PRINT N'[1] ★ LADJUST 조회 실패 : ' + ERROR_MESSAGE(); END CATCH
    END
    ELSE PRINT N'[1] LADJUST_D 에 조정수량 컬럼을 찾지 못함';
END
ELSE PRINT N'[1] LADJUST 없음 - 재고조정 미운영';

CREATE CLUSTERED INDEX IX_ADJ ON #ADJ (ITEM_CD, ADJ_DT);

IF OBJECT_ID(N'dbo.LCTRL_MGM_D', N'U') IS NOT NULL SET @HAS_CTRL = 1;

-- 금액이 없으면 단가를 곱해 근사
SELECT I.ITEM_CD, UM = CAST(ISNULL(NULLIF(I.STD_UM,0), I.PUR_UM) AS DECIMAL(19,6))
INTO #UM
FROM SITEM I WITH (NOLOCK) WHERE I.CO_CD = @CO_CD;
CREATE CLUSTERED INDEX IX_UM ON #UM (ITEM_CD);

IF @AMCOL IS NULL
    UPDATE A SET AM = CAST(A.QT * ISNULL(U.UM, 0) AS DECIMAL(19,4))
    FROM #ADJ A LEFT JOIN #UM U ON U.ITEM_CD = A.ITEM_CD;


/*==============================================================================================
  ** 쿼리 A : 재고조정 요약  ★ 조정이 많다 = 어딘가 등록이 누락되고 있다
==============================================================================================*/
SELECT
     N'[A] 재고조정 요약'                           AS REPORT_NM
    ,@FR_DT + N' ~ ' + @TO_DT                       AS 기간
    ,조정건수 = COUNT(*)
    ,조정문서수 = COUNT(DISTINCT A.ADJ_NB)
    ,품목수 = COUNT(DISTINCT A.ITEM_CD)
    ,창고수 = COUNT(DISTINCT A.WH_CD)
    ,대체입고건수 = SUM(CASE WHEN A.IO_FG = N'1' THEN 1 ELSE 0 END)
    ,대체입고수량 = SUM(CASE WHEN A.IO_FG = N'1' THEN A.QT ELSE 0 END)
    ,대체입고금액 = SUM(CASE WHEN A.IO_FG = N'1' THEN A.AM ELSE 0 END)
    ,대체출고건수 = SUM(CASE WHEN A.IO_FG = N'2' THEN 1 ELSE 0 END)
    ,대체출고수량 = SUM(CASE WHEN A.IO_FG = N'2' THEN A.QT ELSE 0 END)
    ,대체출고금액 = SUM(CASE WHEN A.IO_FG = N'2' THEN A.AM ELSE 0 END)
    ,순조정금액 = SUM(CASE WHEN A.IO_FG = N'1' THEN A.AM ELSE -A.AM END)
    ,사유등록건수 = SUM(CASE WHEN ISNULL(A.CTRL_CD, N'') <> N'' THEN 1 ELSE 0 END)
    ,사유등록률_PCT = CAST(SUM(CASE WHEN ISNULL(A.CTRL_CD,N'')<>N'' THEN 1.0 ELSE 0 END)
                           / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
    ,판정 = CASE
         WHEN @HAS_ADJ = 0
              THEN N'9.★LADJUST 없음 또는 컬럼 미확인'
         WHEN COUNT(*) = 0
              THEN N'0.기간 내 조정 없음 (양호)'
         WHEN SUM(CASE WHEN ISNULL(A.CTRL_CD,N'')<>N'' THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0) < 0.5
              THEN N'1.★조정 사유 등록률 50% 미만 - 감사 대응 불가'
         WHEN ABS(SUM(CASE WHEN A.IO_FG=N'1' THEN A.AM ELSE -A.AM END)) > 0
              THEN N'2.순조정금액 발생 - 손익 영향 확인'
         ELSE N'3.조정 있음 - 원인 추적 필요' END
FROM   #ADJ A
;


/*==============================================================================================
  ** 쿼리 B : 조정 사유별 집계  (LCTRL_MGM, CTRL_CD='LA')
==============================================================================================*/
IF @HAS_CTRL = 1
BEGIN
    SET @SQL = N'
    SELECT
         N''[B] 조정 사유별 집계'' AS REPORT_NM
        ,사유코드 = CASE WHEN ISNULL(A.CTRL_CD, N'''') = N'''' THEN N''(미등록)'' ELSE A.CTRL_CD END
        ,사유명   = M.CTRLD_NM
        ,조정건수 = COUNT(*)
        ,품목수   = COUNT(DISTINCT A.ITEM_CD)
        ,입고수량 = SUM(CASE WHEN A.IO_FG = N''1'' THEN A.QT ELSE 0 END)
        ,출고수량 = SUM(CASE WHEN A.IO_FG = N''2'' THEN A.QT ELSE 0 END)
        ,입고금액 = SUM(CASE WHEN A.IO_FG = N''1'' THEN A.AM ELSE 0 END)
        ,출고금액 = SUM(CASE WHEN A.IO_FG = N''2'' THEN A.AM ELSE 0 END)
        ,순금액   = SUM(CASE WHEN A.IO_FG = N''1'' THEN A.AM ELSE -A.AM END)
        ,건수비중_PCT = CAST(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0) AS DECIMAL(5,1))
        ,금액비중_PCT = CAST(SUM(ABS(A.AM)) * 100.0
                             / NULLIF(SUM(SUM(ABS(A.AM))) OVER (), 0) AS DECIMAL(5,1))
        ,비고 = CASE WHEN ISNULL(A.CTRL_CD, N'''') = N''''
                     THEN N''★ 사유 미등록 - 감사 대응 불가. 등록 운영 필요''
                     ELSE N''-'' END
    FROM       #ADJ A
    LEFT  JOIN dbo.LCTRL_MGM_D M WITH (NOLOCK)
            ON M.CO_CD = @p_CO AND M.CTRL_CD = N''LA'' AND M.CTRLD_CD = A.CTRL_CD
    GROUP BY A.CTRL_CD, M.CTRLD_NM
    ORDER BY ABS(SUM(A.AM)) DESC';
    BEGIN TRY
        EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4)', @p_CO=@CO_CD;
    END TRY
    BEGIN CATCH
        SELECT N'[B] 조정 사유별 집계' AS REPORT_NM
              ,N'LCTRL_MGM_D 컬럼 구조 상이 : ' + ERROR_MESSAGE() AS 결과;
    END CATCH
END
ELSE
    SELECT
         N'[B] 조정 사유별 집계'                    AS REPORT_NM
        ,사유코드 = CASE WHEN ISNULL(A.CTRL_CD, N'') = N'' THEN N'(미등록)' ELSE A.CTRL_CD END
        ,조정건수 = COUNT(*)
        ,순금액   = SUM(CASE WHEN A.IO_FG = N'1' THEN A.AM ELSE -A.AM END)
        ,비고 = N'LCTRL_MGM_D 없음 - 사유명 표시 불가'
    FROM   #ADJ A
    GROUP BY A.CTRL_CD
    ORDER BY ABS(SUM(A.AM)) DESC;


/*==============================================================================================
  ** 쿼리 C : 품목별 조정 현황  ★ 반복 조정 = 실물 관리 붕괴 신호
==============================================================================================*/
SELECT
     N'[C] 품목별 조정 현황'                        AS REPORT_NM
    ,A.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.SPEC                                         AS 규격
    ,I.UNIT_CD                                      AS 단위
    ,계정구분 = CASE I.ACCT_FG WHEN N'0' THEN N'원재료' WHEN N'1' THEN N'부재료'
                               WHEN N'2' THEN N'제품'   WHEN N'4' THEN N'반제품'
                               WHEN N'5' THEN N'상품'   ELSE I.ACCT_FG END
    ,조정건수 = COUNT(*)
    ,조정문서수 = COUNT(DISTINCT A.ADJ_NB)
    ,입고수량 = SUM(CASE WHEN A.IO_FG = N'1' THEN A.QT ELSE 0 END)
    ,출고수량 = SUM(CASE WHEN A.IO_FG = N'2' THEN A.QT ELSE 0 END)
    ,순조정수량 = SUM(CASE WHEN A.IO_FG = N'1' THEN A.QT ELSE -A.QT END)
    ,순조정금액 = SUM(CASE WHEN A.IO_FG = N'1' THEN A.AM ELSE -A.AM END)
    ,절대금액 = SUM(ABS(A.AM))
    ,최초조정일 = MIN(A.ADJ_DT)
    ,최종조정일 = MAX(A.ADJ_DT)
    ,사유종류수 = COUNT(DISTINCT NULLIF(A.CTRL_CD, N''))
    ,사유미등록건수 = SUM(CASE WHEN ISNULL(A.CTRL_CD, N'') = N'' THEN 1 ELSE 0 END)
    ,판정 = CASE
         WHEN COUNT(*) >= @TH_CNT
              THEN N'1.★반복 조정 (' + CAST(COUNT(*) AS NVARCHAR(10)) + N'회) - 실물 관리 점검 필요'
         WHEN SUM(CASE WHEN ISNULL(A.CTRL_CD,N'')=N'' THEN 1 ELSE 0 END) > 0
              THEN N'2.★사유 미등록 조정 포함'
         ELSE N'3.단발 조정' END
    ,추정원인 = CASE
         WHEN SUM(CASE WHEN A.IO_FG=N'2' THEN A.QT ELSE 0 END)
              > SUM(CASE WHEN A.IO_FG=N'1' THEN A.QT ELSE 0 END)
              THEN N'출고 조정 우세 - 사용보고 누락 또는 분실 가능성'
         WHEN SUM(CASE WHEN A.IO_FG=N'1' THEN A.QT ELSE 0 END)
              > SUM(CASE WHEN A.IO_FG=N'2' THEN A.QT ELSE 0 END)
              THEN N'입고 조정 우세 - 입고 등록 누락 가능성'
         ELSE N'입출 균형 - 창고 간 이동 미등록 가능성' END
FROM       #ADJ  A
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = A.ITEM_CD
GROUP BY A.ITEM_CD, I.ITEM_NM, I.SPEC, I.UNIT_CD, I.ACCT_FG
ORDER BY 판정, 절대금액 DESC
;


/*==============================================================================================
  ** 쿼리 D : 조정 상세 (건별)
==============================================================================================*/
SELECT TOP 500
     N'[D] 조정 상세'                               AS REPORT_NM
    ,A.ADJ_DT                                       AS 조정일
    ,A.ADJ_NB                                       AS 조정번호
    ,A.ADJ_SQ                                       AS 순번
    ,구분 = CASE A.IO_FG WHEN N'1' THEN N'대체입고(+)' WHEN N'2' THEN N'대체출고(-)'
                         ELSE N'?' + ISNULL(A.IO_FG, N'') END
    ,A.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,I.UNIT_CD                                      AS 단위
    ,A.WH_CD                                        AS 창고코드
    ,W.WH_NM                                        AS 창고명
    ,A.LC_CD                                        AS 장소코드
    ,A.QT                                           AS 조정수량
    ,A.AM                                           AS 조정금액
    ,A.CTRL_CD                                      AS 사유코드
    ,A.EMP_CD                                       AS 처리자
    ,E.EMP_NM                                       AS 처리자명
    ,A.REMARK                                       AS 비고
    ,검증 = CASE
         WHEN ISNULL(A.CTRL_CD, N'') = N'' THEN N'★ 사유 미등록'
         WHEN ISNULL(A.REMARK , N'') = N'' THEN N'비고 없음'
         ELSE N'-' END
FROM       #ADJ  A
LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = A.ITEM_CD
LEFT  JOIN SWH   W WITH (NOLOCK) ON W.CO_CD = @CO_CD AND W.WH_CD   = A.WH_CD
LEFT  JOIN SEMP  E WITH (NOLOCK) ON E.CO_CD = @CO_CD AND E.EMP_CD  = A.EMP_CD
ORDER BY A.ADJ_DT DESC, ABS(A.AM) DESC
;


/*==============================================================================================
  ** 쿼리 E : 월별 조정 추이  (조정이 늘고 있는가)
==============================================================================================*/
SELECT
     N'[E] 월별 조정 추이'                          AS REPORT_NM
    ,LEFT(A.ADJ_DT, 6)                              AS 조정월
    ,조정건수 = COUNT(*)
    ,품목수   = COUNT(DISTINCT A.ITEM_CD)
    ,입고금액 = SUM(CASE WHEN A.IO_FG = N'1' THEN A.AM ELSE 0 END)
    ,출고금액 = SUM(CASE WHEN A.IO_FG = N'2' THEN A.AM ELSE 0 END)
    ,순조정금액 = SUM(CASE WHEN A.IO_FG = N'1' THEN A.AM ELSE -A.AM END)
    ,절대금액 = SUM(ABS(A.AM))
    ,사유등록률_PCT = CAST(SUM(CASE WHEN ISNULL(A.CTRL_CD,N'')<>N'' THEN 1.0 ELSE 0 END)
                           / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))
    ,전월대비_건수 = COUNT(*) - LAG(COUNT(*)) OVER (ORDER BY LEFT(A.ADJ_DT, 6))
    ,추세 = CASE WHEN COUNT(*) > LAG(COUNT(*)) OVER (ORDER BY LEFT(A.ADJ_DT,6)) * 1.5
                 THEN N'★ 조정 급증 - 원인 확인' ELSE N'-' END
FROM   #ADJ A
GROUP BY LEFT(A.ADJ_DT, 6)
ORDER BY 조정월
;


/*==============================================================================================
  ** 쿼리 F : LINVTORY 조정 수불 대사  (GRP_FG='6')
     ─ LADJUST 와 실제 수불(GRP_FG='6')이 맞는지 본다. 안 맞으면 조정이 재고에 반영되지 않았다.
==============================================================================================*/
SELECT
     N'[F] 조정 수불 대사'                          AS REPORT_NM
    ,품번 = ISNULL(A.ITEM_CD, V.ITEM_CD)
    ,I.ITEM_NM                                      AS 품명
    ,조정테이블_입고 = ISNULL(A.RCV_QT, 0)
    ,조정테이블_출고 = ISNULL(A.ISU_QT, 0)
    ,수불_조정입고   = ISNULL(V.RCV_QT, 0)
    ,수불_조정출고   = ISNULL(V.ISU_QT, 0)
    ,입고차이 = ISNULL(A.RCV_QT,0) - ISNULL(V.RCV_QT,0)
    ,출고차이 = ISNULL(A.ISU_QT,0) - ISNULL(V.ISU_QT,0)
    ,판정 = CASE
         WHEN A.ITEM_CD IS NULL
              THEN N'1.★수불에만 조정 있음 (GRP_FG=6) - 이월/해체일 수 있음'
         WHEN V.ITEM_CD IS NULL
              THEN N'2.★LADJUST 에만 있고 수불 반영 안 됨 - 재고에 미반영'
         WHEN ABS(ISNULL(A.RCV_QT,0)-ISNULL(V.RCV_QT,0)) < 0.000001
          AND ABS(ISNULL(A.ISU_QT,0)-ISNULL(V.ISU_QT,0)) < 0.000001
              THEN N'0.일치'
         ELSE N'3.★수량 불일치' END
FROM ( SELECT ITEM_CD
            ,RCV_QT = SUM(CASE WHEN IO_FG = N'1' THEN QT ELSE 0 END)
            ,ISU_QT = SUM(CASE WHEN IO_FG = N'2' THEN QT ELSE 0 END)
       FROM #ADJ GROUP BY ITEM_CD ) A
FULL JOIN ( SELECT V.ITEM_CD
                 ,RCV_QT = SUM(CAST(ISNULL(V.IRCV_QT,0) AS DECIMAL(19,6)))
                 ,ISU_QT = SUM(CAST(ISNULL(V.IISU_QT,0) AS DECIMAL(19,6)))
            FROM   LINVTORY V WITH (NOLOCK)
            WHERE  V.CO_CD = @CO_CD AND V.GRP_FG = N'6'
              AND  V.IO_DT BETWEEN @FR_DT AND @TO_DT
              AND  ISNULL(V.USE_YN, N'1') = N'1' AND ISNULL(V.EXPIRE_YN, N'1') = N'1'
              AND  (@DIV_CD  IS NULL OR V.DIV_CD  = @DIV_CD)
              AND  (@ITEM_CD IS NULL OR V.ITEM_CD = @ITEM_CD)
            GROUP BY V.ITEM_CD ) V ON V.ITEM_CD = A.ITEM_CD
LEFT JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = @CO_CD AND I.ITEM_CD = ISNULL(A.ITEM_CD, V.ITEM_CD)
WHERE  A.ITEM_CD IS NULL OR V.ITEM_CD IS NULL
   OR  ABS(ISNULL(A.RCV_QT,0)-ISNULL(V.RCV_QT,0)) >= 0.000001
   OR  ABS(ISNULL(A.ISU_QT,0)-ISNULL(V.ISU_QT,0)) >= 0.000001
ORDER BY 판정, ABS(입고차이) + ABS(출고차이) DESC
;


/*==============================================================================================
  ** 쿼리 G : 데이터 점검
==============================================================================================*/
SELECT
     N'[G] 데이터 점검'                             AS REPORT_NM
    ,LADJUST_존재    = CASE WHEN OBJECT_ID(N'dbo.LADJUST'   ,N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,LADJUST_D_존재  = CASE WHEN OBJECT_ID(N'dbo.LADJUST_D' ,N'U') IS NOT NULL THEN N'O' ELSE N'X' END
    ,LCTRL_MGM_D_존재 = CASE WHEN @HAS_CTRL = 1 THEN N'O' ELSE N'X' END
    ,조정수량컬럼 = ISNULL(@QTCOL, N'(미확인)')
    ,조정금액컬럼 = ISNULL(@AMCOL, N'(미확인 - 단가 근사)')
    ,입출구분컬럼 = ISNULL(@IOCOL, N'(미확인 - 수량 부호로 판정)')
    ,적재건수 = (SELECT COUNT(*) FROM #ADJ)
    ,판정 = CASE
         WHEN @HAS_ADJ = 0
              THEN N'1.★LADJUST 조회 실패 - 아래 확인 쿼리로 컬럼을 확인할 것'
         WHEN (SELECT COUNT(*) FROM #ADJ) = 0
              THEN N'0.기간 내 조정 없음 (양호한 상태)'
         WHEN @AMCOL IS NULL
              THEN N'2.금액 컬럼 없음 - 마스터 단가 근사치를 쓰고 있다'
         ELSE N'0.정상' END
;


DROP TABLE #ADJ, #UM;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 재고조정 테이블 컬럼  ★ 본 쿼리는 자동 탐색한다
     SELECT name, TYPE_NAME(user_type_id) FROM sys.columns
     WHERE object_id = OBJECT_ID('LADJUST_D') ORDER BY column_id;
     --> 수량 후보 : ADJ_QT, IO_QT, ITEM_QT, MGMT_QT, QT
        금액 후보 : ADJ_AM, IO_AM, ITEM_AM, INV_AM, AM
        입출 후보 : IO_FG, ADJ_FG, INOUT_FG
        없으면 1번 블록의 IN (...) 에 추가할 것.

  -- (2) 조정 사유 코드  ★ CTRL_CD='LA' 가 재고조정 관리내역이다
     SELECT * FROM LCTRL_MGM   WHERE CO_CD='1000' AND CTRL_CD='LA';
     SELECT * FROM LCTRL_MGM_D WHERE CO_CD='1000' AND CTRL_CD='LA';
     --> 사유 코드가 등록되어 있지 않으면 쿼리 B 가 '(미등록)' 한 줄로만 나온다.
        조정 사유 관리는 감사 대응의 기본이므로 먼저 코드를 정비할 것.

  -- (3) 조정 규모 파악
     SELECT LEFT(ADJ_DT,6) 월, COUNT(*) FROM LADJUST
     WHERE CO_CD='1000' GROUP BY LEFT(ADJ_DT,6) ORDER BY 1;
     --> 조정이 매월 수백 건이면 등록 프로세스 자체에 문제가 있다.

  -- (4) GRP_FG='6' 수불 구성  ★ 쿼리 F 의 전제
     SELECT TYP_FG, COUNT(*) FROM LINVTORY
     WHERE CO_CD='1000' AND GRP_FG='6' GROUP BY TYP_FG;
     --> GRP_FG='6' 에는 조정 외에 해체·이월도 섞인다. TYP_FG 로 구분되면
        쿼리 F 의 서브쿼리에 그 조건을 추가해 정확도를 올릴 것.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **`GRP_FG='6'` 에는 조정 외에 해체·이월이 섞인다.** 쿼리 F 에서 '수불에만 조정 있음'
     으로 잡히는 건 대부분 이월(`IO_NB='XY'`)이나 세트 해체다. 확인 (4)번으로 `TYP_FG`
     구분이 가능하면 조건을 좁힐 것.

  2) **금액 컬럼이 없으면 마스터 표준단가로 근사**한다(쿼리 G 에 표시). 실제 조정 금액은
     평가 단가로 계산되므로 손익 영향을 정확히 보려면 `LINV_MVFIFO` 를 봐야 한다.

  3) 이 리포트는 조정을 **찾아 보여줄 뿐 막지 못한다.** 조정이 반복되는 품목은
     `P03_실시간재고_추적.sql` 의 마이너스 재고, `M05_자재_청구출고사용_현황.sql` 의
     출고미사용과 함께 봐야 진짜 원인(등록 누락 지점)이 나온다.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   P03_실시간재고_추적.sql        : 마이너스 재고 (조정의 흔한 원인)
   M05_자재_청구출고사용_현황.sql : 출고미사용 (자재 조정의 원인)
   P09_재고정합성_점검.sql        : 실사 차이 → 조정으로 이어진다
   P04_재고수불_회전율분석.sql    : 쿼리 B 의 GRP_FG='6' 집계
==============================================================================================*/
