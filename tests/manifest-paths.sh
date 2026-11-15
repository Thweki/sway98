#!/usr/bin/env bash
set -euo pipefail

# All fixtures and state live in a disposable directory; no desktop or downloads.
SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SWAY98_ROOT/lib/common.sh"
# shellcheck source=lib/manifest.sh
source "$SWAY98_ROOT/lib/manifest.sh"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
export SWAY98_LOG="" SWAY98_MODULE=paths SWAY98_DRY_RUN=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

reset_case() {
    rm -rf -- "$TEST_ROOT/case" "$TEST_ROOT/before"
    mkdir -p -- "$TEST_ROOT/case/home" "$TEST_ROOT/case/source"
    export HOME="$TEST_ROOT/case/home"
    export SWAY98_STATE="$TEST_ROOT/case/state"
    SWAY98_DRY_RUN=0
    manifest_init
    printf 'new content\n' >"$TEST_ROOT/case/source/file"
    ln -s missing "$TEST_ROOT/case/source/link"
}

expect_rejected() {
    cp -a -- "$TEST_ROOT/case" "$TEST_ROOT/before"
    if ( "$@" ) >"$TEST_ROOT/action.log" 2>&1; then
        fail "$1 accepted an unsupported path"
    fi
    grep -q 'unsupported manifest path' "$TEST_ROOT/action.log" || {
        cat "$TEST_ROOT/action.log" >&2
        fail "$1 did not explicitly reject the path"
    }
    diff -r --no-dereference -- "$TEST_ROOT/before" "$TEST_ROOT/case" ||
        fail "$1 wrote before rejecting the path"
    rm -rf -- "$TEST_ROOT/before"
}

for bad in $'tab\tname' $'line\nname' $'return\rname' 'back\name' $'trailing\n'; do
    # Single-file and symlink creates and overwrites must reject before backup,
    # parent creation, writing the destination, or appending manifest records.
    for kind in file link; do
        for existing in no yes unchanged; do
            reset_case
            dest="$HOME/new/$bad"
            if [[ "$existing" == yes ]]; then
                mkdir -p -- "$HOME/new"
                printf 'original\n' >"$dest"
            elif [[ "$existing" == unchanged ]]; then
                mkdir -p -- "$HOME/new"
                cp -a -- "$TEST_ROOT/case/source/$kind" "$dest"
            fi
            if [[ "$kind" == file ]]; then
                expect_rejected install_file "$TEST_ROOT/case/source/file" "$dest"
            else
                expect_rejected install_symlink "$TEST_ROOT/case/source/link" "$dest"
            fi
        done
    done

    # Scan the entire source tree before either bulk copying or incremental
    # merging, even when the unsupported name belongs to an empty directory.
    for kind in file link dir; do
        for existing in no yes unchanged; do
            reset_case
            src="$TEST_ROOT/case/source"
            case "$kind" in
                file) printf 'bad\n' >"$src/$bad" ;;
                link) ln -s missing "$src/$bad" ;;
                dir) mkdir -p -- "$src/$bad" ;;
            esac
            dest="$HOME/tree"
            if [[ "$existing" == yes ]]; then
                mkdir -p -- "$dest"
                printf 'original\n' >"$dest/file"
            elif [[ "$existing" == unchanged ]]; then
                cp -a -- "$src" "$dest"
            fi
            expect_rejected install_dir "$src" "$dest"
            SWAY98_DRY_RUN=1
            expect_rejected install_dir "$src" "$dest"
        done
    done

    reset_case
    expect_rejected install_dir "$TEST_ROOT/case/source" "$HOME/$bad/tree"
    expect_rejected backup_of "$HOME/$bad"
    expect_rejected manifest_record_file paths create "$HOME/$bad" hash
    expect_rejected manifest_record_file paths modify "$HOME/file" hash old "$HOME/$bad"
    expect_rejected manifest_record_dir paths "$HOME/$bad"
    expect_rejected _manifest_record_created_dirs "$HOME/$bad"

    # State paths become backup fields. Reject them before any backup or install.
    SWAY98_STATE="$TEST_ROOT/case/$bad/state"
    expect_rejected manifest_init
    expect_rejected bash "$SWAY98_ROOT/install.sh" --yes --modules sway
    printf 'original\n' >"$HOME/existing"
    expect_rejected install_file "$TEST_ROOT/case/source/file" "$HOME/existing"

    # Dry runs also report unsupported paths, without creating any state.
    SWAY98_DRY_RUN=1
    expect_rejected install_dir "$TEST_ROOT/case/source" "$HOME/$bad/tree"
done
printf 'ok   unsupported paths rejected without writes (bulk and incremental)\n'

# Spaces, quotes, glob characters, Unicode and leading dashes remain literal.
# Compare the bulk and incremental manifest rows, then exercise repeat installs
# and rollback, including restoration of an existing file with an unusual name.
reset_case
src="$TEST_ROOT/case/source"
safe_name="-space \"quote\" 'single'é *?[name]"
mkdir -p -- "$src/$safe_name/empty"
printf 'safe\n' >"$src/$safe_name/$safe_name"
ln -s missing "$src/$safe_name/alias"
dest="$HOME/$safe_name"
install_dir "$src" "$dest"
cp -- "$(manifest_files)" "$TEST_ROOT/bulk.tsv"
restore_all
[[ -z "$(find "$HOME" -mindepth 1 -print -quit)" ]] || fail 'bulk rollback left paths'

: >"$(manifest_files)"
: >"$(manifest_dirs)"
mkdir -p -- "$dest"
install_dir "$src" "$dest"
sort "$TEST_ROOT/bulk.tsv" >"$TEST_ROOT/bulk.sorted"
sort "$(manifest_files)" >"$TEST_ROOT/incremental.sorted"
cmp -- "$TEST_ROOT/bulk.sorted" "$TEST_ROOT/incremental.sorted" ||
    fail 'bulk and incremental path/hash records differ'
install_dir "$src" "$dest"
restore_all
rmdir -- "$dest"
[[ -z "$(find "$HOME" -mindepth 1 -print -quit)" ]] || fail 'incremental rollback left paths'

: >"$(manifest_files)"
: >"$(manifest_dirs)"
printf 'original\n' >"$HOME/$safe_name"
install_file "$src/file" "$HOME/$safe_name"
printf 'second install\n' >"$src/file"
install_file "$src/file" "$HOME/$safe_name"
restore_all
[[ "$(cat -- "$HOME/$safe_name")" == original ]] || fail 'original backup was not restored'
printf 'ok   supported paths have consistent records and round-trip correctly\n'
