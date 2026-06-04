# Initial Spec — Generic Restic Backup PowerShell Tool

## 1. Purpose

This project contains a generic PowerShell-based backup helper for running Restic backups from Windows devices to any Restic-supported repository backend.

The script should not contain machine-specific repository paths, hostnames, usernames, password file names, backup folders, exclude rules, retention settings, or restore defaults. Those values belong in an external configuration file.

The script centralizes the common backup workflow:

- loading and validating configuration
- setting Restic environment variables
- validating local prerequisites
- running common Restic commands
- reporting useful status and errors

Deployment-specific values are stored in:

```text
config.ps1
```

An example configuration is committed as:

```text
config.example.ps1
```

---

## 2. Supported Deployment Model

The tool should work with any Restic repository URL supported by Restic, including but not limited to:

- local paths
- SFTP repositories
- REST server repositories
- cloud backends supported by Restic

SFTP-over-SSH is a common deployment option, but the script must treat it as a repository string supplied by configuration rather than a hard-coded assumption.

Example SFTP repository value:

```powershell
$Repository = "sftp:backup-restic-example:/mnt/backups/automated/restic/example-device"
```

Example SSH client configuration for an SFTP deployment:

```sshconfig
Host backup-restic-example
    HostName backup.example.local
    User backup-example-device
    IdentityFile C:/Users/example/Documents/Keys/id_ed25519_backup_example_device
    IdentitiesOnly yes
```

Example hardened SSH server configuration for an SFTP-only backup user:

```sshconfig
Match Group backup-sftp
    ForceCommand internal-sftp
    X11Forwarding no
    AllowTcpForwarding no
    PermitTunnel no
    AllowAgentForwarding no
```

Infrastructure setup is outside the script. The script only needs a valid Restic repository URL and any credentials required by that backend.

---

## 3. Project Goals

The script should support these actions:

```text
init        Initialize the Restic repository
backup      Back up all configured folders
snapshots   List available snapshots
status      Show useful repository status
restore     Restore a snapshot to a chosen folder
check       Check repository integrity
forget      Apply retention policy and prune old data
```

Default action:

```text
backup
```

Example usage:

```powershell
.\restic-backup.ps1 -Action init
.\restic-backup.ps1 -Action backup
.\restic-backup.ps1 -Action backup -DryRun
.\restic-backup.ps1 -Action backup -ConfigPath .\configs\laptop.ps1
.\restic-backup.ps1 -Action snapshots
.\restic-backup.ps1 -Action status
.\restic-backup.ps1 -Action check
.\restic-backup.ps1 -Action restore -Snapshot latest -RestoreTarget C:\Temp\restic-restore
.\restic-backup.ps1 -Action forget
```

---

## 4. Project Folder Structure

Recommended structure:

```text
restic-backup
├── README.md
├── restic-backup.ps1
├── config.example.ps1
├── .gitignore
└── docs
    ├── INITIAL_SPEC.md
    └── setup-notes.md
```

Optional later:

```text
restic-backup
├── logs
├── tests
└── scripts
```

Logs should normally not be committed to Git.

---

## 5. Configuration Files

Configuration must live outside the main script.

### `config.ps1`

`config.ps1` contains real machine-specific values and must not be committed to Git.

The script should load it by default from the project root:

```powershell
.\config.ps1
```

The script should also accept a custom config path so the same code can be reused for multiple devices or backup profiles:

```powershell
.\restic-backup.ps1 -ConfigPath .\configs\desktop.ps1
.\restic-backup.ps1 -ConfigPath .\configs\photos.ps1
```

### `config.example.ps1`

`config.example.ps1` documents the required settings with placeholder values. A user creates their own `config.ps1` by copying the example and editing the values.

Example:

```powershell
# Required: logical name shown in output and logs.
$BackupName = "example-device"

# Required: any Restic-supported repository URL.
$Repository = "sftp:backup-restic-example:/mnt/backups/automated/restic/example-device"

# Required: path to the local Restic password file.
$PasswordFile = "$env:USERPROFILE\.restic\restic-password-example-device.txt"

# Required: folders to back up.
$BackupFolders = @(
    "$env:USERPROFILE\Documents",
    "$env:USERPROFILE\Desktop",
    "$env:USERPROFILE\Pictures"
)

# Optional: Restic exclude rules.
$ExcludeItems = @(
    "$env:USERPROFILE\.restic",
    "node_modules",
    ".cache",
    "bin",
    "obj"
)

# Required: retention policy for forget/prune.
$KeepDaily = 14
$KeepWeekly = 8
$KeepMonthly = 12

# Required: default restore location.
$DefaultRestoreTarget = "C:\Temp\restic-restore"

# Optional: log location.
$LogFolder = "$env:USERPROFILE\.restic\logs"

# Optional: extra tags added to backups.
$BackupTags = @(
    $BackupName
)
```

### Loaded values

The script should dot-source the selected config file and validate that required values exist before running any Restic command.

Required config values:

- `$BackupName`
- `$Repository`
- `$PasswordFile`
- `$BackupFolders`
- `$KeepDaily`
- `$KeepWeekly`
- `$KeepMonthly`
- `$DefaultRestoreTarget`

Optional config values:

- `$ExcludeItems`
- `$LogFolder`
- `$BackupTags`

After loading configuration, the script should set:

```powershell
$env:RESTIC_PASSWORD_FILE = $PasswordFile
```

The script must never print or store the password itself.

---

## 6. Command-Line Parameters

The script should accept:

```powershell
param(
    [ValidateSet("init", "backup", "snapshots", "status", "restore", "check", "forget")]
    [string]$Action = "backup",

    [string]$ConfigPath = ".\config.ps1",

    [string]$Snapshot = "latest",

    [string]$RestoreTarget,

    [switch]$DryRun
)
```

If `-RestoreTarget` is omitted, the script should use `$DefaultRestoreTarget` from the loaded config.

---

## 7. Action Details

### init

Initializes the Restic repository.

```powershell
restic -r $Repository init
```

Expected behavior:

- Run only once per repository.
- If the repository already exists, show a clear message.
- Do not delete or overwrite anything.

---

### backup

Backs up all configured folders.

Command pattern:

```powershell
restic -r $Repository backup <folders> --exclude <items> --tag <tags>
```

Expected behavior:

- Load and validate the selected config file.
- Validate that Restic exists.
- Validate that the password file exists.
- Skip missing backup folders with a warning.
- Stop if no valid folders remain.
- Support `-DryRun`.
- Add configured tags when `$BackupTags` is set.

Dry run pattern:

```powershell
restic -r $Repository backup <folders> --dry-run
```

---

### snapshots

Lists available snapshots.

```powershell
restic -r $Repository snapshots
```

---

### status

Shows practical repository information.

Minimum output:

```powershell
restic -r $Repository snapshots
restic -r $Repository stats latest
```

The script should also print:

- backup name
- config path
- repository URL
- configured backup folders
- configured exclude items
- password file path, but not the password itself
- retention policy

---

### restore

Restores a selected snapshot.

```powershell
restic -r $Repository restore $Snapshot --target $RestoreTarget
```

Examples:

```powershell
.\restic-backup.ps1 -Action restore -Snapshot latest -RestoreTarget C:\Temp\restic-restore
.\restic-backup.ps1 -Action restore -Snapshot abc12345 -RestoreTarget D:\Restore
```

Expected behavior:

- Create restore target if it does not exist.
- Never restore directly over configured backup folders by default.
- Warn clearly before restore.
- Use `$DefaultRestoreTarget` from config when `-RestoreTarget` is omitted.

---

### check

Checks repository integrity.

```powershell
restic -r $Repository check
```

Later optional heavier check:

```powershell
restic -r $Repository check --read-data-subset=5%
```

---

### forget

Applies retention policy and prunes old data.

```powershell
restic -r $Repository forget --keep-daily $KeepDaily --keep-weekly $KeepWeekly --keep-monthly $KeepMonthly --prune
```

Expected behavior:

- Print the active retention policy before running.
- This action modifies repository history, so the output should be clear.

---

## 8. Safety Requirements

The script should be safe and boring.

### Must do

- Stop if the selected config file does not exist.
- Stop if required config values are missing or empty.
- Stop if Restic is not installed.
- Stop if the password file does not exist.
- Skip missing backup folders with warning.
- Never print the Restic password.
- Never delete local files.
- Never restore over configured backup folders by default.
- Use readable error messages.
- Return a non-zero exit code when a Restic command fails.

### Should do

- Use clear console output.
- Show the action being executed.
- Show start and end time.
- Show Restic exit code.
- Make it easy to run from Windows Task Scheduler.

---

## 9. Logging

The script should eventually log to `$LogFolder` from config. If `$LogFolder` is omitted, it should default to:

```powershell
$LogFolder = "$env:USERPROFILE\.restic\logs"
```

Example log file:

```text
restic-backup-YYYY-MM-DD.log
```

Logged information:

- timestamp
- action
- backup name
- config path
- repository URL
- backup folders
- warnings
- Restic command result
- exit code

Logs should not contain:

- Restic password
- private SSH key content

---

## 10. Git Ignore

The repository should not contain secrets or runtime files.

`.gitignore` should include:

```gitignore
# Secrets
config.ps1
configs/*.ps1
!config.example.ps1
*.key
*.pem
*password*
*.secret

# Restic local runtime
logs/
*.log

# PowerShell/editor temp
*.tmp
*.bak

# VS Code local settings if needed
.vscode/
```

Files that must not be committed:

```text
Real config files containing machine-specific settings
Restic password file
SSH private key
Any real credentials
```

The SSH public key may be committed only if there is a clear reason, but normally it is not needed.

---

## 11. Future Improvements

Possible future features:

- Multiple named backup profiles.
- Config schema validation with clearer diagnostics.
- Windows Task Scheduler setup helper.
- Notification on failed backup.
- Backup duration reporting.
- Repository size reporting.
- Automatic `forget` after successful backup.
- Weekly `check`.
- Monthly restore test reminder.
- Support for desktop and family devices.
- Support for Kopia or other backup tools later.

---

## 12. First Implementation Target

Version 1 should implement:

```text
init
backup
snapshots
status
restore
check
forget
```

Keep the first version simple.

The main goal is to have a working, readable, maintainable backup script that can be safely run manually and later scheduled. The implementation should be reusable across devices by changing configuration, not by editing the script.
