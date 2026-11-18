#!/usr/bin/env bash
set -euo pipefail

# Exercise a throwaway copy of the installer. No packages or upstream assets
# are required, and every apply function in the fixture is replaced by a trap.
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -- "$tmp/repo" "$tmp/bin" "$tmp/watch"
mkdir -- "$tmp/watch/home"
cp -- "$root/install.sh" "$tmp/repo/"
cp -a -- "$root/lib" "$tmp/repo/"
for module_file in "$root"/modules/*/module.sh; do
    module_id="$(basename -- "$(dirname -- "$module_file")")"
    mkdir -p -- "$tmp/repo/modules/$module_id"
    cp -- "$module_file" "$tmp/repo/modules/$module_id/module.sh"
    cat >>"$tmp/repo/modules/$module_id/module.sh" <<'EOF'
sway98_apply() { printf 'module applied\n' >>"$SWAY98_TEST_CALLS"; return 1; }
EOF
done

for guarded in curl wget git sudo pacman apt dnf gsettings flatpak fc-cache gum swaymsg; do
    cat >"$tmp/bin/$guarded" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" >>"$SWAY98_TEST_CALLS"
exit 1
EOF
    chmod +x -- "$tmp/bin/$guarded"
done
printf 'keep existing config\n' >"$tmp/watch/home/.profile"
printf 'keep existing log\n' >"$tmp/watch/install.log"
cp -a -- "$tmp/watch" "$tmp/before"
cp -a -- "$tmp/repo" "$tmp/repo-before"

plan() {
    (cd -- "$tmp/watch" && env -i PATH="$tmp/bin:$PATH" HOME="$tmp/watch/home" \
        XDG_CONFIG_HOME="$tmp/watch/config" XDG_DATA_HOME="$tmp/watch/data" \
        XDG_STATE_HOME="$tmp/watch/state" XDG_CACHE_HOME="$tmp/watch/cache" \
        TMPDIR="$tmp/watch/tmp" SWAY98_LOG="$tmp/watch/install.log" \
        SWAY98_TEST_CALLS="$tmp/calls" bash "$tmp/repo/install.sh" "$@") \
        >"$tmp/output" 2>"$tmp/errors"
}
contains() { grep -Fq -- "$1" "$tmp/output" || fail "missing output: $1"; }

plan --plan --modules sway,kitty,sway </dev/null
contains 'Installation plan'
contains 'sway [user]'
contains 'Changes: Win98 window titles, borders, cursor and teal desktop'
contains 'Packages (not checked or installed): sway'
contains 'theme [user] (added dependency)'
contains 'Requires: theme (selected)'
[[ "$(grep -c '^sway \[user\]' "$tmp/output")" == 1 ]] || fail 'duplicate module'
[[ "$(grep -c '^[a-z0-9]* \[user\]' "$tmp/output")" == 3 ]] || fail 'wrong selection'

plan --only kitty --plan --yes --dry-run </dev/null
contains 'kitty [user]'
[[ "$(grep -c '^[a-z0-9]* \[user\]' "$tmp/output")" == 1 ]] || fail '--only selected extra modules'

# Preserve and disclose the existing one-pass dependency expansion.
plan --plan --only waybar </dev/null
contains 'sway [user] (added dependency)'
contains 'Requires: theme (not selected)'

plan --plan --all </dev/null
module_count=0
for module_file in "$root"/modules/*/module.sh; do
    module_id="$(basename -- "$(dirname -- "$module_file")")"
    contains "$module_id [user]"
    module_count=$((module_count + 1))
done
[[ "$(grep -c '^[a-z0-9]* \[user\]' "$tmp/output")" == "$module_count" ]] || fail '--all count'
! grep -Fq '(added dependency)' "$tmp/output" || fail '--all added duplicates'

plan --recommended --plan </dev/null
contains 'theme [user]'
contains 'waybar [user]'
! grep -q '^sounds \[' "$tmp/output" || fail 'recommended included sounds'

plan --plan --modules 1,2-3 </dev/null
contains 'fcitx5 [user]'
contains 'firefox [user]'
contains 'flatpak [user]'

printf 'r\n' | plan --plan
contains 'waybar [user]'
printf '2\n' | plan --plan
contains 'firefox [user]'
[[ "$(grep -c '^[a-z0-9]* \[user\]' "$tmp/output")" == 1 ]] || fail 'numeric picker selected extra modules'
plan --plan </dev/null
grep -Fq 'nothing selected' "$tmp/errors" || fail 'empty picker did not exit cleanly'

if plan --plan --modules does-not-exist </dev/null; then fail 'unknown module accepted'; fi
grep -Fq 'unknown module: does-not-exist' "$tmp/errors" || fail 'missing validation error'
for mode in --list -l --status --verify; do
    if plan --plan "$mode" </dev/null || plan "$mode" --plan </dev/null; then fail "$mode combined with --plan"; fi
done
if plan --list --all --plan </dev/null; then fail '--all hid the --list conflict'; fi
for selector in --modules -m --only; do
    if plan "$selector" --plan </dev/null; then fail "$selector swallowed --plan"; fi
    grep -Fq 'before --plan' "$tmp/errors" || fail 'missing operand error'
    if plan --plan "$selector" </dev/null; then fail "$selector accepted no module"; fi
done

[[ ! -e "$tmp/calls" ]] || fail 'unexpected external helper or apply call'
diff -r -- "$tmp/before" "$tmp/watch" || fail 'plan changed home/log/XDG/tmp'
diff -r -- "$tmp/repo-before" "$tmp/repo" || fail 'plan changed its checkout'
printf 'ok: install plan selections, dependencies, conflicting modes and zero side effects\n'
