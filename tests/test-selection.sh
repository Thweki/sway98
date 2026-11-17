#!/usr/bin/env bash
# Numeric selections must never wrap around or silently select another module.
set -euo pipefail

SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/menu.sh
. "$SWAY98_ROOT/lib/menu.sh"

die() { printf '%s\n' "$*" >&2; exit 1; }

# Keep index expectations independent of the installed module inventory.
module_defaults() {
    printf '%s\n' theme gtk sway waybar kitty mako qt fonts firefox wofi
}

TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT

_sway98_expect_invalid() {
    local selection="$1"
    if ( _expand_selection "$selection" ) >"$TEST_TMP/selection" 2>"$TEST_TMP/error"; then
        die "FAIL: invalid selection '$selection' succeeded"
    fi
    [[ -s "$TEST_TMP/error" ]] || die "FAIL: invalid selection '$selection' had no diagnostic"
}

_sway98_expect_selection() {
    local selection="$1" expected="$2" actual
    actual="$(_expand_selection "$selection")"
    [[ "$actual" == "$expected" ]] || die "FAIL: incorrect expansion of '$selection'"
}

for selection in 0 00 11 0-1 1-11 3-2 theme,0 1,11 \
    18446744073709551617 1-18446744073709551617; do
    _sway98_expect_invalid "$selection"
done
printf 'ok   invalid indices and ranges are rejected\n'

_sway98_expect_selection 1 theme
_sway98_expect_selection 10 wofi
_sway98_expect_selection 8-10 $'fonts\nfirefox\nwofi'
_sway98_expect_selection 2-2 gtk
_sway98_expect_selection 01,08-010 $'theme\nfonts\nfirefox\nwofi'
_sway98_expect_selection 00000000000000000000000000000001 theme
_sway98_expect_selection 'theme,3-4,10' $'theme\nsway\nwaybar\nwofi'
_sway98_expect_selection '1 3,5' $'theme\nsway\nkitty'
_sway98_expect_selection '' ''
printf 'ok   valid numeric, decimal, named and mixed selections retain their order\n'

# Exercise both callers in the real entry point, with no host configuration,
# desktop session, cached assets, or network-dependent modules involved.
mkdir -p -- "$TEST_TMP/home" "$TEST_TMP/tmp"
_sway98_install() {
    env -i PATH="$PATH" HOME="$TEST_TMP/home" TMPDIR="$TEST_TMP/tmp" \
        XDG_CONFIG_HOME="$TEST_TMP/home/.config" \
        XDG_STATE_HOME="$TEST_TMP/state" XDG_CACHE_HOME="$TEST_TMP/cache" \
        XDG_DATA_HOME="$TEST_TMP/home/.local/share" SWAY98_NO_GSETTINGS=1 \
        bash "$SWAY98_ROOT/install.sh" --dry-run "$@"
}

if (( EUID == 0 )); then
    printf 'SKIP entry-point checks: installer refuses root\n'
else
    for mode in cli menu; do
        if [[ "$mode" == cli ]]; then
            if _sway98_install --modules 0 >"$TEST_TMP/$mode.log" 2>&1; then
                die 'FAIL: CLI accepted module zero'
            fi
        elif _sway98_install <<<0 >"$TEST_TMP/$mode.log" 2>&1; then
            die 'FAIL: interactive menu accepted module zero'
        fi
        grep -q 'module number out of range' "$TEST_TMP/$mode.log" \
            || die "FAIL: $mode did not report the invalid index"
        if grep -q '==> module:' "$TEST_TMP/$mode.log"; then
            die "FAIL: $mode applied a module after an invalid selection"
        fi
    done
    _sway98_install --modules wofi >"$TEST_TMP/valid.log" 2>&1
    grep -q '==> module: wofi' "$TEST_TMP/valid.log" \
        || die 'FAIL: valid CLI selection did not reach the module'
    [[ ! -e "$TEST_TMP/state" ]] || die 'FAIL: dry-run wrote state'
    printf 'ok   CLI and menu reject zero before applying any module\n'
fi
