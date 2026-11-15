#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata is read by the installer via lib/menu.sh
# shellcheck shell=bash
#
# sounds — Windows 98 system sounds.
#
# The sound files themselves are Microsoft copyright and are NOT distributed with
# this project. The installer only knows their address and checksum; downloading
# happens here, on the user's machine, on request. See AGENTS.md section 6 and
# CREDITS.md.

SWAY98_MODULE_ID="sounds"
SWAY98_MODULE_DESC="Windows 98 system sounds, downloaded from archive.org on request"
SWAY98_MODULE_SCOPE="user"
SWAY98_MODULE_RECOMMENDED="no"
SWAY98_MODULE_REQUIRES=""
SWAY98_MODULE_NEEDS_PKGS="libcanberra sound-theme-freedesktop pipewire-audio"

sway98_apply() {
    local data="${XDG_DATA_HOME:-$HOME/.local/share}"
    local theme_dir="$data/sounds/sway98"
    local cache="$SWAY98_STATE/sounds-src"
    local sources="$SWAY98_ROOT/modules/sounds/sources.tsv"
    local name item path sha1 missing=0

    while IFS=$'\t' read -r name item path sha1; do
        [[ -n "${name:-}" && "$name" != \#* ]] || continue
        [[ -f "$cache/$name.wav" ]] || missing=$((missing + 1))
    done <"$sources"

    if ((missing > 0)); then
        info "$missing of the Windows 98 sound files are not downloaded yet"
        if confirm "download them from archive.org now? (Microsoft copyright, stored only on this machine)"; then
            "$SWAY98_ROOT/modules/sounds/fetch-ms-sounds.sh" "$cache"
        else
            info "skipped: no sound files downloaded, nothing installed"
            return 0
        fi
    fi

    while IFS=$'\t' read -r name item path sha1; do
        [[ -n "${name:-}" && "$name" != \#* ]] || continue
        if [[ ! -f "$cache/$name.wav" ]]; then
            warn "missing $name.wav, skipping"
            continue
        fi
        install_file "$cache/$name.wav" "$theme_dir/stereo/$name.wav"
    done <"$sources"

    install_file "$SWAY98_ROOT/modules/sounds/files/index.theme" "$theme_dir/index.theme"

    # Tell libcanberra-based applications to use the theme.
    gsettings_set_if_changed org.gnome.desktop.sound theme "sway98"

    # Login sound: pick whichever player is installed, and only wire it up when
    # the file really exists. (The is_dry_run test has to stay outside [[ ]]:
    # inside it a bare word is a string, not a function call.)
    local player="" have_sound=0
    for candidate in pw-play paplay aplay canberra-gtk-play; do
        if have "$candidate"; then player="$candidate"; break; fi
    done
    if [[ -f "$theme_dir/stereo/desktop-login.wav" ]] || is_dry_run; then
        have_sound=1
    fi
    if [[ -n "$player" && "$have_sound" == "1" ]]; then
        if [[ "$player" == "canberra-gtk-play" ]]; then
            template_render "$SWAY98_ROOT/modules/sounds/files/sway-fragment.conf.in" \
                "$(sway98_config_home)/sway/conf.d/sway98.d/sounds.conf" \
                "LOGIN_CMD=canberra-gtk-play -i desktop-login"
        else
            template_render "$SWAY98_ROOT/modules/sounds/files/sway-fragment.conf.in" \
                "$(sway98_config_home)/sway/conf.d/sway98.d/sounds.conf" \
                "LOGIN_CMD=$player $theme_dir/stereo/desktop-login.wav"
        fi
    else
        warn "no audio player found (pw-play/paplay/aplay); the login sound is not wired up"
    fi

    info "GTK applications pick the theme up on restart; uninstall removes the files again"
}
