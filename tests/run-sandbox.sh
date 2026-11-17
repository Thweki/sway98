#!/usr/bin/env bash
#
# sway98 — sandbox test harness.
#
# Runs the installer against a throwaway $HOME so that a developer machine is
# never modified. Three modes:
#
#   run-sandbox.sh all         dry-run then roundtrip, sharing one pristine
#                              sandbox after the dry-run assertions pass
#   run-sandbox.sh dry-run     every module under --dry-run must leave the
#                              sandbox byte for byte identical and must not
#                              create a manifest
#   run-sandbox.sh roundtrip   install everything, uninstall everything, and
#                              require the sandbox to match the pristine copy
#
# Flatpak and sound downloads are excluded from real installs. Dry runs cover
# every module and the standalone sound fetcher with network commands blocked.

set -euo pipefail

# Inherited overrides must never redirect tests into the caller's real state.
for variable in "${!SWAY98_@}" "${!XDG_@}"; do
    unset "$variable"
done

SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$SWAY98_ROOT/tests/sandbox"
MODE="${1:-roundtrip}"

# Modules exercised by real sandbox installs; dry-run uses --all.
TEST_MODULES="theme,sway,waybar,gtk,qt,kitty,wofi,mako,swaylock,fcitx5,fonts,firefox"

# Explicit expectations: do not derive these from firefox_profiles(), whose
# discovery behavior is part of what this test exercises.
FIREFOX_PROFILES=(
    '.mozilla/firefox/native.default'
    '.mozilla/firefox/native.default-release'
    '.var/app/org.mozilla.firefox/.mozilla/firefox/flatpak profile.default-release'
    'snap/firefox/common/.mozilla/firefox/snap.default'
    'snap/firefox/common/.mozilla/firefox/snap.default-release'
)

pass() { printf '\033[32mok\033[0m   %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*"; exit 1; }

assert_firefox_installed() {
    local profile fixture expected_js="$SANDBOX/expected-user.js"
    for profile in "${FIREFOX_PROFILES[@]}"; do
        fixture="$SWAY98_ROOT/tests/fixtures/firefox/home/$profile"
        cmp -s -- "$SWAY98_ROOT/modules/firefox/files/userChrome.css" \
            "$SANDBOX/home/$profile/chrome/userChrome.css" \
            || fail "Firefox CSS missing or incorrect: $profile"

        # Compare the whole file, including original preferences and the exact
        # JavaScript comment markers. This also rejects duplicate blocks.
        : >"$expected_js"
        if [[ -f "$fixture/user.js" ]]; then
            cat -- "$fixture/user.js" >"$expected_js"
            printf '\n' >>"$expected_js"
        fi
        cat >>"$expected_js" <<'EOF'
// >>> sway98 >>>
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
user_pref("browser.tabs.drawInTitlebar", false);
user_pref("browser.uidensity", 1);
// <<< sway98 <<<
EOF
        cmp -s -- "$expected_js" "$SANDBOX/home/$profile/user.js" \
            || fail "Firefox preferences missing, duplicated or damaged: $profile"
    done

    # Browser data and profile registries must be untouched during installation,
    # not merely restored by uninstall. The decoy directory must stay unthemed.
    local fixture_file relative
    while IFS= read -r -d '' fixture_file; do
        relative="${fixture_file#"$SWAY98_ROOT/tests/fixtures/firefox/home/"}"
        case "$relative" in
            */user.js|*/chrome/userChrome.css) continue ;;
        esac
        cmp -s -- "$fixture_file" "$SANDBOX/home/$relative" \
            || fail "Firefox install changed unrelated file: $relative"
    done < <(find "$SWAY98_ROOT/tests/fixtures/firefox/home" -type f -print0)
    diff -r -- "$SWAY98_ROOT/tests/fixtures/firefox/home/snap/firefox/common/.mozilla/firefox/not-a-profile" \
        "$SANDBOX/home/snap/firefox/common/.mozilla/firefox/not-a-profile" \
        || fail "Firefox install modified a non-profile directory"
    pass "all five Firefox profiles have exact CSS and preference blocks; unrelated data is intact"
}

seed_home() {
    rm -rf -- "$SANDBOX"
    mkdir -p -- "$SANDBOX/home/.config/sway" \
                "$SANDBOX/home/.config/gtk-3.0" \
                "$SANDBOX/home/.config/mako" \
                "$SANDBOX/state" \
                "$SANDBOX/cache"

    cat >"$SANDBOX/home/.config/sway/config" <<'EOF'
set $mod Mod4
bindsym $mod+Return exec kitty
input type:touchpad {
    tap enabled
}
EOF

    cat >"$SANDBOX/home/.config/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-theme-name=Adwaita
gtk-decoration-layout=:minimize,maximize,close
EOF

    printf 'border-radius=4\ntext-color=#ffffff\n' >"$SANDBOX/home/.config/mako/config"
    printf '# my profile\nexport EDITOR=nvim\n' >"$SANDBOX/home/.profile"

    # Seed before taking the pristine copy so rollback must restore existing
    # files as well as remove newly created user.js, CSS and chrome directories.
    cp -a -- "$SWAY98_ROOT/tests/fixtures/firefox/home/." "$SANDBOX/home/"

    # A stand-in for the Chicago95 checkout: only the paths the modules read.
    local src="$SANDBOX/Chicago95"
    mkdir -p -- "$src/Theme/Chicago95/gtk-3.0" \
                "$src/Icons/Chicago95/16x16" \
                "$src/Cursors/Chicago95_Standard_Cursors/cursors" \
                "$src/Fonts/vga_font" \
                "$src/Fonts/bitmap/cronyx-cyrillic" \
                "$src/Extras"
    printf 'Name=Chicago95\n' >"$src/Theme/Chicago95/index.theme"
    printf '/* stub */\n' >"$src/Theme/Chicago95/gtk-3.0/gtk.css"
    printf 'Name=Chicago95\n' >"$src/Icons/Chicago95/index.theme"
    printf 'stub\n' >"$src/Icons/Chicago95/16x16/icon.png"
    # Real icon themes are largely symlinks; the sandbox has to cover them.
    ln -s icon.png "$src/Icons/Chicago95/16x16/alias.png"
    ln -s ../index.theme "$src/Icons/Chicago95/16x16/theme-link"
    printf 'Name=Chicago 95 Standard\n' >"$src/Cursors/Chicago95_Standard_Cursors/index.theme"
    printf 'stub\n' >"$src/Cursors/Chicago95_Standard_Cursors/cursors/left_ptr"
    printf 'stub\n' >"$src/Fonts/vga_font/LessPerfectDOSVGA.ttf"
    printf 'stub\n' >"$src/Fonts/bitmap/cronyx-cyrillic/crox1c.otb"
    printf '[ColorScheme]\nactive_colors=#000000\n' >"$src/Extras/Chicago95_qt.conf"

    cp -a -- "$SANDBOX/home" "$SANDBOX/pristine"
}

sandbox_env() {
    export HOME="$SANDBOX/home"
    export XDG_CONFIG_HOME="$SANDBOX/home/.config"
    export XDG_STATE_HOME="$SANDBOX/state"
    export XDG_CACHE_HOME="$SANDBOX/cache"
    export XDG_DATA_HOME="$SANDBOX/home/.local/share"
    export SWAY98_THEME_SRC="$SANDBOX/Chicago95"
    # gsettings would talk to the developer's real dconf daemon.
    export SWAY98_NO_GSETTINGS=1
    unset SWAYSOCK WAYLAND_DISPLAY || true
}

diff_home() {
    diff -r --exclude='.cache' "$SANDBOX/pristine" "$SANDBOX/home"
}

# Keep snapshots and command output outside the controlled roots. Unlike the
# roundtrip comparison, dry-run must include caches and all installer state.
snapshot_controlled() {
    local root
    rm -rf -- "$SANDBOX/dry-pristine"
    mkdir -p -- "$SANDBOX/dry-pristine"
    for root in "${CONTROLLED_ROOTS[@]}"; do
        cp -a -- "$root" "$SANDBOX/dry-pristine/${root##*/}"
    done
}

diff_controlled() {
    local root
    for root in "${CONTROLLED_ROOTS[@]}"; do
        diff -r --no-dereference -- "$SANDBOX/dry-pristine/${root##*/}" "$root" || return 1
    done
}

assert_controlled_unchanged() {
    local label="$1"
    if ! diff_controlled >"$SANDBOX/dry-run.diff"; then
        head -30 "$SANDBOX/dry-run.diff" >&2
        fail "$label modified the controlled home/state/cache/data"
    fi
    pass "$label left the controlled home/state/cache/data untouched"
}

# Prove that the comparison detects both changed bytes and new empty paths in
# every root, including the home cache that roundtrip deliberately excludes.
test_controlled_comparison() {
    local root
    # List the expected roots independently so a missing comparison root fails.
    for root in "$HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$HOME/.cache"; do
        mkdir -p -- "$root"
        printf 'original\n' >"$root/dry-run-sentinel"
    done
    snapshot_controlled
    diff_controlled >/dev/null || fail "unchanged controlled snapshot differs"
    for root in "$HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$HOME/.cache"; do
        printf 'modified\n' >"$root/dry-run-sentinel"
        if diff_controlled >/dev/null; then
            fail "comparison missed changed content in $root"
        fi
        printf 'original\n' >"$root/dry-run-sentinel"
        mkdir -- "$root/dry-run-empty"
        if diff_controlled >/dev/null; then
            fail "comparison missed an empty directory in $root"
        fi
        rmdir -- "$root/dry-run-empty"
    done
    assert_controlled_unchanged "comparison self-test"
}

dry_run_command() {
    local label="$1"; shift
    local dry_output="$SANDBOX/dry.log"
    if ! "$@" >"$dry_output" 2>&1; then
        cat "$dry_output" >&2
        fail "$label exited non-zero"
    fi
    grep -q '\[dry-run\]' "$dry_output" || fail "$label produced no dry-run output"
    [[ ! -s "$SANDBOX/blocked.log" ]] || fail "$label attempted a blocked external command"
    assert_controlled_unchanged "$label"
}

case "$MODE" in
    all|dry-run|roundtrip) ;;
    *) fail "unknown mode: $MODE (expected all, dry-run or roundtrip)" ;;
esac

seed_home
sandbox_env

case "$MODE" in
    all|dry-run)
        (
        # Separate XDG data in dry-run only; real roundtrip keeps default paths.
        export XDG_DATA_HOME="$SANDBOX/data"
        export SWAY98_STATE="$XDG_STATE_HOME/sway98"
        CONTROLLED_ROOTS=("$HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME")
        test_controlled_comparison

        mkdir -p -- "$SANDBOX/bin"
        cat >"$SANDBOX/bin/blocked" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${0##*/}" >>"$HOME/../blocked.log"
exit 1
EOF
        chmod +x -- "$SANDBOX/bin/blocked"
        for cmd in curl git wget; do
            ln -s blocked "$SANDBOX/bin/$cmd"
        done
        # Flatpak's read-only query needs no connection to a real desktop.
        cat >"$SANDBOX/bin/flatpak" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'override --user --show' ]] && exit 0
exec "${0%/*}/blocked"
EOF
        chmod +x -- "$SANDBOX/bin/flatpak"
        export PATH="$SANDBOX/bin:$PATH"

        fetcher="$SWAY98_ROOT/modules/sounds/fetch-ms-sounds.sh"
        dry_run_command "standalone sound fetcher" "$fetcher" --dry-run
        grep -qF -- "$SWAY98_STATE/sounds-src/desktop-login.wav" "$SANDBOX/dry.log" \
            || fail "sound fetcher ignored the default dry-run destination"
        custom_dest="$HOME/sound preview"
        dry_run_command "sound fetcher with explicit destination" "$fetcher" "$custom_dest" --dry-run
        grep -qF -- "$custom_dest/desktop-login.wav" "$SANDBOX/dry.log" \
            || fail "sound fetcher ignored the explicit dry-run destination"
        dry_run_command "sound fetcher with inherited dry-run" env SWAY98_DRY_RUN=1 "$fetcher" "$custom_dest"
        grep -qF -- "$custom_dest/desktop-login.wav" "$SANDBOX/dry.log" \
            || fail "sound fetcher ignored the inherited dry-run destination"

        dry_run_command "installer --dry-run --all" "$SWAY98_ROOT/install.sh" --dry-run --yes --all
        out="$SANDBOX/dry.log"
        for profile in "${FIREFOX_PROFILES[@]}"; do
            grep -Fq "$SANDBOX/home/$profile/chrome/userChrome.css" "$out" \
                || fail "dry run did not plan Firefox CSS: $profile"
            grep -Fq "$SANDBOX/home/$profile/user.js" "$out" \
                || fail "dry run did not plan Firefox preferences: $profile"
        done
        pass "dry run planned CSS and preferences for all five Firefox profiles"
        dry_run_command "installer with uncached theme" env SWAY98_THEME_SRC="$SWAY98_STATE/upstream/Chicago95" \
            "$SWAY98_ROOT/install.sh" --dry-run --yes --all
        grep -q 'would clone' "$SANDBOX/dry.log" || fail "uncached theme download was not planned"
        [[ ! -e "$SWAY98_STATE/manifest/files.tsv" ]] || fail "dry run wrote a manifest"

        # The surrounding test creates a synthetic invalid cache, not a download.
        mkdir -p -- "$SWAY98_STATE/sounds-src"
        printf 'existing sound bytes\n' >"$SWAY98_STATE/sounds-src/desktop-login.wav"
        snapshot_controlled
        dry_run_command "sound fetcher with existing cache" "$fetcher" --dry-run
        rm -f -- "$SWAY98_STATE/sounds-src/desktop-login.wav"
        rmdir -- "$SWAY98_STATE/sounds-src" "$SWAY98_STATE"

        # Remove only sentinels created by the comparison self-test.
        for root in "${CONTROLLED_ROOTS[@]}" "$HOME/.cache"; do
            rm -- "$root/dry-run-sentinel"
        done
        rmdir -- "$HOME/.cache" "$XDG_DATA_HOME"
        )
        ;;&

    all|roundtrip)
        out="$SANDBOX/install.log"
        if ! "$SWAY98_ROOT/install.sh" --yes --modules "$TEST_MODULES" >"$out" 2>&1; then
            tail -30 "$out" >&2
            fail "install exited non-zero"
        fi
        pass "install finished"

        for expected in \
            "$SANDBOX/home/.config/sway/conf.d/sway98.conf" \
            "$SANDBOX/home/.config/sway/conf.d/sway98.d/00-README.conf" \
            "$SANDBOX/home/.config/waybar/style.css" \
            "$SANDBOX/home/.config/kitty/sway98-vga.conf" \
            "$SANDBOX/home/.config/wofi/style.css" \
            "$SANDBOX/home/.config/swaylock/config" \
            "$SANDBOX/home/.config/fcitx5/conf/classicui.conf" \
            "$SANDBOX/home/.local/share/fcitx5/themes/win98/theme.conf" \
            "$SANDBOX/home/.themes/Chicago95/index.theme" \
            "$SANDBOX/state/sway98/manifest/files.tsv"
        do
            [[ -e "$expected" ]] || fail "expected file missing: ${expected#"$SANDBOX"/}"
        done
        pass "expected files are in place"
        assert_firefox_installed

        grep -q '# >>> sway98 >>>' "$SANDBOX/home/.config/sway/config" || fail "sway config has no marker block"
        grep -q 'include .*sway98.conf' "$SANDBOX/home/.config/sway/config" || fail "sway config has no include"
        grep -q 'gtk-theme-name=Chicago95' "$SANDBOX/home/.config/gtk-3.0/settings.ini" || fail "gtk settings not written"
        grep -q 'gtk-decoration-layout' "$SANDBOX/home/.config/gtk-3.0/settings.ini" || fail "gtk settings lost unrelated keys"
        grep -q 'export QT_QPA_PLATFORMTHEME=gtk3' "$SANDBOX/home/.profile" || fail "profile export missing"
        grep -q 'export EDITOR=nvim' "$SANDBOX/home/.profile" || fail "profile lost existing content"
        pass "edits merged into existing files instead of replacing them"

        # Re-running has to be a no-op for the files it already wrote.
        before="$(sha256sum "$SANDBOX/home/.config/waybar/style.css" "$SANDBOX/home/.config/sway/conf.d/sway98.conf" | sha256sum)"
        "$SWAY98_ROOT/install.sh" --yes --modules "$TEST_MODULES" >>"$out" 2>&1 || fail "second install run failed"
        after="$(sha256sum "$SANDBOX/home/.config/waybar/style.css" "$SANDBOX/home/.config/sway/conf.d/sway98.conf" | sha256sum)"
        [[ "$before" == "$after" ]] || fail "second run changed files that should be identical"
        assert_firefox_installed
        pass "re-running the installer is idempotent"

        CONTROLLED_ROOTS=("$HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME")
        snapshot_controlled
        dry_run_command "uninstaller --dry-run" "$SWAY98_ROOT/uninstall.sh" --dry-run --yes

        uout="$SANDBOX/uninstall.log"
        if ! "$SWAY98_ROOT/uninstall.sh" --yes >"$uout" 2>&1; then
            tail -30 "$uout" >&2
            fail "uninstall exited non-zero"
        fi
        pass "uninstall finished"

        if ! diff_home >"$SANDBOX/roundtrip.diff"; then
            head -30 "$SANDBOX/roundtrip.diff" >&2
            fail "sandbox \$HOME differs from the pristine copy after uninstall"
        fi
        pass "sandbox \$HOME is byte for byte identical to the pristine copy"
        ;;
esac
