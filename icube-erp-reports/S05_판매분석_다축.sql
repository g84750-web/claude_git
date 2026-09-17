/*==============================================================================================
  [ iCUBE ] S-05 담당자별 매출이익  +  S-10 거래처·품목군별 판매추이                 (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 매출을 **여러 축(담당·거래처·품목군)** 으로 갈라 보고, **전년 동기 대비** 로 추세를 본다.
         "얼마 팔았나"가 아니라 "어디서 늘고 어디서 줄었나"를 답하는 리포트.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ C-05 와의 차이 ]
  ----------------------------------------------------------------------------------------------
     `C05_매출이익_분석.sql` 은 **역마진 적출**이 목적이라 건별 상세와 원가 커버리지를 본다.
     이 파일은 **추세와 구성**이 목적이다. 전년 동기 대비, 품목군 집계, 신규/이탈 거래처.
     담당자 축(S-05)은 C-05 쿼리 C 와 산식이 같으나, 여기서는 **전년 대비 증감**을 붙였다.

  ----------------------------------------------------------------------------------------------
  [ 산식 ]
  ----------------------------------------------------------------------------------------------
     매출이익 = 매출액(CLSG_AM) - 판매수량 × 단위원가
     전년동기대비 = 당기 / 전년동기 - 1
     신규거래처 = 당기 매출 있고 전년 동기 매출 없음
     이탈거래처 = 전년 동기 매출 있고 당기 매출 없음
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
    ,@TO_DT    NVARCHAR(8)  = N'20260930'
    ,@TR_CD    NVARCHAR(10) = NULL
    ,@EMP_CD   NVARCHAR(10) = NULL
    ,@GRP_CD   NVARCHAR(10) = NULL            -- 품목군
    ,@TH_CHG   DECIMAL(5,1) = 20.0            -- 증감 경고 기준 (%)
;

-- 전년 동기
DECLARE @LY_FR NVARCHAR(8) = CONVERT(NVARCHAR(8), DATEADD(YEAR,-1,CONVERT(DATE,@FR_DT)), 112);
DECLARE @LY_TO NVARCHAR(8) = CONVERT(NVARCHAR(8), DATEADD(YEAR,-1,CONVERT(DATE,@TO_DT)), 112);
DECLARE @SQL NVARCHAR(MAX);
DECLARE @GRPCOL NVARCHAR(30) = NULL, @GRPTBL NVARCHAR(30) = NULL;

IF OBJECT_ID('tempdb..#UM')  IS NOT NULL DROP TABLE #UM;
IF OBJECT_ID('tempdb..#SAL') IS NOT NULL DROP TABLE #SAL;


/*==============================================================================================
  1. #UM : 단위원가 (C-05 와 동일한 우선순위 — PRD → FIFO → TAV → STD)
==============================================================================================*/
CREATE TABLE #UM (ITEM_CD NVARCHAR(25) PRIMARY KEY, UM DECIMAL(19,6), SRC NVARCHAR(10));

IF OBJECT_ID(N'dbo.CIV_PRD_TAV', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
        INSERT INTO #UM (ITEM_CD, UM, SRC)
        SELECT P.ITEM_CD
              ,CAST(SUM(CAST(ISNULL(P.PRD_AM,0) AS DECIMAL(19,4)))
                    / NULLIF(SUM(CAST(ISNULL(P.PRD_QT,0) AS DECIMAL(19,6))), 0) AS DECIMAL(19,6))
              ,N''PRD''
        FROM   dbo.CIV_PRD_TAV P WITH (NOLOCK)
        WHERE  P.CO_CD = @p_CO AND (@p_DIV IS NULL OR P.DIV_CD = @p_DIV)
        GROUP BY P.ITEM_CD
        HAVING SUM(CAST(ISNULL(P.PRD_QT,0) AS DECIMAL(19,6))) > 0';
    BEGIN TRY EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4)'
        ,@p_CO=@CO_CD, @p_DIV=@DIV_CD; END TRY BEGIN CATCH END CATCH
END
IF OBJECT_ID(N'dbo.LINV_TAV', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
        INSERT INTO #UM (ITEM_CD, UM, SRC)
        SELECT T.ITEM_CD, CAST(AVG(CAST(NULLIF(T.ISU_UM,0) AS DECIMAL(19,6))) AS DECIMAL(19,6)), N''TAV''
        FROM   dbo.LINV_TAV T WITH (NOLOCK)
        WHERE  T.CO_CD = @p_CO AND ISNULL(T.ISU_UM,0) <> 0
          AND  (@p_DIV IS NULL OR T.DIV_CD = @p_DIV)
          AND  NOT EXISTS (SELECT 1 FROM #UM U WHERE U.ITEM_CD = T.ITEM_CD)
        GROUP BY T.ITEM_CD';
    BEGIN TRY EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4)'
        ,@p_CO=@CO_CD, @p_DIV=@DIV_CD; END TRY BEGIN CATCH END CATCH
END
INSERT INTO #UM (ITEM_CD, UM, SRC)
SELECT I.ITEM_CD, CAST(ISNULL(NULLIF(I.STD_UM,0), I.PUR_UM) AS DECIMAL(19,6)), N'STD'
FROM   SITEM I WITH (NOLOCK)
WHERE  I.CO_CD = @CO_CD AND ISNULL(NULLIF(I.STD_UM,0), I.PUR_UM) IS NOT NULL
  AND  NOT EXISTS (SELECT 1 FROM #UM U WHERE U.ITEM_CD = I.ITEM_CD);


/*==============================================================================================
  2. 품목군 컬럼 탐색  (SITEM 의 품목군 컬럼명이 사이트마다 다르다)
==============================================================================================*/
SELECT TOP 1 @GRPCOL = name FROM sys.columns
WHERE  object_id = OBJECT_ID(N'dbo.SITEM')
  AND  name IN (N'ITEMGRP_CD', N'GRP_CD', N'ITEM_GRP', N'CLASS_CD', N'L_CD')
ORDER BY CASE name WHEN N'ITEMGRP_CD' THEN 1 WHEN N'GRP_CD' THEN 2 ELSE 3 END;

IF    OBJECT_ID(N'dbo.SITEMGRP', N'U') IS NOT NULL SET @GRPTBL = N'SITEMGRP';
PRINT N'[2] 품목군 컬럼 = ' + ISNULL(@GRPCOL, N'(미확인)')
    + N' / 마스터 = ' + ISNULL(@GRPTBL, N'(없음)');


/*==============================================================================================
  3. #SAL : 당기 + 전년동기 매출 (원가 결합)
==============================================================================================*/
SET @SQL = N'
    SELECT
         TAG = CASE WHEN H.CLS_DT BETWEEN @p_FR AND @p_TO THEN N''C'' ELSE N''P'' END
        ,H.CLS_DT
        ,H.TR_CD
        ,EMP_CD  = ISNULL(NULLIF(D.EMP_CD, N''''), H.EMP_CD)
        ,D.ITEM_CD
        ,GRP_CD  = ' + CASE WHEN @GRPCOL IS NOT NULL
                            THEN N'ISNULL(I.' + QUOTENAME(@GRPCOL) + N', N''(미분류)'')'
                            ELSE N'N''(품목군 없음)''' END + N'
        ,QT      = CAST(ISNULL(D.CLS_QT, 0) AS DECIMAL(19,6))
        ,SALE_AM = CAST(ISNULL(D.CLSG_AM, D.CLSH_AM) AS DECIMAL(19,4))
        ,COST_AM = CAST(ISNULL(D.CLS_QT,0) * ISNULL(U.UM,0) AS DECIMAL(19,4))
    INTO #SAL
    FROM       LSALECLS   H WITH (NOLOCK)
    INNER JOIN LSALECLS_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.CLS_NB = H.CLS_NB
    LEFT  JOIN SITEM      I WITH (NOLOCK) ON I.CO_CD = D.CO_CD AND I.ITEM_CD = D.ITEM_CD
    LEFT  JOIN #UM        U ON U.ITEM_CD = D.ITEM_CD
    WHERE  H.CO_CD = @p_CO
      AND  ( H.CLS_DT BETWEEN @p_FR AND @p_TO OR H.CLS_DT BETWEEN @p_LF AND @p_LT )
      AND  ISNULL(D.USE_YN, N''1'') = N''1'' AND ISNULL(D.EXPIRE_YN, N''1'') = N''1''
      AND  (@p_DIV IS NULL OR H.DIV_CD = @p_DIV)
      AND  (@p_TR  IS NULL OR H.TR_CD  = @p_TR)
      AND  ISNULL(I.S_CD, N'''') <> N''Z00''';
EXEC sp_executesql @SQL
    ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_FR NVARCHAR(8), @p_TO NVARCHAR(8)
      ,@p_LF NVARCHAR(8), @p_LT NVARCHAR(8), @p_TR NVARCHAR(10)'
    ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_FR=@FR_DT, @p_TO=@TO_DT
    ,@p_LF=@LY_FR, @p_LT=@LY_TO, @p_TR=@TR_CD;

CREATE CLUSTERED INDEX IX_SAL ON #SAL (TAG, TR_CD, ITEM_CD);
PRINT N'[3] 매출 라인 : ' + CAST((SELECT COUNT(*) FROM #SAL) AS NVARCHAR(20));


/*==============================================================================================
  ** 쿼리 A : 담당자별 매출이익 + 전년 대비  (S-05)
==============================================================================================*/
;WITH X AS (
    SELECT
         S.EMP_CD
        ,C_SALE = SUM(CASE WHEN S.TAG=N'C' THEN S.SALE_AM ELSE 0 END)
        ,C_COST = SUM(CASE WHEN S.TAG=N'C' THEN S.COST_AM ELSE 0 END)
        ,P_SALE = SUM(CASE WHEN S.TAG=N'P' THEN S.SALE_AM ELSE 0 END)
        ,P_COST = SUM(CASE WHEN S.TAG=N'P' THEN S.COST_AM ELSE 0 END)
        ,C_TR   = COUNT(DISTINCT CASE WHEN S.TAG=N'C' THEN S.TR_CD END)
        ,P_TR   = COUNT(DISTINCT CASE WHEN S.TAG=N'P' THEN S.TR_CD END)
        ,C_ITEM = COUNT(DISTINCT CASE WHEN S.TAG=N'C' THEN S.ITEM_CD END)
    FROM   #SAL S
    WHERE  @EMP_CD IS NULL OR S.EMP_CD = @EMP_CD
    GROUP BY S.EMP_CD
)
SELECT
     N'[A] 담당자별 매출이익'                       AS REPORT_NM
    ,X.EMP_CD                                       AS 담당자코드
    ,E.EMP_NM                                       AS 담당자명
    ,P.DEPT_NM                                      AS 부서명
    ,X.C_TR                                         AS 거래처수
    ,X.C_ITEM                                       AS 품목수
    ,X.C_SALE                                       AS 당기매출
    ,X.C_COST                                       AS 당기원가
    ,당기이익 = X.C_SALE - X.C_COST
    ,이익률_PCT = CAST((X.C_SALE - X.C_COST) / NULLIF(X.C_SALE, 0) * 100 AS DECIMAL(5,1))
    ,X.P_SALE                                       AS 전년동기매출
    ,전년이익 = X.P_SALE - X.P_COST
    ,전년이익률_PCT = CAST((X.P_SALE - X.P_COST) / NULLIF(X.P_SALE, 0) * 100 AS DECIMAL(5,1))
    ,매출증감 = X.C_SALE - X.P_SALE
    ,매출증감률_PCT = CAST(CASE WHEN X.P_SALE <> 0
                                THEN (X.C_SALE / X.P_SALE - 1) * 100 END AS DECIMAL(9,1))
    ,이익증감 = (X.C_SALE - X.C_COST) - (X.P_SALE - X.P_COST)
    ,이익률증감_PCTP = CAST((X.C_SALE-X.C_COST)/NULLIF(X.C_SALE,0)*100
                           - (X.P_SALE-X.P_COST)/NULLIF(X.P_SALE,0)*100 AS DECIMAL(5,1))
    ,거래처증감 = X.C_TR - X.P_TR
    ,매출기여도_PCT = CAST(X.C_SALE * 100.0 / NULLIF(SUM(X.C_SALE) OVER (), 0) AS DECIMAL(5,1))
    ,판정 = CASE
         WHEN X.P_SALE = 0                                                THEN N'9.전년 실적 없음'
         WHEN X.C_SALE < X.P_SALE * (1 - @TH_CHG/100)                     THEN N'1.★매출 감소'
         WHEN (X.C_SALE-X.C_COST)/NULLIF(X.C_SALE,0)
              < (X.P_SALE-X.P_COST)/NULLIF(X.P_SALE,0) - 0.05             THEN N'2.★이익률 악화(5%p 초과)'
         WHEN X.C_SALE > X.P_SALE * (1 + @TH_CHG/100)                     THEN N'0.성장'
         ELSE N'3.보합' END
FROM       X
LEFT  JOIN SEMP  E WITH (NOLOCK) ON E.CO_CD = @CO_CD AND E.EMP_CD  = X.EMP_CD
LEFT  JOIN SDEPT P WITH (NOLOCK) ON P.CO_CD = @CO_CD AND P.DEPT_CD = E.DEPT_CD
ORDER BY 판정, 당기매출 DESC
;


/*==============================================================================================
  ** 쿼리 B : 품목군별 판매추이 + 전년 대비  (S-10)
==============================================================================================*/
;WITH X AS (
    SELECT
         S.GRP_CD
        ,C_SALE = SUM(CASE WHEN S.TAG=N'C' THEN S.SALE_AM ELSE 0 END)
        ,C_COST = SUM(CASE WHEN S.TAG=N'C' THEN S.COST_AM ELSE 0 END)
        ,C_QT   = SUM(CASE WHEN S.TAG=N'C' THEN S.QT ELSE 0 END)
        ,P_SALE = SUM(CASE WHEN S.TAG=N'P' THEN S.SALE_AM ELSE 0 END)
        ,P_COST = SUM(CASE WHEN S.TAG=N'P' THEN S.COST_AM ELSE 0 END)
        ,P_QT   = SUM(CASE WHEN S.TAG=N'P' THEN S.QT ELSE 0 END)
        ,C_TR   = COUNT(DISTINCT CASE WHEN S.TAG=N'C' THEN S.TR_CD END)
        ,C_ITEM = COUNT(DISTINCT CASE WHEN S.TAG=N'C' THEN S.ITEM_CD END)
    FROM   #SAL S
    WHERE  @GRP_CD IS NULL OR S.GRP_CD = @GRP_CD
    GROUP BY S.GRP_CD
)
SELECT
     N'[B] 품목군별 판매추이'                       AS REPORT_NM
    ,X.GRP_CD                                       AS 품목군코드
    ,X.C_ITEM                                       AS 품목수
    ,X.C_TR                                         AS 거래처수
    ,X.C_QT                                         AS 당기수량
    ,X.C_SALE                                       AS 당기매출
    ,당기이익 = X.C_SALE - X.C_COST
    ,이익률_PCT = CAST((X.C_SALE - X.C_COST) / NULLIF(X.C_SALE, 0) * 100 AS DECIMAL(5,1))
    ,X.P_QT                                         AS 전년수량
    ,X.P_SALE                                       AS 전년매출
    ,수량증감률_PCT = CAST(CASE WHEN X.P_QT <> 0
                                THEN (X.C_QT / X.P_QT - 1) * 100 END AS DECIMAL(9,1))
    ,매출증감률_PCT = CAST(CASE WHEN X.P_SALE <> 0
                                THEN (X.C_SALE / X.P_SALE - 1) * 100 END AS DECIMAL(9,1))
    ,평균단가_당기 = CAST(X.C_SALE / NULLIF(X.C_QT, 0) AS DECIMAL(19,2))
    ,평균단가_전년 = CAST(X.P_SALE / NULLIF(X.P_QT, 0) AS DECIMAL(19,2))
    ,단가증감률_PCT = CAST(CASE WHEN X.P_SALE / NULLIF(X.P_QT,0) <> 0
                                THEN ((X.C_SALE/NULLIF(X.C_QT,0)) / (X.P_SALE/NULLIF(X.P_QT,0)) - 1) * 100
                                END AS DECIMAL(9,1))
    ,매출구성비_PCT = CAST(X.C_SALE * 100.0 / NULLIF(SUM(X.C_SALE) OVER (), 0) AS DECIMAL(5,1))
    ,증감요인 = CASE
         WHEN X.P_SALE = 0                                                  THEN N'신규'
         WHEN X.C_QT > X.P_QT AND X.C_SALE > X.P_SALE                        THEN N'물량 증가'
         WHEN X.C_QT < X.P_QT AND X.C_SALE > X.P_SALE                        THEN N'★단가 인상 (물량 감소)'
         WHEN X.C_QT > X.P_QT AND X.C_SALE < X.P_SALE                        THEN N'★단가 하락 (물량 증가)'
         WHEN X.C_QT < X.P_QT AND X.C_SALE < X.P_SALE                        THEN N'★물량·단가 동반 하락'
         ELSE N'보합' END
FROM   X
ORDER BY 당기매출 DESC
;


/*==============================================================================================
  ** 쿼리 C : 거래처별 판매추이 + 신규/이탈  (S-10)
==============================================================================================*/
;WITH X AS (
    SELECT
         S.TR_CD
        ,C_SALE = SUM(CASE WHEN S.TAG=N'C' THEN S.SALE_AM ELSE 0 END)
        ,C_COST = SUM(CASE WHEN S.TAG=N'C' THEN S.COST_AM ELSE 0 END)
        ,P_SALE = SUM(CASE WHEN S.TAG=N'P' THEN S.SALE_AM ELSE 0 END)
        ,P_COST = SUM(CASE WHEN S.TAG=N'P' THEN S.COST_AM ELSE 0 END)
        ,C_ITEM = COUNT(DISTINCT CASE WHEN S.TAG=N'C' THEN S.ITEM_CD END)
        ,P_ITEM = COUNT(DISTINCT CASE WHEN S.TAG=N'P' THEN S.ITEM_CD END)
        ,C_CNT  = SUM(CASE WHEN S.TAG=N'C' THEN 1 ELSE 0 END)
        ,LAST_DT= MAX(CASE WHEN S.TAG=N'C' THEN S.CLS_DT END)
    FROM   #SAL S
    GROUP BY S.TR_CD
)
SELECT
     N'[C] 거래처별 판매추이'                       AS REPORT_NM
    ,구분 = CASE WHEN X.P_SALE = 0 AND X.C_SALE > 0 THEN N'1.★신규 거래처'
                 WHEN X.C_SALE = 0 AND X.P_SALE > 0 THEN N'2.★이탈 거래처'
                 WHEN X.C_SALE < X.P_SALE * (1 - @TH_CHG/100) THEN N'3.★매출 감소'
                 WHEN X.C_SALE > X.P_SALE * (1 + @TH_CHG/100) THEN N'4.성장'
                 ELSE N'5.유지' END
    ,X.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,X.C_ITEM                                       AS 당기품목수
    ,X.C_CNT                                        AS 당기거래건수
    ,X.C_SALE                                       AS 당기매출
    ,당기이익 = X.C_SALE - X.C_COST
    ,이익률_PCT = CAST((X.C_SALE - X.C_COST) / NULLIF(X.C_SALE, 0) * 100 AS DECIMAL(5,1))
    ,X.P_SALE                                       AS 전년동기매출
    ,매출증감 = X.C_SALE - X.P_SALE
    ,매출증감률_PCT = CAST(CASE WHEN X.P_SALE <> 0
                                THEN (X.C_SALE / X.P_SALE - 1) * 100 END AS DECIMAL(9,1))
    ,품목수증감 = X.C_ITEM - X.P_ITEM
    ,X.LAST_DT                                      AS 최종거래일
    ,매출구성비_PCT = CAST(X.C_SALE * 100.0 / NULLIF(SUM(X.C_SALE) OVER (), 0) AS DECIMAL(5,1))
    ,조치 = CASE
         WHEN X.C_SALE = 0 AND X.P_SALE > 0
              THEN N'★ 거래 중단 원인 확인 - 이탈 방지 접촉'
         WHEN X.C_SALE < X.P_SALE * 0.5 AND X.P_SALE > 0
              THEN N'★ 매출 반토막 - 경쟁사 전환 여부 확인'
         WHEN X.C_ITEM < X.P_ITEM
              THEN N'취급 품목 축소 - 이탈 전조일 수 있음'
         ELSE N'-' END
FROM       X
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD = X.TR_CD
ORDER BY 구분, ABS(매출증감) DESC
;


/*==============================================================================================
  ** 쿼리 D : 월별 추이 (당기 vs 전년 동기)
==============================================================================================*/
SELECT
     N'[D] 월별 매출 추이'                          AS REPORT_NM
    ,월 = RIGHT(LEFT(S.CLS_DT, 6), 2)
    ,당기매출 = SUM(CASE WHEN S.TAG=N'C' THEN S.SALE_AM ELSE 0 END)
    ,당기이익 = SUM(CASE WHEN S.TAG=N'C' THEN S.SALE_AM - S.COST_AM ELSE 0 END)
    ,전년매출 = SUM(CASE WHEN S.TAG=N'P' THEN S.SALE_AM ELSE 0 END)
    ,전년이익 = SUM(CASE WHEN S.TAG=N'P' THEN S.SALE_AM - S.COST_AM ELSE 0 END)
    ,매출증감률_PCT = CAST(CASE WHEN SUM(CASE WHEN S.TAG=N'P' THEN S.SALE_AM ELSE 0 END) <> 0
                                THEN (SUM(CASE WHEN S.TAG=N'C' THEN S.SALE_AM ELSE 0 END)
                                      / SUM(CASE WHEN S.TAG=N'P' THEN S.SALE_AM ELSE 0 END) - 1) * 100
                                END AS DECIMAL(9,1))
    ,당기이익률_PCT = CAST(SUM(CASE WHEN S.TAG=N'C' THEN S.SALE_AM-S.COST_AM ELSE 0 END)
                           / NULLIF(SUM(CASE WHEN S.TAG=N'C' THEN S.SALE_AM ELSE 0 END), 0)
                           * 100 AS DECIMAL(5,1))
    ,전년이익률_PCT = CAST(SUM(CASE WHEN S.TAG=N'P' THEN S.SALE_AM-S.COST_AM ELSE 0 END)
                           / NULLIF(SUM(CASE WHEN S.TAG=N'P' THEN S.SALE_AM ELSE 0 END), 0)
                           * 100 AS DECIMAL(5,1))
    ,거래처수 = COUNT(DISTINCT CASE WHEN S.TAG=N'C' THEN S.TR_CD END)
FROM   #SAL S
GROUP BY RIGHT(LEFT(S.CLS_DT, 6), 2)
ORDER BY 월
;


/*==============================================================================================
  ** 쿼리 E : 거래처 × 품목군 교차 (누가 무엇을 사는가)
==============================================================================================*/
SELECT TOP 200
     N'[E] 거래처 × 품목군'                         AS REPORT_NM
    ,S.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,S.GRP_CD                                       AS 품목군
    ,품목수 = COUNT(DISTINCT CASE WHEN S.TAG=N'C' THEN S.ITEM_CD END)
    ,당기매출 = SUM(CASE WHEN S.TAG=N'C' THEN S.SALE_AM ELSE 0 END)
    ,당기이익 = SUM(CASE WHEN S.TAG=N'C' THEN S.SALE_AM - S.COST_AM ELSE 0 END)
    ,이익률_PCT = CAST(SUM(CASE WHEN S.TAG=N'C' THEN S.SALE_AM-S.COST_AM ELSE 0 END)
                       / NULLIF(SUM(CASE WHEN S.TAG=N'C' THEN S.SALE_AM ELSE 0 END), 0)
                       * 100 AS DECIMAL(5,1))
    ,전년매출 = SUM(CASE WHEN S.TAG=N'P' THEN S.SALE_AM ELSE 0 END)
    ,증감률_PCT = CAST(CASE WHEN SUM(CASE WHEN S.TAG=N'P' THEN S.SALE_AM ELSE 0 END) <> 0
                            THEN (SUM(CASE WHEN S.TAG=N'C' THEN S.SALE_AM ELSE 0 END)
                                  / SUM(CASE WHEN S.TAG=N'P' THEN S.SALE_AM ELSE 0 END) - 1) * 100
                            END AS DECIMAL(9,1))
    ,거래처내_비중_PCT = CAST(SUM(CASE WHEN S.TAG=N'C' THEN S.SALE_AM ELSE 0 END) * 100.0
                              / NULLIF(SUM(SUM(CASE WHEN S.TAG=N'C' THEN S.SALE_AM ELSE 0 END))
                                       OVER (PARTITION BY S.TR_CD), 0) AS DECIMAL(5,1))
FROM       #SAL   S
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD = S.TR_CD
GROUP BY S.TR_CD, T.TR_NM, S.GRP_CD
HAVING SUM(CASE WHEN S.TAG=N'C' THEN S.SALE_AM ELSE 0 END) <> 0
ORDER BY 당기매출 DESC
;


/*==============================================================================================
  ** 쿼리 F : 전사 요약
==============================================================================================*/
SELECT
     N'[F] 판매 분석 요약'                          AS REPORT_NM
    ,@FR_DT + N' ~ ' + @TO_DT                       AS 당기
    ,@LY_FR + N' ~ ' + @LY_TO                       AS 전년동기
    ,품목군컬럼 = ISNULL(@GRPCOL, N'★미확인')
    ,당기매출 = SUM(CASE WHEN S.TAG=N'C' THEN S.SALE_AM ELSE 0 END)
    ,당기이익 = SUM(CASE WHEN S.TAG=N'C' THEN S.SALE_AM - S.COST_AM ELSE 0 END)
    ,전년매출 = SUM(CASE WHEN S.TAG=N'P' THEN S.SALE_AM ELSE 0 END)
    ,전년이익 = SUM(CASE WHEN S.TAG=N'P' THEN S.SALE_AM - S.COST_AM ELSE 0 END)
    ,매출증감률_PCT = CAST(CASE WHEN SUM(CASE WHEN S.TAG=N'P' THEN S.SALE_AM ELSE 0 END) <> 0
                                THEN (SUM(CASE WHEN S.TAG=N'C' THEN S.SALE_AM ELSE 0 END)
                                      / SUM(CASE WHEN S.TAG=N'P' THEN S.SALE_AM ELSE 0 END) - 1) * 100
                                END AS DECIMAL(9,1))
    ,당기거래처수 = COUNT(DISTINCT CASE WHEN S.TAG=N'C' THEN S.TR_CD END)
    ,전년거래처수 = COUNT(DISTINCT CASE WHEN S.TAG=N'P' THEN S.TR_CD END)
    ,신규거래처수 = (SELECT COUNT(*) FROM (
         SELECT TR_CD FROM #SAL WHERE TAG=N'C' GROUP BY TR_CD
         EXCEPT SELECT TR_CD FROM #SAL WHERE TAG=N'P' GROUP BY TR_CD) Z)
    ,이탈거래처수 = (SELECT COUNT(*) FROM (
         SELECT TR_CD FROM #SAL WHERE TAG=N'P' GROUP BY TR_CD
         EXCEPT SELECT TR_CD FROM #SAL WHERE TAG=N'C' GROUP BY TR_CD) Z)
    ,원가커버리지_PCT = CAST(SUM(CASE WHEN S.TAG=N'C' AND S.COST_AM <> 0 THEN S.SALE_AM ELSE 0 END) * 100.0
                             / NULLIF(SUM(CASE WHEN S.TAG=N'C' THEN S.SALE_AM ELSE 0 END), 0)
                             AS DECIMAL(5,1))
FROM   #SAL S
;


DROP TABLE #UM, #SAL;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 품목군 컬럼  ★ 쿼리 B·E 의 전제. 본 쿼리는 자동 탐색한다
     SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('SITEM')
       AND (name LIKE '%GRP%' OR name LIKE '%CLASS%');
     SELECT TOP 10 * FROM SITEMGRP WHERE CO_CD='1000';
     --> 후보(ITEMGRP_CD/GRP_CD/ITEM_GRP/CLASS_CD/L_CD)에 없으면 2번 블록에 추가할 것.
        품목군이 없으면 쿼리 B 가 한 줄로만 나온다.

  -- (2) 전년 데이터 존재 여부  ★ 전년 대비의 전제
     SELECT LEFT(CLS_DT,4) 연도, COUNT(*), SUM(CLSG_AM)
     FROM   LSALECLS H INNER JOIN LSALECLS_D D ON D.CO_CD=H.CO_CD AND D.CLS_NB=H.CLS_NB
     WHERE  H.CO_CD='1000' GROUP BY LEFT(CLS_DT,4) ORDER BY 1 DESC;
     --> 전년 데이터가 없으면 증감 컬럼이 전부 NULL 이다 (정상 동작).

  -- (3) 담당자 축  ★ EMP_CD 채움률
     SELECT COUNT(*) 전체, SUM(CASE WHEN ISNULL(EMP_CD,'')='' THEN 1 ELSE 0 END) 미지정
     FROM   LSALECLS WHERE CO_CD='1000';

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **원가는 기간 단일 단가**다. 전년과 당기에 같은 단가를 적용하므로 **전년 이익률은
     참고치**에 불과하다. 전년 이익을 정확히 보려면 전년 원가차수 단가를 따로 붙여야 한다.
     매출 증감은 정확하니, 이익보다 매출 추세를 먼저 볼 것.

  2) `증감요인`(쿼리 B)은 물량·단가 방향으로만 판단한다. 품목 구성이 바뀐 경우
     (고가품 비중 증가)도 '단가 인상'으로 잡히므로, 품목군 안을 다시 봐야 한다.

  3) 신규/이탈 판정은 **기간 비교**다. 전년 동기에 없었을 뿐 그 전에 거래가 있었을 수 있다.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   C05_매출이익_분석.sql     : 역마진 적출 (건별 상세 + 원가 커버리지)
   S04_매출수금_채권KPI.sql  : 판 것을 받았는가
   S09_영업계획대비_실적.sql : 계획 대비 달성
==============================================================================================*/
