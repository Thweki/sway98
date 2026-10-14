#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata is read by the installer via lib/menu.sh
# shellcheck shell=bash
#
# firefox — Windows 98 chrome for Firefox.
#
# This is explicitly best effort: userChrome.css styles Firefox's internal DOM,
# which Mozilla changes between releases. The module installs its own files and
# a small user.js block, so ./uninstall.sh removes both cleanly.

SWAY98_MODULE_ID="firefox"
SWAY98_MODULE_DESC="Win98 chrome for Firefox (userChrome.css + user.js, best effort)"
SWAY98_MODULE_SCOPE="user"
SWAY98_MODULE_RECOMMENDED="no"
SWAY98_MODULE_REQUIRES=""
SWAY98_MODULE_NEEDS_PKGS="firefox"

sway98_apply() {
    local -a profiles=()
    local p

    while IFS= read -r p; do
        [[ -n "$p" ]] && profiles+=("$p")
    done < <(firefox_profiles)

    if ((${#profiles[@]} == 0)); then
        warn "no Firefox profile found (looked in ~/.mozilla, ~/.var/app and ~/snap)"
        warn "start Firefox once, then re-run: ./install.sh --only firefox"
        return 0
    fi

    for p in "${profiles[@]}"; do
        info "profile: $p"
        install_file "$SWAY98_ROOT/modules/firefox/files/userChrome.css" "$p/chrome/userChrome.css"

        # user.js is JavaScript, so the marker block uses // comments.
        SWAY98_BLOCK_PREFIX='//'
        include_block "$p/user.js" "sway98" \
            'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);' \
            'user_pref("browser.tabs.drawInTitlebar", false);' \
            'user_pref("browser.uidensity", 1);'
        unset SWAY98_BLOCK_PREFIX
    done

    warn "Firefox must be fully quit (Ctrl+Shift+Q) and started again, not just reloaded"
    warn "the menu bar is shown by user.js; if a future release breaks the CSS, uninstall this module"
}
