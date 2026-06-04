# Initial Spec - Restic Batch Backup

## 1. Purpose

This project contains a generic, config-driven Restic helper for backing up a batch of configured folders to any Restic-supported repository backend.

Version 1 is Windows-first and uses a PowerShell runner. The project structure and configuration format should already leave room for future Linux support through a Bash runner.

The runner should not contain machine-specific repository paths, hostnames, usernames, password file names, backup folders, exclude rules, retention settings, or restore defaults. Those setup-specific values belong in an external JSON configuration file.

The runner centralizes the common backup workflow:

- loading and validating configuration
- setting Restic environment variables
- validating local prerequisites
- backing up a configured list of folders
- applying configured exclude rules
- running common Restic commands
- reporting useful status, duration, and errors

Deployment-specific values are stored in:

```text
config.json
```

An example configuration is committed as:

```text
config.example.json
```

---

## 2. Supported Deployment Model

The tool should work with any Restic repository URL supported by Restic, including but not limited to:

- local paths
- SFTP repositories
- REST server repositories
- cloud backends supported by Restic

SFTP-over-SSH is a common deployment option, but the runner must treat it as a repository string supplied by configuration rather than a hard-coded assumption.

Example SFTP repository value in JSON:

```json
"repository": "sftp:backup-restic-example:/mnt/backups/automated/restic/example-device"
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

Infrastructure setup is outside the runner. The runner only needs a valid Restic repository URL and any credentials required by that backend.

---

## 3. Project Goals

The runner should support these actions:

```text
init        Initialize the configured Restic repository
backup      Back up all configured folders
snapshots   List available snapshots
status      Show useful repository and configuration status
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
.\runners\restic-batch-backup.ps1 -Action init
.\runners\restic-batch-backup.ps1 -Action backup
.\runners\restic-batch-backup.ps1 -Action backup -DryRun
.\runners\restic-batch-backup.ps1 -Action backup -ConfigPath .\configs\laptop.json
.\runners\restic-batch-backup.ps1 -Action snapshots
.\runners\restic-batch-backup.ps1 -Action status
.\runners\restic-batch-backup.ps1 -Action check
.\runners\restic-batch-backup.ps1 -Action restore -Snapshot latest -DryRun
.\runners\restic-batch-backup.ps1 -Action restore -Snapshot latest -RestoreTarget C:\Temp\restic-restore
.\runners\restic-batch-backup.ps1 -Action forget
```

---

## 4. Project Folder Structure

Recommended structure:

```text
restic-batch-backup
├── README.md
├── config.example.json
├── .gitignore
├── runners
│   └── restic-batch-backup.ps1
└── docs
    ├── INITIAL_SPEC.md
    └── setup-notes.md
```

Local runtime files:

```text
restic-batch-backup
├── config.json
└── logs
```

Optional later:

```text
restic-batch-backup
├── configs
├── logs
├── tests
├── scripts
└── runners
    └── restic-batch-backup.sh
```

Logs should normally not be committed to Git.

---

## 5. Configuration Files

Configuration must live outside the runner code and use JSON so future runners can share the same config contract.

### `config.json`

`config.json` contains real machine-specific values and must not be committed to Git.

The PowerShell runner should load it by default from the project root:

```powershell
.\config.json
```

The runner should also accept a custom config path so the same code can be reused for multiple devices or backup profiles:

```powershell
.\runners\restic-batch-backup.ps1 -ConfigPath .\configs\desktop.json
.\runners\restic-batch-backup.ps1 -ConfigPath .\configs\photos.json
```

### `config.example.json`

`config.example.json` documents the required settings with placeholder values. A user creates their own `config.json` by copying the example and editing the values.

Example:

```json
{
    "name": "example-device",
    "repository": "sftp:backup-restic-example:/mnt/backups/automated/restic/example-device",
    "passwordFile": "%USERPROFILE%\\.restic\\restic-password-example-device.txt",
    "backupFolders": [
        "%USERPROFILE%\\Documents",
        "%USERPROFILE%\\Desktop",
        "%USERPROFILE%\\Pictures"
    ],
    "excludeItems": [
        "%USERPROFILE%\\.restic",
        "node_modules",
        ".cache",
        "bin",
        "obj"
    ],
    "retention": {
        "keepDaily": 14,
        "keepWeekly": 8,
        "keepMonthly": 12
    },
    "restore": {
        "defaultTarget": "C:\\Temp\\restic-restore"
    },
    "logging": {
        "folder": "%USERPROFILE%\\.restic\\logs"
    },
    "backupTags": [
        "example-device"
    ]
}
```

### Loaded values

The runner should read the selected JSON config file, parse it with a structured JSON parser, and validate that required values exist before running any Restic command.

Required config values:

- `name`
- `repository`
- `passwordFile`
- `backupFolders`
- `retention.keepDaily`
- `retention.keepWeekly`
- `retention.keepMonthly`
- `restore.defaultTarget`

Optional config values:

- `excludeItems`
- `logging.folder`
- `backupTags`

After loading configuration, the runner should set:

```powershell
$env:RESTIC_PASSWORD_FILE = $Config.passwordFile
```

The actual password file must not be stored in Git. The runner must never print or store the password itself.

### Path and environment expansion

The v1 PowerShell runner should expand Windows-style environment variables in JSON string values, such as `%USERPROFILE%`.

Linux support is future work. The JSON format should remain portable, but individual config files may contain operating-system-specific paths.

---

## 6. Command-Line Parameters

The PowerShell runner should accept:

```powershell
param(
    [ValidateSet("init", "backup", "snapshots", "status", "restore", "check", "forget")]
    [string]$Action = "backup",

    [string]$ConfigPath = "$PSScriptRoot\..\config.json",

    [string]$Snapshot = "latest",

    [string]$RestoreTarget,

    [switch]$AllowNonEmptyRestoreTarget,

    [switch]$DryRun
)
```

If `-RestoreTarget` is omitted, the runner should use `restore.defaultTarget` from the loaded config.

`-DryRun` should apply to `backup` and `restore`.

---

## 7. Action Details

### init

Initializes the configured Restic repository.

```powershell
restic -r $Config.repository init
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
restic -r $Config.repository backup <folders> --exclude <items> --tag <tags>
```

Expected behavior:

- Load and validate the selected config file.
- Validate that Restic exists.
- Validate that the password file exists.
- Expand configured paths and environment variables.
- Skip missing backup folders with a warning.
- Stop if no valid folders remain.
- Support `-DryRun`.
- Add configured tags when `backupTags` is set.
- Measure and print the backup duration when the command finishes.

Dry run pattern:

```powershell
restic -r $Config.repository backup <folders> --exclude <items> --dry-run
```

---

### snapshots

Lists available snapshots.

```powershell
restic -r $Config.repository snapshots
```

---

### status

Shows practical repository information.

Minimum output:

```powershell
restic -r $Config.repository snapshots
restic -r $Config.repository stats latest
```

The runner should also print:

- config name
- config path
- repository URL
- configured backup folders
- configured exclude items
- password file path, but not the password itself
- retention policy

---

### restore

Restores the configured backup folders from a selected snapshot.

```powershell
restic -r $Config.repository restore "$Snapshot:<restic-folder-path>" --target "$EffectiveRestoreTarget\<folder-name>"
```

Examples:

```powershell
.\runners\restic-batch-backup.ps1 -Action restore -Snapshot latest
.\runners\restic-batch-backup.ps1 -Action restore -Snapshot latest -DryRun
.\runners\restic-batch-backup.ps1 -Action restore -Snapshot abc12345 -RestoreTarget D:\Restore
```

Expected behavior:

- Use the configured default restore target when `-RestoreTarget` is omitted.
- Convert each configured backup folder to the matching Restic snapshot path. For example, `C:\Users\Example\Documents` becomes `/C/Users/Example/Documents`.
- Restore each configured backup folder into a subfolder below the restore target.
- Create restore target if it does not exist, except during restore dry-runs.
- Refuse non-empty restore targets unless `-AllowNonEmptyRestoreTarget` is passed.
- Never restore directly over configured backup folders by default.
- Support `-DryRun`.
- Warn clearly before restore.

Windows note: restoring a whole snapshot can require Restic to restore metadata for ancestor folders such as `C:\Users`. Some Windows metadata and security descriptor operations require Administrator privileges. The default configured-folder restore path should avoid restoring those ancestor folders.

---

### check

Checks repository integrity.

```powershell
restic -r $Config.repository check
```

Later optional heavier check:

```powershell
restic -r $Config.repository check --read-data-subset=5%
```

---

### forget

Applies retention policy and prunes old data.

```powershell
restic -r $Config.repository forget --keep-daily $Config.retention.keepDaily --keep-weekly $Config.retention.keepWeekly --keep-monthly $Config.retention.keepMonthly --prune
```

Expected behavior:

- Print the active retention policy before running.
- This action modifies repository history, so the output should be clear.

---

## 8. Safety Requirements

The runner should be safe and boring.

### Must do

- Stop if the selected config file does not exist.
- Stop if required config values are missing or empty.
- Stop if Restic is not installed.
- Stop if the password file does not exist.
- Skip missing backup folders with warning.
- Never print the Restic password.
- Never delete local files.
- Never restore over configured backup folders by default.
- Never restore into a non-empty target by default.
- Use readable error messages.
- Return a non-zero exit code when a Restic command fails.

### Should do

- Use clear console output.
- Show the action being executed.
- Show the config file being used.
- Show start and end time.
- Show backup duration for the `backup` action.
- Show Restic exit code.
- Make it easy to run from Windows Task Scheduler.

---

## 9. Logging

The runner should eventually log to `logging.folder` from config. If `logging.folder` is omitted, it should default to:

```text
%USERPROFILE%\.restic\logs
```

Example log file:

```text
restic-batch-backup-YYYY-MM-DD.log
```

Logged information:

- timestamp
- action
- config name
- config path
- repository URL
- backup folders
- warnings
- backup duration for backup runs
- Restic command result
- exit code

Logs should not contain:

- Restic password
- private SSH key content
- access tokens

---

## 10. Git Ignore

The repository should not contain secrets or runtime files.

`.gitignore` should include:

```gitignore
# Local configuration
config.json
configs/*.json
!config.example.json
!configs/*.example.json

# Secrets
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
- Linux support with a Bash runner at `runners/restic-batch-backup.sh`.
- Shared JSON config schema used by both PowerShell and Bash runners.
- Cross-platform path and environment variable expansion.
- Config schema validation with clearer diagnostics.
- GitHub Release packaging and checksums.
- Optional install/update helper script.
- Windows Task Scheduler setup helper.
- Notification on failed backup.
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
PowerShell runner at runners/restic-batch-backup.ps1
JSON config loading and validation
init
backup
backup duration reporting
snapshots
status
restore
check
forget
```

Version 1 does not need to implement the Linux Bash runner, but the file layout and JSON config contract should avoid blocking it.

Keep the first version simple.

The main goal is to have a working, readable, maintainable backup runner that can safely back up a configured batch of folders. The implementation should be reusable across devices by changing configuration, not by editing runner code.
