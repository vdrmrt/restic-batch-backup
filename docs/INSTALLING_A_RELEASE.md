# Installing a Release

Download the GitHub release archive, extract it to a stable folder, keep your live config outside that folder, and verify with `status` plus `backup --dry-run`.

There is no installer package yet. The release currently ships the project files, runners, examples, and docs.

## Windows Quick Install

Requirements:

- PowerShell 5.1 or newer
- `restic` on `PATH`
- working SSH access if you use SFTP

1. Extract the release to a stable folder such as `C:\Tools\restic-batch-backup`.
2. Create your config folder and copy the example:

```powershell
$InstallDir = 'C:\Tools\restic-batch-backup'
$ConfigDir = Join-Path $env:APPDATA 'restic-batch-backup'
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
Copy-Item (Join-Path $InstallDir 'config_examples\windows-sftp-backup.example.json') (Join-Path $ConfigDir 'config.json')
notepad (Join-Path $ConfigDir 'config.json')
```

3. Create the password file referenced by `passwordFile` in `config.json`.
4. If you use SFTP, confirm SSH works first and set `ssh.identityFile` if needed.
5. Test the install:

```powershell
Set-Location $InstallDir
.\runners\restic-batch-backup.ps1 -Action status
.\runners\restic-batch-backup.ps1 -Action backup -DryRun
```

If the dry run looks correct, you can run a real backup and then schedule it with Task Scheduler.

## Linux Quick Install

Requirements:

- Bash 4.0 or newer
- `restic`, `jq`, and `realpath` on `PATH`
- working SSH access if you use SFTP

1. Extract the release to a stable folder such as `/opt/restic-batch-backup` or `$HOME/apps/restic-batch-backup`.
2. Create your config folder and copy the example:

```bash
INSTALL_DIR="/opt/restic-batch-backup"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/restic-batch-backup"
mkdir -p "$CONFIG_DIR"
chmod +x "$INSTALL_DIR/runners/restic-batch-backup.sh"
cp "$INSTALL_DIR/config_examples/linux-sftp-test.example.json" "$CONFIG_DIR/config.json"
```

3. Edit `"$CONFIG_DIR/config.json"` with your real repository, password file, backup folders, and restore target.
4. Create the password file referenced by `passwordFile` in the config.
5. If you use SFTP, confirm SSH works first and set `ssh.identityFile` if needed.
6. Test the install:

```bash
cd "$INSTALL_DIR"
./runners/restic-batch-backup.sh status
./runners/restic-batch-backup.sh backup --dry-run
```

If the dry run looks correct, you can run a real backup and then schedule it with `cron` or `systemd`.

## Upgrade

1. Extract the new release over a fresh app folder.
2. Keep your existing external config, password files, and SSH keys.
3. Re-run:

```bash
./runners/restic-batch-backup.sh status
./runners/restic-batch-backup.sh backup --dry-run
```

On Windows:

```powershell
.\runners\restic-batch-backup.ps1 -Action status
.\runners\restic-batch-backup.ps1 -Action backup -DryRun
```
