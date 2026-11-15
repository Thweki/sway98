#!/usr/bin/env bash
set -euo pipefail

# Run the real checks once, asserting fixture reuse without timing thresholds.
SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

BASH_XTRACEFD=3 bash -x "$SWAY98_ROOT/tests/run-sandbox.sh" all \
    3>"$TEST_TMP/trace" >"$TEST_TMP/output" 2>&1 || {
    cat "$TEST_TMP/output" >&2
    fail "combined sandbox checks failed"
}
cat "$TEST_TMP/output"
[[ "$(grep -c '^+ seed_home$' "$TEST_TMP/trace")" == 1 ]] || fail "fixture must be seeded once"
grep -q 'dry run left the sandbox untouched' "$TEST_TMP/output" || fail "dry-run checks were skipped"
grep -q 'byte for byte identical to the pristine copy' "$TEST_TMP/output" || fail "roundtrip checks were skipped"
printf 'ok   combined checks reused one sandbox fixture\n'
