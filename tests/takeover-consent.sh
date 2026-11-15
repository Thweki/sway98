#!/usr/bin/env bash
# Isolated takeover decisions: no desktop commands or network downloads.
set -euo pipefail

SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export XDG_CACHE_HOME="$TEST_TMP/cache"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export SWAY98_STATE="$XDG_STATE_HOME/sway98"
export SWAY98_NO_GSETTINGS=1
export SWAY98_LOG=""
# shellcheck source=install.sh
. "$SWAY98_ROOT/install.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "missing '$2' in $1"; }
assert_unrecorded() {
    if awk -F '\t' -v path="$1" '$3 == path { found=1 } END { exit !found }' "$(manifest_files)"; then
        fail "skipped or unchanged destination was recorded: $1"
    fi
}

setup_case() {
    TEST_CASE="$TEST_TMP/$1"
    export HOME="$TEST_CASE/home" XDG_STATE_HOME="$TEST_CASE/state"
    export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
    export XDG_CACHE_HOME="$TEST_CASE/cache" SWAY98_STATE="$XDG_STATE_HOME/sway98"
    SWAY98_DRY_RUN=0 SWAY98_ASSUME_YES=0 SWAY98_TAKEOVER=0 SWAY98_LOG=""
    SWAY98_MODULE=test SWAY98_TS=test
    SWAY98_SKIPPED_DESTINATIONS=()
    CONFIRM_CALLS=()
    mkdir -p -- "$HOME"
    printf 'replacement\n' >"$TEST_CASE/source"
    manifest_init
}

# Simulate a terminal reply at the prompt boundary, checking that routine --yes
# has been disabled. The real non-terminal refusal is exercised separately.
mock_takeover_reply() {
    confirm() {
        [[ "$SWAY98_ASSUME_YES" == 0 ]] || fail "--yes approved a takeover"
        CONFIRM_CALLS+=("$1")
        [[ "$TEST_REPLY" == yes ]]
    }
}

explicit_consent() {
    printf 'original\n' >"$HOME/config"
    SWAY98_ASSUME_YES=1
    TEST_REPLY=yes
    mock_takeover_reply
    install_file "$TEST_CASE/source" "$HOME/config"
    ((${#CONFIRM_CALLS[@]} == 1)) || fail "replacement did not ask for a separate decision"
    cmp -s "$TEST_CASE/source" "$HOME/config" || fail "approved replacement not installed"
    assert_contains "$(manifest_files)" $'test\tmodify\t'
    assert_contains "$SWAY98_STATE/backups/test/home/config" original

    # Once owned, a different replacement must preserve the original backup.
    confirm() { fail "owned destination asked for takeover again"; }
    printf 'updated\n' >"$TEST_CASE/source"
    install_file "$TEST_CASE/source" "$HOME/config"
    restore_all
    [[ "$(cat "$HOME/config")" == original ]] || fail "original backup was lost"
}

declined_takeover() {
    printf 'original\n' >"$HOME/config"
    TEST_REPLY=no
    mock_takeover_reply
    install_file "$TEST_CASE/source" "$HOME/config"
    ((${#CONFIRM_CALLS[@]} == 1)) || fail "takeover decision was not requested"
    [[ "$(cat "$HOME/config")" == original ]] || fail "declined destination was overwritten"
    [[ "${SWAY98_SKIPPED_DESTINATIONS[*]}" == "$HOME/config" ]] || fail "decline was not tracked"
    assert_unrecorded "$HOME/config"
    [[ ! -e "$SWAY98_STATE/backups/test/home" ]] || fail "decline made a backup"
}

merge_and_overwrite() {
    confirm() { fail "merge requested overwrite consent"; }
    printf '[Settings]\ntheme=old\ncustom=keep\n' >"$HOME/settings.ini"
    printf 'user setting\n' >"$HOME/includes"
    ini_set "$HOME/settings.ini" Settings theme new
    include_block "$HOME/includes" sway98 'include palette'
    assert_contains "$HOME/settings.ini" theme=new
    assert_contains "$HOME/settings.ini" custom=keep
    assert_contains "$HOME/includes" 'user setting'
    assert_contains "$HOME/includes" 'include palette'

    # The module's flat key editor is a merge too.
    # shellcheck source=modules/fcitx5/module.sh
    . "$SWAY98_ROOT/modules/fcitx5/module.sh"
    mkdir -p -- "$HOME/.config/fcitx5/conf"
    printf 'Theme=old\nCustom=keep\n' >"$HOME/.config/fcitx5/conf/classicui.conf"
    _fcitx5_set_key Theme win98
    assert_contains "$HOME/.config/fcitx5/conf/classicui.conf" Custom=keep
    assert_contains "$HOME/.config/fcitx5/conf/classicui.conf" Theme=win98

    # A rendered template replaces content, so it must take the consent path.
    printf 'original\n' >"$HOME/template"
    TEST_REPLY=no
    mock_takeover_reply
    template_render "$TEST_CASE/source" "$HOME/template"
    [[ "$(cat "$HOME/template")" == original ]] || fail "template bypassed takeover"
    assert_unrecorded "$HOME/template"

    # Recording a merge must not silently authorize later whole-file replacement.
    install_file "$TEST_CASE/source" "$HOME/settings.ini"
    assert_contains "$HOME/settings.ini" custom=keep
    TEST_REPLY=yes
    install_file "$TEST_CASE/source" "$HOME/settings.ini"
    cmp -s "$TEST_CASE/source" "$HOME/settings.ini" || fail "approved takeover after merge failed"
    restore_all
    assert_contains "$HOME/settings.ini" theme=old
    assert_contains "$HOME/settings.ini" custom=keep
}

tree_conflicts() {
    mkdir -p -- "$TEST_CASE/tree" "$HOME/tree"
    printf 'replacement\n' >"$TEST_CASE/tree/conflict"
    printf 'new\n' >"$TEST_CASE/tree/new"
    ln -s new "$TEST_CASE/tree/link"
    ln -s new "$TEST_CASE/tree/dangling"
    printf 'original\n' >"$HOME/tree/conflict"
    printf 'user link contents\n' >"$HOME/tree/link"
    ln -s missing "$HOME/tree/dangling"
    TEST_REPLY=no
    mock_takeover_reply
    install_dir "$TEST_CASE/tree" "$HOME/tree"
    [[ "$(cat "$HOME/tree/conflict")" == original ]] || fail "tree file overwritten"
    [[ ! -L "$HOME/tree/link" ]] || fail "tree file replaced by link"
    [[ "$(readlink "$HOME/tree/dangling")" == missing ]] || fail "dangling link overwritten"
    [[ -f "$HOME/tree/new" ]] || fail "non-conflicting tree file was skipped"
    ((${#SWAY98_SKIPPED_DESTINATIONS[@]} == 3)) || fail "tree skips were not counted"
    assert_unrecorded "$HOME/tree/conflict"
    assert_unrecorded "$HOME/tree/link"
    assert_unrecorded "$HOME/tree/dangling"
}

unchanged_unowned() {
    confirm() { fail "unchanged destination asked for takeover"; }
    cp -- "$TEST_CASE/source" "$HOME/config"
    install_file "$TEST_CASE/source" "$HOME/config"
    assert_unrecorded "$HOME/config"
    ((${#SWAY98_SKIPPED_DESTINATIONS[@]} == 0)) || fail "unchanged file reported skipped"
}

dry_run() {
    printf 'original\n' >"$HOME/config"
    cp -a -- "$TEST_CASE" "$TEST_TMP/before-dry-run"
    SWAY98_DRY_RUN=1
    confirm() { fail "dry run prompted for consent"; }
    install_file "$TEST_CASE/source" "$HOME/config" >"$TEST_TMP/dry.log" 2>&1
    assert_contains "$TEST_TMP/dry.log" 'would require explicit takeover consent'
    diff -r -- "$TEST_TMP/before-dry-run" "$TEST_CASE" || fail "dry run changed files or state"
    ((${#SWAY98_SKIPPED_DESTINATIONS[@]} == 0)) || fail "planned takeover reported declined"
}

installer_summary() {
    # Exercise argument parsing and real modules while bypassing platform checks.
    preflight() { :; }
    mkdir -p -- "$HOME/.config/wofi" "$HOME/.config/kitty"
    printf 'user style\n' >"$HOME/.config/wofi/style.css"
    printf 'user palette\n' >"$HOME/.config/kitty/sway98-vga.conf"
    printf 'font_size 13\n' >"$HOME/.config/kitty/kitty.conf"
    main --yes --modules wofi,kitty,swaylock </dev/null >"$TEST_TMP/skipped.log" 2>&1
    assert_contains "$TEST_TMP/skipped.log" 'incomplete (unowned destinations skipped): wofi kitty'
    assert_contains "$TEST_TMP/skipped.log" 'installed: swaylock'
    assert_contains "$TEST_TMP/skipped.log" "skipped unowned destination (takeover not approved): $HOME/.config/wofi/style.css"
    assert_contains "$(manifest_modules)" $'wofi\tincomplete\t'
    assert_contains "$(manifest_modules)" $'kitty\tincomplete\t'
    assert_unrecorded "$HOME/.config/wofi/style.css"
    [[ "$(cat "$HOME/.config/wofi/style.css")" == 'user style' ]] || fail "--yes silently took over"
    assert_contains "$HOME/.config/kitty/kitty.conf" 'font_size 13'
    assert_contains "$HOME/.config/kitty/kitty.conf" '# >>> sway98 >>>'

    main --yes --takeover --only wofi </dev/null >"$TEST_TMP/approved.log" 2>&1
    assert_contains "$TEST_TMP/approved.log" 'installed: wofi'
    if grep -q 'incomplete' "$TEST_TMP/approved.log"; then
        fail "approved takeover reported incomplete"
    fi
    cmp -s "$SWAY98_ROOT/modules/wofi/files/style.css" "$HOME/.config/wofi/style.css" || fail "--takeover not applied"
    assert_contains "$SWAY98_STATE/backups/test/home/.config/wofi/style.css" 'user style'
}

for test_case in explicit_consent declined_takeover merge_and_overwrite tree_conflicts unchanged_unowned dry_run installer_summary; do
    (
        setup_case "$test_case"
        "$test_case"
    )
    printf 'ok   %s\n' "$test_case"
done
