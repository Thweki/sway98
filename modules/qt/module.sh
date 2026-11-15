#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata is read by the installer via lib/menu.sh
# shellcheck shell=bash
#
# qt — make Qt applications follow the GTK theme.
#
# qt5-base and qt6-base both ship a "gtk3" platform theme, so a single
# environment variable covers Qt 5 and Qt 6 without going through qt5ct/qt6ct
# (whose settings are per Qt version and don't talk to each other). Measured
# result: Qt apps get Chicago95 widgets and icons.
#
# The variable has to be in the environment before the application starts, which
# is why it is written in two places: environment.d (systemd-managed sessions)
# and optionally ~/.profile (sway started from a TTY).

SWAY98_MODULE_ID="qt"
SWAY98_MODULE_DESC="Qt5/Qt6 applications follow the GTK3 (Chicago95) theme"
SWAY98_MODULE_SCOPE="user"
SWAY98_MODULE_RECOMMENDED="yes"
SWAY98_MODULE_REQUIRES="gtk"
SWAY98_MODULE_NEEDS_PKGS="qt5-base qt6-base gtk3"

sway98_apply() {
    install_file "$SWAY98_ROOT/modules/qt/files/environment.d.conf" \
        "$(sway98_config_home)/environment.d/90-sway98-qt.conf"

    # Colour scheme for people who already run qt5ct/qt6ct: upstream ships one
    # that matches the GTK theme exactly.
    local version dir
    for version in 5 6; do
        dir="$(sway98_config_home)/qt${version}ct"
        if [[ -d "$dir" ]]; then
            if [[ -f "$SWAY98_THEME_SRC/Extras/Chicago95_qt.conf" ]]; then
                install_file "$SWAY98_THEME_SRC/Extras/Chicago95_qt.conf" "$dir/colors/sway98.conf"
                ini_set "$dir/qt${version}ct.conf" "Appearance" "color_scheme_path" "$dir/colors/sway98.conf"
                ini_set "$dir/qt${version}ct.conf" "Appearance" "custom_palette" "false"
            else
                warn "qt${version}ct is configured but the Chicago95 sources are missing; skipped"
            fi
        fi
    done

    # Sway started from a TTY does not read environment.d at all.
    local profile="$HOME/.profile"
    if [[ -f "$profile" ]] && ! grep -q 'QT_QPA_PLATFORMTHEME' "$profile"; then
        if confirm "also export QT_QPA_PLATFORMTHEME from ~/.profile? (needed when sway is started from a TTY)"; then
            include_block "$profile" "sway98-qt" "export QT_QPA_PLATFORMTHEME=gtk3"
        fi
    fi

    info "log out and back in for the variable to reach already-running sessions"
    info "check with: QT_QPA_PLATFORMTHEME=gtk3 <qt app>  (e.g. pcmanfm-qt, qbittorrent)"
}
