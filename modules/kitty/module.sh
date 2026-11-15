#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata is read by the installer via lib/menu.sh
# shellcheck shell=bash
#
# kitty — VGA 16-colour palette for the terminal.

SWAY98_MODULE_ID="kitty"
SWAY98_MODULE_DESC="DOS/VGA 16-colour palette for the kitty terminal"
SWAY98_MODULE_SCOPE="user"
SWAY98_MODULE_RECOMMENDED="yes"
SWAY98_MODULE_REQUIRES=""
SWAY98_MODULE_NEEDS_PKGS="kitty"

sway98_apply() {
    local dir="$(sway98_config_home)/kitty"

    install_file "$SWAY98_ROOT/modules/kitty/files/vga-palette.conf" "$dir/sway98-vga.conf"

    # An absolute path in the include keeps this working regardless of how kitty
    # resolves relative includes.
    include_block "$dir/kitty.conf" "sway98" "include $dir/sway98-vga.conf"

    info "colours apply to newly opened kitty windows"
}
