#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$BACKUP_TEST_TMP"' EXIT
BACKUP_TEST_HOME="$BACKUP_TEST_TMP/home with spaces"
BACKUP_TEST_STATE="$BACKUP_TEST_HOME/state/sway98"
BACKUP_TEST_SESSION=20261115-100000
mkdir -p -- "$BACKUP_TEST_HOME"

# Do not inherit an installer's state, logging, dry-run or timestamp overrides.
for variable in "${!SWAY98_@}" "${!XDG_@}"; do unset "$variable"; done

_sway98_test_env() {
    env HOME="$BACKUP_TEST_HOME" XDG_STATE_HOME="$BACKUP_TEST_HOME/state" \
        SWAY98_TS="$BACKUP_TEST_SESSION" SWAY98_NO_GSETTINGS=1 "$@"
}
_sway98_test_backups() { _sway98_test_env bash "$REPO_ROOT/backups.sh" "$@"; }
_sway98_test_fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
_sway98_test_reject() {
    if _sway98_test_backups "$@" >"$BACKUP_TEST_TMP/error" 2>&1; then
        _sway98_test_fail "unexpected success: $*"
    fi
}
_sway98_test_unchanged() {
    diff -r --no-dereference -- "$1" "$2" >/dev/null || _sway98_test_fail "trees changed: $1 $2"
}

# A read-only command must not initialize state or append to an inherited log.
printf 'sentinel\n' >"$BACKUP_TEST_TMP/inherited.log"
cp -a -- "$BACKUP_TEST_HOME" "$BACKUP_TEST_TMP/fresh"
listing="$(_sway98_test_env env SWAY98_LOG="$BACKUP_TEST_TMP/inherited.log" bash "$REPO_ROOT/backups.sh")"
[[ "$listing" == SESSION ]] || _sway98_test_fail 'fresh listing'
_sway98_test_backups --help >/dev/null
[[ "$(cat "$BACKUP_TEST_TMP/inherited.log")" == sentinel ]] || _sway98_test_fail 'inherited log changed'
_sway98_test_unchanged "$BACKUP_TEST_TMP/fresh" "$BACKUP_TEST_HOME"
printf 'ok: fresh listing and help have no side effects\n'

_sway98_test_reject --restore
_sway98_test_reject --restore "$BACKUP_TEST_SESSION"
_sway98_test_reject --to
_sway98_test_reject --to "$BACKUP_TEST_HOME/new"
_sway98_test_reject --list --restore "$BACKUP_TEST_SESSION" --to "$BACKUP_TEST_HOME/new"
_sway98_test_reject --restore "$BACKUP_TEST_SESSION" --list
_sway98_test_reject --list --list
_sway98_test_reject --list ../escape
_sway98_test_reject --list /absolute
_sway98_test_reject --list missing
_sway98_test_reject --unknown
_sway98_test_reject --restore "$BACKUP_TEST_SESSION" --to a --to b
_sway98_test_unchanged "$BACKUP_TEST_TMP/fresh" "$BACKUP_TEST_HOME"
printf 'ok: malformed and conflicting arguments fail without writes\n'

# Generate actual installer backups, including a second run that must retain
# the original backup and a created file that has no original to recover.
mkdir -p -- "$BACKUP_TEST_HOME/.config/example"
printf 'original\000bytes\n' >"$BACKUP_TEST_HOME/.config/example/settings file"
chmod 640 -- "$BACKUP_TEST_HOME/.config/example/settings file"
touch -t 202001020304 -- "$BACKUP_TEST_HOME/.config/example/settings file"
cp -a -- "$BACKUP_TEST_HOME/.config/example/settings file" "$BACKUP_TEST_TMP/original"
printf 'installed\n' >"$BACKUP_TEST_TMP/replacement"
_sway98_test_env bash -c '
    set -euo pipefail
    . "$1/lib/common.sh"
    . "$1/lib/manifest.sh"
    manifest_init
    SWAY98_MODULE=test
    install_file "$2/replacement" "$HOME/.config/example/settings file"
    install_file "$2/replacement" "$HOME/.config/example/created"
    SWAY98_TS=20261115-110000
    manifest_init
    printf "reinstalled\n" >"$2/replacement"
    install_file "$2/replacement" "$HOME/.config/example/settings file"
' bash "$REPO_ROOT" "$BACKUP_TEST_TMP" >"$BACKUP_TEST_TMP/install.log" 2>&1

backup_tree="$BACKUP_TEST_STATE/backups/$BACKUP_TEST_SESSION"
mkdir -p -- "$backup_tree/system/etc/example" "$BACKUP_TEST_TMP/outside"
printf 'system original\n' >"$backup_tree/system/etc/example/config"
printf 'outside sentinel\n' >"$BACKUP_TEST_TMP/outside/sentinel"
ln -s "$BACKUP_TEST_TMP/outside" "$backup_tree/home/directory-link"
ln -s nowhere "$backup_tree/home/dangling-link"
printf 'odd name\n' >"$backup_tree/home/"$'tab\tnewline\nback\\slash'
printf 'hidden\n' >"$backup_tree/.hidden"
cp -a -- "$BACKUP_TEST_STATE" "$BACKUP_TEST_TMP/state-before"
cp -a -- "$BACKUP_TEST_HOME/.config" "$BACKUP_TEST_TMP/config-before"

listing="$(_sway98_test_backups --list)"
[[ "$listing" == $'SESSION\n20261115-100000\n20261115-110000' ]] || _sway98_test_fail 'session list'
listing="$(_sway98_test_backups --list "$BACKUP_TEST_SESSION")"
[[ "$listing" == *$'file\thome/.config/example/settings\\ file'* ]] || _sway98_test_fail 'spaced file listing'
[[ "$listing" == *$'symlink\thome/dangling-link'* ]] || _sway98_test_fail 'dangling link listing'
[[ "$listing" != *sentinel* && "$listing" != *created* ]] || _sway98_test_fail 'listing followed links or included unbacked files'
[[ "$(_sway98_test_backups --list 20261115-110000)" == $'TYPE\tPATH' ]] || _sway98_test_fail 'empty session'
_sway98_test_unchanged "$BACKUP_TEST_TMP/state-before" "$BACKUP_TEST_STATE"
printf 'ok: real backups, reinstallation, empty sessions and symlink inventory\n'

recovered="$BACKUP_TEST_HOME/recovered originals"
_sway98_test_backups --restore "$BACKUP_TEST_SESSION" --to "$recovered" --dry-run >"$BACKUP_TEST_TMP/dry.log" 2>&1
_sway98_test_env env SWAY98_DRY_RUN=1 SWAY98_LOG="$BACKUP_TEST_TMP/inherited.log" \
    bash "$REPO_ROOT/backups.sh" --restore "$BACKUP_TEST_SESSION" --to "$recovered" >>"$BACKUP_TEST_TMP/dry.log" 2>&1
[[ ! -e "$recovered" ]] || _sway98_test_fail 'dry run created destination'
[[ "$(cat "$BACKUP_TEST_TMP/inherited.log")" == sentinel ]] || _sway98_test_fail 'dry run wrote inherited log'
_sway98_test_unchanged "$BACKUP_TEST_TMP/state-before" "$BACKUP_TEST_STATE"
printf 'ok: explicit and inherited dry-run leave state and destination untouched\n'

_sway98_test_backups --to "$recovered" --restore "$BACKUP_TEST_SESSION"
_sway98_test_unchanged "$backup_tree" "$recovered"
cmp -- "$BACKUP_TEST_TMP/original" "$recovered/home/.config/example/settings file"
[[ "$(stat -c '%a %Y' -- "$BACKUP_TEST_TMP/original")" == "$(stat -c '%a %Y' -- "$recovered/home/.config/example/settings file")" ]] || _sway98_test_fail 'mode or timestamp lost'
[[ "$(stat -c '%a' -- "$recovered")" == 700 ]] || _sway98_test_fail 'recovery root is not private'
[[ -L "$recovered/home/dangling-link" && -L "$recovered/home/directory-link" ]] || _sway98_test_fail 'symlinks lost'
_sway98_test_unchanged "$BACKUP_TEST_TMP/config-before" "$BACKUP_TEST_HOME/.config"
_sway98_test_unchanged "$BACKUP_TEST_TMP/state-before" "$BACKUP_TEST_STATE"
printf 'ok: recovery preserves contents, metadata and symlinks without changing installation\n'

_sway98_test_reject --restore "$BACKUP_TEST_SESSION" --to "$recovered"
_sway98_test_reject --restore "$BACKUP_TEST_SESSION" --to "$BACKUP_TEST_TMP/original"
ln -s nowhere "$BACKUP_TEST_HOME/dangling-destination"
_sway98_test_reject --restore "$BACKUP_TEST_SESSION" --to "$BACKUP_TEST_HOME/dangling-destination"
_sway98_test_reject --restore "$BACKUP_TEST_SESSION" --to "$BACKUP_TEST_HOME/dangling-destination/" --dry-run
ln -s "$BACKUP_TEST_TMP/outside" "$BACKUP_TEST_HOME/outside-link"
_sway98_test_reject --restore "$BACKUP_TEST_SESSION" --to "$BACKUP_TEST_HOME/outside-link/new"
_sway98_test_reject --restore "$BACKUP_TEST_SESSION" --to "$BACKUP_TEST_STATE/new"
_sway98_test_reject --restore "$BACKUP_TEST_SESSION" --to "$BACKUP_TEST_HOME/../escaped"
_sway98_test_reject --restore "$BACKUP_TEST_SESSION" --to "$BACKUP_TEST_HOME/missing/child"
[[ ! -e "$BACKUP_TEST_TMP/outside/new" ]] || _sway98_test_fail 'escaped HOME'
_sway98_test_unchanged "$backup_tree" "$recovered"
_sway98_test_unchanged "$BACKUP_TEST_TMP/state-before" "$BACKUP_TEST_STATE"
printf 'ok: existing targets, dangling targets, escapes and state writes are refused\n'

# Reject unsupported source entries before creating a partial recovery tree.
mkfifo "$backup_tree/fifo"
_sway98_test_reject --restore "$BACKUP_TEST_SESSION" --to "$BACKUP_TEST_HOME/invalid-source"
[[ ! -e "$BACKUP_TEST_HOME/invalid-source" ]] || _sway98_test_fail 'invalid source created destination'
rm -- "$backup_tree/fifo"
ln -s "$backup_tree" "$BACKUP_TEST_STATE/backups/linked-session"
_sway98_test_reject --list linked-session
_sway98_test_reject --restore linked-session --to "$BACKUP_TEST_HOME/invalid-source"
rm -- "$BACKUP_TEST_STATE/backups/linked-session"
printf 'ok: special entries and symlink sessions are refused\n'

# A copy failure is nonzero, never reports success, and retains the source.
mkdir -- "$BACKUP_TEST_TMP/bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$BACKUP_TEST_TMP/bin/cp"
chmod +x -- "$BACKUP_TEST_TMP/bin/cp"
if _sway98_test_env env PATH="$BACKUP_TEST_TMP/bin:$PATH" bash "$REPO_ROOT/backups.sh" \
    --restore "$BACKUP_TEST_SESSION" --to "$BACKUP_TEST_HOME/failed-copy" >"$BACKUP_TEST_TMP/failure.log" 2>&1; then
    _sway98_test_fail 'copy failure reported success'
fi
grep -q 'partial copy kept' "$BACKUP_TEST_TMP/failure.log" || _sway98_test_fail 'copy failure lacks recovery guidance'
_sway98_test_unchanged "$BACKUP_TEST_TMP/state-before" "$BACKUP_TEST_STATE"
printf 'ok: copy failures leave original backups intact and return failure\n'

_sway98_test_env bash "$REPO_ROOT/uninstall.sh" --yes >"$BACKUP_TEST_TMP/uninstall.log" 2>&1
[[ -d "$BACKUP_TEST_STATE/manifest/history" ]] || _sway98_test_fail 'uninstall did not archive manifest'
cmp -- "$BACKUP_TEST_TMP/original" "$BACKUP_TEST_HOME/.config/example/settings file"
_sway98_test_unchanged "$backup_tree" "$recovered"
_sway98_test_backups --restore "$BACKUP_TEST_SESSION" --to "$BACKUP_TEST_HOME/after-uninstall"
_sway98_test_unchanged "$backup_tree" "$BACKUP_TEST_HOME/after-uninstall"
printf 'ok: recovery works after uninstall; earlier recovery copies survive\n'

# Explicit state overrides work even with no manifest at all.
mkdir -p -- "$BACKUP_TEST_TMP/custom-state/backups/custom-run/home"
printf 'custom\n' >"$BACKUP_TEST_TMP/custom-state/backups/custom-run/home/original"
listing="$(_sway98_test_env env SWAY98_STATE="$BACKUP_TEST_TMP/custom-state" bash "$REPO_ROOT/backups.sh")"
[[ "$listing" == $'SESSION\ncustom-run' ]] || _sway98_test_fail 'state override ignored'
_sway98_test_env env SWAY98_STATE="$BACKUP_TEST_TMP/custom-state" bash "$REPO_ROOT/backups.sh" \
    --restore custom-run --to "$BACKUP_TEST_HOME/custom-recovery"
cmp -- "$BACKUP_TEST_TMP/custom-state/backups/custom-run/home/original" "$BACKUP_TEST_HOME/custom-recovery/home/original"
ln -s "$BACKUP_TEST_STATE/backups" "$BACKUP_TEST_TMP/custom-state/linked-backups"
mv -- "$BACKUP_TEST_TMP/custom-state/backups" "$BACKUP_TEST_TMP/custom-state/saved-backups"
mv -- "$BACKUP_TEST_TMP/custom-state/linked-backups" "$BACKUP_TEST_TMP/custom-state/backups"
if _sway98_test_env env SWAY98_STATE="$BACKUP_TEST_TMP/custom-state" bash "$REPO_ROOT/backups.sh" >"$BACKUP_TEST_TMP/error" 2>&1; then
    _sway98_test_fail 'symlink backup root accepted'
fi
printf 'ok: explicit state override, manifest-free recovery and symlink root refusal\n'
