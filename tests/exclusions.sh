#!/usr/bin/env bash
set -euo pipefail

# Test the selection, dependency and installer boundaries using synthetic
# metadata and apply functions. Never touch the host desktop or fetch assets.
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p -- "$tmp"/{repo/modules,bin,watch/home}
cp -- "$root/install.sh" "$tmp/repo/"
cp -a -- "$root/lib" "$tmp/repo/"
for id in theme gtk kitty sounds flatpak; do
    rec=yes req=""
    case "$id" in
        sounds|flatpak) rec=no ;;
    esac
    case "$id" in
        gtk|flatpak) req=theme ;;
    esac
    mkdir -- "$tmp/repo/modules/$id"
    cat >"$tmp/repo/modules/$id/module.sh" <<EOF
SWAY98_MODULE_ID=$id
SWAY98_MODULE_DESC="Synthetic $id"
SWAY98_MODULE_SCOPE=user
SWAY98_MODULE_RECOMMENDED=$rec
SWAY98_MODULE_REQUIRES="$req"
SWAY98_MODULE_NEEDS_PKGS=""
sway98_apply() {
    printf '%s\\n' "$id" >>"\$SWAY98_TEST_APPLY"
    install_file "\$SWAY98_ROOT/payload" "\$HOME/$id"
}
EOF
done
printf 'synthetic asset\n' >"$tmp/repo/payload"
for cmd in curl wget git sudo pacman apt dnf gsettings flatpak fc-cache gum swaymsg; do
    cat >"$tmp/bin/$cmd" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" >>"$SWAY98_TEST_CALLS"
exit 1
EOF
    chmod +x -- "$tmp/bin/$cmd"
done
printf 'keep existing config\n' >"$tmp/watch/home/.profile"
printf 'keep existing log\n' >"$tmp/watch/install.log"
cp -a -- "$tmp/watch" "$tmp/before"
cp -a -- "$tmp/repo" "$tmp/repo-before"

run() {
    (cd -- "$tmp/watch" && env -i PATH="$tmp/bin:$PATH" HOME="$tmp/watch/home"         XDG_CONFIG_HOME="$tmp/watch/config" XDG_DATA_HOME="$tmp/watch/data"         XDG_STATE_HOME="$tmp/watch/state" XDG_CACHE_HOME="$tmp/watch/cache"         TMPDIR="$tmp/watch/tmp" SWAY98_LOG="$tmp/watch/install.log"         SWAY98_TEST_APPLY="$tmp/applied" SWAY98_TEST_CALLS="$tmp/calls"         bash "$tmp/repo/install.sh" "$@") >"$tmp/output" 2>"$tmp/errors"
}

plan_ids() { sed -n 's/^\([a-z0-9]*\) \[user\].*/\1/p' "$tmp/output" | paste -sd ' '; }
expect_plan() {
    local expected="$1"; shift
    run --plan "$@"
    [[ "$(plan_ids)" == "$expected" ]] || fail "wrong plan: $(plan_ids)"
}
expect_error() {
    if run "$@" </dev/null; then fail "accepted: $*"; fi
}
expect_plan 'gtk kitty theme' --all --exclude sounds --exclude flatpak,sounds </dev/null
expect_plan 'gtk kitty' --recommended --yes --exclude theme </dev/null
grep -Fq 'Requires: theme (excluded)' "$tmp/output" || fail 'plan omitted excluded dependency'
grep -Fq "'gtk' selected without 'theme' (--exclude)" "$tmp/errors" || fail 'missing warning'
expect_plan 'kitty' --modules gtk,kitty,kitty --exclude gtk </dev/null
expect_plan 'gtk theme' --only gtk --exclude sounds </dev/null
expect_plan 'gtk' --only gtk --exclude theme </dev/null
expect_plan 'gtk kitty' --exclude theme <<<'r'
expect_plan '' --only kitty --exclude kitty </dev/null
grep -Fq 'nothing selected' "$tmp/errors" || fail 'empty selection did not report no-op'
run --only kitty --exclude kitty </dev/null
grep -Fq 'nothing selected' "$tmp/errors" || fail 'empty installation did not no-op'

for bad in unknown kit 1 'sounds,' ',sounds' 'sounds,,flatpak' ''; do
    expect_error --plan --all --exclude "$bad"
    expect_error --all --exclude "$bad"
done
expect_error --all --exclude
expect_error --all --exclude --plan
expect_error --exclude theme --plan --modules does-not-exist
for mode in --list -l --status --verify; do
    expect_error "$mode" --exclude theme
    expect_error --exclude theme "$mode"
done
expect_error --list --all --exclude theme
for flag in --modules -m --only; do
    expect_error "$flag" --exclude theme
    grep -Fq 'before --exclude' "$tmp/errors" || fail 'missing selector operand diagnostic'
done
[[ ! -e "$tmp/applied" && ! -e "$tmp/calls" ]] || fail 'plan/no-op/error ran installer commands'

run --dry-run --all --exclude sounds,flatpak,theme </dev/null
printf 'gtk\nkitty\n' >"$tmp/expected-apply"
diff -u -- "$tmp/expected-apply" "$tmp/applied" || fail 'dry run used a different selection'
[[ ! -e "$tmp/calls" ]] || fail 'dry run tried a package manager or external tool'
diff -r -- "$tmp/before" "$tmp/watch" || fail 'changed HOME, XDG, tmp or inherited log'
diff -r -- "$tmp/repo-before" "$tmp/repo" || fail 'changed checkout'
# Exercise actual apply only inside the same throwaway HOME using our two-line
# synthetic apply functions. The host checkout and sentinel log remain intact.
rm -- "$tmp/applied"
run --yes --all --exclude sounds,flatpak,theme </dev/null
diff -u -- "$tmp/expected-apply" "$tmp/applied" || fail 'install applied an excluded module'
diff -u -- "$tmp/repo/payload" "$tmp/watch/home/gtk"
diff -u -- "$tmp/repo/payload" "$tmp/watch/home/kitty"
[[ ! -e "$tmp/watch/home/theme" && ! -e "$tmp/watch/home/flatpak" && ! -e "$tmp/watch/home/sounds" ]] \
    || fail 'install wrote an excluded module'
cut -f1 "$tmp/watch/state/sway98/manifest/modules.tsv" >"$tmp/actual-recorded"
diff -u -- "$tmp/expected-apply" "$tmp/actual-recorded" || fail 'install recorded an excluded module'
[[ ! -e "$tmp/calls" ]] || fail 'synthetic install ran an external helper'
diff -u -- "$tmp/before/install.log" "$tmp/watch/install.log" || fail 'install changed inherited log'
diff -r -- "$tmp/repo-before" "$tmp/repo" || fail 'install changed checkout'
printf 'ok: module exclusions, dependency opt-outs, read-only modes and zero side effects\n'
