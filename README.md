# Restic Batch Backup

Restic Batch Backup is a small, config-driven wrapper around `restic` for backing up a batch of folders with a shared JSON config format.

The project currently includes:

- a PowerShell runner for Windows at `runners/restic-batch-backup.ps1`
- a Bash runner for Linux at `runners/restic-batch-backup.sh`
- shared config examples under `config_examples/`
- SFTP client and server setup docs under `docs/`
- CI smoke tests and a tag-driven release workflow

## Features

- `init`, `backup`, `snapshots`, `status`, `restore`, `check`, and `forget`
- config-driven repository, folder, restore, retention, and tag settings
- restore safety checks to avoid overlapping restore targets and backup folders
- optional `ssh.identityFile` support for SFTP repositories
- dry-run support for backup on both runners
- restore preview mode on Linux using `restic ls`

## Repo Layout

```text
restic-batch-backup
├── config_examples/
│   ├── linux-sftp-test.example.json
│   └── windows-sftp-backup.example.json
├── docs/
│   ├── SFTP_SERVER_SETUP.md
│   ├── SFTP_TESTING.md
│   └── RELEASING.md
├── runners/
├── scripts/
│   └── create-restic-test-data.sh
└── tests/
```

Use `config_examples/` for committed templates. Keep live config outside the repo, preferably in your user config directory.

Default live config locations:

- Windows: `%APPDATA%\restic-batch-backup\config.json`
- Linux: `${XDG_CONFIG_HOME:-$HOME/.config}/restic-batch-backup/config.json`

## Requirements

Windows:

- PowerShell 5.1 or newer
- Restic installed and available on `PATH`
- a reachable Restic repository
- a local Restic password file

Linux:

- Bash 4.0 or newer
- `jq`, `realpath`, and Restic installed and available on `PATH`
- a reachable Restic repository
- a local Restic password file

## Quick Start

Windows example:

```powershell
$ConfigDir = Join-Path $env:APPDATA 'restic-batch-backup'
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
Copy-Item .\config_examples\windows-sftp-backup.example.json (Join-Path $ConfigDir 'config.json')
notepad (Join-Path $ConfigDir 'config.json')
.\runners\restic-batch-backup.ps1 -Action status
.\runners\restic-batch-backup.ps1 -Action backup -DryRun
```

Linux example:

```bash
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/restic-batch-backup"
mkdir -p "$CONFIG_DIR"
cp ./config_examples/linux-sftp-test.example.json "$CONFIG_DIR/config.json"
./runners/restic-batch-backup.sh status
./runners/restic-batch-backup.sh backup --dry-run
```

Create the password file referenced by `passwordFile` before running a real backup, and do not commit it.

## Configuration

Real local configuration belongs outside this repository. The runners default to your user config directory, and you can use `--config <path>` or `-ConfigPath <path>` for additional profiles such as test-only configs.

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
- `ssh.identityFile`

For SFTP repositories, `ssh.identityFile` is optional. When set, the runners pass that key to Restic via `-o sftp.args=...`, so you can use a key from JSON instead of relying only on `~/.ssh/config`.

## Common Commands

PowerShell:

```powershell
.\runners\restic-batch-backup.ps1 -Action init
.\runners\restic-batch-backup.ps1 -Action backup
.\runners\restic-batch-backup.ps1 -Action backup -DryRun
.\runners\restic-batch-backup.ps1 -Action snapshots
.\runners\restic-batch-backup.ps1 -Action status
.\runners\restic-batch-backup.ps1 -Action check
.\runners\restic-batch-backup.ps1 -Action restore -Snapshot latest -DryRun
.\runners\restic-batch-backup.ps1 -Action restore -Snapshot latest -RestoreTarget C:\Temp\restic-restore
.\runners\restic-batch-backup.ps1 -Action forget
```

Bash:

```bash
./runners/restic-batch-backup.sh init
./runners/restic-batch-backup.sh backup
./runners/restic-batch-backup.sh backup --dry-run
./runners/restic-batch-backup.sh snapshots
./runners/restic-batch-backup.sh status
./runners/restic-batch-backup.sh check
./runners/restic-batch-backup.sh restore --snapshot latest --dry-run
./runners/restic-batch-backup.sh restore --snapshot latest --restore-target /tmp/restic-restore
./runners/restic-batch-backup.sh forget
```

Use `--config <path>` or `-ConfigPath <path>` to point at a non-default config file outside the repo, such as `~/.config/restic-batch-backup/sftp-test.json`.

## Restore Behavior

Restore uses the configured `backupFolders` as the source list.

Windows:

- restores each configured folder into a subfolder under the restore target
- uses the configured-folder restore flow to avoid common ancestor-folder permission issues

Linux:

- `restore --dry-run` is implemented as a preview mode
- preview mode validates restore target safety, then uses `restic ls` instead of writing files

On both runners:

- restore targets must not overlap configured backup folders
- restore targets must be empty unless explicitly overridden

## SFTP Workflows

Client-side SFTP testing:

- `docs/SFTP_TESTING.md`
- `config_examples/linux-sftp-test.example.json`
- `scripts/create-restic-test-data.sh`

Server-side SFTP provisioning and hardening:

- `docs/SFTP_SERVER_SETUP.md`

The test data helper supports:

```bash
./scripts/create-restic-test-data.sh
./scripts/create-restic-test-data.sh --target /tmp/my-restic-test
./scripts/create-restic-test-data.sh --target /tmp/my-restic-test --mutate
```

## Safety

- the runners never print the Restic password
- missing backup folders are skipped with warnings
- a backup stops if no configured folders remain
- restore targets are blocked when they overlap backup folders
- Restic failures return non-zero exit codes

## Release Management

- `VERSION` stores the current target release version
- `CHANGELOG.md` tracks unreleased and released changes
- `docs/RELEASING.md` documents the release checklist
- GitHub Actions runs CI smoke checks for both runners
- GitHub releases are created from `vX.Y.Z` tags when the tag matches `VERSION` and `CHANGELOG.md`
