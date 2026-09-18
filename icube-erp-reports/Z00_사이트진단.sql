/*==============================================================================================
  [ iCUBE ] Z-00  사이트 적용 진단                                                   (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : **신규 사이트에 45개 리포트를 적용하기 전, 이 파일 하나만 돌리면 된다.**
         각 리포트의 [도입 전 확인] 항목 중 **공통 전제**를 한 번에 검사하고,
         마지막에 **리포트별 사용가능 판정 매트릭스**를 출력한다.

  DBMS : MS-SQL Server (T-SQL)
  소요 : 대형 DB 기준 1~3분 (읽기 전용. 데이터를 변경하지 않는다)

  ----------------------------------------------------------------------------------------------
  [ 검사 단계 ]
  ----------------------------------------------------------------------------------------------
     0단계  ★ 엔진 버전         2008 R2 면 24개가 구문 오류로 실행 불가
     1단계  테이블 실존          어떤 리포트를 쓸 수 있는가
     2단계  코드값 해석 ★★      EXPIRE_YN / DOC_ST / SO_FG … — 틀리면 전부 무의미
     3단계  마스터 등록률        리드타임·안전재고·단가·BOM
     4단계  문서 간 연결률       수주→지시, 청구→발주, 출고→수주 …
     5단계  모듈 운영 여부       원가·평가·계획·수출·외주·품질·LOT
     6단계  ★ 리포트별 판정 매트릭스

  ----------------------------------------------------------------------------------------------
  [ 사용법 ]
  ----------------------------------------------------------------------------------------------
     ① @CO_CD / @DIV_CD / @P_YR 만 사이트 값으로 바꾼다
     ② 전체 실행
     ③ **6단계 매트릭스를 먼저 본다** — '사용가능' 리포트부터 적용
     ④ '수정필요' 는 비고의 지시대로 해당 파일을 고친 뒤 적용
     ⑤ 2단계 결과가 이 산출물군의 전제와 다르면 **전 파일 일괄 수정이 먼저**다
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS OFF;

/*==============================================================================================
  0. 파라미터  ★ 여기만 바꾸면 된다
==============================================================================================*/
DECLARE
     @CO_CD   NVARCHAR(4) = N'1000'
    ,@DIV_CD  NVARCHAR(4) = N'1000'      -- NULL 이면 전 사업장
    ,@P_YR    NVARCHAR(4) = N'2026'
;
DECLARE @FR_DT NVARCHAR(8) = @P_YR + N'0101';
DECLARE @TO_DT NVARCHAR(8) = @P_YR + N'1231';
DECLARE @SQL NVARCHAR(MAX);

IF OBJECT_ID('tempdb..#T') IS NOT NULL DROP TABLE #T;   -- 테이블 실존
IF OBJECT_ID('tempdb..#R') IS NOT NULL DROP TABLE #R;   -- 검사 결과

CREATE TABLE #T (TB NVARCHAR(50), 구분 NVARCHAR(20), 필수 NCHAR(1), 존재 NCHAR(1), 건수 BIGINT);
CREATE TABLE #R (
     STG   INT
    ,SEQ   INT IDENTITY(1,1)
    ,CAT   NVARCHAR(30)
    ,ITEM  NVARCHAR(60)
    ,VAL   NVARCHAR(100)
    ,LEVEL NVARCHAR(10)         -- 치명 / 경고 / 정보
    ,NOTE  NVARCHAR(300)
);


/*==============================================================================================
  0단계 : ★ DBMS 엔진 버전 — 다른 무엇보다 이것이 먼저다
  ----------------------------------------------------------------------------------------------
  iCUBE 신규 설치는 SQL Server 2012 지만, 오래된 사이트는 2008 R2 로 남아 있다.
  2012 에서 들어온 구문은 2008 R2 에서 **구문 오류**로 거부된다 — 호환성 수준과 무관하다.

      · LAG() / LEAD()                    전기 대비 증감
      · 집계함수 + OVER(ORDER BY ...)     누적합·누적비율   ← 2008 R2 는 PARTITION BY 만 허용
      · ROWS / RANGE BETWEEN 프레임       이동평균·누계
      · PERCENTILE_CONT()                 중앙값·사분위
      · EOMONTH()                         월말일

  46개 중 24개가 여기 걸린다. **테이블이 다 있어도 실행 자체가 되지 않는다.**
  호환성 수준(compatibility_level)은 별개 축이다. 80(2000 모드)이면 엔진이 2008 R2 여도
  OVER() · CROSS/OUTER APPLY · CTE · EXCEPT 가 전부 막힌다.
==============================================================================================*/
DECLARE @VER     NVARCHAR(30) = CONVERT(NVARCHAR(30), SERVERPROPERTY('ProductVersion'));
-- 버전 문자열을 못 읽으면 0 으로 둔다. 조용히 '문제없음'으로 흐르는 쪽보다
-- 경보를 울리고 사람이 위의 버전 문자열을 직접 보게 하는 쪽이 안전하다.
DECLARE @VER_MAJ INT          = ISNULL(CAST(PARSENAME(@VER, 4) AS INT), 0);
DECLARE @EDITION NVARCHAR(60) = CONVERT(NVARCHAR(60), SERVERPROPERTY('Edition'));
DECLARE @COMPAT  INT          = (SELECT compatibility_level FROM sys.databases WHERE database_id = DB_ID());

INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE)
SELECT 0, N'엔진', N'SQL Server 버전'
      ,@VER + N' (' + CONVERT(NVARCHAR(20), SERVERPROPERTY('ProductLevel')) + N')'
      ,CASE WHEN @VER_MAJ >= 11 THEN N'정보' ELSE N'치명' END
      ,CASE WHEN @VER_MAJ >= 11
            THEN N'2012 이상 - 46개 전부 실행 가능'
            ELSE N'★ 2008 R2 이하 - 2012 전용 구문을 쓰는 24개가 실행되지 않는다. 출력 3 의 ''X 엔진버전'' 을 볼 것' END;

INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE)
SELECT 0, N'엔진', N'호환성 수준 (compatibility_level)', CAST(@COMPAT AS NVARCHAR(10))
      ,CASE WHEN @COMPAT >= 90 THEN N'정보' ELSE N'치명' END
      ,CASE WHEN @COMPAT >= 90
            THEN N'90 이상 - 윈도우 함수 / APPLY / CTE / EXCEPT 사용 가능'
            ELSE N'★ 80(SQL 2000 모드) - OVER() · APPLY · CTE · EXCEPT 가 전부 구문 오류. 대부분의 리포트를 쓸 수 없다' END;

INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE)
SELECT 0, N'엔진', N'에디션', @EDITION
      ,CASE WHEN @EDITION LIKE N'Express%' THEN N'경고' ELSE N'정보' END
      ,CASE WHEN @EDITION LIKE N'Express%'
            THEN N'Express - DB 당 10GB · 메모리 1GB · 코어 4 · SQL Agent 없음. 야간 배치는 Windows 작업 스케줄러 + sqlcmd 로'
            ELSE N'자원 제한 없음' END;

/*  2012 전용 구문을 쓰는 24개 — tools/lint_icube_sql.py 의 ENV002 규칙이 산출한 목록이다.
    각 파일 헤더의 'DBMS : MS-SQL Server 2012 이상' 줄과 1:1 로 대응한다.
    파일을 고치면 린터가 헤더와의 불일치를 잡아내므로 이 목록도 함께 갱신할 것.        */
IF OBJECT_ID('tempdb..#V12') IS NOT NULL DROP TABLE #V12;
-- COLLATE DATABASE_DEFAULT : #V12 는 tempdb(서버 정렬)에 만들어지는데 아래 매트릭스의
-- 파일명은 DB 정렬을 따르는 리터럴이다. 둘이 다르면 조인에서 정렬 충돌 오류가 난다.
CREATE TABLE #V12 (파일 NVARCHAR(80) COLLATE DATABASE_DEFAULT PRIMARY KEY, 사유 NVARCHAR(120));
INSERT INTO #V12 (파일, 사유) VALUES
     (N'A05_자금수지_전망.sql'     , N'PERCENTILE_CONT(), 집계 OVER(ORDER BY), 프레임 ROWS/RANGE')
    ,(N'A06_프로젝트별손익_회계.sql'  , N'집계 OVER(ORDER BY), 프레임 ROWS/RANGE')
    ,(N'C02_당기재료비_분석.sql'    , N'집계 OVER(ORDER BY), 프레임 ROWS/RANGE')
    ,(N'C03_제품별_원가구성.sql'    , N'집계 OVER(ORDER BY), 프레임 ROWS/RANGE')
    ,(N'C04_표준원가_차이분석.sql'   , N'집계 OVER(ORDER BY)')
    ,(N'C05_매출이익_분석.sql'     , N'LAG()')
    ,(N'C07_원가차수_마감점검.sql'   , N'EOMONTH(), LAG()')
    ,(N'E02_수주출하_리드타임분석.sql' , N'LAG(), PERCENTILE_CONT()')
    ,(N'M01_작업지시_진행현황.sql'   , N'LAG()')
    ,(N'M02_생산일보_생산성.sql'    , N'LAG(), 집계 OVER(ORDER BY), 프레임 ROWS/RANGE')
    ,(N'M05_자재_청구출고사용_현황.sql', N'집계 OVER(ORDER BY)')
    ,(N'M06_불량파레토_품질KPI.sql' , N'LAG(), 집계 OVER(ORDER BY), 프레임 ROWS/RANGE')
    ,(N'M11_생산계획대비실적.sql'    , N'LAG()')
    ,(N'P02_발주납기준수_KPI.sql'  , N'LAG()')
    ,(N'P04_재고수불_회전율분석.sql'  , N'집계 OVER(ORDER BY), 프레임 ROWS/RANGE')
    ,(N'P07_매입단가_추이분석.sql'   , N'LAG()')
    ,(N'P10_재고조정_현황.sql'     , N'LAG()')
    ,(N'S03_납기준수율_KPI.sql'   , N'LAG(), 집계 OVER(ORDER BY)')
    ,(N'S04_매출수금_채권KPI.sql'  , N'집계 OVER(ORDER BY), 프레임 ROWS/RANGE')
    ,(N'S09_영업계획대비_실적.sql'   , N'집계 OVER(ORDER BY), 프레임 ROWS/RANGE')
    ,(N'S11_수출현황.sql'        , N'LAG()')
    ,(N'S12_거래처단가_이력.sql'    , N'LAG()')
    ,(N'생산지시별_작업수율현황.sql'    , N'LAG(), 집계 OVER(ORDER BY)')
    ,(N'원자재수급총괄현황_MRP.sql'   , N'집계 OVER(ORDER BY)')
;

/*==============================================================================================
  1단계 : 테이블 실존
==============================================================================================*/
INSERT INTO #T (TB, 구분, 필수) VALUES
 (N'SITEM'         ,N'마스터',N'1'),(N'STRADE'      ,N'마스터',N'1')
,(N'SEMP'          ,N'마스터',N'1'),(N'SDEPT'       ,N'마스터',N'1')
,(N'SWH'           ,N'마스터',N'0'),(N'SLC'         ,N'마스터',N'0')
,(N'SPJT'          ,N'마스터',N'0'),(N'SACCT'       ,N'마스터',N'0')
,(N'SPROC'         ,N'마스터',N'0'),(N'SWC'         ,N'마스터',N'0')
,(N'SBOM_WF'       ,N'BOM'   ,N'0'),(N'SBOM'        ,N'BOM'   ,N'0')
,(N'SBOM_WF_B'     ,N'BOM'   ,N'0')
,(N'LSO'           ,N'영업'  ,N'1'),(N'LSO_D'       ,N'영업'  ,N'1')
,(N'LDELIVER'      ,N'영업'  ,N'1'),(N'LDELIVER_D'  ,N'영업'  ,N'1')
,(N'LSALECLS'      ,N'영업'  ,N'1'),(N'LSALECLS_D'  ,N'영업'  ,N'1')
,(N'LRCP'          ,N'영업'  ,N'1'),(N'LRCP_D'      ,N'영업'  ,N'1')
,(N'LOPN_CRISU'    ,N'영업'  ,N'0'),(N'LOPN_CRISU_CLS',N'영업',N'0')
,(N'LCR_ADJUST'    ,N'영업'  ,N'0'),(N'LCR_LIMIT'   ,N'영업'  ,N'0')
,(N'LCUSTM_UM'     ,N'영업'  ,N'0'),(N'LEBL'        ,N'영업'  ,N'0')
,(N'LEBL_D'        ,N'영업'  ,N'0'),(N'LFORECST_SLS_D',N'영업',N'0')
,(N'SBILL'         ,N'영업'  ,N'0')
,(N'LPUR_REQ'      ,N'구매'  ,N'0'),(N'LPUR_REQ_D'  ,N'구매'  ,N'0')
,(N'LPO'           ,N'구매'  ,N'1'),(N'LPO_D'       ,N'구매'  ,N'1')
,(N'LSTOCK'        ,N'구매'  ,N'1'),(N'LSTOCK_D'    ,N'구매'  ,N'1')
,(N'LPURCLS'       ,N'구매'  ,N'1'),(N'LPURCLS_D'   ,N'구매'  ,N'1')
,(N'LPAY'          ,N'구매'  ,N'0'),(N'LPAY_D'      ,N'구매'  ,N'0')
,(N'LOPN_PAY'      ,N'구매'  ,N'0'),(N'ABILLDEB'    ,N'구매'  ,N'0')
,(N'LINVTORY'      ,N'재고'  ,N'1'),(N'LINVTORY_D'  ,N'재고'  ,N'0')
,(N'LINV_WIP'      ,N'재고'  ,N'0'),(N'LINV_MVFIFO' ,N'재고'  ,N'0')
,(N'LINV_MVFIFO_WK',N'재고'  ,N'0'),(N'LINV_TAV'    ,N'재고'  ,N'0')
,(N'LADJUST'       ,N'재고'  ,N'0'),(N'LADJUST_D'   ,N'재고'  ,N'0')
,(N'LINVINSP_WIP'  ,N'재고'  ,N'0'),(N'LSTKMOVE'    ,N'재고'  ,N'0')
,(N'LWO_WF'        ,N'생산'  ,N'1'),(N'LWO_WF_D'    ,N'생산'  ,N'0')
,(N'LWO_REQ_WF'    ,N'생산'  ,N'1'),(N'LORCV_H'     ,N'생산'  ,N'1')
,(N'LPRDINWH'      ,N'생산'  ,N'1'),(N'LMTL_USE'    ,N'생산'  ,N'0')
,(N'LWIPIO'        ,N'생산'  ,N'0'),(N'LMPS'        ,N'생산'  ,N'0')
,(N'LOCLS_H'       ,N'생산'  ,N'0'),(N'LOCLS_D'     ,N'생산'  ,N'0')
,(N'LQC_INSP_D'    ,N'품질'  ,N'0'),(N'LBAD'        ,N'품질'  ,N'0')
,(N'LBADGRP'       ,N'품질'  ,N'0')
,(N'CIV_CHASU'     ,N'원가'  ,N'0'),(N'CIV_PRD_TAV' ,N'원가'  ,N'0')
,(N'CIV_PRD_TAV_D' ,N'원가'  ,N'0'),(N'CIV_CONVCST' ,N'원가'  ,N'0')
,(N'CIV_OE'        ,N'원가'  ,N'0'),(N'CIV_DIST_ITEM',N'원가' ,N'0')
,(N'CIV_TAV'       ,N'원가'  ,N'0'),(N'CIV_LBR_AM'  ,N'원가'  ,N'0')
,(N'ADOCUH'        ,N'회계'  ,N'0'),(N'ADOCUD'      ,N'회계'  ,N'0')
,(N'LCTRL_MGM_D'   ,N'회계'  ,N'0');

UPDATE #T SET 존재 = CASE WHEN OBJECT_ID(N'dbo.' + TB) IS NOT NULL THEN N'O' ELSE N'X' END;

-- 필수 테이블 누락 판정
INSERT INTO #R (STG, CAT, ITEM, VAL, LEVEL, NOTE)
SELECT 1, N'테이블 실존', T.TB + N' (' + T.구분 + N')', N'없음', N'치명'
      ,N'필수 테이블 누락 - 해당 모듈 리포트 전체 사용 불가'
FROM   #T T WHERE T.필수 = N'1' AND T.존재 = N'X';

INSERT INTO #R (STG, CAT, ITEM, VAL, LEVEL, NOTE)
SELECT 1, N'테이블 실존', N'필수 테이블', CAST(SUM(CASE WHEN 존재=N'O' THEN 1 ELSE 0 END) AS NVARCHAR(10))
       + N'/' + CAST(COUNT(*) AS NVARCHAR(10))
      ,CASE WHEN SUM(CASE WHEN 존재=N'X' THEN 1 ELSE 0 END) = 0 THEN N'정보' ELSE N'치명' END
      ,N'필수 테이블이 모두 있어야 기본 리포트가 동작한다'
FROM   #T WHERE 필수 = N'1';

INSERT INTO #R (STG, CAT, ITEM, VAL, LEVEL, NOTE)
SELECT 1, N'테이블 실존', N'선택 테이블 (' + 구분 + N')'
      ,CAST(SUM(CASE WHEN 존재=N'O' THEN 1 ELSE 0 END) AS NVARCHAR(10)) + N'/' + CAST(COUNT(*) AS NVARCHAR(10))
      ,N'정보', N'없으면 해당 기능 리포트만 제외된다'
FROM   #T WHERE 필수 = N'0' GROUP BY 구분;


/*==============================================================================================
  2단계 : 코드값 해석  ★★ 이 산출물군 전체의 전제
==============================================================================================*/
-- EXPIRE_YN — 수주
IF OBJECT_ID(N'dbo.LSO_D') IS NOT NULL
BEGIN
    DECLARE @E1 DECIMAL(5,1), @E0 DECIMAL(5,1);
    SELECT
         @E1 = CAST(SUM(CASE WHEN ISNULL(EXPIRE_YN,N'1')=N'1' AND SO_QT-ISNULL(ISU_QT,0) > 0 THEN 1.0 ELSE 0 END)
                    / NULLIF(SUM(CASE WHEN ISNULL(EXPIRE_YN,N'1')=N'1' THEN 1.0 ELSE 0 END),0) * 100 AS DECIMAL(5,1))
        ,@E0 = CAST(SUM(CASE WHEN ISNULL(EXPIRE_YN,N'1')=N'0' AND SO_QT-ISNULL(ISU_QT,0) > 0 THEN 1.0 ELSE 0 END)
                    / NULLIF(SUM(CASE WHEN ISNULL(EXPIRE_YN,N'1')=N'0' THEN 1.0 ELSE 0 END),0) * 100 AS DECIMAL(5,1))
    FROM   LSO_D WITH (NOLOCK) WHERE CO_CD = @CO_CD;

    INSERT INTO #R (STG, CAT, ITEM, VAL, LEVEL, NOTE)
    VALUES (2, N'★코드값', N'EXPIRE_YN 해석 (LSO_D)'
           ,N'''1''잔량율 ' + ISNULL(CAST(@E1 AS NVARCHAR(10)),N'?') + N'% / ''0''잔량율 ' + ISNULL(CAST(@E0 AS NVARCHAR(10)),N'?') + N'%'
           ,CASE WHEN ISNULL(@E1,0) >= ISNULL(@E0,0) THEN N'정보' ELSE N'치명' END
           ,CASE WHEN ISNULL(@E1,0) >= ISNULL(@E0,0)
                 THEN N'전제대로 ''1''=진행. 전 파일 그대로 사용 가능'
                 ELSE N'★★ 반대다. ''0''이 진행이면 45개 파일의 EXPIRE_YN 조건을 전부 뒤집어야 한다' END);
END

-- DOC_ST 체계
IF OBJECT_ID(N'dbo.LWO_WF') IS NOT NULL
BEGIN
    DECLARE @DS NVARCHAR(100);
    SELECT @DS = STUFF((SELECT N',' + ISNULL(DOC_ST,N'null')
                        FROM (SELECT DISTINCT DOC_ST FROM LWO_WF WITH (NOLOCK) WHERE CO_CD=@CO_CD) X
                        ORDER BY DOC_ST FOR XML PATH(N''), TYPE).value(N'.',N'NVARCHAR(MAX)'),1,1,N'');
    INSERT INTO #R (STG, CAT, ITEM, VAL, LEVEL, NOTE)
    VALUES (2, N'★코드값', N'DOC_ST 코드 체계 (LWO_WF)', ISNULL(@DS, N'(없음)')
           ,CASE WHEN @DS LIKE N'%2%' THEN N'정보' ELSE N'경고' END
           ,CASE WHEN @DS LIKE N'%2%'
                 THEN N'2 존재 → UDR 해석(0계획/1확정/2마감). M-01 기본값 그대로'
                 ELSE N'2 없음 → API 해석(0미처리/1처리) 가능성. M01 쿼리 G 로 확인 후 라벨 수정' END);
END

-- SO_FG (채권 대상 거래구분)
IF OBJECT_ID(N'dbo.LDELIVER') IS NOT NULL
BEGIN
    DECLARE @SF NVARCHAR(200), @SF_ETC INT;
    SELECT @SF = STUFF((SELECT N',' + ISNULL(SO_FG,N'null') + N'(' + CAST(C AS NVARCHAR(10)) + N')'
                        FROM (SELECT SO_FG, C=COUNT(*) FROM LDELIVER WITH (NOLOCK)
                              WHERE CO_CD=@CO_CD GROUP BY SO_FG) X
                        ORDER BY C DESC FOR XML PATH(N''), TYPE).value(N'.',N'NVARCHAR(MAX)'),1,1,N'');
    SELECT @SF_ETC = COUNT(*) FROM LDELIVER WITH (NOLOCK)
    WHERE CO_CD=@CO_CD AND ISNULL(SO_FG,N'') NOT IN (N'0',N'2',N'7');

    INSERT INTO #R (STG, CAT, ITEM, VAL, LEVEL, NOTE)
    VALUES (2, N'★코드값', N'SO_FG 분포 (LDELIVER)', LEFT(ISNULL(@SF,N'(없음)'), 100)
           ,CASE WHEN ISNULL(@SF_ETC,0) = 0 THEN N'정보' ELSE N'경고' END
           ,N'표준 채권대상은 0/2/7. 그 외 ' + CAST(ISNULL(@SF_ETC,0) AS NVARCHAR(10))
          + N'건이 있다면 무슨 거래인지 확인하고 S-06/S-04 의 필터를 조정할 것');
END

-- RCPAM_FG (수금 모듈구분)
IF OBJECT_ID(N'dbo.LRCP_D') IS NOT NULL
BEGIN
    DECLARE @RF DECIMAL(5,1);
    SELECT @RF = CAST(SUM(CASE WHEN ISNULL(RCPAM_FG,N'0')=N'0' THEN 1.0 ELSE 0 END)
                      / NULLIF(COUNT(*),0) * 100 AS DECIMAL(5,1))
    FROM LRCP_D WITH (NOLOCK) WHERE CO_CD = @CO_CD;
    INSERT INTO #R (STG, CAT, ITEM, VAL, LEVEL, NOTE)
    VALUES (2, N'★코드값', N'RCPAM_FG=0 (영업수금) 비율', ISNULL(CAST(@RF AS NVARCHAR(10)),N'?') + N'%'
           ,CASE WHEN ISNULL(@RF,100) >= 80 THEN N'정보' ELSE N'경고' END
           ,N'낮으면 회계 직접수금이 많다는 뜻. S-04/S-06 의 수금 필터 재검토');
END

-- 단종 코드
IF OBJECT_ID(N'dbo.SITEM') IS NOT NULL
BEGIN
    DECLARE @Z INT;
    SELECT @Z = COUNT(*) FROM SITEM WITH (NOLOCK) WHERE CO_CD=@CO_CD AND ISNULL(S_CD,N'')=N'Z00';
    INSERT INTO #R (STG, CAT, ITEM, VAL, LEVEL, NOTE)
    VALUES (2, N'★코드값', N'단종품 S_CD=''Z00''', CAST(ISNULL(@Z,0) AS NVARCHAR(10)) + N'건'
           ,CASE WHEN ISNULL(@Z,0) > 0 THEN N'정보' ELSE N'경고' END
           ,CASE WHEN ISNULL(@Z,0) > 0 THEN N'관례대로 Z00 사용 중. 전 파일의 제외 조건 유효'
                 ELSE N'Z00 이 없다 - 다른 코드로 단종을 관리하면 전 파일의 제외 조건을 바꿔야 한다' END);
END

-- 실적 SUB_TP / BAD_YN
IF OBJECT_ID(N'dbo.LORCV_H') IS NOT NULL
BEGIN
    DECLARE @BAD INT, @SUB INT;
    SELECT @BAD = SUM(CASE WHEN ISNULL(BAD_YN,N'0')=N'1' THEN 1 ELSE 0 END)
          ,@SUB = SUM(CASE WHEN ISNULL(SUB_TP,N'0')=N'1' THEN 1 ELSE 0 END)
    FROM LORCV_H WITH (NOLOCK) WHERE CO_CD=@CO_CD;
    INSERT INTO #R (STG, CAT, ITEM, VAL, LEVEL, NOTE)
    VALUES (2, N'★코드값', N'실적 불량(BAD_YN=1) 건수', CAST(ISNULL(@BAD,0) AS NVARCHAR(10))
           ,CASE WHEN ISNULL(@BAD,0) > 0 THEN N'정보' ELSE N'경고' END
           ,CASE WHEN ISNULL(@BAD,0) > 0 THEN N'불량을 실적으로 등록하는 운영. M-06 사용 가능'
                 ELSE N'불량 실적이 없다 - 다른 방식으로 관리. M-06 양품률이 항상 100%가 된다' END);
    INSERT INTO #R (STG, CAT, ITEM, VAL, LEVEL, NOTE)
    VALUES (2, N'★코드값', N'부산물(SUB_TP=1) 건수', CAST(ISNULL(@SUB,0) AS NVARCHAR(10)), N'정보'
           ,N'부산물이 있으면 양품률 산식에서 분리해야 한다 (전 파일 반영 완료)');
END


/*==============================================================================================
  3단계 : 마스터 등록률
==============================================================================================*/
IF OBJECT_ID(N'dbo.SITEM') IS NOT NULL
BEGIN
    DECLARE @TOT INT, @LEAD DECIMAL(5,1), @SAFE DECIMAL(5,1), @STD DECIMAL(5,1), @LOT INT;
    SELECT @TOT = COUNT(*)
          ,@LEAD = CAST(SUM(CASE WHEN ISNULL(LEAD_DT,0)      <> 0 THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0)*100 AS DECIMAL(5,1))
          ,@SAFE = CAST(SUM(CASE WHEN ISNULL(SAFESTOCK_QT,0) <> 0 THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0)*100 AS DECIMAL(5,1))
          ,@STD  = CAST(SUM(CASE WHEN ISNULL(STD_UM,0)       <> 0 THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0)*100 AS DECIMAL(5,1))
          ,@LOT  = SUM(CASE WHEN ISNULL(LOT_FG,N'0')=N'1' THEN 1 ELSE 0 END)
    FROM SITEM WITH (NOLOCK) WHERE CO_CD=@CO_CD AND ISNULL(USE_YN,N'1')=N'1';

    INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE) VALUES
     (3,N'마스터',N'품목 수',CAST(ISNULL(@TOT,0) AS NVARCHAR(10)),N'정보',N'')
    ,(3,N'마스터',N'리드타임(LEAD_DT) 등록률',ISNULL(CAST(@LEAD AS NVARCHAR(10)),N'?')+N'%'
     ,CASE WHEN ISNULL(@LEAD,0)>=70 THEN N'정보' WHEN ISNULL(@LEAD,0)>=30 THEN N'경고' ELSE N'치명' END
     ,N'P-05 조달불가 판정, E-02 괴리분석, MRP 예정발주일의 근거. 30% 미만이면 MRP 신뢰 불가')
    ,(3,N'마스터',N'안전재고(SAFESTOCK_QT) 등록률',ISNULL(CAST(@SAFE AS NVARCHAR(10)),N'?')+N'%'
     ,CASE WHEN ISNULL(@SAFE,0)>=70 THEN N'정보' WHEN ISNULL(@SAFE,0)>=30 THEN N'경고' ELSE N'치명' END
     ,N'P-05 알람등급 3·9 의 전제. 30% 미만이면 등급 1·2 만 사용할 것')
    ,(3,N'마스터',N'표준단가(STD_UM) 등록률',ISNULL(CAST(@STD AS NVARCHAR(10)),N'?')+N'%'
     ,CASE WHEN ISNULL(@STD,0)>=70 THEN N'정보' ELSE N'경고' END
     ,N'평가 테이블이 없을 때 금액 산출의 대체 소스')
    ,(3,N'마스터',N'LOT 관리 품목수',CAST(ISNULL(@LOT,0) AS NVARCHAR(10))
     ,CASE WHEN ISNULL(@LOT,0)>0 THEN N'정보' ELSE N'경고' END
     ,N'0 이면 P-12 LOT 추적을 쓸 수 없다');
END

-- BOM 등록률
DECLARE @BOMTB NVARCHAR(30) = NULL;
IF    OBJECT_ID(N'dbo.SBOM_WF') IS NOT NULL SET @BOMTB = N'SBOM_WF';
ELSE IF OBJECT_ID(N'dbo.SBOM')  IS NOT NULL SET @BOMTB = N'SBOM';
IF @BOMTB IS NOT NULL
BEGIN
    DECLARE @BR DECIMAL(5,1);
    SET @SQL = N'
        SELECT @o = CAST(SUM(CASE WHEN EXISTS (SELECT 1 FROM dbo.' + @BOMTB + N' B WITH (NOLOCK)
                                               WHERE B.CO_CD=I.CO_CD AND B.ITEM_CD=I.ITEM_CD
                                                 AND ISNULL(B.USE_YN,N''1'')=N''1'')
                                  THEN 1.0 ELSE 0 END) / NULLIF(COUNT(*),0) * 100 AS DECIMAL(5,1))
        FROM   SITEM I WITH (NOLOCK)
        WHERE  I.CO_CD=@p_CO AND ISNULL(I.USE_YN,N''1'')=N''1''
          AND  I.ACCT_FG IN (N''2'',N''4'') AND ISNULL(I.S_CD,N'''')<>N''Z00''';
    BEGIN TRY
        EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @o DECIMAL(5,1) OUTPUT', @p_CO=@CO_CD, @o=@BR OUTPUT;
        INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE)
        VALUES (3,N'마스터',N'BOM 등록률 (제품·반제품)',ISNULL(CAST(@BR AS NVARCHAR(10)),N'?')+N'%'
               ,CASE WHEN ISNULL(@BR,0)>=80 THEN N'정보' WHEN ISNULL(@BR,0)>=40 THEN N'경고' ELSE N'치명' END
               ,N'MRP·표준원가·C-04 의 전제. ' + @BOMTB + N' 사용');
    END TRY BEGIN CATCH END CATCH
END
ELSE
    INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE)
    VALUES (3,N'마스터',N'BOM 테이블',N'없음',N'치명',N'MRP·표준원가·BOM 점검 전부 사용 불가');

-- 여신한도
INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE)
SELECT 3,N'마스터',N'여신한도 소스'
      ,CASE WHEN OBJECT_ID(N'dbo.LCR_LIMIT') IS NOT NULL THEN N'LCR_LIMIT' ELSE N'STRADE(대체)' END
      ,N'정보'
      ,N'S-06 여신 판정. LCR_LIMIT 가 있으면 담보/신용/기타 3단 한도를 쓴다';


/*==============================================================================================
  4단계 : 문서 간 연결률  ★ 조인이 성립하는가
==============================================================================================*/
-- 수주 → 작업지시
IF OBJECT_ID(N'dbo.LWO_WF') IS NOT NULL
BEGIN
    DECLARE @W2S DECIMAL(5,1);
    SELECT @W2S = CAST(SUM(CASE WHEN ISNULL(SO_NB,N'')<>N'' THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0)*100 AS DECIMAL(5,1))
    FROM LWO_WF WITH (NOLOCK) WHERE CO_CD=@CO_CD AND ORD_DT BETWEEN @FR_DT AND @TO_DT;
    INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE)
    VALUES (4,N'연결률',N'수주→작업지시 (LWO_WF.SO_NB)',ISNULL(CAST(@W2S AS NVARCHAR(10)),N'?')+N'%'
           ,CASE WHEN ISNULL(@W2S,0)>=50 THEN N'정보' WHEN ISNULL(@W2S,0)>=20 THEN N'경고' ELSE N'치명' END
           ,N'S-01 수주진행총괄, E-02 리드타임의 생산 경로. 낮으면 계획생산(MTS) 사이트 - M-11 을 쓸 것');
END

-- 청구 → 발주
IF OBJECT_ID(N'dbo.LPO_D') IS NOT NULL
BEGIN
    DECLARE @P2R DECIMAL(5,1);
    SELECT @P2R = CAST(SUM(CASE WHEN ISNULL(REQ_NB,N'')<>N'' THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0)*100 AS DECIMAL(5,1))
    FROM LPO_D WITH (NOLOCK) WHERE CO_CD=@CO_CD;
    INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE)
    VALUES (4,N'연결률',N'청구→발주 (LPO_D.REQ_NB)',ISNULL(CAST(@P2R AS NVARCHAR(10)),N'?')+N'%'
           ,CASE WHEN ISNULL(@P2R,0)>=50 THEN N'정보' ELSE N'경고' END
           ,N'P-01 발주소요일 KPI 의 전제. 낮으면 직발주 중심 - 쿼리 C 만 사용');
END

-- 발주 → 입고
IF OBJECT_ID(N'dbo.LSTOCK_D') IS NOT NULL
BEGIN
    DECLARE @S2P DECIMAL(5,1);
    SELECT @S2P = CAST(SUM(CASE WHEN ISNULL(PO_NB,N'')<>N'' THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0)*100 AS DECIMAL(5,1))
    FROM LSTOCK_D WITH (NOLOCK) WHERE CO_CD=@CO_CD;
    INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE)
    VALUES (4,N'연결률',N'발주→입고 (LSTOCK_D.PO_NB)',ISNULL(CAST(@S2P AS NVARCHAR(10)),N'?')+N'%'
           ,CASE WHEN ISNULL(@S2P,0)>=80 THEN N'정보' ELSE N'경고' END
           ,N'P-01/P-02 의 전제');
END

-- 출고 → 수주
IF OBJECT_ID(N'dbo.LDELIVER_D') IS NOT NULL
BEGIN
    DECLARE @D2S DECIMAL(5,1), @LOTD DECIMAL(5,1);
    SELECT @D2S  = CAST(SUM(CASE WHEN ISNULL(SO_NB ,N'')<>N'' THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0)*100 AS DECIMAL(5,1))
          ,@LOTD = CAST(SUM(CASE WHEN ISNULL(LOT_NB,N'')<>N'' THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0)*100 AS DECIMAL(5,1))
    FROM LDELIVER_D WITH (NOLOCK) WHERE CO_CD=@CO_CD;
    INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE) VALUES
     (4,N'연결률',N'출고→수주 (LDELIVER_D.SO_NB)',ISNULL(CAST(@D2S AS NVARCHAR(10)),N'?')+N'%'
     ,CASE WHEN ISNULL(@D2S,0)>=80 THEN N'정보' ELSE N'경고' END
     ,N'S-02/S-03/S-01 의 전제')
    ,(4,N'연결률',N'출고 LOT 기록률',ISNULL(CAST(@LOTD AS NVARCHAR(10)),N'?')+N'%'
     ,CASE WHEN ISNULL(@LOTD,0)>=50 THEN N'정보' ELSE N'경고' END
     ,N'P-12 정방향 추적의 마지막 단계');
END

-- 수주상세 ISU_QT 정합성
IF OBJECT_ID(N'dbo.LSO_D') IS NOT NULL AND OBJECT_ID(N'dbo.LDELIVER_D') IS NOT NULL
BEGIN
    DECLARE @MIS INT;
    SELECT @MIS = COUNT(*) FROM LSO_D D WITH (NOLOCK)
    WHERE  D.CO_CD=@CO_CD
      AND  ISNULL(D.ISU_QT,0) <> (SELECT ISNULL(SUM(X.ISU_QT),0) FROM LDELIVER_D X WITH (NOLOCK)
                                  WHERE X.CO_CD=D.CO_CD AND X.SO_NB=D.SO_NB AND X.SO_SQ=D.SO_SQ);
    INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE)
    VALUES (4,N'연결률',N'LSO_D.ISU_QT vs 출고원장 불일치',CAST(ISNULL(@MIS,0) AS NVARCHAR(10))+N'건'
           ,CASE WHEN ISNULL(@MIS,0)=0 THEN N'정보' ELSE N'경고' END
           ,N'S-02 쿼리 G 로 원인 유형을 분류할 것. 미납 잔량 산식의 신뢰도에 직결');
END

-- 실적 공정/작업자
IF OBJECT_ID(N'dbo.LORCV_H') IS NOT NULL
BEGIN
    DECLARE @PRC DECIMAL(5,1), @EMP DECIMAL(5,1);
    SELECT @PRC = CAST(SUM(CASE WHEN ISNULL(PROC_CD,N'')<>N'' THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0)*100 AS DECIMAL(5,1))
          ,@EMP = CAST(SUM(CASE WHEN ISNULL(EMP_CD ,N'')<>N'' THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0)*100 AS DECIMAL(5,1))
    FROM LORCV_H WITH (NOLOCK) WHERE CO_CD=@CO_CD;
    INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE) VALUES
     (4,N'연결률',N'실적 공정(PROC_CD) 지정률',ISNULL(CAST(@PRC AS NVARCHAR(10)),N'?')+N'%'
     ,CASE WHEN ISNULL(@PRC,0)>=50 THEN N'정보' ELSE N'경고' END
     ,N'M-01 쿼리 C(공정별 진척), M-06 쿼리 F, M-02 쿼리 D 의 전제')
    ,(4,N'연결률',N'실적 작업자(EMP_CD) 지정률',ISNULL(CAST(@EMP AS NVARCHAR(10)),N'?')+N'%'
     ,CASE WHEN ISNULL(@EMP,0)>=50 THEN N'정보' ELSE N'경고' END
     ,N'M-02 쿼리 E(작업자별 생산성)');
END

-- 자재 사용보고 / LOT
IF OBJECT_ID(N'dbo.LMTL_USE') IS NOT NULL
BEGIN
    DECLARE @MU INT, @MLOT DECIMAL(5,1);
    SELECT @MU = COUNT(*)
          ,@MLOT = CAST(SUM(CASE WHEN ISNULL(LOT_NB,N'')<>N'' THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0)*100 AS DECIMAL(5,1))
    FROM LMTL_USE WITH (NOLOCK) WHERE CO_CD=@CO_CD;
    INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE) VALUES
     (4,N'연결률',N'자재 사용보고 건수',CAST(ISNULL(@MU,0) AS NVARCHAR(20))
     ,CASE WHEN ISNULL(@MU,0)>0 THEN N'정보' ELSE N'치명' END
     ,N'M-05 4단계 추적, C-04 실제사용량, M-10 쿼리 E 의 전제')
    ,(4,N'연결률',N'자재투입 LOT 기록률',ISNULL(CAST(@MLOT AS NVARCHAR(10)),N'?')+N'%'
     ,CASE WHEN ISNULL(@MLOT,0)>=50 THEN N'정보' ELSE N'경고' END
     ,N'P-12 역방향 추적의 핵심');
END
ELSE
    INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE)
    VALUES (4,N'연결률',N'LMTL_USE (자재 사용보고)',N'없음',N'치명'
           ,N'M-05·C-04·P-12·M-10 쿼리E 사용 불가. 지시 단위(LMTL_USEWO) 대체 검토');

-- 수금 소거
IF OBJECT_ID(N'dbo.LRCP_D') IS NOT NULL
BEGIN
    DECLARE @RC DECIMAL(5,1);
    SELECT @RC = CAST(SUM(CASE WHEN ISNULL(CLS_NB,N'')<>N'' THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0)*100 AS DECIMAL(5,1))
    FROM LRCP_D WITH (NOLOCK) WHERE CO_CD=@CO_CD;
    INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE)
    VALUES (4,N'연결률',N'수금→마감 소거 (LRCP_D.CLS_NB)',ISNULL(CAST(@RC AS NVARCHAR(10)),N'?')+N'%'
           ,N'정보'
           ,N'80% 이상이면 S-04 연령분석을 건별 소거로 바꾸면 더 정확. 낮으면 현재 배분 방식 유지');
END

-- 프로젝트 지정률
IF OBJECT_ID(N'dbo.LINVTORY') IS NOT NULL
BEGIN
    DECLARE @PJ DECIMAL(5,1);
    SELECT @PJ = CAST(SUM(CASE WHEN ISNULL(PJT_CD,N'')<>N'' THEN 1.0 ELSE 0 END)/NULLIF(COUNT(*),0)*100 AS DECIMAL(5,1))
    FROM LINVTORY WITH (NOLOCK) WHERE CO_CD=@CO_CD AND P_YR=@P_YR;
    INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE)
    VALUES (4,N'연결률',N'수불 프로젝트(PJT_CD) 지정률',ISNULL(CAST(@PJ AS NVARCHAR(10)),N'?')+N'%'
           ,CASE WHEN ISNULL(@PJ,0)>=30 THEN N'정보' ELSE N'경고' END
           ,N'P-11 프로젝트별 수불의 대표성');
END

-- ★ 전표 관리항목 PJTCD_TY
IF OBJECT_ID(N'dbo.ADOCUD') IS NOT NULL
BEGIN
    DECLARE @HASTY BIT = 0, @D1 INT = 0, @D4 INT = 0;
    IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID(N'dbo.ADOCUD') AND name=N'PJTCD_TY')
    BEGIN
        SET @HASTY = 1;
        SET @SQL = N'SELECT @o1 = SUM(CASE WHEN PJTCD_TY=N''D1'' THEN 1 ELSE 0 END)
                          ,@o2 = SUM(CASE WHEN PJTCD_TY=N''D4'' THEN 1 ELSE 0 END)
                     FROM dbo.ADOCUD WITH (NOLOCK)
                     WHERE CO_CD=@p_CO AND ISNULL(PJT_CD,N'''')<>N''''';
        BEGIN TRY EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @o1 INT OUTPUT, @o2 INT OUTPUT'
            ,@p_CO=@CO_CD, @o1=@D1 OUTPUT, @o2=@D4 OUTPUT; END TRY BEGIN CATCH END CATCH
    END
    INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE)
    VALUES (4,N'★연결률',N'전표 PJTCD_TY (D1 프로젝트 / D4 사원)'
           ,CASE WHEN @HASTY=1 THEN N'D1=' + CAST(@D1 AS NVARCHAR(10)) + N' / D4=' + CAST(@D4 AS NVARCHAR(10))
                 ELSE N'★컬럼 없음' END
           ,CASE WHEN @HASTY=1 THEN N'정보' ELSE N'치명' END
           ,CASE WHEN @HASTY=1
                 THEN N'A-06 은 D1 만 집계한다. D4(사원)가 섞이면 프로젝트 손익이 오염된다'
                 ELSE N'★★ PJTCD_TY 없음 - A-06 결과를 신뢰할 수 없다. SPJT 등록 코드만 필터하도록 수정 필요' END);
END


/*==============================================================================================
  5단계 : 모듈 운영 여부
==============================================================================================*/
-- 원가차수
IF OBJECT_ID(N'dbo.CIV_CHASU') IS NOT NULL
BEGIN
    DECLARE @CH INT, @CLS INT;
    SELECT @CH = COUNT(*), @CLS = SUM(CASE WHEN ISNULL(CLS_YN,N'0')=N'1' THEN 1 ELSE 0 END)
    FROM CIV_CHASU WITH (NOLOCK) WHERE CO_CD=@CO_CD AND P_YR=@P_YR;
    INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE)
    VALUES (5,N'모듈운영',N'원가차수 (마감/전체)'
           ,CAST(ISNULL(@CLS,0) AS NVARCHAR(10)) + N'/' + CAST(ISNULL(@CH,0) AS NVARCHAR(10))
           ,CASE WHEN ISNULL(@CLS,0)>0 THEN N'정보' WHEN ISNULL(@CH,0)>0 THEN N'경고' ELSE N'치명' END
           ,N'C-03/C-05/C-08/E-01 원가타일의 전제. 마감 차수가 없으면 원가 리포트는 ''집계중''으로만 나온다');
END
ELSE
    INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE)
    VALUES (5,N'모듈운영',N'원가모듈 (CIV_*)',N'미운영',N'치명',N'C-02/C-03/C-05/C-07/C-08 사용 불가');

-- 재고평가
INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE)
SELECT 5,N'모듈운영',N'재고평가 (LINV_MVFIFO)'
      ,CASE WHEN OBJECT_ID(N'dbo.LINV_MVFIFO') IS NOT NULL THEN N'운영' ELSE N'미운영' END
      ,CASE WHEN OBJECT_ID(N'dbo.LINV_MVFIFO') IS NOT NULL THEN N'정보' ELSE N'경고' END
      ,N'P-04/P-06/C-06 의 금액 기준. 없으면 마스터 단가 근사치가 된다';

INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE)
SELECT 5,N'모듈운영',N'평가 검증 (LINV_MVFIFO_WK *_AM_GAP)'
      ,CASE WHEN OBJECT_ID(N'dbo.LINV_MVFIFO_WK') IS NOT NULL THEN N'운영' ELSE N'미운영' END
      ,CASE WHEN OBJECT_ID(N'dbo.LINV_MVFIFO_WK') IS NOT NULL THEN N'정보' ELSE N'경고' END
      ,N'P-09 평가 정합성 점검의 핵심';

-- 나머지 모듈
INSERT INTO #R (STG,CAT,ITEM,VAL,LEVEL,NOTE)
SELECT 5,N'모듈운영',X.NM
      ,CASE WHEN OBJECT_ID(N'dbo.' + X.TB) IS NOT NULL THEN N'운영' ELSE N'미운영' END
      ,CASE WHEN OBJECT_ID(N'dbo.' + X.TB) IS NOT NULL THEN N'정보' ELSE N'경고' END
      ,X.NOTE
FROM (VALUES
     (N'영업계획 (LFORECST_SLS_D)' ,N'LFORECST_SLS_D',N'S-09 영업계획 대비 실적')
    ,(N'주계획 MPS (LMPS)'         ,N'LMPS'          ,N'M-11 생산계획 대비 실적')
    ,(N'수출 선적 (LEBL)'          ,N'LEBL'          ,N'S-11 수출현황. 없으면 출고 기준 대체')
    ,(N'외주마감 (LOCLS_H)'        ,N'LOCLS_H'       ,N'M-07 외주비 확정액')
    ,(N'실적검사 (LQC_INSP_D)'     ,N'LQC_INSP_D'    ,N'M-06 불량 Pareto')
    ,(N'재공수불 (LINV_WIP)'       ,N'LINV_WIP'      ,N'M-04 공정별 재공')
    ,(N'재공처리 (LWIPIO)'         ,N'LWIPIO'        ,N'M-10 예외재공 점검')
    ,(N'재공실사 (LINVINSP_WIP)'   ,N'LINVINSP_WIP'  ,N'M-09 재공 실사 대비')
    ,(N'재고조정 (LADJUST)'        ,N'LADJUST'       ,N'P-10 재고조정 현황')
    ,(N'거래처단가 (LCUSTM_UM)'    ,N'LCUSTM_UM'     ,N'S-12 / P-07 등록단가 비교')
    ,(N'받을어음 (SBILL)'          ,N'SBILL'         ,N'A-05 자금수지 확정 수입')
    ,(N'지급어음 (ABILLDEB)'       ,N'ABILLDEB'      ,N'A-05 자금수지 확정 지출')
    ,(N'전표 (ADOCUH/D)'           ,N'ADOCUD'        ,N'A-02 기표 파이프라인, A-06 프로젝트 손익')
) X(NM, TB, NOTE);


/*==============================================================================================
  ** 출력 1 : 검사 결과 (단계순)
==============================================================================================*/
SELECT
     N'[1] 진단 결과'                               AS REPORT_NM
    ,단계 = CASE R.STG WHEN 0 THEN N'0.★엔진 버전' WHEN 1 THEN N'1.테이블 실존' WHEN 2 THEN N'2.★코드값 해석'
                       WHEN 3 THEN N'3.마스터 등록률' WHEN 4 THEN N'4.문서 연결률'
                       ELSE N'5.모듈 운영' END
    ,R.CAT                                          AS 구분
    ,R.ITEM                                         AS 점검항목
    ,R.VAL                                          AS 측정값
    ,R.LEVEL                                        AS 등급
    ,R.NOTE                                         AS 판단_및_조치
FROM   #R R
ORDER BY R.STG, CASE R.LEVEL WHEN N'치명' THEN 1 WHEN N'경고' THEN 2 ELSE 3 END, R.SEQ
;


/*==============================================================================================
  ** 출력 2 : 테이블 실존 매트릭스
==============================================================================================*/
SELECT
     N'[2] 테이블 실존'                             AS REPORT_NM
    ,T.구분, T.TB AS 테이블
    ,필수여부 = CASE T.필수 WHEN N'1' THEN N'필수' ELSE N'선택' END
    ,T.존재
    ,판정 = CASE WHEN T.필수=N'1' AND T.존재=N'X' THEN N'★치명 - 해당 모듈 사용 불가'
                 WHEN T.존재=N'X'                 THEN N'해당 기능 리포트만 제외'
                 ELSE N'정상' END
FROM   #T T
ORDER BY CASE WHEN T.필수=N'1' AND T.존재=N'X' THEN 0 ELSE 1 END, T.구분, T.TB
;


/*==============================================================================================
  ** 출력 3 : ★ 리포트별 적용 판정 매트릭스  ─ 이것부터 보면 된다
==============================================================================================*/
DECLARE @치명 INT = (SELECT COUNT(*) FROM #R WHERE LEVEL = N'치명');

SELECT
     N'[3] ★ 리포트 적용 판정'                     AS REPORT_NM
    ,X.차수, X.파일, X.전제조건
    ,판정 = CASE WHEN V.파일 IS NOT NULL AND @VER_MAJ < 11 THEN N'X 엔진버전'
                 WHEN X.OK = 1 THEN N'O 사용가능'
                 WHEN X.OK = 2 THEN N'△ 수정필요'
                 ELSE N'X 사용불가' END
    ,요구엔진 = CASE WHEN V.파일 IS NOT NULL THEN N'2012 이상' ELSE N'2008 R2 가능' END
    ,조치 = CASE WHEN V.파일 IS NOT NULL AND @VER_MAJ < 11
                 THEN N'★ SQL Server 2012 이상 필요 (' + V.사유 + N'). 현재 ' + @VER
                    + N' — 엔진을 올리거나, 2012+ 인스턴스에 리포팅 복제본을 두고 거기서 실행할 것'
                 ELSE X.조치 END
FROM (
    -- 기준정보
     SELECT 순서=1 ,차수=N'1차',파일=N'B01_마스터품질_스코어카드.sql'    ,전제조건=N'SITEM'
           ,OK=CASE WHEN OBJECT_ID(N'dbo.SITEM') IS NOT NULL THEN 1 ELSE 0 END
           ,조치=N'가장 먼저 실행. 다른 리포트의 신뢰도를 여기서 판단한다'
    UNION ALL SELECT 2,N'상시',N'B02_마스터점검팩.sql',N'SITEM + BOM'
           ,CASE WHEN OBJECT_ID(N'dbo.SITEM') IS NOT NULL THEN 1 ELSE 0 END
           ,N'★ 쿼리 A(코드값 해석)를 전 파일 적용 전에 반드시 실행. @AR_ACCT/@AP_ACCT 교체 필수'
    -- 영업
    UNION ALL SELECT 10,N'2차',N'S02_주문미납_현황.sql',N'LSO_D + LDELIVER_D'
           ,CASE WHEN OBJECT_ID(N'dbo.LSO_D') IS NOT NULL AND OBJECT_ID(N'dbo.LDELIVER_D') IS NOT NULL THEN 1 ELSE 0 END, N''
    UNION ALL SELECT 11,N'3차',N'S03_납기준수율_KPI.sql',N'LSO_D.DUE_DT'
           ,CASE WHEN OBJECT_ID(N'dbo.LSO_D') IS NOT NULL THEN 2 ELSE 0 END
           ,N'@TARGET(95%) 를 실측 후 조정. 납기 등록률 확인 필요'
    UNION ALL SELECT 12,N'5차',N'S04_매출수금_채권KPI.sql',N'LSALECLS_D + LRCP_D'
           ,CASE WHEN OBJECT_ID(N'dbo.LRCP_D') IS NOT NULL THEN 2 ELSE 0 END
           ,N'★ 대손율(@R0~@R4) 을 회사 정책값으로 교체. RCP_FG 현금/어음 구분 확인'
    UNION ALL SELECT 13,N'5차',N'S05_판매분석_다축.sql',N'LSALECLS_D'
           ,CASE WHEN OBJECT_ID(N'dbo.LSALECLS_D') IS NOT NULL THEN 1 ELSE 0 END
           ,N'품목군 컬럼 자동 탐색. 전년 데이터 없으면 증감 컬럼만 NULL'
    UNION ALL SELECT 14,N'1차',N'S06_채권여신_관리현황.sql',N'LOPN_CRISU + LRCP_D'
           ,CASE WHEN OBJECT_ID(N'dbo.LOPN_CRISU') IS NOT NULL THEN 1
                 WHEN OBJECT_ID(N'dbo.LRCP_D') IS NOT NULL THEN 2 ELSE 0 END
           ,N'LCR_LIMIT 없으면 STRADE 대체 (자동)'
    UNION ALL SELECT 15,N'5차',N'S09_영업계획대비_실적.sql',N'LFORECST_SLS_D'
           ,CASE WHEN OBJECT_ID(N'dbo.LFORECST_SLS_D') IS NOT NULL
                   OR OBJECT_ID(N'dbo.LFORECST_D') IS NOT NULL THEN 2 ELSE 0 END
           ,N'컬럼 자동 탐색. 계획 입도(거래처만/품목까지)를 확인해 비교 축을 맞출 것'
    UNION ALL SELECT 16,N'5차',N'S11_수출현황.sql',N'LEBL 또는 LDELIVER'
           ,CASE WHEN OBJECT_ID(N'dbo.LEBL') IS NOT NULL THEN 2
                 WHEN OBJECT_ID(N'dbo.LDELIVER') IS NOT NULL THEN 2 ELSE 0 END
           ,N'★ @EXP_SOFG(수출 SO_FG) 를 반드시 실측값으로 교체. 기본값 1,3,4 는 추정'
    UNION ALL SELECT 17,N'5차',N'S12_거래처단가_이력.sql',N'LCUSTM_UM'
           ,CASE WHEN OBJECT_ID(N'dbo.LCUSTM_UM') IS NOT NULL THEN 1 ELSE 0 END
           ,N'NO_SQ=999 규칙 확인 필요'
    UNION ALL SELECT 18,N'-',N'수주진행총괄현황.sql',N'수주~전표 전 체인'
           ,CASE WHEN OBJECT_ID(N'dbo.LSO_D') IS NOT NULL THEN 2 ELSE 0 END
           ,N'수주→지시 연결률이 낮으면 생산 경로가 비어 보인다'
    -- 구매
    UNION ALL SELECT 20,N'2차',N'P01_청구발주입고_진행현황.sql',N'LPO_D + LSTOCK_D'
           ,CASE WHEN OBJECT_ID(N'dbo.LPO_D') IS NOT NULL THEN 1 ELSE 0 END
           ,N'청구 미운영이면 쿼리 C(발주별) 중심으로 사용'
    UNION ALL SELECT 21,N'3차',N'P02_발주납기준수_KPI.sql',N'LPO_D.DUE_DT + LSTOCK'
           ,CASE WHEN OBJECT_ID(N'dbo.LPO_D') IS NOT NULL THEN 2 ELSE 0 END
           ,N'수입 비중 크면 @LC_FG 로 국내/수입 분리 실행'
    UNION ALL SELECT 22,N'2차',N'P03_실시간재고_추적.sql',N'LINVTORY'
           ,CASE WHEN OBJECT_ID(N'dbo.LINVTORY') IS NOT NULL THEN 1 ELSE 0 END
           ,N'집계뷰 유무에 따라 자동 강등. 소스계층 컬럼으로 확인'
    UNION ALL SELECT 23,N'5차',N'P04_재고수불_회전율분석.sql',N'LINV_MVFIFO 권장'
           ,CASE WHEN OBJECT_ID(N'dbo.LINV_MVFIFO') IS NOT NULL THEN 1
                 WHEN OBJECT_ID(N'dbo.LINVTORY')   IS NOT NULL THEN 2 ELSE 0 END
           ,N'평가 테이블 없으면 금액이 마스터 단가 근사치 - 상대비교만 가능'
    UNION ALL SELECT 24,N'3차',N'P05_재고알람_KPI.sql',N'SITEM.SAFESTOCK_QT'
           ,CASE WHEN OBJECT_ID(N'dbo.LINVTORY') IS NOT NULL THEN 2 ELSE 0 END
           ,N'★ 안전재고 등록률 30% 미만이면 알람등급 1·2 만 사용'
    UNION ALL SELECT 25,N'5차',N'P07_매입단가_추이분석.sql',N'LSTOCK_D 또는 LPURCLS_D'
           ,CASE WHEN OBJECT_ID(N'dbo.LSTOCK_D') IS NOT NULL THEN 1 ELSE 0 END
           ,N'원가 대사에는 @SRC=''CLS''(마감) 사용'
    UNION ALL SELECT 26,N'상시',N'P09_재고정합성_점검.sql',N'LINV_MVFIFO_WK'
           ,CASE WHEN OBJECT_ID(N'dbo.LINV_MVFIFO_WK') IS NOT NULL THEN 1
                 WHEN OBJECT_ID(N'dbo.LINV_MVFIFO')    IS NOT NULL THEN 2 ELSE 0 END
           ,N'★ 원가 마감 전 필수. GAP 컬럼 의미를 원가 담당자와 확인'
    UNION ALL SELECT 27,N'5차',N'P10_재고조정_현황.sql',N'LADJUST'
           ,CASE WHEN OBJECT_ID(N'dbo.LADJUST') IS NOT NULL THEN 1 ELSE 0 END
           ,N'조정 사유 코드(CTRL_CD=''LA'') 등록 여부 확인'
    UNION ALL SELECT 28,N'5차',N'P11_프로젝트별_수불현황.sql',N'LINVTORY.PJT_CD'
           ,CASE WHEN OBJECT_ID(N'dbo.LINVTORY') IS NOT NULL THEN 2 ELSE 0 END
           ,N'PJT_CD 지정률이 낮으면 대표성 없음'
    UNION ALL SELECT 29,N'5차',N'P12_LOT추적.sql',N'LMTL_USE + LOT_NB'
           ,CASE WHEN OBJECT_ID(N'dbo.LMTL_USE') IS NOT NULL THEN 2 ELSE 0 END
           ,N'★ 쿼리 F 로 단계별 LOT 기록률을 먼저 확인. 낮으면 추적이 사슬 중간에 끊긴다'
    UNION ALL SELECT 30,N'-',N'원자재수급총괄현황_MRP.sql',N'BOM + LSO_D'
           ,CASE WHEN OBJECT_ID(N'dbo.SBOM_WF') IS NOT NULL
                   OR OBJECT_ID(N'dbo.SBOM')    IS NOT NULL THEN 2 ELSE 0 END
           ,N'BOM 등록률·리드타임 등록률이 낮으면 결과를 믿을 수 없다'
    -- 생산
    UNION ALL SELECT 40,N'2차',N'M01_작업지시_진행현황.sql',N'LWO_WF + LORCV_H'
           ,CASE WHEN OBJECT_ID(N'dbo.LWO_WF') IS NOT NULL THEN 2 ELSE 0 END
           ,N'★ 쿼리 G 로 DOC_ST 체계 확인 후 라벨 수정. 공정 지정률 낮으면 쿼리 C 생략'
    UNION ALL SELECT 41,N'5차',N'M02_생산일보_생산성.sql',N'LORCV_H'
           ,CASE WHEN OBJECT_ID(N'dbo.LORCV_H') IS NOT NULL THEN 1 ELSE 0 END
           ,N'설비·작업팀·교대조 축은 컬럼 있는 것만 자동 집계'
    UNION ALL SELECT 42,N'2차',N'M04_공정별재공_현황.sql',N'LINV_WIP'
           ,CASE WHEN OBJECT_ID(N'dbo.LINV_WIP') IS NOT NULL THEN 1 ELSE 0 END
           ,N'LX_WH_W 있으면 쿼리 F 로 대사'
    UNION ALL SELECT 43,N'1차',N'M05_자재_청구출고사용_현황.sql',N'LWO_REQ_WF + LMTL_USE'
           ,CASE WHEN OBJECT_ID(N'dbo.LWO_REQ_WF') IS NOT NULL THEN 1 ELSE 0 END
           ,N'원가 마감 전 필수 점검'
    UNION ALL SELECT 44,N'3차',N'M06_불량파레토_품질KPI.sql',N'LORCV_H (+LQC_INSP_D)'
           ,CASE WHEN OBJECT_ID(N'dbo.LORCV_H') IS NOT NULL THEN 2 ELSE 0 END
           ,N'LQC_INSP_D 없으면 KPI(A·B·E·F)만. Pareto(C·D)는 자동 생략'
    UNION ALL SELECT 45,N'5차',N'M07_외주진행마감_현황.sql',N'LWO_WF DOC_FG + LOCLS'
           ,CASE WHEN OBJECT_ID(N'dbo.LWO_WF') IS NOT NULL THEN 2 ELSE 0 END
           ,N'★ @DOC_FG(외주 구분) 실측 확인 필수. LOCLS 없으면 외주비 확정액 불명'
    UNION ALL SELECT 46,N'5차',N'M10_생산마스터_점검.sql',N'LWIPIO + BOM'
           ,CASE WHEN OBJECT_ID(N'dbo.SBOM_WF') IS NOT NULL
                   OR OBJECT_ID(N'dbo.SBOM')    IS NOT NULL THEN 2 ELSE 0 END
           ,N'BOM 소요량 컬럼 자동 탐색. LWIPIO 없으면 BOM 점검만'
    UNION ALL SELECT 47,N'3차',N'M11_생산계획대비실적.sql',N'LMPS'
           ,CASE WHEN OBJECT_ID(N'dbo.LMPS') IS NOT NULL THEN 2 ELSE 0 END
           ,N'★ EXP_FG 분포 확인 후 @EXP_FG 선택. 모의계획(2)은 절대 제외'
    UNION ALL SELECT 48,N'-',N'생산지시별_작업수율현황.sql',N'LORCV_H + LMTL_USE'
           ,CASE WHEN OBJECT_ID(N'dbo.LORCV_H') IS NOT NULL THEN 1 ELSE 0 END, N''
    -- 원가
    UNION ALL SELECT 60,N'5차',N'C02_당기재료비_분석.sql',N'CIV_PRD_TAV_D'
           ,CASE WHEN OBJECT_ID(N'dbo.CIV_PRD_TAV_D') IS NOT NULL THEN 1 ELSE 0 END
           ,N'마감 차수만 신뢰'
    UNION ALL SELECT 61,N'4차',N'C03_제품별_원가구성.sql',N'CIV_PRD_TAV + CIV_CHASU'
           ,CASE WHEN OBJECT_ID(N'dbo.CIV_PRD_TAV') IS NOT NULL THEN 1 ELSE 0 END
           ,N'★ 전차수 대비 비교 전에 C-08 로 배부기준이 같은지 확인'
    UNION ALL SELECT 62,N'1차',N'C04_표준원가_차이분석.sql',N'BOM + LMTL_USE'
           ,CASE WHEN OBJECT_ID(N'dbo.LMTL_USE') IS NOT NULL THEN 2 ELSE 0 END
           ,N'@UM_BASE_FG 로 실제단가 소스 선택'
    UNION ALL SELECT 63,N'4차',N'C05_매출이익_분석.sql',N'LSALECLS_D + 원가소스'
           ,CASE WHEN OBJECT_ID(N'dbo.LSALECLS_D') IS NOT NULL THEN 2 ELSE 0 END
           ,N'★ CLSG_AM(공급가) 사용 확인. 상품 비중 크면 @UM_SRC=PRD 고정 금지'
    UNION ALL SELECT 64,N'5차',N'C06_재고평가_현황.sql',N'LINV_MVFIFO'
           ,CASE WHEN OBJECT_ID(N'dbo.LINV_MVFIFO') IS NOT NULL THEN 1 ELSE 0 END
           ,N'P-09 를 먼저 돌려 GAP=0 확인 후 사용'
    UNION ALL SELECT 65,N'상시',N'C07_원가차수_마감점검.sql',N'CIV_CHASU'
           ,CASE WHEN OBJECT_ID(N'dbo.CIV_CHASU') IS NOT NULL THEN 2 ELSE 0 END
           ,N'★ 선행 점검 6종의 등급(차단/경고)을 원가 담당자와 합의'
    UNION ALL SELECT 66,N'5차',N'C08_가공비배부_검증.sql',N'CIV_CONVCST + CIV_OE'
           ,CASE WHEN OBJECT_ID(N'dbo.CIV_CONVCST') IS NOT NULL THEN 1 ELSE 0 END
           ,N'가공비 미배부 사이트면 사용 안 함'
    UNION ALL SELECT 67,N'-',N'PJT_생산원가_보고서.sql',N'BOM + 지시 + 실적'
           ,CASE WHEN OBJECT_ID(N'dbo.LWO_WF') IS NOT NULL THEN 2 ELSE 0 END
           ,N'프로젝트 지정률 확인'
    -- 회계
    UNION ALL SELECT 80,N'1차',N'A02_기표파이프라인_현황.sql',N'ADOCUD + 마감'
           ,CASE WHEN OBJECT_ID(N'dbo.ADOCUD') IS NOT NULL THEN 1 ELSE 0 END, N''
    UNION ALL SELECT 81,N'4차',N'A05_자금수지_전망.sql',N'SBILL/ABILLDEB + 마감'
           ,CASE WHEN OBJECT_ID(N'dbo.SBILL') IS NOT NULL
                   OR OBJECT_ID(N'dbo.ABILLDEB') IS NOT NULL THEN 2 ELSE 2 END
           ,N'★ @COL_DAY/@PAY_DAY 를 쿼리 F 실측값으로 교체. @OPEN_CASH 수기 입력'
    UNION ALL SELECT 82,N'5차',N'A06_프로젝트별손익_회계.sql',N'ADOCUD.PJTCD_TY'
           ,CASE WHEN OBJECT_ID(N'dbo.ADOCUD') IS NULL THEN 0
                 WHEN EXISTS (SELECT 1 FROM sys.columns
                              WHERE object_id=OBJECT_ID(N'dbo.ADOCUD') AND name=N'PJTCD_TY') THEN 2
                 ELSE 0 END
           ,N'★★ PJTCD_TY=''D1'' 필수. 없으면 사원코드가 프로젝트로 집계된다. 계정 앞자리도 확인'
    UNION ALL SELECT 83,N'-',N'전표_관리항목_검증.sql',N'ADOCUD'
           ,CASE WHEN OBJECT_ID(N'dbo.ADOCUD') IS NOT NULL THEN 1 ELSE 0 END, N''
    -- 통합
    UNION ALL SELECT 90,N'4차',N'E01_경영KPI_대시보드.sql',N'전 모듈'
           ,CASE WHEN OBJECT_ID(N'dbo.LSO_D') IS NOT NULL THEN 2 ELSE 0 END
           ,N'★ 데이터 신선도(쿼리 E) 7일 초과 소스의 타일은 띄우지 말 것'
    UNION ALL SELECT 91,N'4차',N'E02_수주출하_리드타임분석.sql',N'수주~출고 체인'
           ,CASE WHEN OBJECT_ID(N'dbo.LSO_D') IS NOT NULL THEN 2 ELSE 0 END
           ,N'수주→지시 연결률 30% 미만이면 생산 경로 분석 신뢰도 낮음'
) X
LEFT JOIN #V12 V ON V.파일 = X.파일
ORDER BY CASE WHEN V.파일 IS NOT NULL AND @VER_MAJ < 11 THEN 0
              WHEN X.OK = 0 THEN 1
              WHEN X.OK = 2 THEN 2
              ELSE 3 END
        ,X.순서
;


/*==============================================================================================
  ** 출력 4 : 종합 판정
==============================================================================================*/
SELECT
     N'[4] 종합 판정'                               AS REPORT_NM
    ,@CO_CD + N' / ' + ISNULL(@DIV_CD, N'전사') + N' / ' + @P_YR  AS 진단대상
    ,CONVERT(NVARCHAR(20), GETDATE(), 120)          AS 진단시각
    ,@VER + N' / compat ' + CAST(@COMPAT AS NVARCHAR(10))         AS 엔진
    ,실행불가_엔진 = CASE WHEN @VER_MAJ < 11 THEN (SELECT COUNT(*) FROM #V12) ELSE 0 END
    ,치명 = (SELECT COUNT(*) FROM #R WHERE LEVEL = N'치명')
    ,경고 = (SELECT COUNT(*) FROM #R WHERE LEVEL = N'경고')
    ,정보 = (SELECT COUNT(*) FROM #R WHERE LEVEL = N'정보')
    ,필수테이블_누락 = (SELECT COUNT(*) FROM #T WHERE 필수=N'1' AND 존재=N'X')
    ,선택테이블_보유 = (SELECT COUNT(*) FROM #T WHERE 필수=N'0' AND 존재=N'O')
    ,판정 = CASE
         WHEN @COMPAT < 90
              THEN N'1.★★호환성 수준 ' + CAST(@COMPAT AS NVARCHAR(10))
                 + N' - OVER()/APPLY/CTE 가 전부 막힌다. 이것부터 해결하지 않으면 대부분 실행 불가'
         WHEN @VER_MAJ < 11
              THEN N'2.★★SQL Server ' + @VER + N' - 2012 전용 구문을 쓰는 '
                 + CAST((SELECT COUNT(*) FROM #V12) AS NVARCHAR(10))
                 + N'개가 실행 불가. 출력 3 의 ''X 엔진버전'' 참조'
         WHEN (SELECT COUNT(*) FROM #T WHERE 필수=N'1' AND 존재=N'X') > 0
              THEN N'3.★★필수 테이블 누락 - 해당 모듈을 제외하고 적용 범위를 다시 정할 것'
         WHEN @치명 > 0
              THEN N'4.★치명 항목 ' + CAST(@치명 AS NVARCHAR(10)) + N'건 - 출력 1 의 치명 항목을 먼저 해결'
         WHEN (SELECT COUNT(*) FROM #R WHERE LEVEL=N'경고') > 5
              THEN N'5.경고 다수 - 출력 3 의 ''수정필요'' 파일을 조정한 뒤 적용'
         ELSE N'0.양호 - 출력 3 의 ''사용가능'' 부터 순서대로 적용' END
    ,다음단계 = N'⓪ 엔진이 2008 R2 면 ''X 엔진버전'' 24개를 먼저 처리  '
              + N'① 출력 3 매트릭스에서 ''사용가능''부터 적용  '
              + N'② ''수정필요''는 조치 컬럼대로 파일 수정  '
              + N'③ 2단계 코드값이 전제와 다르면 전 파일 일괄 수정이 최우선'
;


DROP TABLE #T, #R, #V12;
GO


/*==============================================================================================
  [ 이 진단으로 커버되지 않는 것 — 리포트별로 개별 확인 ]
  ----------------------------------------------------------------------------------------------
   아래는 사이트 고유값이라 자동 판정할 수 없다. 해당 파일의 [도입 전 확인] 을 직접 볼 것.

   ① 계정과목 코드        B-02 (@AR_ACCT/@AP_ACCT), A-06 (@REV_PFX/@EXP_PFX)
                          → SELECT ACCT_CD, ACCT_NM FROM SACCT WHERE ACCT_NM LIKE '%외상매출%'
   ② 수출 거래구분        S-11 (@EXP_SOFG)  → SO_FG × EXCH_FG 교차 분포로 판별
   ③ 외주 구분            M-07 (@DOC_FG)    → DOC_FG × WOC_FG 분포 + TR_CD 채움 여부
   ④ 대손율               S-04 (@R0~@R4)    → 과거 대손 실적 또는 회계정책
   ⑤ 회수·지급 리드타임   A-05 (@COL_DAY/@PAY_DAY) → A-05 쿼리 F 실측
   ⑥ 기초 자금잔고        A-05 (@OPEN_CASH) → 회계모듈 현금·예금 잔액 (수기)
   ⑦ KPI 목표선           S-03/P-02/M-06/M-11/P-05 (@TARGET 등)
                          → 각 파일의 실측 쿼리로 현재 수준을 보고 단계적으로 설정
   ⑧ 배부기준 코드 의미   C-08 (METHOD_FG)  → 원가 담당자 확인
   ⑨ 예외재공 발생 사유   M-10 (MAP_FG 7~9) → 생산 담당자 확인. 정상 절차일 수도 있다
   ⑩ 원가 마감 선행조건 등급  C-07 → 회사 정책에 맞춰 차단/경고 재분류

  [ 재실행 ]
  ----------------------------------------------------------------------------------------------
   · 마스터 대량 정비 후
   · 신규 모듈 오픈 후 (원가·평가·계획 등)
   · 연도가 바뀐 뒤 (@P_YR 변경)
==============================================================================================*/
