#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata is read by the installer via lib/menu.sh
# shellcheck shell=bash
#
# gtk — make GTK 3 and GTK 4 applications use Chicago95.
#
# Two mechanisms, because neither one alone is enough:
#   * settings.ini  — read by GTK itself, works for every toolkit build, and has
#                     to be set per GTK major version (3 and 4).
#   * gsettings     — the dconf keys that GNOME-ish toolkits and portals read.
#
# libadwaita applications ignore gtk-theme-name entirely; see README limitations.

SWAY98_MODULE_ID="gtk"
SWAY98_MODULE_DESC="GTK 3/4 theme, icons, cursors and fonts via settings.ini + gsettings"
SWAY98_MODULE_SCOPE="user"
SWAY98_MODULE_RECOMMENDED="yes"
SWAY98_MODULE_REQUIRES="theme"
SWAY98_MODULE_NEEDS_PKGS="gtk3 gtk4 gsettings-desktop-schemas"

sway98_apply() {
    local font cursor="Chicago 95 Standard" size=24
    font="$(pick_font "Liberation Sans" "DejaVu Sans" "Sans")"

    local version file
    for version in 3.0 4.0; do
        file="$HOME/.config/gtk-$version/settings.ini"
        ini_set "$file" "Settings" "gtk-theme-name" "Chicago95"
        ini_set "$file" "Settings" "gtk-icon-theme-name" "Chicago95"
        ini_set "$file" "Settings" "gtk-cursor-theme-name" "$cursor"
        ini_set "$file" "Settings" "gtk-cursor-theme-size" "$size"
        ini_set "$file" "Settings" "gtk-font-name" "$font 10"
        ini_set "$file" "Settings" "gtk-application-prefer-dark-theme" "false"
    done

    if have gsettings; then
        gsettings_set_if_changed org.gnome.desktop.interface gtk-theme "Chicago95"
        gsettings_set_if_changed org.gnome.desktop.interface icon-theme "Chicago95"
        gsettings_set_if_changed org.gnome.desktop.interface cursor-theme "$cursor"
        gsettings_set_if_changed org.gnome.desktop.interface cursor-size "$size"
        gsettings_set_if_changed org.gnome.desktop.interface font-name "$font 10"
        gsettings_set_if_changed org.gnome.desktop.interface color-scheme "default"
    fi

    info "restart GTK applications to see the change (GTK reads these only at startup)"
}
