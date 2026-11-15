#!/usr/bin/env bash
set -euo pipefail

SWAY98_TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SWAY98_TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$SWAY98_TEST_TMP"' EXIT
mkdir -p -- "$SWAY98_TEST_TMP/tree/home" "$SWAY98_TEST_TMP/bin"

sway98_test_fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Neither desktop tools nor network access are needed, even for the fixtures.
for tool in curl git pacman gsettings flatpak swaymsg fc-cache; do
    cat >"$SWAY98_TEST_TMP/bin/$tool" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected external command\n' >>"$HOME/tool-called"
exit 99
EOF
    chmod +x "$SWAY98_TEST_TMP/bin/$tool"
done

sway98_test_snapshot() {
    find "$SWAY98_TEST_TMP/tree" -printf '%y %m %T@ %p %l\n' | sort
    find "$SWAY98_TEST_TMP/tree" -type f -exec sha256sum -- {} + | sort
}

sway98_test_verify() {
    local expected_exit="$1" actual_exit=0
    shift
    sway98_test_snapshot >"$SWAY98_TEST_TMP/before"
    env -i PATH="$SWAY98_TEST_TMP/bin:$PATH" \
        HOME="$SWAY98_TEST_TMP/tree/home" \
        XDG_STATE_HOME="$SWAY98_TEST_TMP/tree/state" \
        SWAY98_LOG="$SWAY98_TEST_TMP/tree/inherited.log" \
        bash "$SWAY98_TEST_ROOT/install.sh" "$@" \
        >"$SWAY98_TEST_TMP/output" 2>&1 || actual_exit=$?
    [[ "$actual_exit" == "$expected_exit" ]] || {
        cat "$SWAY98_TEST_TMP/output" >&2
        sway98_test_fail "expected exit $expected_exit, got $actual_exit"
    }
    sway98_test_snapshot >"$SWAY98_TEST_TMP/after"
    diff -u -- "$SWAY98_TEST_TMP/before" "$SWAY98_TEST_TMP/after" ||
        sway98_test_fail 'verification changed files, links, state or logs'
}

sway98_test_expect() {
    grep -Fq -- "$1" "$SWAY98_TEST_TMP/output" || sway98_test_fail "missing output: $1"
}

sway98_test_verify 0 --verify
sway98_test_expect 'No managed file records'
[[ ! -e "$SWAY98_TEST_TMP/tree/state" ]] || sway98_test_fail 'verification created state'
for selection in --all --recommended --list; do
    sway98_test_verify 1 --verify "$selection"
    sway98_test_expect 'cannot be combined'
    sway98_test_verify 1 "$selection" --verify
done
sway98_test_verify 1 --only mako --verify
sway98_test_verify 1 --verify --modules theme
printf 'ok: empty state and conflicting options are read-only\n'

# Generate real manifest records, including two versions owned by different
# modules and a dangling link with empty hash columns.
env -i PATH="$PATH" HOME="$SWAY98_TEST_TMP/tree/home" \
    XDG_STATE_HOME="$SWAY98_TEST_TMP/tree/state" \
    bash -s -- "$SWAY98_TEST_ROOT" "$SWAY98_TEST_TMP" <<'EOF' >"$SWAY98_TEST_TMP/fixture.log" 2>&1
set -euo pipefail
SWAY98_ROOT="$1"
# shellcheck source=lib/common.sh
. "$SWAY98_ROOT/lib/common.sh"
# shellcheck source=lib/manifest.sh
. "$SWAY98_ROOT/lib/manifest.sh"
manifest_init
SWAY98_MODULE=first
printf 'old\n' >"$2/source"
install_file "$2/source" "$HOME/tracked file"
SWAY98_MODULE=latest
printf 'latest\n' >"$2/source"
install_file "$2/source" "$HOME/tracked file"
install_file "$2/source" "$HOME/second"
ln -s absent "$2/source-link"
install_symlink "$2/source-link" "$HOME/link"
# A verifier must never evaluate commands or display their contents.
record_cmd 'touch "$HOME/rollback-executed"'
EOF

manifest="$SWAY98_TEST_TMP/tree/state/sway98/manifest/files.tsv"
test_home="$SWAY98_TEST_TMP/tree/home"
printf 'keep this log\n' >"$SWAY98_TEST_TMP/tree/inherited.log"
sway98_test_verify 0 --verify
sway98_test_expect 'Verification: 2 matched, 0 problem(s), 1 unverified symlink(s).'
sway98_test_expect "OK  latest  $test_home/tracked file"
sway98_test_expect "UNVERIFIED  latest  $test_home/link"
[[ "$(grep -Fc -- "$test_home/tracked file" "$SWAY98_TEST_TMP/output")" == 1 ]] ||
    sway98_test_fail 'duplicate path checked more than once'
if grep -q 'rollback-executed' "$SWAY98_TEST_TMP/output"; then
    sway98_test_fail 'printed a rollback command'
fi
sway98_test_verify 0 --dry-run --verify
printf 'ok: latest hashes, shared paths, spaces and unverified dangling links\n'

printf 'edited\n' >"$test_home/tracked file"
rm -- "$test_home/second" "$test_home/link"
printf 'replacement\n' >"$test_home/link"
sway98_test_verify 1 --verify
sway98_test_expect "CHANGED  latest  $test_home/tracked file"
sway98_test_expect "MISSING  latest  $test_home/second"
sway98_test_expect "TYPE-CHANGED  latest  $test_home/link"
sway98_test_expect 'Verification: 0 matched, 3 problem(s), 0 unverified symlink(s).'
printf 'ok: edits, deletions and symlink replacement detected\n'

rm -- "$test_home/tracked file" "$test_home/link"
ln -s "$SWAY98_TEST_TMP/source" "$test_home/tracked file"
mkfifo "$test_home/second"
ln -s absent "$test_home/link"
sway98_test_verify 1 --verify
sway98_test_expect "TYPE-CHANGED  latest  $test_home/tracked file"
sway98_test_expect "TYPE-CHANGED  latest  $test_home/second"
rm -- "$test_home/second"
mkdir -- "$test_home/second"
sway98_test_verify 1 --verify
sway98_test_expect "TYPE-CHANGED  latest  $test_home/second"
printf 'ok: regular files replaced by links, FIFOs or directories are not hashed\n'

rm -- "$test_home/tracked file"
cp -- "$SWAY98_TEST_TMP/source" "$test_home/tracked file"
if [[ "$EUID" != 0 ]]; then
    chmod 000 "$test_home/tracked file"
    # The snapshot cannot hash a mode-000 fixture either. Test the error and
    # compare the manifest separately, then restore access for later snapshots.
    cp -- "$manifest" "$SWAY98_TEST_TMP/saved-manifest"
    env -i PATH="$PATH" HOME="$test_home" \
        XDG_STATE_HOME="$SWAY98_TEST_TMP/tree/state" \
        bash "$SWAY98_TEST_ROOT/install.sh" --verify >"$SWAY98_TEST_TMP/output" 2>&1 &&
        sway98_test_fail 'unreadable file passed verification'
    sway98_test_expect "ERROR  latest  $test_home/tracked file"
    chmod 644 "$test_home/tracked file"
    cmp -- "$manifest" "$SWAY98_TEST_TMP/saved-manifest" || sway98_test_fail 'manifest changed'
    printf 'ok: unreadable file reported\n'
else
    printf 'SKIP: permission denial requires a non-root user\n'
fi

cp -- "$manifest" "$SWAY98_TEST_TMP/valid-manifest"
for bad_row in 'truncated' $'module\tcreate\trelative\t\t\t' \
    $'module\tunknown\t/unused\t\t\t' $'module\tcreate\t/unused\tbad-hash\t\t'; do
    cp -- "$SWAY98_TEST_TMP/valid-manifest" "$manifest"
    printf '%s\n' "$bad_row" >>"$manifest"
    sway98_test_verify 1 --verify
    sway98_test_expect 'Invalid or unreadable file manifest'
done
: >"$manifest"
sway98_test_verify 0 --verify
sway98_test_expect 'No managed file records'
rm -- "$manifest"
ln -s absent "$manifest"
sway98_test_verify 1 --verify
sway98_test_expect 'Cannot read the file manifest'
rm -- "$manifest"
mkdir -- "$manifest"
sway98_test_verify 1 --verify
sway98_test_expect 'Cannot read the file manifest'
printf 'ok: malformed, empty and unreadable manifest paths handled\n'
