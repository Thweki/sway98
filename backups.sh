#!/usr/bin/env bash
set -euo pipefail

# Recover retained originals without replaying or changing an installation.
SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Listing and dry runs must not append to an inherited installer log.
SWAY98_LOG=""
# shellcheck source=lib/common.sh
. "$SWAY98_ROOT/lib/common.sh"

shopt -s nullglob dotglob

_sway98_backups_usage() {
    cat <<'EOF'
Usage: ./backups.sh [--list [SESSION]]
       ./backups.sh --restore SESSION --to NEW_DIRECTORY [--dry-run]

  --list [SESSION]  list retained sessions, or paths in one session (default)
  --restore SESSION
                   recover a session's originals into a new directory
  --to DIRECTORY   required for restore; must not exist, must be under $HOME,
                   outside sway98 state, with an existing parent directory
  -n, --dry-run    validate and preview recovery without writing anything
  -h, --help       show this help

SESSION is a directory name from --list, normally YYYYMMDD-HHMMSS.
Paths in listings use Bash shell quoting. No file contents are printed.
Recovery preserves the home/ and system/ layout, modes and symlinks; it does
not apply files to their original locations or run recorded commands.
Copies belong to you and survive uninstall. Backups and manifests stay intact.
An empty session means that run saved no originals, not a full system snapshot.
EOF
}

_sway98_backup_session_id() {
    [[ "$1" =~ ^[[:alnum:]][[:alnum:]._-]*$ ]]
}

# Walk with Bash globs so hidden entries and unusual names stay intact. Test
# symlinks first: directory links and dangling links must never be traversed.
_sway98_backup_inventory() {
    local directory="$1" prefix="$2" entry relative kind
    [[ -r "$directory" && -x "$directory" ]] || die "cannot read backup directory: $directory"
    for entry in "$directory"/*; do
        relative="$prefix${entry##*/}"
        if [[ -L "$entry" ]]; then
            kind=symlink
        elif [[ -d "$entry" ]]; then
            kind=directory
        elif [[ -f "$entry" ]]; then
            [[ -r "$entry" ]] || die "cannot read backup file: $entry"
            kind=file
        else
            die "unsupported backup entry: $entry"
        fi
        printf '%s\t%q\n' "$kind" "$relative"
        if [[ "$kind" == directory ]]; then
            _sway98_backup_inventory "$entry" "$relative/"
        fi
    done
}

_sway98_backups_main() {
    local mode="" session="" destination="" backup_root source entry
    local parent leaf home_root state_root
    local -a entries=()
    while (($#)); do
        case "$1" in
            --list)
                [[ -z "$mode" ]] || die "choose only one of --list and --restore"
                mode=list
                shift
                if (($#)) && [[ "$1" != -* ]]; then session="$1"; shift; fi
                ;;
            --restore)
                [[ -z "$mode" ]] || die "choose only one of --list and --restore"
                (($# >= 2)) && [[ -n "$2" && "$2" != -* ]] || die "--restore needs a session"
                mode=restore; session="$2"; shift 2
                ;;
            --to)
                [[ -z "$destination" ]] || die "--to may only be specified once"
                (($# >= 2)) && [[ -n "$2" && "$2" != -* ]] || die "--to needs a directory"
                destination="$2"; shift 2
                ;;
            -n|--dry-run) SWAY98_DRY_RUN=1; shift ;;
            -h|--help) _sway98_backups_usage; return 0 ;;
            *) die "unknown argument: $1" ;;
        esac
    done
    mode="${mode:-list}"
    if [[ "$mode" == restore ]]; then
        [[ -n "$destination" ]] || die "--restore requires --to NEW_DIRECTORY"
    else
        [[ -z "$destination" ]] || die "--to requires --restore"
    fi
    if [[ -n "$session" ]]; then
        _sway98_backup_session_id "$session" || die "invalid backup session: $session"
    fi

    backup_root="$SWAY98_STATE/backups"
    [[ ! -L "$backup_root" ]] || die "backup root must not be a symlink"
    if [[ -z "$session" ]]; then
        printf 'SESSION\n'
        if [[ -e "$backup_root" ]]; then
            [[ -d "$backup_root" && -r "$backup_root" && -x "$backup_root" ]] || die "cannot read backup root"
            for entry in "$backup_root"/*; do
                [[ -d "$entry" && ! -L "$entry" ]] || continue
                _sway98_backup_session_id "${entry##*/}" || continue
                printf '%s\n' "${entry##*/}"
            done
        fi
        return 0
    fi

    source="$backup_root/$session"
    [[ -d "$source" && ! -L "$source" ]] || die "backup session not found or is a symlink: $session"
    if [[ "$mode" == list ]]; then
        printf 'TYPE\tPATH\n'
        _sway98_backup_inventory "$source" ""
        return 0
    fi

    # Validate every source before creating the destination. No manifest is
    # needed: uninstall archives it but deliberately retains the backup tree.
    _sway98_backup_inventory "$source" "" >/dev/null
    leaf="$(basename -- "$destination")"
    [[ "$leaf" != . && "$leaf" != .. && "$leaf" != / ]] || die "invalid recovery destination"
    parent="$(realpath -e -- "$(dirname -- "$destination")")" || die "recovery parent must exist"
    [[ -d "$parent" ]] || die "recovery parent must be a directory"
    destination="$parent/$leaf"
    [[ ! -e "$destination" && ! -L "$destination" ]] || die "recovery destination already exists: $destination"
    home_root="$(realpath -e -- "$HOME")"
    state_root="$(realpath -e -- "$SWAY98_STATE")"
    [[ "$destination" == "$home_root"/* ]] || die "recovery destination must be under HOME"
    [[ "$destination" != "$state_root" && "$destination" != "$state_root"/* ]] || die "recovery destination must be outside sway98 state"
    if is_dry_run; then
        dry "recover backup $session into $destination (home/ and system/ layout)"
        return 0
    fi

    # mkdir without -p claims a fresh destination and refuses existing paths.
    # This is a user-owned recovery copy, intentionally outside the manifest.
    mkdir -m 700 -- "$destination"
    entries=("$source"/*)
    if ((${#entries[@]})); then
        if ! cp -a --no-preserve=ownership -- "${entries[@]}" "$destination/"; then
            die "recovery failed; partial copy kept at $destination; retry with a new destination"
        fi
    fi
    ok "recovered backup $session into $destination"
}

_sway98_backups_main "$@"
