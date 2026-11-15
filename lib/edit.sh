#!/usr/bin/env bash
# shellcheck shell=bash
#
# sway98 — config file editing primitives.
#
# Every function here renders the new file content into a temporary file and then
# hands it to install_file(), which is what records backups and the manifest.
# Never write to a user file directly from a module.

# _edit_apply <src> <dest> [overwrite|merge]: install rendered content.
_edit_apply() {
    local src="$1" dest="$2"
    install_file "$src" "$dest" "${3:-overwrite}"
}

# template_render <src> <dest> [KEY=VALUE...]
#
# Minimal @PLACEHOLDER@ substitution. Used for values that differ per machine
# (font family, cursor name, ...) so no module has to hardcode them.
template_render() {
    local src="$1" dest="$2"; shift 2
    local tmp; tmp="$(mktemp)"
    cp -- "$src" "$tmp"
    local pair key value
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        sed -i "s|@${key}@|${value//|/\\|}|g" "$tmp"
    done
    _edit_apply "$tmp" "$dest"
    rm -f -- "$tmp"
}

# gsettings_set_if_changed <schema> <key> <value>
#
# Sets a gsettings key and records a revert command holding the previous value.
# Silently skips when gsettings is unavailable (non-GNOME minimal installs).
gsettings_set_if_changed() {
    local schema="$1" key="$2" value="$3" old
    if [[ "${SWAY98_NO_GSETTINGS:-0}" == "1" ]]; then
        dry "gsettings set $schema $key $value"
        return 0
    fi
    if ! have gsettings; then
        warn "gsettings not found; skipping $schema $key (set it manually if you use GTK apps)"
        return 0
    fi
    old="$(gsettings get "$schema" "$key" 2>/dev/null)" || {
        warn "gsettings schema/key unavailable: $schema $key"
        return 0
    }
    if [[ "$old" == "$value" || "$old" == "'$value'" ]]; then
        info "gsettings $schema $key already '$value'"
        return 0
    fi
    if is_dry_run; then
        dry "gsettings set $schema $key $value (was $old)"
        return 0
    fi
    gsettings set "$schema" "$key" "$value"
    record_cmd "gsettings set $schema $key $old"
    info "gsettings $schema $key = $value (was $old)"
}

# include_block <file> <block-id> [line...]
#
# Adds / replaces a marker delimited block. Idempotent by construction: the
# previous block is stripped before the new one is appended, so re-running an
# install never stacks duplicate lines.
#
# Set SWAY98_BLOCK_PREFIX when the target file is not shell/INI syntax
# (e.g. "//" for user.js, "<!-- ... -->" style markers get the same prefix).
include_block() {
    local file="$1" id="$2"; shift 2
    local p="${SWAY98_BLOCK_PREFIX:-#}"
    local begin="$p >>> $id >>>" end="$p <<< $id <<<"
    local tmp line
    tmp="$(mktemp)"

    if [[ -f "$file" ]]; then
        awk -v b="$begin" -v e="$end" '
            $0 == b { skip = 1; next }
            $0 == e { skip = 0; next }
            !skip   { print }
        ' "$file" >"$tmp"
        # Trim trailing blank lines the strip may have left behind.
        while [[ -s "$tmp" && -z "$(tail -n 1 "$tmp")" ]]; do
            sed -i '$d' "$tmp"
        done
        # Keep exactly one trailing newline before appending the block.
        if [[ -s "$tmp" ]]; then
            printf '\n' >>"$tmp"
        fi
    fi

    printf '%s\n' "$begin" >>"$tmp"
    for line in "$@"; do
        printf '%s\n' "$line" >>"$tmp"
    done
    printf '%s\n' "$end" >>"$tmp"

    _edit_apply "$tmp" "$file" merge
    rm -f -- "$tmp"
}

# ini_set <file> <section> <key> <value>
#
# Sets key=value inside [section], creating the file, the section or the key as
# needed. Comments and unrelated keys are preserved.
ini_set() {
    local file="$1" section="$2" key="$3" value="$4"
    local tmp
    tmp="$(mktemp)"

    if [[ -f "$file" ]]; then
        awk -v section="$section" -v key="$key" -v value="$value" '
            function emit_missing() {
                if (in_section && !done) {
                    printf "%s=%s\n", key, value
                    done = 1
                }
            }
            /^\[/ {
                emit_missing()
                if ($0 == "[" section "]") { in_section = 1 } else { in_section = 0 }
                print
                next
            }
            {
                if (in_section && $0 ~ "^[ \t]*" key "[ \t]*=") {
                    printf "%s=%s\n", key, value
                    done = 1
                    next
                }
                print
            }
            END {
                if (!done) {
                    if (!in_section) { printf "[%s]\n", section }
                    printf "%s=%s\n", key, value
                }
            }
        ' "$file" >"$tmp"
    else
        printf '[%s]\n%s=%s\n' "$section" "$key" "$value" >"$tmp"
    fi

    _edit_apply "$tmp" "$file" merge
    rm -f -- "$tmp"
}

# ini_remove <file> <section> <key>: delete a key, dropping the section when it
# becomes empty. Used by module revert paths that must not leave debris.
ini_remove() {
    local file="$1" section="$2" key="$3"
    local tmp
    [[ -f "$file" ]] || return 0
    tmp="$(mktemp)"
    awk -v section="$section" -v key="$key" '
        /^\[/ { if (buf != "" && !seen) print "";  buf=""; in_section = ($0 == "[" section "]"); print; next }
        {
            if (in_section && $0 ~ "^[ \t]*" key "[ \t]*=") { next }
            print
        }
    ' "$file" >"$tmp"
    _edit_apply "$tmp" "$file" merge
    rm -f -- "$tmp"
}
