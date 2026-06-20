#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_ROOT

TEMP_DIR="$(mktemp -d)"
readonly TEMP_DIR
RESTIC_LOG="${TEMP_DIR}/restic.log"
readonly RESTIC_LOG

cleanup() {
    rm -rf -- "$TEMP_DIR"
}

fail() {
    printf 'TEST FAILURE: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local needle=$1
    local haystack_file=$2

    if ! grep -F -- "$needle" "$haystack_file" >/dev/null 2>&1; then
        fail "Expected to find '$needle' in $haystack_file"
    fi
}

assert_not_contains() {
    local needle=$1
    local haystack_file=$2

    if grep -F -- "$needle" "$haystack_file" >/dev/null 2>&1; then
        fail "Did not expect to find '$needle' in $haystack_file"
    fi
}

reset_restic_log() {
    : > "$RESTIC_LOG"
}

create_fake_restic() {
    local bin_dir="${TEMP_DIR}/bin"

    mkdir -p -- "$bin_dir"

    cat <<'EOF' > "${bin_dir}/restic"
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$RESTIC_LOG"

command_name=""
for argument in "$@"; do
    case "$argument" in
        init|backup|snapshots|stats|ls|restore|check|forget)
            command_name=$argument
            break
            ;;
    esac
done

case "$command_name" in
    init)
        printf 'created restic repository\n'
        ;;
    backup)
        printf 'Files: 1 new, 0 changed, 0 unmodified\n'
        ;;
    snapshots)
        printf 'ID        Time                 Host        Tags        Paths\n'
        ;;
    stats)
        printf 'processed 2 files, 1.0 KiB in 0:00\n'
        ;;
    ls)
        printf '/mock/path\n'
        ;;
    restore)
        printf 'restored data\n'
        ;;
    check)
        printf 'repository check OK\n'
        ;;
    forget)
        printf 'removed old snapshots\n'
        ;;
    *)
        printf 'Unexpected restic command: %s\n' "$*" >&2
        exit 1
        ;;
esac
EOF

    chmod +x "${bin_dir}/restic"
    export PATH="${bin_dir}:${PATH}"
    export RESTIC_LOG
}

create_test_config() {
    local config_path="${TEMP_DIR}/config.json"
    local password_file="${TEMP_DIR}/restic-password.txt"
    local documents_dir="${TEMP_DIR}/data/documents"
    local pictures_dir="${TEMP_DIR}/data/pictures"
    local restore_dir="${TEMP_DIR}/restore-target"
    local logs_dir="${TEMP_DIR}/logs"

    mkdir -p -- "$documents_dir" "$pictures_dir" "$logs_dir"
    : > "$password_file"

    cat <<EOF > "$config_path"
{
  "name": "bash-smoke",
  "repository": "local:${TEMP_DIR}/repo",
  "passwordFile": "${password_file}",
  "backupFolders": [
    "${documents_dir}",
    "${pictures_dir}"
  ],
  "excludeItems": [
    "node_modules",
    ".cache"
  ],
  "retention": {
    "keepDaily": 7,
    "keepWeekly": 4,
    "keepMonthly": 6
  },
  "restore": {
    "defaultTarget": "${restore_dir}"
  },
  "logging": {
    "folder": "${logs_dir}"
  },
  "backupTags": [
    "bash-smoke",
    "ci"
  ]
}
EOF

    printf '%s\n' "$config_path"
}

create_sftp_identity_test_config() {
    local config_path="${TEMP_DIR}/sftp-config.json"
    local password_file="${TEMP_DIR}/restic-password.txt"
    local documents_dir="${TEMP_DIR}/data/documents"
    local restore_dir="${TEMP_DIR}/restore-target"
    local logs_dir="${TEMP_DIR}/logs"
    local identity_file="${TEMP_DIR}/id_ed25519_test"

    mkdir -p -- "$documents_dir" "$logs_dir"
    : > "$password_file"
    : > "$identity_file"

    cat <<EOF > "$config_path"
{
  "name": "bash-sftp-smoke",
  "repository": "sftp:test-host:/tmp/repo",
  "passwordFile": "${password_file}",
  "backupFolders": [
    "${documents_dir}"
  ],
  "retention": {
    "keepDaily": 7,
    "keepWeekly": 4,
    "keepMonthly": 6
  },
  "restore": {
    "defaultTarget": "${restore_dir}"
  },
  "logging": {
    "folder": "${logs_dir}"
  },
  "ssh": {
    "identityFile": "${identity_file}"
  }
}
EOF

    printf '%s\n' "$config_path"
}

run_runner() {
    bash "${REPO_ROOT}/runners/restic-batch-backup.sh" "$@"
}

trap cleanup EXIT

create_fake_restic
CONFIG_PATH="$(create_test_config)"
readonly CONFIG_PATH
SFTP_CONFIG_PATH="$(create_sftp_identity_test_config)"
readonly SFTP_CONFIG_PATH

bash -n "${REPO_ROOT}/runners/restic-batch-backup.sh"

reset_restic_log
run_runner init --config "$CONFIG_PATH" >/dev/null
assert_contains " init" "$RESTIC_LOG"
assert_not_contains "sftp.args=" "$RESTIC_LOG"

reset_restic_log
run_runner init --config "$SFTP_CONFIG_PATH" >/dev/null
assert_contains "sftp.args=-i ${TEMP_DIR}/id_ed25519_test -o IdentitiesOnly=yes" "$RESTIC_LOG"
assert_contains "sftp:test-host:/tmp/repo init" "$RESTIC_LOG"

reset_restic_log
run_runner backup --dry-run --config "$CONFIG_PATH" >/dev/null
assert_contains " backup " "$RESTIC_LOG"
assert_contains "${TEMP_DIR}/data/documents" "$RESTIC_LOG"
assert_contains "${TEMP_DIR}/data/pictures" "$RESTIC_LOG"
assert_contains "--exclude node_modules" "$RESTIC_LOG"
assert_contains "--exclude .cache" "$RESTIC_LOG"
assert_contains "--tag bash-smoke" "$RESTIC_LOG"
assert_contains "--tag ci" "$RESTIC_LOG"
assert_contains "--dry-run" "$RESTIC_LOG"

reset_restic_log
run_runner snapshots --config "$CONFIG_PATH" >/dev/null
assert_contains " snapshots" "$RESTIC_LOG"

reset_restic_log
run_runner status --config "$CONFIG_PATH" >/dev/null
assert_contains " snapshots" "$RESTIC_LOG"
assert_contains " stats latest" "$RESTIC_LOG"

reset_restic_log
run_runner restore --snapshot latest --dry-run --config "$CONFIG_PATH" >/dev/null
assert_contains " ls latest ${TEMP_DIR}/data/documents --recursive" "$RESTIC_LOG"
assert_contains " ls latest ${TEMP_DIR}/data/pictures --recursive" "$RESTIC_LOG"
assert_not_contains " restore " "$RESTIC_LOG"

reset_restic_log
run_runner check --config "$CONFIG_PATH" >/dev/null
assert_contains " check" "$RESTIC_LOG"

reset_restic_log
run_runner forget --config "$CONFIG_PATH" >/dev/null
assert_contains " forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune" "$RESTIC_LOG"

printf 'Bash smoke tests passed.\n'
