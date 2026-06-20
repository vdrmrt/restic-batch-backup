#!/usr/bin/env bash

set -euo pipefail

TARGET_DIR="/tmp/restic-test"
MUTATE=false

show_usage() {
    cat <<'EOF'
Usage:
  ./scripts/create-restic-test-data.sh [--target <path>] [--mutate]

Options:
  --target <path>   Destination folder for the test data. Default: /tmp/restic-test
  --mutate          Modify an existing dataset instead of recreating it from scratch
  --help            Show this help text
EOF
}

parse_arguments() {
    while (($# > 0)); do
        case "$1" in
            --target)
                if (($# < 2)); then
                    printf 'Missing value for --target.\n' >&2
                    exit 1
                fi
                TARGET_DIR=$2
                shift 2
                ;;
            --target=*)
                TARGET_DIR=${1#--target=}
                shift
                ;;
            --mutate)
                MUTATE=true
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                printf 'Unknown option: %s\n' "$1" >&2
                show_usage >&2
                exit 1
                ;;
        esac
    done
}

seed_dataset() {
    rm -rf -- "$TARGET_DIR"

    mkdir -p \
        "$TARGET_DIR/Documents" \
        "$TARGET_DIR/Projects/app/src" \
        "$TARGET_DIR/Pictures" \
        "$TARGET_DIR/Archives/2026" \
        "$TARGET_DIR/Folder With Spaces" \
        "$TARGET_DIR/.cache" \
        "$TARGET_DIR/node_modules/demo-package"

    printf 'Restic SFTP test notes\nCreated for backup testing\n' > "$TARGET_DIR/Documents/notes.txt"
    printf '%s\n' '- verify backup' '- verify restore' > "$TARGET_DIR/Documents/todo.txt"
    printf '# Demo App\n\nThis file is part of the Restic test dataset.\n' > "$TARGET_DIR/Projects/app/README.md"
    printf 'console.log("restic test data");\n' > "$TARGET_DIR/Projects/app/src/main.js"
    printf 'Monthly test report placeholder.\n' > "$TARGET_DIR/Archives/2026/report-2026-06.txt"
    printf 'This path validates handling of spaces.\n' > "$TARGET_DIR/Folder With Spaces/example file.txt"
    printf 'This file should be excluded when .cache is configured.\n' > "$TARGET_DIR/.cache/cache-info.txt"
    printf 'module.exports = "excluded package";\n' > "$TARGET_DIR/node_modules/demo-package/index.js"

    head -c 1048576 /dev/urandom > "$TARGET_DIR/Pictures/random-1mb.bin"
    head -c 262144 /dev/urandom > "$TARGET_DIR/Pictures/random-256kb.bin"

    printf 'Created test data in %s\n' "$TARGET_DIR"
}

mutate_dataset() {
    if [[ ! -d $TARGET_DIR ]]; then
        printf 'Target folder does not exist yet: %s\n' "$TARGET_DIR" >&2
        printf 'Run the script once without --mutate first.\n' >&2
        exit 1
    fi

    printf '\nMutation applied at %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$TARGET_DIR/Documents/notes.txt"
    printf 'This file was added after the first backup.\n' > "$TARGET_DIR/Documents/new-after-backup.txt"
    printf '{ "featureFlag": true, "mode": "mutated" }\n' > "$TARGET_DIR/Projects/app/src/config.json"
    rm -f -- "$TARGET_DIR/Archives/2026/report-2026-06.txt"
    head -c 524288 /dev/urandom > "$TARGET_DIR/Pictures/random-512kb.bin"

    printf 'Mutated test data in %s\n' "$TARGET_DIR"
}

main() {
    parse_arguments "$@"

    if [[ $MUTATE == "true" ]]; then
        mutate_dataset
        return
    fi

    seed_dataset
}

main "$@"
