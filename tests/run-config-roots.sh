#!/usr/bin/env bash
set -euo pipefail

# Exercise every configuration-writing module without a desktop or downloads.
# Data files and legacy HOME-based paths are deliberately outside this contract.
SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sway98-config-roots.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

sway98_test_config_root() (
    local mode="$1" fixture="$TEST_ROOT/$1" config_root relative module sound_name
    export HOME="$fixture/payload/home"
    mkdir -p -- "$HOME" "$fixture/state"
    case "$mode" in
        unset) unset XDG_CONFIG_HOME; config_root="$HOME/.config" ;;
        empty) export XDG_CONFIG_HOME=""; config_root="$HOME/.config" ;;
        custom)
            # Outside HOME, with whitespace and a sed replacement character:
            # the selected root must survive both resolution and rendering.
            config_root="$fixture/payload/custom config & styles"
            export XDG_CONFIG_HOME="$config_root"
            mkdir -p -- "$HOME/.config"
            printf 'leave this root alone\n' >"$HOME/.config/sentinel"
            ;;
        *) fail "unknown configuration-root case: $mode" ;;
    esac
    export XDG_STATE_HOME="$fixture/state"
    export XDG_DATA_HOME="$HOME/.local/share"
    export SWAY98_STATE="$XDG_STATE_HOME/sway98"
    export SWAY98_THEME_SRC="$fixture/Chicago95"
    export SWAY98_NO_GSETTINGS=1 SWAY98_ASSUME_YES=1 SWAY98_DRY_RUN=0 SWAY98_LOG=""
    export SWAYSOCK=""

    # shellcheck source=lib/common.sh
    . "$SWAY98_ROOT/lib/common.sh"
    # shellcheck source=lib/detect.sh
    . "$SWAY98_ROOT/lib/detect.sh"
    # shellcheck source=lib/manifest.sh
    . "$SWAY98_ROOT/lib/manifest.sh"
    # shellcheck source=lib/edit.sh
    . "$SWAY98_ROOT/lib/edit.sh"

    # Deterministic font fallback, no gsettings access, and a player that is
    # only named in the generated fragment (never executed by these modules).
    have() { [[ "$1" == pw-play ]]; }

    mkdir -p -- "$config_root/sway" "$config_root/gtk-3.0" \
        "$config_root/kitty" "$config_root/fcitx5/conf" "$config_root/mako" \
        "$config_root/qt5ct" "$config_root/qt6ct" "$SWAY98_THEME_SRC/Extras" \
        "$SWAY98_STATE/sounds-src"
    printf 'set $mod Mod4\n' >"$config_root/sway/config"
    printf '[Settings]\ngtk-theme-name=Adwaita\nkeep-me=yes\n' >"$config_root/gtk-3.0/settings.ini"
    printf 'font_size 12\n' >"$config_root/kitty/kitty.conf"
    printf 'Theme=original\nKeepMe=True\n' >"$config_root/fcitx5/conf/classicui.conf"
    printf 'border-size=1\n' >"$config_root/mako/config"
    for module in qt5ct qt6ct; do
        printf '[Appearance]\ncustom_palette=true\n' >"$config_root/$module/$module.conf"
    done
    printf '# original profile\n' >"$HOME/.profile"
    printf '[ColorScheme]\nactive_colors=#000000\n' >"$SWAY98_THEME_SRC/Extras/Chicago95_qt.conf"
    # Plain fixture bytes, never Microsoft assets. A complete cache means the
    # sounds module cannot enter its download branch.
    while IFS=$'\t' read -r sound_name _; do
        [[ -n "$sound_name" && "$sound_name" != \#* ]] || continue
        printf 'test sound\n' >"$SWAY98_STATE/sounds-src/$sound_name.wav"
    done <"$SWAY98_ROOT/modules/sounds/sources.tsv"
    cp -a -- "$fixture/payload" "$fixture/pristine"
    manifest_init

    local modules=(sway waybar gtk qt kitty wofi mako swaylock fcitx5 sounds)
    local expected=(
        sway/conf.d/sway98.conf sway/conf.d/sway98.d/00-README.conf
        sway/conf.d/sway98.d/waybar.conf sway/conf.d/sway98.d/mako.conf
        sway/conf.d/sway98.d/fcitx5.conf sway/conf.d/sway98.d/sounds.conf
        waybar/config waybar/style.css gtk-3.0/settings.ini gtk-4.0/settings.ini
        environment.d/90-sway98-qt.conf qt5ct/colors/sway98.conf qt6ct/colors/sway98.conf
        kitty/kitty.conf kitty/sway98-vga.conf wofi/style.css mako/config
        swaylock/config fcitx5/conf/classicui.conf
    )
    local run
    for run in 1 2; do
        for module in "${modules[@]}"; do
            (
                export SWAY98_MODULE="$module"
                # shellcheck disable=SC1090
                . "$SWAY98_ROOT/modules/$module/module.sh"
                sway98_apply
            ) >>"$fixture/apply.log" 2>&1
        done
        for relative in "${expected[@]}"; do
            [[ -f "$config_root/$relative" ]] || fail "$mode: missing $relative (install $run)"
        done
        grep -Fq "include \"$config_root/sway/conf.d/sway98.conf\"" "$config_root/sway/config" \
            || fail "$mode: sway main include uses the wrong root"
        grep -Fxq "include \"$config_root/sway/conf.d/sway98.d/*.conf\"" "$config_root/sway/conf.d/sway98.conf" \
            || fail "$mode: sway fragment glob uses the wrong root"
        grep -Fxq "include $config_root/kitty/sway98-vga.conf" "$config_root/kitty/kitty.conf" \
            || fail "$mode: kitty include uses the wrong root"
        for module in qt5ct qt6ct; do
            grep -Fxq "color_scheme_path=$config_root/$module/colors/sway98.conf" "$config_root/$module/$module.conf" \
                || fail "$mode: $module palette uses the wrong root"
        done
        grep -Fxq 'gtk-theme-name=Chicago95' "$config_root/gtk-3.0/settings.ini" || fail "$mode: GTK settings unchanged"
        grep -Fxq 'Theme=win98' "$config_root/fcitx5/conf/classicui.conf" || fail "$mode: fcitx5 settings unchanged"
        if [[ "$mode" == custom ]]; then
            diff -r -- "$fixture/pristine/home/.config" "$HOME/.config" \
                || fail 'custom: wrote into the default configuration root'
        fi
        # Check every recorded configuration destination, not just the files
        # whose existence was asserted above.
        while IFS=$'\t' read -r _ _ relative _; do
            case "$relative" in
                "$config_root"/*|"$XDG_DATA_HOME"/*|"$HOME/.profile") ;;
                *) fail "$mode: unexpected manifest destination: $relative" ;;
            esac
        done <"$(manifest_files)"
        if ((run == 1)); then
            cp -a -- "$fixture/payload" "$fixture/installed"
        else
            diff -r -- "$fixture/installed" "$fixture/payload" || fail "$mode: reinstall changed configuration"
        fi
    done
    "$SWAY98_ROOT/uninstall.sh" --yes >"$fixture/uninstall.log" 2>&1
    diff -r -- "$fixture/pristine" "$fixture/payload" || fail "$mode: uninstall did not restore both roots"
    printf 'ok: %s configuration root: install, reinstall, uninstall (%s modules)\n' "$mode" "${#modules[@]}"
)

if (($# == 0)); then set -- unset empty custom; fi
for config_case in "$@"; do
    sway98_test_config_root "$config_case"
done
