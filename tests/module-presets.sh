#!/usr/bin/env bash
set -euo pipefail

# Presets must preserve discovery order and read each module's metadata once.
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/menu.sh
. "$REPO_ROOT/lib/menu.sh"

PRESET_TMP="$(mktemp -d)"
trap 'rm -rf -- "$PRESET_TMP"' EXIT
SWAY98_ROOT="$PRESET_TMP/repo with spaces"
SWAY98_TEST_SOURCES="$PRESET_TMP/sources"
SWAY98_SYSTEM=0
export LC_ALL=C

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

_sway98_seed_module() {
    local id="$1" scope="$2" recommended="$3" description="$4"
    mkdir -p -- "$SWAY98_ROOT/modules/$id"
    {
        printf 'SWAY98_MODULE_ID=%q\n' "$id"
        printf 'SWAY98_MODULE_SCOPE=%q\n' "$scope"
        printf 'SWAY98_MODULE_RECOMMENDED=%q\n' "$recommended"
        printf 'SWAY98_MODULE_DESC=%q\n' "$description"
        printf 'SWAY98_MODULE_REQUIRES=""\nSWAY98_MODULE_NEEDS_PKGS=""\n'
        # shellcheck disable=SC2016  # Expanded when the fixture is sourced.
        printf 'printf "%%s\\n" "$SWAY98_MODULE_ID" >>"$SWAY98_TEST_SOURCES"\n'
    } >"$SWAY98_ROOT/modules/$id/module.sh"
}

_sway98_check_preset() {
    local preset="$1" expected="$2" actual
    : >"$SWAY98_TEST_SOURCES"
    actual="$("$preset")" || fail "$preset exited nonzero"
    [[ "$actual" == "$expected" ]] || fail "$preset selected unexpected modules: $actual"
    sort "$SWAY98_TEST_SOURCES" >"$PRESET_TMP/sorted-sources"
    cmp -s "$PRESET_TMP/expected-sources" "$PRESET_TMP/sorted-sources" \
        || fail "$preset must source each discovered module exactly once (got $(wc -l <"$SWAY98_TEST_SOURCES") loads)"
}

_sway98_seed_module a_optional user no 'Optional user module'
_sway98_seed_module b_system system yes 'Recommended system module'
# Empty TSV fields must not shift the scope or recommendation columns.
_sway98_seed_module c_recommended user yes ''
_sway98_seed_module d_defaults '' '' ''
_sway98_seed_module e_system_optional system no 'Optional system module'
printf '%s\n' a_optional b_system c_recommended d_defaults e_system_optional \
    >"$PRESET_TMP/expected-sources"

_sway98_check_preset module_defaults $'a_optional\nc_recommended\nd_defaults'
_sway98_check_preset module_recommended c_recommended
SWAY98_SYSTEM=1
_sway98_check_preset module_defaults $'a_optional\nb_system\nc_recommended\nd_defaults\ne_system_optional'
_sway98_check_preset module_recommended $'b_system\nc_recommended'
printf 'ok: scope, recommendation, defaults, empty fields and one metadata load per module\n'

# A fresh selection must see changed metadata; there is no persistent cache.
_sway98_seed_module c_recommended user no ''
SWAY98_SYSTEM=0
_sway98_check_preset module_recommended ''
printf 'ok: fresh metadata and an empty recommended set\n'

SWAY98_ROOT="$PRESET_TMP/empty repo"
: >"$PRESET_TMP/expected-sources"
_sway98_check_preset module_defaults ''
_sway98_check_preset module_recommended ''
printf 'ok: no modules returns an empty successful selection\n'
