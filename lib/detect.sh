#!/usr/bin/env bash
# shellcheck shell=bash
#
# sway98 — environment detection. All functions are side-effect free: they print a
# single value on stdout and never exit, so callers decide how to react.

# Package manager gate. The project targets Arch (and Arch derivatives, which all
# use pacman); anything else is refused by preflight.
detect_pkg_manager() {
    if have pacman; then
        printf 'pacman\n'
    else
        printf 'unknown\n'
    fi
}

detect_distro_id() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        ( . /etc/os-release; printf '%s\n' "${ID:-unknown}" )
    else
        printf 'unknown\n'
    fi
}

# wayland | x11 | tty | unknown
detect_session_type() {
    if [[ -n "${SWAYSOCK:-}" || "${XDG_CURRENT_DESKTOP:-}" == *sway* ]]; then
        printf 'sway\n'
    elif [[ -n "${WAYLAND_DISPLAY:-}" || "${XDG_SESSION_TYPE:-}" == wayland ]]; then
        printf 'wayland\n'
    elif [[ "${XDG_SESSION_TYPE:-}" == x11 ]]; then
        printf 'x11\n'
    else
        printf 'unknown\n'
    fi
}

# Returns 0 when the running compositor is sway (config reload/exec will work).
is_running_sway() { [[ -n "${SWAYSOCK:-}" ]]; }

sway_config_file() {
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/sway/config"
}

# There is deliberately no output/resolution detection: every module writes
# `output * ...` wildcards, so the installed configuration is resolution and
# output-name agnostic. Per-machine values stay in the user's own config.

# Swiss-army font probe: is a fontconfig family available?
has_font() {
    local family="$1"
    have fc-list || return 1
    fc-list --family 2>/dev/null | grep -qi -- "$family"
}

# Echo the first fontconfig family from a list that exists, or the first one.
pick_font() {
    local f
    for f in "$@"; do
        if has_font "$f"; then
            printf '%s\n' "$f"
            return 0
        fi
    done
    printf '%s\n' "$1"
}

# Print the subset of the given pacman packages that is NOT installed.
# Always exits 0: callers run it inside command substitutions under `set -e`,
# where a non-zero status would abort the installer (learned the hard way).
pacman_missing() {
    local out=() p
    for p in "$@"; do
        pacman -Qq -- "$p" >/dev/null 2>&1 || out+=("$p")
    done
    if ((${#out[@]})); then
        printf '%s\n' "${out[@]}"
    fi
    return 0
}

aur_helper() {
    if have paru; then printf 'paru\n'
    elif have yay; then printf 'yay\n'
    else printf '\n'
    fi
}

# Firefox profiles: native, Flatpak and Snap layouts. Prints "<profile-dir>" lines.
firefox_profiles() {
    local root ini dir
    for root in "$HOME/.mozilla/firefox" \
                "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox" \
                "$HOME/snap/firefox/common/.mozilla/firefox"; do
        [[ -d "$root" ]] || continue
        ini="$root/profiles.ini"
        if [[ -r "$ini" ]]; then
            while IFS= read -r dir; do
                [[ -d "$root/$dir" ]] && printf '%s\n' "$root/$dir"
            done < <(
                awk -F= '
                    /^\[Profile[0-9]+\]/ { path="" }
                    /^Path=/             { path=substr($0, 6) }
                    /^Default=1/         { if (path != "") print path }
                    END                  { if (path != "") print path }
                ' "$ini"
            )
        fi
        # Fall back to well-known directories when profiles.ini has no Default=1.
        if [[ -z "$(grep -c . "$ini" 2>/dev/null || true)" || ! -r "$ini" ]]; then
            for dir in "$root"/*.default "$root"/*.default-release; do
                [[ -d "$dir" ]] && printf '%s\n' "$dir"
            done
        fi
    done | sort -u
}
