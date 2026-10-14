#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata is read by the installer via lib/menu.sh
# shellcheck shell=bash
#
# waybar — a Windows 98 taskbar along the bottom edge.

SWAY98_MODULE_ID="waybar"
SWAY98_MODULE_DESC="Win98 taskbar: workspaces, tray, clock (bottom edge)"
SWAY98_MODULE_SCOPE="user"
SWAY98_MODULE_RECOMMENDED="yes"
SWAY98_MODULE_REQUIRES="sway"
SWAY98_MODULE_NEEDS_PKGS="waybar ttf-jetbrains-mono-nerd"

sway98_apply() {
    local cfg="$HOME/.config/waybar"

    install_file "$SWAY98_ROOT/modules/waybar/files/config" "$cfg/config"
    install_file "$SWAY98_ROOT/modules/waybar/files/style.css" "$cfg/style.css"

    # Start it with the session. The fragment is picked up by sway98.conf.
    install_file "$SWAY98_ROOT/modules/waybar/files/sway-fragment.conf" \
        "$HOME/.config/sway/conf.d/sway98.d/waybar.conf"

    if ! has_font "JetBrainsMono Nerd Font"; then
        warn "no Nerd Font installed: the taskbar icons will render as boxes"
        warn "fix it with: sudo pacman -S ttf-jetbrains-mono-nerd"
    fi

    if is_running_sway && ! pgrep -x waybar >/dev/null 2>&1; then
        info "start the taskbar now with: swaymsg exec waybar"
    fi
}
