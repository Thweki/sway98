#!/usr/bin/env bash
# Exercise rollback through the real uninstaller with fake desktop commands.
set -euo pipefail

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" != --isolated ]]; then
    exec env -i PATH=/usr/bin:/bin LC_ALL=C bash "$0" --isolated
fi

TEST_TMP="$(mktemp -d /tmp/sway98-rollback-quoting.XXXXXX)"
trap 'rm -rf -- "$TEST_TMP"' EXIT
export HOME="$TEST_TMP/home"
export SWAY98_ROOT="$TEST_ROOT" SWAY98_NO_GSETTINGS=0
export SWAY98_TEST_CALLS="$TEST_TMP/calls"
export SWAY98_TEST_SENTINEL="$TEST_TMP/injected"
mkdir -p -- "$HOME"

# Exported functions shadow host tools in both this process and uninstall.sh.
gsettings() {
    case "$1" in
        get) printf '%s\n' "$SWAY98_TEST_OLD" ;;
        set) printf '%s\0' "$@" >>"$SWAY98_TEST_CALLS" ;;
        *) return 1 ;;
    esac
}
flatpak() {
    if [[ "$*" == 'override --user --show' ]]; then
        return 0
    fi
    printf '%s\0' "$@" >>"$SWAY98_TEST_CALLS"
}
export -f gsettings flatpak

# shellcheck source=lib/common.sh
. "$TEST_ROOT/lib/common.sh"
# shellcheck source=lib/manifest.sh
. "$TEST_ROOT/lib/manifest.sh"
# shellcheck source=lib/edit.sh
. "$TEST_ROOT/lib/edit.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

test_index=0
prepare_case() {
    test_index=$((test_index + 1))
    export SWAY98_STATE="$TEST_TMP/state-$test_index"
    export SWAY98_MODULE="$1"
    manifest_init
    : >"$SWAY98_TEST_CALLS"
}

uninstall_case() {
    bash "$TEST_ROOT/uninstall.sh" --yes >"$TEST_TMP/uninstall.log" 2>&1 \
        || fail 'uninstall failed'
    [[ ! -e "$SWAY98_TEST_SENTINEL" ]] || fail 'rollback executed setting/path contents as shell code'
    cmp -s -- "$TEST_TMP/expected" "$SWAY98_TEST_CALLS" \
        || fail 'rollback did not preserve command argument boundaries and bytes'
}

# These are serialized GVariant values, not shell literals. An apostrophe can
# make GVariant use double quotes, which do not protect shell substitutions.
# shellcheck disable=SC2016  # Shell syntax is intentional literal test data.
old_values=(
    $'"Font\'s $(touch $SWAY98_TEST_SENTINEL) 10"'
    $'"Font\'s `touch $SWAY98_TEST_SENTINEL` 10"'
    "'Adwaita'"
    "'Font with spaces 10'"
    "'back\\\\slash'"
    "['one', 'two words']"
    $'[\'one\',\n\t\'two words\']'
    '@as []'
    'uint32 24'
    'true'
    "''"
)
for old_value in "${old_values[@]}"; do
    prepare_case gtk
    export SWAY98_TEST_OLD="$old_value"
    gsettings_set_if_changed org.gnome.desktop.interface gtk-theme Chicago95 \
        >"$TEST_TMP/install.log" 2>&1
    printf '%s\0' set org.gnome.desktop.interface gtk-theme Chicago95 \
        set org.gnome.desktop.interface gtk-theme "$old_value" >"$TEST_TMP/expected"
    [[ "$(wc -l <"$(manifest_commands)")" == 1 ]] || fail 'expected one rollback record'
    uninstall_case
done
printf 'ok   GSettings rollback preserves values without evaluating them\n'

# Flatpak rollback also interpolated unquoted user data: HOME is a valid path
# even when it contains shell syntax. No actual Flatpak service is contacted.
export HOME="$TEST_TMP/space home \$(touch \$SWAY98_TEST_SENTINEL)"
mkdir -p -- "$HOME"
prepare_case flatpak
# shellcheck source=modules/flatpak/module.sh
. "$TEST_ROOT/modules/flatpak/module.sh"
sway98_apply >"$TEST_TMP/install.log" 2>&1
printf '%s\0' override --user "--filesystem=$HOME/.themes:ro" \
    override --user "--filesystem=$HOME/.icons:ro" \
    override --user "--nofilesystem=$HOME/.icons" \
    override --user "--nofilesystem=$HOME/.themes" >"$TEST_TMP/expected"
uninstall_case
printf 'ok   Flatpak rollback preserves paths and reverse command order\n'

prepare_case gtk
export SWAY98_TEST_OLD="'Adwaita'" SWAY98_DRY_RUN=1
gsettings_set_if_changed org.gnome.desktop.interface gtk-theme Chicago95 \
    >"$TEST_TMP/install.log" 2>&1
sway98_apply >>"$TEST_TMP/install.log" 2>&1
record_cmd_argv gsettings set schema key "$SWAY98_TEST_OLD" >>"$TEST_TMP/install.log" 2>&1
[[ ! -s "$SWAY98_TEST_CALLS" && ! -s "$(manifest_commands)" ]] \
    || fail 'dry run wrote settings or rollback commands'
printf 'ok   dry run neither changes settings nor records rollback\n'
