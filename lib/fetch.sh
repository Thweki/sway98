#!/usr/bin/env bash
# shellcheck shell=bash
#
# sway98 — downloading things.
#
# The archive.org path is deliberately not the obvious one. `https://archive.org/
# download/<item>/<path>` answers with a 302 to a storage node such as
# `dn721905.ca.archive.org`, and on some networks that node drops the TLS
# handshake ("unexpected eof while reading"). Verified on the maintainer machine:
# the generic URL failed 5 out of 5 times for a file that downloads fine when the
# node is taken from the metadata API. So: ask the metadata API for `server` and
# `dir`, then download straight from the node, then verify the sha1 that the same
# metadata API reports. See AGENTS.md section 6.

http_get() {
    local url="$1" dest="$2" retries="${3:-3}"
    curl --fail --silent --show-error --location \
        --retry "$retries" --retry-all-errors --retry-delay 1 \
        --connect-timeout 15 --max-time 600 \
        --user-agent "sway98/$SWAY98_VERSION (+$SWAY98_REPO)" \
        --output "$dest" "$url"
}

# Percent-encode everything outside the unreserved set. Forced to the C locale so
# that multi-byte characters are encoded byte by byte.
_urlencode() {
    local s="$1" out="" c i
    LC_ALL=C
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [A-Za-z0-9._~/-]) out+="$c" ;;
            *) out+="$(printf '%%%02X' "'$c")" ;;
        esac
    done
    printf '%s\n' "$out"
}

_json_str() {
    local json="$1" key="$2"
    printf '%s' "$json" | grep -o "\"$key\": *\"[^\"]*\"" | head -n 1 | cut -d'"' -f4
}

verify_sha1() {
    local file="$1" expected="$2" got
    [[ -n "$expected" ]] || return 0
    got="$(sha1sum -- "$file" | awk '{print $1}')"
    if [[ "$got" != "$expected" ]]; then
        warn "sha1 mismatch for $(basename -- "$file"): expected $expected, got $got"
        return 1
    fi
    return 0
}

# archive_org_fetch <item> <remote-path> <dest> <sha1> [retries]
#
# <remote-path> is the path inside the item as reported by the metadata API
# (it may contain spaces and brackets; encoding is handled here).
archive_org_fetch() {
    local item="$1" remote="$2" dest="$3" expected="$4" tries="${5:-2}"
    local meta server dir url attempt

    require_cmd curl

    for (( attempt = 1; attempt <= tries; attempt++ )); do
        if ! meta="$(curl --fail --silent --show-error --retry 3 --retry-all-errors \
                --connect-timeout 15 --max-time 60 \
                --user-agent "sway98/$SWAY98_VERSION (+$SWAY98_REPO)" \
                "https://archive.org/metadata/$item")"; then
            warn "metadata lookup failed for $item (attempt $attempt/$tries)"
            continue
        fi
        server="$(_json_str "$meta" server)"
        dir="$(_json_str "$meta" dir)"
        if [[ -z "$server" || -z "$dir" ]]; then
            warn "metadata for $item has no server/dir (attempt $attempt/$tries)"
            continue
        fi
        url="https://$server$dir/$(_urlencode "$remote")"
        info "fetching $(basename -- "$remote") from $server"
        if http_get "$url" "$dest" 3 && verify_sha1 "$dest" "$expected"; then
            return 0
        fi
        rm -f -- "$dest"
        sleep 1
    done

    err "could not download $remote from archive.org item $item"
    return 1
}

# git_clone_pinned <url> <commit-or-ref> <dest>
#
# Clones at an exact revision with a depth of 1. Re-running against an existing
# clone re-checks out the pinned revision instead of re-downloading.
git_clone_pinned() {
    local url="$1" ref="$2" dest="$3"

    require_cmd git

    if [[ -d "$dest/.git" ]]; then
        if [[ "$(git -C "$dest" rev-parse --verify --quiet HEAD)" == "$ref"* ]] \
            || git -C "$dest" rev-parse --verify --quiet "$ref" >/dev/null; then
            ok "upstream checkout already at $(git -C "$dest" rev-parse --short HEAD)"
            return 0
        fi
        info "re-pinning $dest to $ref"
        git -C "$dest" fetch --quiet --depth 1 origin "$ref"
        git -C "$dest" checkout --quiet FETCH_HEAD
        return 0
    fi

    [[ -e "$dest" ]] && die "git_clone_pinned: $dest exists and is not a git checkout"

    mkdir -p -- "$(dirname -- "$dest")"
    git init --quiet "$dest"
    git -C "$dest" remote add origin "$url"
    git -C "$dest" fetch --quiet --depth 1 origin "$ref" \
        || die "failed to fetch $ref from $url"
    git -C "$dest" checkout --quiet FETCH_HEAD
    ok "cloned $(basename -- "$url") at $(git -C "$dest" rev-parse --short HEAD)"
}

# ensure_chicago95 — the shared upstream checkout used by several modules.
ensure_chicago95() {
    if [[ -d "$SWAY98_THEME_SRC/Theme/Chicago95" ]]; then
        ok "Chicago95 sources present: $SWAY98_THEME_SRC"
        return 0
    fi
    if is_dry_run; then
        dry "would clone Chicago95 ($SWAY98_CHICAGO95_REF) into $SWAY98_THEME_SRC"
        return 0
    fi
    git_clone_pinned "$SWAY98_CHICAGO95_URL" "$SWAY98_CHICAGO95_REF" "$SWAY98_THEME_SRC"
}
