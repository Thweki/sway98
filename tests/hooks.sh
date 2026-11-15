#!/usr/bin/env bash
set -euo pipefail

# Exercise the real entry points with tiny offline modules and isolated user state.
for variable in "${!SWAY98_@}" "${!XDG_@}"; do
    unset "$variable"
done
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_TMP="$(mktemp -d)"
trap 'rm -rf -- "$HOOK_TMP"' EXIT
HOOK_REPO="$HOOK_TMP/repo with spaces"
mkdir -p -- "$HOOK_REPO/modules/alpha" "$HOOK_REPO/modules/beta" "$HOOK_REPO/modules/failing"
cp -- "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh" "$HOOK_REPO/"
cp -a -- "$REPO_ROOT/lib" "$HOOK_REPO/lib"
printf 'fixture\n' >"$HOOK_REPO/payload"
cat >"$HOOK_REPO/modules/alpha/module.sh" <<'EOF'
SWAY98_MODULE_ID=alpha
sway98_apply() { install_file "$SWAY98_ROOT/payload" "$HOME/alpha"; }
EOF
cat >"$HOOK_REPO/modules/beta/module.sh" <<'EOF'
SWAY98_MODULE_ID=beta
SWAY98_MODULE_REQUIRES=alpha
sway98_apply() { install_file "$SWAY98_ROOT/payload" "$HOME/beta"; }
EOF
cat >"$HOOK_REPO/modules/failing/module.sh" <<'EOF'
SWAY98_MODULE_ID=failing
sway98_apply() { return 19; }
EOF

_sway98_fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
_sway98_case() {
    export HOME="$HOOK_TMP/$1/home"
    export XDG_CONFIG_HOME="$HOME/config with spaces"
    export XDG_STATE_HOME="$HOOK_TMP/$1/state"
    export XDG_CACHE_HOME="$HOOK_TMP/$1/cache"
    export XDG_DATA_HOME="$HOME/data"
    export SWAY98_NO_GSETTINGS=1
    export HOOK_TRACE="$HOOK_TMP/$1/trace"
    unset SWAY98_STATE SWAY98_NO_HOOKS SWAYSOCK WAYLAND_DISPLAY
    mkdir -p -- "$HOME"
    HOOK_DIR="$XDG_CONFIG_HOME/sway98/hooks"
}
_sway98_run() {
    local expected="$1" entry="$2" actual=0
    shift 2
    bash "$HOOK_REPO/$entry.sh" "$@" >"$HOOK_TMP/output" 2>&1 || actual=$?
    if [[ "$actual" != "$expected" ]]; then
        cat "$HOOK_TMP/output" >&2
        _sway98_fail "$entry $*: expected exit $expected, got $actual"
    fi
}
_sway98_hooks() {
    mkdir -p -- "$HOOK_DIR"
    cat >"$HOOK_DIR/post-install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -f "$HOME/alpha" && -s "$SWAY98_STATE/manifest/modules.tsv" ]]
printf '%s|%s|%s\n' "$SWAY98_HOOK_EVENT" "$*" "$SWAY98_STATE" >>"$HOOK_TRACE"
# An executed hook cannot change its parent's state or shell.
SWAY98_STATE=/not-the-installers-state
cd /
exit 0
EOF
    cat >"$HOOK_DIR/post-uninstall" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if (($#)); then
    [[ "$1" == alpha && ! -e "$HOME/alpha" && -f "$HOME/beta" ]]
else
    [[ ! -e "$HOME/alpha" && ! -e "$HOME/beta" ]]
    [[ ! -s "$SWAY98_STATE/manifest/files.tsv" ]]
    [[ -d "$SWAY98_STATE/manifest/history" ]]
fi
printf '%s|%s|%s\n' "$SWAY98_HOOK_EVENT" "$*" "$SWAY98_STATE" >>"$HOOK_TRACE"
EOF
    chmod +x -- "$HOOK_DIR/post-install" "$HOOK_DIR/post-uninstall"
}

_sway98_case absent
_sway98_run 0 install --yes --only alpha
_sway98_run 0 uninstall --yes
[[ ! -e "$HOOK_TRACE" && ! -e "$HOOK_DIR" ]] || _sway98_fail 'absent hooks created files'
printf 'ok: absent hooks are optional and create no hook directory\n'

_sway98_case lifecycle
_sway98_hooks
_sway98_run 0 install --yes --only beta
_sway98_run 0 install --yes --only beta
_sway98_run 0 uninstall --only alpha
_sway98_run 0 uninstall --yes
printf '%s\n' \
    "post-install|beta alpha|$XDG_STATE_HOME/sway98" \
    "post-install|beta alpha|$XDG_STATE_HOME/sway98" \
    "post-uninstall|alpha|$XDG_STATE_HOME/sway98" \
    "post-uninstall||$XDG_STATE_HOME/sway98" >"$HOOK_TMP/expected"
cmp -s "$HOOK_TMP/expected" "$HOOK_TRACE" || _sway98_fail 'hook scope, order or invocation count differs'
[[ -x "$HOOK_DIR/post-install" && -x "$HOOK_DIR/post-uninstall" ]] || _sway98_fail 'uninstall removed user hooks'
grep -q 'hook completed: post-uninstall' "$XDG_STATE_HOME"/sway98/log/uninstall-*.log
printf 'ok: dependencies, reinstall, partial/full rollback, isolation, logs and user script retention\n'

for config_mode in unset empty; do
    _sway98_case "config-$config_mode"
    if [[ "$config_mode" == unset ]]; then unset XDG_CONFIG_HOME; else export XDG_CONFIG_HOME=''; fi
    HOOK_DIR="$HOME/.config/sway98/hooks"
    export SWAY98_STATE="$HOOK_TMP/config-$config_mode/custom state"
    _sway98_hooks
    _sway98_run 0 install --yes --only alpha
    _sway98_run 0 uninstall --yes
    grep -Fxq "post-install|alpha|$SWAY98_STATE" "$HOOK_TRACE"
done
printf 'ok: unset/empty XDG fallback and explicit state override\n'

_sway98_case dry
_sway98_hooks
cp -a -- "$HOME" "$HOOK_TMP/pristine-home"
_sway98_run 0 install --dry-run --yes --only alpha
grep -Fq "would run hook $HOOK_DIR/post-install" "$HOOK_TMP/output"
diff -r "$HOOK_TMP/pristine-home" "$HOME"
[[ ! -e "$HOOK_TRACE" && ! -e "$XDG_STATE_HOME" ]] || _sway98_fail 'dry install wrote state or ran hook'
_sway98_run 0 install --yes --only alpha --no-hooks
cp -a -- "$XDG_STATE_HOME" "$HOOK_TMP/pristine-state"
_sway98_run 0 uninstall --dry-run --yes
grep -Fq "would run hook $HOOK_DIR/post-uninstall" "$HOOK_TMP/output"
diff -r "$HOOK_TMP/pristine-state" "$XDG_STATE_HOME"
[[ -f "$HOME/alpha" && ! -e "$HOOK_TRACE" ]] || _sway98_fail 'dry uninstall changed files or ran hook'
_sway98_run 0 uninstall --yes --no-hooks
[[ ! -e "$HOOK_TRACE" ]] || _sway98_fail '--no-hooks ran a hook'
printf 'ok: dry runs preview without effects; --no-hooks suppresses both events\n'

_sway98_case skip
_sway98_hooks
for entry in install uninstall; do
    _sway98_run 0 "$entry" --help
    _sway98_run 0 "$entry" --list
done
_sway98_run 0 install --recommended --yes
_sway98_run 0 uninstall --yes
_sway98_run 0 install --only alpha </dev/null
[[ ! -e "$HOOK_TRACE" ]] || _sway98_fail 'read-only, empty or cancelled operation ran hook'
_sway98_run 0 install --yes --only alpha --no-hooks
_sway98_run 0 uninstall </dev/null
[[ ! -e "$HOOK_TRACE" && -f "$HOME/alpha" ]] || _sway98_fail 'cancelled uninstall ran hook'
printf 'ok: help, list, empty selection, absent manifest and cancelled operations skip hooks\n'

_sway98_case invalid
_sway98_hooks
chmod -x -- "$HOOK_DIR/post-install"
_sway98_run 0 install --yes --only alpha
grep -q 'skipping hook.*executable regular file' "$HOOK_TMP/output"
rm -- "$HOOK_DIR/post-uninstall"
mkdir -- "$HOOK_DIR/post-uninstall"
_sway98_run 0 uninstall --yes
grep -q 'skipping hook.*executable regular file' "$HOOK_TMP/output"
rm -- "$HOOK_DIR/post-install"
ln -s missing "$HOOK_DIR/post-install"
_sway98_run 0 install --yes --only alpha
grep -q 'skipping hook.*executable regular file' "$HOOK_TMP/output"
[[ ! -e "$HOOK_TRACE" ]] || _sway98_fail 'invalid hook ran'
printf 'ok: non-executable files, directories and dangling symlinks are reported and skipped\n'

_sway98_case failure
_sway98_hooks
cat >"$HOOK_DIR/post-install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 23
EOF
_sway98_run 23 install --yes --only alpha
grep -Fq "hook $HOOK_DIR/post-install failed (exit 23)" "$HOOK_TMP/output"
grep -q 'failed (exit 23)' "$XDG_STATE_HOME"/sway98/log/install-*.log
[[ -f "$HOME/alpha" && -s "$XDG_STATE_HOME/sway98/manifest/files.tsv" ]] || _sway98_fail 'hook failure undid install'
_sway98_run 0 install --yes --only alpha --no-hooks
cat >"$HOOK_DIR/post-install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
false
printf 'unreachable\n' >>"$HOOK_TRACE"
EOF
_sway98_run 1 install --yes --only alpha
[[ ! -e "$HOOK_TRACE" ]] || _sway98_fail 'hook lost its own errexit behavior'
cat >"$HOOK_DIR/post-uninstall" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 31
EOF
_sway98_run 31 uninstall --yes
grep -Fq "hook $HOOK_DIR/post-uninstall failed (exit 31)" "$HOOK_TMP/output"
grep -q 'failed (exit 31)' "$XDG_STATE_HOME"/sway98/log/uninstall-*.log
[[ ! -e "$HOME/alpha" && ! -s "$XDG_STATE_HOME/sway98/manifest/files.tsv" ]] || _sway98_fail 'hook failure undid rollback'
printf 'ok: hook failures preserve completed operations and report exit status in terminal and log\n'

_sway98_case core-failure
_sway98_hooks
_sway98_run 1 install --yes --modules alpha,failing
[[ -f "$HOME/alpha" && ! -e "$HOOK_TRACE" ]] || _sway98_fail 'failed install ran hook'
# A directory where a managed file was expected makes rollback fail fatally.
rm -- "$HOME/alpha"
mkdir -- "$HOME/alpha"
_sway98_run 123 uninstall --yes
[[ ! -e "$HOOK_TRACE" ]] || _sway98_fail 'failed rollback ran hook'
printf 'ok: fatal install and rollback errors skip hooks\n'
