#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata is read by the installer via lib/menu.sh
# shellcheck shell=bash
#
# fonts — the bitmap and VGA fonts that come with Chicago95.

SWAY98_MODULE_ID="fonts"
SWAY98_MODULE_DESC="DOS/VGA fonts bundled with Chicago95"
SWAY98_MODULE_SCOPE="user"
SWAY98_MODULE_RECOMMENDED="no"
SWAY98_MODULE_REQUIRES="theme"
SWAY98_MODULE_NEEDS_PKGS="fontconfig"

sway98_apply() {
    ensure_chicago95

    local dir="$HOME/.local/share/fonts/sway98"

    if [[ ! -d "$SWAY98_THEME_SRC/Fonts" ]]; then
        if is_dry_run; then
            dry "would install Chicago95 VGA fonts into $dir"
            return 0
        fi
        die "Chicago95 sources are missing at $SWAY98_THEME_SRC"
    fi

    install_dir "$SWAY98_THEME_SRC/Fonts/vga_font" "$dir"
    install_dir "$SWAY98_THEME_SRC/Fonts/bitmap/cronyx-cyrillic" "$dir/cronyx-cyrillic"

    if have fc-cache; then
        if is_dry_run; then
            dry "fc-cache -f"
        else
            fc-cache -f >/dev/null || warn "fc-cache reported an error; fonts may still work after a re-login"
            record_cmd "fc-cache -f"
        fi
    else
        warn "fc-cache not found; run it manually so the fonts become available"
    fi

    info "the VGA fonts are meant for terminals (kitty: font_family LessPerfectDOSVGA)"
}
