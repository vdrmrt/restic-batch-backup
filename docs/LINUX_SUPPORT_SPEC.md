# Linux Support Spec - Restic Batch Backup

## 1. Purpose

This document defines version 1 Linux support for Restic Batch Backup.

The project already has a Windows PowerShell runner. Linux support should add a Bash runner with the same overall workflow, the same safety posture, and the same JSON configuration contract wherever practical.

The Linux work should keep the tool small, readable, and easy to run from cron or systemd. It should not require editing runner code for each machine.

---

## 2. Goals

Version 1 Linux support should provide:

- a Bash runner at `runners/restic-batch-backup.sh`
- support for `init`, `backup`, `snapshots`, `status`, `restore`, `check`, and `forget`
- the same required and optional JSON config keys already used by the PowerShell runner
- safe restore behavior comparable to the Windows runner
- config-driven operation with no hard-coded repository or machine settings
- readable console output with start time, end time, duration, and exit code
- scheduling compatibility with cron and systemd timers

---

## 3. Non-Goals

Version 1 Linux support should not require:

- replacing the existing PowerShell runner
- merging Windows and Linux into one runner file
- introducing a GUI
- making one single config file portable across Windows and Linux path syntax
- supporting every shell beyond Bash
- adding file logging if the current PowerShell runner still defers it

Shared schema does not mean shared machine-specific values. Linux configs may use Linux paths and Linux environment variable syntax, while Windows configs may keep using Windows-specific paths.

---

## 4. Supported Environment

The Linux runner should target:

- Bash 4.0 or newer
- Restic installed and available on `PATH`
- `jq` installed and available on `PATH`
- standard coreutils typically present on mainstream Linux distributions

The runner should work with any Restic repository backend supported by Restic, including:

- local repositories
- SFTP repositories
- REST server repositories
- cloud backends supported by Restic

The runner itself should not require root. Users may still choose to run it with elevated privileges when backing up or restoring protected paths such as `/etc`, `/root`, or data owned by other users.

---

## 5. Project Structure Changes

Recommended structure after Linux support is added:

```text
restic-batch-backup
├── README.md
├── config_examples
│   ├── linux-sftp-test.example.json
│   └── windows-sftp-backup.example.json
├── .gitignore
├── docs
│   ├── INITIAL_SPEC.md
│   └── LINUX_SUPPORT_SPEC.md
└── runners
    ├── restic-batch-backup.ps1
    └── restic-batch-backup.sh
```

Optional later:

```text
restic-batch-backup
├── configs
├── tests
└── scripts
```

---

## 6. Runner Interface

The Bash runner should support a simple command style:

```bash
./runners/restic-batch-backup.sh [action] [options]
```

If `action` is omitted, the default action should be:

```text
backup
```

Supported actions:

```text
init
backup
snapshots
status
restore
check
forget
```

Supported options:

```text
--config <path>
--snapshot <id-or-id:path>
--restore-target <path>
--allow-non-empty-restore-target
--dry-run
--help
```

Suggested examples:

```bash
./runners/restic-batch-backup.sh init
./runners/restic-batch-backup.sh backup
./runners/restic-batch-backup.sh backup --dry-run
./runners/restic-batch-backup.sh backup --config ~/.config/restic-batch-backup/server.json
./runners/restic-batch-backup.sh snapshots
./runners/restic-batch-backup.sh status
./runners/restic-batch-backup.sh check
./runners/restic-batch-backup.sh restore --snapshot latest --dry-run
./runners/restic-batch-backup.sh restore --snapshot latest --restore-target /tmp/restic-restore
./runners/restic-batch-backup.sh forget
```

Implementation guidance:

- Use exit codes normally so schedulers can detect failures.
- Use `set -euo pipefail`.
- Keep output human-readable rather than JSON-only.

---

## 7. Configuration Contract

Linux support should reuse the current JSON schema.

### Default config location

The Linux runner should load this by default:

```text
~/.config/restic-batch-backup/config.json
```

It should also accept a custom path through:

```text
--config <path>
```

### Required config values

- `name`
- `repository`
- `passwordFile`
- `backupFolders`
- `retention.keepDaily`
- `retention.keepWeekly`
- `retention.keepMonthly`
- `restore.defaultTarget`

### Optional config values

- `excludeItems`
- `logging.folder`
- `backupTags`
- `ssh.identityFile`

### Example Linux config

```json
{
    "name": "example-linux-device",
    "repository": "sftp:backup-restic-example:/srv/backups/restic/example-linux-device",
    "passwordFile": "$HOME/.config/restic/restic-password-example-linux-device.txt",
    "backupFolders": [
        "$HOME/Documents",
        "$HOME/Pictures",
        "/etc"
    ],
    "excludeItems": [
        ".cache",
        "node_modules",
        "/var/tmp"
    ],
    "retention": {
        "keepDaily": 14,
        "keepWeekly": 8,
        "keepMonthly": 12
    },
    "restore": {
        "defaultTarget": "/tmp/restic-restore"
    },
    "ssh": {
        "identityFile": "$HOME/.ssh/id_ed25519_backup_example_linux_device"
    },
    "logging": {
        "folder": "$HOME/.local/state/restic-batch-backup/logs"
    },
    "backupTags": [
        "linux",
        "example-linux-device"
    ]
}
```

### Config handling rules

The Linux runner should:

- parse JSON with `jq`
- validate required values before running Restic
- treat `repository` as a literal Restic repository string after environment expansion
- resolve path-like config values to full paths before use
- keep secrets out of Git and out of console output

The following fields should be treated as path-like values:

- `passwordFile`
- each item in `backupFolders`
- `restore.defaultTarget`
- `logging.folder`
- `ssh.identityFile`

The following fields should remain plain strings after environment expansion:

- `repository`
- `excludeItems`
- `backupTags`

---

## 8. Linux Path and Environment Expansion

The Linux runner should support Linux-native path handling rather than Windows-style path rules.

### Environment expansion

The runner should expand:

- `$VAR`
- `${VAR}`
- leading `~` in path-like values

The Linux runner does not need to interpret Windows-style `%USERPROFILE%` syntax.

### Relative path handling

Path-like values that are not absolute should be resolved relative to the selected config file's directory.

This applies to:

- `passwordFile`
- `backupFolders`
- `restore.defaultTarget`
- `logging.folder`

### Snapshot path conversion

On Linux, absolute backup paths should map directly to Restic snapshot paths.

Examples:

```text
/home/example/Documents -> /home/example/Documents
/etc -> /etc
/var/lib/postgresql -> /var/lib/postgresql
```

This is simpler than the Windows `/C/...` path conversion and should use normalized absolute paths before building restore commands.

---

## 9. Action Details

### init

Initialize the configured repository.

```bash
restic -r "$REPOSITORY" init
```

Expected behavior:

- validate config and prerequisites first
- do not delete or overwrite local data
- show a clear message if the repository already exists

### backup

Back up all configured folders.

Command pattern:

```bash
restic -r "$REPOSITORY" backup <folders> --exclude <items> --tag <tags>
```

Expected behavior:

- validate Restic and `jq`
- validate the password file
- expand and normalize configured backup folders
- skip missing backup folders with warnings
- stop if no valid folders remain
- support `--dry-run`
- append configured tags when present
- print backup duration

### snapshots

List snapshots.

```bash
restic -r "$REPOSITORY" snapshots
```

### status

Show a practical status summary.

Minimum Restic commands:

```bash
restic -r "$REPOSITORY" snapshots
restic -r "$REPOSITORY" stats latest
```

The runner should also print:

- config name
- config path
- repository string
- password file path, but never the password
- configured backup folders
- configured exclude items
- retention policy

### restore

Restore the configured backup folders from a selected snapshot.

Command pattern:

```bash
restic -r "$REPOSITORY" restore "${SNAPSHOT}:${RESTIC_PATH}" --target "$RESTORE_TARGET/$FOLDER_NAME"
```

Examples:

```bash
./runners/restic-batch-backup.sh restore --snapshot latest
./runners/restic-batch-backup.sh restore --snapshot latest --dry-run
./runners/restic-batch-backup.sh restore --snapshot 8f3a2b1c --restore-target /tmp/restore
```

Expected behavior:

- use `restore.defaultTarget` if `--restore-target` is omitted
- normalize the restore target path
- block restore targets that overlap configured backup folders
- create the restore target if it does not exist, except during dry-run
- refuse non-empty restore targets unless `--allow-non-empty-restore-target` is passed
- restore each configured backup folder into a subfolder below the restore target
- support `--dry-run` as a preview mode
- warn clearly before restore

Restic does not currently provide a native `restore --dry-run` flag. For Linux, `--dry-run` should therefore:

- perform the normal restore target safety checks
- avoid creating restore directories
- avoid writing restored files
- preview matching snapshot contents with `restic ls`

If the user passes a snapshot spec that already includes a path, such as:

```text
latest:/etc
```

the runner should restore that path directly into the chosen restore target instead of expanding all configured backup folders.

### Restore folder naming

Default restore folder naming should use the leaf folder name.

Examples:

```text
/home/example/Documents -> Documents
/etc -> etc
/var/lib/postgresql -> postgresql
```

If multiple configured backup folders share the same leaf name, the runner should disambiguate by using a sanitized path-based folder name.

Example:

```text
/srv/app/cache -> srv_app_cache
/var/cache -> var_cache
```

### check

Check repository integrity.

```bash
restic -r "$REPOSITORY" check
```

Optional later heavier check:

```bash
restic -r "$REPOSITORY" check --read-data-subset=5%
```

### forget

Apply retention policy and prune forgotten data.

```bash
restic -r "$REPOSITORY" forget --keep-daily <n> --keep-weekly <n> --keep-monthly <n> --prune
```

Expected behavior:

- print the active retention policy before running
- clearly warn that repository history will be modified

---

## 10. Safety Requirements

The Linux runner should be safe and boring in the same spirit as the PowerShell runner.

### Must do

- stop if the selected config file does not exist
- stop if the config JSON is invalid
- stop if required config values are missing or empty
- stop if `restic` is not installed
- stop if `jq` is not installed
- stop if the password file does not exist
- skip missing backup folders with warnings
- stop if no valid backup folders remain
- never print the Restic password
- never remove local files as part of normal runner behavior
- never restore over configured backup folders by default
- never restore into a non-empty target by default
- return a non-zero exit code when a Restic command fails

### Should do

- print the selected action
- print the config file in use
- print start and end time
- print total duration
- print backup duration for the `backup` action
- print Restic exit code
- show readable warnings and errors

---

## 11. Logging

The JSON field `logging.folder` should remain part of the shared schema for Linux as well.

To stay aligned with the current project scope, Linux support does not need to implement file logging if the PowerShell runner still defers it. However, the Linux runner should keep the config field compatible so logging can be added later without changing the schema.

If logging is implemented later, the preferred log file pattern is:

```text
restic-batch-backup-YYYY-MM-DD.log
```

Logs must not contain:

- Restic password contents
- SSH private key contents
- access tokens
- other raw secrets

---

## 12. Scheduling

Linux support should be easy to automate.

### Cron example

```cron
30 2 * * * cd /opt/restic-batch-backup && ./runners/restic-batch-backup.sh backup --config /etc/restic-batch-backup/config.json
```

### systemd service example

```ini
[Unit]
Description=Restic Batch Backup

[Service]
Type=oneshot
WorkingDirectory=/opt/restic-batch-backup
ExecStart=/opt/restic-batch-backup/runners/restic-batch-backup.sh backup --config /etc/restic-batch-backup/config.json
```

### systemd timer example

```ini
[Unit]
Description=Run Restic Batch Backup daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

The docs should recommend validating the command manually before enabling a scheduled run.

---

## 13. Testing and Validation

Linux support should include manual validation on a throwaway repository before considering the feature complete.

Minimum test cases:

- status with a valid config
- init against a new repository
- backup with `--dry-run`
- backup against a real small test folder
- backup with one missing configured folder and one valid folder
- restore with `--dry-run`
- restore into a new empty target
- restore refusal when the target already contains files
- restore refusal when the target overlaps a configured backup folder
- forget against a disposable test repository
- config-relative path resolution
- duplicate leaf-name restore disambiguation

Recommended tooling:

- `shellcheck` for the Bash runner
- optional `bats` tests later if the project grows

---

## 14. Implementation Phases

### Phase 1

Deliver a working Bash runner with action parity and the shared config schema:

- `runners/restic-batch-backup.sh`
- config loading with `jq`
- prerequisite checks
- `init`
- `backup`
- backup duration reporting
- `snapshots`
- `status`
- `restore`
- `check`
- `forget`

### Phase 2

Improve documentation and examples:

- README Linux usage section
- Linux example config values
- cron example
- systemd service and timer examples

### Phase 3

Optional hardening and polish:

- file logging
- shellcheck in CI
- automated integration tests
- optional heavier `check` mode

---

## 15. Acceptance Criteria

Linux support is ready for a first usable release when all of the following are true:

- a Bash runner exists at `runners/restic-batch-backup.sh`
- the runner supports the same action set as the PowerShell runner
- the runner uses the same JSON config schema
- Linux path and environment expansion behave as defined in this document
- backup and restore dry-runs work
- restore safety checks block overlapping and non-empty targets by default
- scheduled execution works with at least one documented Linux scheduler example
- manual validation has been completed on a disposable repository

The goal is not to build the most abstract cross-platform framework. The goal is to add a dependable Linux runner that feels as predictable and maintainable as the existing Windows-first implementation.
