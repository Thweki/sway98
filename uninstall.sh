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

ONLY=""

usage() {
    cat <<EOF
$SWAY98_NAME $SWAY98_VERSION — rollback

Usage: ./uninstall.sh [options]

  -n, --dry-run      show what would be reverted, change nothing
  -y, --yes          assume yes
      --only MODULE  revert a single module
      --list         show what the manifest currently holds
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
            -h|--help)    usage; exit 0 ;;
            *)            usage >&2; die "unknown option: $1" ;;
        esac
    done
}

list_manifest() {
    if ! manifest_has_records; then
        info "no manifest found at $SWAY98_STATE/manifest — nothing was installed"
        return 0
    fi
    printf '%sInstalled modules%s\n' "$C_BOLD" "$C_RESET"
    awk -F'\t' '{ print "  " $1 "  " $2 "  " $4 }' "$(manifest_modules)" | tac | awk '!seen[$1]++'
    printf '\n%sFiles under management: %s%s\n' "$C_BOLD" "$(sort -u -t$'\t' -k3,3 "$(manifest_files)" | wc -l)" "$C_RESET"
    printf '%sRevert commands: %s%s\n' "$C_BOLD" "$(wc -l <"$(manifest_commands)")" "$C_RESET"
}

main() {
    parse_args "$@"

    if ! manifest_has_records "$ONLY"; then
        info "nothing to revert${ONLY:+ for module $ONLY} (no active records at $SWAY98_STATE)"
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

    step "done"
    info "backups are kept in $SWAY98_STATE/backups/$SWAY98_TS"
    info "reload sway to see it: swaymsg reload"
}

main "$@"
