#!/usr/bin/env bash
set -euo pipefail

# User-owned lifecycle hooks run as child processes, never in the installer shell.
# Arguments describe the requested scope, not a guarantee that modules changed files.
sway98_run_hook() {
    local event="$1" hook_path hook_status
    shift
    [[ "${SWAY98_NO_HOOKS:-0}" == "1" ]] && return 0
    hook_path="${XDG_CONFIG_HOME:-$HOME/.config}/sway98/hooks/$event"
    [[ -e "$hook_path" || -L "$hook_path" ]] || return 0
    if [[ ! -f "$hook_path" || ! -x "$hook_path" ]]; then
        warn "skipping hook $hook_path: expected an executable regular file"
        return 0
    fi
    if is_dry_run; then
        dry "would run hook $hook_path"
        return 0
    fi

    info "running hook: $hook_path"
    if SWAY98_HOOK_EVENT="$event" SWAY98_STATE="$SWAY98_STATE" \
        "$hook_path" "$@" </dev/null; then
        ok "hook completed: $event"
    else
        hook_status=$?
        err "hook $hook_path failed (exit $hook_status); the completed operation has not been rolled back"
        return "$hook_status"
    fi
}
