#!/usr/bin/env bash
#
# sway98 — end-to-end check against a *real* Chicago95 checkout.
#
# tests/run-sandbox.sh uses a hand-built stub tree, which is too tidy: it has no
# symlinks and almost no depth. Run this before a release (or after touching the
# transaction layer) to verify a full install and rollback against the real
# upstream tree, in a throwaway $HOME.
#
#   SWAY98_THEME_SRC=/path/to/Chicago95 bash tests/verify-real-tree.sh
#
# Exit status is 0 only when the sandbox $HOME is identical, entry for entry,
# before and after the install/uninstall cycle.

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
theme_src="${SWAY98_THEME_SRC:-$repo_root/../Chicago95}"

if [[ ! -d "$theme_src/Theme/Chicago95" ]]; then
    echo "SKIP: no Chicago95 checkout at $theme_src" >&2
    echo "      clone it and set SWAY98_THEME_SRC, e.g." >&2
    echo "      git clone --depth 1 https://github.com/grassmunk/Chicago95 ~/Chicago95" >&2
    exit 0
fi

theme_src="$(realpath -e -- "$theme_src")"
if [[ ! -d "$repo_root/tests" || -L "$repo_root/tests" ]]; then
    echo 'FAIL real tree: tests must be a real directory in the checkout' >&2
    exit 1
fi
# Allocate a fresh directory and retain its diagnostics. Never remove or reuse
# an inherited path or the fixed directory left by earlier versions.
SANDBOX="$(mktemp -d -- "$repo_root/tests/sandbox-real.XXXXXX")"
printf 'real-tree sandbox and logs: %s\n' "$SANDBOX"

for override in "${!SWAY98_@}" "${!XDG_@}"; do
    unset "$override"
done
unset SWAYSOCK WAYLAND_DISPLAY DISPLAY DBUS_SESSION_BUS_ADDRESS XAUTHORITY SESSION_MANAGER
export SWAY98_ROOT="$repo_root"
export SWAY98_THEME_SRC="$theme_src"
export SWAY98_NO_GSETTINGS=1
export HOME="$SANDBOX/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$SANDBOX/state"
export XDG_CACHE_HOME="$SANDBOX/cache"
export XDG_RUNTIME_DIR="$SANDBOX/runtime"
export TMPDIR="$SANDBOX/tmp"
mkdir -p -- "$XDG_CONFIG_HOME/sway" "$TMPDIR"
install -d -m 0700 -- "$XDG_RUNTIME_DIR"
# shellcheck disable=SC2016  # sway variables, not shell ones
echo 'set $mod Mod4' >"$HOME/.config/sway/config"

snapshot() { find "$HOME" -mindepth 1 -not -path "$HOME/.cache*" | sort; }

snapshot >"$SANDBOX/before.txt"

MODULES="theme,sway,gtk,waybar,kitty,fonts"
if "$SWAY98_ROOT/install.sh" --yes --modules "$MODULES" >"$SANDBOX/install.log" 2>&1; then
    install_rc=0
else
    install_rc=1
fi
installed=$(find "$HOME" -type f -not -path "$HOME/.cache/*" | wc -l)

if "$SWAY98_ROOT/uninstall.sh" --yes >"$SANDBOX/uninstall.log" 2>&1; then
    uninstall_rc=0
else
    uninstall_rc=1
fi
snapshot >"$SANDBOX/after.txt"

printf 'install rc=%s (files installed: %s)\n' "$install_rc" "$installed"
printf 'uninstall rc=%s (entries left: %s)\n' "$uninstall_rc" "$(wc -l <"$SANDBOX/after.txt")"

if [[ "$install_rc" == "0" && "$uninstall_rc" == "0" ]] \
    && diff -q "$SANDBOX/before.txt" "$SANDBOX/after.txt" >/dev/null; then
    echo "ok   real tree: entry-for-entry identical after rollback"
    exit 0
fi

echo "FAIL real tree: rollback left something behind" >&2
diff "$SANDBOX/before.txt" "$SANDBOX/after.txt" | head -20 >&2 || true
exit 1
