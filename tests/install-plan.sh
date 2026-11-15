#!/usr/bin/env bash
set -euo pipefail

# Exercise the CLI without a desktop, package manager, or upstream checkout.
SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PLAN_TMP="$(mktemp -d)"
trap 'rm -rf -- "$PLAN_TMP"' EXIT

sway98_test_fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p -- "$PLAN_TMP/repo" "$PLAN_TMP/bin" "$PLAN_TMP/watched/home"
cp -- "$SWAY98_ROOT/install.sh" "$PLAN_TMP/repo/"
cp -a -- "$SWAY98_ROOT/lib" "$PLAN_TMP/repo/"
for module_file in "$SWAY98_ROOT"/modules/*/module.sh; do
    module_id="$(basename -- "$(dirname -- "$module_file")")"
    mkdir -p -- "$PLAN_TMP/repo/modules/$module_id"
    cp -- "$module_file" "$PLAN_TMP/repo/modules/$module_id/module.sh"
    # Preserve real metadata, but make any apply call observable and harmless.
    cat >>"$PLAN_TMP/repo/modules/$module_id/module.sh" <<'EOF'
sway98_apply() { printf 'module applied\n' >>"$SWAY98_TEST_CALLS"; return 1; }
EOF
done

for guarded_command in curl git gsettings flatpak fc-cache pacman gum swaymsg; do
    cat >"$PLAN_TMP/bin/$guarded_command" <<'EOF'
#!/usr/bin/env bash
printf 'external command invoked\n' >>"$SWAY98_TEST_CALLS"
exit 1
EOF
    chmod +x -- "$PLAN_TMP/bin/$guarded_command"
done
printf 'keep existing config\n' >"$PLAN_TMP/watched/home/.profile"
printf 'keep existing log\n' >"$PLAN_TMP/watched/install.log"
cp -a -- "$PLAN_TMP/watched" "$PLAN_TMP/before"

sway98_test_plan() {
    env -i PATH="$PLAN_TMP/bin:$PATH" HOME="$PLAN_TMP/watched/home" \
        XDG_CONFIG_HOME="$PLAN_TMP/watched/config" \
        XDG_DATA_HOME="$PLAN_TMP/watched/data" \
        XDG_STATE_HOME="$PLAN_TMP/watched/state" \
        XDG_CACHE_HOME="$PLAN_TMP/watched/cache" \
        TMPDIR="$PLAN_TMP/watched/tmp" \
        SWAY98_LOG="$PLAN_TMP/watched/install.log" \
        SWAY98_TEST_CALLS="$PLAN_TMP/calls" \
        bash "$PLAN_TMP/repo/install.sh" "$@" \
        >"$PLAN_TMP/output" 2>"$PLAN_TMP/errors" </dev/null
}

sway98_test_contains() {
    grep -Fq -- "$1" "$PLAN_TMP/output" || sway98_test_fail "missing output: $1"
}

sway98_test_plan --plan --modules sway,kitty,sway
sway98_test_contains 'Installation plan'
sway98_test_contains 'sway [user]'
sway98_test_contains 'Changes: Win98 window titles, borders, cursor and teal desktop'
sway98_test_contains 'Packages (not checked or installed): sway'
sway98_test_contains 'theme [user] (added dependency)'
sway98_test_contains 'Requires: theme (selected)'
[[ "$(grep -c '^sway \[user\]' "$PLAN_TMP/output")" == 1 ]] || sway98_test_fail 'duplicate module'
[[ "$(grep -c '^[a-z0-9]* \[user\]' "$PLAN_TMP/output")" == 3 ]] || sway98_test_fail 'wrong selection'

sway98_test_plan --only kitty --plan --yes --dry-run
sway98_test_contains 'kitty [user]'
[[ "$(grep -c '^[a-z0-9]* \[user\]' "$PLAN_TMP/output")" == 1 ]] || sway98_test_fail '--only selected extra modules'

# Match the installer's single dependency expansion pass, including omissions.
sway98_test_plan --plan --only waybar
sway98_test_contains 'sway [user] (added dependency)'
sway98_test_contains 'Requires: theme (not selected)'

sway98_test_plan --plan --all
module_count=0
for module_file in "$SWAY98_ROOT"/modules/*/module.sh; do
    module_id="$(basename -- "$(dirname -- "$module_file")")"
    sway98_test_contains "$module_id [user]"
    module_count=$((module_count + 1))
done
[[ "$(grep -c '^[a-z0-9]* \[user\]' "$PLAN_TMP/output")" == "$module_count" ]] || sway98_test_fail '--all count'
sway98_test_contains 'Windows 98 system sounds, downloaded from archive.org on request'
! grep -Fq '(added dependency)' "$PLAN_TMP/output" || sway98_test_fail '--all added duplicates'

sway98_test_plan --recommended --plan
sway98_test_contains 'theme [user]'
sway98_test_contains 'waybar [user]'
! grep -q '^sounds \[' "$PLAN_TMP/output" || sway98_test_fail 'recommended included sounds'

sway98_test_plan --plan --modules 1,2-3
sway98_test_contains 'fcitx5 [user]'
sway98_test_contains 'firefox [user]'
sway98_test_contains 'flatpak [user]'

if sway98_test_plan --plan --modules does-not-exist; then
    sway98_test_fail 'unknown module accepted'
fi
grep -Fq 'unknown module: does-not-exist' "$PLAN_TMP/errors" || sway98_test_fail 'missing validation error'

sway98_test_plan --plan
grep -Fq 'nothing selected' "$PLAN_TMP/errors" || sway98_test_fail 'empty selection did not exit cleanly'
[[ ! -e "$PLAN_TMP/calls" ]] || sway98_test_fail 'plan invoked an apply function or external command'
diff -r -- "$PLAN_TMP/before" "$PLAN_TMP/watched" || sway98_test_fail 'plan changed home, log, state, cache, data, or temp files'
printf 'ok: install plan selections, dependencies, validation, and zero side effects\n'
