#!/usr/bin/env bash
set -euo pipefail

# Exercise the real edit/manifest path without applications or downloads.
SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT/home" TMPDIR="$TEST_ROOT/tmp"
export SWAY98_STATE="$TEST_ROOT/state" SWAY98_TS=ini-test
export SWAY98_MODULE=gtk SWAY98_DRY_RUN=0 SWAY98_ASSUME_YES=1 SWAY98_LOG=""
mkdir -p -- "$HOME" "$TMPDIR" "$TEST_ROOT/pristine"
# shellcheck source=lib/common.sh
. "$SWAY98_ROOT/lib/common.sh"
# shellcheck source=lib/manifest.sh
. "$SWAY98_ROOT/lib/manifest.sh"
# shellcheck source=lib/edit.sh
. "$SWAY98_ROOT/lib/edit.sh"
manifest_init

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

check_case() {
    local name="$1" original="$2" expected="$3" style="$4"
    local dest="$HOME/$name-$style.ini"
    if [[ "$style" == crlf ]]; then
        original="${original//$'\n'/$'\r\n'}"
        expected="${expected//$'\n'/$'\r\n'}"
    fi
    printf '%s' "$original" >"$dest"
    cp -- "$dest" "$TEST_ROOT/pristine/$(basename -- "$dest")"
    printf '%s' "$expected" >"$TEST_ROOT/expected"
    ini_set "$dest" Settings gtk-theme-name Chicago95
    cmp -s -- "$dest" "$TEST_ROOT/expected" || fail "$name ($style): unexpected content or line endings"
    cp -- "$(manifest_files)" "$TEST_ROOT/manifest-before"
    ini_set "$dest" Settings gtk-theme-name Chicago95
    cmp -s -- "$dest" "$TEST_ROOT/expected" || fail "$name ($style): second edit changed content"
    cmp -s -- "$(manifest_files)" "$TEST_ROOT/manifest-before" || fail "$name ($style): second edit added a manifest row"
}

for style in lf crlf; do
    check_case replace \
        $'# keep comment\n[Settings]\ngtk-theme-name=Adwaita\nkeep=yes\n[Other]\ngtk-theme-name=Other\n' \
        $'# keep comment\n[Settings]\ngtk-theme-name=Chicago95\nkeep=yes\n[Other]\ngtk-theme-name=Other\n' "$style"
    check_case insert-middle \
        $'[Settings]\nkeep=yes\n[Other]\nother=value\n' \
        $'[Settings]\nkeep=yes\ngtk-theme-name=Chicago95\n[Other]\nother=value\n' "$style"
    check_case insert-end \
        $'[Other]\nother=value\n[Settings]\nkeep=yes\n' \
        $'[Other]\nother=value\n[Settings]\nkeep=yes\ngtk-theme-name=Chicago95\n' "$style"
    check_case new-section \
        $'[Other]\nother=value\n' \
        $'[Other]\nother=value\n[Settings]\ngtk-theme-name=Chicago95\n' "$style"
done

cp -a -- "$HOME" "$TEST_ROOT/before-dry"
cp -a -- "$SWAY98_STATE" "$TEST_ROOT/state-before-dry"
SWAY98_DRY_RUN=1 ini_set "$HOME/replace-crlf.ini" Settings gtk-theme-name Preview
diff -r -- "$TEST_ROOT/before-dry" "$HOME" || fail 'dry run changed configuration'
diff -r -- "$TEST_ROOT/state-before-dry" "$SWAY98_STATE" || fail 'dry run changed state'

ini_set "$HOME/new.ini" Settings gtk-theme-name Chicago95
printf '[Settings]\ngtk-theme-name=Chicago95\n' >"$TEST_ROOT/expected"
cmp -s -- "$HOME/new.ini" "$TEST_ROOT/expected" || fail 'new files should use LF'
restore_all
diff -r -- "$TEST_ROOT/pristine" "$HOME" || fail 'rollback did not restore original bytes'
printf 'ok: INI LF/CRLF edits, idempotence, dry run, and rollback\n'
