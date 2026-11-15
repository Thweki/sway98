#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata is read by the installer via lib/menu.sh
# shellcheck shell=bash
#
# fcitx5 — Windows 98 look for the input method panel.
#
# The panel is a fcitx5 "classic UI" theme: two colours, a 2px border and square
# corners are all it takes. The four PNGs are the page arrows and the menu radio
# mark, drawn at 1x to match the Win98 pixel grid.

SWAY98_MODULE_ID="fcitx5"
SWAY98_MODULE_DESC="Win98 input method panel (fcitx5) and IM environment"
SWAY98_MODULE_SCOPE="user"
SWAY98_MODULE_RECOMMENDED="yes"
SWAY98_MODULE_REQUIRES=""
SWAY98_MODULE_NEEDS_PKGS="fcitx5 fcitx5-gtk fcitx5-qt"

sway98_apply() {
    local data="${XDG_DATA_HOME:-$HOME/.local/share}"
    local theme_dir="$data/fcitx5/themes/win98"
    local font

    font="$(pick_font "Liberation Sans" "DejaVu Sans" "Sans")"

    install_dir "$SWAY98_ROOT/modules/fcitx5/files/theme" "$theme_dir"
    template_render "$SWAY98_ROOT/modules/fcitx5/files/theme.conf.in" \
        "$theme_dir/theme.conf" "FONT=$font"

    # classicui.conf has no section headers; write its keys with the helper below
    # so unknown keys survive untouched.
    _fcitx5_set_key "Theme" "win98"
    _fcitx5_set_key "DarkTheme" "win98"
    _fcitx5_set_key "UseDarkTheme" "False"
    _fcitx5_set_key "Vertical Candidate List" "False"
    _fcitx5_set_key "UseInputMethodLanguageToDisplayText" "True"
    _fcitx5_set_key "Font" "$font 10"

    # Under sway, fcitx5 needs both the D-Bus activation environment and its own
    # daemon started once; without this, X11 apps in particular never see it.
    install_file "$SWAY98_ROOT/modules/fcitx5/files/sway-fragment.conf" \
        "$(sway98_config_home)/sway/conf.d/sway98.d/fcitx5.conf"

    if pgrep -x fcitx5 >/dev/null 2>&1; then
        info "restart the input method to see the new panel: fcitx5 -r -d --replace"
    else
        info "start it with: fcitx5 -d"
    fi
}

# classicui.conf is a flat key=value file with no section headers, which ini_set
# cannot express. Rewrite it line by line instead, preserving unknown keys.
_fcitx5_set_key() {
    local key="$1" value="$2"
    local file="$(sway98_config_home)/fcitx5/conf/classicui.conf"
    local tmp; tmp="$(mktemp)"

    if [[ -f "$file" ]]; then
        awk -v key="$key" -v value="$value" '
            BEGIN { done = 0 }
            $0 ~ "^[ \t]*" key "[ \t]*=" { printf "%s=%s\n", key, value; done = 1; next }
            { print }
            END { if (!done) printf "%s=%s\n", key, value }
        ' "$file" >"$tmp"
    else
        printf '%s=%s\n' "$key" "$value" >"$tmp"
    fi

    install_file "$tmp" "$file"
    rm -f -- "$tmp"
}
