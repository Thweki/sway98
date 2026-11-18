#!/usr/bin/env bash
set -euo pipefail

# Use only synthetic settings/Flatpak tools, no live desktop or install state.
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home with spaces"
export SWAY98_STATE="$tmp/state" SWAY98_ROOT="$root" SWAY98_TS=fixture
export SWAY98_LOG="" SWAY98_DRY_RUN=0 SWAY98_NO_GSETTINGS=0
mkdir -- "$HOME"

# shellcheck source=lib/common.sh
. "$root/lib/common.sh"
# shellcheck source=lib/manifest.sh
. "$root/lib/manifest.sh"
# shellcheck source=lib/edit.sh
. "$root/lib/edit.sh"
# shellcheck source=modules/flatpak/module.sh
. "$root/modules/flatpak/module.sh"

prior=$'["Classic theme", "Accent *", "A\tB", "C\nD"]'
gsettings() {
    case "$1" in
        get)   printf '%s\n' "$prior" ;;
        set)   printf '%s\0' "$@" >>"$tmp/settings-calls" ;;
        *)     return 99 ;;
    esac
}
flatpak() {
    [[ "${1-}" == override && "${2-}" == --user && "$#" == 3 ]] || return 99
    case "$3" in
        --show) return 0 ;;
        --filesystem=*|--nofilesystem=*) printf '%s\0' "$@" >>"$tmp/flatpak-calls" ;;
        *) return 99 ;;
    esac
}

manifest_init
SWAY98_MODULE=gtk
gsettings_set_if_changed org.example.settings gtk-theme 'New Theme'
SWAY98_MODULE=flatpak
sway98_apply
printf '%s\0' set org.example.settings gtk-theme 'New Theme' >"$tmp/wanted"
cmp "$tmp/wanted" "$tmp/settings-calls"
printf '%s\0' override --user "--filesystem=$HOME/.themes:ro" \
    override --user "--filesystem=$HOME/.icons:ro" >"$tmp/wanted"
cmp "$tmp/wanted" "$tmp/flatpak-calls"
[[ "$(wc -l < "$(manifest_commands)")" -eq 3 ]]
awk -F '\t' 'NF != 2 { exit 1 }' "$(manifest_commands)"

: >"$tmp/settings-calls"
: >"$tmp/flatpak-calls"
SWAY98_DRY_RUN=1 restore_all
[[ ! -s "$tmp/settings-calls" && ! -s "$tmp/flatpak-calls" ]]
SWAY98_DRY_RUN=0 restore_all gtk
printf '%s\0' set org.example.settings gtk-theme "$prior" >"$tmp/wanted"
cmp "$tmp/wanted" "$tmp/settings-calls"
[[ ! -s "$tmp/flatpak-calls" ]]
SWAY98_DRY_RUN=0 restore_all flatpak
printf '%s\0' override --user "--nofilesystem=$HOME/.icons" \
    override --user "--nofilesystem=$HOME/.themes" >"$tmp/wanted"
cmp "$tmp/wanted" "$tmp/flatpak-calls"
printf 'ok: rollback preserves exact GSettings and Flatpak arguments\n'
