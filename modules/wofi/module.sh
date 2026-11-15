#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata is read by the installer via lib/menu.sh
# shellcheck shell=bash
#
# wofi — Win98 skin for the application launcher.

SWAY98_MODULE_ID="wofi"
SWAY98_MODULE_DESC="Win98 skin for the wofi launcher"
SWAY98_MODULE_SCOPE="user"
SWAY98_MODULE_RECOMMENDED="yes"
SWAY98_MODULE_REQUIRES=""
SWAY98_MODULE_NEEDS_PKGS="wofi"

sway98_apply() {
    install_file "$SWAY98_ROOT/modules/wofi/files/style.css" "$(sway98_config_home)/wofi/style.css"
    info "open the launcher to see it (normally Mod+d)"
}
