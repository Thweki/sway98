#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata is read by the installer via lib/menu.sh
# shellcheck shell=bash
#
# mako — Win98 style notifications, started with the session.

SWAY98_MODULE_ID="mako"
SWAY98_MODULE_DESC="Win98 notification popups (mako) started with sway"
SWAY98_MODULE_SCOPE="user"
SWAY98_MODULE_RECOMMENDED="yes"
SWAY98_MODULE_REQUIRES="sway"
SWAY98_MODULE_NEEDS_PKGS="mako"

sway98_apply() {
    install_file "$SWAY98_ROOT/modules/mako/files/config" "$HOME/.config/mako/config"
    install_file "$SWAY98_ROOT/modules/mako/files/sway-fragment.conf" \
        "$HOME/.config/sway/conf.d/sway98.d/mako.conf"

    if is_running_sway && ! pgrep -x mako >/dev/null 2>&1; then
        info "start it now with: swaymsg exec mako"
    else
        info "test it with: notify-send hello"
    fi
}
