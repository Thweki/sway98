#!/usr/bin/env bash
#
# sway98 — installer entry point.
#
# Usage: ./install.sh [options]   (see --help)

set -euo pipefail

SWAY98_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export SWAY98_ROOT

# shellcheck source=lib/common.sh
. "$SWAY98_ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
. "$SWAY98_ROOT/lib/detect.sh"
# shellcheck source=lib/manifest.sh
. "$SWAY98_ROOT/lib/manifest.sh"
# shellcheck source=lib/edit.sh
. "$SWAY98_ROOT/lib/edit.sh"
# shellcheck source=lib/fetch.sh
. "$SWAY98_ROOT/lib/fetch.sh"
# shellcheck source=lib/menu.sh
. "$SWAY98_ROOT/lib/menu.sh"

SELECTION=""
MODE=""

usage() {
    cat <<EOF
$SWAY98_NAME $SWAY98_VERSION — Windows 98 look for Arch Linux + Sway

Usage: ./install.sh [options]

Selection
  -m, --modules LIST     comma separated module ids, numbers or ranges (1,3-5)
  -a, --all              select every available module
  -r, --recommended      select the recommended set
  -l, --list             list modules and exit
      --system           also offer modules that change system paths (needs sudo)

Behaviour
  -n, --dry-run          print every change without touching anything
  -y, --yes              assume yes for routine prompts (excludes takeover)
      --takeover         explicitly allow overwriting unowned destinations
      --verbose          log every helper call
      --only MODULE      restrict to a single module (implies --modules)

Examples
  ./install.sh --list
  ./install.sh --dry-run --all
  ./install.sh --modules theme,gtk,sway,waybar,kitty
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            -m|--modules)   SELECTION="${2:?--modules needs an argument}"; shift 2 ;;
            --only)         SELECTION="${2:?--only needs an argument}"; shift 2 ;;
            -a|--all)       MODE="all"; shift ;;
            -r|--recommended) MODE="recommended"; shift ;;
            -l|--list)      MODE="list"; shift ;;
            -n|--dry-run)   export SWAY98_DRY_RUN=1; shift ;;
            -y|--yes)       export SWAY98_ASSUME_YES=1; shift ;;
            --takeover)     export SWAY98_TAKEOVER=1; shift ;;
            --system)       export SWAY98_SYSTEM=1; shift ;;
            --verbose)      export SWAY98_VERBOSE=1; shift ;;
            -h|--help)      usage; exit 0 ;;
            *)              usage >&2; die "unknown option: $1" ;;
        esac
    done
}

list_modules() {
    local id desc scope rec req pkgs file status
    printf '%s%-10s %-9s %-6s %s%s\n' "$C_BOLD" "MODULE" "SCOPE" "REC" "DESCRIPTION" "$C_RESET"
    while IFS=$'\t' read -r id desc scope rec req pkgs file; do
        if [[ "$scope" == "system" && "$SWAY98_SYSTEM" != "1" ]]; then
            status="$C_DIM(needs --system)$C_RESET"
        else
            status=""
        fi
        printf '%-10s %-9s %-6s %s %s\n' "$id" "$scope" "$rec" "$desc" "$status"
    done < <(modules_table)
    printf '\n%sDependencies are reported as: requires → %s\n' "$C_DIM" "$C_RESET"
}

preflight() {
    [[ "${EUID:-$(id -u)}" -ne 0 ]] || die "run $SWAY98_NAME as your normal user, not as root"
    [[ -w "$HOME" ]] || die "\$HOME is not writable: $HOME"

    local pm session
    pm="$(detect_pkg_manager)"
    if [[ "$pm" != "pacman" ]]; then
        warn "this project targets Arch Linux (pacman); detected package manager: $pm"
        warn "continuing anyway — file installation itself is distribution independent"
    fi
    session="$(detect_session_type)"
    if [[ "$session" != "sway" ]]; then
        warn "current session is '$session', not a running sway: changes apply at the next login"
    fi
    have curl || warn "curl is missing: modules that download upstream assets will fail"
    have git  || warn "git is missing: the 'theme' module cannot fetch Chicago95"
}

report_missing_pkgs() {
    local selection="$1" id pkgs missing
    local -a report=()

    if ! have pacman; then
        info "package check skipped: pacman is not available (this project targets Arch Linux)"
        return 0
    fi

    for id in $selection; do
        pkgs="$(module_field "$id" pkgs)"
        [[ -n "$pkgs" ]] || continue
        # $pkgs is a space separated package list on purpose.
        # shellcheck disable=SC2086
        missing="$(pacman_missing $pkgs | tr '\n' ' ' | sed 's/ *$//')"
        [[ -n "$missing" ]] && report+=("$id:$missing")
    done
    if ((${#report[@]})); then
        warn "missing packages (install with: sudo pacman -S ...)"
        printf '    %s\n' "${report[@]}" >&2
    fi
}

expand_requirements() {
    local selection="$1"
    local id req out="$selection"
    for id in $selection; do
        req="$(module_field "$id" requires)"
        [[ -n "$req" ]] || continue
        local r
        for r in $req; do
            if ! grep -qw -- "$r" <<<"$out"; then
                if confirm "module '$id' works best with '$r'; install '$r' too?"; then
                    out="$out $r"
                else
                    warn "'$id' installed without '$r'"
                fi
            fi
        done
    done
    printf '%s\n' "$out"
}

apply_selection() {
    local selection="$1" id file status applied=() incomplete=() failed=()
    for id in $selection; do
        file="$(module_file "$id")" || die "unknown module: $id"
        export SWAY98_MODULE="$id"
        step "module: $id"
        if ( # shellcheck disable=SC1090
            SWAY98_SKIPPED_DESTINATIONS=()
            . "$file"
            sway98_apply || exit 1
            # Reserved result for successful work with declined destinations.
            ((${#SWAY98_SKIPPED_DESTINATIONS[@]} == 0)) || exit 3
        ); then
            applied+=("$id")
            record_module "$id" installed
        else
            status=$?
            if [[ "$status" == "3" ]]; then
                incomplete+=("$id")
                record_module "$id" incomplete
            else
                warn "module '$id' did not complete; its changes stay reverted-able via ./uninstall.sh"
                failed+=("$id")
            fi
        fi
    done

    step "done"
    if ((${#applied[@]})); then
        ok "installed: ${applied[*]}"
    fi
    if ((${#failed[@]})); then
        err "failed: ${failed[*]}"
    fi
    if ((${#incomplete[@]})); then
        warn "incomplete (unowned destinations skipped): ${incomplete[*]}"
    fi
    printf '\n' >&2
    info "check the result:  swaymsg reload   (then restart GTK apps / Firefox)"
    info "undo everything:   ./uninstall.sh --dry-run && ./uninstall.sh"
    if ((${#failed[@]})); then
        return 1
    fi
}

main() {
    parse_args "$@"

    case "${MODE:-}" in
        list) list_modules; exit 0 ;;
    esac

    if [[ "$SWAY98_DRY_RUN" != "1" ]]; then
        mkdir -p -- "$SWAY98_STATE/log"
        export SWAY98_LOG="$SWAY98_STATE/log/install-$SWAY98_TS.log"
    fi

    step "$SWAY98_NAME $SWAY98_VERSION"
    preflight
    manifest_init

    local selection=""
    case "${MODE:-}" in
        all)         selection="$(module_defaults | tr '\n' ' ')" ;;
        recommended) selection="$(module_recommended | tr '\n' ' ')" ;;
        "")          if [[ -n "$SELECTION" ]]; then
                         selection="$(_expand_selection "$SELECTION" | tr '\n' ' ')"
                     else
                         selection="$(menu_select | tr '\n' ' ')"
                     fi ;;
    esac

    if [[ -z "${selection// /}" ]]; then
        info "nothing selected, nothing to do"
        exit 0
    fi

    selection="$(tr ' ' '\n' <<<"$selection" | sed '/^$/d' | awk '!seen[$0]++' | tr '\n' ' ')"
    validate_selection "$selection"
    selection="$(expand_requirements "$selection" | tr '\n' ' ')"

    printf '\n' >&2
    report_missing_pkgs "$selection"
    info "modules to install: $(tr -s ' ' <<<"$selection" | sed 's/^ //; s/ $//')"
    if is_dry_run; then
        info "dry run: no file will be touched, no manifest written"
    elif ! confirm "proceed?" y; then
        info "aborted by user"
        exit 0
    fi

    apply_selection "$selection"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
