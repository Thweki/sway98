#!/usr/bin/env bash
set -euo pipefail

# Exercise the real entry point with synthetic modules: no downloads or desktop.
SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p -- "$TEST_ROOT/repo"
cp -- "$SWAY98_ROOT/install.sh" "$TEST_ROOT/repo/install.sh"
cp -R -- "$SWAY98_ROOT/lib" "$TEST_ROOT/repo/lib"

for module in theme gtk kitty sounds flatpak; do
    recommended=yes
    requires=""
    case "$module" in
        sounds|flatpak) recommended=no ;;
    esac
    case "$module" in
        gtk|flatpak) requires=theme ;;
    esac
    mkdir -p -- "$TEST_ROOT/repo/modules/$module"
    cat >"$TEST_ROOT/repo/modules/$module/module.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
SWAY98_MODULE_ID="$module"
SWAY98_MODULE_DESC="Synthetic $module"
SWAY98_MODULE_SCOPE="user"
SWAY98_MODULE_RECOMMENDED="$recommended"
SWAY98_MODULE_REQUIRES="$requires"
SWAY98_MODULE_NEEDS_PKGS=""
sway98_apply() {
    install_file "\$SWAY98_ROOT/payload" "\$HOME/\$SWAY98_MODULE"
}
EOF
done
printf 'synthetic asset\n' >"$TEST_ROOT/repo/payload"

_sway98_test_fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

_sway98_test_run() {
    rm -rf -- "$TEST_ROOT/home" "$TEST_ROOT/state"
    mkdir -p -- "$TEST_ROOT/home"
    env -i PATH="$PATH" HOME="$TEST_ROOT/home" \
        XDG_CONFIG_HOME="$TEST_ROOT/home/.config" \
        XDG_DATA_HOME="$TEST_ROOT/home/.local/share" \
        XDG_CACHE_HOME="$TEST_ROOT/home/.cache" \
        XDG_STATE_HOME="$TEST_ROOT/state" SWAY98_NO_GSETTINGS=1 \
        bash "$TEST_ROOT/repo/install.sh" "$@" >"$TEST_ROOT/output" 2>&1
}

_sway98_test_applied() {
    local expected="$1" actual
    shift
    _sway98_test_run --yes "$@" || {
        cat "$TEST_ROOT/output" >&2
        _sway98_test_fail "installer failed: $*"
    }
    actual="$(find "$TEST_ROOT/home" -type f -printf '%f\n' | sort | tr '\n' ' ')"
    [[ "$actual" == "$expected" ]] || _sway98_test_fail "expected '$expected', got '$actual'"
    actual="$(cut -f1 "$TEST_ROOT/state/sway98/manifest/modules.tsv" | sort | tr '\n' ' ')"
    [[ "$actual" == "$expected" ]] || _sway98_test_fail "unexpected module records: $actual"
}

# Presets, repeated options, explicit selection, and the plain Bash picker.
_sway98_test_applied 'gtk kitty theme ' --all --exclude sounds,flatpak
_sway98_test_applied 'gtk kitty ' --exclude theme --recommended
grep -q "'gtk' selected without 'theme' (--exclude)" "$TEST_ROOT/output" \
    || _sway98_test_fail 'missing excluded dependency warning'
_sway98_test_applied 'gtk kitty theme ' --exclude sounds --all --exclude flatpak,sounds
_sway98_test_applied 'kitty ' --modules gtk,kitty --exclude gtk
_sway98_test_applied 'gtk ' --only gtk --exclude theme
_sway98_test_applied 'gtk kitty theme ' --exclude sounds,flatpak <<<'a'
_sway98_test_applied '' --only kitty --exclude kitty
grep -q 'nothing selected, nothing to do' "$TEST_ROOT/output" \
    || _sway98_test_fail 'missing empty selection message'

# Without exclusions, dependency expansion and selection still work.
_sway98_test_applied 'gtk theme ' --only gtk
_sway98_test_applied 'kitty ' --only kitty --exclude sounds

# Rejected input must not even create logs or manifests.
for invalid in unknown kit 1 'sounds,' ',sounds' 'sounds,,flatpak' ''; do
    if _sway98_test_run --all --exclude "$invalid"; then
        _sway98_test_fail "accepted invalid exclusion: '$invalid'"
    fi
    [[ ! -e "$TEST_ROOT/state" ]] || _sway98_test_fail 'invalid exclusion created state'
    [[ -z "$(find "$TEST_ROOT/home" -mindepth 1 -print -quit)" ]] \
        || _sway98_test_fail 'invalid exclusion changed home'
done
if _sway98_test_run --all --exclude; then
    _sway98_test_fail 'accepted --exclude without an argument'
fi
[[ ! -e "$TEST_ROOT/state" ]] || _sway98_test_fail 'missing argument created state'

# The dry-run applies the same filter without creating files or state.
_sway98_test_run --dry-run --all --exclude sounds,flatpak,theme
grep -q '^info modules to install: gtk kitty$' "$TEST_ROOT/output" \
    || _sway98_test_fail 'dry-run selection differs'
[[ ! -e "$TEST_ROOT/state" ]] || _sway98_test_fail 'dry-run created state'
[[ -z "$(find "$TEST_ROOT/home" -mindepth 1 -print -quit)" ]] \
    || _sway98_test_fail 'dry-run changed home'

printf 'ok: module exclusions (presets, explicit/menu selection, dependencies, validation, dry-run)\n'
