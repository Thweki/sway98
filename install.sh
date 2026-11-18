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
# shellcheck source=lib/status.sh
. "$SWAY98_ROOT/lib/status.sh"
# shellcheck source=lib/verify.sh
. "$SWAY98_ROOT/lib/verify.sh"

SELECTION=""
EXCLUSIONS=""
MODE=""
STATUS=0
VERIFY=0
SWAY98_PLAN=0
SAW_LIST=0

usage() {
    cat <<EOF
$SWAY98_NAME $SWAY98_VERSION — Windows 98 look for Arch Linux + Sway

Usage: ./install.sh [options]

Selection
  -m, --modules LIST     comma separated module ids, numbers or ranges (1,3-5)
  -a, --all              select every available module
  -r, --recommended      select the recommended set
      --exclude LIST      omit exact comma-separated module ids (repeatable)
  -l, --list             list modules and exit
      --status           summarize active manifest records without writing
      --system           also offer modules that change system paths (needs sudo)

Behaviour
      --plan             summarize selected modules and requirements, then exit
      --verify           check managed files against the manifest, then exit
  -n, --dry-run          print every change without touching anything
  -y, --yes              assume yes for all prompts
      --verbose          log every helper call
      --only MODULE      restrict to a single module (implies --modules)

Examples
  ./install.sh --list
  ./install.sh --plan --recommended --exclude theme
  ./install.sh --dry-run --all
  ./install.sh --modules theme,gtk,sway,waybar,kitty
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            -m|--modules)   [[ "${2-}" != --status && "${2-}" != --verify && "${2-}" != --plan && "${2-}" != --exclude ]] || SWAY98_LOG="" die "--modules needs a module selection before ${2-}"; SELECTION="${2:?--modules needs an argument}"; shift 2 ;;
            --only)         [[ "${2-}" != --status && "${2-}" != --verify && "${2-}" != --plan && "${2-}" != --exclude ]] || SWAY98_LOG="" die "--only needs a module before ${2-}"; SELECTION="${2:?--only needs an argument}"; shift 2 ;;
            --exclude)
                [[ "${2:-}" =~ ^[a-zA-Z0-9_-]+(,[a-zA-Z0-9_-]+)*$ ]] \
                    || SWAY98_LOG="" die "--exclude needs comma separated module ids"
                EXCLUSIONS+=" ${2//,/ }"
                shift 2 ;;
            -a|--all)       MODE="all"; shift ;;
            -r|--recommended) MODE="recommended"; shift ;;
            -l|--list)      MODE="list"; SAW_LIST=1; shift ;;
            --plan)         SWAY98_PLAN=1; SWAY98_LOG=""; shift ;;
            --status)       STATUS=1; SWAY98_LOG=""; shift ;;
            --verify)       VERIFY=1; SWAY98_LOG=""; shift ;;
            -n|--dry-run)   export SWAY98_DRY_RUN=1; shift ;;
            -y|--yes)       export SWAY98_ASSUME_YES=1; shift ;;
            --system)       export SWAY98_SYSTEM=1; shift ;;
            --verbose)      export SWAY98_VERBOSE=1; shift ;;
            -h|--help)      usage; exit 0 ;;
            *)              usage >&2; SWAY98_LOG="" die "unknown option: $1" ;;
        esac
    done
}

_sway98_module_excluded() {
    [[ " $EXCLUSIONS " == *" $1 "* ]]
}

_sway98_filter_exclusions() {
    local id
    for id in $1; do
        if ! _sway98_module_excluded "$id"; then
            printf '%s\n' "$id"
        fi
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
            if _sway98_module_excluded "$r"; then
                warn "'$id' selected without '$r' (--exclude)"
                continue
            fi
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
    local selection="$1" id file applied=() failed=()
    for id in $selection; do
        file="$(module_file "$id")" || die "unknown module: $id"
        export SWAY98_MODULE="$id"
        step "module: $id"
        if ( # shellcheck disable=SC1090
            . "$file"
            sway98_apply
        ); then
            applied+=("$id")
            record_module "$id" installed
        else
            warn "module '$id' did not complete; its changes stay reverted-able via ./uninstall.sh"
            failed+=("$id")
        fi
    done

    step "done"
    if ((${#applied[@]})); then
        ok "installed: ${applied[*]}"
    fi
    if ((${#failed[@]})); then
        err "failed: ${failed[*]}"
    fi
    printf '\n' >&2
    info "check the result:  swaymsg reload   (then restart GTK apps / Firefox)"
    info "undo everything:   ./uninstall.sh --dry-run && ./uninstall.sh"
    if ((${#failed[@]})); then
        return 1
    fi
}

sway98_print_plan() {
    local requested="$1" selection="$2" id requirement
    printf 'Installation plan (module summary, not a file diff)\n'
    printf 'Dependency prompts are assumed accepted; installation may still skip unavailable modules.\n'
    for id in $selection; do
        printf '\n%s [%s]' "$id" "$(module_field "$id" scope)"
        if [[ " $requested " != *" $id "* ]]; then
            printf ' (added dependency)'
        fi
        printf '\n  Changes: %s\n' "$(module_field "$id" desc)"
        printf '  Packages (not checked or installed): %s\n' "$(module_field "$id" pkgs)"
        for requirement in $(module_field "$id" requires); do
            if _sway98_module_excluded "$requirement"; then
                printf '  Requires: %s (excluded)\n' "$requirement"
            elif [[ " $selection " == *" $requirement "* ]]; then
                printf '  Requires: %s (selected)\n' "$requirement"
            else
                printf '  Requires: %s (not selected)\n' "$requirement"
            fi
        done
    done
    printf '\nNo modules applied, downloads performed, or installation state written.\n'
}

prepare_install() {
    if [[ "$SWAY98_DRY_RUN" != "1" ]]; then
        mkdir -p -- "$SWAY98_STATE/log"
        export SWAY98_LOG="$SWAY98_STATE/log/install-$SWAY98_TS.log"
    fi
    step "$SWAY98_NAME $SWAY98_VERSION"
    preflight
    manifest_init
}

main() {
    parse_args "$@"

    if [[ -n "$EXCLUSIONS" ]]; then
        [[ "$VERIFY" == 0 && "$STATUS" == 0 && "$SAW_LIST" == 0 ]] \
            || SWAY98_LOG="" die "--exclude cannot be combined with --verify, --status, or --list"
        SWAY98_LOG=""
        local id
        for id in $EXCLUSIONS; do
            module_file "$id" >/dev/null \
                || die "unknown module to exclude: $id (see --list)"
        done
    fi

    if [[ "$SWAY98_PLAN" == "1" ]]; then
        [[ "$VERIFY" == 0 && "$STATUS" == 0 && "$SAW_LIST" == 0 ]] \
            || die "--plan cannot be combined with --verify, --status, or --list"
        # Reuse the dry-run dependency decisions, but never execute module bodies.
        export SWAY98_DRY_RUN=1
    fi

    if [[ "$VERIFY" == 1 ]]; then
        [[ "$STATUS" == 0 ]] || die "--verify cannot be combined with --status"
        [[ -z "$MODE" && -z "$SELECTION" ]] || die "--verify cannot be combined with module selection or --list"
        [[ "$EUID" -ne 0 ]] || die "run --verify as the normal installing user, not as root"
        sway98_verify_files "$(manifest_files)"
        return
    fi

    if [[ "$STATUS" == 1 ]]; then
        [[ -z "$MODE" && -z "$SELECTION" ]] || die "--status cannot be combined with module selection or --list"
        sway98_status
        return
    fi

    case "${MODE:-}" in
        list) list_modules; exit 0 ;;
    esac

    if [[ "$SWAY98_PLAN" == "1" ]]; then
        step "$SWAY98_NAME $SWAY98_VERSION"
    elif [[ -z "$EXCLUSIONS" ]]; then
        prepare_install
    fi

    local selection="" requested
    case "${MODE:-}" in
        all)         selection="$(module_defaults | tr '\n' ' ')" ;;
        recommended) selection="$(module_recommended | tr '\n' ' ')" ;;
        "")          if [[ -n "$SELECTION" ]]; then
                         selection="$(_expand_selection "$SELECTION" | tr '\n' ' ')"
                     else
                         selection="$(menu_select "$SWAY98_PLAN" | tr '\n' ' ')"
                     fi ;;
    esac

    if [[ -n "$EXCLUSIONS" ]]; then
        validate_selection "$selection"
        selection="$(_sway98_filter_exclusions "$selection" | tr '\n' ' ')"
    fi

    if [[ -z "${selection// /}" ]]; then
        info "nothing selected, nothing to do"
        exit 0
    fi

    selection="$(tr ' ' '\n' <<<"$selection" | sed '/^$/d' | awk '!seen[$0]++' | tr '\n' ' ')"
    validate_selection "$selection"
    requested="$selection"
    if [[ "$SWAY98_PLAN" != "1" && -n "$EXCLUSIONS" ]]; then
        prepare_install
    fi
    selection="$(expand_requirements "$selection" | tr '\n' ' ')"

    if [[ "$SWAY98_PLAN" == "1" ]]; then
        sway98_print_plan "$requested" "$selection"
        return 0
    fi

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

main "$@"
