#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# execute -- carry out one planned action.
#
# Handler contract, identical for every directive:
#   * signature: handler <plan-index>
#   * EXACTLY ONE log line per call, describing the outcome
#   * the RETURN CODE is the source of truth; counting lives in the caller,
#     never in a handler
#   * --dry-run logs the intended action and returns success WITHOUT touching
#     the filesystem
#   * errors are logged and returned; a handler NEVER exits
#
# Performance: cp, rm and cmp are the real work and are expected to spawn.
# Everything around them is a builtin -- no basename, no dirname, no subshell.
#
# Author: Haris Ahmad -- Smart IS
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# ensure_dir <dir>
#
# Create a destination directory when it is missing. The rollout may deliver
# into a tree the repository has never had -- the declared patch source tree is
# exactly that case -- so creating it is part of applying, not an error.
#
# `[ -d ]` is a builtin and mkdir is not, so the test comes first: an existing
# directory costs no process spawn.
# ---------------------------------------------------------------------------
ensure_dir() {
    [ -d "$1" ] && return 0
    [ "$DRY_RUN" -eq 1 ] && return 0
    mkdir -p "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# prune_empty_dirs <start-dir> <floor>
#
# After a deletion, remove parent directories that are now empty, walking
# bottom-up and stopping at the first non-empty one. Never removes the floor
# and never climbs above it; a blank floor disables pruning entirely.
#
# Emptiness is tested with a glob, so a directory that still has siblings costs
# NO process spawn. rmdir is spawned only for a directory that really is empty.
# Do not replace this with a blind rmdir per file, or with find/ls.
# ---------------------------------------------------------------------------
prune_empty_dirs() {
    local dir=$1 floor=$2 entry empty
    [ -n "$floor" ] || return 0
    [ "$DRY_RUN" -eq 1 ] && return 0

    while [ -n "$dir" ] && [ "$dir" != "$floor" ] && [ "$dir" != "/" ] && [ "$dir" != "." ]; do
        case $dir in
            "$floor"/*) ;;
            *) break ;;                       # never climb above the floor
        esac
        [ -d "$dir" ] || break

        empty=1
        for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
            if [ -e "$entry" ] || [ -L "$entry" ]; then empty=0; break; fi
        done
        [ "$empty" -eq 1 ] || break

        rmdir "$dir" 2>/dev/null || break
        path_dir "$dir"; dir=$PATH_DIR
    done
    return 0
}

# ---------------------------------------------------------------------------
# replace_file <index>   ->  0 ok / 1 failed
# ---------------------------------------------------------------------------
replace_file() {
    local i=$1
    local label=${P_MANIFEST[$i]} no=${P_LINE[$i]}
    local src="$PACKAGE_DIR/${P_SOURCE[$i]}" dest=${P_DEST[$i]} rule=${P_RULE[$i]}
    local dir

    if [ ! -f "$src" ]; then
        log_error "$label:$no REPLACE failed, source not found: ${P_SOURCE[$i]}"
        return 1
    fi

    path_dir "$dest"; dir=$PATH_DIR

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "$label:$no REPLACE would place [$rule] $dest"
        version_applies "$i" && preview_version "$src" "$VERSION_OVERRIDE"
        return 0
    fi

    if ! ensure_dir "$dir"; then
        log_error "$label:$no REPLACE failed, cannot create directory: $dir"
        return 1
    fi
    # Some corrections substitute IN TRANSIT -- the version override, and the
    # deploy bundle's web application segment. A qualifying file is copied line
    # by line instead of with cp, through every transform that applies. The
    # package is never written to.
    if version_applies "$i" || bundle_applies "$i"; then
        if copy_with_transforms "$src" "$dest" "$i"; then
            log_info "$label:$no REPLACE placed [$rule] $dest"
            return 0
        fi
        log_error "$label:$no REPLACE failed, cannot write: $dest"
        return 1
    fi
    if cp "$src" "$dest" 2>/dev/null; then
        log_info "$label:$no REPLACE placed [$rule] $dest"
        return 0
    fi
    log_error "$label:$no REPLACE failed, cannot write: $dest"
    return 1
}

# ---------------------------------------------------------------------------
# remove_file <index>   ->  0 removed / 2 absent / 1 failed
#
# REMOVE is optional and never fails. An already-absent target is a no-op, not
# a failure and not worth a warning: a package may legitimately be applied
# where the cleanup already happened by other means.
# ---------------------------------------------------------------------------
remove_file() {
    local i=$1
    local label=${P_MANIFEST[$i]} no=${P_LINE[$i]}
    local dest=${P_DEST[$i]} floor=${P_BASE[$i]} dir

    if [ -d "$dest" ]; then
        log_warn "$label:$no REMOVE skipped, destination is a directory: $dest"
        return 0
    fi
    if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
        log_info "$label:$no REMOVE absent, nothing to remove: $dest"
        return 2
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "$label:$no REMOVE would delete $dest"
        return 0
    fi
    if rm -f "$dest" 2>/dev/null; then
        log_info "$label:$no REMOVE deleted $dest"
        path_dir "$dest"; dir=$PATH_DIR
        prune_empty_dirs "$dir" "$floor"
        return 0
    fi
    log_error "$label:$no REMOVE failed, cannot delete: $dest"
    return 1
}

# ---------------------------------------------------------------------------
# undo_file <index>   ->  0 removed / 2 absent / 3 skipped / 1 failed
#
# Undo reverses REPLACE only, and deletes a file ONLY while it still matches
# the package's copy. That guard is what stops an undo from clobbering a later
# rollout's work -- do not remove it.
#
# Undo needs no stored state and no backup: it derives everything from the
# manifest, so it works on any already-applied package, including one applied
# before this tool existed. That was a deliberate design choice -- delete-based,
# not restore-based.
# ---------------------------------------------------------------------------
undo_file() {
    local i=$1
    local label=${P_MANIFEST[$i]} no=${P_LINE[$i]}
    local src="$PACKAGE_DIR/${P_SOURCE[$i]}" dest=${P_DEST[$i]}
    local floor=${P_BASE[$i]} dir

    if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
        log_info "$label:$no UNDO absent, nothing to remove: $dest"
        return 2
    fi
    if [ ! -f "$src" ]; then
        log_warn "$label:$no UNDO skipped, package source missing so the file cannot be verified: $dest"
        return 3
    fi
    # Byte equality first. On failure, a second pass that tolerates a
    # difference confined to the leading four-digit year of a version value --
    # which is what makes undo independent of whether --version was used on the
    # way in. Everywhere else, byte equality alone.
    if ! cmp -s "$src" "$dest"; then
        if version_scope "$i" && same_but_for_year "$src" "$dest"; then
            log_info "$label:$no UNDO version differs only by year; treated as this package's work"
        elif bundle_applies "$i" && same_but_for_web_app "$src" "$dest"; then
            log_info "$label:$no UNDO differs only by the web application segment this run substituted; treated as this package's work"
        elif same_but_for_merged_attrs "$src" "$dest"; then
            log_info "$label:$no UNDO differs only by attributes this package's retired kinds contributed; treated as this package's work"
        else
            log_warn "$label:$no UNDO skipped, file changed since apply: $dest"
            return 3
        fi
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "$label:$no UNDO would remove $dest"
        return 0
    fi
    if rm -f "$dest" 2>/dev/null; then
        log_info "$label:$no UNDO removed $dest"
        path_dir "$dest"; dir=$PATH_DIR
        prune_empty_dirs "$dir" "$floor"
        return 0
    fi
    log_error "$label:$no UNDO failed, cannot delete: $dest"
    return 1
}

# ---------------------------------------------------------------------------
# execute_plan
#
# Walk the plan and dispatch. Counting happens HERE, in one place, driven by
# the handlers' return codes.
# ---------------------------------------------------------------------------
T_REPLACED=0; T_REMOVED=0; T_ABSENT=0; T_FAILED=0
T_SKIPPED=0;  T_UNDONE=0;  T_UNDO_SKIPPED=0; T_MERGE=0; T_REPORT=0

execute_plan() {
    local i rc pass kind

    # REPLACE runs first, REMOVE last -- across the WHOLE plan, not per
    # manifest. A package may deliver a record into one directory and remove a
    # superseded one from another, and interleaving them in manifest order
    # makes the final tree depend on directive order within the file. Two
    # passes make the outcome depend only on the package's content, which is
    # what lets the same rollout be applied repeatedly to the same result: the
    # second run re-copies files that are already there and finds nothing left
    # to delete.
    #
    # Undo needs no such split: it only ever reverses REPLACE, so there is one
    # kind of operation to carry out.
    if [ "$UNDO" -eq 1 ]; then
        i=0
        while [ "$i" -lt "$P_COUNT" ]; do
            if skip_disposition "$i"; then i=$((i + 1)); continue; fi
            if [ "${P_KIND[$i]}" = "REMOVE" ]; then
                log_info "${P_MANIFEST[$i]}:${P_LINE[$i]} REMOVE cannot be undone, skipped: ${P_DEST[$i]}"
                T_UNDO_SKIPPED=$((T_UNDO_SKIPPED + 1))
            else
                undo_file "$i"; rc=$?
                case $rc in
                    0) T_UNDONE=$((T_UNDONE + 1)) ;;
                    2) T_ABSENT=$((T_ABSENT + 1)) ;;
                    3) T_UNDO_SKIPPED=$((T_UNDO_SKIPPED + 1)) ;;
                    *) T_FAILED=$((T_FAILED + 1)) ;;
                esac
            fi
            i=$((i + 1))
        done
        return 0
    fi

    for pass in REPLACE REMOVE; do
        i=0
        while [ "$i" -lt "$P_COUNT" ]; do
            kind=${P_KIND[$i]}
            if [ "$kind" != "$pass" ] || skip_disposition "$i"; then i=$((i + 1)); continue; fi
            case $kind in
                REPLACE) replace_file "$i"; rc=$?
                         if [ "$rc" -eq 0 ]; then T_REPLACED=$((T_REPLACED + 1))
                         else T_FAILED=$((T_FAILED + 1)); fi ;;
                REMOVE)  remove_file "$i"; rc=$?
                         case $rc in
                             0) T_REMOVED=$((T_REMOVED + 1)) ;;
                             2) T_ABSENT=$((T_ABSENT + 1)) ;;
                             *) T_FAILED=$((T_FAILED + 1)) ;;
                         esac ;;
            esac
            i=$((i + 1))
        done
    done
    return 0
}

# ---------------------------------------------------------------------------
# skip_disposition <index>
#
# True when the action is not executed at all. Counted once, on the REPLACE
# pass, so a two-pass walk does not double-count.
# ---------------------------------------------------------------------------
skip_disposition() {
    local i=$1
    case ${P_DISP[$i]} in
        skip)   [ "${P_KIND[$i]}" = "REPLACE" ] && T_SKIPPED=$((T_SKIPPED + 1)); return 0 ;;
        merge)  [ "${P_KIND[$i]}" = "REPLACE" ] && T_MERGE=$((T_MERGE + 1));     return 0 ;;
        report) [ "${P_KIND[$i]}" = "REPLACE" ] && T_REPORT=$((T_REPORT + 1));   return 0 ;;
    esac
    return 1
}
