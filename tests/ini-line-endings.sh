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
# Call the actual GTK/Qt modules against throwaway configs. No font or desktop
# interaction: GTK uses a fixed fixture font and bypasses gsettings.
for version in 3.0 4.0; do
    dir=".config/gtk-$version"
    mkdir -p -- "$HOME/$dir" "$TEST_ROOT/pristine/$dir"
    printf '[Settings]\r\ngtk-theme-name=Adwaita\r\n[Other]\r\ngtk-theme-name=Keep\r\n' >"$HOME/$dir/settings.ini"
    cp -- "$HOME/$dir/settings.ini" "$TEST_ROOT/pristine/$dir/settings.ini"
done
(
    # shellcheck source=modules/gtk/module.sh
    . "$SWAY98_ROOT/modules/gtk/module.sh"
    pick_font() { printf '%s\n' 'Liberation Sans'; }
    have() { return 1; }
    sway98_apply
)
for version in 3.0 4.0; do
    dest="$HOME/.config/gtk-$version/settings.ini"
    printf '[Settings]\r\ngtk-theme-name=Chicago95\r\ngtk-icon-theme-name=Chicago95\r\ngtk-cursor-theme-name=Chicago 95 Standard\r\ngtk-cursor-theme-size=24\r\ngtk-font-name=Liberation Sans 10\r\ngtk-application-prefer-dark-theme=false\r\n[Other]\r\ngtk-theme-name=Keep\r\n' >"$TEST_ROOT/expected"
    cmp -s -- "$dest" "$TEST_ROOT/expected" || fail "GTK $version CRLF caller"
done
export SWAY98_THEME_SRC="$TEST_ROOT/chicago95"
mkdir -p -- "$SWAY98_THEME_SRC/Extras"
printf '[ColorScheme]\nfixture=true\n' >"$SWAY98_THEME_SRC/Extras/Chicago95_qt.conf"
for version in 5 6; do
    dir=".config/qt${version}ct"
    mkdir -p -- "$HOME/$dir" "$TEST_ROOT/pristine/$dir"
    printf '[Appearance]\r\ncustom_palette=true\r\n[Other]\r\ncustom_palette=keep\r\n' >"$HOME/$dir/qt${version}ct.conf"
    cp -- "$HOME/$dir/qt${version}ct.conf" "$TEST_ROOT/pristine/$dir/qt${version}ct.conf"
done
(
    # shellcheck source=modules/qt/module.sh
    . "$SWAY98_ROOT/modules/qt/module.sh"
    sway98_apply
)
for version in 5 6; do
    dir="$HOME/.config/qt${version}ct"
    printf '[Appearance]\r\ncustom_palette=false\r\ncolor_scheme_path=%s\r\n[Other]\r\ncustom_palette=keep\r\n' "$dir/colors/sway98.conf" >"$TEST_ROOT/expected"
    cmp -s -- "$dir/qt${version}ct.conf" "$TEST_ROOT/expected" || fail "Qt $version CRLF caller"
done
printf 'ok: GTK3/4 and Qt5ct/6ct CRLF caller fixtures\n'

restore_all
diff -r -- "$TEST_ROOT/pristine" "$HOME" || fail 'rollback did not restore original bytes'
printf 'ok: INI LF/CRLF edits, idempotence, dry run, and rollback\n'
