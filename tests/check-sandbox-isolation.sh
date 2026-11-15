#!/usr/bin/env bash
set -euo pipefail

# Exercise both harnesses with hostile inherited paths, without a desktop or
# network. Copy the code so failure injection cannot damage the working tree.
SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
REPO="$WORK/repo"
OUTSIDE="$WORK/outside"
mkdir -p -- "$REPO/tests" "$WORK/bin" "$OUTSIDE/config/sway"
cp -a -- "$SWAY98_ROOT/lib" "$SWAY98_ROOT/modules" "$REPO/"
cp -a -- "$SWAY98_ROOT/install.sh" "$SWAY98_ROOT/uninstall.sh" "$REPO/"
cp -a -- "$SWAY98_ROOT/tests/run-sandbox.sh" \
    "$SWAY98_ROOT/tests/verify-real-tree.sh" \
    "$SWAY98_ROOT/tests/sandbox-env.sh" "$REPO/tests/"

for sentinel_dir in home data state cache override-state logs delete-target theme; do
    mkdir -p -- "$OUTSIDE/$sentinel_dir"
    printf 'outside sentinel\n' >"$OUTSIDE/$sentinel_dir/sentinel"
done
# shellcheck disable=SC2016  # Sway variable, not a shell variable.
printf 'set $mod Mod4\n# outside sway config\n' >"$OUTSIDE/config/sway/config"

# Include metadata so even an edit restored by uninstall is detected. Ignore
# access times, which can change merely from reading the sentinel files.
snapshot_outside() {
    (
        cd -- "$OUTSIDE"
        find . -printf '%P\t%y\t%m\t%T@\t%C@\t%l\n' | sort
        find . -type f -exec sha256sum -- {} + | sort
    )
}
snapshot_outside >"$WORK/outside.before"

# Unexpected network/desktop calls fail the test, even if a module ignores the
# command's status. Font cache work is stubbed to keep this regression offline.
cat >"$WORK/bin/guard" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${0##*/}" != fc-cache || -n "${SWAY98_UNTRUSTED+x}" \
    || -n "${SWAYSOCK+x}" || -n "${WAYLAND_DISPLAY+x}" \
    || "$XDG_CONFIG_HOME" != "$HOME/.config" \
    || "$XDG_DATA_HOME" != "$HOME/.local/share" \
    || "$XDG_STATE_HOME" != "${HOME%/home}/state" \
    || "$XDG_CACHE_HOME" != "${HOME%/home}/cache" ]]; then
    printf '%s\n' "${0##*/}" >>"$ISOLATION_UNEXPECTED"
    exit 97
fi
EOF
chmod +x "$WORK/bin/guard"
for guarded_cmd in curl git gsettings swaymsg fc-cache; do
    ln -s guard "$WORK/bin/$guarded_cmd"
done

run_case() {
    local expected_rc="$1" label="$2" source_tree="$3" actual_rc=0
    shift 3
    (
        export HOME="$OUTSIDE/home"
        export XDG_CONFIG_HOME="$OUTSIDE/config"
        export XDG_DATA_HOME="$OUTSIDE/data"
        export XDG_STATE_HOME="$OUTSIDE/state"
        export XDG_CACHE_HOME="$OUTSIDE/cache"
        export SWAY98_STATE="$OUTSIDE/override-state"
        export SWAY98_LOG="$OUTSIDE/logs/sentinel"
        export SWAY98_REAL_SANDBOX="$OUTSIDE/delete-target"
        export SWAY98_THEME_SRC="$source_tree"
        export SWAY98_TS=inherited-timestamp
        export SWAY98_DRY_RUN=0 SWAY98_SYSTEM=1 SWAY98_NO_GSETTINGS=0
        export SWAY98_BLOCK_PREFIX=// SWAY98_UNTRUSTED=1
        export SWAYSOCK="$OUTSIDE/sway.sock" WAYLAND_DISPLAY=outside-wayland
        export PATH="$WORK/bin:$PATH"
        export ISOLATION_UNEXPECTED="$WORK/unexpected"
        "$@"
    ) >"$WORK/case.log" 2>&1 || actual_rc=$?

    snapshot_outside >"$WORK/outside.after"
    if ! cmp -s -- "$WORK/outside.before" "$WORK/outside.after"; then
        echo "FAIL $label: an outside sentinel was touched" >&2
        diff -u "$WORK/outside.before" "$WORK/outside.after" >&2 || true
        exit 1
    fi
    if [[ -e "$WORK/unexpected" ]]; then
        echo "FAIL $label: unexpected network/desktop call or inherited override" >&2
        cat "$WORK/unexpected" >&2
        exit 1
    fi
    if [[ "$actual_rc" != "$expected_rc" ]]; then
        cat "$WORK/case.log" >&2
        echo "FAIL $label: expected exit $expected_rc, got $actual_rc" >&2
        exit 1
    fi
    echo "ok   isolation: $label (outside sentinels unchanged)"
}

run_case 0 dry-run "$OUTSIDE/theme" "$REPO/tests/run-sandbox.sh" dry-run
run_case 0 roundtrip "$OUTSIDE/theme" "$REPO/tests/run-sandbox.sh" roundtrip
run_case 0 inherited-dry-run "$OUTSIDE/theme" env SWAY98_DRY_RUN=1 \
    "$REPO/tests/run-sandbox.sh" roundtrip

# Reuse the local stub as the documented real-tree source: no download needed.
cp -a -- "$REPO/tests/sandbox/Chicago95" "$WORK/source"
run_case 0 real-tree "$WORK/source" "$REPO/tests/verify-real-tree.sh"
run_case 0 real-tree-skip "$WORK/missing-source" "$REPO/tests/verify-real-tree.sh"
grep -q 'SKIP: no Chicago95 checkout' "$WORK/case.log"

# A missing asset fails after Sway has been installed. The roundtrip harness
# stops there; the real-tree harness still attempts rollback. Guard both exits.
rm -- "$REPO/modules/kitty/files/vga-palette.conf"
run_case 1 roundtrip-failure "$OUTSIDE/theme" "$REPO/tests/run-sandbox.sh" roundtrip
grep -q 'source does not exist:' "$REPO/tests/sandbox/install.log"
grep -Fq "modified: $REPO/tests/sandbox/home/.config/sway/config" "$REPO/tests/sandbox/install.log"
run_case 1 real-tree-failure "$WORK/source" "$REPO/tests/verify-real-tree.sh"
grep -q 'source does not exist:' "$REPO/tests/sandbox-real/install.log"
grep -Fq "modified: $REPO/tests/sandbox-real/home/.config/sway/config" "$REPO/tests/sandbox-real/install.log"
