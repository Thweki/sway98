#!/usr/bin/env bash
set -euo pipefail

SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
for variable in "${!SWAY98_@}" "${!XDG_@}"; do
    [[ "$variable" == SWAY98_ROOT ]] || unset "$variable"
done
SANDBOX="$(mktemp -d "$SWAY98_ROOT/tests/status.XXXXXX")"
trap 'rm -rf -- "$SANDBOX"' EXIT
export HOME="$SANDBOX/tree/home"
export XDG_STATE_HOME="$SANDBOX/tree/state with spaces"
export SWAY98_LOG="$SANDBOX/tree/inherited.log"
mkdir -p -- "$HOME" "$SANDBOX/bin"
printf 'keep this log\n' >"$SWAY98_LOG"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

# Status must not enter preflight, hash managed files, fetch, or create state.
for blocked in pacman curl git swaymsg gsettings sha256sum mkdir mktemp; do
    printf '#!/usr/bin/env bash\nprintf "unexpected command\\n" >>"%s"\nexit 99\n' \
        "$SANDBOX/unexpected" >"$SANDBOX/bin/$blocked"
    chmod +x "$SANDBOX/bin/$blocked"
done

sway98_test_status() {
    local result=0
    rm -rf -- "$SANDBOX/before"
    cp -a -- "$SANDBOX/tree" "$SANDBOX/before"
    PATH="$SANDBOX/bin:$PATH" bash "$SWAY98_ROOT/install.sh" "$@" \
        >"$SANDBOX/output" 2>"$SANDBOX/error" </dev/null || result=$?
    diff -r --no-dereference -- "$SANDBOX/before" "$SANDBOX/tree" || fail 'status wrote to home/state/log'
    [[ ! -e "$SANDBOX/unexpected" ]] || fail 'status ran an installation or verification command'
    return "$result"
}

sway98_test_status --status || fail 'fresh status failed'
grep -qx 'No active manifest records.' "$SANDBOX/output" || fail 'missing empty-state message'
[[ ! -e "$XDG_STATE_HOME" ]] || fail 'created state directory'
pass 'fresh state is read-only without --dry-run'

manifest="$XDG_STATE_HOME/sway98/manifest"
mkdir -p -- "$manifest/history/old"
printf 'archived\tinstalled\t0.0.1\told\n' >"$manifest/history/old/modules.tsv"
for name in modules files dirs commands; do : >"$manifest/$name.tsv"; done
sway98_test_status --status || fail 'empty manifest failed'
grep -qx 'No active manifest records.' "$SANDBOX/output" || fail 'included archived history'
pass 'empty active manifests ignore history'

printf 'theme\tinstalled\t0.0.1\tfirst\ntheme\tinstalled\t0.1.0\tlast\nnoop\tinstalled\t0.1.0\tlast\n' >"$manifest/modules.tsv"
printf 'theme\tcreate\t%s/missing file\thash\t\t\ntheme\tcreate\t%s/missing file\tnewhash\t\t\nlegacy\tcreate\t%s/dangling\t\t\t\n' \
    "$HOME" "$HOME" "$HOME" >"$manifest/files.tsv"
ln -s missing "$HOME/dangling"
printf 'theme\t%s/directory\ntheme\t%s/directory\ndirs-only\t%s/other\n' \
    "$HOME" "$HOME" "$HOME" >"$manifest/dirs.tsv"
printf 'commands-only\ttouch "%s/executed"\ncommands-only\ttouch "%s/executed"\n' \
    "$HOME" "$HOME" >"$manifest/commands.tsv"
sway98_test_status --status || fail 'populated status failed'
awk 'BEGIN { OFS=" " } NF == 7 { $1=$1; print }' "$SANDBOX/output" >"$SANDBOX/rows"
for row in \
    'theme installed 0.1.0 last 1 1 0' \
    'noop installed 0.1.0 last 0 0 0' \
    'legacy records-only - - 1 0 0' \
    'dirs-only records-only - - 0 1 0' \
    'commands-only records-only - - 0 0 2'; do
    grep -Fxq -- "$row" "$SANDBOX/rows" || fail "missing summary: $row"
done
[[ "$(grep -c '^theme ' "$SANDBOX/rows")" == 1 ]] || fail 'reinstall duplicated module row'
if grep -q 'touch\|missing file\|archived' "$SANDBOX/output"; then fail 'printed command/path/history contents'; fi
pass 'latest results, unique paths, orphan records, and command counts'

rm -- "$manifest/modules.tsv" "$manifest/files.tsv" "$manifest/dirs.tsv"
sway98_test_status --status || fail 'command-only state failed'
grep -Eq '^commands-only[[:space:]]+records-only' "$SANDBOX/output" || fail 'lost command-only state'
pass 'partial manifests remain visible'

export SWAY98_STATE="$SANDBOX/tree/override"
sway98_test_status --status --dry-run --yes || fail 'state override failed'
grep -qx 'No active manifest records.' "$SANDBOX/output" || fail 'ignored SWAY98_STATE'
pass 'explicit state override takes precedence'
unset SWAY98_STATE

saved_state_home="$XDG_STATE_HOME"
unset XDG_STATE_HOME
sway98_test_status --status || fail 'default state path failed'
grep -Fxq "Manifest: $HOME/.local/state/sway98/manifest" "$SANDBOX/output" || fail 'wrong default state path'
export XDG_STATE_HOME="$saved_state_home"
pass 'default state location is read-only'

for selection in --all --recommended --list '--modules theme' '--only theme'; do
    read -r -a selection_args <<<"$selection"
    if sway98_test_status --status "${selection_args[@]}"; then fail 'accepted status with selection'; fi
    if sway98_test_status "${selection_args[@]}" --status; then fail 'accepted selection with status'; fi
done
pass 'conflicting modes fail without writes in either order'

for args in '--bogus --status' '--status --bogus' '--modules --status' '--only --status' '-- --status'; do
    read -r -a invalid_args <<<"$args"
    if sway98_test_status "${invalid_args[@]}"; then fail "accepted invalid status options: $args"; fi
done
pass 'invalid status options fail without writing inherited log'

(
    cd -- "$SANDBOX/tree"
    for state in 'state=' '-state'; do
        mkdir -p -- "$state/manifest"
        printf 'relative\tinstalled\t0.1.0\tlast\n' > "$state/manifest/modules.tsv"
        SWAY98_STATE="$state" sway98_test_status --status || fail "relative state failed: $state"
        grep -Eq '^relative[[:space:]]+installed' "$SANDBOX/output" || fail 'relative manifest was not read'
    done
)
pass 'relative state paths are passed to awk as filenames'

printf 'broken\n' >"$manifest/files.tsv"
if sway98_test_status --status; then fail 'accepted malformed manifest'; fi
grep -q 'invalid manifest record' "$SANDBOX/error" || fail 'missing malformed manifest diagnostic'
rm -- "$manifest/files.tsv"
mkdir -- "$manifest/files.tsv"
if sway98_test_status --status; then fail 'accepted manifest directory'; fi
pass 'invalid manifest input fails without writes'

if [[ "$EUID" == 0 ]]; then
    printf 'SKIP: installer lifecycle requires a non-root user\n'
else
    export SWAY98_STATE="$SANDBOX/tree/lifecycle-state"
    for attempt in 1 2; do
        bash "$SWAY98_ROOT/install.sh" --yes --only swaylock >"$SANDBOX/install.log" 2>&1 || fail "install $attempt failed"
        sway98_test_status --status || fail "status after install $attempt failed"
        awk '$1 == "swaylock" && $2 == "installed" && $5 == 1 && $6 == 2 && $7 == 0 { found=1 }
             END { exit !found }' "$SANDBOX/output" || fail 'incorrect real manifest summary'
    done
    bash "$SWAY98_ROOT/uninstall.sh" --yes >"$SANDBOX/uninstall.log" 2>&1 || fail 'uninstall failed'
    sway98_test_status --status || fail 'status after uninstall failed'
    grep -qx 'No active manifest records.' "$SANDBOX/output" || fail 'full uninstall left active status'
    pass 'real install, reinstall, and full uninstall update recorded status'
fi
