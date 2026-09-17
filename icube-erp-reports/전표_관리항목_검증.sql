/*==============================================================================================
  [ iCUBE ] 전표입력 관리항목 구조 분석 및 코드 검증                                 (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : 전표(ADOCUH/ADOCUD)에 실제로 사용된 부서·사원·프로젝트 코드를 전 위치에서 수집하여
         마스터 등록 여부를 검증한다. 데이터 이관(소급 입력) 전 필수 점검.

  DBMS : MS-SQL Server (T-SQL)

  근거 : 아이큐브 전표입력_사용된 모든 부서/사원코드 추출_251224.txt
         아이큐브 전표입력_통합 검증 쿼리(부서,사원 전체)_251224.txt
         아이큐브테이블명세서 (ADOCUH / ADOCUD / SCTRL / SCTRL_D)

  ----------------------------------------------------------------------------------------------
  [ ★ 핵심 : ADOCUD 는 "타입 컬럼"이 "값 컬럼"의 의미를 결정한다 ]
  ----------------------------------------------------------------------------------------------
   전표 디테일의 관리항목은 값만 보면 무슨 코드인지 알 수 없다. 반드시 짝이 되는 타입 컬럼을
   같이 봐야 한다.

     타입 컬럼        값 컬럼      의미                    주요 타입값
     ---------------  -----------  ----------------------  ---------------------------------
     TRCD_TY          (TR_CD)      거래처코드 타입
     DEPTCD_TY        CT_DEPT      사용부서                'C1' = 부서
     PJTCD_TY         PJT_CD       프로젝트                'D1' = 프로젝트 / **'D4' = 사원**
     CTNB_TY          CT_NB        관리번호
     QT_TY            CT_QT        관리수량
     AM_TY            CT_AM        관리금액
     RT_TY            CT_RT        관리율
     DEAL_TY          CT_DEAL      관리구분
     USER1_TY         CT_USER1     유저정의1               SCTRL.CTRL_CD 로 속성 결정
     USER2_TY         CT_USER2     유저정의2               SCTRL.CTRL_CD 로 속성 결정

   ** 가장 중요한 함정 **
     `ADOCUD.PJT_CD` 가 항상 프로젝트인 것이 아니다.
         PJTCD_TY = 'D1'  ->  PJT_CD 는 프로젝트코드
         PJTCD_TY = 'D4'  ->  PJT_CD 는 **사원코드**
     프로젝트별 원가/손익을 ADOCUD 에서 집계할 때 `PJTCD_TY='D1'` 조건을 빼면
     사원코드가 프로젝트로 섞여 들어간다. (반대로 사원 분석 시엔 'D4' 만 봐야 한다)

  ----------------------------------------------------------------------------------------------
  [ SCTRL — 관리항목 마스터 ]
  ----------------------------------------------------------------------------------------------
     CO_CD + CTRL_CD(관리항목코드)
     MODULE_CD  모듈코드          'A' = 회계
     CTRL_FG    관리항목유형      'A'
     CTRL_NM    관리항목명
     EDIT_YN    수정여부          <-- 실질적으로 "값의 속성"을 뜻한다
                                      2 = 사원 속성
                                      6 = 부서 속성
     CTRL_CD 유효 범위 : 'L%' 또는 'M%'   (단 'M9' 는 제외)

     즉 CT_USER1 / CT_USER2 에 담긴 값이 부서인지 사원인지는
     USER1_TY / USER2_TY -> SCTRL.CTRL_CD -> SCTRL.EDIT_YN 으로 판별한다.

  ----------------------------------------------------------------------------------------------
  [ 코드가 등장하는 전체 위치 ]
  ----------------------------------------------------------------------------------------------
     부서 : ADOCUH.DEPT_CD          (헤더 작성부서)
            ADOCUD.CT_DEPT          (디테일 사용부서, DEPTCD_TY='C1')
            ADOCUD.CT_USER1/2       (SCTRL.EDIT_YN=6 인 관리항목)
     사원 : ADOCUH.EMP_CD           (헤더 입력사원)
            ADOCUH.ADMIT_ID         (승인자)
            ADOCUH.INSERT_ID        (입력 ID)
            ADOCUD.PJT_CD           (PJTCD_TY='D4' 인 경우)
            ADOCUD.CT_USER1/2       (SCTRL.EDIT_YN=2 인 관리항목)
     프로젝트 : ADOCUD.PJT_CD       (PJTCD_TY='D1' 인 경우)

     ADOCUH <-> ADOCUD 조인은 **DIV_CD 포함 4키**를 쓴다.
         CO_CD + ISU_DT + ISU_SQ + DIV_CD
==============================================================================================*/

SET NOCOUNT ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD   NVARCHAR(4) = N'1000'        -- 회사코드
    ,@FR_DT   NVARCHAR(8) = N'20180101'    -- 전표 결의일자 FROM
    ,@TO_DT   NVARCHAR(8) = N'20181231'    -- 전표 결의일자 TO
    ,@DIV_CD  NVARCHAR(4) = NULL           -- 사업장 (NULL = 전체)
;

IF OBJECT_ID('tempdb..#CODE') IS NOT NULL DROP TABLE #CODE;


/*==============================================================================================
  1. #CODE : 전표에 사용된 모든 부서·사원·프로젝트 코드 수집
==============================================================================================*/
SELECT TYPE_NM, SRC_COL, CODE_VAL
INTO   #CODE
FROM (
    /* ---------------- 부서 ---------------- */
    SELECT TYPE_NM = N'부서', SRC_COL = N'1.헤더_작성부서', CODE_VAL = H.DEPT_CD
    FROM        ADOCUH H WITH (NOLOCK)
    INNER JOIN  ADOCUD D WITH (NOLOCK)
           ON   H.CO_CD=D.CO_CD AND H.ISU_DT=D.ISU_DT AND H.ISU_SQ=D.ISU_SQ AND H.DIV_CD=D.DIV_CD
    WHERE  D.CO_CD = @CO_CD AND D.ISU_DT BETWEEN @FR_DT AND @TO_DT
      AND  (@DIV_CD IS NULL OR D.DIV_CD = @DIV_CD)

    UNION

    SELECT N'부서', N'2.디테일_사용부서', D.CT_DEPT
    FROM   ADOCUD D WITH (NOLOCK)
    WHERE  D.CO_CD = @CO_CD AND D.ISU_DT BETWEEN @FR_DT AND @TO_DT
      AND  D.DEPTCD_TY = N'C1'
      AND  (@DIV_CD IS NULL OR D.DIV_CD = @DIV_CD)

    UNION

    SELECT N'부서', N'3.관리항목1(부서속성)', D.CT_USER1
    FROM        ADOCUD D WITH (NOLOCK)
    INNER JOIN  SCTRL SC WITH (NOLOCK) ON D.CO_CD = SC.CO_CD AND D.USER1_TY = SC.CTRL_CD
    WHERE  D.CO_CD = @CO_CD AND D.ISU_DT BETWEEN @FR_DT AND @TO_DT
      AND  D.PJTCD_TY = N'D1' AND D.DEPTCD_TY = N'C1'
      AND  SC.MODULE_CD = N'A' AND SC.CTRL_FG = N'A' AND SC.EDIT_YN = 6      -- 부서 속성
      AND  (SC.CTRL_CD LIKE N'L%' OR (SC.CTRL_CD LIKE N'M%' AND SC.CTRL_CD NOT IN (N'M9')))
      AND  (@DIV_CD IS NULL OR D.DIV_CD = @DIV_CD)

    UNION

    SELECT N'부서', N'4.관리항목2(부서속성)', D.CT_USER2
    FROM        ADOCUD D WITH (NOLOCK)
    INNER JOIN  SCTRL SC WITH (NOLOCK) ON D.CO_CD = SC.CO_CD AND D.USER2_TY = SC.CTRL_CD
    WHERE  D.CO_CD = @CO_CD AND D.ISU_DT BETWEEN @FR_DT AND @TO_DT
      AND  D.PJTCD_TY = N'D1' AND D.DEPTCD_TY = N'C1'
      AND  SC.MODULE_CD = N'A' AND SC.CTRL_FG = N'A' AND SC.EDIT_YN = 6
      AND  (SC.CTRL_CD LIKE N'L%' OR (SC.CTRL_CD LIKE N'M%' AND SC.CTRL_CD NOT IN (N'M9')))
      AND  (@DIV_CD IS NULL OR D.DIV_CD = @DIV_CD)

    UNION

    /* ---------------- 사원 ---------------- */
    SELECT N'사원', N'1.헤더_입력사원', H.EMP_CD
    FROM        ADOCUH H WITH (NOLOCK)
    INNER JOIN  ADOCUD D WITH (NOLOCK)
           ON   H.CO_CD=D.CO_CD AND H.ISU_DT=D.ISU_DT AND H.ISU_SQ=D.ISU_SQ AND H.DIV_CD=D.DIV_CD
    WHERE  D.CO_CD = @CO_CD AND D.ISU_DT BETWEEN @FR_DT AND @TO_DT
      AND  (@DIV_CD IS NULL OR D.DIV_CD = @DIV_CD)

    UNION

    SELECT N'사원', N'2.헤더_승인자', H.ADMIT_ID
    FROM        ADOCUH H WITH (NOLOCK)
    INNER JOIN  ADOCUD D WITH (NOLOCK)
           ON   H.CO_CD=D.CO_CD AND H.ISU_DT=D.ISU_DT AND H.ISU_SQ=D.ISU_SQ AND H.DIV_CD=D.DIV_CD
    WHERE  D.CO_CD = @CO_CD AND D.ISU_DT BETWEEN @FR_DT AND @TO_DT
      AND  (@DIV_CD IS NULL OR D.DIV_CD = @DIV_CD)

    UNION

    SELECT N'사원', N'3.헤더_INSERT_ID', H.INSERT_ID
    FROM        ADOCUH H WITH (NOLOCK)
    INNER JOIN  ADOCUD D WITH (NOLOCK)
           ON   H.CO_CD=D.CO_CD AND H.ISU_DT=D.ISU_DT AND H.ISU_SQ=D.ISU_SQ AND H.DIV_CD=D.DIV_CD
    WHERE  D.CO_CD = @CO_CD AND D.ISU_DT BETWEEN @FR_DT AND @TO_DT
      AND  (@DIV_CD IS NULL OR D.DIV_CD = @DIV_CD)

    UNION

    -- ★ PJT_CD 가 사원인 경우 (PJTCD_TY = 'D4')
    SELECT N'사원', N'4.디테일_PJT_CD(D4)', D.PJT_CD
    FROM   ADOCUD D WITH (NOLOCK)
    WHERE  D.CO_CD = @CO_CD AND D.ISU_DT BETWEEN @FR_DT AND @TO_DT
      AND  D.PJTCD_TY = N'D4'
      AND  (@DIV_CD IS NULL OR D.DIV_CD = @DIV_CD)

    UNION

    SELECT N'사원', N'5.관리항목1(사원속성)', D.CT_USER1
    FROM        ADOCUD D WITH (NOLOCK)
    INNER JOIN  SCTRL SC WITH (NOLOCK) ON D.CO_CD = SC.CO_CD AND D.USER1_TY = SC.CTRL_CD
    WHERE  D.CO_CD = @CO_CD AND D.ISU_DT BETWEEN @FR_DT AND @TO_DT
      AND  D.PJTCD_TY = N'D1' AND D.DEPTCD_TY = N'C1'
      AND  SC.MODULE_CD = N'A' AND SC.CTRL_FG = N'A' AND SC.EDIT_YN = 2      -- 사원 속성
      AND  (SC.CTRL_CD LIKE N'L%' OR (SC.CTRL_CD LIKE N'M%' AND SC.CTRL_CD NOT IN (N'M9')))
      AND  (@DIV_CD IS NULL OR D.DIV_CD = @DIV_CD)

    UNION

    SELECT N'사원', N'6.관리항목2(사원속성)', D.CT_USER2
    FROM        ADOCUD D WITH (NOLOCK)
    INNER JOIN  SCTRL SC WITH (NOLOCK) ON D.CO_CD = SC.CO_CD AND D.USER2_TY = SC.CTRL_CD
    WHERE  D.CO_CD = @CO_CD AND D.ISU_DT BETWEEN @FR_DT AND @TO_DT
      AND  D.PJTCD_TY = N'D1' AND D.DEPTCD_TY = N'C1'
      AND  SC.MODULE_CD = N'A' AND SC.CTRL_FG = N'A' AND SC.EDIT_YN = 2
      AND  (SC.CTRL_CD LIKE N'L%' OR (SC.CTRL_CD LIKE N'M%' AND SC.CTRL_CD NOT IN (N'M9')))
      AND  (@DIV_CD IS NULL OR D.DIV_CD = @DIV_CD)

    UNION

    /* ---------------- 프로젝트 ---------------- */
    SELECT N'프로젝트', N'1.디테일_PJT_CD(D1)', D.PJT_CD
    FROM   ADOCUD D WITH (NOLOCK)
    WHERE  D.CO_CD = @CO_CD AND D.ISU_DT BETWEEN @FR_DT AND @TO_DT
      AND  D.PJTCD_TY = N'D1'
      AND  (@DIV_CD IS NULL OR D.DIV_CD = @DIV_CD)
) X
WHERE ISNULL(X.CODE_VAL, N'') <> N''
;
CREATE CLUSTERED INDEX IX_CODE ON #CODE (TYPE_NM, CODE_VAL);


/*==============================================================================================
  ** 쿼리 A : 통합 검증 (부서 + 사원 + 프로젝트)
==============================================================================================*/
SELECT
     N'[A] 전표 사용코드 통합 검증'                 AS REPORT_NM
    ,T.TYPE_NM                                      AS 구분
    ,T.SRC_COL                                      AS 출처
    ,T.CODE_VAL                                     AS 전표입력_코드
    ,등록_명칭 = CASE T.TYPE_NM
                     WHEN N'부서'     THEN D.DEPT_NM
                     WHEN N'사원'     THEN E.KOR_NM
                     WHEN N'프로젝트' THEN P.PJT_NM END
    ,등록여부 = CASE WHEN (T.TYPE_NM=N'부서'     AND D.DEPT_CD IS NOT NULL)
                       OR (T.TYPE_NM=N'사원'     AND E.EMP_CD  IS NOT NULL)
                       OR (T.TYPE_NM=N'프로젝트' AND P.PJT_CD  IS NOT NULL)
                     THEN N'등록' ELSE N'★미등록' END
FROM        #CODE T
LEFT  JOIN  SDEPT D WITH (NOLOCK) ON D.CO_CD=@CO_CD AND T.TYPE_NM=N'부서'     AND T.CODE_VAL=D.DEPT_CD
LEFT  JOIN  SEMP  E WITH (NOLOCK) ON E.CO_CD=@CO_CD AND T.TYPE_NM=N'사원'     AND T.CODE_VAL=E.EMP_CD
LEFT  JOIN  SPJT  P WITH (NOLOCK) ON P.CO_CD=@CO_CD AND T.TYPE_NM=N'프로젝트' AND T.CODE_VAL=P.PJT_CD
ORDER BY 등록여부, T.TYPE_NM, T.SRC_COL, T.CODE_VAL
;


/*==============================================================================================
  ** 쿼리 B : 미등록 코드만 (이관 대상 리스트)
==============================================================================================*/
SELECT
     N'[B] 미등록 코드 (마스터 등록 필요)'          AS REPORT_NM
    ,T.TYPE_NM                                      AS 구분
    ,T.CODE_VAL                                     AS 미등록코드
    ,사용위치 = STUFF((SELECT DISTINCT N', ' + T2.SRC_COL
                       FROM #CODE T2
                       WHERE T2.TYPE_NM = T.TYPE_NM AND T2.CODE_VAL = T.CODE_VAL
                       FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 2, N'')
    ,사용건수 = (SELECT COUNT(*) FROM ADOCUD D WITH (NOLOCK)
                 WHERE D.CO_CD=@CO_CD AND D.ISU_DT BETWEEN @FR_DT AND @TO_DT
                   AND (   (T.TYPE_NM=N'부서'     AND D.DEPTCD_TY=N'C1' AND D.CT_DEPT=T.CODE_VAL)
                        OR (T.TYPE_NM=N'사원'     AND D.PJTCD_TY =N'D4' AND D.PJT_CD =T.CODE_VAL)
                        OR (T.TYPE_NM=N'프로젝트' AND D.PJTCD_TY =N'D1' AND D.PJT_CD =T.CODE_VAL)))
FROM   (SELECT DISTINCT TYPE_NM, CODE_VAL FROM #CODE) T
LEFT  JOIN  SDEPT D WITH (NOLOCK) ON D.CO_CD=@CO_CD AND T.TYPE_NM=N'부서'     AND T.CODE_VAL=D.DEPT_CD
LEFT  JOIN  SEMP  E WITH (NOLOCK) ON E.CO_CD=@CO_CD AND T.TYPE_NM=N'사원'     AND T.CODE_VAL=E.EMP_CD
LEFT  JOIN  SPJT  P WITH (NOLOCK) ON P.CO_CD=@CO_CD AND T.TYPE_NM=N'프로젝트' AND T.CODE_VAL=P.PJT_CD
WHERE  (T.TYPE_NM=N'부서'     AND D.DEPT_CD IS NULL)
    OR (T.TYPE_NM=N'사원'     AND E.EMP_CD  IS NULL)
    OR (T.TYPE_NM=N'프로젝트' AND P.PJT_CD  IS NULL)
ORDER BY T.TYPE_NM, T.CODE_VAL
;


/*==============================================================================================
  ** 쿼리 C : 관리항목(SCTRL) 설정 현황 — 어떤 항목이 부서/사원 속성인가
==============================================================================================*/
SELECT
     N'[C] 관리항목 설정 현황'                      AS REPORT_NM
    ,SC.CTRL_CD                                     AS 관리항목코드
    ,SC.CTRL_NM                                     AS 관리항목명
    ,SC.MODULE_CD                                   AS 모듈
    ,SC.CTRL_FG                                     AS 유형
    ,SC.EDIT_YN                                     AS 속성코드
    ,속성 = CASE SC.EDIT_YN WHEN 2 THEN N'사원'
                            WHEN 6 THEN N'부서'
                            ELSE N'기타(' + CAST(SC.EDIT_YN AS NVARCHAR(10)) + N')' END
    ,SC.REG_DT                                      AS 사용시작일
    ,SC.TO_DT                                       AS 종료일
    ,USER1_사용건수 = (SELECT COUNT(*) FROM ADOCUD D WITH (NOLOCK)
                       WHERE D.CO_CD=@CO_CD AND D.ISU_DT BETWEEN @FR_DT AND @TO_DT
                         AND D.USER1_TY = SC.CTRL_CD)
    ,USER2_사용건수 = (SELECT COUNT(*) FROM ADOCUD D WITH (NOLOCK)
                       WHERE D.CO_CD=@CO_CD AND D.ISU_DT BETWEEN @FR_DT AND @TO_DT
                         AND D.USER2_TY = SC.CTRL_CD)
FROM   SCTRL SC WITH (NOLOCK)
WHERE  SC.CO_CD = @CO_CD
  AND  SC.MODULE_CD = N'A' AND SC.CTRL_FG = N'A'
  AND  (SC.CTRL_CD LIKE N'L%' OR (SC.CTRL_CD LIKE N'M%' AND SC.CTRL_CD NOT IN (N'M9')))
ORDER BY SC.EDIT_YN, SC.CTRL_CD
;


/*==============================================================================================
  ** 쿼리 D : 타입 컬럼 분포 점검  ★ PJT_CD 혼재 여부 확인
     PJTCD_TY 가 'D1'(프로젝트)과 'D4'(사원)로 섞여 있으면
     PJT_CD 를 그냥 집계하는 모든 쿼리가 오염된다.
==============================================================================================*/
SELECT
     N'[D] 타입 컬럼 분포'                          AS REPORT_NM
    ,항목 = N'PJTCD_TY'
    ,타입값 = D.PJTCD_TY
    ,의미   = CASE D.PJTCD_TY WHEN N'D1' THEN N'프로젝트'
                              WHEN N'D4' THEN N'★사원'
                              ELSE N'기타(확인필요)' END
    ,건수   = COUNT(*)
    ,값_고유수 = COUNT(DISTINCT D.PJT_CD)
    ,샘플   = MAX(D.PJT_CD)
FROM   ADOCUD D WITH (NOLOCK)
WHERE  D.CO_CD = @CO_CD AND D.ISU_DT BETWEEN @FR_DT AND @TO_DT
  AND  ISNULL(D.PJT_CD, N'') <> N''
GROUP BY D.PJTCD_TY

UNION ALL

SELECT N'[D] 타입 컬럼 분포', N'DEPTCD_TY', D.DEPTCD_TY
      ,CASE D.DEPTCD_TY WHEN N'C1' THEN N'부서' ELSE N'기타(확인필요)' END
      ,COUNT(*), COUNT(DISTINCT D.CT_DEPT), MAX(D.CT_DEPT)
FROM   ADOCUD D WITH (NOLOCK)
WHERE  D.CO_CD = @CO_CD AND D.ISU_DT BETWEEN @FR_DT AND @TO_DT
  AND  ISNULL(D.CT_DEPT, N'') <> N''
GROUP BY D.DEPTCD_TY

UNION ALL

SELECT N'[D] 타입 컬럼 분포', N'USER1_TY', D.USER1_TY
      ,ISNULL(SC.CTRL_NM, N'(SCTRL 미등록)')
      ,COUNT(*), COUNT(DISTINCT D.CT_USER1), MAX(D.CT_USER1)
FROM   ADOCUD D WITH (NOLOCK)
LEFT  JOIN SCTRL SC WITH (NOLOCK) ON SC.CO_CD=D.CO_CD AND SC.CTRL_CD=D.USER1_TY
WHERE  D.CO_CD = @CO_CD AND D.ISU_DT BETWEEN @FR_DT AND @TO_DT
  AND  ISNULL(D.CT_USER1, N'') <> N''
GROUP BY D.USER1_TY, SC.CTRL_NM

UNION ALL

SELECT N'[D] 타입 컬럼 분포', N'USER2_TY', D.USER2_TY
      ,ISNULL(SC.CTRL_NM, N'(SCTRL 미등록)')
      ,COUNT(*), COUNT(DISTINCT D.CT_USER2), MAX(D.CT_USER2)
FROM   ADOCUD D WITH (NOLOCK)
LEFT  JOIN SCTRL SC WITH (NOLOCK) ON SC.CO_CD=D.CO_CD AND SC.CTRL_CD=D.USER2_TY
WHERE  D.CO_CD = @CO_CD AND D.ISU_DT BETWEEN @FR_DT AND @TO_DT
  AND  ISNULL(D.CT_USER2, N'') <> N''
GROUP BY D.USER2_TY, SC.CTRL_NM
ORDER BY 항목, 타입값
;


/*==============================================================================================
  ** 쿼리 E : 전표 요약 (기간/유형/승인상태)
==============================================================================================*/
SELECT
     N'[E] 전표 요약'                               AS REPORT_NM
    ,LEFT(H.ISU_DT, 6)                              AS 결의년월
    ,H.DOCU_TY                                      AS 전표유형
    ,H.DOCU_ST                                      AS 승인구분
    ,H.GET_FG                                       AS 연동구분
    ,COUNT(DISTINCT CAST(H.ISU_DT AS NVARCHAR(8)) + CAST(H.ISU_SQ AS NVARCHAR(10))) AS 전표건수
    ,COUNT(*)                                       AS 라인수
    ,SUM(CASE WHEN D.DRCR_FG = N'1' THEN CAST(ISNULL(D.ACCT_AM,0) AS DECIMAL(19,4)) ELSE 0 END) AS 차변합계
    ,SUM(CASE WHEN D.DRCR_FG = N'2' THEN CAST(ISNULL(D.ACCT_AM,0) AS DECIMAL(19,4)) ELSE 0 END) AS 대변합계
    ,SUM(CASE WHEN D.DRCR_FG = N'1' THEN CAST(ISNULL(D.ACCT_AM,0) AS DECIMAL(19,4))
              WHEN D.DRCR_FG = N'2' THEN -CAST(ISNULL(D.ACCT_AM,0) AS DECIMAL(19,4))
              ELSE 0 END)                           AS 차대차이
FROM        ADOCUH H WITH (NOLOCK)
INNER JOIN  ADOCUD D WITH (NOLOCK)
       ON   H.CO_CD=D.CO_CD AND H.ISU_DT=D.ISU_DT AND H.ISU_SQ=D.ISU_SQ AND H.DIV_CD=D.DIV_CD
WHERE  H.CO_CD = @CO_CD AND H.ISU_DT BETWEEN @FR_DT AND @TO_DT
  AND  (@DIV_CD IS NULL OR H.DIV_CD = @DIV_CD)
GROUP BY LEFT(H.ISU_DT,6), H.DOCU_TY, H.DOCU_ST, H.GET_FG
ORDER BY 1, 2, 3, 4
;


DROP TABLE #CODE;
GO


/*==============================================================================================
  [ 부록 1 ] 사용 시나리오
  ----------------------------------------------------------------------------------------------
  1) **데이터 이관(소급 입력) 전** : 쿼리 B 로 미등록 코드를 뽑아 마스터부터 등록한다.
     미등록 코드가 있는 상태로 이관하면 전표는 들어가지만 조회·집계에서 명칭이 비고
     부서별/사원별 보고서에서 누락된다.

  2) **전표 품질 점검** : 쿼리 E 의 `차대차이` 가 0 이 아니면 전표 불균형이다.
     단 DRCR_FG 코드값('1'=차변 가정)을 쿼리 D 로 먼저 확인할 것.

  3) **프로젝트별 회계 집계 전** : 쿼리 D 로 `PJTCD_TY` 분포를 본다.
     'D1' 과 'D4' 가 섞여 있으면 프로젝트 집계 쿼리에 반드시 `PJTCD_TY='D1'` 을 넣어야 한다.

  [ 부록 2 ] 다른 산출물에 미치는 영향 ★
  ----------------------------------------------------------------------------------------------
  `수주진행총괄현황.sql` 등에서 ADOCUD 를 집계할 때 아래를 지킬 것.

      -- 프로젝트별 금액 집계 (잘못된 예)
      SELECT PJT_CD, SUM(ACCT_AM) FROM ADOCUD GROUP BY PJT_CD        -- ✗ 사원코드 혼입

      -- 올바른 예
      SELECT PJT_CD, SUM(ACCT_AM) FROM ADOCUD
      WHERE  PJTCD_TY = 'D1'                                          -- ✓
      GROUP BY PJT_CD

  부서 집계도 동일하다. `CT_DEPT` 는 `DEPTCD_TY='C1'` 조건과 함께 써야 한다.

  [ 부록 3 ] 확인이 필요한 항목
  ----------------------------------------------------------------------------------------------
  1) `SCTRL.EDIT_YN` 의 2(사원)/6(부서) 외 다른 값의 의미 — 쿼리 C 로 분포 확인.
  2) `ADOCUD.DRCR_FG` 차대 코드값 — 본 쿼리는 '1'=차변, '2'=대변으로 가정.
  3) `ADOCUH.DOCU_ST`(승인구분) / `DOCU_TY`(전표유형) / `GET_FG`(연동구분) 코드값 —
     쿼리 E 결과로 실제 분포를 보고 라벨을 확정할 것.
  4) `PJTCD_TY` 의 'D1'/'D4' 외 값이 있으면 무엇인지 확인 (거래처·관리번호 등일 수 있음).
  5) 본 쿼리는 `SCTRL`(관리내역 상위)만 사용한다. 관리항목의 **값 목록**은 `SCTRL_D`(관리내역
     디테일)에 있으므로, 값 자체의 유효성까지 검증하려면 `SCTRL_D` 조인이 추가로 필요하다.

  [ 부록 4 ] 성능
  ----------------------------------------------------------------------------------------------
     ADOCUH (CO_CD, ISU_DT, ISU_SQ, DIV_CD)
     ADOCUD (CO_CD, ISU_DT, ISU_SQ, DIV_CD) INCLUDE (PJT_CD, PJTCD_TY, CT_DEPT, DEPTCD_TY,
                                                     CT_USER1, USER1_TY, CT_USER2, USER2_TY,
                                                     DRCR_FG, ACCT_AM, ACCT_CD)
     SCTRL  (CO_CD, CTRL_CD)

  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------

  -- (1) ★★ PJTCD_TY 분포. 같은 PJT_CD 컬럼이 타입에 따라 프로젝트도 되고 사원도 된다
     SELECT PJTCD_TY, COUNT(*), COUNT(DISTINCT PJT_CD), MAX(PJT_CD) 샘플
     FROM   ADOCUD WHERE CO_CD='1000' AND ISNULL(PJT_CD,'')<>'' GROUP BY PJTCD_TY;
     --> 'D1'=프로젝트, 'D4'=사원. D4 샘플이 사원번호처럼 보이는지 눈으로 확인할 것.

  -- (2) 관리항목 마스터의 속성 구분
     SELECT CTRL_CD, EDIT_YN, COUNT(*) FROM SCTRL WHERE CO_CD='1000' GROUP BY CTRL_CD, EDIT_YN;
     --> EDIT_YN 2 = 사원속성, 6 = 부서속성.

  -- (3) 관리항목을 아예 쓰지 않는 사이트인지 먼저 본다. 전부 공백이면 이 검증은 불필요하다
     SELECT SUM(CASE WHEN ISNULL(CT_DEPT,'')<>'' THEN 1 ELSE 0 END) 부서기재
           ,SUM(CASE WHEN ISNULL(PJT_CD ,'')<>'' THEN 1 ELSE 0 END) 프로젝트기재
     FROM   ADOCUD WHERE CO_CD='1000';

  [ 한계 ]
  ----------------------------------------------------------------------------------------------

  1) **마스터 등록 여부만 본다.** 코드가 존재한다는 것과 그 전표에 그 코드가 맞게 찍혔다는
     것은 다르다. 잘못된 부서로 찍힌 전표는 여기서 걸러지지 않는다.

  2) **관리항목 컬럼은 사이트별 커스터마이즈가 잦다.** `CT_USER1`/`CT_USER2` 가 무엇을
     의미하는지는 사이트 정의를 봐야 하며, 타입 컬럼 없이 값만 보고 판단하면 안 된다.

  3) **삭제·비활성된 마스터를 참조하는 과거 전표는 미등록으로 잡힌다.** 이관 대상 기간의
     전표라면 당시 기준으로 유효했을 수 있으므로, 건수만 보고 오류로 단정하지 말 것.

  4) **이 검증은 소급 입력(이관) 전 점검용**이다. 운영 중 전표는 입력 시점에 마스터가
     강제되므로 대개 문제가 없다. 이관 데이터에 집중해 볼 것.

==============================================================================================*/
