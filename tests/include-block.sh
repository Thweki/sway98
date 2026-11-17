#!/usr/bin/env bash
set -euo pipefail

# Exercise only local config edits; never invoke desktop tools or fetch assets.
SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/sway98-include-block.XXXXXX)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT/home" TMPDIR="$TEST_ROOT/tmp"
SWAY98_STATE="$TEST_ROOT/state"
SWAY98_TS="include-block-test"
SWAY98_LOG=""
SWAY98_DRY_RUN=0
SWAY98_MODULE="test"
SWAY98_ASSUME_YES=1
mkdir -p -- "$HOME" "$TMPDIR"

# shellcheck source=lib/common.sh
. "$SWAY98_ROOT/lib/common.sh"
# shellcheck source=lib/manifest.sh
. "$SWAY98_ROOT/lib/manifest.sh"
# shellcheck source=lib/edit.sh
. "$SWAY98_ROOT/lib/edit.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

manifest_init
cp -a -- "$SWAY98_STATE" "$TEST_ROOT/pristine-state"

_sway98_test_reject() {
    local scenario="$1" file="$HOME/config" begin end
    begin="$SWAY98_BLOCK_PREFIX >>> sway98 >>>"
    end="$SWAY98_BLOCK_PREFIX <<< sway98 <<<"
    case "$scenario" in
        missing-end) printf 'before\n%s\nkeep this tail\n' "$begin" ;;
        orphan-end) printf 'before\n%s\nkeep this tail\n' "$end" ;;
        nested) printf 'before\n%s\n%s\n%s\n%s\nafter\n' "$begin" "$begin" "$end" "$end" ;;
        reversed) printf 'before\n%s\n%s\nkeep this tail\n' "$end" "$begin" ;;
    esac >"$file"
    cp -a -- "$file" "$TEST_ROOT/original"

    # Match the installer's conditional subshell: a later successful command
    # must not hide a rejected edit when Bash disables errexit in this context.
    if (include_block "$file" sway98 'new include'; touch "$TEST_ROOT/continued") \
            >"$TEST_ROOT/reject.log" 2>&1; then
        fail "$scenario accepted (prefix=$SWAY98_BLOCK_PREFIX, dry-run=$SWAY98_DRY_RUN)"
    fi
    [[ ! -e "$TEST_ROOT/continued" ]] || fail "module continued after rejection"
    grep -q 'marker' "$TEST_ROOT/reject.log" || fail "missing marker diagnostic"
    cmp -s -- "$TEST_ROOT/original" "$file" || fail "$scenario modified user config"
    diff -r -- "$TEST_ROOT/pristine-state" "$SWAY98_STATE" || fail "$scenario modified state"
    [[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]] || fail "temporary file leaked"
}

for SWAY98_BLOCK_PREFIX in '#' '//'; do
    for SWAY98_DRY_RUN in 0 1; do
        for scenario in missing-end orphan-end nested reversed; do
            _sway98_test_reject "$scenario"
        done
    done
done
printf 'ok: malformed blocks rejected without changing config or state (16 cases)\n'

SWAY98_DRY_RUN=0
SWAY98_BLOCK_PREFIX='#'
file="$HOME/config"
cat >"$file" <<'EOF'
before
# >>> sway98 >>>
old include
# <<< sway98 <<<
between
# >>> unrelated >>>
keep this block
# <<< unrelated <<<
# >>> unrelated-unclosed >>>
keep this unmatched unrelated marker
# >>> sway98 >>>
duplicate include
# <<< sway98 <<<
after
EOF
cp -a -- "$file" "$TEST_ROOT/original"
cat >"$TEST_ROOT/expected" <<'EOF'
before
between
# >>> unrelated >>>
keep this block
# <<< unrelated <<<
# >>> unrelated-unclosed >>>
keep this unmatched unrelated marker
after

# >>> sway98 >>>
new include
# <<< sway98 <<<
EOF
include_block "$file" sway98 'new include'
cmp -s -- "$TEST_ROOT/expected" "$file" || fail "valid replacement lost unrelated content"
cp -a -- "$(manifest_files)" "$TEST_ROOT/first-manifest"
include_block "$file" sway98 'new include'
cmp -s -- "$TEST_ROOT/expected" "$file" || fail "replacement is not idempotent"
cmp -s -- "$TEST_ROOT/first-manifest" "$(manifest_files)" || fail "unchanged edit added manifest rows"
restore_all
cmp -s -- "$TEST_ROOT/original" "$file" || fail "rollback lost original config"
printf 'ok: valid duplicate blocks consolidate, preserve unrelated content, and roll back\n'

# New files have no markers to validate, including Firefox's JS comment prefix.
SWAY98_BLOCK_PREFIX='//'
include_block "$HOME/user.js" sway98 'user_pref("test", true);'
printf '// >>> sway98 >>>\nuser_pref("test", true);\n// <<< sway98 <<<\n' >"$TEST_ROOT/expected"
cmp -s -- "$TEST_ROOT/expected" "$HOME/user.js" || fail "new JS block differs"
include_block "$HOME/user.js" sway98 'user_pref("test", true);'
cmp -s -- "$TEST_ROOT/expected" "$HOME/user.js" || fail "JS block is not idempotent"
restore_all
[[ ! -e "$HOME/user.js" ]] || fail "rollback left new JS config"
printf 'ok: new JS block installs idempotently and rolls back\n'
