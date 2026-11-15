#!/usr/bin/env bash
set -euo pipefail

SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/manifest.sh
. "$SWAY98_ROOT/lib/manifest.sh"

HASH_TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$HASH_TEST_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Count invocations across command substitutions without replacing the real
# hasher. A parser regression must fail even when its output is still correct.
sha256sum() {
    printf 'hash\n' >>"$HASH_TEST_DIR/calls"
    command sha256sum "$@"
}
awk() {
    printf 'parser\n' >>"$HASH_TEST_DIR/calls"
    command awk "$@"
}

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
expected="$(command sha256sum -- -binary)"
[[ "$(sha256_of -binary)" == "${expected%% *}" ]] || fail 'binary file digest'
printf 'ok: empty, text, binary, spaced and leading-dash paths, symlink\n'

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
sha256sum() { return 42; }
hash_status=0
sha256_of 'file with spaces' >result || hash_status=$?
[[ "$hash_status" == 42 && ! -s result ]] || fail 'hash command failure was masked'
printf 'ok: hash command exit status preserved\n'
