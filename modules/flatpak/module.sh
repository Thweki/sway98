#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata is read by the installer via lib/menu.sh
# shellcheck shell=bash
#
# flatpak — let sandboxed applications see the theme.
#
# Flatpak applications only see ~/.themes and ~/.icons if the sandbox is told
# about them; without this, GTK apps installed as Flatpaks stay on Adwaita while
# everything else is Chicago95.

SWAY98_MODULE_ID="flatpak"
SWAY98_MODULE_DESC="Expose ~/.themes and ~/.icons to Flatpak applications"
SWAY98_MODULE_SCOPE="user"
SWAY98_MODULE_RECOMMENDED="no"
SWAY98_MODULE_REQUIRES="theme"
SWAY98_MODULE_NEEDS_PKGS="flatpak"

sway98_apply() {
    if ! have flatpak; then
        warn "flatpak is not installed; skipping"
        return 0
    fi

    local path
    for path in "$HOME/.themes" "$HOME/.icons"; do
        if flatpak override --user --show 2>/dev/null | grep -qF "$path"; then
            info "already visible to Flatpak applications: $path"
            continue
        fi
        if is_dry_run; then
            dry "flatpak override --user --filesystem=$path:ro"
            continue
        fi
        flatpak override --user --filesystem="$path:ro"
        record_cmd_argv flatpak override --user "--nofilesystem=$path"
        ok "shared read-only with Flatpak applications: $path"
    done

    info "for GTK3 runtime theming you can also install the published theme:"
    info "  flatpak install flathub org.gtk.Gtk3theme.Chicago95"
    info "restart Flatpak applications to see the change"
}
