#!/usr/bin/env bash
# shellcheck shell=bash
#
# sway98 — module discovery and interactive selection.
#
# Module metadata lives in modules/<id>/module.sh as plain variables. We read it
# in a subshell so that sourcing every module cannot leak functions or variables
# into the installer.

# shellcheck disable=SC2034  # variables are read by callers
modules_discover() {
    local f id
    for f in "$SWAY98_ROOT"/modules/*/module.sh; do
        [[ -f "$f" ]] || continue
        id="$(basename -- "$(dirname -- "$f")")"
        printf '%s\t%s\n' "$id" "$f"
    done
}

# _module_meta <file> — prints "desc<TAB>scope<TAB>recommended<TAB>requires<TAB>pkgs"
_module_meta() {
    local file="$1"
    (
        # shellcheck disable=SC1090
        . "$file"
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "${SWAY98_MODULE_DESC:-}" \
            "${SWAY98_MODULE_SCOPE:-user}" \
            "${SWAY98_MODULE_RECOMMENDED:-no}" \
            "${SWAY98_MODULE_REQUIRES:-}" \
            "${SWAY98_MODULE_NEEDS_PKGS:-}"
    )
}

# modules_table — prints "id<TAB>desc<TAB>scope<TAB>recommended<TAB>requires<TAB>pkgs<TAB>file"
modules_table() {
    local id file meta
    while IFS=$'\t' read -r id file; do
        meta="$(_module_meta "$file")"
        printf '%s\t%s\t%s\n' "$id" "$meta" "$file"
    done < <(modules_discover)
}

module_file() {
    local want="$1" id file
    while IFS=$'\t' read -r id file; do
        if [[ "$id" == "$want" ]]; then
            printf '%s\n' "$file"
            return 0
        fi
    done < <(modules_discover)
    return 1
}

module_field() {
    local id="$1" field="$2" file line
    file="$(module_file "$id")" || return 1
    line="$(_module_meta "$file")"
    case "$field" in
        desc)        cut -f1 <<<"$line" ;;
        scope)       cut -f2 <<<"$line" ;;
        recommended) cut -f3 <<<"$line" ;;
        requires)    cut -f4 <<<"$line" ;;
        pkgs)        cut -f5 <<<"$line" ;;
        *)           die "module_field: unknown field '$field'" ;;
    esac
}

module_defaults() {
    # Filter the metadata already loaded by modules_table instead of looking up
    # each module again. AWK preserves empty TSV fields and discovery order.
    modules_table | awk -F '\t' -v allow_system="$SWAY98_SYSTEM" '
        $3 != "system" || allow_system == "1" { print $1 }
    '
}

module_recommended() {
    modules_table | awk -F '\t' -v allow_system="$SWAY98_SYSTEM" '
        ($3 != "system" || allow_system == "1") && $4 == "yes" { print $1 }
    '
}

# Normalize a decimal menu index before arithmetic. Check its length first so
# oversized input cannot overflow into a valid index or an unbounded range.
_sway98_selection_index() {
    local index="$1" count="$2"
    index="${index#"${index%%[!0]*}"}"
    if [[ -z "$index" || ${#index} -gt ${#count} ]]; then
        die "module number out of range: $1 (expected 1-$count)"
    fi
    (( index >= 1 && index <= count )) \
        || die "module number out of range: $1 (expected 1-$count)"
    printf '%s\n' "$index"
}

# _expand_selection "theme,gtk,sway" -> one id per line
_expand_selection() {
    local raw="$1" token i first last
    local -a ids=()
    while IFS= read -r i; do ids+=("$i"); done < <(module_defaults)
    for token in ${raw//,/ }; do
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            first="$(_sway98_selection_index "${BASH_REMATCH[1]}" "${#ids[@]}")" || return
            last="$(_sway98_selection_index "${BASH_REMATCH[2]}" "${#ids[@]}")" || return
            (( first <= last )) || die "module range is reversed: $token"
            for (( i = first; i <= last; i++ )); do
                printf '%s\n' "${ids[i-1]}"
            done
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            i="$(_sway98_selection_index "$token" "${#ids[@]}")" || return
            printf '%s\n' "${ids[i-1]}"
        else
            printf '%s\n' "$token"
        fi
    done
}

validate_selection() {
    local id
    for id in $1; do
        module_file "$id" >/dev/null || die "unknown module: $id (see --list)"
    done
}

# menu_select — interactive multi-select. Prints the chosen ids, one per line.
menu_select() {
    local id desc scope rec req pkgs line
    local -a ids=() descs=()
    while IFS=$'\t' read -r id desc scope rec req pkgs _; do
        [[ "$scope" == "system" && "$SWAY98_SYSTEM" != "1" ]] && continue
        ids+=("$id"); descs+=("$desc")
    done < <(modules_table)

    if have gum && [[ -t 0 ]]; then
        local -a args=()
        for line in "${!ids[@]}"; do
            args+=("${ids[line]} — ${descs[line]}")
        done
        gum choose --no-limit --header "Select modules to install (space to toggle, enter to confirm):" "${args[@]}" \
            | cut -d' ' -f1 || true
        return 0
    fi

    printf '\n' >&2
    printf '%sAvailable modules%s\n' "$C_BOLD" "$C_RESET" >&2
    for line in "${!ids[@]}"; do
        printf '  %s%2d%s) %-10s %s\n' "$C_BOLD" "$((line + 1))" "$C_RESET" "${ids[line]}" "${descs[line]}" >&2
    done
    printf '\n  a) all   r) recommended   Enter) none\n' >&2
    printf '%sSelect%s [e.g. 1,3-4 / a / r]: ' "$C_BOLD" "$C_RESET" >&2

    local answer=""
    read -r answer || true
    case "$answer" in
        "") return 0 ;;
        a|A|all) module_defaults ;;
        r|R) module_recommended ;;
        *) _expand_selection "$answer" ;;
    esac
}
