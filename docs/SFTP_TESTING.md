# SFTP Testing

This guide walks through a safe first test of Restic Batch Backup against an SFTP-backed Restic repository.

Use a dedicated test repository path and, ideally, a dedicated SSH user so you can validate the workflow without touching production backups.

If you still need to provision the backup server itself, start with [SFTP_SERVER_SETUP.md](/home/vdrmrt/workspace/restic-batch-backup/docs/SFTP_SERVER_SETUP.md:1).

## What You Need

- a reachable SSH/SFTP server
- a writable folder on that server for the test repository
- Restic installed locally
- the Bash runner or PowerShell runner from this repository
- a local Restic password file

## Recommended Test Setup

Create or choose:

- an SSH host or alias such as `backup-restic-test`
- a remote repository folder such as `/data/restic/sftp-test-device`
- a local password file such as `$HOME/.config/restic/restic-password-sftp-test.txt`
- a local test dataset rooted at `/tmp/restic-test`

Example SSH config:

```sshconfig
Host backup-restic-test
    HostName backup.example.local
    User backup-test
    IdentityFile ~/.ssh/id_ed25519_restic_test
    IdentitiesOnly yes
```

## Test Config

Start from [linux-sftp-test.example.json](/home/vdrmrt/workspace/restic-batch-backup/config_examples/linux-sftp-test.example.json:1) and copy it to a real local config file outside the repo.

Example repository value:

```json
"repository": "sftp:backup-restic-test:/data/restic/sftp-test-device"
```

Notes:

- the part after `sftp:` is the SSH host or alias Restic connects to
- the path after the second `:` is the remote repository path on that server
- use Linux-style paths in Linux configs and Windows-style paths in Windows configs
- the provided SFTP test example already points `backupFolders` at `/tmp/restic-test`
- if you want the runners to point Restic at a specific private key directly, set `ssh.identityFile`

## Linux Test Flow

1. Create the test dataset:

```bash
./scripts/create-restic-test-data.sh
```

Use a different destination if you do not want `/tmp/restic-test`:

```bash
./scripts/create-restic-test-data.sh --target /tmp/my-restic-test
```

For a second backup that includes adds, changes, and deletes:

```bash
./scripts/create-restic-test-data.sh --mutate
```

2. Copy the example config and edit it:

```bash
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/restic-batch-backup"
mkdir -p "$CONFIG_DIR"
cp ./config_examples/linux-sftp-test.example.json "$CONFIG_DIR/sftp-test.json"
```

If you want to specify the SSH private key in JSON instead of relying only on `~/.ssh/config`, keep or edit:

```json
"ssh": {
    "identityFile": "$HOME/.ssh/id_ed25519_restic_test"
}
```

3. Create the password file referenced by `passwordFile`:

```bash
mkdir -p "$HOME/.config/restic"
printf 'choose-a-strong-test-password\n' > "$HOME/.config/restic/restic-password-sftp-test.txt"
chmod 600 "$HOME/.config/restic/restic-password-sftp-test.txt"
```

4. Confirm the SSH connection works before testing Restic:

```bash
ssh backup-restic-test
```

5. Run a repository status check. This may fail if the repository has not been initialized yet:

```bash
./runners/restic-batch-backup.sh status --config "$CONFIG_DIR/sftp-test.json"
```

6. Initialize the test repository once:

```bash
./runners/restic-batch-backup.sh init --config "$CONFIG_DIR/sftp-test.json"
```

7. Run a dry backup:

```bash
./runners/restic-batch-backup.sh backup --dry-run --config "$CONFIG_DIR/sftp-test.json"
```

8. Run the real backup:

```bash
./runners/restic-batch-backup.sh backup --config "$CONFIG_DIR/sftp-test.json"
```

9. Validate that the repository contains snapshots:

```bash
./runners/restic-batch-backup.sh snapshots --config "$CONFIG_DIR/sftp-test.json"
./runners/restic-batch-backup.sh check --config "$CONFIG_DIR/sftp-test.json"
```

10. Preview a restore:

```bash
./runners/restic-batch-backup.sh restore --snapshot latest --dry-run --config "$CONFIG_DIR/sftp-test.json"
```

11. Perform a real restore into an empty test folder:

```bash
rm -rf /tmp/restic-sftp-restore
./runners/restic-batch-backup.sh restore --snapshot latest --config "$CONFIG_DIR/sftp-test.json"
```

## Windows Test Flow

1. Copy `config_examples/windows-sftp-backup.example.json` to a real config file outside the repo, such as `%APPDATA%\restic-batch-backup\sftp-test.json`, and replace example paths with your Windows paths.
2. Ensure your SSH key or agent access works for the target host alias.
3. Create the local Restic password file.
4. Run:

```powershell
.\runners\restic-batch-backup.ps1 -Action init -ConfigPath "$env:APPDATA\restic-batch-backup\sftp-test.json"
.\runners\restic-batch-backup.ps1 -Action backup -DryRun -ConfigPath "$env:APPDATA\restic-batch-backup\sftp-test.json"
.\runners\restic-batch-backup.ps1 -Action backup -ConfigPath "$env:APPDATA\restic-batch-backup\sftp-test.json"
.\runners\restic-batch-backup.ps1 -Action snapshots -ConfigPath "$env:APPDATA\restic-batch-backup\sftp-test.json"
.\runners\restic-batch-backup.ps1 -Action check -ConfigPath "$env:APPDATA\restic-batch-backup\sftp-test.json"
.\runners\restic-batch-backup.ps1 -Action restore -Snapshot latest -DryRun -ConfigPath "$env:APPDATA\restic-batch-backup\sftp-test.json"
```

## What Success Looks Like

You should be able to:

- connect to the remote host over SSH without interactive surprises
- initialize the repository once
- create a snapshot successfully
- list snapshots afterward
- run `check` without repository errors
- restore test data into a separate restore folder

## Common Issues

- SSH works interactively but fails in scripts:
  check that the same host alias, key, and user are available in the environment where the runner executes.
- test data does not exist yet:
  rerun `./scripts/create-restic-test-data.sh` to recreate `/tmp/restic-test`.
- custom target path not reflected in backup config:
  if you use `--target`, update `backupFolders` in your config to the same path.
- `status` fails before `init`:
  this is normal for a brand-new repository path.
- wrong remote path:
  Restic may report the repository does not exist or cannot be opened.
- password mismatch:
  Restic will refuse access to an existing repository if the password file is wrong.
- restore target blocked:
  the runners intentionally reject restore targets that overlap configured backup folders.

## Safe Cleanup

If this is only a disposable test, remove:

- the remote test repository folder
- the local test config
- the local test password file if you do not want to keep it
- the local restore output folder
