#!/usr/bin/env bash
#
# sway98 — uninstall / rollback entry point.
#
# Everything installed by install.sh is reversed from the manifest: recorded
# revert commands first, then files (restoring backups, deleting files we
# created), then directories that the install created and left empty.

set -euo pipefail

SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export SWAY98_ROOT

# shellcheck source=lib/common.sh
. "$SWAY98_ROOT/lib/common.sh"
# shellcheck source=lib/manifest.sh
. "$SWAY98_ROOT/lib/manifest.sh"
# shellcheck source=lib/hooks.sh
. "$SWAY98_ROOT/lib/hooks.sh"

ONLY=""

usage() {
    cat <<EOF
$SWAY98_NAME $SWAY98_VERSION — rollback

Usage: ./uninstall.sh [options]

  -n, --dry-run      show what would be reverted, change nothing
  -y, --yes          assume yes
      --only MODULE  revert a single module
      --list         show what the manifest currently holds
      --no-hooks     skip user post-uninstall hook
  -h, --help         this text
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            -n|--dry-run) export SWAY98_DRY_RUN=1; shift ;;
            -y|--yes)     export SWAY98_ASSUME_YES=1; shift ;;
            --only)       ONLY="${2:?--only needs an argument}"; shift 2 ;;
            --list)       list_manifest; exit 0 ;;
            --no-hooks)   SWAY98_NO_HOOKS=1; shift ;;
            -h|--help)    usage; exit 0 ;;
            *)            usage >&2; die "unknown option: $1" ;;
        esac
    done
}

list_manifest() {
    if [[ ! -s "$(manifest_files)" ]]; then
        info "no manifest found at $SWAY98_STATE/manifest — nothing was installed"
        return 0
    fi
    printf '%sInstalled modules%s\n' "$C_BOLD" "$C_RESET"
    awk -F'\t' '{ print "  " $1 "  " $2 "  " $4 }' "$(manifest_modules)" | tac | awk '!seen[$1]++'
    printf '\n%sFiles under management: %s%s\n' "$C_BOLD" "$(sort -u -t$'\t' -k3,3 "$(manifest_files)" | wc -l)" "$C_RESET"
    printf '%sRevert commands: %s%s\n' "$C_BOLD" "$(wc -l <"$(manifest_commands)")" "$C_RESET"
}

archive_manifest() {
    local hist="$SWAY98_STATE/manifest/history/$SWAY98_TS"
    is_dry_run && { dry "would archive manifest to $hist"; return 0; }
    mkdir -p -- "$hist"
    local f
    for f in "$(manifest_files)" "$(manifest_commands)" "$(manifest_dirs)" "$(manifest_modules)"; do
        [[ -s "$f" ]] && mv -- "$f" "$hist/$(basename -- "$f")"
        : >"$f"
    done
    info "manifest archived to $hist"
}

main() {
    parse_args "$@"

    if [[ ! -s "$(manifest_files)" && ! -s "$(manifest_commands)" ]]; then
        info "nothing to revert (no manifest at $SWAY98_STATE)"
        exit 0
    fi

    if [[ "$SWAY98_DRY_RUN" != "1" ]]; then
        mkdir -p -- "$SWAY98_STATE/log"
        export SWAY98_LOG="$SWAY98_STATE/log/uninstall-$SWAY98_TS.log"
    fi

    step "$SWAY98_NAME uninstall${ONLY:+ (module: $ONLY)}"
    if [[ -z "$ONLY" ]] && ! confirm "revert every change recorded in the manifest?" y; then
        info "aborted by user"
        exit 0
    fi

    restore_all "$ONLY"

    if [[ -z "$ONLY" ]]; then
        archive_manifest
    fi

    step "done"
    info "backups are kept in $SWAY98_STATE/backups/$SWAY98_TS"
    info "reload sway to see it: swaymsg reload"
    if [[ -n "$ONLY" ]]; then
        sway98_run_hook post-uninstall "$ONLY"
    else
        sway98_run_hook post-uninstall
    fi
}

main "$@"
