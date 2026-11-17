#!/usr/bin/env bash
set -euo pipefail

SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/manifest.sh
. "$SWAY98_ROOT/lib/manifest.sh"

HASH_TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$HASH_TEST_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Use external fixtures so calls made via xargs would also reach the same
# wrappers. Capture the real programs before prepending the fixture PATH.
export SWAY98_HASH_TEST_SUM SWAY98_HASH_TEST_AWK SWAY98_HASH_TEST_TRACE
SWAY98_HASH_TEST_SUM="$(command -v sha256sum)"
SWAY98_HASH_TEST_AWK="$(command -v awk)"
SWAY98_HASH_TEST_TRACE="$HASH_TEST_DIR/calls"
mkdir -- "$HASH_TEST_DIR/bin"
cat >"$HASH_TEST_DIR/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'hash\n' >>"$SWAY98_HASH_TEST_TRACE"
if [[ "${SWAY98_HASH_TEST_FAIL:-0}" == 1 ]]; then
    exit 42
fi
exec "$SWAY98_HASH_TEST_SUM" "$@"
EOF
cat >"$HASH_TEST_DIR/bin/awk" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'parser\n' >>"$SWAY98_HASH_TEST_TRACE"
exec "$SWAY98_HASH_TEST_AWK" "$@"
EOF
chmod +x -- "$HASH_TEST_DIR/bin/sha256sum" "$HASH_TEST_DIR/bin/awk"
export PATH="$HASH_TEST_DIR/bin:$PATH"
unset SWAY98_HASH_TEST_FAIL

cd -- "$HASH_TEST_DIR"
: >empty
printf abc >'file with spaces'
printf '\000\001\377\n' >-binary
ln -s 'file with spaces' link

[[ "$(sha256_of empty)" == e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]] \
    || fail 'empty file digest'
[[ "$(sha256_of 'file with spaces')" == ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ]] \
    || fail 'text file digest'
[[ "$(sha256_of link)" == ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ]] \
    || fail 'symlink digest'
expected="$("$SWAY98_HASH_TEST_SUM" -- -binary)"
[[ "$(sha256_of -binary)" == "${expected%% *}" ]] || fail 'binary file digest'
for escaped_name in 'literal\slash' $'line\nbreak' $'carriage\rreturn'; do
    printf abc >"$escaped_name"
    expected="$("$SWAY98_HASH_TEST_SUM" -- "$escaped_name" | "$SWAY98_HASH_TEST_AWK" "{print \$1}")"
    [[ "$(sha256_of "$escaped_name")" == "$expected" ]] || fail 'legacy escaped-name digest'
done
printf 'ok: empty, text, binary, spaced, escaped and leading-dash paths, symlink\n'

if sha256_of missing >result 2>/dev/null; then
    fail 'missing file accepted'
fi
[[ ! -s result ]] || fail 'missing file produced a digest'
chmod 000 -- empty
if [[ ! -r empty ]]; then
    if sha256_of empty >result 2>/dev/null; then
        fail 'unreadable file accepted'
    fi
    [[ ! -s result ]] || fail 'unreadable file produced a digest'
else
    printf 'SKIP: unreadable-file check requires an unprivileged user\n'
fi
chmod 600 -- empty
printf 'ok: file read failures propagate\n'

: >calls
for ((hash_index = 0; hash_index < 100; hash_index++)); do
    sha256_of 'file with spaces' >result
done
[[ "$(wc -l <calls)" == 100 ]] || fail 'expected one hash command and no external parser per file'
[[ "$(<result)" == ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ]] \
    || fail 'repeated hash changed output'
printf 'ok: 100 file hashes use 100 hash calls and zero parser calls\n'

# Explicit failure handling must also work in an if condition, where Bash
# disables errexit inside the function.
export SWAY98_HASH_TEST_FAIL=1
hash_status=0
sha256_of 'file with spaces' >result || hash_status=$?
[[ "$hash_status" == 42 && ! -s result ]] || fail 'hash command failure was masked'
printf 'ok: hash command exit status preserved\n'
