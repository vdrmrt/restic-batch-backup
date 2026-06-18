# Restic Batch Backup

Restic Batch Backup is a small, config-driven helper for backing up a batch of configured folders with Restic.

The project is still Windows-first, and now includes both a PowerShell runner for Windows and an initial Bash runner for Linux. Both runners use the same JSON config shape, while real config values remain operating-system specific.

## What It Does

- Loads backup settings from `config.json`.
- Backs up a configured batch of folders.
- Applies configured Restic exclude rules and tags.
- Supports `init`, `backup`, `snapshots`, `status`, `restore`, `check`, and `forget`.
- Reports start time, end time, Restic exit code, and backup duration.
- Keeps machine-specific config and secrets out of Git.
- Restores configured backup folders into a chosen restore folder.

## Requirements

Windows:

- PowerShell 5.1 or newer.
- Restic installed and available on `PATH`.
- A reachable Restic repository.
- A local Restic password file.

Linux:

- Bash 4.0 or newer.
- `jq`, `realpath`, and Restic installed and available on `PATH`.
- A reachable Restic repository.
- A local Restic password file.

## Quick Start

Copy the example config and edit it for the current machine:

```powershell
Copy-Item .\config.example.json .\config.json
notepad .\config.json
```

Create the password file referenced by `passwordFile` in `config.json`. Do not commit this file.

Run a status check:

```powershell
.\runners\restic-batch-backup.ps1 -Action status
```

Initialize a new repository only once:

```powershell
.\runners\restic-batch-backup.ps1 -Action init
```

Run a dry backup first:

```powershell
.\runners\restic-batch-backup.ps1 -Action backup -DryRun
```

Run the real backup:

```powershell
.\runners\restic-batch-backup.ps1 -Action backup
```

## Commands

```powershell
.\runners\restic-batch-backup.ps1 -Action init
.\runners\restic-batch-backup.ps1 -Action backup
.\runners\restic-batch-backup.ps1 -Action backup -DryRun
.\runners\restic-batch-backup.ps1 -Action snapshots
.\runners\restic-batch-backup.ps1 -Action status
.\runners\restic-batch-backup.ps1 -Action check
.\runners\restic-batch-backup.ps1 -Action restore -Snapshot latest
.\runners\restic-batch-backup.ps1 -Action restore -Snapshot latest -DryRun
.\runners\restic-batch-backup.ps1 -Action restore -Snapshot latest -RestoreTarget C:\Temp\restic-restore
.\runners\restic-batch-backup.ps1 -Action forget
```

Use a different config file:

```powershell
.\runners\restic-batch-backup.ps1 -Action backup -ConfigPath .\configs\laptop.json
```

Linux runner examples:

```bash
./runners/restic-batch-backup.sh status --config ./config.json
./runners/restic-batch-backup.sh backup --dry-run --config ./config.json
./runners/restic-batch-backup.sh restore --snapshot latest --dry-run --config ./config.json
./runners/restic-batch-backup.sh forget --config ./config.json
```

## Configuration

Real local configuration belongs in `config.json`, which is ignored by Git. The committed `config.example.json` documents the schema.

Required fields:

- `name`
- `repository`
- `passwordFile`
- `backupFolders`
- `retention.keepDaily`
- `retention.keepWeekly`
- `retention.keepMonthly`
- `restore.defaultTarget`

Optional fields:

- `excludeItems`
- `logging.folder`
- `backupTags`

Windows-style environment variables such as `%USERPROFILE%` are expanded by the PowerShell runner.

## Restore Behavior

Restore uses the configured `backupFolders` as the source list. For each configured folder, the runner converts the local Windows path to the matching Restic snapshot path and restores it into a subfolder under the restore target.

Example: `C:\Users\Example\Documents` is restored from `/C/Users/Example/Documents` into `C:\Temp\restic-restore\Documents`.

Use an empty restore target for normal restores. The runner refuses non-empty restore targets by default to avoid mixing old restore output with new data. For deliberate advanced restores into an existing target, pass `-AllowNonEmptyRestoreTarget`.

Restic can restore full snapshots directly, but on Windows that may involve restoring metadata for ancestor folders such as `C:\Users`. Some Windows metadata and security descriptor restore operations require Administrator privileges. The runner's configured-folder restore avoids those ancestor folders for the common batch-backup restore path.

## Scheduling

After manual backup and restore testing works, use Windows Task Scheduler with:

```text
Program: powershell.exe
Arguments: -NoProfile -ExecutionPolicy Bypass -File "C:\Path\To\restic-batch-backup\runners\restic-batch-backup.ps1" -Action backup -ConfigPath "C:\Path\To\restic-batch-backup\config.json"
Start in: C:\Path\To\restic-batch-backup
```

## Safety

- The runner never prints the Restic password.
- Missing backup folders are skipped with warnings.
- A backup run stops if no configured folders exist.
- Restore targets are blocked when they overlap configured backup folders.
- Restore targets must be empty unless `-AllowNonEmptyRestoreTarget` is passed.
- Restic failures return non-zero exit codes.

## Linux Support

An initial Linux Bash runner is available at `runners/restic-batch-backup.sh`.

Linux configs should use Linux paths and Linux-style environment variables such as `$HOME`. The detailed Linux design and behavior notes live in `docs/LINUX_SUPPORT_SPEC.md`.

On Linux, `restore --dry-run` is implemented as a preview mode. The runner still validates restore target safety, but it lists the snapshot contents with `restic ls` instead of writing files because current Restic versions do not provide a native restore dry-run flag.
