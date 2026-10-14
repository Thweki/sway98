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

set -uo pipefail

SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="${SWAY98_REAL_SANDBOX:-$SWAY98_ROOT/tests/sandbox-real}"

export HOME="$SANDBOX/home"
export XDG_STATE_HOME="$SANDBOX/state"
export XDG_CACHE_HOME="$SANDBOX/cache"
export SWAY98_NO_GSETTINGS=1
export SWAY98_THEME_SRC="${SWAY98_THEME_SRC:-$SWAY98_ROOT/../Chicago95}"

if [[ ! -d "$SWAY98_THEME_SRC/Theme/Chicago95" ]]; then
    echo "SKIP: no Chicago95 checkout at $SWAY98_THEME_SRC" >&2
    echo "      clone it and set SWAY98_THEME_SRC, e.g." >&2
    echo "      git clone --depth 1 https://github.com/grassmunk/Chicago95 ~/Chicago95" >&2
    exit 0
fi

rm -rf "$SANDBOX"
mkdir -p "$HOME/.config/sway"
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
diff "$SANDBOX/before.txt" "$SANDBOX/after.txt" | head -20 >&2
exit 1
