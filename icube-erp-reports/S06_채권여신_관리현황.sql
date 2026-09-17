/*==============================================================================================
  [ iCUBE ] S-06 / S-08  채권 · 여신한도 관리 현황                                   (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : ① 거래처별 채권잔액을 **출고기준 / 마감기준 2종**으로 산출하고 그 차이(미마감 채권)를
            마감 통제 지표로 제시한다.
         ② 여신한도(`LCR_LIMIT`) 대비 소진율을 판정해 여신 초과 거래처를 사전에 잡는다.
         ③ 채권 연령분석(AR Aging)으로 회수 위험을 계량한다.

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 채권 산식 — 2기준 병행, 최종은 마감기준 ]
  ----------------------------------------------------------------------------------------------
     기초채권(출고) = LOPN_CRISU.OPEN_AM
     기초채권(마감) = LOPN_CRISU_CLS.OPEN_AM        ← 없으면 LOPN_CRISU 로 대체
     채권조정       = LCR_ADJUST.ADJUST_AM (해당년도)

     당기발생(출고) = LDELIVER_D.ISUH_AM            필터 LDELIVER.SO_FG IN ('0','2','7')
     당기발생(마감) = LSALECLS_D.CLSH_AM            ★ 회계 확정 = 최종
     당기수금       = LRCP_D.NORMAL_AM + BEFORE_AM  필터 RCPAM_FG = '0' (영업모듈)

     채권잔액(최종) = 기초(마감) + 당기발생(마감) - 수금 + 조정
     미마감채권     = 당기발생(출고) - 당기발생(마감)   ← 회계 미확정분. 마감 누락 통제 지표

  ----------------------------------------------------------------------------------------------
  [ 여신한도 ]
  ----------------------------------------------------------------------------------------------
     LCR_LIMIT (사업장별) — 명세서 누락 테이블. 존재 확인 후 사용.
        DAMBO_AM   담보한도      SINYONG_AM 신용한도
        ETC_AM     기타한도      YUSIN_AM   여신한도(합계·통제 기준)
        YUSIN_FG / YUSIN_TY / TERMS / DEPOSIT_FG / CHECK_YN
     없으면 STRADE.CREDIT_AM(여신한도금액) / LIMIT_AM(한도금액) 으로 대체.

     여신소진율 = 채권잔액(마감기준) / 여신한도 x 100
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@BASE_DT  NVARCHAR(8)  = N'20260915'     -- 기준일자 (연령분석 기준)
    ,@FR_DT    NVARCHAR(8)  = N'20260101'     -- 당기 집계 FROM
    ,@TO_DT    NVARCHAR(8)  = N'20261231'
    ,@TR_CD    NVARCHAR(10) = NULL            -- 특정 거래처
    ,@PLN_CD   NVARCHAR(5)  = NULL            -- 영업담당
    ,@TR_FG    NVARCHAR(1)  = NULL            -- 거래구분 (NULL = 전체)

    ,@TH_LIMIT DECIMAL(5,1) = 90.0            -- 여신 임박 경고 기준 %
    ,@AGE1     INT = 30                       -- 연령 구간
    ,@AGE2     INT = 60
    ,@AGE3     INT = 90
;

DECLARE @SQL NVARCHAR(MAX), @P_YR NVARCHAR(4) = LEFT(@BASE_DT, 4);

IF OBJECT_ID('tempdb..#OPN')   IS NOT NULL DROP TABLE #OPN;
IF OBJECT_ID('tempdb..#LIMIT') IS NOT NULL DROP TABLE #LIMIT;
IF OBJECT_ID('tempdb..#ISU')   IS NOT NULL DROP TABLE #ISU;
IF OBJECT_ID('tempdb..#CLS')   IS NOT NULL DROP TABLE #CLS;
IF OBJECT_ID('tempdb..#RCP')   IS NOT NULL DROP TABLE #RCP;
IF OBJECT_ID('tempdb..#AGE')   IS NOT NULL DROP TABLE #AGE;
IF OBJECT_ID('tempdb..#AR')    IS NOT NULL DROP TABLE #AR;


/*==============================================================================================
  1. #OPN : 기초채권 (출고기준 / 마감기준) + 채권조정
==============================================================================================*/
CREATE TABLE #OPN (
     TR_CD NVARCHAR(10)
    ,OPN_ISU DECIMAL(19,4) DEFAULT 0    -- 기초 (출고기준)
    ,OPN_CLS DECIMAL(19,4) DEFAULT 0    -- 기초 (마감기준)
    ,ADJ_AM  DECIMAL(19,4) DEFAULT 0    -- 채권조정
);

INSERT INTO #OPN (TR_CD, OPN_ISU)
SELECT TR_CD, SUM(CAST(ISNULL(OPEN_AM,0) AS DECIMAL(19,4)))
FROM   LOPN_CRISU WITH (NOLOCK)
WHERE  CO_CD = @CO_CD AND P_YR = @P_YR AND ISNULL(USE_YN, N'1') = N'1'
  AND  (@DIV_CD IS NULL OR DIV_CD = @DIV_CD)
GROUP BY TR_CD;

CREATE CLUSTERED INDEX IX_OPN ON #OPN (TR_CD);

-- 마감기준 기초채권 (LOPN_CRISU_CLS — 명세서 누락)
IF OBJECT_ID(N'dbo.LOPN_CRISU_CLS', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
        MERGE #OPN AS T
        USING ( SELECT TR_CD, AM = SUM(CAST(ISNULL(OPEN_AM,0) AS DECIMAL(19,4)))
                FROM   dbo.LOPN_CRISU_CLS WITH (NOLOCK)
                WHERE  CO_CD=@p_CO AND P_YR=@p_YR AND ISNULL(USE_YN,N''1'')=N''1''
                  AND  (@p_DIV IS NULL OR DIV_CD=@p_DIV)
                GROUP BY TR_CD ) AS S ON S.TR_CD = T.TR_CD
        WHEN MATCHED THEN UPDATE SET OPN_CLS = S.AM
        WHEN NOT MATCHED THEN INSERT (TR_CD, OPN_ISU, OPN_CLS, ADJ_AM) VALUES (S.TR_CD, 0, S.AM, 0);';
    EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_YR NVARCHAR(4)'
        ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_YR=@P_YR;
    PRINT N'[1] 기초채권 : LOPN_CRISU(출고) + LOPN_CRISU_CLS(마감) 적재';
END
ELSE
BEGIN
    UPDATE #OPN SET OPN_CLS = OPN_ISU;
    PRINT N'[1] LOPN_CRISU_CLS 없음 - 마감기준 기초를 출고기준으로 대체';
END

-- 채권조정
MERGE #OPN AS T
USING ( SELECT TR_CD, AM = SUM(CAST(ISNULL(ADJUST_AM,0) AS DECIMAL(19,4)))
        FROM   LCR_ADJUST WITH (NOLOCK)
        WHERE  CO_CD = @CO_CD AND P_YR = @P_YR AND ISNULL(USE_YN, N'1') = N'1'
          AND  (@DIV_CD IS NULL OR DIV_CD = @DIV_CD)
        GROUP BY TR_CD ) AS S ON S.TR_CD = T.TR_CD
WHEN MATCHED THEN UPDATE SET ADJ_AM = S.AM
WHEN NOT MATCHED THEN INSERT (TR_CD, OPN_ISU, OPN_CLS, ADJ_AM) VALUES (S.TR_CD, 0, 0, S.AM);


/*==============================================================================================
  2. #LIMIT : 여신한도  (LCR_LIMIT 우선, 없으면 STRADE)
==============================================================================================*/
CREATE TABLE #LIMIT (
     TR_CD NVARCHAR(10)
    ,YUSIN_AM   DECIMAL(19,4)
    ,DAMBO_AM   DECIMAL(19,4)
    ,SINYONG_AM DECIMAL(19,4)
    ,ETC_AM     DECIMAL(19,4)
    ,LIMIT_SRC  NVARCHAR(30)
);

IF OBJECT_ID(N'dbo.LCR_LIMIT', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
        INSERT INTO #LIMIT (TR_CD, YUSIN_AM, DAMBO_AM, SINYONG_AM, ETC_AM, LIMIT_SRC)
        SELECT TR_CD
              ,SUM(CAST(ISNULL(YUSIN_AM  ,0) AS DECIMAL(19,4)))
              ,SUM(CAST(ISNULL(DAMBO_AM  ,0) AS DECIMAL(19,4)))
              ,SUM(CAST(ISNULL(SINYONG_AM,0) AS DECIMAL(19,4)))
              ,SUM(CAST(ISNULL(ETC_AM    ,0) AS DECIMAL(19,4)))
              ,N''LCR_LIMIT''
        FROM   dbo.LCR_LIMIT WITH (NOLOCK)
        WHERE  CO_CD = @p_CO AND ISNULL(USE_YN, N''1'') = N''1''
          AND  (@p_DIV IS NULL OR DIV_CD = @p_DIV)
        GROUP BY TR_CD';
    EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4)'
        ,@p_CO=@CO_CD, @p_DIV=@DIV_CD;
    PRINT N'[2] 여신한도 : LCR_LIMIT ' + CAST((SELECT COUNT(*) FROM #LIMIT) AS NVARCHAR(20)) + N' 거래처';
END
ELSE
BEGIN
    INSERT INTO #LIMIT (TR_CD, YUSIN_AM, DAMBO_AM, SINYONG_AM, ETC_AM, LIMIT_SRC)
    SELECT T.TR_CD
          ,CAST(ISNULL(NULLIF(T.CREDIT_AM,0), T.LIMIT_AM) AS DECIMAL(19,4))
          ,0, 0, 0, N'STRADE(대체)'
    FROM   STRADE T WITH (NOLOCK)
    WHERE  T.CO_CD = @CO_CD AND ISNULL(T.USE_YN, N'1') = N'1'
      AND  ISNULL(NULLIF(T.CREDIT_AM,0), T.LIMIT_AM) IS NOT NULL;
    PRINT N'[2] LCR_LIMIT 없음 - STRADE.CREDIT_AM/LIMIT_AM 으로 대체';
END
CREATE CLUSTERED INDEX IX_LIMIT ON #LIMIT (TR_CD);


/*==============================================================================================
  3. #ISU / #CLS / #RCP : 당기 발생(출고기준/마감기준) + 수금
==============================================================================================*/
-- 출고기준 발생
SELECT
     H.TR_CD
    ,ISU_AM  = SUM(CAST(ISNULL(D.ISUH_AM,0) AS DECIMAL(19,4)))
    ,ISU_CNT = COUNT(*)
INTO #ISU
FROM       LDELIVER   H WITH (NOLOCK)
INNER JOIN LDELIVER_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.ISU_NB = H.ISU_NB
WHERE  H.CO_CD  = @CO_CD
  AND  H.ISU_DT BETWEEN @FR_DT AND @TO_DT
  AND  H.SO_FG IN (N'0', N'2', N'7')                      -- 채권 대상 거래구분
  AND  ISNULL(D.USE_YN, N'1') = N'1'
  AND  ISNULL(D.EXPIRE_YN, N'1') = N'1'
  AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
GROUP BY H.TR_CD;
CREATE CLUSTERED INDEX IX_ISU ON #ISU (TR_CD);

-- 마감기준 발생 (★ 최종)
SELECT
     H.TR_CD
    ,CLS_AM  = SUM(CAST(ISNULL(D.CLSH_AM,0) AS DECIMAL(19,4)))
    ,CLS_VAT = SUM(CAST(ISNULL(D.CLSV_AM,0) AS DECIMAL(19,4)))
    ,CLS_CNT = COUNT(*)
INTO #CLS
FROM       LSALECLS   H WITH (NOLOCK)
INNER JOIN LSALECLS_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.CLS_NB = H.CLS_NB
WHERE  H.CO_CD  = @CO_CD
  AND  H.CLS_DT BETWEEN @FR_DT AND @TO_DT
  AND  ISNULL(D.USE_YN, N'1') = N'1'
  AND  ISNULL(D.EXPIRE_YN, N'1') = N'1'
  AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
GROUP BY H.TR_CD;
CREATE CLUSTERED INDEX IX_CLS ON #CLS (TR_CD);

-- 수금
SELECT
     H.TR_CD
    ,NORMAL_AM = SUM(CAST(ISNULL(D.NORMAL_AM,0) AS DECIMAL(19,4)))
    ,BEFORE_AM = SUM(CAST(ISNULL(D.BEFORE_AM,0) AS DECIMAL(19,4)))
    ,RCP_CNT   = COUNT(*)
    ,LAST_DT   = MAX(H.RCP_DT)
INTO #RCP
FROM       LRCP   H WITH (NOLOCK)
INNER JOIN LRCP_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.RCP_NB = H.RCP_NB
WHERE  H.CO_CD  = @CO_CD
  AND  H.RCP_DT BETWEEN @FR_DT AND @TO_DT
  AND  ISNULL(D.USE_YN, N'1') = N'1'
  AND  ISNULL(D.EXPIRE_YN, N'1') = N'1'
  AND  ISNULL(D.RCPAM_FG, N'0') = N'0'                    -- 영업모듈 수금만
  AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
GROUP BY H.TR_CD;
CREATE CLUSTERED INDEX IX_RCP ON #RCP (TR_CD);


/*==============================================================================================
  4. #AGE : 채권 연령분석 (미수금 = 마감액 - 배부된 수금, 마감건별 선입선출 근사)
     * 정밀한 건별 소거가 없는 사이트가 많으므로, 마감일 기준 경과일 구간별 잔액으로 근사한다.
==============================================================================================*/
;WITH CLSD AS (
    SELECT
         H.TR_CD
        ,H.CLS_DT
        ,CLS_AM = SUM(CAST(ISNULL(D.CLSH_AM,0) AS DECIMAL(19,4)))
    FROM       LSALECLS   H WITH (NOLOCK)
    INNER JOIN LSALECLS_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.CLS_NB = H.CLS_NB
    WHERE  H.CO_CD  = @CO_CD
      AND  H.CLS_DT <= @BASE_DT
      AND  H.CLS_DT >= LEFT(@BASE_DT,4) + N'0101'
      AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
      AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
    GROUP BY H.TR_CD, H.CLS_DT
)
SELECT
     C.TR_CD
    ,AGE_00 = SUM(CASE WHEN DATEDIFF(DAY,CONVERT(DATE,C.CLS_DT),CONVERT(DATE,@BASE_DT)) <= @AGE1
                       THEN C.CLS_AM ELSE 0 END)
    ,AGE_01 = SUM(CASE WHEN DATEDIFF(DAY,CONVERT(DATE,C.CLS_DT),CONVERT(DATE,@BASE_DT)) > @AGE1
                        AND DATEDIFF(DAY,CONVERT(DATE,C.CLS_DT),CONVERT(DATE,@BASE_DT)) <= @AGE2
                       THEN C.CLS_AM ELSE 0 END)
    ,AGE_02 = SUM(CASE WHEN DATEDIFF(DAY,CONVERT(DATE,C.CLS_DT),CONVERT(DATE,@BASE_DT)) > @AGE2
                        AND DATEDIFF(DAY,CONVERT(DATE,C.CLS_DT),CONVERT(DATE,@BASE_DT)) <= @AGE3
                       THEN C.CLS_AM ELSE 0 END)
    ,AGE_03 = SUM(CASE WHEN DATEDIFF(DAY,CONVERT(DATE,C.CLS_DT),CONVERT(DATE,@BASE_DT)) > @AGE3
                       THEN C.CLS_AM ELSE 0 END)
    ,OLDEST_DT = MIN(C.CLS_DT)
INTO #AGE
FROM   CLSD C
GROUP BY C.TR_CD;
CREATE CLUSTERED INDEX IX_AGE ON #AGE (TR_CD);


/*==============================================================================================
  5. #AR : 거래처별 통합
==============================================================================================*/
;WITH K AS (
    SELECT TR_CD FROM #OPN
    UNION SELECT TR_CD FROM #ISU
    UNION SELECT TR_CD FROM #CLS
    UNION SELECT TR_CD FROM #RCP
)
SELECT
     K.TR_CD
    ,OPN_ISU  = ISNULL(O.OPN_ISU, 0)
    ,OPN_CLS  = ISNULL(O.OPN_CLS, 0)
    ,ADJ_AM   = ISNULL(O.ADJ_AM , 0)
    ,ISU_AM   = ISNULL(I.ISU_AM , 0)
    ,ISU_CNT  = ISNULL(I.ISU_CNT, 0)
    ,CLS_AM   = ISNULL(C.CLS_AM , 0)
    ,CLS_VAT  = ISNULL(C.CLS_VAT, 0)
    ,CLS_CNT  = ISNULL(C.CLS_CNT, 0)
    ,RCP_AM   = ISNULL(R.NORMAL_AM,0) + ISNULL(R.BEFORE_AM,0)
    ,NORMAL_AM= ISNULL(R.NORMAL_AM, 0)
    ,BEFORE_AM= ISNULL(R.BEFORE_AM, 0)
    ,RCP_CNT  = ISNULL(R.RCP_CNT, 0)
    ,LAST_RCP = R.LAST_DT
    -- 채권잔액
    ,BAL_CLS  = ISNULL(O.OPN_CLS,0) + ISNULL(C.CLS_AM,0)
              - (ISNULL(R.NORMAL_AM,0)+ISNULL(R.BEFORE_AM,0)) + ISNULL(O.ADJ_AM,0)
    ,BAL_ISU  = ISNULL(O.OPN_ISU,0) + ISNULL(I.ISU_AM,0)
              - (ISNULL(R.NORMAL_AM,0)+ISNULL(R.BEFORE_AM,0)) + ISNULL(O.ADJ_AM,0)
    ,UNCLS_AM = ISNULL(I.ISU_AM,0) - ISNULL(C.CLS_AM,0)     -- 미마감채권
    -- 여신
    ,YUSIN_AM   = ISNULL(L.YUSIN_AM  , 0)
    ,DAMBO_AM   = ISNULL(L.DAMBO_AM  , 0)
    ,SINYONG_AM = ISNULL(L.SINYONG_AM, 0)
    ,ETC_AM     = ISNULL(L.ETC_AM    , 0)
    ,LIMIT_SRC  = L.LIMIT_SRC
    -- 연령
    ,AGE_00 = ISNULL(G.AGE_00,0), AGE_01 = ISNULL(G.AGE_01,0)
    ,AGE_02 = ISNULL(G.AGE_02,0), AGE_03 = ISNULL(G.AGE_03,0)
    ,OLDEST_DT = G.OLDEST_DT
INTO #AR
FROM       K
LEFT  JOIN #OPN   O ON O.TR_CD = K.TR_CD
LEFT  JOIN #ISU   I ON I.TR_CD = K.TR_CD
LEFT  JOIN #CLS   C ON C.TR_CD = K.TR_CD
LEFT  JOIN #RCP   R ON R.TR_CD = K.TR_CD
LEFT  JOIN #LIMIT L ON L.TR_CD = K.TR_CD
LEFT  JOIN #AGE   G ON G.TR_CD = K.TR_CD
;
CREATE CLUSTERED INDEX IX_AR ON #AR (TR_CD);

-- 거래처 필터
IF @TR_CD IS NOT NULL OR @PLN_CD IS NOT NULL OR @TR_FG IS NOT NULL
    DELETE A FROM #AR A
    LEFT JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD = A.TR_CD
    WHERE (@TR_CD  IS NOT NULL AND A.TR_CD <> @TR_CD)
       OR (@TR_FG  IS NOT NULL AND ISNULL(T.TR_FG, N'') <> @TR_FG)
       OR (@PLN_CD IS NOT NULL AND ISNULL(T.EMP_CD, N'') <> @PLN_CD);


/*==============================================================================================
  ** 쿼리 A : 거래처별 채권 · 여신 현황  (메인)
==============================================================================================*/
SELECT
     N'[A] 채권 · 여신 현황'                        AS REPORT_NM
    ,A.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,T.ATTR_NM                                      AS 약칭
    ,T.TR_FG                                        AS 거래구분

    -- 채권 (마감기준 = 최종)
    ,A.OPN_CLS                                      AS 기초채권_마감기준
    ,A.CLS_AM                                       AS 당기매출_마감기준
    ,A.RCP_AM                                       AS 수금액
    ,A.ADJ_AM                                       AS 채권조정
    ,A.BAL_CLS                                      AS 채권잔액
    ,A.NORMAL_AM                                    AS 정상수금
    ,A.BEFORE_AM                                    AS 선수금
    ,A.LAST_RCP                                     AS 최종수금일
    ,회수율_PCT = CAST(CASE WHEN A.CLS_AM <> 0 THEN A.RCP_AM/A.CLS_AM*100 END AS DECIMAL(19,2))

    -- 출고기준 (선행지표) + 미마감
    ,A.OPN_ISU                                      AS 기초채권_출고기준
    ,A.ISU_AM                                       AS 당기매출_출고기준
    ,A.BAL_ISU                                      AS 채권잔액_출고기준
    ,A.UNCLS_AM                                     AS 미마감채권

    -- 여신
    ,A.YUSIN_AM                                     AS 여신한도
    ,A.DAMBO_AM                                     AS 담보한도
    ,A.SINYONG_AM                                   AS 신용한도
    ,A.ETC_AM                                       AS 기타한도
    ,A.LIMIT_SRC                                    AS 한도출처
    ,여신소진율_PCT = CAST(CASE WHEN A.YUSIN_AM <> 0
                                THEN A.BAL_CLS / A.YUSIN_AM * 100 END AS DECIMAL(19,2))
    ,여신잔여 = CASE WHEN A.YUSIN_AM <> 0 THEN A.YUSIN_AM - A.BAL_CLS END
    ,여신상태 = CASE
         WHEN A.YUSIN_AM = 0                                   THEN N'9.한도미등록'
         WHEN A.BAL_CLS > A.YUSIN_AM                           THEN N'1.★한도초과'
         WHEN A.BAL_CLS > A.YUSIN_AM * (@TH_LIMIT/100.0)       THEN N'2.한도임박'
         ELSE N'3.정상' END

    -- 연령
    ,A.AGE_00                                       AS 채권_30일이내
    ,A.AGE_01                                       AS 채권_31_60일
    ,A.AGE_02                                       AS 채권_61_90일
    ,A.AGE_03                                       AS 채권_90일초과
    ,A.OLDEST_DT                                    AS 최장기미수_마감일
    ,장기채권비율_PCT = CAST(CASE WHEN (A.AGE_00+A.AGE_01+A.AGE_02+A.AGE_03) <> 0
                                  THEN A.AGE_03/(A.AGE_00+A.AGE_01+A.AGE_02+A.AGE_03)*100
                                  END AS DECIMAL(19,2))
FROM       #AR    A
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD = A.TR_CD
WHERE  A.OPN_CLS <> 0 OR A.CLS_AM <> 0 OR A.RCP_AM <> 0 OR A.ISU_AM <> 0
ORDER BY 여신상태, A.BAL_CLS DESC
;


/*==============================================================================================
  ** 쿼리 B : 여신 초과 · 임박 (즉시 조치)
==============================================================================================*/
SELECT
     N'[B] 여신 초과 · 임박'                        AS REPORT_NM
    ,여신상태 = CASE WHEN A.BAL_CLS > A.YUSIN_AM                     THEN N'1.★한도초과'
                     WHEN A.BAL_CLS > A.YUSIN_AM*(@TH_LIMIT/100.0)   THEN N'2.한도임박'
                     END
    ,A.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,A.BAL_CLS                                      AS 채권잔액
    ,A.YUSIN_AM                                     AS 여신한도
    ,A.BAL_CLS - A.YUSIN_AM                         AS 초과금액
    ,여신소진율_PCT = CAST(A.BAL_CLS/NULLIF(A.YUSIN_AM,0)*100 AS DECIMAL(19,2))
    ,A.DAMBO_AM                                     AS 담보한도
    ,A.SINYONG_AM                                   AS 신용한도
    ,A.UNCLS_AM                                     AS 미마감채권
    ,잠재채권 = A.BAL_CLS + A.UNCLS_AM               -- 미마감분까지 확정되면 이 금액
    ,잠재소진율_PCT = CAST((A.BAL_CLS+A.UNCLS_AM)/NULLIF(A.YUSIN_AM,0)*100 AS DECIMAL(19,2))
    ,A.AGE_03                                       AS 채권_90일초과
    ,A.LAST_RCP                                     AS 최종수금일
    ,미수금경과일 = CASE WHEN A.LAST_RCP IS NOT NULL
                         THEN DATEDIFF(DAY, CONVERT(DATE,A.LAST_RCP), CONVERT(DATE,@BASE_DT)) END
    ,조치 = CASE WHEN A.BAL_CLS > A.YUSIN_AM AND A.AGE_03 > 0
                      THEN N'출고 보류 + 장기채권 회수 협의'
                 WHEN A.BAL_CLS > A.YUSIN_AM
                      THEN N'출고 보류 또는 한도 증액 검토'
                 ELSE N'추가 출고 전 한도 확인' END
FROM       #AR    A
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD = A.TR_CD
WHERE  A.YUSIN_AM > 0
  AND  A.BAL_CLS > A.YUSIN_AM * (@TH_LIMIT/100.0)
ORDER BY 여신상태, 초과금액 DESC
;


/*==============================================================================================
  ** 쿼리 C : 채권 2기준 대사  ★ 차이 = 미마감(회계 미확정) 채권
==============================================================================================*/
SELECT
     N'[C] 출고기준 vs 마감기준 대사'               AS REPORT_NM
    ,A.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,A.ISU_AM                                       AS 출고기준_당기매출
    ,A.CLS_AM                                       AS 마감기준_당기매출
    ,A.UNCLS_AM                                     AS 미마감채권
    ,미마감비율_PCT = CAST(CASE WHEN A.ISU_AM <> 0
                                THEN A.UNCLS_AM/A.ISU_AM*100 END AS DECIMAL(19,2))
    ,A.ISU_CNT                                      AS 출고건수
    ,A.CLS_CNT                                      AS 마감건수
    ,A.BAL_ISU                                      AS 채권잔액_출고기준
    ,A.BAL_CLS                                      AS 채권잔액_마감기준
    ,판정 = CASE WHEN ABS(A.UNCLS_AM) < 1                THEN N'0.일치'
                 WHEN A.UNCLS_AM > 0                     THEN N'1.★매출마감 누락 (출고 > 마감)'
                 ELSE N'2.마감이 출고 초과 (선마감·반품 확인)' END
FROM       #AR    A
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD = A.TR_CD
WHERE  ABS(A.UNCLS_AM) >= 1
ORDER BY ABS(A.UNCLS_AM) DESC
;


/*==============================================================================================
  ** 쿼리 D : 미마감 출고 상세  (쿼리 C 의 드릴다운 — 마감 담당자 작업지시서)
==============================================================================================*/
SELECT
     N'[D] 미마감 출고 상세'                        AS REPORT_NM
    ,H.TR_CD                                        AS 거래처코드
    ,TR.TR_NM                                       AS 거래처명
    ,H.ISU_NB                                       AS 출고번호
    ,D.ISU_SQ                                       AS 출고순번
    ,H.ISU_DT                                       AS 출고일
    ,D.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,D.ISU_QT                                       AS 출고수량
    ,ISNULL(D.CLS_QT,0)                             AS 마감수량
    ,D.ISU_QT - ISNULL(D.CLS_QT,0)                  AS 미마감수량
    ,D.ISUG_AM                                      AS 공급가액
    ,D.ISUV_AM                                      AS 부가세
    ,D.ISUH_AM                                      AS 합계액
    ,경과일 = DATEDIFF(DAY, CONVERT(DATE,H.ISU_DT), CONVERT(DATE,@BASE_DT))
    ,긴급도 = CASE WHEN DATEDIFF(DAY,CONVERT(DATE,H.ISU_DT),CONVERT(DATE,@BASE_DT)) > 60 THEN N'1.60일 경과'
                   WHEN DATEDIFF(DAY,CONVERT(DATE,H.ISU_DT),CONVERT(DATE,@BASE_DT)) > 30 THEN N'2.30일 경과'
                   ELSE N'3.당월' END
FROM       LDELIVER   H WITH (NOLOCK)
INNER JOIN LDELIVER_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.ISU_NB = H.ISU_NB
LEFT  JOIN STRADE     TR WITH (NOLOCK) ON TR.CO_CD = H.CO_CD AND TR.TR_CD = H.TR_CD
LEFT  JOIN SITEM      I  WITH (NOLOCK) ON I.CO_CD = D.CO_CD AND I.ITEM_CD = D.ITEM_CD
WHERE  H.CO_CD  = @CO_CD
  AND  H.ISU_DT BETWEEN @FR_DT AND @TO_DT
  AND  H.SO_FG IN (N'0', N'2', N'7')
  AND  ISNULL(D.USE_YN, N'1') = N'1' AND ISNULL(D.EXPIRE_YN, N'1') = N'1'
  AND  ISNULL(D.ISU_QT,0) - ISNULL(D.CLS_QT,0) <> 0
  AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
  AND  (@TR_CD  IS NULL OR H.TR_CD  = @TR_CD)
ORDER BY 긴급도, D.ISUH_AM DESC
;


/*==============================================================================================
  ** 쿼리 E : 채권 연령분석 (AR Aging)
==============================================================================================*/
SELECT
     N'[E] 채권 연령분석'                           AS REPORT_NM
    ,A.TR_CD                                        AS 거래처코드
    ,T.TR_NM                                        AS 거래처명
    ,A.BAL_CLS                                      AS 채권잔액
    ,A.AGE_00                                       AS [30일이내]
    ,A.AGE_01                                       AS [31_60일]
    ,A.AGE_02                                       AS [61_90일]
    ,A.AGE_03                                       AS [90일초과]
    ,A.AGE_00+A.AGE_01+A.AGE_02+A.AGE_03            AS 발생액계
    ,비율_30일이내 = CAST(A.AGE_00/NULLIF(A.AGE_00+A.AGE_01+A.AGE_02+A.AGE_03,0)*100 AS DECIMAL(5,1))
    ,비율_90일초과 = CAST(A.AGE_03/NULLIF(A.AGE_00+A.AGE_01+A.AGE_02+A.AGE_03,0)*100 AS DECIMAL(5,1))
    ,A.OLDEST_DT                                    AS 최장기마감일
    ,최장경과일 = CASE WHEN A.OLDEST_DT IS NOT NULL
                       THEN DATEDIFF(DAY, CONVERT(DATE,A.OLDEST_DT), CONVERT(DATE,@BASE_DT)) END
    ,A.LAST_RCP                                     AS 최종수금일
    ,회수위험 = CASE
         WHEN A.BAL_CLS <= 0                                                 THEN N'0.없음'
         WHEN A.AGE_03 > A.BAL_CLS * 0.5                                     THEN N'1.★높음 (90일초과 50% 이상)'
         WHEN A.AGE_02 + A.AGE_03 > A.BAL_CLS * 0.5                          THEN N'2.중간 (60일초과 50% 이상)'
         WHEN A.LAST_RCP IS NULL AND A.BAL_CLS > 0                           THEN N'3.수금이력 없음'
         ELSE N'4.낮음' END
FROM       #AR    A
LEFT  JOIN STRADE T WITH (NOLOCK) ON T.CO_CD = @CO_CD AND T.TR_CD = A.TR_CD
WHERE  A.BAL_CLS <> 0
ORDER BY 회수위험, A.AGE_03 DESC
;


/*==============================================================================================
  ** 쿼리 F : 전체 요약 (경영 보고 1행)
==============================================================================================*/
SELECT
     N'[F] 채권 · 여신 요약'                        AS REPORT_NM
    ,@FR_DT + N' ~ ' + @TO_DT                       AS 기간
    ,@BASE_DT                                       AS 기준일
    ,COUNT(*)                                       AS 거래처수
    ,SUM(A.OPN_CLS)                                 AS 기초채권계
    ,SUM(A.CLS_AM)                                  AS 당기매출계_마감기준
    ,SUM(A.ISU_AM)                                  AS 당기매출계_출고기준
    ,SUM(A.RCP_AM)                                  AS 수금계
    ,SUM(A.BAL_CLS)                                 AS 채권잔액계
    ,SUM(A.UNCLS_AM)                                AS 미마감채권계
    ,전체회수율_PCT = CAST(CASE WHEN SUM(A.CLS_AM) <> 0
                                THEN SUM(A.RCP_AM)/SUM(A.CLS_AM)*100 END AS DECIMAL(19,2))
    ,SUM(A.AGE_03)                                  AS 장기채권_90일초과
    ,장기채권비율_PCT = CAST(CASE WHEN SUM(A.BAL_CLS) <> 0
                                  THEN SUM(A.AGE_03)/SUM(A.BAL_CLS)*100 END AS DECIMAL(19,2))
    ,SUM(CASE WHEN A.YUSIN_AM > 0 AND A.BAL_CLS > A.YUSIN_AM THEN 1 ELSE 0 END) AS 여신초과거래처수
    ,SUM(CASE WHEN A.YUSIN_AM > 0 AND A.BAL_CLS > A.YUSIN_AM
              THEN A.BAL_CLS - A.YUSIN_AM ELSE 0 END)                          AS 여신초과금액계
    ,SUM(CASE WHEN A.YUSIN_AM = 0 THEN 1 ELSE 0 END)                           AS 여신미등록거래처수
    ,판정 = CASE
         WHEN SUM(CASE WHEN A.YUSIN_AM > 0 AND A.BAL_CLS > A.YUSIN_AM THEN 1 ELSE 0 END) > 0
              THEN N'1.★여신 초과 거래처 존재'
         WHEN ABS(SUM(A.UNCLS_AM)) >= 1
              THEN N'2.★미마감 채권 존재 - 마감 필요'
         ELSE N'0.정상' END
FROM   #AR A
;


DROP TABLE #OPN, #LIMIT, #ISU, #CLS, #RCP, #AGE, #AR;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 채권·여신 테이블 실존 (명세서 누락분)
     SELECT name FROM sys.tables
     WHERE name IN ('LOPN_CRISU','LOPN_CRISU_CLS','LCR_ADJUST','LCR_LIMIT','LRCP','LRCP_D');

  -- (2) 여신한도 등록률  ★ 미등록이면 쿼리 B 가 무의미
     SELECT COUNT(*) 전체거래처,
            SUM(CASE WHEN ISNULL(L.YUSIN_AM,0)=0 THEN 1 ELSE 0 END) 여신미등록
     FROM   STRADE S LEFT OUTER JOIN LCR_LIMIT L ON L.CO_CD=S.CO_CD AND L.TR_CD=S.TR_CD
     WHERE  S.CO_CD='1000' AND ISNULL(S.USE_YN,'1')='1' AND S.TR_FG IN ('0','2');

  -- (3) 거래구분(SO_FG) / 수금 모듈구분(RCPAM_FG) 분포  ★ 채권 산식의 전제
     SELECT SO_FG, COUNT(*) FROM LDELIVER WHERE CO_CD='1000' GROUP BY SO_FG;
     SELECT RCPAM_FG, COUNT(*) FROM LRCP_D WHERE CO_CD='1000' GROUP BY RCPAM_FG;
     --> 표준은 SO_FG IN ('0','2','7'), RCPAM_FG='0'. 다른 값이 많으면 무슨 거래인지 확인.

  -- (4) 기초채권 2종 금액 비교
     SELECT '출고기준' 구분, SUM(OPEN_AM) FROM LOPN_CRISU     WHERE CO_CD='1000' AND P_YR='2026'
     UNION ALL
     SELECT '마감기준',      SUM(OPEN_AM) FROM LOPN_CRISU_CLS WHERE CO_CD='1000' AND P_YR='2026';

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **연령분석(쿼리 E)은 근사치**다. 마감건별로 수금을 소거(matching)하는 데이터가 없으면
     정확한 건별 미수 잔액을 낼 수 없다. 본 쿼리는 마감일 기준 발생액을 구간별로 나눈 것이므로
     "어느 시점 매출이 남아 있는가"의 경향만 본다.
     정밀 소거가 필요하면 `LRCP_D.ISU_NB + ISU_SQ`(출고 매칭)로 건별 소거 로직을 추가해야 하며,
     그 전에 매칭률을 먼저 확인할 것.
        SELECT COUNT(*) 전체, SUM(CASE WHEN ISNULL(ISU_NB,'')='' THEN 1 ELSE 0 END) 미매칭
        FROM   LRCP_D WHERE CO_CD='1000';

  2) 선수금(`BEFORE_AM`)을 수금에 합산했다. 선수금을 채권 차감이 아니라 부채로 보는 회계정책이면
     `RCP_AM` 에서 `BEFORE_AM` 을 제외하도록 수정할 것.

  3) 여신한도는 **사업장별**로 등록될 수 있다. @DIV_CD 를 지정하지 않으면 전 사업장 한도가
     합산되므로, 사업장별 여신 통제를 하는 사이트는 반드시 @DIV_CD 를 지정할 것.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   수주진행총괄현황.sql   : 수주 단위 채권 추적 (쿼리 F)
   A02_기표파이프라인.sql : 매출마감 → 전표 → 장부 반영
==============================================================================================*/
