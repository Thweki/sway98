#!/usr/bin/env bash
# Failure injection stays in a throwaway HOME; no desktop or network is used.
set -euo pipefail

SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=install.sh
. "$SWAY98_ROOT/install.sh"

# A fresh Bash keeps the module runner out of the test harness's conditional
# context. Helper probes deliberately use a conditional to test explicit returns.
if [[ "${1:-}" == --probe ]]; then
    # shellcheck disable=SC1091
    . "$SWAY98_TEST_ROOT/inject.sh"
    module_file() { printf '%s/%s.sh\n' "$SWAY98_TEST_ROOT" "$1"; }
    if [[ "$2" == module ]]; then
        apply_selection 'broken healthy'
    else
        if sway98_test_operation; then
            printf 'helper swallowed failure\n' >&2
            exit 1
        fi
    fi
    exit 0
fi

SWAY98_TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$SWAY98_TEST_TMP"' EXIT
export LC_ALL=C SWAY98_NO_GSETTINGS=1 SWAY98_ASSUME_YES=1
export SWAY98_DRY_RUN=0 SWAY98_LOG="" SWAY98_MODULE=broken

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

for scenario in backup-mkdir backup-copy backup-link manifest-read parent-mkdir \
    parent-manifest file-mode file-write file-hash file-manifest link-write \
    link-manifest tree-copy tree-dir-manifest tree-hash tree-file-manifest \
    existing-tree-write existing-tree-link edit-write edit-render command-manifest \
    module-manifest raw-command; do
    export SWAY98_TEST_ROOT="$SWAY98_TEST_TMP/$scenario"
    export HOME="$SWAY98_TEST_ROOT/home"
    export SWAY98_STATE="$SWAY98_TEST_ROOT/state"
    export TMPDIR="$SWAY98_TEST_ROOT/tmp"
    mkdir -p -- "$HOME" "$TMPDIR" "$SWAY98_TEST_ROOT/src/nested"
    manifest_init
    printf 'original\n' >"$HOME/dest"
    printf 'replacement\n' >"$SWAY98_TEST_ROOT/src/file"
    printf 'nested\n' >"$SWAY98_TEST_ROOT/src/nested/file"
    ln -s file "$SWAY98_TEST_ROOT/src/link"
    cat >"$SWAY98_TEST_ROOT/inject.sh" <<'INJECT'
sway98_test_fail() { printf 'injected failure\n' >&2; return 73; }
sway98_test_operation() { install_file "$SWAY98_TEST_ROOT/src/file" "$HOME/dest"; }
INJECT
    case "$scenario" in
        backup-mkdir)
            echo 'mkdir() { sway98_test_fail; }' >>"$SWAY98_TEST_ROOT/inject.sh" ;;
        backup-copy|backup-link)
            echo 'cp() { sway98_test_fail; }' >>"$SWAY98_TEST_ROOT/inject.sh"
            if [[ "$scenario" == backup-link ]]; then
                echo 'sway98_test_operation() { install_symlink "$SWAY98_TEST_ROOT/src/link" "$HOME/dest"; }' >>"$SWAY98_TEST_ROOT/inject.sh"
            fi ;;
        manifest-read)
            printf 'seed\n' >"$(manifest_files)"
            echo 'awk() { sway98_test_fail; }' >>"$SWAY98_TEST_ROOT/inject.sh" ;;
        parent-mkdir|parent-manifest)
            echo 'sway98_test_operation() { install_file "$SWAY98_TEST_ROOT/src/file" "$HOME/new/dest"; }' >>"$SWAY98_TEST_ROOT/inject.sh"
            if [[ "$scenario" == parent-mkdir ]]; then
                echo 'mkdir() { sway98_test_fail; }' >>"$SWAY98_TEST_ROOT/inject.sh"
            else
                rm -- "$(manifest_dirs)"
                mkdir -- "$(manifest_dirs)"
            fi ;;
        file-mode) echo 'stat() { sway98_test_fail; }' >>"$SWAY98_TEST_ROOT/inject.sh" ;;
        file-write|existing-tree-write|edit-write)
            echo 'install() { sway98_test_fail; }' >>"$SWAY98_TEST_ROOT/inject.sh" ;;
        file-hash)
            cat >>"$SWAY98_TEST_ROOT/inject.sh" <<'INJECT'
sha256sum() {
    if [[ -e "$SWAY98_STATE/backups/$SWAY98_TS/home/dest" ]]; then
        sway98_test_fail
    else
        command sha256sum "$@"
    fi
}
INJECT
            ;;
        file-manifest|link-manifest|tree-file-manifest)
            rm -- "$(manifest_files)"
            mkdir -- "$(manifest_files)" ;;
        link-write|existing-tree-link)
            echo 'ln() { sway98_test_fail; }' >>"$SWAY98_TEST_ROOT/inject.sh" ;;
        tree-copy) echo 'cp() { sway98_test_fail; }' >>"$SWAY98_TEST_ROOT/inject.sh" ;;
        tree-dir-manifest)
            rm -- "$(manifest_dirs)"
            mkdir -- "$(manifest_dirs)" ;;
        tree-hash) echo 'xargs() { sway98_test_fail; }' >>"$SWAY98_TEST_ROOT/inject.sh" ;;
        edit-render) echo 'awk() { sway98_test_fail; }' >>"$SWAY98_TEST_ROOT/inject.sh" ;;
        command-manifest)
            rm -- "$(manifest_commands)"
            mkdir -- "$(manifest_commands)"
            echo 'sway98_test_operation() { record_cmd true; }' >>"$SWAY98_TEST_ROOT/inject.sh" ;;
        module-manifest)
            rm -- "$(manifest_modules)"
            mkdir -- "$(manifest_modules)"
            echo 'sway98_test_operation() { :; }' >>"$SWAY98_TEST_ROOT/inject.sh" ;;
        raw-command) echo 'sway98_test_operation() { false; }' >>"$SWAY98_TEST_ROOT/inject.sh" ;;
    esac
    case "$scenario" in
        link-*) echo 'sway98_test_operation() { install_symlink "$SWAY98_TEST_ROOT/src/link" "$HOME/dest"; }' >>"$SWAY98_TEST_ROOT/inject.sh" ;;
        tree-*) echo 'sway98_test_operation() { install_dir "$SWAY98_TEST_ROOT/src" "$HOME/tree"; }' >>"$SWAY98_TEST_ROOT/inject.sh" ;;
        existing-tree-*)
            mkdir -- "$HOME/tree"
            if [[ "$scenario" == existing-tree-link ]]; then
                cp -- "$SWAY98_TEST_ROOT/src/file" "$HOME/tree/file"
                mkdir -- "$HOME/tree/nested"
                cp -- "$SWAY98_TEST_ROOT/src/nested/file" "$HOME/tree/nested/file"
            fi
            echo 'sway98_test_operation() { install_dir "$SWAY98_TEST_ROOT/src" "$HOME/tree"; }' >>"$SWAY98_TEST_ROOT/inject.sh" ;;
        edit-*) echo 'sway98_test_operation() { ini_set "$HOME/dest" Settings theme Chicago95; }' >>"$SWAY98_TEST_ROOT/inject.sh" ;;
    esac
    cat >"$SWAY98_TEST_ROOT/broken.sh" <<'MODULE'
sway98_apply() {
    sway98_test_operation
    info 'must not reach module tail'
}
MODULE
    if [[ "$scenario" == module-manifest ]]; then
        echo 'sway98_apply() { sway98_test_operation; }' >"$SWAY98_TEST_ROOT/broken.sh"
    fi
    echo 'sway98_apply() { info "healthy module ran"; }' >"$SWAY98_TEST_ROOT/healthy.sh"

    # Run modules first so helper probes cannot pre-install the fixture files.
    log="$SWAY98_TEST_ROOT/module.log"
    if bash "$SWAY98_ROOT/tests/run-errors.sh" --probe module >"$log" 2>&1; then
        cat "$log" >&2
        fail "$scenario: installer reported success"
    fi
    grep -q 'failed: .*broken' "$log" || fail "$scenario: missing failure summary"
    grep -q 'healthy module ran' "$log" || fail "$scenario: subsequent module did not run"
    if grep -q 'must not reach module tail\|installed: .*broken\|info created:\|info modified:\|info modify:' "$log"; then
        cat "$log" >&2
        fail "$scenario: success logged after a failed transaction"
    fi
    if [[ -f "$(manifest_modules)" ]] && grep -q $'^broken\tinstalled\t' "$(manifest_modules)"; then
        fail "$scenario: failed module marked installed"
    fi
    if [[ "$scenario" != module-manifest ]]; then
        grep -q $'^healthy\tinstalled\t' "$(manifest_modules)" || fail "$scenario: healthy module not recorded"
    fi
    case "$scenario" in
        backup-*|manifest-read|parent-*|file-mode|file-write|link-write|edit-*)
            [[ "$(cat "$HOME/dest")" == original ]] || fail "$scenario: destination overwritten"
            [[ ! -e "$HOME/new/dest" ]] || fail "$scenario: write continued after parent failure" ;;
    esac
    case "$scenario" in
        backup-*|parent-*|file-mode|file-write|link-write|tree-copy|tree-hash|edit-*)
            [[ ! -s "$(manifest_files)" ]] || fail "$scenario: file recorded after failure" ;;
    esac

    if [[ "$scenario" != module-manifest ]]; then
        # Reset writes from failed post-write checks so probes hit the boundary
        # again instead of returning early through the unchanged-file fast path.
        rm -f -- "$HOME/dest"
        printf 'original\n' >"$HOME/dest"
        rm -rf -- "$HOME/tree" "$HOME/new" "$SWAY98_STATE/backups/$SWAY98_TS"
        mkdir -p -- "$SWAY98_STATE/backups/$SWAY98_TS"
        if [[ "$scenario" == existing-tree-* ]]; then
            mkdir -- "$HOME/tree"
        fi
        log="$SWAY98_TEST_ROOT/helper.log"
        if ! bash "$SWAY98_ROOT/tests/run-errors.sh" --probe helper >"$log" 2>&1; then
            cat "$log" >&2
            fail "$scenario: helper did not propagate its error in a conditional"
        fi
    fi
    printf 'ok   %s\n' "$scenario"
done
