#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# consolidate -- rebuild the combined load-data file for a table.
#
# Some load data is stored one file per record, and the destination also keeps
# a COMBINED file per table in a versioned upgrade directory.
#
# The combined file is a MANUFACTURED ARTIFACT: rebuilt from scratch whenever a
# run touches the table, never edited in place. It does not replace, modify or
# remove source records, which land through their own directives.
#
# Every record file in one table directory carries the same header -- that is a
# property of how the data is generated, and it is what makes a single combined
# header well-defined. The RECORDS are the authority on columns; the control
# file is copied alongside and consumed by the loader, but does not dictate the
# column set (SPEC.md 7.1).
#
# Author: Haris Ahmad -- Smart IS
# ---------------------------------------------------------------------------

CON_REBUILT=0
CON_REMOVED=0
CON_WARNINGS=0

# ---------------------------------------------------------------------------
# is_table_dir <dir>
#
# A per-table load directory, recognised by SHAPE: a directory with a control
# file of the same base name beside it. Nothing is matched by name.
# ---------------------------------------------------------------------------
is_table_dir() {
    local dir=$1 parent base
    [ -d "$dir" ] || return 1
    path_dir "$dir"; parent=$PATH_DIR
    base=${dir##*/}
    [ -f "$parent/$base.ctl" ]
}

# ---------------------------------------------------------------------------
# table_header <dir> -> $TBL_HEADER
#
# The header the record files already carry. They are expected to agree; if two
# disagree the first in stable order wins and the discrepancy is REPORTED,
# because a silent choice between two shapes is exactly the guess this design
# removes.
# ---------------------------------------------------------------------------
table_header() {
    local dir=$1 f first="" line
    TBL_HEADER=""
    for f in "$dir"/*; do
        [ -f "$f" ] || continue
        IFS= read -r line <"$f" || continue
        strip_cr "$line"; line=$STRIPPED_CR
        [ -n "$line" ] || continue
        if [ -z "$first" ]; then
            first=$line
            TBL_HEADER=$line
        elif [ "$line" != "$first" ]; then
            log_warn "  consolidate: record files disagree on their header in ${dir##*/}; using the first: ${f##*/}"
            CON_WARNINGS=$((CON_WARNINGS + 1))
        fi
    done
    [ -n "$TBL_HEADER" ]
}

# ---------------------------------------------------------------------------
# write_descriptor <version-dir> <base>
#
# The loader descriptor's form is fixed and derivable from the base name alone.
# GENERATED ONLY WHEN ABSENT: an existing one is left untouched, because it may
# carry local adjustment this tool has no basis to overwrite.
# ---------------------------------------------------------------------------
write_descriptor() {
    local vdir=$1 base=$2 out="$1/$2.mload"
    if [ -f "$out" ]; then
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "  consolidate: would create the loader descriptor $base.mload"
        return 0
    fi
    {
        printf -- '-H\n'
        printf -- '-d=%s.csv\n' "$base"
        printf -- '-c=%s.ctl\n' "$base"
    } >"$out" 2>/dev/null || { log_error "  consolidate: cannot write $out"; return 1; }
    log_info "  consolidate: created the loader descriptor $base.mload"
    return 0
}

# ---------------------------------------------------------------------------
# remove_combined_everywhere <base>
#
# When a rollout deletes a table's last record file -- so the folder itself is
# gone -- the combined artifacts it fed must go too, and from EVERY version
# directory under the upgrade parent, not merely the newest.
#
# Sweeping all of them is not thoroughness for its own sake: the versions here
# hold disjoint sets of tables, so a table's combined file may well sit in an
# older directory. Cleaning only the newest would leave it behind, still
# loadable, describing records that no longer exist.
#
# ROLLOUT ONLY. Manual consolidation never deletes: --combine is invoked to
# rebuild named folders, and a folder that is absent there is the operator's
# mistake, not an instruction to remove data.
# ---------------------------------------------------------------------------
remove_combined_everywhere() {
    local base=$1 v vdir hit=0

    [ -n "$D_UPGRADE_PARENT" ] || return 1
    for vdir in "$D_UPGRADE_PARENT"/*/; do
        [ -d "$vdir" ] || continue
        vdir=${vdir%/}
        [ -f "$vdir/$base.csv" ] || [ -f "$vdir/$base.ctl" ] || [ -f "$vdir/$base.mload" ] || continue
        hit=$((hit + 1))
        if [ "$DRY_RUN" -eq 1 ]; then
            log_warn "  consolidate: would remove the combined artifacts for $base from ${vdir##*/} (its folder is gone)"
        else
            rm -f "$vdir/$base.csv" "$vdir/$base.ctl" "$vdir/$base.mload" 2>/dev/null
            log_warn "  consolidate: removed the combined artifacts for $base from ${vdir##*/} (its folder is gone)"
        fi
        CON_REMOVED=$((CON_REMOVED + 1))
    done
    [ "$hit" -gt 0 ]
}

# ---------------------------------------------------------------------------
# folder_is_gone <table-dir>
#
# The trigger for removal is the table folder ending the run with nothing in
# it -- the rollout deleted its last record and the empty parent was pruned.
#
# In a DRY RUN the answer must be PREDICTED, not read off disk. Nothing has
# been written yet, so a folder this package is about to create looks exactly
# like one that has just been emptied. Reading disk directly made the preview
# announce that it would delete the combined data for every table the run in
# fact rebuilds -- the opposite of what happens.
# ---------------------------------------------------------------------------
folder_is_gone() {
    local dir=$1 f n=0 i=0

    if [ "$DRY_RUN" -eq 0 ]; then
        [ -d "$dir" ] || return 0
        for f in "$dir"/*; do
            [ -f "$f" ] && return 1
        done
        return 0
    fi

    # --- predicted -----------------------------------------------------------
    for f in "$dir"/*; do
        [ -f "$f" ] && n=$((n + 1))
    done
    while [ "$i" -lt "$P_COUNT" ]; do
        if [ "${P_DISP[$i]}" = "apply" ]; then
            case ${P_DEST[$i]} in
                "$dir"/*)
                    if [ "$UNDO" -eq 1 ]; then
                        # undo reverses REPLACE: the file it placed goes away
                        [ "${P_KIND[$i]}" = "REPLACE" ] && [ -f "${P_DEST[$i]}" ] && n=$((n - 1))
                    else
                        case ${P_KIND[$i]} in
                            REPLACE) [ -f "${P_DEST[$i]}" ] || n=$((n + 1)) ;;
                            REMOVE)  [ -f "${P_DEST[$i]}" ] && n=$((n - 1)) ;;
                        esac
                    fi
                    ;;
            esac
        fi
        i=$((i + 1))
    done
    [ "$n" -le 0 ]
}

# ---------------------------------------------------------------------------
# consolidate_table <table-dir> <version-dir>
#
# Rebuild one table's combined artifacts from the CURRENT state of the tree --
# every record file now present, not only what this package delivered -- so the
# result is complete.
# ---------------------------------------------------------------------------
consolidate_table() {
    local dir=$1 vdir=$2
    local base=${dir##*/} parent f line first=1 count=0 tmp out ctl

    path_dir "$dir"; parent=$PATH_DIR
    ctl="$parent/$base.ctl"
    out="$vdir/$base.csv"

    # --- no records left ---------------------------------------------------
    # Removal is not decided here. A folder that still exists but holds nothing
    # is simply not rebuilt; a folder that is GONE is handled by the caller,
    # which sweeps every version directory (remove_combined_everywhere).
    count=0
    for f in "$dir"/*; do
        [ -f "$f" ] && count=$((count + 1))
    done
    if [ "$DRY_RUN" -eq 1 ]; then
        planned_record_count "$dir"
        count=$PRC_N
    fi
    if [ "$count" -eq 0 ]; then
        log_info "  consolidate: $base has no record files; nothing rebuilt"
        return 0
    fi

    if [ "$DRY_RUN" -eq 0 ] && ! table_header "$dir"; then
        log_warn "  consolidate: $base has record files but no readable header; skipped"
        CON_WARNINGS=$((CON_WARNINGS + 1))
        return 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        planned_record_count "$dir"
        log_info "  consolidate: would rebuild $base.csv from $PRC_N record file(s) into ${vdir##*/}"
        CON_REBUILT=$((CON_REBUILT + 1))
        return 0
    fi

    tmp="$out.tmp$$"
    : >"$tmp" 2>/dev/null || { log_error "  consolidate: cannot write $tmp"; return 1; }
    printf '%s\n' "$TBL_HEADER" >>"$tmp"

    # Record files in stable order, so re-running the same package over the
    # same tree produces the same file. The glob is already sorted; it also
    # avoids the word-splitting a $(... | sort) would do on a path with spaces,
    # and the subshell it would spawn.
    for f in "$dir"/*; do
        [ -f "$f" ] || continue
        first=1
        while IFS= read -r line || [ -n "$line" ]; do
            strip_cr "$line"; line=$STRIPPED_CR
            if [ "$first" -eq 1 ]; then first=0; continue; fi   # drop the header
            # EVERY remaining line is emitted verbatim, blank ones included.
            # A field may carry embedded newlines -- the syntax column of a
            # command table holds multi-line text -- so a "blank line" can be
            # part of a value. Dropping them would silently corrupt the record.
            printf '%s\n' "$line" >>"$tmp"
        done <"$f"
    done

    mv -f "$tmp" "$out" 2>/dev/null || { rm -f "$tmp"; log_error "  consolidate: cannot replace $out"; return 1; }
    log_info "  consolidate: rebuilt $base.csv from $count record file(s)"
    CON_REBUILT=$((CON_REBUILT + 1))

    if [ -f "$ctl" ]; then
        cp "$ctl" "$vdir/$base.ctl" 2>/dev/null \
            || log_error "  consolidate: cannot place the control file for $base"
    else
        log_warn "  consolidate: $base has no control file beside it; none placed"
        CON_WARNINGS=$((CON_WARNINGS + 1))
    fi

    write_descriptor "$vdir" "$base"
    return 0
}

# ---------------------------------------------------------------------------
# Which folders are consolidated (SPEC.md 7.3)
#
# Every folder THIS PACKAGE delivers record files into, that has a control file
# beside it, is rebuilt once all file operations have completed. Folders the
# package does not touch are left alone; the whole target is never scanned.
#
# ------------------------------------------------------------------ EXCLUSION
# A destination may keep more than one data tree -- records to LOAD and records
# to DELETE. They are structurally identical (both are <table>.ctl beside
# <table>/) and their table names collide, but their control files are opposite
# operations:
#
#     load tree    <table>.ctl : publish data where table=...
#     delete tree  <table>.ctl : [delete from <table> ...]
#
# Only one of them can own <upgrade>/<version>/<table>.csv.
#
# The delete tree is therefore EXPLICITLY EXCLUDED. Nothing in the tree tells
# the tool which of two identically-shaped folders is the delete tree, so this
# is a SETTING, not a derived rule. The tree's files are still delivered
# normally; only its combined artifact is not built. If a destination ever
# wants a combined artifact for its delete tree too, give it a destination of
# its own and drop it from this list.
#
# Entirely a SETTING, with no built-in default. The tool ships knowing no
# destination's tree names, so the exclusion list is stated in the settings
# file or it is empty -- a name compiled into the source would be wrong for
# every other destination and invisible to the operator running against one.
# ---------------------------------------------------------------------------
CON_EXCLUDE=""

derive_load_trees() {
    CON_EXCLUDE=$SET_COMBINE_EXCLUDE
    return 0
}

# ---------------------------------------------------------------------------
# planned_table_dir <dir>
#
# In a DRY RUN the table directory may not exist yet -- this package is what
# creates it -- so is_table_dir() would say no and the preview would silently
# understate what a real run changes (SPEC.md 10). Recognise the shape from the
# PLAN instead: a control file of the same base name is being delivered beside
# it.
# ---------------------------------------------------------------------------
planned_table_dir() {
    local dir=$1 parent base i=0
    path_dir "$dir"; parent=$PATH_DIR
    base=${dir##*/}
    while [ "$i" -lt "$P_COUNT" ]; do
        if [ "${P_DEST[$i]}" = "$parent/$base.ctl" ] && [ "${P_DISP[$i]}" = "apply" ]; then
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# planned_record_count <dir> -> $PRC_N
# How many record files that folder would hold after a real run: what is there
# now, plus what this package would put in it.
planned_record_count() {
    local dir=$1 f i=0
    PRC_N=0
    for f in "$dir"/*; do
        [ -f "$f" ] && PRC_N=$((PRC_N + 1))
    done
    while [ "$i" -lt "$P_COUNT" ]; do
        case ${P_DEST[$i]} in
            "$dir"/*)
                if [ "${P_DISP[$i]}" = "apply" ] && [ "${P_KIND[$i]}" = "REPLACE" ] \
                   && [ ! -f "${P_DEST[$i]}" ]; then
                    PRC_N=$((PRC_N + 1))
                fi
                ;;
        esac
        i=$((i + 1))
    done
    return 0
}

# is_excluded <dir> -- true when any path segment names an excluded tree
is_excluded() {
    local dir=$1 seg
    for seg in $CON_EXCLUDE; do
        [ -n "$seg" ] || continue
        case "/$dir/" in
            */"$seg"/*) return 0 ;;
        esac
    done
    return 1
}

log_load_trees() {
    if [ -n "$CON_EXCLUDE" ]; then
        log_info "  excluded       : $CON_EXCLUDE"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# consolidate_run
#
# Rebuild the combined data for every table a directive touched. Only touched
# tables are rebuilt, and the tool NEVER creates a version directory.
#
# Runs after all file operations, in apply AND undo, because it derives from
# the final state of the tree rather than from what the package contained.
# ---------------------------------------------------------------------------
consolidate_run() {
    local i=0 tables="" dir vdir excluded=""

    [ -n "$D_UPGRADE_PARENT" ] && [ -n "$D_UPGRADE_VERSION" ] || return 0
    vdir="$D_UPGRADE_PARENT/$D_UPGRADE_VERSION"
    [ -d "$vdir" ] || return 0

    while [ "$i" -lt "$P_COUNT" ]; do
        if [ -n "${P_DEST[$i]}" ] && [ "${P_DISP[$i]}" = "apply" ]; then
            path_dir "${P_DEST[$i]}"; dir=$PATH_DIR
            if is_table_dir "$dir" || planned_table_dir "$dir"; then
                if is_excluded "$dir"; then
                    path_dir "$dir"
                    list_has "$excluded" "$PATH_DIR" || list_add excluded "$PATH_DIR"
                else
                    list_add tables "$dir"
                fi
            fi
        fi
        i=$((i + 1))
    done

    [ -n "$tables" ] || [ -n "$excluded" ] || return 0
    log_head "load-data consolidation"
    log_info "  version dir    : ${vdir#"$TARGET_DIR"/}"
    log_load_trees

    for dir in $excluded; do
        log_info "  explicitly ignored, no combined data built: ${dir#"$TARGET_DIR"/}"
        log_info "    (files were delivered normally; a destination for this tree is still to be confirmed)"
    done

    for dir in $tables; do
        if folder_is_gone "$dir"; then
            remove_combined_everywhere "${dir##*/}"
        else
            consolidate_table "$dir" "$vdir"
        fi
    done

    if [ "$CON_REBUILT" -eq 0 ] && [ "$CON_REMOVED" -eq 0 ]; then
        log_info "  no table needed rebuilding."
    else
        log_info "  tables rebuilt: $CON_REBUILT   removed: $CON_REMOVED   warnings: $CON_WARNINGS"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# find_upgrade_for <base-path> -> $CU_PARENT, $CU_VERSION
#
# Manual mode is handed a directory of tables, not a repository, so the version
# directory is located by walking UP from that path: the first ancestor holding
# a child whose own children are all version-named is the upgrade parent.
#
# Shape again, not a name -- the same test stage 2 uses, anchored differently.
# ---------------------------------------------------------------------------
find_upgrade_for() {
    local dir=$1 sub kid kids vers best all
    CU_PARENT=""; CU_VERSION=""

    while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "." ]; do
        for sub in "$dir"/*/; do
            [ -d "$sub" ] || continue
            sub=${sub%/}
            kids=0; vers=0
            for kid in "$sub"/*/; do
                [ -d "$kid" ] || continue
                kid=${kid%/}; kid=${kid##*/}
                kids=$((kids + 1))
                case $kid in [0-9]*.[0-9]*) vers=$((vers + 1)) ;; esac
            done
            if [ "$kids" -gt 0 ] && [ "$kids" -eq "$vers" ]; then
                CU_PARENT=$sub
                all=""
                for kid in "$sub"/*/; do
                    [ -d "$kid" ] || continue
                    kid=${kid%/}
                    all="$all${kid##*/}
"
                done
                best=$(printf '%s' "$all" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1)
                CU_VERSION=$best
                return 0
            fi
        done
        path_dir "$dir"; dir=$PATH_DIR
    done
    return 1
}

# ---------------------------------------------------------------------------
# combine_run
#
# Manual consolidation (SPEC.md 7.4). The SAME engine the automatic path uses --
# it differs only in where the table list comes from:
#
#   base path(s)   given -> use them   omitted -> the configured list
#   --folders      REQUIRED            omitted -> setup error
#   target version given -> write here omitted -> the highest present
#
# BOTH inputs are required. There is no default base path, and no "every folder
# under it" default either: a manual run states exactly which tables it means.
# Sweeping a whole tree by default would rebuild every table the destination
# has, not the handful the operator had in mind.
#
# MANUAL CONSOLIDATION NEVER DELETES. Removing a combined artifact is driven by
# a rollout deleting a table's last record; a folder that is missing here is the
# operator naming the wrong thing, and is skipped with a warning.
# ---------------------------------------------------------------------------
combine_run() {
    local paths base folders f d vdir name found=0

    paths=${COMBINE_PATHS_ARG:-$SET_COMBINE_PATHS}
    [ -n "$paths" ] || die "--combine needs a base path, either on the command line or as COMBINE_PATHS in the settings file.
  There is no default: where load data lives is not something this tool guesses."

    [ -n "$COMBINE_FOLDERS" ] || die "--combine needs --folders naming the table folders to rebuild.
  There is deliberately no \"every folder\" default: a manual run states which tables
  it means, rather than rebuilding every table the destination happens to have.
  Example: --combine <base-path> --folders <table-a>,<table-b>"

    CON_EXCLUDE=$SET_COMBINE_EXCLUDE

    log_head "manual consolidation"
    log_load_trees

    # --folders accepts a comma- or space-separated list
    folders=$(printf '%s' "$COMBINE_FOLDERS" | tr ',' ' ')

    for base in $paths; do
        is_abs "$base" || base="$PWD/$base"
        normalize_path "$base"; base=$NORMALIZED
        if [ ! -d "$base" ]; then
            log_error "  base path not found: $base"
            continue
        fi

        if [ -n "$COMBINE_TARGET_VERSION" ]; then
            if find_upgrade_for "$base"; then
                vdir="$CU_PARENT/$COMBINE_TARGET_VERSION"
            else
                log_error "  no version directory could be located above $base"
                continue
            fi
        elif find_upgrade_for "$base"; then
            vdir="$CU_PARENT/$CU_VERSION"
        else
            log_error "  no version directory could be located above $base"
            continue
        fi
        if [ ! -d "$vdir" ]; then
            log_error "  version directory does not exist: $vdir   (this tool never creates one)"
            continue
        fi

        log_info "  base path      : $base"
        log_info "  version dir    : $vdir"

        for name in $folders; do
            d="$base/$name"
            if [ ! -d "$d" ]; then
                log_warn "  no such folder, skipped: $name"
                CON_WARNINGS=$((CON_WARNINGS + 1)); continue
            fi
            if ! is_table_dir "$d"; then
                log_warn "  no control file beside it, skipped: $name"
                CON_WARNINGS=$((CON_WARNINGS + 1)); continue
            fi
            if is_excluded "$d"; then
                log_info "  explicitly ignored: $name"; continue
            fi
            consolidate_table "$d" "$vdir"; found=1
        done
    done

    if [ "$found" -eq 0 ]; then
        log_warn "  no table folder was consolidated."
    else
        log_info "  tables rebuilt: $CON_REBUILT   removed: $CON_REMOVED   warnings: $CON_WARNINGS"
    fi
    return 0
}
