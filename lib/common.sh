#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # the constants below are used by install.sh / modules
#
# sway98 — shared constants, logging and prompts.
# This file is sourced by install.sh, uninstall.sh and modules. It is never executed directly.

SWAY98_NAME="sway98"
SWAY98_VERSION="0.1.0"
SWAY98_REPO="${SWAY98_REPO:-https://github.com/thweki/sway98}"

SWAY98_ROOT="${SWAY98_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
SWAY98_STATE="${SWAY98_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/sway98}"
SWAY98_TS="${SWAY98_TS:-$(date +%Y%m%d-%H%M%S)}"
SWAY98_THEME_SRC="${SWAY98_THEME_SRC:-$SWAY98_STATE/upstream/Chicago95}"

# Runtime switches (set by install.sh / uninstall.sh from the command line)
SWAY98_DRY_RUN="${SWAY98_DRY_RUN:-0}"
SWAY98_ASSUME_YES="${SWAY98_ASSUME_YES:-0}"
SWAY98_TAKEOVER="${SWAY98_TAKEOVER:-0}"
SWAY98_VERBOSE="${SWAY98_VERBOSE:-0}"
SWAY98_SYSTEM="${SWAY98_SYSTEM:-0}"
SWAY98_LOG="${SWAY98_LOG:-}"
SWAY98_MODULE="${SWAY98_MODULE:-}"   # current module id, used by the manifest layer

# Chicago95 upstream is pinned to a known-good commit instead of tracking master:
# upstream has already reorganised its directory layout once, which broke every
# hardcoded path. Bump this deliberately, after running `make check-real`.
SWAY98_CHICAGO95_URL="https://github.com/grassmunk/Chicago95.git"
SWAY98_CHICAGO95_REF="e89583c9a0fbc5022d099fbe6f12132a756027a8"

# --- colours ------------------------------------------------------------------
if [[ -t 2 ]]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
    C_RESET=""; C_DIM=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

# --- logging ------------------------------------------------------------------
_log() {
    local level="$1" colour="$2"; shift 2
    printf '%s%s%s %s\n' "$colour" "$level" "$C_RESET" "$*" >&2
    if [[ -n "$SWAY98_LOG" ]]; then
        printf '[%s] %-5s %s\n' "$(date -Is)" "$level" "$*" >>"$SWAY98_LOG" 2>/dev/null || true
    fi
}

info() { _log "info" "$C_BLUE" "$@"; }
ok()   { _log "ok" "$C_GREEN" "$@"; }
warn() { _log "warn" "$C_YELLOW" "$@"; }
err()  { _log "err" "$C_RED" "$@"; }

step() {
    printf '\n%s==>%s %s%s%s\n' "${C_BOLD}${C_BLUE}" "$C_RESET" "$C_BOLD" "$*" "$C_RESET" >&2
    if [[ -n "$SWAY98_LOG" ]]; then
        printf '[%s] ---   ==> %s\n' "$(date -Is)" "$*" >>"$SWAY98_LOG" 2>/dev/null || true
    fi
}

# Print what would happen, without doing it. Every write path calls this first.
dry() {
    printf '%s[dry-run] %s%s\n' "$C_DIM" "$*" "$C_RESET" >&2
    if [[ -n "$SWAY98_LOG" ]]; then
        printf '[%s] dry   %s\n' "$(date -Is)" "$*" >>"$SWAY98_LOG" 2>/dev/null || true
    fi
}

die() { err "$@"; exit 1; }

is_dry_run() { [[ "$SWAY98_DRY_RUN" == "1" ]]; }

# --- small helpers ------------------------------------------------------------
have() { command -v -- "$1" >/dev/null 2>&1; }

require_cmd() {
    local missing=() c
    for c in "$@"; do
        have "$c" || missing+=("$c")
    done
    ((${#missing[@]} == 0)) || die "missing required command(s): ${missing[*]}"
}

# confirm <prompt> [default: n] — auto-accepts under --yes and --dry-run,
# refuses (instead of hanging) when stdin is not a terminal.
confirm() {
    local prompt="$1" reply
    if is_dry_run || [[ "$SWAY98_ASSUME_YES" == "1" ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        warn "stdin is not a terminal; assuming 'no' for: $prompt"
        return 1
    fi
    read -r -p "$prompt [y/N] " reply || true
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Overwriting an unowned destination needs its own decision. A general --yes
# only approves routine prompts; --takeover explicitly approves replacements.
confirm_takeover() {
    [[ "$SWAY98_TAKEOVER" == "1" ]] && return 0
    local SWAY98_ASSUME_YES=0
    confirm "$1"
}
