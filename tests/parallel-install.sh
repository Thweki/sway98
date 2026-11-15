#!/usr/bin/env bash
set -euo pipefail

# Run real entry points and transaction helpers against instrumented modules.
for variable in "${!SWAY98_@}" "${!XDG_@}"; do unset "$variable"; done
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PARALLEL_TMP="$(mktemp -d)"
trap 'rm -rf -- "$PARALLEL_TMP"' EXIT
TEST_REPO="$PARALLEL_TMP/repo with spaces"
mkdir -p -- "$TEST_REPO"
cp -- "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh" "$TEST_REPO/"
cp -a -- "$REPO_ROOT/lib" "$TEST_REPO/lib"
export HOME="$PARALLEL_TMP/home"
export XDG_STATE_HOME="$PARALLEL_TMP/state"
export SWAY98_NO_GSETTINGS=1
export SWAY98_TEST_ROOT="$PARALLEL_TMP"
unset SWAYSOCK WAYLAND_DISPLAY || true

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

for module in theme kitty gtk wofi swaylock; do
    mkdir -p -- "$TEST_REPO/modules/$module"
    cat >"$TEST_REPO/modules/$module/module.sh" <<'MODULE'
SWAY98_MODULE_REQUIRES=""
SWAY98_MODULE_NEEDS_PKGS=""
sway98_apply() {
    local peer attempt
    printf 'start %s\n' "$SWAY98_MODULE" >>"$SWAY98_TEST_ROOT/events"
    touch "$SWAY98_TEST_ROOT/started-$SWAY98_MODULE"
    if [[ "$SWAY98_MODULE" == gtk ]]; then
        [[ -f "$SWAY98_TEST_ROOT/ended-theme" && -f "$SWAY98_TEST_ROOT/ended-kitty" ]]
        [[ ! -e "$SWAY98_TEST_ROOT/started-wofi" ]]
    fi
    if [[ "${SWAY98_TEST_OVERLAP:-0}" == 1 ]]; then
        case "$SWAY98_MODULE" in
            theme) peer=kitty ;;
            kitty) peer=theme ;;
            wofi) peer=swaylock ;;
            swaylock) peer=wofi ;;
            *) peer= ;;
        esac
        if [[ -n "$peer" ]]; then
            for ((attempt=0; attempt<500; attempt++)); do
                [[ ! -e "$SWAY98_TEST_ROOT/started-$peer" ]] || break
                sleep 0.01
            done
            [[ -e "$SWAY98_TEST_ROOT/started-$peer" ]] || return 1
        fi
    fi
    if [[ "${SWAY98_TEST_LIMIT:-0}" == 1 && "$SWAY98_MODULE" == wofi ]]; then
        [[ -f "$SWAY98_TEST_ROOT/ended-theme" && -f "$SWAY98_TEST_ROOT/ended-kitty" ]]
    fi
    if [[ "${SWAY98_TEST_HOLD:-}" == "$SWAY98_MODULE" ]]; then
        for ((attempt=0; attempt<500; attempt++)); do
            [[ ! -e "$SWAY98_TEST_ROOT/release" ]] || break
            sleep 0.01
        done
        [[ -e "$SWAY98_TEST_ROOT/release" ]] || return 1
    fi
    # Competing read-modify-write operations must keep every block and the
    # earliest backup. Trees exercise large manifests and shared parent creation.
    include_block "$HOME/.config/shared.conf" "$SWAY98_MODULE" "$SWAY98_MODULE enabled"
    install_dir "$SWAY98_TEST_ROOT/assets" "$HOME/new/shared/$SWAY98_MODULE"
    if [[ "${SWAY98_TEST_FAIL:-}" == "$SWAY98_MODULE" ]]; then
        install_file "$SWAY98_TEST_ROOT/missing-source" "$HOME/must-not-exist"
        touch "$SWAY98_TEST_ROOT/continued-after-failure"
    fi
    touch "$SWAY98_TEST_ROOT/ended-$SWAY98_MODULE"
    printf 'end %s\n' "$SWAY98_MODULE" >>"$SWAY98_TEST_ROOT/events"
}
MODULE
done

mkdir -p -- "$PARALLEL_TMP/assets/deep/subdir" "$HOME/.config"
printf 'original user config\n' >"$HOME/.config/shared.conf"
printf 'payload\n' >"$PARALLEL_TMP/assets/deep/subdir/file"
for ((asset=0; asset<128; asset++)); do
    printf 'asset %s\n' "$asset" >"$PARALLEL_TMP/assets/deep/subdir/file-$asset"
done
ln -s deep/subdir/file "$PARALLEL_TMP/assets/link"
cp -a -- "$HOME" "$PARALLEL_TMP/pristine"

_sway98_test_run() {
    "$TEST_REPO/install.sh" --modules theme,kitty,gtk,wofi,swaylock "$@" >"$PARALLEL_TMP/install.log" 2>&1
}
_sway98_test_reset_events() {
    local module
    : >"$PARALLEL_TMP/events"
    for module in theme kitty gtk wofi swaylock; do
        rm -f -- "$PARALLEL_TMP/started-$module" "$PARALLEL_TMP/ended-$module"
    done
}
_sway98_test_restore() {
    "$TEST_REPO/uninstall.sh" --yes >"$PARALLEL_TMP/uninstall.log" 2>&1
    diff -r --no-dereference -- "$PARALLEL_TMP/pristine" "$HOME" || fail 'rollback differs'
    [[ -z "$(find "$XDG_STATE_HOME" -name 'parallel.*' -print)" ]] || fail 'worker lock leaked'
}

# Reject unusable options before even creating the installer log/state.
for count in '' 0 1 9 -2 nope 2.5; do
    if _sway98_test_run --yes --experimental-parallel "$count"; then fail "accepted count: $count"; fi
    [[ ! -e "$XDG_STATE_HOME" ]] || fail 'invalid argument created state'
done
if _sway98_test_run --experimental-parallel 2; then fail 'accepted interactive workers'; fi
[[ ! -e "$XDG_STATE_HOME" ]] || fail 'missing --yes created state'
_sway98_test_run --list --experimental-parallel 2 || fail 'read-only listing requires --yes'
[[ ! -e "$XDG_STATE_HOME" ]] || fail 'listing created state'
printf 'ok: worker count and prompt validation before writes\n'

# Default and explicit dry run remain strictly serial, with no worker artifacts.
_sway98_test_reset_events
_sway98_test_run --yes || { cat "$PARALLEL_TMP/install.log"; fail 'serial install'; }
printf '%s\n' 'start theme' 'end theme' 'start kitty' 'end kitty' 'start gtk' 'end gtk' \
    'start wofi' 'end wofi' 'start swaylock' 'end swaylock' >"$PARALLEL_TMP/serial-events"
cmp -- "$PARALLEL_TMP/serial-events" "$PARALLEL_TMP/events" || fail 'default not serial'
_sway98_test_restore
printf 'ok: default path is serial and reversible\n'

# Fixtures write event instrumentation even in dry run; assert HOME and state.
_sway98_test_reset_events
cp -a -- "$XDG_STATE_HOME" "$PARALLEL_TMP/state-before-dry"
_sway98_test_run --dry-run --experimental-parallel 2 || fail 'dry run failed'
cmp -- "$PARALLEL_TMP/serial-events" "$PARALLEL_TMP/events" || fail 'dry run not serial'
diff -r -- "$PARALLEL_TMP/state-before-dry" "$XDG_STATE_HOME" || fail 'dry run changed state'
diff -r -- "$PARALLEL_TMP/pristine" "$HOME" || fail 'dry run changed home'
printf 'ok: experimental dry run is serial and leaves HOME/state untouched\n'

export SWAY98_TEST_OVERLAP=1
for count in 2 8; do
    _sway98_test_reset_events
    _sway98_test_run --yes --experimental-parallel "$count" || {
        cat "$PARALLEL_TMP/install.log"; fail 'parallel install';
    }
    awk '
        $1 == "start" { active++; if (active > max) max=active }
        $1 == "end" { active-- }
        END { exit !(max == 2 && active == 0) }
    ' "$PARALLEL_TMP/events" || fail 'expected overlapping pairs and serial barrier'
    for module in theme kitty gtk wofi swaylock; do
        [[ "$(grep -c "^# >>> $module >>>$" "$HOME/.config/shared.conf")" == 1 ]] || fail 'lost/duplicate edit'
        [[ -L "$HOME/new/shared/$module/link" ]] || fail 'missing symlink'
    done
    [[ "$(wc -l <"$XDG_STATE_HOME/sway98/manifest/modules.tsv")" == 5 ]] || fail 'missing completion records'
    _sway98_test_reset_events
    _sway98_test_run --yes --experimental-parallel "$count" || fail 'parallel reinstall'
    _sway98_test_restore
    printf 'ok: parallel pairs, barrier, competing edits and install/reinstall/rollback (%s workers)\n' "$count"
done

# Four eligible modules without a barrier must still respect the worker limit.
_sway98_test_reset_events
export SWAY98_TEST_LIMIT=1
_sway98_test_run --yes --experimental-parallel 2 --modules theme,kitty,wofi,swaylock || {
    cat "$PARALLEL_TMP/install.log"; fail 'worker limit';
}
_sway98_test_restore
unset SWAY98_TEST_LIMIT
printf 'ok: worker count bounds adjacent eligible modules\n'

# SIGTERM drains the active batch and starts no later modules.
_sway98_test_reset_events
export SWAY98_TEST_HOLD=theme
"$TEST_REPO/install.sh" --yes --experimental-parallel 2 --modules theme,kitty,gtk,wofi,swaylock \
    >"$PARALLEL_TMP/install.log" 2>&1 &
installer_pid=$!
for ((attempt=0; attempt<500; attempt++)); do
    [[ ! -e "$PARALLEL_TMP/started-theme" ]] || break
    sleep 0.01
done
[[ -e "$PARALLEL_TMP/started-theme" ]] || fail 'signal fixture did not start'
kill -TERM "$installer_pid"
touch "$PARALLEL_TMP/release"
installer_rc=0
wait "$installer_pid" || installer_rc=$?
[[ "$installer_rc" == 143 ]] || { cat "$PARALLEL_TMP/install.log"; fail "signal exit: $installer_rc"; }
[[ -f "$PARALLEL_TMP/ended-theme" && -f "$PARALLEL_TMP/ended-kitty" ]] || fail 'returned before workers finished'
[[ ! -e "$PARALLEL_TMP/started-gtk" ]] || fail 'started a module after interruption'
_sway98_test_restore
unset SWAY98_TEST_HOLD
printf 'ok: SIGTERM drains active workers and preserves rollback\n'

# Nonzero workers release locks, retain partial rollback records and report failure.
_sway98_test_reset_events
export SWAY98_TEST_FAIL=theme
if _sway98_test_run --yes --experimental-parallel 2; then fail 'worker failure hidden'; fi
[[ ! -e "$PARALLEL_TMP/continued-after-failure" ]] || fail 'worker continued after failure'
grep -q 'failed: theme' "$PARALLEL_TMP/install.log" || fail 'failed module missing from summary'
[[ -f "$PARALLEL_TMP/ended-kitty" ]] || fail 'other worker did not finish'
_sway98_test_restore
printf 'ok: failed worker releases lock and partial changes remain reversible\n'

# Exercise the admitted production modules, with offline Chicago95 stand-ins.
unset SWAY98_TEST_FAIL SWAY98_TEST_OVERLAP
export SWAY98_THEME_SRC="$PARALLEL_TMP/Chicago95"
for subtree in Theme/Chicago95 Icons/Chicago95 Cursors/Chicago95_Standard_Cursors; do
    mkdir -p -- "$SWAY98_THEME_SRC/$subtree"
    cp -a -- "$PARALLEL_TMP/assets/." "$SWAY98_THEME_SRC/$subtree/"
done
for ((run=0; run<2; run++)); do
    "$REPO_ROOT/install.sh" --yes --experimental-parallel 2 --modules theme,kitty,wofi,swaylock \
        >"$PARALLEL_TMP/real-modules.log" 2>&1 || { cat "$PARALLEL_TMP/real-modules.log"; fail 'production modules'; }
done
[[ -f "$HOME/.config/kitty/sway98-vga.conf" && -f "$HOME/.config/wofi/style.css" &&
   -f "$HOME/.config/swaylock/config" && -L "$HOME/.icons/Chicago95/link" ]] || fail 'production assets missing'
_sway98_test_restore
printf 'ok: production modules install/reinstall/uninstall with offline theme tree\n'
