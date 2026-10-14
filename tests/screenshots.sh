#!/usr/bin/env bash
#
# sway98 — generate the README screenshots.
#
# The screenshots are produced in a *throwaway* headless sway session, never on
# the machine's own desktop: a private XDG_RUNTIME_DIR (own Wayland socket),
# a private D-Bus session (notifications cannot escape onto the real desktop)
# and a private XDG_CONFIG_HOME, which is populated from the module assets in
# this repository. The pictures therefore show what sway98 ships, not whatever
# the developer happens to have configured.
#
#   tests/screenshots.sh                          # writes docs/screenshots/*.png
#   SWAY98_SHOT_RES=1920x1200 tests/screenshots.sh
#
# Requires: sway, waybar, kitty, thunar, mako, wofi, grim, jq, notify-send.
#
# Two traps this script exists to avoid, both found the hard way:
#   * swaymsg ignores XDG_RUNTIME_DIR and its socket discovery can reach the
#     *user's real session* — it needs SWAYSOCK pointing at the sandbox socket,
#     and we abort unless the session we reached reports a HEADLESS-* output.
#   * wlroots names the headless socket wayland-1 regardless of WAYLAND_DISPLAY,
#     so the socket name is discovered after startup and exported to clients.

set -euo pipefail

SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$SWAY98_ROOT/docs/screenshots"
RES="${SWAY98_SHOT_RES:-1600x1000}"

# Hermetic D-Bus session. The check must not be "is DBUS_SESSION_BUS_ADDRESS
# set" — the caller's shell always has one (the real session), and then mako
# would fail with "Failed to acquire service name: File exists" because the real
# notification daemon already owns the name. A marker variable is the only
# reliable way to know we are already inside our own bus.
if [[ -z "${SWAY98_SHOTS_INNER:-}" ]]; then
    export SWAY98_SHOTS_INNER=1
    exec dbus-run-session -- "$0" "$@"
fi

missing=()
for c in sway swaymsg waybar kitty thunar mako wofi grim jq notify-send; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
((${#missing[@]} == 0)) || { echo "missing tools: ${missing[*]}" >&2; exit 1; }

RT="$(mktemp -d)"
CFG="$(mktemp -d)"
TMP="$(mktemp -d)"
SWAY_PID=""
CLIENT_PIDS=()

cleanup() {
    local pid
    for pid in ${CLIENT_PIDS[@]+"${CLIENT_PIDS[@]}"}; do
        kill "$pid" 2>/dev/null || true
    done
    if [[ -n "$SWAY_PID" ]]; then
        pkill -P "$SWAY_PID" 2>/dev/null || true
        kill "$SWAY_PID" 2>/dev/null || true
        wait "$SWAY_PID" 2>/dev/null || true
    fi
    # Safety net: anything still carrying our private runtime dir would fight the
    # real session over the notification bus on the next run.
    local leaked=0
    for pid in /proc/[0-9]*; do
        pid="${pid#/proc/}"
        # /proc/<pid>/environ is unreadable for processes that cleared their
        # dumpable flag; the subshell keeps the shell's own error quiet.
        if (tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -q "XDG_RUNTIME_DIR=$RT") 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            leaked=$((leaked + 1))
        fi
    done
    ((leaked == 0)) || echo "warn: killed $leaked leftover process(es)" >&2
    rm -rf "$RT" "$CFG" "$TMP"
}
trap cleanup EXIT

# --- private environment ------------------------------------------------------
export XDG_RUNTIME_DIR="$RT"
export XDG_CONFIG_HOME="$CFG"
export XCURSOR_THEME="Chicago 95 Standard"
export XCURSOR_SIZE=24
export GTK_THEME=Chicago95
export WLR_BACKENDS=headless
export WLR_LIBINPUT_NO_DEVICES=1
unset WAYLAND_DISPLAY SWAYSOCK DISPLAY

install_assets() {
    mkdir -p "$CFG/waybar" "$CFG/mako" "$CFG/kitty" "$CFG/wofi"
    # The shipped Waybar config shows the Wi-Fi SSID in its network cell. These
    # pictures go on the public internet, so the author's network name is
    # replaced by the signal strength; everything else is exactly what the
    # module installs.
    jq '.network["format-wifi"] = "{signalStrength}%"' \
        "$SWAY98_ROOT/modules/waybar/files/config" >"$CFG/waybar/config"
    cp "$SWAY98_ROOT/modules/waybar/files/style.css" "$CFG/waybar/style.css"
    cp "$SWAY98_ROOT/modules/mako/files/config" "$CFG/mako/config"
    cp "$SWAY98_ROOT/modules/wofi/files/style.css" "$CFG/wofi/style.css"
    {
        cat "$SWAY98_ROOT/modules/kitty/files/vga-palette.conf"
        echo "window_padding_width 14"
        echo "font_size 12.0"
    } >"$CFG/kitty/kitty.conf"
}

write_sway_config() {
    cat >"$TMP/sway.conf" <<'EOF'
# Minimal session used only to render screenshots; daemons are started by the
# calling script so that they inherit the correct socket environment.
output * bg #008080 solid_color
font pango:Liberation Sans Bold 9
default_border normal 3
default_floating_border normal 3
client.focused          #c0c0c0 #000080 #ffffff #c0c0c0 #c0c0c0
client.focused_inactive #c0c0c0 #808080 #c0c0c0 #c0c0c0 #c0c0c0
client.unfocused        #c0c0c0 #808080 #c0c0c0 #c0c0c0 #c0c0c0
client.urgent           #c0c0c0 #800000 #ffffff #c0c0c0 #c0c0c0
seat * xcursor_theme "Chicago 95 Standard" 24
EOF
}

wait_for() {  # wait_for <description> <command...>
    local desc="$1"; shift
    local i
    for ((i = 0; i < 80; i++)); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 0.25
    done
    echo "timed out waiting for $desc" >&2
    return 1
}

# True when at least one path matches the given pattern. The unquoted expansion
# is the point: it is a glob, not a path.
any_glob() {
    local f
    # shellcheck disable=SC2086
    for f in $1; do
        [[ -e "$f" || -S "$f" ]] && return 0
    done
    return 1
}

shot() {  # shot <name>
    local name="$1"
    mkdir -p "$OUT_DIR"
    grim -o "$OUTPUT" "$OUT_DIR/$name.png"
    echo "wrote docs/screenshots/$name.png"
}

start_session() {
    sway -c "$TMP/sway.conf" >"$TMP/sway.log" 2>&1 &
    SWAY_PID=$!

    wait_for "headless wayland socket" any_glob "$RT/wayland-*"
    wait_for "headless sway ipc socket" any_glob "$RT/sway-ipc.*.sock"

    # wlroots chooses the socket name itself (wayland-1 for a fresh runtime dir),
    # so both names are discovered rather than assumed.
    local sock
    for sock in "$RT"/wayland-*; do
        [[ "$sock" =~ ^.*/wayland-[0-9]+$ ]] || continue
        WAYLAND_DISPLAY="${sock##*/}"
        break
    done
    for sock in "$RT"/sway-ipc.*.sock; do
        [[ -S "$sock" ]] || continue
        SWAYSOCK="$sock"
        break
    done
    [[ -n "${WAYLAND_DISPLAY:-}" && -n "${SWAYSOCK:-}" ]] \
        || { echo "could not discover the sandbox sockets in $RT" >&2; exit 1; }
    export WAYLAND_DISPLAY SWAYSOCK

    wait_for "sway ipc" swaymsg -t get_version

    OUTPUT="$(swaymsg -t get_outputs | jq -r '.[0].name')"
    case "$OUTPUT" in
        HEADLESS-*)
            ;;
        *)
            echo "refusing to continue: swaymsg reached '$OUTPUT', not the sandbox session" >&2
            exit 1
            ;;
    esac
    swaymsg output "$OUTPUT" resolution "$RES" >/dev/null
}

main() {
    install_assets
    write_sway_config
    start_session

    waybar >"$TMP/waybar.log" 2>&1 &
    CLIENT_PIDS+=("$!")
    mako >"$TMP/mako.log" 2>&1 &
    CLIENT_PIDS+=("$!")

    # mako has to own the notification name on *our* bus before it can draw
    # anything; without this check the notification screenshot silently ends up
    # identical to the desktop one.
    if wait_for "mako to own org.freedesktop.Notifications" \
        dbus-send --session --print-reply --dest=org.freedesktop.DBus \
        /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
        string:org.freedesktop.Notifications \
        ; then
        :
    else
        echo "warning: mako did not take the notification name" >&2
        cat "$TMP/mako.log" >&2 || true
    fi
    sleep 1.5

    # Left: the terminal with the VGA palette this project installs.
    kitty --title sway98 --hold -d "$SWAY98_ROOT" \
        -e ./install.sh --list >/dev/null 2>&1 &
    CLIENT_PIDS+=("$!")
    sleep 2.5

    # Right: a GTK application, showing theme and icon theme.
    swaymsg split h >/dev/null
    thunar "$SWAY98_ROOT/docs" >/dev/null 2>&1 &
    CLIENT_PIDS+=("$!")
    sleep 2.5
    # Give the terminal the wider half: the installer's module table is long.
    swaymsg resize set width 34 ppt >/dev/null 2>&1 || true
    sleep 1

    shot desktop

    notify-send -a sway98 -i dialog-information \
        "sway98" "Windows 98 look for Arch Linux + Sway" >/dev/null 2>&1 || true
    sleep 1.5
    shot notification

    swaymsg 'exec wofi --show drun' >/dev/null 2>&1 || true
    sleep 2.5
    shot launcher
    pkill -f "wofi --show drun" 2>/dev/null || true
}

main "$@"
