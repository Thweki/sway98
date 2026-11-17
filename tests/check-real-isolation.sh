#!/usr/bin/env bash
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fixtures="$tmp/repo"
theme="$tmp/theme"
host="$tmp/outside"
mkdir -p -- "$fixtures/tests/sandbox-real" "$theme/Theme/Chicago95" "$host"
cp -- "$repo/tests/verify-real-tree.sh" "$fixtures/tests/verify-real-tree.sh"
printf 'legacy\n' >"$fixtures/tests/sandbox-real/keep"
printf 'outside\n' >"$host/keep"
printf 'theme\n' >"$theme/keep"
mkdir -p -- "$tmp/bin"
for command in curl wget git swaymsg flatpak gsettings; do
    printf '#!/usr/bin/env bash\nexit 99\n' >"$tmp/bin/$command"
    chmod +x "$tmp/bin/$command"
done

# The harness sees a synthetic theme and stubs, never the actual installer
# or network. The stubs check only the environment they receive.
cat >"$fixtures/install.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
scratch="${HOME%/home}"
[[ "$HOME" == "$root/tests/sandbox-real."*/home ]]
[[ "$SWAY98_ROOT" == "$root" && -f "$SWAY98_THEME_SRC/keep" ]]
[[ "$SWAY98_NO_GSETTINGS" == 1 ]]
[[ "$XDG_CONFIG_HOME" == "$HOME/.config" && "$XDG_DATA_HOME" == "$HOME/.local/share" ]]
[[ "$XDG_STATE_HOME" == "$scratch/state" && "$XDG_CACHE_HOME" == "$scratch/cache" ]]
[[ "$XDG_RUNTIME_DIR" == "$scratch/runtime" && "$(stat -c '%a' "$XDG_RUNTIME_DIR")" == 700 ]]
[[ "$TMPDIR" == "$scratch/tmp" && -d "$TMPDIR" ]]
[[ -z "${SWAY98_REAL_SANDBOX+x}${SWAY98_LOG+x}${XDG_CONFIG_DIRS+x}${XDG_DATA_DIRS+x}" ]]
[[ -z "${SWAYSOCK+x}${WAYLAND_DISPLAY+x}${DISPLAY+x}${DBUS_SESSION_BUS_ADDRESS+x}${XAUTHORITY+x}${SESSION_MANAGER+x}" ]]
printf 'install isolated\n'
SH
cat >"$fixtures/uninstall.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ -f "${HOME%/home}/install.log" ]]
printf 'uninstall isolated\n'
SH
chmod +x -- "$fixtures/install.sh" "$fixtures/uninstall.sh"

run_harness() {
    env -i PATH="$tmp/bin:$PATH" HOME="$host" TMPDIR="$host" \
        SWAY98_ROOT="$host" SWAY98_THEME_SRC="$1" SWAY98_REAL_SANDBOX="$host" SWAY98_LOG="$host/keep" \
        XDG_CONFIG_HOME="$host" XDG_DATA_HOME="$host" XDG_STATE_HOME="$host" XDG_CACHE_HOME="$host" \
        XDG_RUNTIME_DIR="$host" XDG_CONFIG_DIRS="$host" XDG_DATA_DIRS="$host" SWAYSOCK="$host/socket" \
        WAYLAND_DISPLAY=fixture DISPLAY=:99 DBUS_SESSION_BUS_ADDRESS=fixture XAUTHORITY="$host" SESSION_MANAGER=fixture \
        bash "$fixtures/tests/verify-real-tree.sh"
}
run_harness "$tmp/no-theme" >"$tmp/skip" 2>&1
grep -q 'SKIP: no Chicago95 checkout' "$tmp/skip"
[[ -z "$(find "$fixtures/tests" -maxdepth 1 -type d -name 'sandbox-real.*' -print -quit)" ]]

for run in first second; do
    run_harness "$theme" >"$tmp/$run" 2>&1
    grep -q 'entry-for-entry identical' "$tmp/$run"
    path="$(sed -n 's/^real-tree sandbox and logs: //p' "$tmp/$run")"
    [[ "$path" == "$fixtures/tests/sandbox-real."* ]]
    grep -qx 'install isolated' "$path/install.log"
    grep -qx 'uninstall isolated' "$path/uninstall.log"
done
[[ "$(find "$fixtures/tests" -maxdepth 1 -type d -name 'sandbox-real.*' | wc -l)" == 2 ]]
[[ "$(cat "$fixtures/tests/sandbox-real/keep")" == legacy ]]
[[ "$(cat "$host/keep")" == outside && "$(cat "$theme/keep")" == theme ]]
[[ "$(find "$host" -mindepth 1 -maxdepth 1 | wc -l)" == 1 ]]
printf 'ok: real-tree harness uses fresh isolated paths and preserves logs without touching outside paths\n'
