#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# plan -- turn every directive into a resolved action, touching nothing.
#
# Planning is separated from execution on purpose. It is what makes --dry-run a
# true preview rather than a second code path, and it is the ONLY way collision
# detection can work: collisions are visible only once every destination is
# known.
#
# THE PLAN IS THE REPORTING SOURCE. The dry run and the real run print from
# this same structure, so they cannot diverge.
#
# bash 3.2 has no associative arrays, so the plan is parallel indexed arrays
# keyed by position, and collision detection is a sort over the destination
# field rather than a hash lookup.
#
# Author: Haris Ahmad -- Smart IS
# ---------------------------------------------------------------------------

P_MANIFEST=(); P_LINE=(); P_KIND=(); P_SOURCE=(); P_SPEC=()
P_DEST=();     P_BASE=(); P_RULE=(); P_DISP=();   P_PATCH=(); P_NOTE=()
P_COUNT=0

# ---------------------------------------------------------------------------
# effective_spec <spec> <source>
#
# Complete a destination before it is resolved. A destination ending in "/" is
# a directory and the source keeps its own name inside it; otherwise the spec
# is already the full file path.
#
# This runs BEFORE resolution, deliberately. Nearly every real directive uses
# the directory form, and the <patch>/<kind>/<file> shape test needs a file
# component to recognise -- resolving the bare directory made every webclient
# directive fall through to manifest-only placement.
# ---------------------------------------------------------------------------
effective_spec() {
    case $1 in
        */) path_base "$2"; EFF_SPEC="$1$PATH_BASE" ;;
        *)  EFF_SPEC=$1 ;;
    esac
}

# ---------------------------------------------------------------------------
# seed_patch_names
#
# Learn the patches this package carries before resolving anything, so a patch
# the destination has never seen still resolves its entry point and its shared
# files.
#
# Restricted to paths under the refs root. Seeding from the <patch>/<kind>
# shape anywhere was tried and removed: it is circular -- it feeds the very
# heuristic it is meant to constrain -- and it admitted ordinary program-source
# directory segments as patch names.
# ---------------------------------------------------------------------------
seed_patch_names() {
    # A rollout seeds nothing: it recognises no patches, and the guard below
    # would already stand down because no fact was derived. Saying so
    # explicitly keeps the behaviour from depending on that side effect.
    [ "$ROLLOUT_MODE" -eq 0 ] || return 0
    [ -n "$D_REFS_ROOT" ] || return 0
    local m line dest root

    local i=0
    while [ "$i" -lt "${#MANIFESTS[@]}" ]; do
        m=${MANIFESTS[$i]}
        while IFS= read -r line || [ -n "$line" ]; do
            manifest_directive "$line" || continue
            if [ "$MD_KIND" = "REMOVE" ]; then dest=$MD_ARG1; else
                effective_spec "$MD_ARG2" "$MD_ARG1"; dest=$EFF_SPEC
            fi
            split_var "$dest"
            [ -n "$SPEC_VAR" ] || continue
            case $SPEC_VAR in
                REFSDIR) root=${D_REFS_ROOT:-$TARGET_DIR} ;;
                *)       root=$TARGET_DIR ;;
            esac
            normalize_path "$root/$SPEC_REST"
            case $NORMALIZED in
                "$D_REFS_ROOT"/*) ;;
                *) continue ;;
            esac
            find_kind_split "$SPEC_REST" || continue
            list_add D_PATCH_NAMES "$KS_PATCH"
        done <"$m"
        i=$((i + 1))
    done
}

# ---------------------------------------------------------------------------
# plan_add -- record one resolved action.
# ---------------------------------------------------------------------------
plan_add() {
    local n=$P_COUNT
    P_MANIFEST[$n]=$1; P_LINE[$n]=$2; P_KIND[$n]=$3
    P_SOURCE[$n]=$4;   P_SPEC[$n]=$5
    P_DEST[$n]=$6;     P_BASE[$n]=$7; P_RULE[$n]=$8
    P_DISP[$n]=$9;     P_PATCH[$n]=${10}; P_NOTE[$n]=${11}
    P_COUNT=$((n + 1))
}

# ---------------------------------------------------------------------------
# build_plan
#
# Read every manifest and resolve every directive. No filesystem writes.
# ---------------------------------------------------------------------------
build_plan() {
    local m label line no dest src note

    seed_patch_names

    local i=0
    while [ "$i" -lt "${#MANIFESTS[@]}" ]; do
        m=${MANIFESTS[$i]}
        label=${m##*/}
        no=0
        while IFS= read -r line || [ -n "$line" ]; do
            no=$((no + 1))
            manifest_directive "$line" || continue

            note=""
            if [ "$MD_KIND" = "REMOVE" ]; then
                src=""
                dest=$MD_ARG1
            else
                src=$MD_ARG1
                effective_spec "$MD_ARG2" "$MD_ARG1"
                dest=$EFF_SPEC
            fi

            resolve_destination "$dest"

            # A destination that would escape the target is a SETUP error, not
            # a logged failure: it means the package or the settings are wrong
            # about where they are writing.
            if [ -n "$RESOLVED" ] && ! inside_target "$RESOLVED"; then
                die "destination escapes the target directory: $RESOLVED
  from $label line $no: $MD_KIND $dest
  target: $TARGET_DIR"
            fi

            [ "$RESOLVED_RULE" = "$R_RETIRED" ] && note="deploy kind '${RESOLVED_RETIRED%%/*}' is not declared by this destination"

            plan_add "$label" "$no" "$MD_KIND" "$src" "$dest" \
                     "$RESOLVED" "$RESOLVED_BASE" "$RESOLVED_RULE" \
                     "$RESOLVED_DISP" "$RESOLVED_PATCH" "$note"
        done <"$m"
        i=$((i + 1))
    done

    [ "$P_COUNT" -gt 0 ]
}

# ---------------------------------------------------------------------------
# detect_collisions
#
# Two directives resolving to one destination -- two REPLACEs, or a REPLACE and
# a REMOVE -- must never let apply order decide silently. The tool REPORTS a
# collision; it does not pick a winner, because a collision signals a package
# that needs correcting.
#
# A sort over the destination field: one spawn for the whole plan, not a lookup
# per directive.
# ---------------------------------------------------------------------------
COLLISION_COUNT=0
detect_collisions() {
    local i=0 dups dest
    COLLISION_COUNT=0
    [ "$P_COUNT" -gt 0 ] || return 0

    dups=$(
        i=0
        while [ "$i" -lt "$P_COUNT" ]; do
            [ -n "${P_DEST[$i]}" ] && printf '%s\n' "${P_DEST[$i]}"
            i=$((i + 1))
        done | sort | uniq -d
    )
    [ -n "$dups" ] || return 0

    split_lines "$dups"
    for dest in ${SPLIT[@]+"${SPLIT[@]}"}; do
        [ -n "$dest" ] || continue
        COLLISION_COUNT=$((COLLISION_COUNT + 1))
        i=0
        while [ "$i" -lt "$P_COUNT" ]; do
            if [ "${P_DEST[$i]}" = "$dest" ]; then
                P_NOTE[$i]="claimed by another directive"
            fi
            i=$((i + 1))
        done
    done
    return 0
}

# ---------------------------------------------------------------------------
# check_ignored
#
# Everything delivered must be TRACKABLE. A destination the version-control
# system ignores is indistinguishable from one never delivered: the run reports
# success and the repository is silently short (SPEC.md 11).
#
# One batched git call for the whole plan -- never one per directive. When the
# target is not a git working tree, or git is unavailable, the check simply
# does not apply.
# ---------------------------------------------------------------------------
IGNORED_COUNT=0
check_ignored() {
    IGNORED_COUNT=0
    [ "$P_COUNT" -gt 0 ] || return 0
    command -v git >/dev/null 2>&1 || return 0
    git -C "$TARGET_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

    local ignored i=0 dest
    ignored=$(
        i=0
        while [ "$i" -lt "$P_COUNT" ]; do
            [ "${P_DISP[$i]}" = "apply" ] && [ "${P_KIND[$i]}" = "REPLACE" ] \
                && [ -n "${P_DEST[$i]}" ] && printf '%s\n' "${P_DEST[$i]}"
            i=$((i + 1))
        done | sort -u | git -C "$TARGET_DIR" check-ignore --stdin 2>/dev/null
    )
    [ -n "$ignored" ] || return 0

    split_lines "$ignored"
    for dest in ${SPLIT[@]+"${SPLIT[@]}"}; do
        [ -n "$dest" ] || continue
        IGNORED_COUNT=$((IGNORED_COUNT + 1))
        i=0
        while [ "$i" -lt "$P_COUNT" ]; do
            if [ "${P_DEST[$i]}" = "$dest" ]; then
                P_NOTE[$i]="destination is ignored by version control"
            fi
            i=$((i + 1))
        done
    done
    return 0
}

# ---------------------------------------------------------------------------
# will_exist <path>
#
# True when the file is there, OR when this run would put it there.
#
# Stage 5 asks "is this registered file still present?" to decide whether an
# entry is stale. In a real run the answer comes off disk, because execution
# has already happened. In a DRY RUN nothing has been written, so a plain
# [ -f ] test says no for every file the package is about to deliver -- and the
# preview then claims it would strip the entire bundle target. Consulting the
# plan as well keeps one routine answering for both modes, which is the whole
# point of computing the preview from the same logic that writes.
# ---------------------------------------------------------------------------
will_exist() {
    local path=$1 i=0
    [ -f "$path" ] && return 0
    # While undoing, a planned REPLACE is being REVERSED, not carried out --
    # counting it would report a file as present that undo has just removed.
    [ "$UNDO" -eq 1 ] && return 1
    while [ "$i" -lt "$P_COUNT" ]; do
        if [ "${P_DEST[$i]}" = "$path" ] && [ "${P_DISP[$i]}" = "apply" ] \
           && [ "${P_KIND[$i]}" = "REPLACE" ]; then
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}
