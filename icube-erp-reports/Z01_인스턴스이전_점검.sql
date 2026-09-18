/*==============================================================================================
  [ iCUBE ] Z-01  인스턴스 이전 점검 (2008 R2 → 2012 이상)                          (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : **옮기기 전 원본에서 한 번, 옮긴 뒤 대상에서 한 번** 돌려 결과를 나란히 비교한다.
         버전을 보고 추측하지 않는다. 2012 전용 구문을 **실제로 실행해 보고** 되는지 본다.

  DBMS : MS-SQL Server (T-SQL) — 이 파일 자신은 2008 R2 에서도 돈다

  lint-ignore : ENV002 — 2012 구문을 일부러 실행해 실패를 TRY/CATCH 로 받는 파일이다.
                구버전에서 실패하는 것이 이 파일의 동작이지 결함이 아니다.

  ----------------------------------------------------------------------------------------------
  [ 왜 버전만으로는 부족한가 ]
  ----------------------------------------------------------------------------------------------
     `LAG()` 같은 2012 분석함수는 **엔진이 2012 이상이고 + DB 호환성 수준이 110 이상**일 때만
     동작한다. 둘 중 하나만 충족하면 실패한다.

         엔진 2017 + compat 100  →  LAG 실패   ← 복원 직후가 정확히 이 상태다
         엔진 2017 + compat 110  →  LAG 성공

     2008 R2 의 DB 를 2017 에 복원하면 호환성 수준이 **100 그대로 따라온다.** 자동으로
     올라가지 않는다. 그래서 복원만 하고 끝내면 24개 리포트가 그대로 실패한다.
     이 파일의 검사 C 가 그것을 잡는다.

  ----------------------------------------------------------------------------------------------
  [ 검사 ]
  ----------------------------------------------------------------------------------------------
     A  서버 지문      인스턴스 · 엔진 · 에디션 · 인증모드 · 서버 데이터 정렬 · TCP 포트
     B  DB 지문        크기 · 복구모델 · 호환성 수준 · DB 데이터 정렬 · 파일 경로 · 여유공간
     C  ★ 구문 실행    2012 전용 구문 5종을 실제로 실행해 본다
     D  로그인         고아 사용자 — 복원 뒤 로그인이 끊긴 사용자
     E  종합 판정      이 서버에서 46개가 도는가
==============================================================================================*/

SET NOCOUNT ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @DB_NM   SYSNAME = DB_NAME()        -- 점검 대상 DB. 보통 현재 DB 그대로 두면 된다
    ,@NEED_MB INT     = 6000             -- 필요 여유공간(MB). 백업+복원 여유를 감안한 값
;

IF OBJECT_ID('tempdb..#R') IS NOT NULL DROP TABLE #R;
IF OBJECT_ID('tempdb..#P') IS NOT NULL DROP TABLE #P;

CREATE TABLE #R (
     SEQ   INT IDENTITY(1,1)
    ,CAT   NVARCHAR(20)
    ,ITEM  NVARCHAR(60)
    ,VAL   NVARCHAR(200)
    ,LEVEL NVARCHAR(10)          -- 치명 / 경고 / 정보
    ,NOTE  NVARCHAR(300)
);
CREATE TABLE #P (
     ID     INT
    ,구문   NVARCHAR(40)
    ,쓰는곳 NVARCHAR(40)
    ,결과   NVARCHAR(20)
    ,오류   NVARCHAR(400)
);


/*==============================================================================================
  A. 서버 지문
==============================================================================================*/
DECLARE @VER     NVARCHAR(30) = CONVERT(NVARCHAR(30), SERVERPROPERTY('ProductVersion'));
DECLARE @VER_MAJ INT          = ISNULL(CAST(PARSENAME(@VER, 4) AS INT), 0);
DECLARE @EDITION NVARCHAR(60) = CONVERT(NVARCHAR(60), SERVERPROPERTY('Edition'));
DECLARE @SRV_COL NVARCHAR(60) = CONVERT(NVARCHAR(60), SERVERPROPERTY('Collation'));
DECLARE @WINONLY INT          = CONVERT(INT, SERVERPROPERTY('IsIntegratedSecurityOnly'));
DECLARE @PORT    NVARCHAR(10);

SELECT @PORT = CAST(local_tcp_port AS NVARCHAR(10))
FROM   sys.dm_exec_connections
WHERE  session_id = @@SPID;

INSERT INTO #R (CAT, ITEM, VAL, LEVEL, NOTE) VALUES
 (N'A.서버', N'인스턴스'
  , ISNULL(CONVERT(NVARCHAR(60), SERVERPROPERTY('ServerName')), N'(미상)')
  , N'정보', N'이전 전후로 이 값이 달라야 한다. 같으면 같은 서버에서 두 번 돌린 것이다')
,(N'A.서버', N'엔진 버전'
  , @VER + N' (' + CONVERT(NVARCHAR(20), SERVERPROPERTY('ProductLevel')) + N')'
  , CASE WHEN @VER_MAJ >= 11 THEN N'정보' ELSE N'치명' END
  , CASE WHEN @VER_MAJ >= 11 THEN N'2012 이상'
         ELSE N'★ 2012 미만 - 24개 리포트가 실행되지 않는다' END)
,(N'A.서버', N'에디션', @EDITION
  , CASE WHEN @EDITION LIKE N'Express%' THEN N'경고' ELSE N'정보' END
  , CASE WHEN @EDITION LIKE N'Express%'
         THEN N'Express - DB 당 10GB · 메모리 1GB · 코어 4 · SQL Agent 없음'
         ELSE N'자원 제한 없음' END)
,(N'A.서버', N'서버 데이터 정렬', @SRV_COL, N'정보'
  , N'★ tempdb 가 이 정렬을 쓴다. 원본과 다르면 임시테이블 조인에서 정렬 충돌이 난다')
,(N'A.서버', N'인증 모드'
  , CASE WHEN @WINONLY = 1 THEN N'Windows 전용' ELSE N'혼합 모드' END
  , CASE WHEN @WINONLY = 1 THEN N'경고' ELSE N'정보' END
  , CASE WHEN @WINONLY = 1
         THEN N'★ iCUBE 는 SQL 로그인으로 붙는다. 서버 속성 > 보안에서 혼합 모드로 바꾸고 재시작할 것'
         ELSE N'SQL 로그인 사용 가능' END)
,(N'A.서버', N'TCP 포트', ISNULL(@PORT, N'(공유 메모리 접속이라 확인 불가)')
  , CASE WHEN @PORT IS NULL THEN N'정보' ELSE N'정보' END
  , N'원격에서 붙으려면 구성 관리자에서 TCP/IP 사용 + 포트 고정. iCUBE 기본은 5539');


/*==============================================================================================
  B. DB 지문
==============================================================================================*/
DECLARE @COMPAT INT, @DB_COL NVARCHAR(60), @RECOV NVARCHAR(20);
SELECT @COMPAT = compatibility_level
      ,@DB_COL = collation_name
      ,@RECOV  = recovery_model_desc
FROM   sys.databases
WHERE  name = @DB_NM;

INSERT INTO #R (CAT, ITEM, VAL, LEVEL, NOTE)
SELECT N'B.DB', N'대상 DB', @DB_NM
      ,CASE WHEN @COMPAT IS NULL THEN N'치명' ELSE N'정보' END
      ,CASE WHEN @COMPAT IS NULL THEN N'★ 그런 이름의 DB 가 없다. @DB_NM 을 확인할 것'
            ELSE N'' END;

INSERT INTO #R (CAT, ITEM, VAL, LEVEL, NOTE)
SELECT N'B.DB', N'호환성 수준', ISNULL(CAST(@COMPAT AS NVARCHAR(10)), N'(미상)')
      ,CASE WHEN @COMPAT >= 110 THEN N'정보' ELSE N'치명' END
      ,CASE WHEN @COMPAT IS NULL
            THEN N'★ DB 를 찾지 못했다 - @DB_NM 을 확인할 것'
            WHEN @COMPAT >= 110
            THEN N'110 이상 - 2012 분석함수 사용 가능'
            WHEN @COMPAT >= 100
            THEN N'★ 100 - 엔진이 2017 이어도 LAG 등이 막힌다. ALTER DATABASE 로 올릴 것 (아래 [이전 절차] 5)'
            ELSE N'★ 90 이하 - 윈도우 함수 · APPLY · CTE 까지 막힌다' END;

INSERT INTO #R (CAT, ITEM, VAL, LEVEL, NOTE)
SELECT N'B.DB', N'DB 데이터 정렬', ISNULL(@DB_COL, N'(미상)')
      ,CASE WHEN @DB_COL = @SRV_COL THEN N'정보' ELSE N'경고' END
      ,CASE WHEN @DB_COL = @SRV_COL
            THEN N'서버 정렬과 같다'
            ELSE N'★ 서버(tempdb) 정렬과 다르다 - 임시테이블 조인에서 정렬 충돌이 날 수 있다' END;

INSERT INTO #R (CAT, ITEM, VAL, LEVEL, NOTE)
SELECT N'B.DB', N'복구 모델', ISNULL(@RECOV, N'(미상)'), N'정보'
      ,N'SIMPLE 이면 로그 백업이 없다. 이전 직전 전체 백업 하나로 충분하다';

INSERT INTO #R (CAT, ITEM, VAL, LEVEL, NOTE)
SELECT N'B.DB', N'데이터 파일 합계'
      ,CAST(CAST(SUM(CASE WHEN mf.type = 0 THEN mf.size END) * 8.0 / 1024 AS DECIMAL(10,1)) AS NVARCHAR(20)) + N' MB'
      ,CASE WHEN SUM(CASE WHEN mf.type = 0 THEN mf.size END) * 8.0 / 1024 > 9000
                 AND @EDITION LIKE N'Express%' THEN N'치명' ELSE N'정보' END
      ,CASE WHEN SUM(CASE WHEN mf.type = 0 THEN mf.size END) * 8.0 / 1024 > 9000
                 AND @EDITION LIKE N'Express%'
            THEN N'★ Express 10GB 한도에 근접. 대상도 Express 면 들어가지 않는다'
            ELSE N'Express 10GB 한도 안' END
FROM   sys.master_files mf
WHERE  mf.database_id = DB_ID(@DB_NM);

INSERT INTO #R (CAT, ITEM, VAL, LEVEL, NOTE)
SELECT N'B.DB', N'파일 경로', mf.physical_name, N'정보'
      ,CASE mf.type WHEN 0 THEN N'데이터' ELSE N'로그' END
       + N' — 복원 시 RESTORE ... WITH MOVE 로 대상 경로를 지정한다'
FROM   sys.master_files mf
WHERE  mf.database_id = DB_ID(@DB_NM);

-- 여유 공간 — sys.dm_os_volume_stats 는 2008 R2 **SP1** 부터다.
-- 없는 객체는 컴파일 단계에서 터지고 같은 배치의 TRY/CATCH 로는 잡히지 않는다.
-- 그래서 동적 SQL 로 별도 배치에 보낸다. 검사 C 와 같은 이유다.
DECLARE @VOL NVARCHAR(MAX) = N'
    SELECT DISTINCT N''B.DB'', N''볼륨 여유공간 '' + vs.volume_mount_point
          ,CAST(CAST(vs.available_bytes / 1048576.0 AS DECIMAL(10,0)) AS NVARCHAR(20)) + N'' MB''
          ,CASE WHEN vs.available_bytes / 1048576.0 < @p_need THEN N''경고'' ELSE N''정보'' END
          ,CASE WHEN vs.available_bytes / 1048576.0 < @p_need
                THEN N''★ 백업본과 복원본이 함께 들어갈 여유가 부족할 수 있다''
                ELSE N''충분'' END
    FROM   sys.master_files mf
    CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
    WHERE  mf.database_id = DB_ID(@p_db);';

BEGIN TRY
    INSERT INTO #R (CAT, ITEM, VAL, LEVEL, NOTE)
    EXEC sp_executesql @VOL, N'@p_db SYSNAME, @p_need INT'
                     , @p_db = @DB_NM, @p_need = @NEED_MB;
END TRY
BEGIN CATCH
    INSERT INTO #R (CAT, ITEM, VAL, LEVEL, NOTE)
    VALUES (N'B.DB', N'볼륨 여유공간', N'(확인 불가)', N'정보'
           ,N'2008 R2 SP0 이거나 권한 부족. 탐색기에서 직접 확인할 것');
END CATCH


/*==============================================================================================
  C. ★ 2012 전용 구문을 실제로 실행해 본다
  ----------------------------------------------------------------------------------------------
  버전·호환성 수준을 조합해 추론하지 않고 직접 돌린다. 동적 SQL 로 감싸는 이유는
  같은 배치 안의 구문 오류는 TRY/CATCH 로 잡히지 않기 때문이다. 별도 배치로 보내야 잡힌다.
==============================================================================================*/
INSERT INTO #P (ID, 구문, 쓰는곳) VALUES
 (1, N'LAG()'                      , N'전기 대비 증감')
,(2, N'집계 OVER(ORDER BY)'        , N'누적합 · 누적비율')
,(3, N'ROWS BETWEEN 프레임'        , N'이동평균 · 누계')
,(4, N'PERCENTILE_CONT()'          , N'중앙값 · 사분위')
,(5, N'EOMONTH()'                  , N'월말일');

DECLARE @i INT = 1, @sql NVARCHAR(400);

WHILE @i <= 5
BEGIN
    SET @sql =
        CASE @i
        WHEN 1 THEN N'SELECT TOP 0 LAG(N.n) OVER (ORDER BY N.n) FROM (SELECT 1 AS n) N'
        WHEN 2 THEN N'SELECT TOP 0 SUM(N.n) OVER (ORDER BY N.n) FROM (SELECT 1 AS n) N'
        WHEN 3 THEN N'SELECT TOP 0 SUM(N.n) OVER (ORDER BY N.n ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM (SELECT 1 AS n) N'
        WHEN 4 THEN N'SELECT TOP 0 PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY N.n) OVER () FROM (SELECT 1 AS n) N'
        ELSE        N'SELECT TOP 0 EOMONTH(GETDATE())'
        END;

    BEGIN TRY
        EXEC sp_executesql @sql;
        UPDATE #P SET 결과 = N'O 실행됨', 오류 = N'' WHERE ID = @i;
    END TRY
    BEGIN CATCH
        UPDATE #P SET 결과 = N'X 실패', 오류 = LEFT(ERROR_MESSAGE(), 400) WHERE ID = @i;
    END CATCH

    SET @i = @i + 1;
END

DECLARE @FAIL INT = (SELECT COUNT(*) FROM #P WHERE 결과 = N'X 실패');

INSERT INTO #R (CAT, ITEM, VAL, LEVEL, NOTE)
SELECT N'C.구문', N'2012 전용 구문 5종'
      ,CAST(5 - @FAIL AS NVARCHAR(10)) + N'/5 실행됨'
      ,CASE WHEN @FAIL = 0 THEN N'정보' ELSE N'치명' END
      ,CASE WHEN @FAIL = 0
            THEN N'46개 전부 실행 가능한 서버다'
            ELSE N'★ ' + CAST(@FAIL AS NVARCHAR(10))
               + N'종 실패 - 이 서버에서는 24개 리포트가 돌지 않는다. 출력 [2] 의 오류 메시지를 볼 것' END;


/*==============================================================================================
  D. 고아 사용자 — 복원 뒤 로그인이 끊긴 DB 사용자
==============================================================================================*/
INSERT INTO #R (CAT, ITEM, VAL, LEVEL, NOTE)
SELECT N'D.로그인', N'고아 사용자', CAST(COUNT(*) AS NVARCHAR(10)) + N'명'
      ,CASE WHEN COUNT(*) > 0 THEN N'경고' ELSE N'정보' END
      ,CASE WHEN COUNT(*) > 0
            THEN N'★ 서버 로그인과 연결이 끊긴 DB 사용자가 있다. 출력 [3] 참조'
            ELSE N'없음' END
FROM   sys.database_principals dp
LEFT   JOIN sys.server_principals sp ON sp.sid = dp.sid
WHERE  dp.type IN ('S', 'U')
  AND  dp.sid IS NOT NULL
  AND  dp.principal_id > 4
  AND  sp.sid IS NULL;


/*==============================================================================================
  ** 출력 1 : 점검 결과
==============================================================================================*/
SELECT
     N'[1] 이전 점검'                      AS REPORT_NM
    ,R.CAT                                 AS 구분
    ,R.ITEM                                AS 점검항목
    ,R.VAL                                 AS 측정값
    ,R.LEVEL                               AS 등급
    ,R.NOTE                                AS 판단_및_조치
FROM   #R R
ORDER BY CASE R.LEVEL WHEN N'치명' THEN 1 WHEN N'경고' THEN 2 ELSE 3 END, R.SEQ
;

/*==============================================================================================
  ** 출력 2 : ★ 2012 구문 실행 결과 — 이것이 결론이다
==============================================================================================*/
SELECT
     N'[2] ★ 구문 실행'                    AS REPORT_NM
    ,P.구문, P.쓰는곳, P.결과
    ,P.오류                                AS 오류메시지
FROM   #P P
ORDER BY CASE WHEN P.결과 = N'X 실패' THEN 0 ELSE 1 END, P.ID
;

/*==============================================================================================
  ** 출력 3 : 고아 사용자 목록과 복구 명령
==============================================================================================*/
SELECT
     N'[3] 고아 사용자'                    AS REPORT_NM
    ,dp.name                               AS DB사용자
    ,dp.type_desc                          AS 종류
    ,복구명령 = N'ALTER USER ' + QUOTENAME(dp.name)
              + N' WITH LOGIN = ' + QUOTENAME(dp.name) + N';'
    ,비고 = N'같은 이름의 서버 로그인을 먼저 만든 뒤 실행한다. 이름이 다르면 LOGIN = 부분을 바꿀 것'
FROM   sys.database_principals dp
LEFT   JOIN sys.server_principals sp ON sp.sid = dp.sid
WHERE  dp.type IN ('S', 'U')
  AND  dp.sid IS NOT NULL
  AND  dp.principal_id > 4
  AND  sp.sid IS NULL
ORDER BY dp.name
;

/*==============================================================================================
  ** 출력 4 : 종합 판정
==============================================================================================*/
SELECT
     N'[4] 종합 판정'                      AS REPORT_NM
    ,CONVERT(NVARCHAR(60), SERVERPROPERTY('ServerName'))          AS 인스턴스
    ,@VER + N' / compat ' + ISNULL(CAST(@COMPAT AS NVARCHAR(10)), N'?')  AS 엔진_호환성
    ,CONVERT(NVARCHAR(20), GETDATE(), 120)                        AS 점검시각
    ,구문실패 = @FAIL
    ,치명 = (SELECT COUNT(*) FROM #R WHERE LEVEL = N'치명')
    ,경고 = (SELECT COUNT(*) FROM #R WHERE LEVEL = N'경고')
    ,판정 = CASE
         WHEN @FAIL > 0 AND @VER_MAJ >= 11 AND @COMPAT < 110
              THEN N'1.★ 엔진은 되는데 호환성 수준이 ' + CAST(@COMPAT AS NVARCHAR(10))
                 + N' 이라 막혔다 - ALTER DATABASE 로 110 이상으로 올릴 것. 아래 [이전 절차] 5'
         WHEN @FAIL > 0
              THEN N'2.★★이 서버에서는 24개가 돌지 않는다 - 2012 이상 인스턴스로 옮길 것'
         WHEN (SELECT COUNT(*) FROM #R WHERE LEVEL = N'치명') > 0
              THEN N'3.★치명 항목이 있다 - 출력 [1] 을 먼저 볼 것'
         WHEN (SELECT COUNT(*) FROM #R WHERE LEVEL = N'경고') > 0
              THEN N'4.경고 항목 확인 후 진행'
         ELSE N'0.양호 - 46개 전부 실행 가능. Z00_사이트진단.sql 로 넘어갈 것' END
;

DROP TABLE #R, #P;
GO


/*==============================================================================================
  [ 이전 절차 ] — 2008 R2 인스턴스 → 2017 인스턴스
  ----------------------------------------------------------------------------------------------
  **전부 SSMS 쿼리 창에서 실행하는 T-SQL 이다.** PowerShell 명령을 SSMS 창에 붙이면
  `'$i' 근처의 구문이 잘못되었습니다` 같은 오류가 난다. 아래에는 셸 명령이 없다.

  **단계마다 접속 대상이 다르다.** SSMS 쿼리 창에서 우클릭 > [연결] > [연결 변경] 으로
  바꾸고, 창 아래 상태표시줄에서 지금 어디에 붙어 있는지 **매번 확인한다.**
  서버 이름은 목록에 없어도 직접 입력하면 된다 (`.\ICUBE`, `.\SQLEXPRESS01`).

  원본 인스턴스는 끝까지 건드리지 않는다. 잘못되면 되돌릴 자리가 거기다.
  되돌리기는 대상에서 `DROP DATABASE [DZICUBE];` 하나면 끝난다.

  ─ 1) 【원본】 이 파일을 먼저 실행한다 (기준값 확보)
        출력 [2] 가 5종 모두 'X 실패' 로 나온다. 그것이 지금 상태의 기준값이다.

  ─ 2) 【원본】과 【대상】 각각에서 경로·여유공간을 확인한다
        EXEC master.dbo.xp_fixeddrives;        -- 드라이브별 여유 MB

        DECLARE @p NVARCHAR(4000);
        EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',
             N'Software\Microsoft\MSSQLServer\MSSQLServer', N'BackupDirectory', @p OUTPUT;
        SELECT @p AS 기본백업경로;

        -- 대상에서는 데이터 파일을 놓을 경로도 함께 본다 (2012 이상에서만 나온다)
        SELECT SERVERPROPERTY('InstanceDefaultDataPath') AS 데이터경로
             , SERVERPROPERTY('InstanceDefaultLogPath')  AS 로그경로;

        ★ **각 인스턴스의 기본 백업 폴더를 쓴다.** 서비스 계정이 자기 폴더에 대한
          권한을 이미 갖고 있으므로, 공용 폴더를 만들고 icacls 로 권한을 주는 일을
          통째로 건너뛸 수 있다. 백업본 4.5GB + 복원본 4.5GB 가 들어갈 여유가 필요하다.

  ─ 3) 【원본】 전체 백업 — COPY_ONLY 라 기존 백업 체인을 건드리지 않는다
        BACKUP DATABASE [DZICUBE]
            TO DISK = N'<원본백업경로>DZICUBE_MIG.bak'
            WITH COPY_ONLY, INIT, CHECKSUM, STATS = 5;
        -- 압축(COMPRESSION)은 Express 에서 지원되지 않으므로 넣지 않는다
        -- 경로 끝에 역슬래시가 이미 붙어 있는지 확인할 것

  ─ 4) 【SSMS 밖】 파일 탐색기로 .bak 을 <대상백업경로> 폴더로 복사한다
        여기만 SSMS 밖에서 한다. 권한을 물으면 [계속] 을 누른다.

  ─ 5) 【대상】 논리 파일명 확인
        RESTORE FILELISTONLY FROM DISK = N'<대상백업경로>DZICUBE_MIG.bak';
        -- 결과 그리드의 LogicalName 열에서 데이터·로그 두 값을 적어 둔다

  ─ 6) 【대상】 복원 — 5 에서 본 논리명, 2 에서 본 데이터 경로를 쓴다
        RESTORE DATABASE [DZICUBE]
            FROM DISK = N'<대상백업경로>DZICUBE_MIG.bak'
            WITH MOVE N'<데이터 LogicalName>' TO N'<데이터경로>DZICUBE.mdf'
               , MOVE N'<로그 LogicalName>'   TO N'<로그경로>DZICUBE_log.ldf'
               , RECOVERY, STATS = 5;

  ─ 7) 【대상】 ★ 호환성 수준을 올린다 — 이것을 빠뜨리면 여기까지 온 의미가 없다
        ALTER DATABASE [DZICUBE] SET COMPATIBILITY_LEVEL = 140;   -- 2017 기본

        복원된 DB 는 원본의 호환성 수준(보통 100)을 **그대로 물고 온다.** 자동으로
        올라가지 않는다. LAG() 등은 110 이상을 요구하므로, 이 줄이 없으면 엔진이
        2017 이어도 24개가 그대로 실패한다.

        리포팅 전용 복제본이면 140. iCUBE 운영을 옮기는 것이면 110 부터 시작해
        단계적으로 올린다. 120 이상은 쿼리 최적화기(카디널리티 추정)가 바뀌어
        더존 저장프로시저의 실행계획이 달라질 수 있다.

  ─ 8) 【대상】 무결성·통계 정비 — 버전을 건너뛴 DB 는 이것을 한 번 해줘야 한다
        DBCC CHECKDB ([DZICUBE]) WITH DATA_PURITY, NO_INFOMSGS;
        GO
        USE DZICUBE;
        GO
        EXEC sp_updatestats;

  ─ 9) 【대상·DZICUBE】 구식 조인 확인
        더존 뷰·함수에 `*=` 가 있으면 호환성 수준 90 이상에서 깨진다
        SELECT o.type_desc, o.name
        FROM   sys.sql_modules m
        JOIN   sys.objects o ON o.object_id = m.object_id
        WHERE  m.definition LIKE N'%*=%' OR m.definition LIKE N'%=*%';
        -- 0 건이면 안전. 나오면 그 객체를 쓰는 리포트만 따로 점검한다

  ─ 10) 【대상】 로그인 정리 — 이 파일 출력 [3] 의 복구명령을 쓴다.
        원본과 같은 SID 로 만들어야 권한이 그대로 따라온다
        -- 원본에서 : SELECT name, sid FROM sys.server_principals WHERE principal_id > 4;
        -- 대상에서 : CREATE LOGIN [이름] WITH PASSWORD = 0x... HASHED, SID = 0x...;

  ─ 11) 【대상·DZICUBE】 **이 파일을 다시 실행** — 출력 [2] 가 5/5 실행됨이어야 한다
        1) 의 기준값과 나란히 놓고 비교한다. 그것이 이전이 끝났다는 증거다.

  ─ 12) 【대상·DZICUBE】 Z00_사이트진단.sql 실행
        출력 [3] 매트릭스에서 'X 엔진버전' 이 사라졌는지 확인한다.

  ----------------------------------------------------------------------------------------------
  [ 여기서 갈린다 — 무엇을 옮기는가 ]
  ----------------------------------------------------------------------------------------------
   ㉮ 리포팅 전용 복제본     iCUBE 는 기존 2008 R2 인스턴스에 그대로 둔다.
                             리포트만 2017 복제본에서 돌린다. **운영 위험 없음.**
                             데이터는 스냅숏이므로 야간 갱신이 필요하면 Express 에는
                             SQL Agent 가 없으니 Windows 작업 스케줄러 + sqlcmd 로 2~4 를 돌린다.

   ㉯ 운영 자체를 이전       iCUBE 접속 대상을 2017 인스턴스로 바꾼다. 추가로 필요한 것:
                             · 혼합 모드 인증 (출력 [1] A.인증 모드 확인)
                             · TCP/IP 사용 + 포트 지정 (기존과 같은 5539 를 쓰려면
                               원본 인스턴스를 먼저 중지해야 한다. 두 인스턴스가
                               같은 포트를 동시에 쓸 수 없다)
                             · SQL Server Browser 서비스
                             · **더존 인증 버전 확인이 선행되어야 한다**
                             · 되돌리기 : iCUBE 접속 대상을 원래대로 되돌리면 끝.
                               원본 DB 를 지우지 않았다면 언제든 복귀할 수 있다.

   어느 쪽이든 1~10 은 같다. 갈리는 것은 그다음뿐이다.

  ----------------------------------------------------------------------------------------------
  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
   ① 대상 인스턴스가 비어 있는가
        SELECT name FROM sys.databases WHERE database_id > 4;
   ② 대상 서버 데이터 정렬이 원본과 같은가 — 출력 [1] A.서버 데이터 정렬 비교
        다르면 tempdb 조인에서 정렬 충돌이 난다. 더존 저장프로시저는 임시테이블을
        많이 쓰므로, 운영을 옮기는 경우라면 **정렬이 다르면 인스턴스를 다시 설치**하는
        편이 낫다. 리포팅 복제본이면 COLLATE 로 넘길 수 있다.
   ③ 대상이 Express 인가 — 그렇다면 데이터 파일 합계가 10GB 안인지 (출력 [1] B.DB)
   ④ 대상 2017 에 최신 누적 업데이트(CU)가 적용되어 있는가. RTM 그대로면 먼저 올릴 것
   ⑤ 백업 파일을 둘 디스크 여유 — 원본 크기만큼 두 벌이 들어갈 공간

  ----------------------------------------------------------------------------------------------
  [ 한계 ]
  ----------------------------------------------------------------------------------------------
   · 이 파일은 **DB 하나**만 본다. 연결된 서버(linked server), SQL Agent 작업,
     서버 수준 트리거, 암호화 키는 보지 않는다. 운영을 옮기는 경우 그것들은 따로 옮겨야 한다.
   · 더존 iCUBE 응용프로그램이 특정 버전을 요구하는지는 알 수 없다. **벤더 확인 사항**이다.
   · 호환성 수준을 올리면 더존의 기존 저장프로시저 실행계획이 달라질 수 있다.
     이 파일은 그 영향을 예측하지 못한다. 운영 이전이라면 단계적으로 올리고 관찰할 것.
   · 구문 검사 C 는 **구문이 통과하는지**만 본다. 결과 숫자가 맞는지는 보지 않는다.
   · TCP 포트는 현재 접속이 TCP 일 때만 보인다. SSMS 를 같은 PC 에서 띄우면
     공유 메모리로 붙어 NULL 이 나온다 — 그것이 포트가 없다는 뜻은 아니다.
==============================================================================================*/
