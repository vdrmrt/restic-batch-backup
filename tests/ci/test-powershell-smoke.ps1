$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDirectory "..\.."))
$RunnerPath = Join-Path $RepoRoot "runners\restic-batch-backup.ps1"
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("restic-batch-backup-smoke-" + [System.Guid]::NewGuid().ToString("N"))
$ResticLog = Join-Path $TempRoot "restic.log"

function Fail-Test {
    param([Parameter(Mandatory = $true)][string]$Message)

    throw "TEST FAILURE: $Message"
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Haystack
    )

    if (-not $Haystack.Contains($Needle)) {
        Fail-Test -Message "Expected to find '$Needle'."
    }
}

function Assert-NotContains {
    param(
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Haystack
    )

    if ($Haystack.Contains($Needle)) {
        Fail-Test -Message "Did not expect to find '$Needle'."
    }
}

function Reset-ResticLog {
    Set-Content -LiteralPath $ResticLog -Value $null
}

function Get-ResticLogContent {
    if (-not (Test-Path -LiteralPath $ResticLog)) {
        return ""
    }

    return [string](Get-Content -LiteralPath $ResticLog -Raw)
}

function Convert-ToSnapshotPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $FullPath = [System.IO.Path]::GetFullPath($Path)
    $PathWithForwardSlashes = $FullPath.Replace("\", "/")

    if ($PathWithForwardSlashes -match "^([A-Za-z]):/?(.*)$") {
        $Drive = $Matches[1].ToUpperInvariant()
        $PathWithoutDrive = $Matches[2].TrimStart("/")

        if ([string]::IsNullOrWhiteSpace($PathWithoutDrive)) {
            return "/$Drive"
        }

        return "/$Drive/$PathWithoutDrive"
    }

    if ($PathWithForwardSlashes.StartsWith("/")) {
        return $PathWithForwardSlashes
    }

    return "/$PathWithForwardSlashes"
}

function Invoke-Runner {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RunnerPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $renderedOutput = ($output | Out-String).Trim()
        Fail-Test -Message "Runner failed with exit code $LASTEXITCODE.`n$renderedOutput"
    }

    return [string]($output | Out-String)
}

try {
    New-Item -Path $TempRoot -ItemType Directory -Force | Out-Null

    $BinDirectory = Join-Path $TempRoot "bin"
    $DocumentsDirectory = Join-Path $TempRoot "Documents"
    $PicturesDirectory = Join-Path $TempRoot "Pictures"
    $RestoreDirectory = Join-Path $TempRoot "restore-target"
    $LogsDirectory = Join-Path $TempRoot "logs"
    $PasswordFile = Join-Path $TempRoot "restic-password.txt"
    $IdentityFile = Join-Path $TempRoot "id_ed25519_test"
    $ConfigPath = Join-Path $TempRoot "config.json"
    $SftpConfigPath = Join-Path $TempRoot "sftp-config.json"
    $FakeResticPath = Join-Path $BinDirectory "restic.cmd"

    New-Item -Path $BinDirectory, $DocumentsDirectory, $PicturesDirectory, $LogsDirectory -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath $PasswordFile -Value "secret"
    Set-Content -LiteralPath $IdentityFile -Value "fake-key"

    @'
@echo off
setlocal EnableExtensions DisableDelayedExpansion
echo %*>>"%RESTIC_LOG%"
set "command_name="
:loop
if "%~1"=="" goto after_loop
if /I "%~1"=="init" set "command_name=init"
if /I "%~1"=="backup" set "command_name=backup"
if /I "%~1"=="snapshots" set "command_name=snapshots"
if /I "%~1"=="stats" set "command_name=stats"
if /I "%~1"=="restore" set "command_name=restore"
if /I "%~1"=="check" set "command_name=check"
if /I "%~1"=="forget" set "command_name=forget"
if defined command_name goto after_loop
shift
goto loop
:after_loop
if /I "%command_name%"=="init" echo created restic repository
if /I "%command_name%"=="backup" echo Files: 1 new, 0 changed, 0 unmodified
if /I "%command_name%"=="snapshots" echo ID        Time                 Host        Tags        Paths
if /I "%command_name%"=="stats" echo processed 2 files, 1.0 KiB in 0:00
if /I "%command_name%"=="restore" echo restored data
if /I "%command_name%"=="check" echo repository check OK
if /I "%command_name%"=="forget" echo removed old snapshots
exit /b 0
'@ | Set-Content -LiteralPath $FakeResticPath

    [Environment]::SetEnvironmentVariable("RESTIC_LOG", $ResticLog, "Process")
    [Environment]::SetEnvironmentVariable("PATH", "$BinDirectory;$env:PATH", "Process")

    $Config = [ordered]@{
        name = "powershell-smoke"
        repository = "local:$TempRoot\repo"
        passwordFile = $PasswordFile
        backupFolders = @(
            $DocumentsDirectory,
            $PicturesDirectory
        )
        excludeItems = @(
            "node_modules",
            ".cache"
        )
        retention = [ordered]@{
            keepDaily = 7
            keepWeekly = 4
            keepMonthly = 6
        }
        restore = [ordered]@{
            defaultTarget = $RestoreDirectory
        }
        logging = [ordered]@{
            folder = $LogsDirectory
        }
        backupTags = @(
            "powershell-smoke",
            "ci"
        )
    }

    $Config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath

    $SftpConfig = [ordered]@{
        name = "powershell-sftp-smoke"
        repository = "sftp:test-host:/tmp/repo"
        passwordFile = $PasswordFile
        backupFolders = @(
            $DocumentsDirectory
        )
        retention = [ordered]@{
            keepDaily = 7
            keepWeekly = 4
            keepMonthly = 6
        }
        restore = [ordered]@{
            defaultTarget = $RestoreDirectory
        }
        logging = [ordered]@{
            folder = $LogsDirectory
        }
        ssh = [ordered]@{
            identityFile = $IdentityFile
        }
    }

    $SftpConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $SftpConfigPath

    Reset-ResticLog
    Invoke-Runner -Arguments @("-Action", "init", "-ConfigPath", $ConfigPath) | Out-Null
    $InitLog = Get-ResticLogContent
    Assert-Contains -Needle " init" -Haystack $InitLog
    Assert-NotContains -Needle "sftp.args=" -Haystack $InitLog

    Reset-ResticLog
    Invoke-Runner -Arguments @("-Action", "init", "-ConfigPath", $SftpConfigPath) | Out-Null
    $SftpInitLog = Get-ResticLogContent
    Assert-Contains -Needle "sftp.args=-i" -Haystack $SftpInitLog
    Assert-Contains -Needle $IdentityFile -Haystack $SftpInitLog
    Assert-Contains -Needle "-o IdentitiesOnly=yes" -Haystack $SftpInitLog
    Assert-Contains -Needle "sftp:test-host:/tmp/repo init" -Haystack $SftpInitLog

    Reset-ResticLog
    Invoke-Runner -Arguments @("-Action", "backup", "-DryRun", "-ConfigPath", $ConfigPath) | Out-Null
    $BackupLog = Get-ResticLogContent
    Assert-Contains -Needle " backup " -Haystack $BackupLog
    Assert-Contains -Needle $DocumentsDirectory -Haystack $BackupLog
    Assert-Contains -Needle $PicturesDirectory -Haystack $BackupLog
    Assert-Contains -Needle "--exclude node_modules" -Haystack $BackupLog
    Assert-Contains -Needle "--exclude .cache" -Haystack $BackupLog
    Assert-Contains -Needle "--tag powershell-smoke" -Haystack $BackupLog
    Assert-Contains -Needle "--tag ci" -Haystack $BackupLog
    Assert-Contains -Needle "--dry-run" -Haystack $BackupLog

    Reset-ResticLog
    Invoke-Runner -Arguments @("-Action", "snapshots", "-ConfigPath", $ConfigPath) | Out-Null
    Assert-Contains -Needle " snapshots" -Haystack (Get-ResticLogContent)

    Reset-ResticLog
    Invoke-Runner -Arguments @("-Action", "status", "-ConfigPath", $ConfigPath) | Out-Null
    $StatusLog = Get-ResticLogContent
    Assert-Contains -Needle " snapshots" -Haystack $StatusLog
    Assert-Contains -Needle " stats latest" -Haystack $StatusLog

    Reset-ResticLog
    Invoke-Runner -Arguments @("-Action", "restore", "-Snapshot", "latest", "-DryRun", "-ConfigPath", $ConfigPath) | Out-Null
    $RestoreLog = Get-ResticLogContent
    Assert-Contains -Needle (" restore latest:{0}" -f (Convert-ToSnapshotPath -Path $DocumentsDirectory)) -Haystack $RestoreLog
    Assert-Contains -Needle (" restore latest:{0}" -f (Convert-ToSnapshotPath -Path $PicturesDirectory)) -Haystack $RestoreLog
    Assert-Contains -Needle "--dry-run" -Haystack $RestoreLog

    Reset-ResticLog
    Invoke-Runner -Arguments @("-Action", "check", "-ConfigPath", $ConfigPath) | Out-Null
    Assert-Contains -Needle " check" -Haystack (Get-ResticLogContent)

    Reset-ResticLog
    Invoke-Runner -Arguments @("-Action", "forget", "-ConfigPath", $ConfigPath) | Out-Null
    Assert-Contains -Needle " forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune" -Haystack (Get-ResticLogContent)

    Write-Host "PowerShell smoke tests passed."
}
finally {
    if (Test-Path -LiteralPath $TempRoot) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force
    }
}
