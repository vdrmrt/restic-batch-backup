[CmdletBinding()]
param(
    [ValidateSet("init", "backup", "snapshots", "status", "restore", "check", "forget")]
    [string]$Action = "backup",

    [string]$ConfigPath = "$PSScriptRoot\..\config.json",

    [string]$Snapshot = "latest",

    [string]$RestoreTarget,

    [switch]$AllowNonEmptyRestoreTarget,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ScriptStartTime = Get-Date
$FinalExitCode = 0

function Write-Info {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[INFO] $Message"
}

function Write-Failure {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Title)
    Write-Host ""
    Write-Host "== $Title =="
}

function Test-IsBlank {
    param([object]$Value)

    if ($null -eq $Value) {
        return $true
    }

    if ($Value -is [string]) {
        return [string]::IsNullOrWhiteSpace($Value)
    }

    if ($Value -is [System.Array]) {
        return $Value.Count -eq 0
    }

    return $false
}

function Get-ConfigProperty {
    param(
        [object]$Source,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Source) {
        return $null
    }

    $Property = $Source.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($null -eq $Property) {
        return $null
    }

    return $Property.Value
}

function Get-RequiredConfigProperty {
    param(
        [object]$Source,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    $Value = Get-ConfigProperty -Source $Source -Name $Name
    if (Test-IsBlank -Value $Value) {
        throw "Missing required config value '$DisplayName'."
    }

    return $Value
}

function Expand-ConfigString {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    return [Environment]::ExpandEnvironmentVariables([string]$Value)
}

function Expand-ConfigStringArray {
    param([object]$Value)

    $ExpandedValues = New-Object System.Collections.Generic.List[string]
    foreach ($Item in @($Value)) {
        $ExpandedItem = Expand-ConfigString -Value $Item
        if (-not [string]::IsNullOrWhiteSpace($ExpandedItem)) {
            [void]$ExpandedValues.Add($ExpandedItem)
        }
    }

    return $ExpandedValues.ToArray()
}

function Convert-ToConfigInteger {
    param(
        [object]$Value,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    try {
        $IntegerValue = [int]$Value
    }
    catch {
        throw "Config value '$DisplayName' must be an integer."
    }

    if ($IntegerValue -lt 0) {
        throw "Config value '$DisplayName' must be zero or greater."
    }

    return $IntegerValue
}

function Convert-ToFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $ExpandedPath = Expand-ConfigString -Value $Path
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ExpandedPath)
}

function Convert-ToConfigPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ConfigDirectory
    )

    $ExpandedPath = Expand-ConfigString -Value $Path
    if ([System.IO.Path]::IsPathRooted($ExpandedPath)) {
        return [System.IO.Path]::GetFullPath($ExpandedPath)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $ConfigDirectory $ExpandedPath))
}

function Read-BackupConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    $FullConfigPath = Convert-ToFullPath -Path $Path
    if (-not (Test-Path -LiteralPath $FullConfigPath -PathType Leaf)) {
        throw "Config file not found: $FullConfigPath"
    }

    try {
        $RawJson = Get-Content -LiteralPath $FullConfigPath -Raw
        $RawConfig = $RawJson | ConvertFrom-Json
    }
    catch {
        throw "Failed to read JSON config '$FullConfigPath': $($_.Exception.Message)"
    }

    if ($null -eq $RawConfig -or $RawConfig -is [System.Array]) {
        throw "Config file must contain a single JSON object: $FullConfigPath"
    }

    $ConfigDirectory = Split-Path -Parent $FullConfigPath
    $Retention = Get-RequiredConfigProperty -Source $RawConfig -Name "retention" -DisplayName "retention"
    $Restore = Get-RequiredConfigProperty -Source $RawConfig -Name "restore" -DisplayName "restore"

    $Name = Expand-ConfigString -Value (Get-RequiredConfigProperty -Source $RawConfig -Name "name" -DisplayName "name")
    $Repository = Expand-ConfigString -Value (Get-RequiredConfigProperty -Source $RawConfig -Name "repository" -DisplayName "repository")
    $PasswordFile = Convert-ToConfigPath -Path (Get-RequiredConfigProperty -Source $RawConfig -Name "passwordFile" -DisplayName "passwordFile") -ConfigDirectory $ConfigDirectory
    $BackupFolders = @(Expand-ConfigStringArray -Value (Get-RequiredConfigProperty -Source $RawConfig -Name "backupFolders" -DisplayName "backupFolders") | ForEach-Object {
        Convert-ToConfigPath -Path $_ -ConfigDirectory $ConfigDirectory
    })

    if ($BackupFolders.Count -eq 0) {
        throw "Config value 'backupFolders' must contain at least one folder."
    }

    $ExcludeItems = @(Expand-ConfigStringArray -Value (Get-ConfigProperty -Source $RawConfig -Name "excludeItems"))
    $BackupTags = @(Expand-ConfigStringArray -Value (Get-ConfigProperty -Source $RawConfig -Name "backupTags"))
    $Logging = Get-ConfigProperty -Source $RawConfig -Name "logging"
    $LoggingFolderValue = Expand-ConfigString -Value (Get-ConfigProperty -Source $Logging -Name "folder")

    if ([string]::IsNullOrWhiteSpace($LoggingFolderValue)) {
        $LoggingFolderValue = "%USERPROFILE%\.restic\logs"
    }

    return [pscustomobject]@{
        Name = $Name
        Repository = $Repository
        PasswordFile = $PasswordFile
        BackupFolders = $BackupFolders
        ExcludeItems = $ExcludeItems
        BackupTags = $BackupTags
        KeepDaily = Convert-ToConfigInteger -Value (Get-RequiredConfigProperty -Source $Retention -Name "keepDaily" -DisplayName "retention.keepDaily") -DisplayName "retention.keepDaily"
        KeepWeekly = Convert-ToConfigInteger -Value (Get-RequiredConfigProperty -Source $Retention -Name "keepWeekly" -DisplayName "retention.keepWeekly") -DisplayName "retention.keepWeekly"
        KeepMonthly = Convert-ToConfigInteger -Value (Get-RequiredConfigProperty -Source $Retention -Name "keepMonthly" -DisplayName "retention.keepMonthly") -DisplayName "retention.keepMonthly"
        DefaultRestoreTarget = Convert-ToConfigPath -Path (Get-RequiredConfigProperty -Source $Restore -Name "defaultTarget" -DisplayName "restore.defaultTarget") -ConfigDirectory $ConfigDirectory
        LoggingFolder = Convert-ToConfigPath -Path $LoggingFolderValue -ConfigDirectory $ConfigDirectory
        ConfigPath = $FullConfigPath
    }
}

function Assert-ResticAvailable {
    if ($null -eq (Get-Command restic -ErrorAction SilentlyContinue)) {
        throw "Restic is not installed or is not available on PATH."
    }
}

function Assert-PasswordFileExists {
    param([Parameter(Mandatory = $true)][object]$Config)

    if (-not (Test-Path -LiteralPath $Config.PasswordFile -PathType Leaf)) {
        throw "Restic password file not found: $($Config.PasswordFile)"
    }
}

function Format-TimeSpan {
    param([Parameter(Mandatory = $true)][TimeSpan]$Duration)

    if ($Duration.TotalDays -ge 1) {
        return "{0:dd\.hh\:mm\:ss}" -f $Duration
    }

    if ($Duration.TotalHours -ge 1) {
        return "{0:hh\:mm\:ss}" -f $Duration
    }

    return "{0:mm\:ss}" -f $Duration
}

function Format-ResticArgument {
    param([Parameter(Mandatory = $true)][string]$Argument)

    if ($Argument -match "\s") {
        return '"' + $Argument.Replace('"', '\"') + '"'
    }

    return $Argument
}

function Invoke-ResticCommand {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $DisplayArguments = @($Arguments | ForEach-Object { Format-ResticArgument -Argument $_ }) -join " "
    Write-Info "Running: restic $DisplayArguments"

    & restic @Arguments | ForEach-Object { Write-Host $_ }

    if ($null -eq $LASTEXITCODE) {
        $ResticExitCode = 0
    }
    else {
        $ResticExitCode = [int]$LASTEXITCODE
    }

    Write-Info "Restic exit code: $ResticExitCode"
    return $ResticExitCode
}

function Add-RepeatedResticOption {
    param(
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[string]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Option,
        [string[]]$Values
    )

    foreach ($Value in @($Values)) {
        if (-not [string]::IsNullOrWhiteSpace($Value)) {
            [void]$Arguments.Add($Option)
            [void]$Arguments.Add($Value)
        }
    }
}

function Get-ValidBackupFolders {
    param([Parameter(Mandatory = $true)][object]$Config)

    $ValidFolders = New-Object System.Collections.Generic.List[string]
    foreach ($BackupFolder in $Config.BackupFolders) {
        if (Test-Path -LiteralPath $BackupFolder -PathType Container) {
            $ResolvedFolder = (Resolve-Path -LiteralPath $BackupFolder).Path
            [void]$ValidFolders.Add($ResolvedFolder)
        }
        else {
            Write-Warning "Backup folder not found; skipping: $BackupFolder"
        }
    }

    if ($ValidFolders.Count -eq 0) {
        throw "No valid backup folders remain after checking configured folders."
    }

    return $ValidFolders.ToArray()
}

function Get-NormalizedFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $FullPath = [System.IO.Path]::GetFullPath($Path)
    return $FullPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

function Test-PathsOverlap {
    param(
        [Parameter(Mandatory = $true)][string]$FirstPath,
        [Parameter(Mandatory = $true)][string]$SecondPath
    )

    $FirstNormalized = (Get-NormalizedFullPath -Path $FirstPath) + [System.IO.Path]::DirectorySeparatorChar
    $SecondNormalized = (Get-NormalizedFullPath -Path $SecondPath) + [System.IO.Path]::DirectorySeparatorChar

    return $FirstNormalized.StartsWith($SecondNormalized, [System.StringComparison]::OrdinalIgnoreCase) -or $SecondNormalized.StartsWith($FirstNormalized, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-RestoreTargetIsSafe {
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][string]$EffectiveRestoreTarget
    )

    foreach ($BackupFolder in $Config.BackupFolders) {
        if (Test-PathsOverlap -FirstPath $EffectiveRestoreTarget -SecondPath $BackupFolder) {
            throw "Restore target overlaps a configured backup folder. Choose a separate restore target. Target: $EffectiveRestoreTarget Backup folder: $BackupFolder"
        }
    }
}

function Test-DirectoryHasContent {
    param([Parameter(Mandatory = $true)][string]$Path)

    $FirstChild = Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1
    return $null -ne $FirstChild
}

function Assert-RestoreTargetCanBeUsed {
    param(
        [Parameter(Mandatory = $true)][string]$EffectiveRestoreTarget,
        [switch]$AllowNonEmptyTarget,
        [switch]$CreateIfMissing
    )

    if (Test-Path -LiteralPath $EffectiveRestoreTarget -PathType Leaf) {
        throw "Restore target is a file, not a folder: $EffectiveRestoreTarget"
    }

    if (-not (Test-Path -LiteralPath $EffectiveRestoreTarget -PathType Container)) {
        if ($CreateIfMissing) {
            New-Item -Path $EffectiveRestoreTarget -ItemType Directory -Force | Out-Null
        }

        return
    }

    if ((Test-DirectoryHasContent -Path $EffectiveRestoreTarget) -and -not $AllowNonEmptyTarget) {
        throw "Restore target is not empty: $EffectiveRestoreTarget. Choose a new empty folder or rerun with -AllowNonEmptyRestoreTarget."
    }
}

function Convert-ToResticSnapshotPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $FullPath = Get-NormalizedFullPath -Path $Path
    $PathWithForwardSlashes = $FullPath.Replace([System.IO.Path]::DirectorySeparatorChar, "/").Replace([System.IO.Path]::AltDirectorySeparatorChar, "/")

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

function Convert-ToRestoreFolderName {
    param([Parameter(Mandatory = $true)][string]$Path)

    $LeafName = Split-Path -Path (Get-NormalizedFullPath -Path $Path) -Leaf
    if (-not [string]::IsNullOrWhiteSpace($LeafName)) {
        return $LeafName
    }

    return (Convert-ToResticSnapshotPath -Path $Path).TrimStart("/").Replace("/", "_")
}

function Get-RestoreFolderPlan {
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][string]$EffectiveRestoreTarget
    )

    $Plans = New-Object System.Collections.Generic.List[object]
    $FolderNameCounts = @{}

    foreach ($BackupFolder in $Config.BackupFolders) {
        $FolderName = Convert-ToRestoreFolderName -Path $BackupFolder
        $FolderNameKey = $FolderName.ToLowerInvariant()

        if (-not $FolderNameCounts.ContainsKey($FolderNameKey)) {
            $FolderNameCounts[$FolderNameKey] = 0
        }

        $FolderNameCounts[$FolderNameKey] += 1

        [void]$Plans.Add([pscustomobject]@{
            BackupFolder = $BackupFolder
            SnapshotPath = Convert-ToResticSnapshotPath -Path $BackupFolder
            FolderName = $FolderName
            RestoreTarget = $null
        })
    }

    foreach ($Plan in $Plans) {
        $FolderNameKey = $Plan.FolderName.ToLowerInvariant()
        $TargetFolderName = $Plan.FolderName
        if ($FolderNameCounts[$FolderNameKey] -gt 1) {
            $TargetFolderName = $Plan.SnapshotPath.TrimStart("/").Replace("/", "_")
        }

        $Plan.RestoreTarget = Join-Path $EffectiveRestoreTarget $TargetFolderName
    }

    return $Plans.ToArray()
}

function Test-SnapshotSpecIncludesPath {
    param([Parameter(Mandatory = $true)][string]$SnapshotId)

    return $SnapshotId -match "^[^:]+:.+"
}

function Show-ConfigSummary {
    param([Parameter(Mandatory = $true)][object]$Config)

    Write-Section "Configuration"
    Write-Info "Name: $($Config.Name)"
    Write-Info "Config path: $($Config.ConfigPath)"
    Write-Info "Repository: $($Config.Repository)"
    Write-Info "Password file: $($Config.PasswordFile)"
    Write-Info "Log folder: $($Config.LoggingFolder)"
    Write-Info "Retention: daily=$($Config.KeepDaily), weekly=$($Config.KeepWeekly), monthly=$($Config.KeepMonthly)"

    Write-Info "Backup folders:"
    foreach ($BackupFolder in $Config.BackupFolders) {
        Write-Host "  - $BackupFolder"
    }

    Write-Info "Exclude items:"
    if ($Config.ExcludeItems.Count -eq 0) {
        Write-Host "  - none"
    }
    else {
        foreach ($ExcludeItem in $Config.ExcludeItems) {
            Write-Host "  - $ExcludeItem"
        }
    }
}

function Invoke-InitAction {
    param([Parameter(Mandatory = $true)][object]$Config)

    $Arguments = @("-r", $Config.Repository, "init")
    $ExitCode = Invoke-ResticCommand -Arguments $Arguments
    if ($ExitCode -ne 0) {
        Write-Warning "If the repository is already initialized, no action may be needed. Review the Restic output above."
    }

    return $ExitCode
}

function Invoke-BackupAction {
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [switch]$UseDryRun
    )

    $ValidBackupFolders = @(Get-ValidBackupFolders -Config $Config)
    $Arguments = New-Object System.Collections.Generic.List[string]
    [void]$Arguments.Add("-r")
    [void]$Arguments.Add($Config.Repository)
    [void]$Arguments.Add("backup")

    foreach ($BackupFolder in $ValidBackupFolders) {
        [void]$Arguments.Add($BackupFolder)
    }

    Add-RepeatedResticOption -Arguments $Arguments -Option "--exclude" -Values $Config.ExcludeItems
    Add-RepeatedResticOption -Arguments $Arguments -Option "--tag" -Values $Config.BackupTags

    if ($UseDryRun) {
        [void]$Arguments.Add("--dry-run")
    }

    $BackupStartTime = Get-Date
    $ExitCode = Invoke-ResticCommand -Arguments $Arguments.ToArray()
    $BackupDuration = (Get-Date) - $BackupStartTime
    Write-Info "Backup duration: $(Format-TimeSpan -Duration $BackupDuration)"

    return $ExitCode
}

function Invoke-SnapshotsAction {
    param([Parameter(Mandatory = $true)][object]$Config)

    return Invoke-ResticCommand -Arguments @("-r", $Config.Repository, "snapshots")
}

function Invoke-StatusAction {
    param([Parameter(Mandatory = $true)][object]$Config)

    Show-ConfigSummary -Config $Config

    Write-Section "Snapshots"
    $SnapshotExitCode = Invoke-ResticCommand -Arguments @("-r", $Config.Repository, "snapshots")
    if ($SnapshotExitCode -ne 0) {
        return $SnapshotExitCode
    }

    Write-Section "Stats"
    return Invoke-ResticCommand -Arguments @("-r", $Config.Repository, "stats", "latest")
}

function Invoke-RestoreAction {
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][string]$SnapshotId,
        [string]$RequestedRestoreTarget,
        [switch]$UseDryRun,
        [switch]$AllowNonEmptyTarget
    )

    $EffectiveRestoreTarget = $RequestedRestoreTarget
    if ([string]::IsNullOrWhiteSpace($EffectiveRestoreTarget)) {
        $EffectiveRestoreTarget = $Config.DefaultRestoreTarget
    }

    $EffectiveRestoreTarget = Convert-ToFullPath -Path $EffectiveRestoreTarget
    Assert-RestoreTargetIsSafe -Config $Config -EffectiveRestoreTarget $EffectiveRestoreTarget
    Assert-RestoreTargetCanBeUsed -EffectiveRestoreTarget $EffectiveRestoreTarget -AllowNonEmptyTarget:$AllowNonEmptyTarget -CreateIfMissing:(-not $UseDryRun)

    if ($AllowNonEmptyTarget) {
        Write-Warning "Restore target may already contain files: $EffectiveRestoreTarget"
    }

    if (Test-SnapshotSpecIncludesPath -SnapshotId $SnapshotId) {
        $Arguments = New-Object System.Collections.Generic.List[string]
        [void]$Arguments.Add("-r")
        [void]$Arguments.Add($Config.Repository)
        [void]$Arguments.Add("restore")
        [void]$Arguments.Add($SnapshotId)
        [void]$Arguments.Add("--target")
        [void]$Arguments.Add($EffectiveRestoreTarget)

        if ($UseDryRun) {
            [void]$Arguments.Add("--dry-run")
        }

        Write-Warning "Restoring snapshot path '$SnapshotId' to '$EffectiveRestoreTarget'."
        return Invoke-ResticCommand -Arguments $Arguments.ToArray()
    }

    $RestorePlans = @(Get-RestoreFolderPlan -Config $Config -EffectiveRestoreTarget $EffectiveRestoreTarget)
    foreach ($RestorePlan in $RestorePlans) {
        $SnapshotSpec = "{0}:{1}" -f $SnapshotId, $RestorePlan.SnapshotPath
        $Arguments = New-Object System.Collections.Generic.List[string]
        [void]$Arguments.Add("-r")
        [void]$Arguments.Add($Config.Repository)
        [void]$Arguments.Add("restore")
        [void]$Arguments.Add($SnapshotSpec)
        [void]$Arguments.Add("--target")
        [void]$Arguments.Add($RestorePlan.RestoreTarget)

        if ($UseDryRun) {
            [void]$Arguments.Add("--dry-run")
        }

        Write-Warning "Restoring '$($RestorePlan.BackupFolder)' from snapshot '$SnapshotId' to '$($RestorePlan.RestoreTarget)'."
        $ExitCode = Invoke-ResticCommand -Arguments $Arguments.ToArray()
        if ($ExitCode -ne 0) {
            return $ExitCode
        }
    }

    return 0
}

function Invoke-CheckAction {
    param([Parameter(Mandatory = $true)][object]$Config)

    return Invoke-ResticCommand -Arguments @("-r", $Config.Repository, "check")
}

function Invoke-ForgetAction {
    param([Parameter(Mandatory = $true)][object]$Config)

    Write-Info "Retention policy: daily=$($Config.KeepDaily), weekly=$($Config.KeepWeekly), monthly=$($Config.KeepMonthly)"
    Write-Warning "This action modifies repository history by pruning forgotten data."

    return Invoke-ResticCommand -Arguments @(
        "-r", $Config.Repository,
        "forget",
        "--keep-daily", [string]$Config.KeepDaily,
        "--keep-weekly", [string]$Config.KeepWeekly,
        "--keep-monthly", [string]$Config.KeepMonthly,
        "--prune"
    )
}

try {
    Write-Section "Restic Batch Backup"
    Write-Info "Action: $Action"
    Write-Info "Start time: $($ScriptStartTime.ToString('yyyy-MM-dd HH:mm:ss'))"

    $Config = Read-BackupConfig -Path $ConfigPath
    $env:RESTIC_PASSWORD_FILE = $Config.PasswordFile

    Assert-ResticAvailable
    Assert-PasswordFileExists -Config $Config

    if ($DryRun -and $Action -notin @("backup", "restore")) {
        Write-Warning "-DryRun only applies to the backup and restore actions and will be ignored for '$Action'."
    }

    switch ($Action) {
        "init" { $FinalExitCode = Invoke-InitAction -Config $Config }
        "backup" { $FinalExitCode = Invoke-BackupAction -Config $Config -UseDryRun:$DryRun }
        "snapshots" { $FinalExitCode = Invoke-SnapshotsAction -Config $Config }
        "status" { $FinalExitCode = Invoke-StatusAction -Config $Config }
        "restore" { $FinalExitCode = Invoke-RestoreAction -Config $Config -SnapshotId $Snapshot -RequestedRestoreTarget $RestoreTarget -UseDryRun:$DryRun -AllowNonEmptyTarget:$AllowNonEmptyRestoreTarget }
        "check" { $FinalExitCode = Invoke-CheckAction -Config $Config }
        "forget" { $FinalExitCode = Invoke-ForgetAction -Config $Config }
    }

    if ($FinalExitCode -ne 0) {
        Write-Failure "Action '$Action' failed with exit code $FinalExitCode."
    }
}
catch {
    $FinalExitCode = 1
    Write-Failure $_.Exception.Message
}
finally {
    $ScriptEndTime = Get-Date
    $ScriptDuration = $ScriptEndTime - $ScriptStartTime
    Write-Info "End time: $($ScriptEndTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Info "Total duration: $(Format-TimeSpan -Duration $ScriptDuration)"
    Write-Info "Final exit code: $FinalExitCode"
}

exit $FinalExitCode