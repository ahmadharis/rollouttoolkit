#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ddl -- promote delivered schema files into the upgrade version directory and
# maintain the include list there (SPEC.md 7A). HOTFIX ONLY.
#
# A package delivering a table definition into the DDL tree has not finished the
# job: the upgrade reads schema from a VERSION DIRECTORY, through one include
# list. A file that lands in the tree and is never promoted is inert, and the
# upgrade runs without it while reporting success.
#
# Author: Haris Ahmad -- Smart IS
# ---------------------------------------------------------------------------

# Phases, in the order they must run. The numbers ARE the order.
DDL_P_TABLES=1
DDL_P_INDEXES=2
DDL_P_SEQUENCES=3
DDL_P_VIEWS=4
DDL_P_CARRIED=9          # entries the tool did not write and cannot classify

# Tallied by rebuild_ddl_list specifically: how many include lists it wrote
# or removed. Distinct from DDL_PROMOTED, which counts schema files a package
# apply copied in. --rebuild-ddl-list copies nothing, so that counter would
# always read zero there.
DDL_LISTS_REBUILT=0

DDL_PROMOTED=0
DDL_WARNINGS=0
DDL_LIST_NAME="001-ddl_alters.sql"

# The one deliberate hardcoded value in this pass. Reachable only on a
# destination where no version directory has ever carried an include list, so
# there is nothing to derive from (IMPLEMENTATION.md 6A.1).
DDL_FALLBACK_HEADER='#use $DCSDIR/include
#include <dcsddl.h>
#include <dcscolwid.h>
#include <dcstbldef.h>
#include <sqlDataTypes.h>
#include <dcsUpgradeUtils.h>'

# ---------------------------------------------------------------------------
# ddl_arg1 <text-after-open-paren> -> $DDL_ARG
#
# First macro argument: everything up to the first ',' or ')', trimmed.
# ---------------------------------------------------------------------------
ddl_arg1() {
    local v=$1
    v=${v%%)*}
    v=${v%%,*}
    v=${v#"${v%%[![:space:]]*}"}
    v=${v%"${v##*[![:space:]]}"}
    DDL_ARG=$v
}

# ---------------------------------------------------------------------------
# ddl_classify <file> -> $DDL_PHASE, $DDL_TABLE
#
# What the file DOES decides, never what it is called. Extensions in these
# trees are unreliable: an index is routinely named .iesql, and misnamed files
# are checked in.
#
# THE CONSTRAINT TEST OUTRANKS THE ALTER TEST. A constraint file can read
# "alter table <t> add" and then add a CONSTRAINT rather than a column.
# Deciding on the verb puts it in the table phase, where it would run before
# the column it covers exists. Test what is being ADDED.
#
# The catch clause is deliberately ignored: some files name symbolic errors,
# others raw numeric codes, and both forms appear on every operation kind.
# ---------------------------------------------------------------------------
ddl_classify() {
    local f=$1 line
    DDL_PHASE=0; DDL_TABLE=""
    local t_create="" t_index="" t_alter="" t_seq="" t_view=""
    local is_index=0

    [ -f "$f" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        strip_cr "$line"; line=$STRIPPED_CR

        # --- table creation ------------------------------------------------
        case $line in
            *CREATE_TABLE\(*)
                [ -n "$t_create" ] || { ddl_arg1 "${line#*CREATE_TABLE(}"; t_create=$DDL_ARG; } ;;
        esac

        # --- constraint / index: checked BEFORE the column test -------------
        case $line in
            *CREATE_INDEX_BEGIN\(*)
                is_index=1; [ -n "$t_index" ] || { ddl_arg1 "${line#*CREATE_INDEX_BEGIN(}"; t_index=$DDL_ARG; } ;;
            *CREATE_PK_CONSTRAINT_BEGIN\(*)
                is_index=1; [ -n "$t_index" ] || { ddl_arg1 "${line#*CREATE_PK_CONSTRAINT_BEGIN(}"; t_index=$DDL_ARG; } ;;
            *CREATE_PK_PRE\(*)
                is_index=1; [ -n "$t_index" ] || { ddl_arg1 "${line#*CREATE_PK_PRE(}"; t_index=$DDL_ARG; } ;;
            *CREATE_INDEX*|*BEGIN_CONSTRAINT*|*END_CONSTRAINT*)
                is_index=1 ;;
            *[Cc][Oo][Nn][Ss][Tt][Rr][Aa][Ii][Nn][Tt]*)
                is_index=1 ;;
            *[Pp][Rr][Ii][Mm][Aa][Rr][Yy]" "[Kk][Ee][Yy]*)
                is_index=1 ;;
        esac

        # --- column addition -----------------------------------------------
        case $line in
            *ALTER_TABLE_TABLE_INFO\(*)
                [ -n "$t_alter" ] || { ddl_arg1 "${line#*ALTER_TABLE_TABLE_INFO(}"; t_alter=$DDL_ARG; } ;;
            *[Aa][Ll][Tt][Ee][Rr]" "[Tt][Aa][Bb][Ll][Ee]" "*)
                if [ -z "$t_alter" ]; then
                    local rest=${line#*[Aa][Ll][Tt][Ee][Rr] }
                    rest=${rest#*[Tt][Aa][Bb][Ll][Ee] }
                    rest=${rest#"${rest%%[![:space:]]*}"}
                    rest=${rest%%[[:space:]]*}
                    t_alter=$rest
                fi ;;
        esac

        # --- sequences and views -------------------------------------------
        case $line in
            *CREATE_SEQUENCE\(*)
                [ -n "$t_seq" ] || { ddl_arg1 "${line#*CREATE_SEQUENCE(}"; t_seq=$DDL_ARG; } ;;
            *[Cc][Rr][Ee][Aa][Tt][Ee]*[Ss][Ee][Qq][Uu][Ee][Nn][Cc][Ee]*)
                [ -n "$t_seq" ] || t_seq="?" ;;
            *CREATE_VIEW\(*)
                [ -n "$t_view" ] || { ddl_arg1 "${line#*CREATE_VIEW(}"; t_view=$DDL_ARG; } ;;
            *[Cc][Rr][Ee][Aa][Tt][Ee]*[Vv][Ii][Ee][Ww]" "*)
                [ -n "$t_view" ] || t_view="?" ;;
        esac
    done <"$f"

    # Precedence: create table, then constraint/index, then column addition.
    if [ -n "$t_create" ]; then
        DDL_PHASE=$DDL_P_TABLES; DDL_TABLE=$t_create; return 0
    fi
    if [ "$is_index" -eq 1 ]; then
        DDL_PHASE=$DDL_P_INDEXES
        DDL_TABLE=${t_index:-$t_alter}
        return 0
    fi
    if [ -n "$t_alter" ]; then
        DDL_PHASE=$DDL_P_TABLES; DDL_TABLE=$t_alter; return 0
    fi
    if [ -n "$t_seq" ]; then
        DDL_PHASE=$DDL_P_SEQUENCES; DDL_TABLE=$t_seq; return 0
    fi
    if [ -n "$t_view" ]; then
        DDL_PHASE=$DDL_P_VIEWS; DDL_TABLE=$t_view; return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# ddl_phase_from_dir <subdirectory-name> -> $DDL_PHASE  (0 when unrecognised)
#
# The subdirectory a file was picked from. Decisive for the kinds the
# destination files separately, and the fallback when content says nothing.
# ---------------------------------------------------------------------------
ddl_phase_from_dir() {
    case $1 in
        [Tt]able*)    DDL_PHASE=$DDL_P_TABLES ;;
        [Ii]ndex*)    DDL_PHASE=$DDL_P_INDEXES ;;
        [Ss]equence*) DDL_PHASE=$DDL_P_SEQUENCES ;;
        [Vv]iew*)     DDL_PHASE=$DDL_P_VIEWS ;;
        *)            DDL_PHASE=0 ;;
    esac
}

# ---------------------------------------------------------------------------
# derive_ddl_root -> $D_DDL_ROOT
#
# The directory holding the schema subdirectories. Derived, never configured:
# a directory qualifies when it contains at least one subdirectory naming a
# schema kind.
# ---------------------------------------------------------------------------
derive_ddl_root() {
    D_DDL_ROOT=""
    local found cand sub
    found=$(find "$TARGET_DIR" -name .git -prune -o -type d -iname ddl -print 2>/dev/null)
    [ -n "$found" ] || return 1
    split_lines "$found"
    for cand in ${SPLIT[@]+"${SPLIT[@]}"}; do
        [ -n "$cand" ] || continue
        for sub in "$cand"/*/; do
            [ -d "$sub" ] || continue
            sub=${sub%/}; sub=${sub##*/}
            ddl_phase_from_dir "$sub"
            if [ "$DDL_PHASE" -ne 0 ]; then
                if [ -n "$D_DDL_ROOT" ] && [ "$D_DDL_ROOT" != "$cand" ]; then
                    log_warn "derive: a second candidate ddl root was found and ignored: $cand"
                else
                    D_DDL_ROOT=$cand
                fi
                break
            fi
        done
    done
    [ -n "$D_DDL_ROOT" ]
}

# ---------------------------------------------------------------------------
# ddl_list_path <version-dir> -> $DDL_LIST
#
# An existing list keeps whatever name it already has; only a directory with
# none gets the default name. Returns 1 when it had to fall back to a name.
# ---------------------------------------------------------------------------
ddl_list_path() {
    local vdir=$1 f
    DDL_LIST=""
    for f in "$vdir"/*ddl_alters*.sql; do
        [ -f "$f" ] || continue
        DDL_LIST=$f; return 0
    done
    DDL_LIST="$vdir/$DDL_LIST_NAME"
    return 1
}

# ---------------------------------------------------------------------------
# ddl_header <list-path> -> $DDL_HEADER
#
# Everything before the first local include. From this list when it exists,
# else from the most recent version directory that has one, else the tool's own
# known-good block -- the single hardcoded value in this pass, reachable only
# where no list has ever existed (SPEC.md 7A.4).
# ---------------------------------------------------------------------------
ddl_header() {
    local f=$1 line out=""
    DDL_HEADER=""
    if [ -f "$f" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            strip_cr "$line"; line=$STRIPPED_CR
            case $line in
                '#include "'*) break ;;
            esac
            out="$out$line
"
        done <"$f"
        if [ -n "$out" ]; then
            DDL_HEADER=$(printf '%s' "$out" | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}')
            [ -n "$DDL_HEADER" ] && return 0
        fi
    fi

    local vdir cand
    for vdir in $(ls -1 "$D_UPGRADE_PARENT" 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n -r); do
        for cand in "$D_UPGRADE_PARENT/$vdir"/*ddl_alters*.sql; do
            [ -f "$cand" ] || continue
            [ "$cand" = "$f" ] && continue
            ddl_header "$cand"
            [ -n "$DDL_HEADER" ] && return 0
        done
    done

    DDL_HEADER=$DDL_FALLBACK_HEADER
    log_warn "  ddl: no existing include list to take a header from; using the default header"
    DDL_WARNINGS=$((DDL_WARNINGS + 1))
    return 0
}

# ---------------------------------------------------------------------------
# ddl_scan_version <version-dir>
#
# Classify every file in the version directory, building the CURRENT truth:
#   DDL_K[]  the table
#   DDL_F[]  newline-separated "<phase>|<filename>" for that table
#
# Grouping is BY TABLE, not by phase. Everything acting on one table belongs
# together -- its create, its column additions and its index are one group, and
# the blank line separates one TABLE from the next (SPEC.md 7A.3).
#
# Ordering inside a group is by phase, so a column addition still precedes the
# index that may cover it. Across groups the phase does not matter: an index on
# one table cannot depend on a column added to another.
#
# Rebuilt from the directory rather than from what this run copied, because
# post-processing derives from the FINAL state of the tree.
# ---------------------------------------------------------------------------
ddl_scan_version() {
    local vdir=$1 f key i n found
    DDL_K=(); DDL_F=()

    for f in $(ls -1 "$vdir" 2>/dev/null | sort); do
        [ -f "$vdir/$f" ] || continue
        case $f in *ddl_alters*.sql) continue ;; esac
        ddl_classify "$vdir/$f" || continue
        [ -n "$DDL_TABLE" ] || continue
        key=$DDL_TABLE

        found=-1; i=0; n=${#DDL_K[@]}
        while [ "$i" -lt "$n" ]; do
            [ "${DDL_K[$i]}" = "$key" ] && { found=$i; break; }
            i=$((i + 1))
        done
        if [ "$found" -lt 0 ]; then
            DDL_K[$n]=$key
            DDL_F[$n]="$DDL_PHASE|$f"
        else
            DDL_F[$found]="${DDL_F[$found]}
$DDL_PHASE|$f"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# ddl_sort_group <table> <entries> -> $DDL_SORTED  (filenames, newline sep)
#
# Phase first, so creates and alters precede indexes. Within a phase the
# DEFAULT file leads -- the one whose name is the table itself -- and the rest
# follow in name order.
# ---------------------------------------------------------------------------
ddl_sort_group() {
    local table=$1 entries=$2 line phase name rank
    DDL_SORTED=$(
        printf '%s\n' "$entries" | while IFS= read -r line; do
            [ -n "$line" ] || continue
            phase=${line%%|*}
            name=${line#*|}
            rank=1
            [ "${name%%.*}" = "$table" ] && rank=0
            printf '%s %s %s\n' "$phase" "$rank" "$name"
        done | sort -k1,1n -k2,2n -k3,3 | while read -r _p _r name; do
            printf '%s\n' "$name"
        done
    )
}

# ---------------------------------------------------------------------------
# ddl_key_files <key> -> $DDL_KF   (newline separated, "" when absent)
# ---------------------------------------------------------------------------
ddl_key_files() {
    local i=0 n=${#DDL_K[@]}
    DDL_KF=""
    while [ "$i" -lt "$n" ]; do
        if [ "${DDL_K[$i]}" = "$1" ]; then DDL_KF=${DDL_F[$i]}; return 0; fi
        i=$((i + 1))
    done
    return 1
}

# ---------------------------------------------------------------------------
# ddl_write_list <list-path> <header>
#
# Header, then one group per table with a blank line between groups. Entries
# inside a group are phase-ordered; the carried-forward group is emitted last.
# ---------------------------------------------------------------------------
ddl_write_list() {
    local path=$1 header=$2 tmp="$1.tmp$$"
    local i n line

    : >"$tmp" 2>/dev/null || return 1
    printf '%s\n' "$header" >>"$tmp"

    i=0; n=${#DDL_K[@]}
    while [ "$i" -lt "$n" ]; do
        if [ -n "${DDL_F[$i]}" ] && [ "${DDL_K[$i]}" != "carried-forward" ]; then
            ddl_sort_group "${DDL_K[$i]}" "${DDL_F[$i]}"
            printf '\n' >>"$tmp"
            printf '%s\n' "$DDL_SORTED" | while IFS= read -r line; do
                [ -n "$line" ] && printf '#include "%s"\n' "$line" >>"$tmp"
            done
        fi
        i=$((i + 1))
    done

    i=0
    while [ "$i" -lt "$n" ]; do
        if [ "${DDL_K[$i]}" = "carried-forward" ] && [ -n "${DDL_F[$i]}" ]; then
            printf '\n' >>"$tmp"
            printf '%s\n' "${DDL_F[$i]}" | while IFS= read -r line; do
                line=${line#*|}
                [ -n "$line" ] && printf '#include "%s"\n' "$line" >>"$tmp"
            done
        fi
        i=$((i + 1))
    done

    mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# ddl_validate <list-path> <version-dir>
#
# Every entry must name a file in the same directory. A dangling entry is
# REPORTED, never repaired: the file it names is the package's to supply, and
# inventing one would hide a packaging error (SPEC.md 7A.5).
# ---------------------------------------------------------------------------
ddl_validate() {
    local path=$1 vdir=$2 line name missing=0
    [ -f "$path" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        strip_cr "$line"; line=$STRIPPED_CR
        case $line in
            '#include "'*)
                name=${line#*\"}; name=${name%%\"*}
                if [ ! -f "$vdir/$name" ]; then
                    log_warn "  ddl: include names a file that is not in ${vdir##*/}: $name"
                    missing=$((missing + 1))
                fi
                ;;
        esac
    done <"$path"
    if [ "$missing" -gt 0 ]; then
        DDL_WARNINGS=$((DDL_WARNINGS + missing))
        return 1
    fi
    log_info "  ddl: every include resolves to a file in ${vdir##*/}"
    return 0
}

# ---------------------------------------------------------------------------
# ddl_unclassified <list-path> <version-dir> -> $DDL_KEEP
#
# Existing entries whose file is present but whose content names no operation
# this tool recognises. They are carried forward untouched: the tool did not
# write them and has no basis for deciding they are obsolete.
# ---------------------------------------------------------------------------
ddl_unclassified() {
    local path=$1 vdir=$2 line name
    DDL_KEEP=""
    [ -f "$path" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        strip_cr "$line"; line=$STRIPPED_CR
        case $line in
            '#include "'*)
                name=${line#*\"}; name=${name%%\"*}
                [ -f "$vdir/$name" ] || continue
                if ! ddl_classify "$vdir/$name"; then
                    DDL_KEEP="$DDL_KEEP$name
"
                fi
                ;;
        esac
    done <"$path"
    return 0
}

# ---------------------------------------------------------------------------
# promote_ddl -- the pass. HOTFIX ONLY; the caller guards on the type.
#
# Apply: copy every delivered schema file into the highest version directory.
# Undo:  remove the copies this package put there, while they still match.
# Both:  rebuild the include list from what is now in that directory, and
#        validate that every entry resolves.
# ---------------------------------------------------------------------------
promote_ddl() {
    DDL_PROMOTED=0; DDL_WARNINGS=0
    [ -n "$D_UPGRADE_PARENT" ] || return 0
    [ -n "$D_UPGRADE_VERSION" ] || return 0

    local vdir="$D_UPGRADE_PARENT/$D_UPGRADE_VERSION"
    [ -d "$vdir" ] || return 0

    local i=0 dest src base any=0 removed=0
    while [ "$i" -lt "$P_COUNT" ]; do
        dest=${P_DEST[$i]}
        if [ "${P_KIND[$i]}" = "REPLACE" ] && [ -n "$dest" ]; then
            # Recognised from the RESOLVED PATH, not from a derived root. The
            # ddl tree frequently does not exist until this very run creates
            # it -- deriving it in stage 2 found nothing, and the whole pass
            # silently did nothing on a fresh target. Under undo the tree is
            # gone again by the time this runs, so disk cannot be the test
            # either. The path is true in both directions.
            case $dest in
                */[Dd][Dd][Ll]/*)
                    if [ "$any" -eq 0 ]; then log_head "ddl promotion"; any=1; fi
                    base=${dest##*/}
                    src="$PACKAGE_DIR/${P_SOURCE[$i]}"

                    if [ "$UNDO" -eq 1 ]; then
                        if [ -f "$vdir/$base" ]; then
                            # The content guard applies to the PREVIEW too. Undo
                            # reclaims a promoted file only while it still matches
                            # the package's copy, so a dry run that skipped the
                            # comparison announced the removal of a file the real
                            # run then left in place -- the preview and the write
                            # must come from the same test (SPEC.md 10).
                            if ! cmp -s "$src" "$vdir/$base"; then
                                log_warn "  ddl: ${D_UPGRADE_VERSION}/$base changed since it was promoted; left in place"
                                DDL_WARNINGS=$((DDL_WARNINGS + 1))
                            elif [ "$DRY_RUN" -eq 1 ]; then
                                log_info "  ddl: would remove ${D_UPGRADE_VERSION}/$base"
                                removed=$((removed + 1))
                            elif rm -f "$vdir/$base" 2>/dev/null; then
                                log_info "  ddl: removed ${D_UPGRADE_VERSION}/$base"
                                removed=$((removed + 1))
                            else
                                log_error "  ddl: cannot remove ${D_UPGRADE_VERSION}/$base"
                                DDL_WARNINGS=$((DDL_WARNINGS + 1))
                            fi
                        fi
                    else
                        ddl_classify "$src" || log_warn "  ddl: no recognised operation in $base; placed by its directory only"
                        if [ "$DRY_RUN" -eq 1 ]; then
                            log_info "  ddl: would promote $base into $D_UPGRADE_VERSION"
                            DDL_PROMOTED=$((DDL_PROMOTED + 1))
                        elif cp -p "$dest" "$vdir/$base" 2>/dev/null; then
                            log_info "  ddl: promoted $base into $D_UPGRADE_VERSION"
                            DDL_PROMOTED=$((DDL_PROMOTED + 1))
                        else
                            log_error "  ddl: failed to promote $base into $D_UPGRADE_VERSION"
                            DDL_WARNINGS=$((DDL_WARNINGS + 1))
                        fi
                    fi
                    ;;
            esac
        fi
        i=$((i + 1))
    done

    [ "$any" -eq 1 ] || return 0
    [ "$DRY_RUN" -eq 1 ] && return 0

    rebuild_ddl_list "$vdir"
    return 0
}

# ---------------------------------------------------------------------------
# rebuild_ddl_list <version-dir>
#
# The half of DDL promotion that needs no package plan: given a version
# directory, rebuild its include list from whatever schema files are CURRENTLY
# inside it. promote_ddl (apply/undo) reaches this after copying files in;
# rebuild_ddl_run (--rebuild-ddl-list) reaches it directly, with nothing to
# copy, because the files it cares about already live in the version
# directory by the time a manual run has any reason to touch it.
#
# Uses $D_UPGRADE_PARENT purely as a display name and as ddl_header's fallback
# search root (sibling version directories to borrow a header from). The
# caller sets it. promote_ddl already has it from stage 2; rebuild_ddl_run
# sets it itself, since --rebuild-ddl-list derives no destination facts.
# ---------------------------------------------------------------------------
rebuild_ddl_list() {
    local vdir=$1
    local vname=${vdir##*/}

    ddl_list_path "$vdir" || log_info "  ddl: no include list in $vname; creating ${DDL_LIST##*/}"
    ddl_unclassified "$DDL_LIST" "$vdir"
    ddl_header "$DDL_LIST"
    ddl_scan_version "$vdir"

    if [ -n "$DDL_KEEP" ]; then
        local n=${#DDL_K[@]}
        DDL_K[$n]="carried-forward"
        DDL_F[$n]=$(printf '%s' "$DDL_KEEP" | sed "s/^/9|/")
    fi

    # A list with no entries includes nothing, so it has no reason to exist.
    # Leaving a header-only stub behind would look like a configured-but-empty
    # upgrade rather than the absence of one.
    local groups=0 gi=0 gn=${#DDL_K[@]}
    while [ "$gi" -lt "$gn" ]; do
        [ -n "${DDL_F[$gi]}" ] && groups=$((groups + 1))
        gi=$((gi + 1))
    done
    if [ "$groups" -eq 0 ]; then
        if [ -f "$DDL_LIST" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log_info "  ddl: would remove ${DDL_LIST##*/} (no schema left in $vname)"
                DDL_LISTS_REBUILT=$((DDL_LISTS_REBUILT + 1))
            elif rm -f "$DDL_LIST" 2>/dev/null; then
                log_info "  ddl: no schema left in $vname; removed ${DDL_LIST##*/}"
                DDL_LISTS_REBUILT=$((DDL_LISTS_REBUILT + 1))
            else
                log_error "  ddl: could not remove the now-empty ${DDL_LIST##*/}"
                DDL_WARNINGS=$((DDL_WARNINGS + 1))
            fi
        fi
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "  ddl: would rebuild ${DDL_LIST##*/} in $vname"
        DDL_LISTS_REBUILT=$((DDL_LISTS_REBUILT + 1))
        return 0
    fi

    if ddl_write_list "$DDL_LIST" "$DDL_HEADER"; then
        log_info "  ddl: rebuilt ${DDL_LIST##*/} in $vname"
        DDL_LISTS_REBUILT=$((DDL_LISTS_REBUILT + 1))
    else
        log_error "  ddl: could not write ${DDL_LIST##*/}"
        DDL_WARNINGS=$((DDL_WARNINGS + 1))
    fi

    ddl_validate "$DDL_LIST" "$vdir"
    return 0
}

# ---------------------------------------------------------------------------
# rebuild_ddl_run
#
# Manual entry point for --rebuild-ddl-list, the DDL-list counterpart to
# combine_run. Resolves each given base path to a version directory the exact
# same way --combine does (find_upgrade_for, or --target-version to override
# it), then rebuilds that directory's include list. A base path shared with a
# --combine invocation naturally resolves to the same version directory here,
# without either mode needing to know about the other.
# ---------------------------------------------------------------------------
rebuild_ddl_run() {
    local paths base vdir seen=""

    paths=${DDL_PATHS_ARG:-$SET_COMBINE_PATHS}
    [ -n "$paths" ] || die "--rebuild-ddl-list needs a base path, either on the command line or as COMBINE_PATHS in the settings file.
  There is no default: where the upgrade tree lives is not something this tool guesses."

    log_head "manual ddl list rebuild"

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

        case " $seen " in
            *" $vdir "*) continue ;;
        esac
        seen="$seen $vdir"

        log_info "  base path      : $base"
        log_info "  version dir    : $vdir"
        D_UPGRADE_PARENT=$CU_PARENT
        D_UPGRADE_VERSION=${vdir##*/}
        rebuild_ddl_list "$vdir"
    done

    log_info "  ddl lists rebuilt: $DDL_LISTS_REBUILT   warnings: $DDL_WARNINGS"
    return 0
}
