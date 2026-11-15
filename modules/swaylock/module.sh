#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata is read by the installer via lib/menu.sh
# shellcheck shell=bash
#
# swaylock — Win98 coloured lock screen.

SWAY98_MODULE_ID="swaylock"
SWAY98_MODULE_DESC="Win98 coloured lock screen (swaylock)"
SWAY98_MODULE_SCOPE="user"
SWAY98_MODULE_RECOMMENDED="yes"
SWAY98_MODULE_REQUIRES=""
SWAY98_MODULE_NEEDS_PKGS="swaylock"

sway98_apply() {
    install_file "$SWAY98_ROOT/modules/swaylock/files/config" "$(sway98_config_home)/swaylock/config"
    info "lock your screen to see it: swaylock -f"
    info "no key binding is created on purpose; add one yourself, e.g."
    info "  bindsym \$mod+Escape exec swaylock -f"
}
