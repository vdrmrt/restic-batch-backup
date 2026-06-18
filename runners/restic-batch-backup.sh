#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

SCRIPT_START_EPOCH="$(date +%s)"
SCRIPT_START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
FINAL_EXIT_CODE=0
SHOW_FINAL_SUMMARY=true
FAILURE_REPORTED=false

ACTION="backup"
CONFIG_PATH="${SCRIPT_DIR}/../config.json"
SNAPSHOT="latest"
RESTORE_TARGET=""
ALLOW_NON_EMPTY_RESTORE_TARGET=false
DRY_RUN=false

CONFIG_DIRECTORY=""
CONFIG_NAME=""
CONFIG_REPOSITORY=""
CONFIG_PASSWORD_FILE=""
CONFIG_DEFAULT_RESTORE_TARGET=""
CONFIG_LOGGING_FOLDER=""
CONFIG_KEEP_DAILY=0
CONFIG_KEEP_WEEKLY=0
CONFIG_KEEP_MONTHLY=0

declare -a CONFIG_BACKUP_FOLDERS=()
declare -a CONFIG_EXCLUDE_ITEMS=()
declare -a CONFIG_BACKUP_TAGS=()
declare -a VALID_BACKUP_FOLDERS=()

write_info() {
    printf '[INFO] %s\n' "$1"
}

write_warning() {
    printf '[WARN] %s\n' "$1"
}

write_failure() {
    FAILURE_REPORTED=true
    printf '[ERROR] %s\n' "$1" >&2
}

write_section() {
    printf '\n== %s ==\n' "$1"
}

format_duration() {
    local total_seconds=${1:-0}
    local days=0
    local hours=0
    local minutes=0
    local seconds=0

    days=$(( total_seconds / 86400 ))
    hours=$(( (total_seconds % 86400) / 3600 ))
    minutes=$(( (total_seconds % 3600) / 60 ))
    seconds=$(( total_seconds % 60 ))

    if (( days > 0 )); then
        printf '%02d.%02d:%02d:%02d\n' "$days" "$hours" "$minutes" "$seconds"
        return
    fi

    if (( total_seconds >= 3600 )); then
        printf '%02d:%02d:%02d\n' "$hours" "$minutes" "$seconds"
        return
    fi

    printf '%02d:%02d\n' "$minutes" "$seconds"
}

quote_argument() {
    local quoted
    printf -v quoted '%q' "$1"
    printf '%s\n' "$quoted"
}

show_usage() {
    cat <<'EOF'
Usage:
  ./runners/restic-batch-backup.sh [action] [options]

Actions:
  init
  backup
  snapshots
  status
  restore
  check
  forget

Options:
  --config <path>
  --snapshot <id-or-id:path>
  --restore-target <path>
  --allow-non-empty-restore-target
  --dry-run
  --help

Examples:
  ./runners/restic-batch-backup.sh backup
  ./runners/restic-batch-backup.sh backup --dry-run
  ./runners/restic-batch-backup.sh status
  ./runners/restic-batch-backup.sh restore --snapshot latest --restore-target /tmp/restic-restore
EOF
}

fail() {
    local message=$1
    local exit_code=${2:-1}

    FINAL_EXIT_CODE=$exit_code
    write_failure "$message"
    exit "$exit_code"
}

handle_unexpected_error() {
    local exit_code=$1
    local line_number=$2

    if (( exit_code == 0 )); then
        return
    fi

    FINAL_EXIT_CODE=$exit_code
    if [[ "$FAILURE_REPORTED" != "true" ]]; then
        write_failure "Unexpected error near line ${line_number}."
    fi

    exit "$exit_code"
}

finalize_script() {
    local exit_code=$?
    local script_end_epoch
    local script_end_time
    local script_duration

    if [[ $FINAL_EXIT_CODE -eq 0 ]]; then
        FINAL_EXIT_CODE=$exit_code
    fi

    if [[ "$SHOW_FINAL_SUMMARY" != "true" ]]; then
        return
    fi

    script_end_epoch="$(date +%s)"
    script_end_time="$(date '+%Y-%m-%d %H:%M:%S')"
    script_duration="$(format_duration "$(( script_end_epoch - SCRIPT_START_EPOCH ))")"

    write_info "End time: $script_end_time"
    write_info "Total duration: $script_duration"
    write_info "Final exit code: $FINAL_EXIT_CODE"
}

trap 'handle_unexpected_error $? $LINENO' ERR
trap finalize_script EXIT

is_blank_string() {
    [[ -z "${1//[[:space:]]/}" ]]
}

assert_bash_version() {
    if (( BASH_VERSINFO[0] < 4 )); then
        fail "Bash 4.0 or newer is required."
    fi
}

assert_command_available() {
    local command_name=$1

    if ! command -v "$command_name" >/dev/null 2>&1; then
        fail "Required command not found on PATH: $command_name"
    fi
}

normalize_path() {
    realpath -m -- "$1"
}

normalize_existing_or_virtual_path() {
    if [[ -e $1 ]]; then
        realpath -- "$1"
        return
    fi

    normalize_path "$1"
}

expand_environment_references() {
    local remainder=$1
    local output=""
    local prefix=""
    local variable_name=""

    while [[ -n $remainder ]]; do
        if [[ $remainder =~ ^([^$]*)\$\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$ ]]; then
            prefix=${BASH_REMATCH[1]}
            variable_name=${BASH_REMATCH[2]}
            remainder=${BASH_REMATCH[3]}
            output+=$prefix
            output+=${!variable_name-}
        elif [[ $remainder =~ ^([^$]*)\$([A-Za-z_][A-Za-z0-9_]*)(.*)$ ]]; then
            prefix=${BASH_REMATCH[1]}
            variable_name=${BASH_REMATCH[2]}
            remainder=${BASH_REMATCH[3]}
            output+=$prefix
            output+=${!variable_name-}
        else
            output+=$remainder
            break
        fi
    done

    printf '%s\n' "$output"
}

expand_leading_tilde() {
    local value=$1

    if [[ $value == "~" ]]; then
        if [[ -z ${HOME:-} ]]; then
            fail "HOME is not set, so '~' cannot be expanded."
        fi

        printf '%s\n' "$HOME"
        return
    fi

    if [[ $value == \~/* ]]; then
        if [[ -z ${HOME:-} ]]; then
            fail "HOME is not set, so '~' cannot be expanded."
        fi

        printf '%s\n' "$HOME/${value#~/}"
        return
    fi

    printf '%s\n' "$value"
}

resolve_config_path_value() {
    local value=$1
    local expanded_value

    expanded_value="$(expand_environment_references "$value")"
    expanded_value="$(expand_leading_tilde "$expanded_value")"

    if is_blank_string "$expanded_value"; then
        printf '\n'
        return
    fi

    if [[ $expanded_value != /* ]]; then
        expanded_value="${CONFIG_DIRECTORY}/${expanded_value}"
    fi

    normalize_path "$expanded_value"
}

resolve_cli_path_value() {
    local value=$1
    local expanded_value

    expanded_value="$(expand_environment_references "$value")"
    expanded_value="$(expand_leading_tilde "$expanded_value")"

    if is_blank_string "$expanded_value"; then
        printf '\n'
        return
    fi

    if [[ $expanded_value != /* ]]; then
        expanded_value="${PWD}/${expanded_value}"
    fi

    normalize_path "$expanded_value"
}

read_required_json_string() {
    local jq_query=$1
    local display_name=$2
    local raw_value

    if ! raw_value="$(jq -er "$jq_query | select(type == \"string\")" "$CONFIG_PATH" 2>/dev/null)"; then
        fail "Missing required config value '$display_name'."
    fi

    if is_blank_string "$raw_value"; then
        fail "Missing required config value '$display_name'."
    fi

    printf '%s\n' "$raw_value"
}

read_optional_json_string() {
    local jq_query=$1
    local raw_value

    if ! jq -e "if ($jq_query) == null then true else (($jq_query) | type == \"string\") end" "$CONFIG_PATH" >/dev/null 2>&1; then
        fail "Optional config value for query '$jq_query' must be a string when set."
    fi

    raw_value="$(jq -er "($jq_query // empty) | select(type == \"string\")" "$CONFIG_PATH" 2>/dev/null || true)"
    printf '%s\n' "$raw_value"
}

read_required_json_integer() {
    local jq_query=$1
    local display_name=$2
    local raw_value

    if ! raw_value="$(jq -er "$jq_query | select(type == \"number\" or type == \"string\")" "$CONFIG_PATH" 2>/dev/null)"; then
        fail "Missing required config value '$display_name'."
    fi

    if ! [[ $raw_value =~ ^[0-9]+$ ]]; then
        fail "Config value '$display_name' must be zero or greater."
    fi

    printf '%s\n' "$raw_value"
}

assert_json_array_of_strings() {
    local jq_query=$1
    local display_name=$2
    local required=$3

    if [[ $required == "true" ]]; then
        if ! jq -e "$jq_query | type == \"array\" and all(.[]; type == \"string\")" "$CONFIG_PATH" >/dev/null 2>&1; then
            fail "Config value '$display_name' must be an array of strings."
        fi
        return
    fi

    if ! jq -e "($jq_query // []) | type == \"array\" and all(.[]; type == \"string\")" "$CONFIG_PATH" >/dev/null 2>&1; then
        fail "Config value '$display_name' must be an array of strings."
    fi
}

load_backup_config() {
    local raw_name
    local raw_repository
    local raw_password_file
    local raw_default_restore_target
    local raw_logging_folder
    local raw_item
    local expanded_item

    CONFIG_PATH="$(normalize_path "$CONFIG_PATH")"
    if [[ ! -f $CONFIG_PATH ]]; then
        fail "Config file not found: $CONFIG_PATH"
    fi

    if ! jq empty "$CONFIG_PATH" >/dev/null 2>&1; then
        fail "Failed to read JSON config '$CONFIG_PATH'."
    fi

    if ! jq -e 'type == "object"' "$CONFIG_PATH" >/dev/null 2>&1; then
        fail "Config file must contain a single JSON object: $CONFIG_PATH"
    fi

    CONFIG_DIRECTORY="$(dirname "$CONFIG_PATH")"

    raw_name="$(read_required_json_string '.name' 'name')"
    CONFIG_NAME="$(expand_environment_references "$raw_name")"
    if is_blank_string "$CONFIG_NAME"; then
        fail "Missing required config value 'name'."
    fi

    raw_repository="$(read_required_json_string '.repository' 'repository')"
    CONFIG_REPOSITORY="$(expand_environment_references "$raw_repository")"
    if is_blank_string "$CONFIG_REPOSITORY"; then
        fail "Missing required config value 'repository'."
    fi

    raw_password_file="$(read_required_json_string '.passwordFile' 'passwordFile')"
    CONFIG_PASSWORD_FILE="$(resolve_config_path_value "$raw_password_file")"
    if is_blank_string "$CONFIG_PASSWORD_FILE"; then
        fail "Missing required config value 'passwordFile'."
    fi

    CONFIG_BACKUP_FOLDERS=()
    assert_json_array_of_strings '.backupFolders' 'backupFolders' 'true'
    while IFS= read -r raw_item; do
        expanded_item="$(resolve_config_path_value "$raw_item")"
        if ! is_blank_string "$expanded_item"; then
            CONFIG_BACKUP_FOLDERS+=("$expanded_item")
        fi
    done < <(jq -r '.backupFolders[]' "$CONFIG_PATH")

    if (( ${#CONFIG_BACKUP_FOLDERS[@]} == 0 )); then
        fail "Config value 'backupFolders' must contain at least one folder."
    fi

    CONFIG_EXCLUDE_ITEMS=()
    assert_json_array_of_strings '.excludeItems' 'excludeItems' 'false'
    while IFS= read -r raw_item; do
        expanded_item="$(expand_environment_references "$raw_item")"
        if ! is_blank_string "$expanded_item"; then
            CONFIG_EXCLUDE_ITEMS+=("$expanded_item")
        fi
    done < <(jq -r '(.excludeItems // [])[]' "$CONFIG_PATH")

    CONFIG_BACKUP_TAGS=()
    assert_json_array_of_strings '.backupTags' 'backupTags' 'false'
    while IFS= read -r raw_item; do
        expanded_item="$(expand_environment_references "$raw_item")"
        if ! is_blank_string "$expanded_item"; then
            CONFIG_BACKUP_TAGS+=("$expanded_item")
        fi
    done < <(jq -r '(.backupTags // [])[]' "$CONFIG_PATH")

    CONFIG_KEEP_DAILY="$(read_required_json_integer '.retention.keepDaily' 'retention.keepDaily')"
    CONFIG_KEEP_WEEKLY="$(read_required_json_integer '.retention.keepWeekly' 'retention.keepWeekly')"
    CONFIG_KEEP_MONTHLY="$(read_required_json_integer '.retention.keepMonthly' 'retention.keepMonthly')"

    raw_default_restore_target="$(read_required_json_string '.restore.defaultTarget' 'restore.defaultTarget')"
    CONFIG_DEFAULT_RESTORE_TARGET="$(resolve_config_path_value "$raw_default_restore_target")"
    if is_blank_string "$CONFIG_DEFAULT_RESTORE_TARGET"; then
        fail "Missing required config value 'restore.defaultTarget'."
    fi

    raw_logging_folder="$(read_optional_json_string '.logging.folder')"
    if is_blank_string "$raw_logging_folder"; then
        raw_logging_folder="$HOME/.local/state/restic-batch-backup/logs"
    fi

    CONFIG_LOGGING_FOLDER="$(resolve_config_path_value "$raw_logging_folder")"
    if is_blank_string "$CONFIG_LOGGING_FOLDER"; then
        CONFIG_LOGGING_FOLDER="$(resolve_config_path_value "$HOME/.local/state/restic-batch-backup/logs")"
    fi
}

assert_restic_available() {
    assert_command_available jq
    assert_command_available realpath
    assert_command_available restic
}

assert_password_file_exists() {
    if [[ ! -f $CONFIG_PASSWORD_FILE ]]; then
        fail "Restic password file not found: $CONFIG_PASSWORD_FILE"
    fi
}

invoke_restic_command() {
    local -a arguments=("$@")
    local -a formatted_arguments=()
    local argument
    local formatted_command=""
    local exit_code=0

    for argument in "${arguments[@]}"; do
        formatted_arguments+=("$(quote_argument "$argument")")
    done

    formatted_command="${formatted_arguments[*]}"
    write_info "Running: restic $formatted_command"

    if restic "${arguments[@]}"; then
        exit_code=0
    else
        exit_code=$?
    fi

    write_info "Restic exit code: $exit_code"
    return "$exit_code"
}

get_valid_backup_folders() {
    local backup_folder
    local resolved_folder

    VALID_BACKUP_FOLDERS=()
    for backup_folder in "${CONFIG_BACKUP_FOLDERS[@]}"; do
        if [[ -d $backup_folder ]]; then
            resolved_folder="$(realpath -- "$backup_folder")"
            VALID_BACKUP_FOLDERS+=("$resolved_folder")
        else
            write_warning "Backup folder not found; skipping: $backup_folder"
        fi
    done

    if (( ${#VALID_BACKUP_FOLDERS[@]} == 0 )); then
        fail "No valid backup folders remain after checking configured folders."
    fi
}

ensure_trailing_slash() {
    if [[ $1 == "/" ]]; then
        printf '/\n'
        return
    fi

    printf '%s/\n' "${1%/}"
}

paths_overlap() {
    local first_path
    local second_path

    first_path="$(normalize_existing_or_virtual_path "$1")"
    second_path="$(normalize_existing_or_virtual_path "$2")"

    first_path="$(ensure_trailing_slash "$first_path")"
    second_path="$(ensure_trailing_slash "$second_path")"

    [[ $first_path == "$second_path"* || $second_path == "$first_path"* ]]
}

assert_restore_target_is_safe() {
    local effective_restore_target=$1
    local backup_folder

    for backup_folder in "${CONFIG_BACKUP_FOLDERS[@]}"; do
        if paths_overlap "$effective_restore_target" "$backup_folder"; then
            fail "Restore target overlaps a configured backup folder. Choose a separate restore target. Target: $effective_restore_target Backup folder: $backup_folder"
        fi
    done
}

directory_has_content() {
    find "$1" -mindepth 1 -maxdepth 1 -print -quit | grep -q .
}

assert_restore_target_can_be_used() {
    local effective_restore_target=$1
    local allow_non_empty_target=$2
    local create_if_missing=$3

    if [[ -f $effective_restore_target ]]; then
        fail "Restore target is a file, not a folder: $effective_restore_target"
    fi

    if [[ ! -d $effective_restore_target ]]; then
        if [[ $create_if_missing == "true" ]]; then
            mkdir -p -- "$effective_restore_target"
        fi
        return
    fi

    if directory_has_content "$effective_restore_target" && [[ $allow_non_empty_target != "true" ]]; then
        fail "Restore target is not empty: $effective_restore_target. Choose a new empty folder or rerun with --allow-non-empty-restore-target."
    fi
}

convert_to_restic_snapshot_path() {
    normalize_existing_or_virtual_path "$1"
}

sanitize_snapshot_path_for_folder_name() {
    local snapshot_path=$1
    local sanitized_name=${snapshot_path#/}

    sanitized_name=${sanitized_name//\//_}
    if [[ -z $sanitized_name ]]; then
        sanitized_name="root"
    fi

    printf '%s\n' "$sanitized_name"
}

convert_to_restore_folder_name() {
    local path=$1
    local normalized_path
    local leaf_name
    local snapshot_path

    normalized_path="$(normalize_existing_or_virtual_path "$path")"
    leaf_name="$(basename -- "$normalized_path")"

    if [[ -n $leaf_name && $leaf_name != "/" && $leaf_name != "." ]]; then
        printf '%s\n' "$leaf_name"
        return
    fi

    snapshot_path="$(convert_to_restic_snapshot_path "$normalized_path")"
    sanitize_snapshot_path_for_folder_name "$snapshot_path"
}

join_path() {
    local parent_path=$1
    local child_path=${2#/}

    if [[ $parent_path == "/" ]]; then
        printf '/%s\n' "$child_path"
        return
    fi

    printf '%s/%s\n' "${parent_path%/}" "$child_path"
}

snapshot_spec_includes_path() {
    [[ $1 =~ ^[^:]+:.+$ ]]
}

show_config_summary() {
    local backup_folder
    local exclude_item

    write_section "Configuration"
    write_info "Name: $CONFIG_NAME"
    write_info "Config path: $CONFIG_PATH"
    write_info "Repository: $CONFIG_REPOSITORY"
    write_info "Password file: $CONFIG_PASSWORD_FILE"
    write_info "Log folder: $CONFIG_LOGGING_FOLDER"
    write_info "Retention: daily=$CONFIG_KEEP_DAILY, weekly=$CONFIG_KEEP_WEEKLY, monthly=$CONFIG_KEEP_MONTHLY"

    write_info "Backup folders:"
    for backup_folder in "${CONFIG_BACKUP_FOLDERS[@]}"; do
        printf '  - %s\n' "$backup_folder"
    done

    write_info "Exclude items:"
    if (( ${#CONFIG_EXCLUDE_ITEMS[@]} == 0 )); then
        printf '  - none\n'
        return
    fi

    for exclude_item in "${CONFIG_EXCLUDE_ITEMS[@]}"; do
        printf '  - %s\n' "$exclude_item"
    done
}

invoke_init_action() {
    local exit_code

    if invoke_restic_command -r "$CONFIG_REPOSITORY" init; then
        return 0
    else
        exit_code=$?
    fi

    write_warning "If the repository is already initialized, no action may be needed. Review the Restic output above."
    return "$exit_code"
}

invoke_backup_action() {
    local use_dry_run=$1
    local -a arguments=(-r "$CONFIG_REPOSITORY" backup)
    local exclude_item
    local backup_tag
    local backup_folder
    local backup_start_epoch
    local backup_end_epoch
    local backup_duration
    local exit_code

    get_valid_backup_folders

    for backup_folder in "${VALID_BACKUP_FOLDERS[@]}"; do
        arguments+=("$backup_folder")
    done

    for exclude_item in "${CONFIG_EXCLUDE_ITEMS[@]}"; do
        arguments+=(--exclude "$exclude_item")
    done

    for backup_tag in "${CONFIG_BACKUP_TAGS[@]}"; do
        arguments+=(--tag "$backup_tag")
    done

    if [[ $use_dry_run == "true" ]]; then
        arguments+=(--dry-run)
    fi

    backup_start_epoch="$(date +%s)"
    if invoke_restic_command "${arguments[@]}"; then
        exit_code=0
    else
        exit_code=$?
    fi

    backup_end_epoch="$(date +%s)"
    backup_duration="$(format_duration "$(( backup_end_epoch - backup_start_epoch ))")"
    write_info "Backup duration: $backup_duration"
    return "$exit_code"
}

invoke_snapshots_action() {
    invoke_restic_command -r "$CONFIG_REPOSITORY" snapshots
}

invoke_status_action() {
    local exit_code

    show_config_summary

    write_section "Snapshots"
    if invoke_restic_command -r "$CONFIG_REPOSITORY" snapshots; then
        :
    else
        exit_code=$?
        return "$exit_code"
    fi

    write_section "Stats"
    invoke_restic_command -r "$CONFIG_REPOSITORY" stats latest
}

invoke_restore_action() {
    local snapshot_id=$1
    local requested_restore_target=$2
    local use_dry_run=$3
    local allow_non_empty_target=$4
    local effective_restore_target=$requested_restore_target
    local create_if_missing=true
    local -A folder_name_counts=()
    local backup_folder
    local folder_name
    local snapshot_path
    local target_folder_name
    local restore_subfolder
    local snapshot_spec
    local exit_code
    local snapshot_ref
    local snapshot_filter

    if is_blank_string "$effective_restore_target"; then
        effective_restore_target=$CONFIG_DEFAULT_RESTORE_TARGET
    else
        effective_restore_target="$(resolve_cli_path_value "$effective_restore_target")"
    fi

    if is_blank_string "$effective_restore_target"; then
        fail "Restore target cannot be blank."
    fi

    if [[ $use_dry_run == "true" ]]; then
        create_if_missing=false
    fi

    assert_restore_target_is_safe "$effective_restore_target"
    assert_restore_target_can_be_used "$effective_restore_target" "$allow_non_empty_target" "$create_if_missing"

    if [[ $allow_non_empty_target == "true" ]]; then
        write_warning "Restore target may already contain files: $effective_restore_target"
    fi

    if snapshot_spec_includes_path "$snapshot_id"; then
        if [[ $use_dry_run == "true" ]]; then
            snapshot_ref=${snapshot_id%%:*}
            snapshot_filter=${snapshot_id#*:}
            write_warning "Previewing restore of snapshot path '$snapshot_id' to '$effective_restore_target'. Restic restore does not support --dry-run, so no files will be written."
            invoke_restic_command -r "$CONFIG_REPOSITORY" ls "$snapshot_ref" "$snapshot_filter" --recursive
            return
        fi

        local -a arguments=(-r "$CONFIG_REPOSITORY" restore "$snapshot_id" --target "$effective_restore_target")

        write_warning "Restoring snapshot path '$snapshot_id' to '$effective_restore_target'."
        invoke_restic_command "${arguments[@]}"
        return
    fi

    for backup_folder in "${CONFIG_BACKUP_FOLDERS[@]}"; do
        folder_name="$(convert_to_restore_folder_name "$backup_folder")"
        folder_name_counts["$folder_name"]=$(( ${folder_name_counts["$folder_name"]:-0} + 1 ))
    done

    for backup_folder in "${CONFIG_BACKUP_FOLDERS[@]}"; do
        snapshot_path="$(convert_to_restic_snapshot_path "$backup_folder")"
        target_folder_name="$(convert_to_restore_folder_name "$backup_folder")"
        if (( ${folder_name_counts["$target_folder_name"]} > 1 )); then
            target_folder_name="$(sanitize_snapshot_path_for_folder_name "$snapshot_path")"
        fi

        restore_subfolder="$(join_path "$effective_restore_target" "$target_folder_name")"
        snapshot_spec="${snapshot_id}:${snapshot_path}"

        if [[ $use_dry_run == "true" ]]; then
            write_warning "Previewing restore of '$backup_folder' from snapshot '$snapshot_id' to '$restore_subfolder'. Restic restore does not support --dry-run, so no files will be written."
            if invoke_restic_command -r "$CONFIG_REPOSITORY" ls "$snapshot_id" "$snapshot_path" --recursive; then
                :
            else
                exit_code=$?
                return "$exit_code"
            fi
            continue
        fi

        local -a arguments=(-r "$CONFIG_REPOSITORY" restore "$snapshot_spec" --target "$restore_subfolder")
        write_warning "Restoring '$backup_folder' from snapshot '$snapshot_id' to '$restore_subfolder'."
        if invoke_restic_command "${arguments[@]}"; then
            :
        else
            exit_code=$?
            return "$exit_code"
        fi
    done
}

invoke_check_action() {
    invoke_restic_command -r "$CONFIG_REPOSITORY" check
}

invoke_forget_action() {
    write_info "Retention policy: daily=$CONFIG_KEEP_DAILY, weekly=$CONFIG_KEEP_WEEKLY, monthly=$CONFIG_KEEP_MONTHLY"
    write_warning "This action modifies repository history by pruning forgotten data."

    invoke_restic_command \
        -r "$CONFIG_REPOSITORY" \
        forget \
        --keep-daily "$CONFIG_KEEP_DAILY" \
        --keep-weekly "$CONFIG_KEEP_WEEKLY" \
        --keep-monthly "$CONFIG_KEEP_MONTHLY" \
        --prune
}

parse_arguments() {
    local action_was_set=false

    while (($# > 0)); do
        case "$1" in
            init|backup|snapshots|status|restore|check|forget)
                if [[ $action_was_set == "true" ]]; then
                    fail "Only one action may be specified."
                fi
                ACTION=$1
                action_was_set=true
                shift
                ;;
            --config)
                if (($# < 2)); then
                    fail "Missing value for --config."
                fi
                CONFIG_PATH=$2
                shift 2
                ;;
            --config=*)
                CONFIG_PATH=${1#--config=}
                shift
                ;;
            --snapshot)
                if (($# < 2)); then
                    fail "Missing value for --snapshot."
                fi
                SNAPSHOT=$2
                shift 2
                ;;
            --snapshot=*)
                SNAPSHOT=${1#--snapshot=}
                shift
                ;;
            --restore-target)
                if (($# < 2)); then
                    fail "Missing value for --restore-target."
                fi
                RESTORE_TARGET=$2
                shift 2
                ;;
            --restore-target=*)
                RESTORE_TARGET=${1#--restore-target=}
                shift
                ;;
            --allow-non-empty-restore-target)
                ALLOW_NON_EMPTY_RESTORE_TARGET=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help|-h)
                SHOW_FINAL_SUMMARY=false
                show_usage
                exit 0
                ;;
            -*)
                fail "Unknown option: $1"
                ;;
            *)
                fail "Unknown action or argument: $1"
                ;;
        esac
    done
}

run_action() {
    case "$ACTION" in
        init)
            invoke_init_action
            ;;
        backup)
            invoke_backup_action "$DRY_RUN"
            ;;
        snapshots)
            invoke_snapshots_action
            ;;
        status)
            invoke_status_action
            ;;
        restore)
            invoke_restore_action "$SNAPSHOT" "$RESTORE_TARGET" "$DRY_RUN" "$ALLOW_NON_EMPTY_RESTORE_TARGET"
            ;;
        check)
            invoke_check_action
            ;;
        forget)
            invoke_forget_action
            ;;
        *)
            fail "Unsupported action: $ACTION"
            ;;
    esac
}

main() {
    assert_bash_version
    parse_arguments "$@"

    write_section "Restic Batch Backup"
    write_info "Action: $ACTION"
    write_info "Start time: $SCRIPT_START_TIME"

    assert_command_available jq
    assert_command_available realpath
    load_backup_config
    export RESTIC_PASSWORD_FILE="$CONFIG_PASSWORD_FILE"

    assert_restic_available
    assert_password_file_exists

    if [[ $DRY_RUN == "true" && $ACTION != "backup" && $ACTION != "restore" ]]; then
        write_warning "--dry-run only applies to the backup and restore actions and will be ignored for '$ACTION'."
    fi

    local action_exit_code

    if run_action; then
        FINAL_EXIT_CODE=0
        return 0
    else
        action_exit_code=$?
    fi

    FINAL_EXIT_CODE=$action_exit_code
    write_failure "Action '$ACTION' failed with exit code $FINAL_EXIT_CODE."
    return "$FINAL_EXIT_CODE"
}

main "$@"
