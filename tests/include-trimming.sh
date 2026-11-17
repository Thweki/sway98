#!/usr/bin/env bash
set -euo pipefail

# Check exact output and bound text-processing calls, without timing thresholds.
SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/sway98-include-trimming.XXXXXX)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT/home" TMPDIR="$TEST_ROOT/tmp"
SWAY98_LOG=""
SWAY98_DRY_RUN=0
SWAY98_MODULE="test"
SWAY98_ASSUME_YES=1
SWAY98_TS="include-trimming-test"
mkdir -p -- "$HOME" "$TMPDIR"

# shellcheck source=lib/common.sh
. "$SWAY98_ROOT/lib/common.sh"
# shellcheck source=lib/manifest.sh
. "$SWAY98_ROOT/lib/manifest.sh"
# shellcheck source=lib/edit.sh
. "$SWAY98_ROOT/lib/edit.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Count the text tools used by the editor and manifest helpers. These wrappers
# preserve their output/status; the assertion also catches the old tail/sed loop.
awk() { printf 'awk\n' >>"$TEST_ROOT/calls"; command awk "$@"; }
tail() { printf 'tail\n' >>"$TEST_ROOT/calls"; command tail "$@"; }
sed() { printf 'sed\n' >>"$TEST_ROOT/calls"; command sed "$@"; }

_sway98_test_trimming() (
    local scenario="$1" padding="$2" prefix="$3" file expected calls
    SWAY98_STATE="$TEST_ROOT/state-$scenario"
    SWAY98_BLOCK_PREFIX="$prefix"
    file="$HOME/$scenario"
    expected="$TEST_ROOT/expected"
    case "$scenario" in
        empty|blank-only) : >"$file" ;;
        unterminated) printf 'keep without newline' >"$file" ;;
        whitespace-tail) printf 'keep\n\n \t\n' >"$file" ;;
        *)
            printf '\nkeep first\n\n \t\nkeep last\n' >"$file"
            printf '%s >>> test >>>\nold include\n%s <<< test <<<\n' "$prefix" "$prefix" >>"$file"
            ;;
    esac
    if ((padding > 0)); then
        printf '%*s' "$padding" '' | tr ' ' '\n' >>"$file"
    fi
    cp -- "$file" "$TEST_ROOT/original"
    case "$scenario" in
        empty|blank-only) : >"$expected" ;;
        unterminated) printf 'keep without newline\n\n' >"$expected" ;;
        whitespace-tail) printf 'keep\n\n \t\n\n' >"$expected" ;;
        *) printf '\nkeep first\n\n \t\nkeep last\n\n' >"$expected" ;;
    esac
    printf '%s >>> test >>>\nnew include\n%s <<< test <<<\n' "$prefix" "$prefix" >>"$expected"

    manifest_init
    : >"$TEST_ROOT/calls"
    include_block "$file" test 'new include'
    calls="$(wc -l <"$TEST_ROOT/calls")"
    cmp -s -- "$expected" "$file" || fail "$scenario: rendered content differs"
    # Includes hashing and manifest lookup, with room for small fixed overhead.
    ((calls <= 8)) || fail "$scenario: $calls text-tool calls; expected at most 8"
    cp -- "$(manifest_files)" "$TEST_ROOT/first-manifest"
    include_block "$file" test 'new include'
    cmp -s -- "$expected" "$file" || fail "$scenario: reinstall changed content"
    cmp -s -- "$TEST_ROOT/first-manifest" "$(manifest_files)" || fail "$scenario: reinstall recorded a change"
    restore_all
    cmp -s -- "$TEST_ROOT/original" "$file" || fail "$scenario: rollback changed original bytes"
    [[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]] || fail "$scenario: temporary file leaked"
    printf 'ok: %s (%s text-tool calls)\n' "$scenario" "$calls"
)

_sway98_test_trimming empty 0 '#'
_sway98_test_trimming unterminated 0 '#'
_sway98_test_trimming unpadded 0 '#'
_sway98_test_trimming padded 256 '#'
_sway98_test_trimming blank-only 256 '#'
_sway98_test_trimming js-padded 256 '//'
_sway98_test_trimming whitespace-tail 256 '#'
