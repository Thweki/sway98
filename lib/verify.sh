#!/usr/bin/env bash
set -euo pipefail

# Read-only verification of the latest installed state, not rollback originals.
# Use printf instead of logging helpers: even an inherited log must stay intact.
sway98_verify_files() {
    local manifest="$1" records module path expected actual status
    local matched=0 problems=0 unverified=0

    if [[ ! -e "$manifest" && ! -L "$manifest" ]]; then
        printf '%s\n' 'No managed file records; nothing to verify.'
        return 0
    fi
    if [[ ! -f "$manifest" || ! -r "$manifest" ]]; then
        printf '%s\n' 'Cannot read the file manifest.' >&2
        return 1
    fi

    # Validate before inspecting paths. Preserve empty TSV fields, and use the
    # last hash for shared paths or repeated installs, in first-seen path order.
    if ! records="$(awk -F '\t' '
        NF != 6 || $1 == "" || ($2 != "create" && $2 != "modify") ||
        substr($3, 1, 1) != "/" ||
        ($4 != "" && (length($4) != 64 || $4 ~ /[^0-9a-f]/)) {
            invalid = 1; next
        }
        {
            if (!($3 in latest)) paths[++count] = $3
            latest[$3] = $1 "\t" $3 "\t" $4
        }
        END {
            if (invalid) exit 1
            for (entry = 1; entry <= count; entry++) print latest[paths[entry]]
        }
    ' "$manifest")"; then
        printf '%s\n' 'Invalid or unreadable file manifest; verification aborted.' >&2
        return 1
    fi
    if [[ -z "$records" ]]; then
        printf '%s\n' 'No managed file records; nothing to verify.'
        return 0
    fi

    printf '%s\n' 'STATUS  MODULE  PATH'
    while IFS=$'\t' read -r module path expected; do
        if [[ ! -e "$path" && ! -L "$path" ]]; then
            status=MISSING
        elif [[ -z "$expected" ]]; then
            if [[ -L "$path" ]]; then
                status=UNVERIFIED
            else
                status=TYPE-CHANGED
            fi
        elif [[ -L "$path" || ! -f "$path" ]]; then
            status=TYPE-CHANGED
        elif ! actual="$(sha256sum <"$path" 2>/dev/null)"; then
            status=ERROR
        elif [[ "${actual%% *}" != "$expected" ]]; then
            status=CHANGED
        else
            status=OK
        fi
        case "$status" in
            OK) matched=$((matched + 1)) ;;
            UNVERIFIED) unverified=$((unverified + 1)) ;;
            *) problems=$((problems + 1)) ;;
        esac
        printf '%s  %s  %s\n' "$status" "$module" "$path"
    done <<<"$records"
    printf 'Verification: %d matched, %d problem(s), %d unverified symlink(s).\n' \
        "$matched" "$problems" "$unverified"
    printf '%s\n' 'Symlink targets, permissions, backups and desktop settings are not verified.'
    ((problems == 0))
}
