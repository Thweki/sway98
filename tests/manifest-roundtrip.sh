#!/usr/bin/env bash
# Focused, offline transaction tests; all writes stay in a temporary directory.
set -euo pipefail

SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# shellcheck source=lib/common.sh
source "$SWAY98_ROOT/lib/common.sh"
# shellcheck source=lib/manifest.sh
source "$SWAY98_ROOT/lib/manifest.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

replacement_roundtrip() (
    local original="$1" replacement="$2" dest expected_record link_target=targets/installed
    export HOME="$TEST_ROOT/$original-$replacement/home"
    SWAY98_STATE="$TEST_ROOT/$original-$replacement/state"
    SWAY98_MODULE=roundtrip
    SWAY98_LOG=""
    SWAY98_DRY_RUN=0
    mkdir -p -- "$HOME/targets/directory" "$HOME/sources"
    printf 'original target\n' >"$HOME/targets/file"
    printf 'installed target\n' >"$HOME/targets/installed"
    printf 'directory sentinel\n' >"$HOME/targets/directory/sentinel"
    printf 'installed content\n' >"$HOME/sources/file"
    [[ "$replacement" != dangling-link ]] || link_target=targets/missing-installed
    ln -s -- "$link_target" "$HOME/sources/link"
    dest="$HOME/entry with spaces"
    case "$original" in
        absent) ;;
        file) printf 'user content\n' >"$dest"; chmod 640 "$dest" ;;
        link) ln -s targets/file "$dest" ;;
        dangling) ln -s targets/missing "$dest" ;;
        directory-link) ln -s targets/directory "$dest" ;;
        matching-link) ln -s sources/file "$dest" ;;
    esac
    cp -a -- "$HOME" "${HOME%/home}/pristine"
    manifest_init

    if [[ "$replacement" == file ]]; then
        install_file "$HOME/sources/file" "$dest"
        [[ -f "$dest" && ! -L "$dest" ]] || fail "file install left a link"
        cmp -s -- "$HOME/sources/file" "$dest" || fail "installed file content"
    else
        install_symlink "$HOME/sources/link" "$dest"
        [[ -L "$dest" && "$(readlink -- "$dest")" == "$link_target" ]] || fail "installed link target"
    fi
    expected_record="$(_manifest_earliest_record "$dest")"
    [[ -n "$expected_record" ]] || fail "replacement was not recorded"

    # Switch types twice, then reinstall: the first backup and action must win.
    if [[ "$replacement" == file ]]; then
        install_symlink "$HOME/sources/link" "$dest"
        install_file "$HOME/sources/file" "$dest"
        install_file "$HOME/sources/file" "$dest"
    else
        install_file "$HOME/sources/file" "$dest"
        install_symlink "$HOME/sources/link" "$dest"
        install_symlink "$HOME/sources/link" "$dest"
    fi
    [[ "$(_manifest_earliest_record "$dest")" == "$expected_record" ]] || fail "original record changed"

    cp -a -- "$HOME" "${HOME%/home}/installed"
    SWAY98_DRY_RUN=1
    restore_all roundtrip
    diff -r --no-dereference -- "${HOME%/home}/installed" "$HOME" || fail "dry restore changed files"
    SWAY98_DRY_RUN=0
    restore_all roundtrip
    diff -r --no-dereference -- "${HOME%/home}/pristine" "$HOME" || fail "replacement did not roundtrip"
    if [[ "$original" == file ]]; then
        [[ "$(stat -c '%a' -- "$dest")" == 640 ]] || fail "original mode was lost"
    fi
)

empty_fields_roundtrip() (
    SWAY98_STATE="$TEST_ROOT/empty-fields/state"
    SWAY98_LOG=""
    SWAY98_DRY_RUN=0
    local dest="$TEST_ROOT/empty-fields/file" backup="$TEST_ROOT/empty-fields/backup with spaces"
    local parsed_module parsed_action parsed_path parsed_new parsed_old parsed_backup
    local tsv_row=$'\tmodify\t path with \\ and spaces \t\t\t'
    _manifest_split_tsv "$tsv_row" parsed_module parsed_action parsed_path parsed_new parsed_old parsed_backup
    [[ "$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$parsed_module" "$parsed_action" "$parsed_path" \
        "$parsed_new" "$parsed_old" "$parsed_backup")" == "$tsv_row" ]] || fail "TSV fields were not preserved"
    manifest_init
    printf 'original\n' >"$backup"
    printf 'replacement\n' >"$dest"
    # Both hashes are intentionally empty: backup must remain the sixth field.
    manifest_record_file empty-fields modify "$dest" "" "" "$backup"
    restore_all empty-fields
    cmp -s -- "$backup" "$dest" || fail "empty fields shifted the backup column"
)

if [[ "${1:-}" == --case ]]; then
    replacement_roundtrip "$2" "$3"
    exit 0
fi
if [[ "${1:-}" == --empty-fields ]]; then
    empty_fields_roundtrip
    exit 0
fi

failures=0
if bash "$SWAY98_ROOT/tests/manifest-roundtrip.sh" --empty-fields >"$TEST_ROOT/empty-fields.log" 2>&1; then
    printf 'ok: empty manifest fields\n'
else
    cat -- "$TEST_ROOT/empty-fields.log" >&2
    failures=$((failures + 1))
fi
for original in absent file link dangling directory-link matching-link; do
    for replacement in file link dangling-link; do
        # A separate Bash process retains errexit even when its status is tested.
        if bash "$SWAY98_ROOT/tests/manifest-roundtrip.sh" --case "$original" "$replacement" \
            >"$TEST_ROOT/$original-$replacement.log" 2>&1; then
            printf 'ok: %s -> %s -> original\n' "$original" "$replacement"
        else
            cat -- "$TEST_ROOT/$original-$replacement.log" >&2
            failures=$((failures + 1))
        fi
    done
done
((failures == 0)) || fail "$failures regression case(s) failed"
