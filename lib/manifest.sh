#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# manifest -- find the package's manifests and read their directives.
#
# Only REPLACE and REMOVE are acted on. Every other directive (LOADDATA,
# LOADYAML, MBUILD, REBUILD, RUNSQL, ...), comment and blank line is ignored:
# they are carried out separately and are out of scope (SPEC.md 12).
#
# Author: Haris Ahmad -- Smart IS
# ---------------------------------------------------------------------------

MANIFESTS=()
MANIFEST_SUFFIXES="_LES _REFS"      # order is fixed: bare, then LES, then REFS

# ---------------------------------------------------------------------------
# discover_manifests
#
# A manifest is named after the package directory, optionally suffixed. EVERY
# manifest present is applied, in a stable order, so a package shipping both a
# LES and a REFS manifest has both applied and their results combined.
#
# A package whose manifest cannot be found contributes nothing; that is
# reported rather than run as an empty success (SPEC.md 11).
# ---------------------------------------------------------------------------
discover_manifests() {
    local name suffix candidate
    MANIFESTS=()

    strip_slash "$PACKAGE_DIR"
    name=${STRIPPED##*/}

    # Appended in the fixed order -- bare, then _LES, then _REFS. Built by
    # appending rather than prepending the bare name afterwards: expanding
    # "${MANIFESTS[@]}" while the array is still empty is an UNBOUND VARIABLE
    # under `set -u` in bash 3.2, which is the oldest shell this must run on.
    [ -f "$PACKAGE_DIR/$name" ] && MANIFESTS[${#MANIFESTS[@]}]="$PACKAGE_DIR/$name"
    for suffix in $MANIFEST_SUFFIXES; do
        candidate="$PACKAGE_DIR/$name$suffix"
        [ -f "$candidate" ] && MANIFESTS[${#MANIFESTS[@]}]=$candidate
    done

    [ "${#MANIFESTS[@]}" -gt 0 ]
}

# ---------------------------------------------------------------------------
# manifest_directive <line> -> $MD_KIND, $MD_ARG1, $MD_ARG2
#
# Tokenise one manifest line. Returns 1 for anything that is not a REPLACE or
# a REMOVE.
#
# Hot path -- runs once per manifest line:
#   * keywords match with a case glob, not `tr` (no spawn to fold case)
#   * `set -f; set -- $line; set +f` word-splits without a subshell, a here-doc
#     or a temp file; set -f guards a literal glob character in a path
# ---------------------------------------------------------------------------
manifest_directive() {
    local line=$1
    MD_KIND=""; MD_ARG1=""; MD_ARG2=""

    strip_cr "$line"; line=$STRIPPED_CR
    case $line in
        ""|\#*|[[:space:]]*\#*) return 1 ;;
    esac

    set -f
    set -- $line
    set +f
    [ "$#" -ge 2 ] || return 1

    case $1 in
        [Rr][Ee][Pp][Ll][Aa][Cc][Ee])
            [ "$#" -ge 3 ] || return 1
            MD_KIND="REPLACE"; MD_ARG1=$2; MD_ARG2=$3 ;;
        [Rr][Ee][Mm][Oo][Vv][Ee])
            MD_KIND="REMOVE"; MD_ARG1=$2 ;;
        *) return 1 ;;
    esac
    return 0
}
