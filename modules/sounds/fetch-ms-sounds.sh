#!/usr/bin/env bash
#
# sway98 — fetch the Windows 98 sound files listed in sources.tsv.
#
# Usage: ./fetch-ms-sounds.sh [destination-dir] [--dry-run]
#
# Files are written as <freedesktop-name>.wav and verified against the sha1 in
# sources.tsv. Already downloaded, verified files are left alone, so re-running
# this is cheap.
#
# The download itself goes through archive_org_fetch() in lib/fetch.sh, which
# resolves the storage node via the Internet Archive metadata API. Do not replace
# that with a plain curl on the /download URL — see AGENTS.md section 6.

set -euo pipefail

SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
export SWAY98_ROOT

# shellcheck source=lib/common.sh
. "$SWAY98_ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
. "$SWAY98_ROOT/lib/detect.sh"
# shellcheck source=lib/fetch.sh
. "$SWAY98_ROOT/lib/fetch.sh"

DEST="${1:-$SWAY98_STATE/sounds-src}"
if [[ "${2:-}" == "--dry-run" || "${1:-}" == "--dry-run" ]]; then
    export SWAY98_DRY_RUN=1
    if [[ "${1:-}" == "--dry-run" ]]; then
        DEST="$SWAY98_STATE/sounds-src"
    fi
fi

SOURCES="$SWAY98_ROOT/modules/sounds/sources.tsv"
[[ -r "$SOURCES" ]] || die "source list not found: $SOURCES"

fetched=0
cached=0
failed=0

if ! is_dry_run; then
    mkdir -p -- "$DEST"
fi

while IFS=$'\t' read -r name item path sha1; do
    [[ -n "${name:-}" && "$name" != \#* ]] || continue
    dest_file="$DEST/$name.wav"

    if [[ -f "$dest_file" ]] && verify_sha1 "$dest_file" "$sha1" 2>/dev/null; then
        info "cached: $name.wav"
        cached=$((cached + 1))
        continue
    fi

    if is_dry_run; then
        dry "GET https://archive.org/metadata/$item  →  $path  →  $dest_file"
        fetched=$((fetched + 1))
        continue
    fi

    if archive_org_fetch "$item" "$path" "$dest_file" "$sha1"; then
        ok "$name.wav"
        fetched=$((fetched + 1))
    else
        warn "failed: $name.wav"
        failed=$((failed + 1))
    fi
done <"$SOURCES"

step "sounds: $fetched fetched, $cached cached, $failed failed"
if ((failed > 0)); then
    exit 1
fi
