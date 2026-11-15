#!/usr/bin/env bash
# shellcheck shell=bash
#
# sway98 — the transaction layer.
#
# Everything that touches a file on the user's disk goes through install_file(),
# install_dir() or record_cmd(). Those are the only functions that write to the
# manifest, and the manifest is the only source of truth for uninstall.sh.
#
# Manifest layout (TSV, appended during install, consumed during rollback):
#   manifest/files.tsv     module  action  path  sha_new  sha_old  backup
#   manifest/commands.tsv  module  revert_command
#   manifest/dirs.tsv      module  path
#   manifest/modules.tsv   module  status  version  timestamp

manifest_dir() { printf '%s\n' "$SWAY98_STATE/manifest"; }
manifest_files() { printf '%s\n' "$SWAY98_STATE/manifest/files.tsv"; }
manifest_commands() { printf '%s\n' "$SWAY98_STATE/manifest/commands.tsv"; }
manifest_dirs() { printf '%s\n' "$SWAY98_STATE/manifest/dirs.tsv"; }
manifest_modules() { printf '%s\n' "$SWAY98_STATE/manifest/modules.tsv"; }

manifest_init() {
    if is_dry_run; then
        dry "would prepare state directory $SWAY98_STATE"
        return 0
    fi
    mkdir -p -- "$SWAY98_STATE/manifest" "$SWAY98_STATE/backups/$SWAY98_TS" "$SWAY98_STATE/log"
    local f
    for f in "$(manifest_files)" "$(manifest_commands)" "$(manifest_dirs)" "$(manifest_modules)"; do
        [[ -e "$f" ]] || : >"$f"
    done
}

sha256_of() { sha256sum -- "$1" | awk '{print $1}'; }

# backup_of <path> — copy a file aside for the current run and echo the copy path.
backup_of() {
    local path="$1" rel out
    if [[ "$path" == "$HOME"/* ]]; then
        rel="home/${path#"$HOME"/}"
    else
        rel="system${path}"
    fi
    out="$SWAY98_STATE/backups/$SWAY98_TS/$rel"
    mkdir -p -- "$(dirname -- "$out")"
    cp -a -- "$path" "$out"
    printf '%s\n' "$out"
}

manifest_record_file() {
    local module="$1" action="$2" path="$3" sha_new="$4" sha_old="${5:-}" backup="${6:-}"
    is_dry_run && return 0
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$module" "$action" "$path" "$sha_new" "$sha_old" "$backup" >>"$(manifest_files)"
}

manifest_record_dir() {
    local module="$1" path="$2"
    is_dry_run && return 0
    printf '%s\t%s\n' "$module" "$path" >>"$(manifest_dirs)"
}

record_cmd() {
    local cmd="$1"
    is_dry_run && { dry "would record revert command: $cmd"; return 0; }
    printf '%s\t%s\n' "${SWAY98_MODULE:-manual}" "$cmd" >>"$(manifest_commands)"
}

record_module() {
    local module="$1" status="$2"
    is_dry_run && return 0
    printf '%s\t%s\t%s\t%s\n' "$module" "$status" "$SWAY98_VERSION" "$(date -Is)" >>"$(manifest_modules)"
}

# The earliest record for a path defines how it is reverted. Re-installing must
# not overwrite that with an intermediate state, otherwise repeated runs would
# restore a half-themed file instead of the user's original.
#
# Returns 1 (and prints nothing) when the path has no record yet. Note the
# explicit emptiness check: awk exits 0 even when nothing matched, so a plain
# `if out="$(...)"` would silently treat "no record" as "record with empty
# fields" and lose the action column.
_manifest_earliest_record() {
    local path="$1" out
    [[ -s "$(manifest_files)" ]] || return 1
    out="$(awk -F'\t' -v p="$path" '$3 == p { print $2 "\t" $5 "\t" $6; exit }' "$(manifest_files)")"
    [[ -n "$out" ]] || return 1
    printf '%s\n' "$out"
}

# install_file <src> <dest>
install_file() {
    local src="$1" dest="$2"
    local action sha_new sha_old="" backup="" prev mode

    [[ -f "$src" ]] || die "install_file: source does not exist: $src"
    [[ -d "$dest" ]] && die "install_file: destination is a directory: $dest"

    if [[ -e "$dest" ]] && cmp -s -- "$src" "$dest"; then
        info "unchanged: $dest"
        return 0
    fi

    if [[ -e "$dest" ]]; then
        action="modify"
        if prev="$(_manifest_earliest_record "$dest")"; then
            action="$(cut -f1 <<<"$prev")"
            sha_old="$(cut -f2 <<<"$prev")"
            backup="$(cut -f3 <<<"$prev")"
        else
            sha_old="$(sha256_of "$dest")"
            if is_dry_run; then
                dry "would back up $dest"
            else
                backup="$(backup_of "$dest")"
            fi
        fi
    else
        action="create"
    fi

    if is_dry_run; then
        dry "$action $dest"
        return 0
    fi

    # Create (and record) every missing parent level so that uninstall can remove
    # the directories again once they are empty. Hand-rolled mkdir -p here would
    # leave empty directory trees behind after a rollback.
    _manifest_record_created_dirs "$(dirname -- "$dest")"

    mode="$(stat -c '%a' -- "$src")"
    install -m "$mode" -- "$src" "$dest"
    sha_new="$(sha256_of "$dest")"
    manifest_record_file "${SWAY98_MODULE:-manual}" "$action" "$dest" "$sha_new" "$sha_old" "$backup"
    if [[ "$action" == "modify" ]]; then
        info "modified: $dest (backup: ${backup#"$SWAY98_STATE"/})"
    else
        info "created: $dest"
    fi
}

# install_symlink <src-link> <dest>
#
# Chicago95's icon theme is largely built from symlinks (one icon reused under
# twenty names). install_file() would dereference them and duplicate the target
# thousands of times, so links get their own path: recreate the link, record it
# without a hash. Rollback deletes it like any file it created.
install_symlink() {
    local src="$1" dest="$2" target prev
    target="$(readlink -- "$src")" || die "install_symlink: not a symlink: $src"

    if [[ -L "$dest" && "$(readlink -- "$dest")" == "$target" ]]; then
        info "unchanged: $dest"
        return 0
    fi

    local action="create" backup=""
    if [[ -e "$dest" || -L "$dest" ]]; then
        action="modify"
        if prev="$(_manifest_earliest_record "$dest")" && [[ -n "$prev" ]]; then
            action="$(cut -f1 <<<"$prev")"
            backup="$(cut -f3 <<<"$prev")"
        elif is_dry_run; then
            dry "would back up $dest"
        else
            backup="$(backup_of "$dest")"
        fi
    fi

    if is_dry_run; then
        dry "$action $dest -> $target"
        return 0
    fi

    _manifest_record_created_dirs "$(dirname -- "$dest")"
    ln -sfn -- "$target" "$dest"
    manifest_record_file "${SWAY98_MODULE:-manual}" "$action" "$dest" "" "" "$backup"
    info "$action: $dest -> $target"
}

# install_dir <src-dir> <dest-dir> — recursive, records files and created dirs.
install_dir() {
    local src="$1" dest="$2" f rel
    [[ -d "$src" ]] || die "install_dir: source does not exist: $src"

    if [[ ! -e "$dest" ]]; then
        _install_tree_create "$src" "$dest"
        return 0
    fi

    # Re-installing over an existing tree: one diff for the whole tree is much
    # cheaper than comparing file by file, and is the common case for `--only`.
    if ! is_dry_run && diff -rq --no-dereference -- "$src" "$dest" >/dev/null 2>&1; then
        info "unchanged: $dest"
        return 0
    fi

    _manifest_record_created_dirs "$dest"
    while IFS= read -r -d '' f; do
        rel="${f#"$src"/}"
        install_file "$f" "$dest/$rel"
    done < <(find "$src" -type f -print0)
    while IFS= read -r -d '' l; do
        rel="${l#"$src"/}"
        install_symlink "$l" "$dest/$rel"
    done < <(find "$src" -type l -print0)
}

# Fast path for a destination that does not exist yet, which is what the big
# upstream trees (Chicago95's 4000+ icon files) hit. Copying the tree in one
# process, hashing it with a batched sha256sum and appending the manifest rows in
# a single awk pass cuts a full install from ~90s to a few seconds. Per-file
# install_file() costs four processes per file, which is fine for a handful of
# config files and terrible for a theme.
_install_tree_create() {
    local src="$1" dest="$2" hashes escaped_list odd_file subdir

    if is_dry_run; then
        dry "create $dest ($(find "$src" -type f | wc -l) files from ${src#"$SWAY98_ROOT"/})"
        return 0
    fi

    # Parents first (recorded), then the tree itself: `cp -a src dest` only copies
    # into dest when dest does not exist yet.
    _manifest_record_created_dirs "$(dirname -- "$dest")"
    cp -a -- "$src" "$dest"
    manifest_record_dir "${SWAY98_MODULE:-manual}" "$dest"

    # Every subdirectory the copy created, shallowest first so that the reverse
    # rollback order removes them deepest first. Forgetting this leaves empty
    # directory trees in $HOME after an uninstall (found by tests/run-sandbox.sh).
    {
        while IFS= read -r -d '' subdir; do
            printf '%s\t%s\n' "${SWAY98_MODULE:-manual}" "$subdir"
        done < <(find "$dest" -mindepth 1 -type d -print0)
    } >>"$(manifest_dirs)"

    hashes="$(mktemp)"
    find "$dest" -type f -print0 | xargs -0 -r sha256sum >"$hashes"

    # sha256sum prints "<64 hex chars>  <path>". A leading backslash means the
    # path contains characters sha256sum escaped; those rare files are recorded
    # individually below instead of in the bulk pass.
    escaped_list="$(mktemp)"
    awk -v module="${SWAY98_MODULE:-manual}" '
        substr($0, 1, 1) == "\\" { print substr($0, 68) >"/dev/stderr"; next }
        { printf "%s\tcreate\t%s\t%s\t\t\n", module, substr($0, 67), substr($0, 1, 64) }
    ' "$hashes" >>"$(manifest_files)" 2>"$escaped_list"

    if [[ -s "$escaped_list" ]]; then
        warn "$(wc -l <"$escaped_list") file(s) with unusual names recorded individually"
        while IFS= read -r odd_file; do
            [[ -f "$odd_file" ]] || continue
            manifest_record_file "${SWAY98_MODULE:-manual}" "create" "$odd_file" "$(sha256_of "$odd_file")" "" ""
        done <"$escaped_list"
    fi
    rm -f -- "$escaped_list"

    # Symlinks: not regular files, so they need their own pass. Chicago95's icon
    # theme is mostly symlinks — miss them and every rollback leaves thousands of
    # dangling links behind. They are recorded without a hash: rollback deletes
    # them, it never restores them from a backup.
    {
        while IFS= read -r -d '' link; do
            printf '%s\tcreate\t%s\t\t\t\n' "${SWAY98_MODULE:-manual}" "$link"
        done < <(find "$dest" -type l -print0)
    } >>"$(manifest_files)"

    rm -f -- "$hashes"
    info "created: $dest ($(wc -l <"$(manifest_files)") manifest rows so far)"
}

_manifest_record_created_dirs() {
    local dest="$1" cur parent created=()
    cur="$dest"
    while [[ ! -d "$cur" && "$cur" != "/" && "$cur" != "." ]]; do
        created+=("$cur")
        parent="$(dirname -- "$cur")"
        [[ "$parent" == "$cur" ]] && break
        cur="$parent"
    done
    local i
    for (( i = ${#created[@]} - 1; i >= 0; i-- )); do
        if is_dry_run; then
            dry "create dir ${created[i]}"
        else
            mkdir -p -- "${created[i]}"
            manifest_record_dir "${SWAY98_MODULE:-manual}" "${created[i]}"
        fi
    done
}

# --- uninstall engine ---------------------------------------------------------

manifest_has_records() {
    local only="${1:-}" kind source_file
    for kind in files commands dirs modules; do
        source_file="$(manifest_dir)/$kind.tsv"
        [[ -s "$source_file" ]] || continue
        [[ -n "$only" ]] || return 0
        if awk -F'\t' -v only="$only" '$1 == only { found = 1; exit } END { exit !found }' "$source_file"; then
            return 0
        fi
    done
    return 1
}

# Partition a manifest using successful row numbers (key=0) or paths (key=3).
# The original stays active until all partitions have been prepared.
_manifest_partition() {
    local kind="$1" key="$2" work="$3" only="${4:-}" source_file
    source_file="$(manifest_dir)/$kind.tsv"
    : >"$work/$kind.keep" || return 1
    : >"$work/$kind.done" || return 1
    [[ -f "$source_file" ]] || return 0
    awk -F'\t' -v key="$key" -v only="$only" -v keep="$work/$kind.keep" -v done="$work/$kind.done" '
        FILENAME == ARGV[1] { success[$0] = 1; next }
        {
            record_key = (key == 0 ? FNR : $key)
            if ((only == "" || $1 == only) && record_key in success) print >done
            else print >keep
        }
    ' "$work/$kind.success" "$source_file"
}

# restore_all [module-filter] — reverse order: commands, files, directories.
# Successful records are consumed even if another rollback fails. Failed rows
# and module metadata with outstanding work remain active for an ordinary retry.
restore_all() {
    local only="${1:-}" mod cmd action path sha_new sha_old backup row row_id
    local failures=0 count=0 work="" kind hist
    local -a created_paths=()

    if ! is_dry_run; then
        work="$(mktemp -d "$(manifest_dir)/.rollback.XXXXXX")" || return 1
        for kind in commands files dirs; do
            : >"$work/$kind.success" || return 1
        done
    fi

    if [[ -s "$(manifest_commands)" ]]; then
        step "Reverting recorded commands"
        while IFS=$'\t' read -r row_id mod cmd; do
            [[ -n "$only" && "$mod" != "$only" ]] && continue
            if is_dry_run; then
                dry "revert command [$mod]: $cmd"
            elif [[ -n "$cmd" ]] && ( eval "$cmd" ); then
                printf '%s\n' "$row_id" >>"$work/commands.success" || return 1
            else
                warn "revert command failed [$mod]: $cmd"
                failures=$((failures + 1))
            fi
        done < <(awk '{ print NR "\t" $0 }' "$(manifest_commands)" | tac)
    fi

    if [[ -s "$(manifest_files)" ]]; then
        step "Restoring files"
        # Re-install rows for the same selected path share its original backup.
        # Consume them together only after the path has been reverted.
        while IFS= read -r row; do
            # A non-whitespace delimiter preserves empty TSV columns (symlinks
            # have no hashes, but may still have a backup in the last column).
            IFS=$'\x1f' read -r mod action path sha_new sha_old backup <<<"${row//$'\t'/$'\x1f'}"
            case "$action" in
                create)
                    if is_dry_run; then
                        dry "remove $path"
                    else
                        created_paths+=("$path")
                    fi
                    continue
                    ;;
                modify)
                    if [[ -z "$backup" || ( ! -e "$backup" && ! -L "$backup" ) ]]; then
                        warn "no backup for $path, leaving as is"
                    elif is_dry_run; then
                        dry "restore $path from ${backup#"$SWAY98_STATE"/}"
                        continue
                    elif cp -a -- "$backup" "$path"; then
                        info "restored: $path"
                        printf '%s\n' "$path" >>"$work/files.success" || return 1
                        count=$((count + 1))
                        continue
                    else
                        warn "restore failed for $path"
                    fi
                    ;;
                *) warn "unknown manifest action '$action' for $path" ;;
            esac
            failures=$((failures + 1))
        done < <(awk -F'\t' -v only="$only" '
            (only == "" || $1 == only) && !seen[$3]++ {print}
        ' "$(manifest_files)" | tac)

        if ((${#created_paths[@]})); then
            # rm can partially succeed. Check each path before consuming its
            # rows so that a failed batch never loses retry information.
            if ! printf '%s\0' "${created_paths[@]}" | xargs -0 -r rm -f --; then
                warn "some created files could not be removed"
            fi
            for path in "${created_paths[@]}"; do
                if [[ ! -e "$path" && ! -L "$path" ]]; then
                    printf '%s\n' "$path" >>"$work/files.success" || return 1
                    count=$((count + 1))
                else
                    warn "could not remove $path"
                    failures=$((failures + 1))
                fi
            done
        fi
        info "$count file(s) reverted"
    fi

    if [[ -s "$(manifest_dirs)" ]]; then
        step "Removing directories created by $SWAY98_NAME"
        while IFS=$'\t' read -r row_id mod path; do
            [[ -n "$only" && "$mod" != "$only" ]] && continue
            if is_dry_run; then
                dry "rmdir $path"
            elif [[ ! -e "$path" && ! -L "$path" ]] || rmdir -- "$path"; then
                printf '%s\n' "$row_id" >>"$work/dirs.success" || return 1
            else
                warn "could not remove directory $path; keeping its record for retry"
                failures=$((failures + 1))
            fi
        done < <(awk '{ print NR "\t" $0 }' "$(manifest_dirs)" | tac)
    fi

    if ! is_dry_run; then
        _manifest_partition commands 0 "$work" || return 1
        _manifest_partition files 3 "$work" "$only" || return 1
        _manifest_partition dirs 0 "$work" || return 1
        : >"$work/modules.keep" || return 1
        : >"$work/modules.done" || return 1
        if [[ -f "$(manifest_modules)" ]]; then
            awk -F'\t' -v only="$only" -v keep="$work/modules.keep" -v done="$work/modules.done" '
                FILENAME != ARGV[4] { pending[$1] = 1; next }
                { if ((only == "" || $1 == only) && !($1 in pending)) print >done; else print >keep }
            ' "$work/commands.keep" "$work/files.keep" "$work/dirs.keep" "$(manifest_modules)" || return 1
        fi
        # A unique history directory prevents retries in the same second from
        # replacing an earlier archive. Only consumed rows belong in history.
        for kind in commands files dirs modules; do
            if [[ -s "$work/$kind.done" ]]; then
                if [[ -z "${hist:-}" ]]; then
                    mkdir -p -- "$(manifest_dir)/history" || return 1
                    hist="$(mktemp -d "$(manifest_dir)/history/$SWAY98_TS-XXXXXX")" || return 1
                fi
                cp -- "$work/$kind.done" "$hist/$kind.tsv" || return 1
            fi
        done
        for kind in commands files dirs modules; do
            mv -- "$work/$kind.keep" "$(manifest_dir)/$kind.tsv" || return 1
        done
        rm -r -- "$work" || return 1
        [[ -z "${hist:-}" ]] || info "reverted records archived to $hist"
    fi

    if ((failures)); then
        err "$failures rollback operation(s) failed; unresolved records remain active. Run uninstall again to retry."
        return 1
    fi
}
