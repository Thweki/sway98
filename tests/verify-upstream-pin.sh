#!/usr/bin/env bash
set -euo pipefail

# Local Git fixtures only: no upstream downloads, credentials or user config.
SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SWAY98_PIN_TMP="$(mktemp -d)"
trap 'rm -rf -- "$SWAY98_PIN_TMP"' EXIT
export HOME="$SWAY98_PIN_TMP/home"
export XDG_STATE_HOME="$SWAY98_PIN_TMP/state"
export SWAY98_STATE="$XDG_STATE_HOME/sway98"
export SWAY98_THEME_SRC="$SWAY98_STATE/upstream/Chicago95"
export SWAY98_DRY_RUN=0 SWAY98_LOG=""
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_TERMINAL_PROMPT=0 GIT_ALLOW_PROTOCOL=file
mkdir -p -- "$HOME"

# shellcheck source=lib/common.sh
. "$SWAY98_ROOT/lib/common.sh"
# shellcheck source=lib/fetch.sh
. "$SWAY98_ROOT/lib/fetch.sh"

_sway98_test_pass() { printf 'ok   %s\n' "$*"; }
_sway98_test_fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
_sway98_test_head() {
    [[ "$(git -C "$1" rev-parse HEAD)" == "$2" ]] \
        || _sway98_test_fail "wrong HEAD in $1 (expected $2)"
}
_sway98_test_pin() (
    git_clone_pinned "$SWAY98_PIN_URL" "$1" "$2"
)
_sway98_test_reject() {
    local expected_message="$1"
    shift
    # Call in a conditional, as install.sh does: errexit cannot hide failures.
    if ( "$@" ) >"$SWAY98_PIN_TMP/rejected.log" 2>&1; then
        _sway98_test_fail "unexpected success: $*"
    fi
    if ! grep -Fq -- "$expected_message" "$SWAY98_PIN_TMP/rejected.log"; then
        cat "$SWAY98_PIN_TMP/rejected.log" >&2
        _sway98_test_fail "missing failure diagnostic: $expected_message"
    fi
}

SWAY98_PIN_ORIGIN="$SWAY98_PIN_TMP/origin"
git init --quiet --object-format=sha1 "$SWAY98_PIN_ORIGIN"
git -C "$SWAY98_PIN_ORIGIN" config user.name 'sway98 fixture'
git -C "$SWAY98_PIN_ORIGIN" config user.email 'fixture@localhost'
mkdir -p -- "$SWAY98_PIN_ORIGIN/Theme/Chicago95"
printf 'pinned\n' >"$SWAY98_PIN_ORIGIN/Theme/Chicago95/index.theme"
git -C "$SWAY98_PIN_ORIGIN" add .
git -C "$SWAY98_PIN_ORIGIN" commit --quiet -m 'fixture: pinned commit'
SWAY98_PIN_COMMIT="$(git -C "$SWAY98_PIN_ORIGIN" rev-parse HEAD)"
printf 'newer\n' >"$SWAY98_PIN_ORIGIN/Theme/Chicago95/index.theme"
git -C "$SWAY98_PIN_ORIGIN" commit --quiet -am 'fixture: newer commit'
SWAY98_PIN_TIP="$(git -C "$SWAY98_PIN_ORIGIN" rev-parse HEAD)"
SWAY98_PIN_URL="file://$SWAY98_PIN_ORIGIN"
SWAY98_CHICAGO95_URL="$SWAY98_PIN_URL"
SWAY98_CHICAGO95_REF="$SWAY98_PIN_COMMIT"

_sway98_test_pin "$SWAY98_PIN_COMMIT" "$SWAY98_PIN_TMP/fresh"
_sway98_test_head "$SWAY98_PIN_TMP/fresh" "$SWAY98_PIN_COMMIT"
[[ "$(cat "$SWAY98_PIN_TMP/fresh/Theme/Chicago95/index.theme")" == pinned ]] \
    || _sway98_test_fail 'fresh clone used the wrong content'
_sway98_test_pass 'fresh clone checks out the full pin, not the remote tip'

git clone --quiet "$SWAY98_PIN_URL" "$SWAY98_PIN_TMP/cached"
# Both commits exist locally, but HEAD is wrong. Re-pinning must work offline.
git -C "$SWAY98_PIN_TMP/cached" remote set-url origin "$SWAY98_PIN_TMP/missing-origin"
_sway98_test_pin "$SWAY98_PIN_COMMIT" "$SWAY98_PIN_TMP/cached"
_sway98_test_head "$SWAY98_PIN_TMP/cached" "$SWAY98_PIN_COMMIT"
_sway98_test_pin "$SWAY98_PIN_COMMIT" "$SWAY98_PIN_TMP/cached"
_sway98_test_head "$SWAY98_PIN_TMP/cached" "$SWAY98_PIN_COMMIT"
_sway98_test_pass 'cached pin is checked out and repeated calls work offline'

git clone --quiet --depth 1 "$SWAY98_PIN_URL" "$SWAY98_PIN_TMP/shallow"
if git -C "$SWAY98_PIN_TMP/shallow" cat-file -e "$SWAY98_PIN_COMMIT" 2>/dev/null; then
    _sway98_test_fail 'shallow fixture unexpectedly contains the pin'
fi
_sway98_test_reject 'is missing in' _sway98_test_pin "$SWAY98_PIN_COMMIT" "$SWAY98_PIN_TMP/shallow"
_sway98_test_head "$SWAY98_PIN_TMP/shallow" "$SWAY98_PIN_TIP"
if git -C "$SWAY98_PIN_TMP/shallow" cat-file -e "$SWAY98_PIN_COMMIT" 2>/dev/null; then
    _sway98_test_fail 'existing shallow fixture fetched the missing pin'
fi
_sway98_test_pass 'existing shallow clone fails closed without fetching its missing pin'

git clone --quiet "$SWAY98_PIN_URL" "$SWAY98_PIN_TMP/dirty"
printf 'user edit\n' >"$SWAY98_PIN_TMP/dirty/Theme/Chicago95/index.theme"
_sway98_test_reject 'tracked changes' _sway98_test_pin "$SWAY98_PIN_COMMIT" "$SWAY98_PIN_TMP/dirty"
_sway98_test_reject 'tracked changes' _sway98_test_pin "$SWAY98_PIN_TIP" "$SWAY98_PIN_TMP/dirty"
_sway98_test_head "$SWAY98_PIN_TMP/dirty" "$SWAY98_PIN_TIP"
[[ "$(cat "$SWAY98_PIN_TMP/dirty/Theme/Chicago95/index.theme")" == 'user edit' ]] \
    || _sway98_test_fail 'tracked user edit was changed'
_sway98_test_pass 'tracked edits are preserved and not accepted as a verified pin'

_sway98_test_reject 'failed to fetch' _sway98_test_pin \
    0000000000000000000000000000000000000000 "$SWAY98_PIN_TMP/unavailable"
_sway98_test_reject 'expected a full commit id' _sway98_test_pin \
    "${SWAY98_PIN_COMMIT:0:8}" "$SWAY98_PIN_TMP/abbreviated"
_sway98_test_reject 'expected a full commit id' _sway98_test_pin \
    HEAD "$SWAY98_PIN_TMP/symbolic"
[[ ! -e "$SWAY98_PIN_TMP/abbreviated" && ! -e "$SWAY98_PIN_TMP/symbolic" ]] \
    || _sway98_test_fail 'invalid pins created a checkout'
_sway98_test_pass 'unavailable, abbreviated and symbolic pins fail closed'

# Inject success responses with the wrong result to exercise explicit equality
# checks, rather than relying on Git itself to reject impossible fetches.
_sway98_test_wrong_fetch() (
    git() {
        local -a git_args=("$@")
        if [[ "${git_args[2]:-}" == fetch ]]; then
            git_args[${#git_args[@]}-1]="$SWAY98_PIN_TIP"
        fi
        command git "${git_args[@]}"
    }
    git_clone_pinned "$SWAY98_PIN_URL" "$SWAY98_PIN_COMMIT" "$SWAY98_PIN_TMP/wrong-fetch"
)
_sway98_test_reject 'upstream commit mismatch' _sway98_test_wrong_fetch
_sway98_test_pass 'fetch success with a different commit is rejected'

git clone --quiet "$SWAY98_PIN_URL" "$SWAY98_PIN_TMP/wrong-checkout"
_sway98_test_wrong_checkout() (
    git() {
        [[ "${5:-}" == checkout ]] && return 0
        command git "$@"
    }
    git_clone_pinned "$SWAY98_PIN_URL" "$SWAY98_PIN_COMMIT" "$SWAY98_PIN_TMP/wrong-checkout"
)
_sway98_test_reject 'upstream commit mismatch' _sway98_test_wrong_checkout
_sway98_test_pass 'checkout success without moving HEAD is rejected'

_sway98_test_failed_checkout() (
    git() {
        [[ "${5:-}" == checkout ]] && return 1
        command git "$@"
    }
    git_clone_pinned "$SWAY98_PIN_URL" "$SWAY98_PIN_COMMIT" "$SWAY98_PIN_TMP/wrong-checkout"
)
_sway98_test_reject 'failed to check out' _sway98_test_failed_checkout
_sway98_test_pass 'checkout errors propagate even in a conditional caller'

# The managed path contains the expected theme directory at the wrong commit.
mkdir -p -- "$(dirname -- "$SWAY98_THEME_SRC")"
git clone --quiet "$SWAY98_PIN_URL" "$SWAY98_THEME_SRC"
( ensure_chicago95 )
_sway98_test_head "$SWAY98_THEME_SRC" "$SWAY98_PIN_COMMIT"
_sway98_test_pass 'existing managed theme directory cannot bypass the pin'

rm -rf -- "$SWAY98_THEME_SRC"
( ensure_chicago95 )
_sway98_test_head "$SWAY98_THEME_SRC" "$SWAY98_PIN_COMMIT"
_sway98_test_pass 'missing managed source is cloned at the pin'

git -C "$SWAY98_THEME_SRC" fetch --quiet origin "$SWAY98_PIN_TIP"
git -C "$SWAY98_THEME_SRC" checkout --quiet --detach "$SWAY98_PIN_TIP"
cp -a -- "$SWAY98_THEME_SRC" "$SWAY98_PIN_TMP/before-dry-run"
_sway98_test_dry_run() {
    local SWAY98_DRY_RUN=1
    ensure_chicago95
    git_clone_pinned "$SWAY98_PIN_URL" "$SWAY98_PIN_COMMIT" "$SWAY98_PIN_TMP/dry-missing"
    _sway98_test_theme "$SWAY98_PIN_TMP/dry-managed/upstream/Chicago95" "$SWAY98_PIN_TMP/dry-managed"
}
_sway98_test_theme() {
    local SWAY98_THEME_SRC="$1" SWAY98_STATE="${2:-$SWAY98_STATE}"
    ensure_chicago95
}
_sway98_test_dry_run
diff -r -- "$SWAY98_PIN_TMP/before-dry-run" "$SWAY98_THEME_SRC" \
    || _sway98_test_fail 'dry run changed the managed checkout'
[[ ! -e "$SWAY98_PIN_TMP/dry-missing" && ! -e "$SWAY98_PIN_TMP/dry-managed" ]] \
    || _sway98_test_fail 'dry run created a destination'
_sway98_test_pass 'dry run leaves existing and missing checkouts untouched'

git clone --quiet "$SWAY98_PIN_URL" "$SWAY98_PIN_TMP/external-git"
mkdir -p -- "$SWAY98_PIN_TMP/external-tree/Theme/Chicago95"
printf 'external\n' >"$SWAY98_PIN_TMP/external-tree/Theme/Chicago95/index.theme"
for SWAY98_PIN_EXTERNAL in external-git external-tree; do
    cp -a -- "$SWAY98_PIN_TMP/$SWAY98_PIN_EXTERNAL" "$SWAY98_PIN_TMP/external-before"
    _sway98_test_theme "$SWAY98_PIN_TMP/$SWAY98_PIN_EXTERNAL"
    diff -r -- "$SWAY98_PIN_TMP/external-before" "$SWAY98_PIN_TMP/$SWAY98_PIN_EXTERNAL" \
        || _sway98_test_fail 'external source was modified'
    rm -rf -- "$SWAY98_PIN_TMP/external-before"
done
_sway98_test_head "$SWAY98_PIN_TMP/external-git" "$SWAY98_PIN_TIP"
_sway98_test_pass 'caller-managed Git and non-Git source trees remain supported'

_sway98_test_theme "$SWAY98_PIN_TMP/external-missing"
_sway98_test_head "$SWAY98_PIN_TMP/external-missing" "$SWAY98_PIN_COMMIT"
_sway98_test_pass 'missing external destination still gets a pinned clone'

mkdir -p -- "$SWAY98_PIN_TMP/external-incomplete"
touch "$SWAY98_PIN_TMP/external-incomplete/keep"
_sway98_test_reject 'source is incomplete' _sway98_test_theme "$SWAY98_PIN_TMP/external-incomplete"
[[ -f "$SWAY98_PIN_TMP/external-incomplete/keep" && ! -e "$SWAY98_PIN_TMP/external-incomplete/.git" ]] \
    || _sway98_test_fail 'incomplete external source was changed'
_sway98_test_pass 'incomplete external source remains untouched'

rm -rf -- "$SWAY98_THEME_SRC"
mkdir -p -- "$SWAY98_THEME_SRC/Theme/Chicago95"
_sway98_test_managed_tree() ( ensure_chicago95 )
_sway98_test_reject 'exists and is not a git checkout' _sway98_test_managed_tree
_sway98_test_pass 'non-Git tree at the managed path cannot bypass verification'
