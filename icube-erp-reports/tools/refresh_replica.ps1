<#
  iCUBE 리포팅 복제본 갱신
  ==========================================================================
  운영 인스턴스의 DZICUBE 를 리포팅 전용 인스턴스로 복사한다.
  Express 에는 SQL Agent 가 없으므로 Windows 작업 스케줄러로 돌린다.

      [운영 .\ICUBE]  --COPY_ONLY 백업-->  복사  --복원-->  [리포팅 .\SQLEXPRESS01]
        건드리지 않음                                          매번 통째로 교체

  운영 DB 에 하는 일은 COPY_ONLY 전체 백업 하나뿐이다. 기존 백업 체인을
  건드리지 않고, 데이터도 스키마도 바꾸지 않는다.

  등록 (관리자 PowerShell) :
      $a = New-ScheduledTaskAction -Execute 'powershell.exe' `
             -Argument '-NoProfile -ExecutionPolicy Bypass -File "D:\Projects\sql\icube\tools\refresh_replica.ps1"'
      $t = New-ScheduledTaskTrigger -Daily -At 03:00
      $p = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest
      Register-ScheduledTask -TaskName 'iCUBE 리포팅 복제본 갱신' -Action $a -Trigger $t -Principal $p

  먼저 손으로 한 번 돌려 성공하는지 보고 나서 등록할 것.
==========================================================================#>

[CmdletBinding()]
param(
    # 운영(원본) 인스턴스. 읽기만 한다
    [string] $SourceInstance = '.\ICUBE',
    # 리포팅(대상) 인스턴스. 매번 통째로 덮어쓴다
    [string] $TargetInstance = '.\SQLEXPRESS01',
    [string] $Database       = 'DZICUBE',
    # 2017 은 140. 110 미만이면 LAG 등이 막혀 24개 리포트가 실패한다
    [int]    $CompatLevel    = 140,
    # 복제본을 읽기 전용으로 잠근다. 실수로 쓰는 것을 막는다
    [switch] $ReadOnly,
    # 끝난 뒤 백업 파일을 남긴다 (기본은 지운다 — 매번 4~5GB 다)
    [switch] $KeepBackup,
    [string] $LogDir = "$env:ProgramData\icube-replica"
)

$ErrorActionPreference = 'Stop'
$BakName = "${Database}_REPL.bak"

# ─ 로그 ────────────────────────────────────────────────────────────────
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir ("refresh_{0:yyyyMMdd}.log" -f (Get-Date))

function Write-Log {
    param([string] $Message, [string] $Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

# ─ sqlcmd 호출 ─────────────────────────────────────────────────────────
# T-SQL 은 ASCII 로만 쓴다. 한글을 -Q 로 넘기면 코드페이지에 따라 깨진다.
function Invoke-Sql {
    param([string] $Instance, [string] $Sql, [switch] $Scalar)
    # $args 는 PowerShell 자동 변수라 덮어쓰지 않는다
    $sqlArgs = @('-S', $Instance, '-E', '-b')
    if ($Scalar) { $sqlArgs += @('-h', '-1', '-W') }
    $sqlArgs += @('-Q', $Sql)
    $out = & sqlcmd @sqlArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "sqlcmd 실패 ($Instance, 종료코드 $LASTEXITCODE)`n$($out -join [Environment]::NewLine)"
    }
    return ($out | Where-Object { $_ -ne '' })
}

function Get-Scalar {
    param([string] $Instance, [string] $Select)
    $r = Invoke-Sql -Instance $Instance -Scalar -Sql "SET NOCOUNT ON; $Select"
    return ($r | Select-Object -First 1).ToString().Trim()
}

if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    Write-Log 'sqlcmd 를 찾을 수 없다. SSMS 또는 SQL Server Command Line Utilities 를 설치하거나 PATH 에 넣을 것' 'ERROR'
    exit 1
}

$sw = [Diagnostics.Stopwatch]::StartNew()
Write-Log "=== 갱신 시작 : $SourceInstance -> $TargetInstance ($Database) ==="

try {
    # ─ 1. 경로 조회 ────────────────────────────────────────────────────
    $regread = @'
DECLARE @p NVARCHAR(4000);
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',
     N'Software\Microsoft\MSSQLServer\MSSQLServer', N'BackupDirectory', @p OUTPUT;
SELECT CASE WHEN RIGHT(@p,1) = N'\' THEN LEFT(@p, LEN(@p)-1) ELSE @p END;
'@
    $srcBakDir = Get-Scalar -Instance $SourceInstance -Select $regread
    $tgtBakDir = Get-Scalar -Instance $TargetInstance -Select $regread
    $tgtDataDir = Get-Scalar -Instance $TargetInstance `
        -Select "SELECT CONVERT(NVARCHAR(4000), SERVERPROPERTY('InstanceDefaultDataPath'));"

    if ([string]::IsNullOrWhiteSpace($tgtDataDir) -or $tgtDataDir -eq 'NULL') {
        throw "대상 인스턴스의 기본 데이터 경로를 읽지 못했다. 2012 미만 인스턴스를 가리키고 있지 않은지 확인할 것."
    }
    $srcBak = Join-Path $srcBakDir $BakName
    $tgtBak = Join-Path $tgtBakDir $BakName
    Write-Log "원본 백업 : $srcBak"
    Write-Log "대상 백업 : $tgtBak"
    Write-Log "대상 데이터: $tgtDataDir"

    # ─ 2. 원본 백업 (COPY_ONLY — 운영 백업 체인을 건드리지 않는다) ────
    Write-Log '백업 중...'
    Invoke-Sql -Instance $SourceInstance -Sql (
        "BACKUP DATABASE [$Database] TO DISK = N'$srcBak' " +
        "WITH COPY_ONLY, INIT, CHECKSUM, STATS = 10;") | Out-Null
    $sizeGb = [math]::Round((Get-Item $srcBak).Length / 1GB, 2)
    Write-Log "백업 완료 ($sizeGb GB)"

    # ─ 3. 대상 백업 폴더로 복사 ────────────────────────────────────────
    # 각 인스턴스는 자기 기본 백업 폴더 권한만 갖고 있다. 공용 폴더를 만들고
    # 권한을 주는 대신 복사한다 — 이 스크립트를 돌리는 계정이 둘 다 접근한다.
    if ($srcBak -ne $tgtBak) {
        Write-Log '복사 중...'
        Copy-Item -LiteralPath $srcBak -Destination $tgtBak -Force
    }

    # ─ 4. 복원 ─────────────────────────────────────────────────────────
    # 논리 파일명은 백업에서 읽어 쓴다. 손으로 적으면 더존이 파일그룹을
    # 추가했을 때 조용히 어긋난다.
    #
    # ★ 안전장치 : 복원 대상 경로가 원본 파일 경로와 같으면 중단한다.
    #   MOVE 를 빠뜨리면 운영 파일을 덮어쓰러 간다. 그 시도 자체를 막는다.
    $restore = @'
SET NOCOUNT ON;
-- 접속 기본 DB 가 복제본이면 자기 자신을 복원할 수 없다. master 로 옮겨둔다
USE master;

DECLARE @bak NVARCHAR(4000) = N'{BAK}';
DECLARE @dir NVARCHAR(4000) = N'{DIR}';
DECLARE @db  SYSNAME        = N'{DB}';

IF OBJECT_ID(N'tempdb..#fl') IS NOT NULL DROP TABLE #fl;
CREATE TABLE #fl (
     LogicalName NVARCHAR(128), PhysicalName NVARCHAR(260), [Type] CHAR(1)
    ,FileGroupName NVARCHAR(128), Size NUMERIC(20,0), MaxSize NUMERIC(20,0)
    ,FileId BIGINT, CreateLSN NUMERIC(25,0), DropLSN NUMERIC(25,0)
    ,UniqueId UNIQUEIDENTIFIER, ReadOnlyLSN NUMERIC(25,0), ReadWriteLSN NUMERIC(25,0)
    ,BackupSizeInBytes BIGINT, SourceBlockSize INT, FileGroupId INT
    ,LogGroupGUID UNIQUEIDENTIFIER, DifferentialBaseLSN NUMERIC(25,0)
    ,DifferentialBaseGUID UNIQUEIDENTIFIER, IsReadOnly BIT, IsPresent BIT
    ,TDEThumbprint VARBINARY(32), SnapshotUrl NVARCHAR(360)
);
INSERT INTO #fl EXEC(N'RESTORE FILELISTONLY FROM DISK = N''' + @bak + N'''');

-- 계산 열은 변수를 참조할 수 없다. 일반 열에 채운다
ALTER TABLE #fl ADD NewPath NVARCHAR(400) NULL;
UPDATE #fl SET NewPath = @dir
    + CASE WHEN [Type] = 'L' THEN @db + N'_log.ldf'
           WHEN FileId = 1   THEN @db + N'.mdf'
           ELSE @db + N'_' + CAST(FileId AS NVARCHAR(10)) + N'.ndf' END;

-- ★ 안전장치 : 복원 대상이 원본 파일 경로와 같으면 운영 파일을 덮어쓰러 간다.
--   MOVE 가 어긋나는 사고를 여기서 끊는다.
IF EXISTS (SELECT 1 FROM #fl WHERE PhysicalName = NewPath)
BEGIN
    RAISERROR(N'ABORT: restore target equals source file path.', 16, 1);
    RETURN;
END

-- SELECT @sql = @sql + ... 는 순서가 보장되지 않는다. 커서로 확정한다
DECLARE @sql NVARCHAR(MAX) =
    N'RESTORE DATABASE ' + QUOTENAME(@db) + N' FROM DISK = N''' + @bak + N''' WITH ';
DECLARE @ln NVARCHAR(128), @np NVARCHAR(400);
DECLARE fc CURSOR LOCAL FAST_FORWARD FOR
    SELECT LogicalName, NewPath FROM #fl ORDER BY FileId;
OPEN fc; FETCH NEXT FROM fc INTO @ln, @np;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = @sql + N'MOVE N''' + @ln + N''' TO N''' + @np + N''', ';
    FETCH NEXT FROM fc INTO @ln, @np;
END
CLOSE fc; DEALLOCATE fc;
SET @sql = @sql + N'REPLACE, RECOVERY, STATS = 10;';
DROP TABLE #fl;

-- 온라인일 때만 세션을 끊는다. 지난번 복원이 끊겨 RESTORING 으로 남아 있으면
-- ALTER DATABASE 가 거부되므로, 그때는 건너뛰고 바로 덮어쓴다.
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = @db AND state = 0)
BEGIN
    DECLARE @x NVARCHAR(400) =
        N'ALTER DATABASE ' + QUOTENAME(@db) + N' SET READ_WRITE;'
      + N'ALTER DATABASE ' + QUOTENAME(@db) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;';
    EXEC sp_executesql @x;
END

EXEC sp_executesql @sql;

EXEC sp_executesql N'ALTER DATABASE {DBQ} SET MULTI_USER;';
EXEC sp_executesql N'ALTER DATABASE {DBQ} SET COMPATIBILITY_LEVEL = {COMPAT};';
'@
    $restore = $restore.Replace('{BAK}', $tgtBak).Replace('{DIR}', $tgtDataDir) `
                       .Replace('{DBQ}', "[$Database]").Replace('{DB}', $Database) `
                       .Replace('{COMPAT}', $CompatLevel.ToString())
    Write-Log '복원 중...'
    Invoke-Sql -Instance $TargetInstance -Sql $restore | Out-Null

    # ─ 5. 통계 갱신 ────────────────────────────────────────────────────
    Write-Log '통계 갱신 중...'
    Invoke-Sql -Instance $TargetInstance -Sql "USE [$Database]; EXEC sp_updatestats;" | Out-Null

    # ─ 6. 검증 — 2012 구문이 실제로 도는지 돌려서 확인한다 ─────────────
    # 버전·호환성 수준을 조합해 추론하지 않는다. 복원이 성공해도 호환성
    # 수준이 100 으로 돌아가 있으면 24개 리포트가 조용히 실패한다.
    $verify = @'
SET NOCOUNT ON;
USE {DBQ};
DECLARE @fail INT = 0, @i INT = 1, @sql NVARCHAR(400);
WHILE @i <= 5
BEGIN
    SET @sql = CASE @i
        WHEN 1 THEN N'SELECT TOP 0 LAG(N.n) OVER (ORDER BY N.n) FROM (SELECT 1 AS n) N'
        WHEN 2 THEN N'SELECT TOP 0 SUM(N.n) OVER (ORDER BY N.n) FROM (SELECT 1 AS n) N'
        WHEN 3 THEN N'SELECT TOP 0 SUM(N.n) OVER (ORDER BY N.n ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM (SELECT 1 AS n) N'
        WHEN 4 THEN N'SELECT TOP 0 PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY N.n) OVER () FROM (SELECT 1 AS n) N'
        ELSE        N'SELECT TOP 0 EOMONTH(GETDATE())' END;
    BEGIN TRY  EXEC sp_executesql @sql;  END TRY
    BEGIN CATCH SET @fail = @fail + 1;   END CATCH
    SET @i = @i + 1;
END
SELECT CAST(5 - @fail AS NVARCHAR(2)) + N'/5|'
     + CAST((SELECT compatibility_level FROM sys.databases WHERE name = N'{DB}') AS NVARCHAR(5));
'@
    $verify = $verify.Replace('{DBQ}', "[$Database]").Replace('{DB}', $Database)
    $r = (Get-Scalar -Instance $TargetInstance -Select $verify) -split '\|'
    Write-Log "검증 : 2012 구문 $($r[0]) · 호환성 수준 $($r[1])"
    if ($r[0] -ne '5/5') {
        throw "2012 구문 검사 $($r[0]) — 복제본에서 24개 리포트가 실패한다. 호환성 수준($($r[1]))을 확인할 것."
    }

    # ─ 7. 읽기 전용 잠금 (선택) ────────────────────────────────────────
    if ($ReadOnly) {
        Invoke-Sql -Instance $TargetInstance `
            -Sql "ALTER DATABASE [$Database] SET READ_ONLY WITH ROLLBACK IMMEDIATE;" | Out-Null
        Write-Log '복제본을 읽기 전용으로 잠갔다'
    }

    # ─ 8. 정리 ─────────────────────────────────────────────────────────
    if (-not $KeepBackup) {
        Remove-Item -LiteralPath $srcBak -Force -ErrorAction SilentlyContinue
        if ($srcBak -ne $tgtBak) { Remove-Item -LiteralPath $tgtBak -Force -ErrorAction SilentlyContinue }
        Write-Log '백업 파일 정리'
    }

    $sw.Stop()
    Write-Log ("=== 갱신 완료 ({0:mm\:ss}) ===" -f $sw.Elapsed)
    exit 0
}
catch {
    $sw.Stop()
    Write-Log $_.Exception.Message 'ERROR'
    Write-Log '=== 갱신 실패 — 운영 DB 는 영향받지 않았다 ===' 'ERROR'
    # 복원이 중간에 끊기면 복제본이 RESTORING 상태로 남는다. 다음 실행의
    # REPLACE 가 덮어쓰므로 손댈 필요는 없지만, 그때까지 복제본은 못 쓴다.
    exit 1
}
