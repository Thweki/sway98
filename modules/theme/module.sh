#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata is read by the installer via lib/menu.sh
# shellcheck shell=bash
#
# theme — Chicago95 GTK theme, icon theme and Win95 cursors.

SWAY98_MODULE_ID="theme"
SWAY98_MODULE_DESC="Chicago95 GTK theme, icon theme and Win95 cursors"
SWAY98_MODULE_SCOPE="user"
SWAY98_MODULE_RECOMMENDED="yes"
SWAY98_MODULE_REQUIRES=""
SWAY98_MODULE_NEEDS_PKGS="gtk3 gtk4"

sway98_apply() {
    ensure_chicago95

    local themes="$HOME/.themes" icons="$HOME/.icons"

    if [[ ! -d "$SWAY98_THEME_SRC/Theme/Chicago95" ]]; then
        if is_dry_run; then
            dry "would install Chicago95 into $themes/Chicago95 and $icons/{Chicago95,Chicago95-cursors}"
            return 0
        fi
        die "Chicago95 sources are missing at $SWAY98_THEME_SRC"
    fi

    install_dir "$SWAY98_THEME_SRC/Theme/Chicago95" "$themes/Chicago95"
    install_dir "$SWAY98_THEME_SRC/Icons/Chicago95" "$icons/Chicago95"

    # The cursor theme directory name is arbitrary; the theme name apps use comes
    # from index.theme ("Chicago 95 Standard").
    install_dir "$SWAY98_THEME_SRC/Cursors/Chicago95_Standard_Cursors" "$icons/Chicago95-cursors"

    ok "Chicago95 installed: $themes/Chicago95, $icons/Chicago95, $icons/Chicago95-cursors"
    info "GTK apps pick this up after a restart; the 'gtk' module sets it as the default."
}
