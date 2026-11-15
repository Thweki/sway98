#!/usr/bin/env bash
set -euo pipefail

# Experimental, deliberately conservative admission list. These modules have no
# module dependencies or shared external settings. Everything else is a barrier,
# including future modules, so the selection order around dependencies survives.
# Adding an id requires auditing downloads, prompts and non-file side effects.
_sway98_parallel_eligible() {
    case "$1" in
        theme|kitty|wofi|swaylock) return 0 ;;
        *) return 1 ;;
    esac
}

_sway98_parallel_unlock() {
    if [[ "${SWAY98_PARALLEL_OWNER:-}" == "$BASHPID" ]]; then
        rmdir -- "$SWAY98_PARALLEL_DIR/write-lock"
        SWAY98_PARALLEL_OWNER=""
    fi
}

_sway98_parallel_locked() {
    # Nested helpers share the lock (include_block -> install_file, for example).
    if [[ -n "${SWAY98_PARALLEL_OWNER:-}" ]]; then
        "$@"
        return
    fi
    until mkdir -- "$SWAY98_PARALLEL_DIR/write-lock" 2>/dev/null; do
        # The other worker may release the lock immediately after mkdir fails.
        [[ -d "$SWAY98_PARALLEL_DIR" && -w "$SWAY98_PARALLEL_DIR" ]] || return 1
        sleep 0.02
    done
    SWAY98_PARALLEL_OWNER="$BASHPID"
    "$@"
    _sway98_parallel_unlock
}

_sway98_parallel_wrap_helpers() {
    # Wrap only inside workers, leaving the ordinary serial path untouched.
    # Lock the entire read/edit/backup/write/record operation, not just appends:
    # shared parents, symlink aliases and large tree manifests must be safe too.
    local helper definition
    for helper in install_file install_dir install_symlink include_block ini_set record_cmd; do
        definition="$(declare -f "$helper")"
        eval "${definition/#$helper /_sway98_unlocked_$helper }"
        # Both names come exclusively from the fixed list above, never input.
        eval "$helper() { _sway98_parallel_locked _sway98_unlocked_$helper \"\$@\"; }"
    done
}

# Called directly by the entry point so signals reach the scheduler itself.
sway98_apply_parallel() {
    local selection="$1" limit="$2" id file slot
    local -a pids=() ids=() applied=() failed=()
    SWAY98_PARALLEL_DIR="$(mktemp -d "$SWAY98_STATE/parallel.XXXXXXXX")"
    SWAY98_PARALLEL_OWNER=""

    _sway98_parallel_cleanup() {
        # On interruption finish active workers before returning control. Killing
        # between a file write and its manifest row would make rollback unsafe.
        trap '' INT TERM
        local worker
        # The job table also covers a signal between spawning and saving $!.
        for worker in $(jobs -pr); do wait "$worker" || true; done
        rmdir -- "$SWAY98_PARALLEL_DIR"
    }
    trap _sway98_parallel_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    _sway98_parallel_drain() {
        for slot in "${!pids[@]}"; do
            if wait "${pids[slot]}"; then
                applied+=("${ids[slot]}")
                record_module "${ids[slot]}" installed
            else
                failed+=("${ids[slot]}")
                warn "module '${ids[slot]}' did not complete; use ./uninstall.sh to revert its recorded changes"
            fi
            unset 'pids[slot]' 'ids[slot]'
        done
        pids=(); ids=()
    }

    warn "experimental parallel installation: up to $limit workers; file transactions remain serial"
    for id in $selection; do
        if ! _sway98_parallel_eligible "$id"; then
            _sway98_parallel_drain
        fi
        file="$(module_file "$id")" || die "unknown module: $id"
        step "module: $id"
        (
            # Background jobs never read terminal input; --yes is required.
            # Ignore signals until the module has recorded every completed write.
            trap '' INT TERM
            trap _sway98_parallel_unlock EXIT
            export SWAY98_MODULE="$id"
            _sway98_parallel_wrap_helpers
            # shellcheck disable=SC1090
            . "$file"
            sway98_apply
        ) </dev/null &
        pids+=("$!"); ids+=("$id")
        if ! _sway98_parallel_eligible "$id" || ((${#pids[@]} >= limit)); then
            _sway98_parallel_drain
        fi
    done
    _sway98_parallel_drain

    step "done"
    ((${#applied[@]} == 0)) || ok "installed: ${applied[*]}"
    ((${#failed[@]} == 0)) || err "failed: ${failed[*]}"
    info "check the result:  swaymsg reload   (then restart GTK apps / Firefox)"
    info "undo everything:   ./uninstall.sh --dry-run && ./uninstall.sh"
    _sway98_parallel_cleanup
    trap - EXIT INT TERM
    ((${#failed[@]} == 0))
}
