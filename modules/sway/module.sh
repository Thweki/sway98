#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata is read by the installer via lib/menu.sh
# shellcheck shell=bash
#
# sway — Windows 98 window decorations, cursor and desktop colour.

SWAY98_MODULE_ID="sway"
SWAY98_MODULE_DESC="Win98 window titles, borders, cursor and teal desktop"
SWAY98_MODULE_SCOPE="user"
SWAY98_MODULE_RECOMMENDED="yes"
SWAY98_MODULE_REQUIRES="theme"
SWAY98_MODULE_NEEDS_PKGS="sway"

sway98_apply() {
    local confdir="$HOME/.config/sway/conf.d"
    local main; main="$(sway_config_file)"
    local font

    font="$(pick_font "Liberation Sans" "DejaVu Sans" "Sans")"
    info "sway decoration font: $font"

    template_render "$SWAY98_ROOT/modules/sway/files/sway98.conf" \
        "$confdir/sway98.conf" "FONT=$font"

    # Keep the fragment directory present so the glob include always matches.
    install_file "$SWAY98_ROOT/modules/sway/files/00-README.conf" \
        "$confdir/sway98.d/00-README.conf"

    if [[ -f "$main" ]]; then
        include_block "$main" "sway98" "include $confdir/sway98.conf"
    else
        warn "no sway config at $main yet"
        warn "after starting sway once, re-run: ./install.sh --only sway"
        warn "or add this line to the end of your sway config:"
        printf '    include %s/sway98.conf\n' "$confdir" >&2
    fi

    if is_running_sway; then
        info "reload the running session to see it: swaymsg reload"
    fi
}
