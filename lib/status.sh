#!/usr/bin/env bash
set -euo pipefail

# Summarize recorded state only: do not source modules, inspect managed paths,
# execute rollback commands, or initialize the manifest/log directories.
sway98_status() {
    local status_name status_path
    local -a status_manifests=()
    for status_name in modules files dirs commands; do
        status_path="$SWAY98_STATE/manifest/$status_name.tsv"
        if [[ -e "$status_path" || -L "$status_path" ]]; then
            if [[ ! -f "$status_path" || ! -r "$status_path" ]]; then
                printf 'error: cannot read manifest: %s\n' "$status_path" >&2
                return 1
            fi
            # Relative paths that start with a dash or contain an equals
            # sign are filenames, not awk options or assignments.
            case "$status_path" in
                /*) ;;
                *) status_path="./$status_path" ;;
            esac
            status_manifests+=("$status_path")
        fi
    done

    printf 'Manifest: %s/manifest\n' "$SWAY98_STATE"
    if ((${#status_manifests[@]} == 0)); then
        printf 'No active manifest records.\n'
        return 0
    fi

    # Preserve first-seen module order and take the last completion record.
    # Per-module path counts deduplicate reinstall entries; every command row
    # counts because rollback executes each one. Never print command contents.
    awk -F '\t' '
        function invalid() {
            printf "error: invalid manifest record in %s at line %d\n", FILENAME, FNR > "/dev/stderr"
            bad = 1
            exit 1
        }
        NF == 0 { next }
        {
            if ($1 == "") invalid()
            if (!seen_module[$1]++) module[++count] = $1
        }
        FILENAME ~ /\/modules.tsv$/ {
            if (NF != 4 || $2 == "" || $3 == "" || $4 == "") invalid()
            result[$1] = $2
            version[$1] = $3
            timestamp[$1] = $4
        }
        FILENAME ~ /\/files.tsv$/ {
            if (NF != 6 || ($2 != "create" && $2 != "modify") || $3 == "") invalid()
            if (!seen_file[$1, $3]++) files[$1]++
        }
        FILENAME ~ /\/dirs.tsv$/ {
            if (NF != 2 || $2 == "") invalid()
            if (!seen_dir[$1, $2]++) dirs[$1]++
        }
        FILENAME ~ /\/commands.tsv$/ {
            if (NF < 2 || $2 == "") invalid()
            commands[$1]++
        }
        END {
            if (bad) exit 1
            if (!count) {
                print "No active manifest records."
                exit
            }
            print "Recorded state only; file contents and current installation health are not checked."
            printf "%-16s %-14s %-10s %-25s %7s %7s %8s\n", \
                "MODULE", "LAST_RESULT", "VERSION", "LAST_RUN", "FILES", "DIRS", "COMMANDS"
            for (idx = 1; idx <= count; idx++) {
                id = module[idx]
                printf "%-16s %-14s %-10s %-25s %7d %7d %8d\n", id, \
                    (id in result ? result[id] : "records-only"), \
                    (id in version ? version[id] : "-"), \
                    (id in timestamp ? timestamp[id] : "-"), \
                    files[id], dirs[id], commands[id]
            }
        }
    ' "${status_manifests[@]}"
}
