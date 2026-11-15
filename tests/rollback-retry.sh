#!/usr/bin/env bash
# Rollback lifecycle regressions. All state and commands stay in a temporary tree.
set -euo pipefail

SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT
TEST_PATH="$PATH"
REAL_CP="$(command -v cp)"
REAL_RM="$(command -v rm)"

fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$TEST_TMP/uninstall.log" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

fixture() {
    CASE_ROOT="$TEST_TMP/$1"
    MANIFEST="$CASE_ROOT/state/manifest"
    mkdir -p -- "$MANIFEST" "$CASE_ROOT/home" "$CASE_ROOT/bin" "$CASE_ROOT/backups"
    local kind
    for kind in files commands dirs modules; do
        : >"$MANIFEST/$kind.tsv"
    done
}

module_row() { printf '%s\tok\t0.1.0\ttest\n' "$1" >>"$MANIFEST/modules.tsv"; }
file_row() { printf '%s\t%s\t%s\tnew\told\t%s\n' "$1" "$2" "$3" "${4:-}" >>"$MANIFEST/files.tsv"; }
run_uninstall() {
    env HOME="$CASE_ROOT/home" SWAY98_STATE="$CASE_ROOT/state" \
        SWAY98_LOG='' SWAY98_DRY_RUN=0 SWAY98_TS=retry-test \
        SWAY98_FAIL_COPY="$CASE_ROOT/backups/original" SWAY98_REAL_CP="$REAL_CP" \
        SWAY98_FAIL_REMOVE="$CASE_ROOT/home/blocked" SWAY98_REAL_RM="$REAL_RM" \
        PATH="$CASE_ROOT/bin:$TEST_PATH" \
        bash "$SWAY98_ROOT/uninstall.sh" --yes "$@" >"$TEST_TMP/uninstall.log" 2>&1
}
expect_failure() {
    if run_uninstall "$@"; then fail 'rollback unexpectedly succeeded'; fi
    grep -q 'done' "$TEST_TMP/uninstall.log" && fail 'failed rollback reported completion'
    return 0
}
expect_success() { run_uninstall "$@" || fail 'rollback failed'; }
rows() {
    local actual
    actual="$(wc -l <"$MANIFEST/$1.tsv")"
    [[ "$actual" -eq "$2" ]] || fail "$1: expected $2 active rows, got $actual"
}
history_rows() {
    find "$MANIFEST/history" -name "$1.tsv" -exec cat -- {} + | sort
}
empty_manifest() {
    local kind
    for kind in files commands dirs modules; do rows "$kind" 0; done
}

fixture missing-backup
module_row broken
module_row healthy
printf 'themed\n' >"$CASE_ROOT/home/config"
printf 'created\n' >"$CASE_ROOT/home/created"
file_row broken modify "$CASE_ROOT/home/config" "$CASE_ROOT/backups/original"
file_row broken modify "$CASE_ROOT/home/config" "$CASE_ROOT/backups/intermediate"
file_row healthy create "$CASE_ROOT/home/created"
expect_failure
rows files 2
rows modules 1
[[ -e "$CASE_ROOT/home/created" ]] && fail 'successful deletion was not performed'
[[ "$(cat "$CASE_ROOT/home/config")" == themed ]] || fail 'missing backup changed the target'
[[ "$(history_rows files | wc -l)" -eq 1 ]] || fail 'history includes unresolved file rows'
expect_failure
rows files 2
printf 'original\n' >"$CASE_ROOT/backups/original"
expect_success
empty_manifest
[[ "$(cat "$CASE_ROOT/home/config")" == original ]] || fail 'retry did not restore original'
[[ "$(history_rows files | wc -l)" -eq 3 ]] || fail 'retry lost history from the same timestamp'
pass 'missing backups stay active; successful paths are consumed; ordinary retry restores the original'

fixture failed-copy
module_row copy
printf 'original\n' >"$CASE_ROOT/backups/original"
printf 'themed\n' >"$CASE_ROOT/home/config"
file_row copy modify "$CASE_ROOT/home/config" "$CASE_ROOT/backups/original"
cat >"$CASE_ROOT/bin/cp" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for copy_arg in "$@"; do
    [[ "$copy_arg" != "$SWAY98_FAIL_COPY" ]] || exit 73
done
exec "$SWAY98_REAL_CP" "$@"
SH
chmod +x "$CASE_ROOT/bin/cp"
expect_failure
rows files 1
rows modules 1
[[ "$(cat "$CASE_ROOT/home/config")" == themed ]] || fail 'failed copy changed the target'
rm -- "$CASE_ROOT/bin/cp"
expect_success
empty_manifest
[[ "$(cat "$CASE_ROOT/home/config")" == original ]] || fail 'copy retry did not restore original'
pass 'failed restore copies return nonzero and retain their records for retry'

fixture commands
module_row commands
printf -v command_prefix 'printf "attempt\\n" >> %q; test -e %q' "$CASE_ROOT/attempts" "$CASE_ROOT/allow"
printf 'commands\t%s\n' "$command_prefix" >>"$MANIFEST/commands.tsv"
printf 'commands\tprintf "success\\n" >> %q\n' "$CASE_ROOT/successes" >>"$MANIFEST/commands.tsv"
# A command can explicitly exit; it must not exit the rollback engine itself.
printf 'commands\texit 42\n' >>"$MANIFEST/commands.tsv"
expect_failure
rows commands 2
rows modules 1
[[ "$(wc -l <"$CASE_ROOT/successes")" -eq 1 ]] || fail 'successful command did not execute'
touch "$CASE_ROOT/allow"
expect_failure
rows commands 1
[[ "$(wc -l <"$CASE_ROOT/successes")" -eq 1 ]] || fail 'consumed command ran again'
[[ "$(wc -l <"$CASE_ROOT/attempts")" -eq 2 ]] || fail 'failed command was not retried'
[[ "$(history_rows commands | wc -l)" -eq 2 ]] || fail 'failed command was archived'
sed -i 's/exit 42/true/' "$MANIFEST/commands.tsv"
expect_success
empty_manifest
[[ "$(wc -l <"$CASE_ROOT/successes")" -eq 1 ]] || fail 'consumed command ran during final retry'
pass 'failed commands stay active while successful commands are never replayed'

fixture unknown-action
module_row unknown
printf 'untouched\n' >"$CASE_ROOT/home/config"
file_row unknown mystery "$CASE_ROOT/home/config"
expect_failure
rows files 1
rows modules 1
[[ "$(cat "$CASE_ROOT/home/config")" == untouched ]] || fail 'unknown action changed the target'
pass 'unknown file actions fail and remain active'

fixture failed-removal
module_row remove
printf 'blocked\n' >"$CASE_ROOT/home/blocked"
printf 'created\n' >"$CASE_ROOT/home/created"
file_row remove create "$CASE_ROOT/home/blocked"
file_row remove create "$CASE_ROOT/home/created"
cat >"$CASE_ROOT/bin/rm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
remove_status=0
for remove_arg in "$@"; do
    case "$remove_arg" in
        -f|--) continue ;;
    esac
    if [[ "$remove_arg" == "$SWAY98_FAIL_REMOVE" ]]; then
        remove_status=74
    else
        "$SWAY98_REAL_RM" -f -- "$remove_arg"
    fi
done
exit "$remove_status"
SH
chmod +x "$CASE_ROOT/bin/rm"
expect_failure
rows files 1
[[ ! -e "$CASE_ROOT/home/created" ]] || fail 'successful batch deletion was not consumed'
rm -- "$CASE_ROOT/bin/rm"
expect_success
empty_manifest
pass 'partial batch deletion consumes only paths actually removed'

fixture directories-only
module_row dirs
mkdir -- "$CASE_ROOT/home/owned"
printf 'user data\n' >"$CASE_ROOT/home/owned/user-file"
printf 'dirs\t%s\n' "$CASE_ROOT/home/owned" >>"$MANIFEST/dirs.tsv"
expect_failure
rows dirs 1
rows modules 1
rm -- "$CASE_ROOT/home/owned/user-file"
expect_success
empty_manifest
[[ ! -e "$CASE_ROOT/home/owned" ]] || fail 'directory-only retry did not remove the directory'
pass 'directory failures remain active and directory-only manifests can be retried'

fixture filtered
module_row alpha
module_row alpha
module_row beta
mkdir -- "$CASE_ROOT/home/alpha-dir" "$CASE_ROOT/home/alpha-empty" "$CASE_ROOT/home/beta-dir"
printf 'original\n' >"$CASE_ROOT/backups/original"
printf 'themed\n' >"$CASE_ROOT/home/alpha-dir/config"
printf 'beta\n' >"$CASE_ROOT/home/beta-dir/config"
file_row alpha modify "$CASE_ROOT/home/alpha-dir/config" "$CASE_ROOT/backups/original"
file_row alpha modify "$CASE_ROOT/home/alpha-dir/config" "$CASE_ROOT/backups/original"
file_row beta create "$CASE_ROOT/home/beta-dir/config"
printf 'alpha\t%s\n' "$CASE_ROOT/home/alpha-empty" >>"$MANIFEST/dirs.tsv"
printf 'beta\t%s\n' "$CASE_ROOT/home/beta-dir" >>"$MANIFEST/dirs.tsv"
printf 'alpha\tprintf "alpha\\n" >> %q\n' "$CASE_ROOT/commands" >>"$MANIFEST/commands.tsv"
printf 'beta\tprintf "beta\\n" >> %q\n' "$CASE_ROOT/commands" >>"$MANIFEST/commands.tsv"
cp -a -- "$CASE_ROOT/state" "$CASE_ROOT/before-dry-run"
expect_success --dry-run --only alpha
diff -r -- "$CASE_ROOT/before-dry-run" "$CASE_ROOT/state" || fail 'dry run changed manifest state'
[[ "$(cat "$CASE_ROOT/home/alpha-dir/config")" == themed ]] || fail 'dry run changed the target'
for kind in files commands dirs modules; do
    grep '^beta' "$MANIFEST/$kind.tsv" >"$CASE_ROOT/beta-$kind"
done
expect_success --only alpha
for kind in files commands dirs modules; do
    cmp -- "$CASE_ROOT/beta-$kind" "$MANIFEST/$kind.tsv" || fail "filtered rollback changed beta $kind rows"
done
[[ "$(cat "$CASE_ROOT/home/alpha-dir/config")" == original ]] || fail 'filtered uninstall did not restore original'
[[ ! -e "$CASE_ROOT/home/alpha-empty" ]] || fail 'filtered uninstall did not consume its directory'
printf 'later user edit\n' >"$CASE_ROOT/home/alpha-dir/config"
cp -a -- "$CASE_ROOT/state/manifest" "$CASE_ROOT/after-alpha"
expect_success --only alpha
diff -r -- "$CASE_ROOT/after-alpha" "$MANIFEST" || fail 'repeated module rollback changed its manifest'
[[ "$(cat "$CASE_ROOT/home/alpha-dir/config")" == 'later user edit' ]] || fail 'repeated module rollback discarded user edits'
[[ "$(cat "$CASE_ROOT/commands")" == alpha ]] || fail 'filtered command ran more than once or ran beta'
expect_success
empty_manifest
[[ ! -e "$CASE_ROOT/home/beta-dir" ]] || fail 'full uninstall did not remove remaining module'
[[ "$(cat "$CASE_ROOT/home/alpha-dir/config")" == 'later user edit' ]] || fail 'full rollback replayed a consumed backup'
[[ "$(history_rows files | wc -l)" -eq 3 ]] || fail 'filtered uninstall did not archive every consumed file row'
expect_success
pass 'filtered rollback consumes all selected records, preserves other modules, and never replays old backups'

fixture filtered-failure
module_row alpha
module_row beta
printf 'themed\n' >"$CASE_ROOT/home/config"
file_row alpha modify "$CASE_ROOT/home/config" "$CASE_ROOT/backups/original"
file_row beta create "$CASE_ROOT/home/beta"
printf 'created\n' >"$CASE_ROOT/home/alpha-created"
file_row alpha create "$CASE_ROOT/home/alpha-created"
expect_failure --only alpha
[[ ! -e "$CASE_ROOT/home/alpha-created" ]] || fail 'filtered failure did not consume successful paths'
rows files 2
rows modules 2
printf 'original\n' >"$CASE_ROOT/backups/original"
expect_success --only alpha
rows files 1
rows modules 1
pass 'filtered failures retain retry state without consuming unrelated modules'

fixture symlink-backup
module_row link
ln -s missing-original-target "$CASE_ROOT/backups/link"
ln -s themed-target "$CASE_ROOT/home/link"
printf 'link\tmodify\t%s\t\t\t%s\n' "$CASE_ROOT/home/link" "$CASE_ROOT/backups/link" >>"$MANIFEST/files.tsv"
expect_success
empty_manifest
[[ "$(readlink -- "$CASE_ROOT/home/link")" == missing-original-target ]] || fail 'dangling symlink backup was not restored'
pass 'empty hash columns and dangling symlink backups are preserved'
