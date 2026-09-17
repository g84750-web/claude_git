/*==============================================================================================
  [ iCUBE ] A-02 / A-03  마감 → 전표 → 장부 파이프라인 현황                          (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 물류·영업 트랜잭션이 회계 전표로 넘어가 장부에 반영되기까지 어느 단계에서
         멈춰 있는지를 건수·금액으로 계량한다. **월 마감 통제의 핵심 리포트.**

     매출  LDELIVER ──→ LSALECLS ──(DOCU_YN/DT/SQ)──→ ADOCUH ──(DOCU_ST)──→ 장부
     매입  LSTOCK   ──→ LPURCLS  ──(DOCU_YN/DT/SQ)──→ ADOCUH ──(DOCU_ST)──→ 장부
     수금  LRCP     ─────────────(DOCU_DT/SQ)──────→ ADOCUH
     지급  LPAY     ─────────────(DOCU_DT/SQ)──────→ ADOCUH

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ 연동 키 ]
  ----------------------------------------------------------------------------------------------
     LSALECLS / LPURCLS . DOCU_YN(기표여부) + DOCU_DT(기표일자) + DOCU_SQ(기표순번)
     LRCP     / LPAY    .                     DOCU_DT           + DOCU_SQ
                                     ↓
     ADOCUH ( CO_CD + ISU_DT + ISU_SQ )   결의일자 + 결의번호
            DOCU_ST 승인구분   DOCU_TY 전표유형   GET_FG 전표원인(연동구분)
     ADOCUD ( + LN_SQ )  DRCR_FG 차대 / ACCT_CD 계정 / ACCT_AM 금액

     * LSALECLS 는 `DOCU_DT_PLUS` / `DOCU_SQ_PLUS` 도 보유(부가세 등 추가전표). @INC_PLUS 로 제어.

  ----------------------------------------------------------------------------------------------
  [ 단계 정의 ]
  ----------------------------------------------------------------------------------------------
     1.출고/입고만   전표 근거 트랜잭션은 있으나 마감이 없음      -> 마감 담당자
     2.마감완료      마감은 됐으나 기표 안 됨 (DOCU_YN <> '1')    -> 회계 기표 담당자
     3.기표완료      기표는 됐으나 ADOCUH 에 전표가 없음          -> 데이터 이상 (조사 필요)
     4.전표생성      전표는 있으나 미승인 (DOCU_ST)               -> 승인권자
     5.장부반영      승인 완료                                     -> 정상
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD     NVARCHAR(4)  = N'1000'
    ,@DIV_CD    NVARCHAR(4)  = NULL           -- 사업장 (NULL = 전체)
    ,@FR_DT     NVARCHAR(8)  = N'20260101'    -- 마감일 기준 FROM
    ,@TO_DT     NVARCHAR(8)  = N'20261231'
    ,@TR_CD     NVARCHAR(10) = NULL           -- 거래처
    ,@INC_PLUS  NVARCHAR(1)  = N'Y'           -- LSALECLS 추가전표(DOCU_*_PLUS) 포함
    ,@APPR_ST   NVARCHAR(1)  = NULL           -- 승인으로 간주할 DOCU_ST 값
                                              --   NULL 이면 'DOCU_ST 가 NULL 이 아니면 전표 존재'로만 판정
                                              --   실 DB 분포 확인 후 지정 (예: '1')
;

DECLARE @SQL NVARCHAR(MAX);

IF OBJECT_ID('tempdb..#PIPE') IS NOT NULL DROP TABLE #PIPE;
CREATE TABLE #PIPE (
     구분     NVARCHAR(10)      -- 매출 / 매입 / 수금 / 지급
    ,CLS_NB   NVARCHAR(12)      -- 마감(전표원인) 번호
    ,CLS_DT   NVARCHAR(8)
    ,CLS_YM   NVARCHAR(6)
    ,DIV_CD   NVARCHAR(4)
    ,TR_CD    NVARCHAR(10)
    ,CLS_AM   DECIMAL(19,4)     -- 마감 합계액
    ,SRC_AM   DECIMAL(19,4)     -- 원천(출고/입고) 금액
    ,DOCU_YN  NVARCHAR(1)
    ,DOCU_DT  NVARCHAR(8)
    ,DOCU_SQ  NUMERIC(5,0)
    ,DOC_ST   NVARCHAR(1)       -- ADOCUH.DOCU_ST
    ,DOC_TY   NVARCHAR(1)
    ,GET_FG   NVARCHAR(2)
    ,DOC_DR   DECIMAL(19,4)     -- 전표 차변합계
    ,DOC_CR   DECIMAL(19,4)     -- 전표 대변합계
    ,PLUS_YN  NVARCHAR(1)       -- 추가전표 여부
);


/*==============================================================================================
  1. 매출마감 → 전표
==============================================================================================*/
INSERT INTO #PIPE (구분, CLS_NB, CLS_DT, CLS_YM, DIV_CD, TR_CD, CLS_AM, SRC_AM,
                   DOCU_YN, DOCU_DT, DOCU_SQ, DOC_ST, DOC_TY, GET_FG, DOC_DR, DOC_CR, PLUS_YN)
SELECT
     N'매출', H.CLS_NB, H.CLS_DT, LEFT(H.CLS_DT,6), H.DIV_CD, H.TR_CD
    ,CAST(ISNULL(D.CLS_AM,0) AS DECIMAL(19,4))
    ,CAST(ISNULL(V.ISU_AM,0) AS DECIMAL(19,4))
    ,ISNULL(H.DOCU_YN, N'0'), H.DOCU_DT, H.DOCU_SQ
    ,A.DOCU_ST, A.DOCU_TY, A.GET_FG, A.DR_AM, A.CR_AM, N'N'
FROM        LSALECLS H WITH (NOLOCK)
OUTER APPLY (SELECT CLS_AM = SUM(CAST(ISNULL(X.CLSH_AM,0) AS DECIMAL(19,4)))
             FROM   LSALECLS_D X WITH (NOLOCK)
             WHERE  X.CO_CD = H.CO_CD AND X.CLS_NB = H.CLS_NB
               AND  ISNULL(X.USE_YN,N'1') = N'1' AND ISNULL(X.EXPIRE_YN,N'1') = N'1') D
OUTER APPLY (SELECT ISU_AM = SUM(CAST(ISNULL(Y.ISUH_AM,0) AS DECIMAL(19,4)))
             FROM   LSALECLS_D X WITH (NOLOCK)
             INNER JOIN LDELIVER_D Y WITH (NOLOCK)
                    ON Y.CO_CD=X.CO_CD AND Y.ISU_NB=X.ISU_NB AND Y.ISU_SQ=X.ISU_SQ
             WHERE  X.CO_CD = H.CO_CD AND X.CLS_NB = H.CLS_NB) V
OUTER APPLY (SELECT TOP 1 HH.DOCU_ST, HH.DOCU_TY, HH.GET_FG
                   ,DR_AM = (SELECT SUM(CAST(ISNULL(DD.ACCT_AM,0) AS DECIMAL(19,4)))
                             FROM ADOCUD DD WITH (NOLOCK)
                             WHERE DD.CO_CD=HH.CO_CD AND DD.ISU_DT=HH.ISU_DT
                               AND DD.ISU_SQ=HH.ISU_SQ AND DD.DRCR_FG=N'1')
                   ,CR_AM = (SELECT SUM(CAST(ISNULL(DD.ACCT_AM,0) AS DECIMAL(19,4)))
                             FROM ADOCUD DD WITH (NOLOCK)
                             WHERE DD.CO_CD=HH.CO_CD AND DD.ISU_DT=HH.ISU_DT
                               AND DD.ISU_SQ=HH.ISU_SQ AND DD.DRCR_FG=N'2')
             FROM   ADOCUH HH WITH (NOLOCK)
             WHERE  HH.CO_CD=H.CO_CD AND HH.ISU_DT=H.DOCU_DT AND HH.ISU_SQ=H.DOCU_SQ) A
WHERE   H.CO_CD  = @CO_CD
  AND   H.CLS_DT BETWEEN @FR_DT AND @TO_DT
  AND   (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
  AND   (@TR_CD  IS NULL OR H.TR_CD  = @TR_CD)
;

-- 매출 추가전표 (부가세 등)
IF @INC_PLUS = N'Y'
INSERT INTO #PIPE (구분, CLS_NB, CLS_DT, CLS_YM, DIV_CD, TR_CD, CLS_AM, SRC_AM,
                   DOCU_YN, DOCU_DT, DOCU_SQ, DOC_ST, DOC_TY, GET_FG, DOC_DR, DOC_CR, PLUS_YN)
SELECT
     N'매출', H.CLS_NB, H.CLS_DT, LEFT(H.CLS_DT,6), H.DIV_CD, H.TR_CD, 0, 0
    ,ISNULL(H.DOCU_YN, N'0'), H.DOCU_DT_PLUS, H.DOCU_SQ_PLUS
    ,A.DOCU_ST, A.DOCU_TY, A.GET_FG, A.DR_AM, A.CR_AM, N'Y'
FROM        LSALECLS H WITH (NOLOCK)
OUTER APPLY (SELECT TOP 1 HH.DOCU_ST, HH.DOCU_TY, HH.GET_FG
                   ,DR_AM = (SELECT SUM(CAST(ISNULL(DD.ACCT_AM,0) AS DECIMAL(19,4)))
                             FROM ADOCUD DD WITH (NOLOCK)
                             WHERE DD.CO_CD=HH.CO_CD AND DD.ISU_DT=HH.ISU_DT
                               AND DD.ISU_SQ=HH.ISU_SQ AND DD.DRCR_FG=N'1')
                   ,CR_AM = (SELECT SUM(CAST(ISNULL(DD.ACCT_AM,0) AS DECIMAL(19,4)))
                             FROM ADOCUD DD WITH (NOLOCK)
                             WHERE DD.CO_CD=HH.CO_CD AND DD.ISU_DT=HH.ISU_DT
                               AND DD.ISU_SQ=HH.ISU_SQ AND DD.DRCR_FG=N'2')
             FROM   ADOCUH HH WITH (NOLOCK)
             WHERE  HH.CO_CD=H.CO_CD AND HH.ISU_DT=H.DOCU_DT_PLUS AND HH.ISU_SQ=H.DOCU_SQ_PLUS) A
WHERE   H.CO_CD  = @CO_CD
  AND   H.CLS_DT BETWEEN @FR_DT AND @TO_DT
  AND   ISNULL(H.DOCU_DT_PLUS, N'') <> N''
  AND   (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
  AND   (@TR_CD  IS NULL OR H.TR_CD  = @TR_CD)
;


/*==============================================================================================
  2. 매입마감 → 전표   (LPURCLS 는 명세서 누락 -> 존재 확인)
==============================================================================================*/
IF OBJECT_ID(N'dbo.LPURCLS', N'U') IS NOT NULL
BEGIN
    SET @SQL = N'
    INSERT INTO #PIPE (구분, CLS_NB, CLS_DT, CLS_YM, DIV_CD, TR_CD, CLS_AM, SRC_AM,
                       DOCU_YN, DOCU_DT, DOCU_SQ, DOC_ST, DOC_TY, GET_FG, DOC_DR, DOC_CR, PLUS_YN)
    SELECT
         N''매입'', H.CLS_NB, H.CLS_DT, LEFT(H.CLS_DT,6), H.DIV_CD, H.TR_CD
        ,CAST(ISNULL(D.CLS_AM,0) AS DECIMAL(19,4))
        ,CAST(ISNULL(V.RCV_AM,0) AS DECIMAL(19,4))
        ,ISNULL(H.DOCU_YN, N''0''), H.DOCU_DT, H.DOCU_SQ
        ,A.DOCU_ST, A.DOCU_TY, A.GET_FG, A.DR_AM, A.CR_AM, N''N''
    FROM        dbo.LPURCLS H WITH (NOLOCK)
    OUTER APPLY (SELECT CLS_AM = SUM(CAST(ISNULL(X.CLSH_AM,0) AS DECIMAL(19,4)))
                 FROM   dbo.LPURCLS_D X WITH (NOLOCK)
                 WHERE  X.CO_CD = H.CO_CD AND X.CLS_NB = H.CLS_NB
                   AND  ISNULL(X.EXPIRE_YN,N''1'') = N''1'') D
    OUTER APPLY (SELECT RCV_AM = SUM(CAST(ISNULL(Y.RCVG_AM,0) AS DECIMAL(19,4)))
                 FROM   dbo.LPURCLS_D X WITH (NOLOCK)
                 INNER JOIN dbo.LSTOCK_D Y WITH (NOLOCK)
                        ON Y.CO_CD=X.CO_CD AND Y.RCV_NB=X.RCV_NB AND Y.RCV_SQ=X.RCV_SQ
                 WHERE  X.CO_CD = H.CO_CD AND X.CLS_NB = H.CLS_NB) V
    OUTER APPLY (SELECT TOP 1 HH.DOCU_ST, HH.DOCU_TY, HH.GET_FG
                       ,DR_AM = (SELECT SUM(CAST(ISNULL(DD.ACCT_AM,0) AS DECIMAL(19,4)))
                                 FROM ADOCUD DD WITH (NOLOCK)
                                 WHERE DD.CO_CD=HH.CO_CD AND DD.ISU_DT=HH.ISU_DT
                                   AND DD.ISU_SQ=HH.ISU_SQ AND DD.DRCR_FG=N''1'')
                       ,CR_AM = (SELECT SUM(CAST(ISNULL(DD.ACCT_AM,0) AS DECIMAL(19,4)))
                                 FROM ADOCUD DD WITH (NOLOCK)
                                 WHERE DD.CO_CD=HH.CO_CD AND DD.ISU_DT=HH.ISU_DT
                                   AND DD.ISU_SQ=HH.ISU_SQ AND DD.DRCR_FG=N''2'')
                 FROM   ADOCUH HH WITH (NOLOCK)
                 WHERE  HH.CO_CD=H.CO_CD AND HH.ISU_DT=H.DOCU_DT AND HH.ISU_SQ=H.DOCU_SQ) A
    WHERE   H.CO_CD  = @p_CO
      AND   H.CLS_DT BETWEEN @p_FR AND @p_TO
      AND   (@p_DIV IS NULL OR H.DIV_CD = @p_DIV)
      AND   (@p_TR  IS NULL OR H.TR_CD  = @p_TR)';
    EXEC sp_executesql @SQL
        ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_FR NVARCHAR(8), @p_TO NVARCHAR(8), @p_TR NVARCHAR(10)'
        ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_FR=@FR_DT, @p_TO=@TO_DT, @p_TR=@TR_CD;
END
ELSE
    PRINT N'[WARN] LPURCLS 없음 - 매입 파이프라인 생략';


/*==============================================================================================
  3. 수금 / 지급 → 전표
==============================================================================================*/
INSERT INTO #PIPE (구분, CLS_NB, CLS_DT, CLS_YM, DIV_CD, TR_CD, CLS_AM, SRC_AM,
                   DOCU_YN, DOCU_DT, DOCU_SQ, DOC_ST, DOC_TY, GET_FG, DOC_DR, DOC_CR, PLUS_YN)
SELECT
     N'수금', H.RCP_NB, H.RCP_DT, LEFT(H.RCP_DT,6), H.DIV_CD, H.TR_CD
    ,CAST(ISNULL(D.AM,0) AS DECIMAL(19,4)), 0
    ,CASE WHEN ISNULL(H.DOCU_DT, N'') <> N'' THEN N'1' ELSE N'0' END
    ,H.DOCU_DT, H.DOCU_SQ
    ,A.DOCU_ST, A.DOCU_TY, A.GET_FG, A.DR_AM, A.CR_AM, N'N'
FROM        LRCP H WITH (NOLOCK)
OUTER APPLY (SELECT AM = SUM(CAST(ISNULL(X.NORMAL_AM,0) + ISNULL(X.BEFORE_AM,0) AS DECIMAL(19,4)))
             FROM   LRCP_D X WITH (NOLOCK)
             WHERE  X.CO_CD = H.CO_CD AND X.RCP_NB = H.RCP_NB
               AND  ISNULL(X.USE_YN,N'1')=N'1' AND ISNULL(X.EXPIRE_YN,N'1')=N'1') D
OUTER APPLY (SELECT TOP 1 HH.DOCU_ST, HH.DOCU_TY, HH.GET_FG
                   ,DR_AM = (SELECT SUM(CAST(ISNULL(DD.ACCT_AM,0) AS DECIMAL(19,4)))
                             FROM ADOCUD DD WITH (NOLOCK)
                             WHERE DD.CO_CD=HH.CO_CD AND DD.ISU_DT=HH.ISU_DT
                               AND DD.ISU_SQ=HH.ISU_SQ AND DD.DRCR_FG=N'1')
                   ,CR_AM = (SELECT SUM(CAST(ISNULL(DD.ACCT_AM,0) AS DECIMAL(19,4)))
                             FROM ADOCUD DD WITH (NOLOCK)
                             WHERE DD.CO_CD=HH.CO_CD AND DD.ISU_DT=HH.ISU_DT
                               AND DD.ISU_SQ=HH.ISU_SQ AND DD.DRCR_FG=N'2')
             FROM   ADOCUH HH WITH (NOLOCK)
             WHERE  HH.CO_CD=H.CO_CD AND HH.ISU_DT=H.DOCU_DT AND HH.ISU_SQ=H.DOCU_SQ) A
WHERE   H.CO_CD  = @CO_CD
  AND   H.RCP_DT BETWEEN @FR_DT AND @TO_DT
  AND   (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
  AND   (@TR_CD  IS NULL OR H.TR_CD  = @TR_CD)

UNION ALL

SELECT
     N'지급', H.PAY_NB, H.PAY_DT, LEFT(H.PAY_DT,6), H.DIV_CD, H.TR_CD
    ,CAST(ISNULL(D.AM,0) AS DECIMAL(19,4)), 0
    ,CASE WHEN ISNULL(H.DOCU_DT, N'') <> N'' THEN N'1' ELSE N'0' END
    ,H.DOCU_DT, H.DOCU_SQ
    ,A.DOCU_ST, A.DOCU_TY, A.GET_FG, A.DR_AM, A.CR_AM, N'N'
FROM        LPAY H WITH (NOLOCK)
OUTER APPLY (SELECT AM = SUM(CAST(ISNULL(X.NORMAL_AM,0) + ISNULL(X.BEFORE_AM,0) AS DECIMAL(19,4)))
             FROM   LPAY_D X WITH (NOLOCK)
             WHERE  X.CO_CD = H.CO_CD AND X.PAY_NB = H.PAY_NB
               AND  ISNULL(X.EXPIRE_YN,N'1')=N'1') D
OUTER APPLY (SELECT TOP 1 HH.DOCU_ST, HH.DOCU_TY, HH.GET_FG
                   ,DR_AM = (SELECT SUM(CAST(ISNULL(DD.ACCT_AM,0) AS DECIMAL(19,4)))
                             FROM ADOCUD DD WITH (NOLOCK)
                             WHERE DD.CO_CD=HH.CO_CD AND DD.ISU_DT=HH.ISU_DT
                               AND DD.ISU_SQ=HH.ISU_SQ AND DD.DRCR_FG=N'1')
                   ,CR_AM = (SELECT SUM(CAST(ISNULL(DD.ACCT_AM,0) AS DECIMAL(19,4)))
                             FROM ADOCUD DD WITH (NOLOCK)
                             WHERE DD.CO_CD=HH.CO_CD AND DD.ISU_DT=HH.ISU_DT
                               AND DD.ISU_SQ=HH.ISU_SQ AND DD.DRCR_FG=N'2')
             FROM   ADOCUH HH WITH (NOLOCK)
             WHERE  HH.CO_CD=H.CO_CD AND HH.ISU_DT=H.DOCU_DT AND HH.ISU_SQ=H.DOCU_SQ) A
WHERE   H.CO_CD  = @CO_CD
  AND   H.PAY_DT BETWEEN @FR_DT AND @TO_DT
  AND   (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
  AND   (@TR_CD  IS NULL OR H.TR_CD  = @TR_CD)
;

CREATE CLUSTERED INDEX IX_PIPE ON #PIPE (구분, CLS_YM, CLS_NB);

PRINT N'[1~3] 파이프라인 대상 : ' + CAST((SELECT COUNT(*) FROM #PIPE) AS NVARCHAR(20)) + N' 건';


/*==============================================================================================
  ** 쿼리 A : 파이프라인 요약  (마감 통제 1화면)
==============================================================================================*/
SELECT
     N'[A] 기표 파이프라인 요약'                    AS REPORT_NM
    ,P.구분
    ,COUNT(*)                                       AS 마감건수
    ,SUM(P.CLS_AM)                                  AS 마감금액

    ,SUM(CASE WHEN P.DOCU_YN = N'1' THEN 1 ELSE 0 END)                       AS 기표건수
    ,SUM(CASE WHEN P.DOCU_YN = N'1' THEN P.CLS_AM ELSE 0 END)                AS 기표금액
    ,SUM(CASE WHEN P.DOCU_YN <> N'1' THEN 1 ELSE 0 END)                      AS 미기표건수
    ,SUM(CASE WHEN P.DOCU_YN <> N'1' THEN P.CLS_AM ELSE 0 END)               AS 미기표금액

    ,SUM(CASE WHEN P.DOC_ST IS NOT NULL THEN 1 ELSE 0 END)                   AS 전표존재건수
    ,SUM(CASE WHEN P.DOCU_YN = N'1' AND P.DOC_ST IS NULL THEN 1 ELSE 0 END)  AS 기표했으나전표없음
    ,SUM(CASE WHEN @APPR_ST IS NOT NULL AND P.DOC_ST = @APPR_ST THEN 1 ELSE 0 END) AS 승인건수

    ,기표율_PCT = CAST(CASE WHEN COUNT(*) <> 0
                            THEN 100.0*SUM(CASE WHEN P.DOCU_YN=N'1' THEN 1 ELSE 0 END)/COUNT(*)
                            END AS DECIMAL(5,1))
    ,전표생성율_PCT = CAST(CASE WHEN SUM(CASE WHEN P.DOCU_YN=N'1' THEN 1 ELSE 0 END) <> 0
                                THEN 100.0*SUM(CASE WHEN P.DOC_ST IS NOT NULL THEN 1 ELSE 0 END)
                                     / SUM(CASE WHEN P.DOCU_YN=N'1' THEN 1 ELSE 0 END)
                                END AS DECIMAL(5,1))
    ,판정 = CASE
         WHEN SUM(CASE WHEN P.DOCU_YN <> N'1' THEN 1 ELSE 0 END) > 0
              THEN N'1.★미기표 존재 - 마감 불가'
         WHEN SUM(CASE WHEN P.DOCU_YN = N'1' AND P.DOC_ST IS NULL THEN 1 ELSE 0 END) > 0
              THEN N'2.★기표했으나 전표 없음 - 조사 필요'
         ELSE N'0.정상' END
FROM   #PIPE P
WHERE  P.PLUS_YN = N'N'
GROUP BY P.구분
ORDER BY P.구분
;


/*==============================================================================================
  ** 쿼리 B : 미기표 마감 리스트  (회계 기표 담당자 작업지시서)
==============================================================================================*/
SELECT
     N'[B] 미기표 마감'                             AS REPORT_NM
    ,P.구분
    ,P.CLS_NB                                       AS 마감번호
    ,P.CLS_DT                                       AS 마감일
    ,D.DIV_NM                                       AS 사업장
    ,P.TR_CD                                        AS 거래처코드
    ,TR.TR_NM                                       AS 거래처명
    ,P.CLS_AM                                       AS 마감금액
    ,P.SRC_AM                                       AS 원천금액
    ,경과일 = DATEDIFF(DAY, CONVERT(DATE, P.CLS_DT), GETDATE())
    ,긴급도 = CASE WHEN DATEDIFF(DAY, CONVERT(DATE,P.CLS_DT), GETDATE()) > 60 THEN N'1.60일 경과'
                   WHEN DATEDIFF(DAY, CONVERT(DATE,P.CLS_DT), GETDATE()) > 30 THEN N'2.30일 경과'
                   ELSE N'3.당월' END
FROM       #PIPE  P
LEFT  JOIN SDIV   D  WITH (NOLOCK) ON D.CO_CD  = @CO_CD AND D.DIV_CD = P.DIV_CD
LEFT  JOIN STRADE TR WITH (NOLOCK) ON TR.CO_CD = @CO_CD AND TR.TR_CD = P.TR_CD
WHERE  P.PLUS_YN = N'N'
  AND  P.DOCU_YN <> N'1'
ORDER BY 긴급도, P.CLS_AM DESC
;


/*==============================================================================================
  ** 쿼리 C : 전표 이상 (기표됐으나 전표 없음 / 미승인 / 차대 불일치)
==============================================================================================*/
SELECT
     N'[C] 전표 이상'                               AS REPORT_NM
    ,이상유형 = CASE
         WHEN P.DOCU_YN = N'1' AND P.DOC_ST IS NULL                THEN N'1.★기표됐으나 전표 없음'
         WHEN @APPR_ST IS NOT NULL AND P.DOC_ST <> @APPR_ST        THEN N'2.전표 미승인'
         WHEN ISNULL(P.DOC_DR,0) <> ISNULL(P.DOC_CR,0)             THEN N'3.★차대 불일치'
         WHEN P.PLUS_YN = N'N' AND ABS(ISNULL(P.CLS_AM,0) - ISNULL(P.DOC_DR,0)) > 1
              AND ISNULL(P.DOC_DR,0) <> 0                          THEN N'4.마감금액 ≠ 전표금액'
         ELSE NULL END
    ,P.구분
    ,P.CLS_NB                                       AS 마감번호
    ,P.CLS_DT                                       AS 마감일
    ,CASE P.PLUS_YN WHEN N'Y' THEN N'추가전표' ELSE N'본전표' END AS 전표구분
    ,TR.TR_NM                                       AS 거래처
    ,P.CLS_AM                                       AS 마감금액
    ,P.DOCU_DT                                      AS 전표일자
    ,P.DOCU_SQ                                      AS 전표번호
    ,P.DOC_ST                                       AS 승인구분
    ,P.DOC_TY                                       AS 전표유형
    ,P.GET_FG                                       AS 연동구분
    ,P.DOC_DR                                       AS 전표차변
    ,P.DOC_CR                                       AS 전표대변
    ,ISNULL(P.DOC_DR,0) - ISNULL(P.DOC_CR,0)        AS 차대차이
    ,ISNULL(P.CLS_AM,0) - ISNULL(P.DOC_DR,0)        AS 마감_전표차이
FROM       #PIPE  P
LEFT  JOIN STRADE TR WITH (NOLOCK) ON TR.CO_CD = @CO_CD AND TR.TR_CD = P.TR_CD
WHERE  (P.DOCU_YN = N'1' AND P.DOC_ST IS NULL)
    OR (@APPR_ST IS NOT NULL AND P.DOC_ST IS NOT NULL AND P.DOC_ST <> @APPR_ST)
    OR (ISNULL(P.DOC_DR,0) <> ISNULL(P.DOC_CR,0))
    OR (P.PLUS_YN = N'N' AND ISNULL(P.DOC_DR,0) <> 0
        AND ABS(ISNULL(P.CLS_AM,0) - ISNULL(P.DOC_DR,0)) > 1)
ORDER BY 이상유형, ABS(ISNULL(P.CLS_AM,0) - ISNULL(P.DOC_DR,0)) DESC
;


/*==============================================================================================
  ** 쿼리 D : 출고/입고 후 마감 누락  (마감 담당자 작업지시서)
     파이프라인 1단계 — 전표 이전에 마감 자체가 안 된 건
==============================================================================================*/
SELECT
     N'[D] 출고 후 매출마감 누락'                   AS REPORT_NM
    ,N'매출'                                        AS 구분
    ,H.ISU_NB                                       AS 출고번호
    ,D.ISU_SQ                                       AS 출고순번
    ,H.ISU_DT                                       AS 출고일
    ,TR.TR_NM                                       AS 거래처
    ,D.ITEM_CD                                      AS 품번
    ,I.ITEM_NM                                      AS 품명
    ,D.ISU_QT                                       AS 출고수량
    ,ISNULL(D.CLS_QT,0)                             AS 마감수량
    ,D.ISU_QT - ISNULL(D.CLS_QT,0)                  AS 미마감수량
    ,D.ISUH_AM                                      AS 출고합계액
    ,경과일 = DATEDIFF(DAY, CONVERT(DATE, H.ISU_DT), GETDATE())
FROM       LDELIVER   H WITH (NOLOCK)
INNER JOIN LDELIVER_D D WITH (NOLOCK) ON D.CO_CD = H.CO_CD AND D.ISU_NB = H.ISU_NB
LEFT  JOIN STRADE     TR WITH (NOLOCK) ON TR.CO_CD = H.CO_CD AND TR.TR_CD = H.TR_CD
LEFT  JOIN SITEM      I  WITH (NOLOCK) ON I.CO_CD = D.CO_CD AND I.ITEM_CD = D.ITEM_CD
WHERE   H.CO_CD  = @CO_CD
  AND   H.ISU_DT BETWEEN @FR_DT AND @TO_DT
  AND   H.SO_FG IN (N'0', N'2', N'7')
  AND   ISNULL(D.USE_YN, N'1') = N'1'
  AND   ISNULL(D.EXPIRE_YN, N'1') = N'1'
  AND   ISNULL(D.ISU_QT,0) - ISNULL(D.CLS_QT,0) <> 0
  AND   (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
  AND   (@TR_CD  IS NULL OR H.TR_CD  = @TR_CD)
ORDER BY 경과일 DESC, D.ISUH_AM DESC
;


/*==============================================================================================
  ** 쿼리 E : 월별 기표율 추이  (마감 프로세스 건전성)
==============================================================================================*/
SELECT
     N'[E] 월별 기표율 추이'                        AS REPORT_NM
    ,P.CLS_YM                                       AS 마감년월
    ,P.구분
    ,COUNT(*)                                       AS 마감건수
    ,SUM(P.CLS_AM)                                  AS 마감금액
    ,SUM(CASE WHEN P.DOCU_YN = N'1' THEN 1 ELSE 0 END)        AS 기표건수
    ,SUM(CASE WHEN P.DOCU_YN <> N'1' THEN 1 ELSE 0 END)       AS 미기표건수
    ,SUM(CASE WHEN P.DOCU_YN <> N'1' THEN P.CLS_AM ELSE 0 END) AS 미기표금액
    ,기표율_PCT = CAST(CASE WHEN COUNT(*) <> 0
                            THEN 100.0*SUM(CASE WHEN P.DOCU_YN=N'1' THEN 1 ELSE 0 END)/COUNT(*)
                            END AS DECIMAL(5,1))
    ,SUM(CASE WHEN P.DOC_ST IS NOT NULL THEN 1 ELSE 0 END)    AS 전표생성건수
FROM   #PIPE P
WHERE  P.PLUS_YN = N'N'
GROUP BY P.CLS_YM, P.구분
ORDER BY P.CLS_YM, P.구분
;


/*==============================================================================================
  ** 쿼리 F : 전체 요약  (마감 가능 여부 1행)
==============================================================================================*/
SELECT
     N'[F] 마감 가능 판정'                          AS REPORT_NM
    ,@FR_DT + N' ~ ' + @TO_DT                       AS 기간
    ,COUNT(*)                                       AS 전체마감건수
    ,SUM(P.CLS_AM)                                  AS 전체마감금액
    ,SUM(CASE WHEN P.DOCU_YN <> N'1' THEN 1 ELSE 0 END)        AS 미기표건수
    ,SUM(CASE WHEN P.DOCU_YN <> N'1' THEN P.CLS_AM ELSE 0 END) AS 미기표금액
    ,SUM(CASE WHEN P.DOCU_YN = N'1' AND P.DOC_ST IS NULL THEN 1 ELSE 0 END) AS 전표없음건수
    ,SUM(CASE WHEN ISNULL(P.DOC_DR,0) <> ISNULL(P.DOC_CR,0) THEN 1 ELSE 0 END) AS 차대불일치건수
    ,전체기표율_PCT = CAST(CASE WHEN COUNT(*) <> 0
                                THEN 100.0*SUM(CASE WHEN P.DOCU_YN=N'1' THEN 1 ELSE 0 END)/COUNT(*)
                                END AS DECIMAL(5,1))
    ,마감판정 = CASE
         WHEN SUM(CASE WHEN P.DOCU_YN <> N'1' THEN 1 ELSE 0 END) > 0
              THEN N'1.★미기표 ' + CAST(SUM(CASE WHEN P.DOCU_YN <> N'1' THEN 1 ELSE 0 END) AS NVARCHAR(10))
                   + N'건 - 기표 후 마감'
         WHEN SUM(CASE WHEN P.DOCU_YN = N'1' AND P.DOC_ST IS NULL THEN 1 ELSE 0 END) > 0
              THEN N'2.★전표 미생성 - 조사 필요'
         WHEN SUM(CASE WHEN ISNULL(P.DOC_DR,0) <> ISNULL(P.DOC_CR,0) THEN 1 ELSE 0 END) > 0
              THEN N'3.★차대 불일치 - 전표 수정 필요'
         ELSE N'0.마감 가능' END
FROM   #PIPE P
WHERE  P.PLUS_YN = N'N'
;


DROP TABLE #PIPE;
GO


/*==============================================================================================
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) 전표 코드값 분포  ★ @APPR_ST 확정에 필요
     SELECT DOCU_ST, DOCU_TY, GET_FG, COUNT(*) 건수
     FROM   ADOCUH WHERE CO_CD='1000' AND ISU_DT BETWEEN '20260101' AND '20261231'
     GROUP BY DOCU_ST, DOCU_TY, GET_FG ORDER BY 4 DESC;
     --> DOCU_ST 에서 '승인'에 해당하는 값을 찾아 @APPR_ST 에 넣는다.
     --  지정하지 않으면 '전표 존재 여부'까지만 판정한다.

  -- (2) 차대구분 코드값  ★ 본 쿼리는 '1'=차변, '2'=대변 가정
     SELECT DRCR_FG, COUNT(*), SUM(ACCT_AM) FROM ADOCUD
     WHERE CO_CD='1000' GROUP BY DRCR_FG;
     --> 다르면 쿼리 내 DRCR_FG=N'1' / N'2' 를 교체할 것.

  -- (3) 기표 연동 컬럼 사용 여부
     SELECT DOCU_YN, COUNT(*) 건수,
            SUM(CASE WHEN ISNULL(DOCU_DT,'')='' THEN 1 ELSE 0 END) 기표일자없음,
            SUM(CASE WHEN ISNULL(DOCU_DT_PLUS,'')<>'' THEN 1 ELSE 0 END) 추가전표있음
     FROM   LSALECLS WHERE CO_CD='1000' GROUP BY DOCU_YN;
     --> 추가전표가 0 이면 @INC_PLUS='N' 으로 실행해도 된다.

  -- (4) 매입마감 헤더 존재 (명세서 누락)
     SELECT name FROM sys.tables WHERE name IN ('LPURCLS','LPURCLS_D');

  [ 활용 ]
  ----------------------------------------------------------------------------------------------
  1) **월 마감 D-3 부터 매일 실행.** 쿼리 F 의 `마감판정` 이 '0.마감 가능' 이 될 때까지
     쿼리 B(미기표) → 쿼리 D(미마감) 순으로 처리한다.

  2) 쿼리 C 의 '3.차대 불일치' 는 전표 자체의 결함이므로 회계에서 즉시 수정해야 한다.
     '4.마감금액 ≠ 전표금액' 은 부가세 별도전표(추가전표) 때문일 수 있으니
     @INC_PLUS='Y' 로 실행해 추가전표까지 합산한 뒤 판단할 것.

  3) 쿼리 E 의 월별 기표율이 지속적으로 100% 미만이면 **기표 프로세스 자체에 병목**이 있다.
     특정 구분(매출/매입/수금/지급)에 몰려 있는지 확인한다.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   전표_관리항목_검증.sql  : 전표에 쓰인 부서·사원·프로젝트 코드 등록 검증
   수주진행총괄현황.sql    : 수주 단위로 본 동일 파이프라인 (쿼리 E)

  [ 성능 인덱스 ]
  ----------------------------------------------------------------------------------------------
   LSALECLS (CO_CD, CLS_DT) INCLUDE (CLS_NB, TR_CD, DIV_CD, DOCU_YN, DOCU_DT, DOCU_SQ)
   LPURCLS  (CO_CD, CLS_DT) INCLUDE (CLS_NB, TR_CD, DIV_CD, DOCU_YN, DOCU_DT, DOCU_SQ)
   ADOCUH   (CO_CD, ISU_DT, ISU_SQ) INCLUDE (DOCU_ST, DOCU_TY, GET_FG)
   ADOCUD   (CO_CD, ISU_DT, ISU_SQ, DRCR_FG) INCLUDE (ACCT_AM)
   LDELIVER_D (CO_CD, ISU_NB) INCLUDE (ISU_QT, CLS_QT, ISUH_AM)
==============================================================================================*/
