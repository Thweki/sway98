#!/usr/bin/env bash
set -euo pipefail

# Exercise the real Makefile with synthetic recipes: no installer, downloads,
# desktop commands, or shared repository sandbox are involved.
SWAY98_TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SWAY98_TEST_MAKE="${MAKE:-make}"
command -v "$SWAY98_TEST_MAKE" >/dev/null || {
    echo 'FAIL: make is required for the Makefile regression test' >&2
    exit 1
}
SWAY98_TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$SWAY98_TEST_TMP"' EXIT
mkdir -p -- "$SWAY98_TEST_TMP/tests" "$SWAY98_TEST_TMP/bin"
cp -- "$SWAY98_TEST_ROOT/Makefile" "$SWAY98_TEST_TMP/Makefile"

# Avoid recursive self-testing and dependence on ShellCheck in this fixture.
for stub in check-make test-selection module-presets file-hashes install-status verify-files ini-line-endings include-block; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$SWAY98_TEST_TMP/tests/$stub.sh"
done
printf '#!/usr/bin/env bash\nexit 0\n' >"$SWAY98_TEST_TMP/bin/shellcheck"
chmod +x "$SWAY98_TEST_TMP/bin/shellcheck"
cat >"$SWAY98_TEST_TMP/tests/run-sandbox.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == all ]]; then
    "$0" dry-run
    exec "$0" roundtrip
fi
case "$1" in
    dry-run) peer=roundtrip ;;
    roundtrip) peer=dry-run ;;
    *) printf 'unexpected sandbox fixture stage: %s\n' "$1" >&2; exit 2 ;;
esac

# Each recipe owns its marker; no recipe removes its peer's marker.
if [[ "${SWAY98_TEST_PARALLEL_CONTROL:-0}" == 1 ]]; then
    # Keep the arrivals until the parent cleans the fixture. The first recipe
    # waits for the second, so this does not depend on scheduling within a sleep.
    : >"arrived-$1"
    for ((poll = 0; poll < 100; poll++)); do
        if [[ -e "arrived-$peer" ]]; then
            printf 'OVERLAP: %s and %s rendezvoused\n' "$1" "$peer" >&2
            exit 1
        fi
        sleep 0.05
    done
    rm -f -- "arrived-$1"
    printf 'TIMEOUT: %s did not see %s\n' "$1" "$peer" >&2
    exit 2
fi

: >"active-$1"
trap 'rm -f -- "active-$1"' EXIT
check_peer() {
    if [[ -e "active-$peer" ]]; then
        printf 'OVERLAP: %s while %s is active\n' "$1" "$peer" >&2
        exit 1
    fi
}
check_peer "$1"
printf '%s\n' "$1" >> completed-checks
sleep 1
check_peer "$1"
if [[ "${SWAY98_TEST_FAIL:-}" == "$1" ]]; then
    printf 'INJECTED: %s\n' "$1" >&2
    exit 1
fi
EOF
chmod +x "$SWAY98_TEST_TMP/tests/run-sandbox.sh"

_sway98_test_make() {
    local injected_failure="$1" parallel_control="$2"
    shift 2
    # Use a fresh jobserver and supply the fixture's failure mode explicitly.
    env -u MAKEFLAGS -u GNUMAKEFLAGS -u MFLAGS -u MAKELEVEL \
        SWAY98_TEST_FAIL="$injected_failure" SWAY98_TEST_PARALLEL_CONTROL="$parallel_control" \
        PATH="$SWAY98_TEST_TMP/bin:$PATH" \
        "$SWAY98_TEST_MAKE" --no-print-directory -C "$SWAY98_TEST_TMP" -j8 "$@" \
        >"$SWAY98_TEST_TMP/make.log" 2>&1
}

_sway98_test_serial() {
    rm -f -- "$SWAY98_TEST_TMP/completed-checks"
    if ! _sway98_test_make "" 0 "$@"; then
        cat "$SWAY98_TEST_TMP/make.log" >&2
        exit 1
    fi
    printf 'dry-run\nroundtrip\n' >"$SWAY98_TEST_TMP/expected-checks"
    sort "$SWAY98_TEST_TMP/completed-checks" >"$SWAY98_TEST_TMP/sorted-checks"
    diff -u "$SWAY98_TEST_TMP/expected-checks" "$SWAY98_TEST_TMP/sorted-checks"
    printf 'ok   make -j8 %s runs both sandbox checks without overlap\n' "$*"
}

_sway98_test_serial check
_sway98_test_serial check-dryrun check-roundtrip
_sway98_test_serial check-roundtrip check-dryrun

if _sway98_test_make dry-run 0 check; then
    echo 'FAIL: make check swallowed a sandbox failure' >&2
    exit 1
fi
if ! grep -qx 'INJECTED: dry-run' "$SWAY98_TEST_TMP/make.log"; then
    echo 'FAIL: make check failed without reaching the injected sandbox failure' >&2
    cat "$SWAY98_TEST_TMP/make.log" >&2
    exit 1
fi
echo 'ok   make check propagates a sandbox failure'

# Prove the fixture detects the original scheduling bug, rather than merely
# passing because its synthetic work never overlaps on this machine.
sed -i '/^\.NOTPARALLEL:/d' "$SWAY98_TEST_TMP/Makefile"
# Give the two recipes a common goal so make schedules them as siblings.
printf '\n.PHONY: test-parallel-sandbox\ntest-parallel-sandbox: check-dryrun check-roundtrip\n' \
    >>"$SWAY98_TEST_TMP/Makefile"
if _sway98_test_make "" 1 test-parallel-sandbox; then
    echo 'FAIL: the fixture did not detect parallel sandbox recipes' >&2
    exit 1
fi
if ! grep -q 'OVERLAP:' "$SWAY98_TEST_TMP/make.log"; then
    echo 'FAIL: parallel sandbox control failed without demonstrating overlap' >&2
    cat "$SWAY98_TEST_TMP/make.log" >&2
    exit 1
fi
echo 'ok   removing serialization reproduces the sandbox race'
