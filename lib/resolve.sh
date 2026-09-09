#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# resolve -- map one manifest path onto the destination tree.
#
# THE single resolution point. Apply, remove and undo all come through here, so
# they cannot disagree about where a file lives.
#
# Results come back in globals rather than through $(...), which would fork a
# subshell for every directive:
#
#   RESOLVED       absolute destination, or "" when there is none
#   RESOLVED_BASE  pruning floor -- never delete this directory or above it
#   RESOLVED_RULE  which rule decided it (the log's "why")
#   RESOLVED_DISP  apply | skip | merge | report
#   RESOLVED_PATCH the patch this file belongs to, when it belongs to one
#
# Author: Haris Ahmad -- Smart IS
# ---------------------------------------------------------------------------

# Rule tags. "manifest" is the one that matters most in a dry run: it means the
# destination declared no standard for this file, so the package decided.
R_MANIFEST="manifest"           # placed exactly as the manifest said
R_PATCH_SRC="patch-source"      # webclient patch source -> declared source tree
R_DEPLOY="deploy-unwrap"        # deployed shape -> source shape, wrapper removed
R_JAR="jar-redirect"            # generic library jar -> JAR_DIR
R_SHARED="shared-file"          # patch config / build file -> merged, not copied
R_WEB="deployed-web"            # build output -> skipped
R_RETIRED="retired-kind"        # a deploy kind the destination no longer has

# Rollout-type tags. The REFS variable is the only one that is name-specific,
# exactly as under hotfix -- every other variable maps to the target.
R_REFS_WEB="refs-web"           # $REFS/web    -> REFSDIR_ROOT + REFSDIR_WEB
R_REFS_DEPLOY="refs-deploy"     # $REFS/deploy -> REFSDIR_ROOT + REFSDIR_DEPLOY
R_REFS_ROOT="refs-root"         # $REFS/<rest> -> REFSDIR_ROOT

# ---------------------------------------------------------------------------
# split_var <spec> -> $SPEC_VAR, $SPEC_REST
#
# "$LESDIR/db/ddl/x.tbl" -> SPEC_VAR=LESDIR  SPEC_REST=db/ddl/x.tbl
# A spec with no leading variable yields an empty SPEC_VAR.
# ---------------------------------------------------------------------------
split_var() {
    SPEC_VAR=""; SPEC_REST=$1
    case $1 in
        \$*)
            SPEC_VAR=${1#\$}
            case $SPEC_VAR in
                \{*) SPEC_VAR=${SPEC_VAR#\{}; SPEC_VAR=${SPEC_VAR%%\}*}
                     SPEC_REST=${1#*\}} ;;
                */*) SPEC_REST=${SPEC_VAR#*/}; SPEC_VAR=${SPEC_VAR%%/*} ;;
                *)   SPEC_REST="" ;;
            esac
            SPEC_REST=${SPEC_REST#/}
            ;;
    esac
}

# ---------------------------------------------------------------------------
# find_kind_split <relative-path> -> $KS_PATCH, $KS_KIND, $KS_REST
#
# Locate a "<patch>/<kind>/<rest>" shape, where <kind> names an asset kind or a
# source kind. Patch identity therefore comes from the SHAPE of the path, never
# from a list of application names -- so a directory at that level that is not
# a patch is never mistaken for one.
#
# Scans left to right and takes the FIRST recognised kind, so a file whose own
# name matches a kind cannot shift the split.
# ---------------------------------------------------------------------------
find_kind_split() {
    local path=$1 before="" seg rest=$1
    KS_PATCH=""; KS_KIND=""; KS_REST=""

    while :; do
        case $rest in
            */*) seg=${rest%%/*}; rest=${rest#*/} ;;
            *) return 1 ;;
        esac
        if [ -n "$before" ] \
           && { list_has "$D_ASSET_KINDS" "$seg" || list_has "$D_SOURCE_KINDS" "$seg"; } \
           && [ -n "$rest" ]; then
            KS_PATCH=${before##*/}
            KS_KIND=$seg
            KS_REST=$rest
            return 0
        fi
        before="${before:+$before/}$seg"
    done
}

# ---------------------------------------------------------------------------
# deploy_unwrap <relative-path-after-deploy> -> $DU_REST
#
# Strip the deployed-shape wrapper: whatever lies between the deploy directory
# and the first segment naming a valid deploy kind.
#
#   app/db/load/bundles/x.yaml  ->  bundles/x.yaml
#
# The wrapper is DERIVED per path, not configured, so a package that carries a
# different one still resolves. Returns 1 when no valid kind appears, which is
# how a retired kind is detected (SPEC.md 4.7).
# ---------------------------------------------------------------------------
deploy_unwrap() {
    local rest=$1 seg
    DU_REST=""; DU_WRAPPER=""
    while :; do
        case $rest in
            */*) seg=${rest%%/*} ;;
            *) return 1 ;;
        esac
        if list_has "$D_DEPLOY_KINDS" "$seg"; then
            DU_REST=$rest
            return 0
        fi
        DU_WRAPPER="${DU_WRAPPER:+$DU_WRAPPER/}$seg"
        rest=${rest#*/}
    done
}

# ---------------------------------------------------------------------------
# is_shared_file <basename> <patch>
#
# True when a patch-root file is a CONFIG rather than a source. These are never
# copied: they are an INPUT to registration, not the authority (SPEC.md 6.3).
# Several packages may target the same shared file, and copying would let a
# later one discard an earlier one's entries.
#
# Every .xml at a patch root qualifies -- the build file, the per-patch config
# the build file names, and any other xml the platform puts there. Everything
# else at the patch root is a source file (typically the entry point, but a
# patch may put more than one there) and is copied into the patch source tree.
#
# SHARED_KNOWN records whether this is a config the destination recognises, so
# an xml that is neither can be reported rather than silently not copied.
# ---------------------------------------------------------------------------
is_shared_file() {
    SHARED_KNOWN=0
    case $1 in
        build.xml) SHARED_KNOWN=1; return 0 ;;
        "$2".xml)  SHARED_KNOWN=1; return 0 ;;
        *.xml)     return 0 ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# resolve_reset -- clear the RESOLVED_* globals before a resolution.
#
# Shared by both types so neither can forget a field and inherit the previous
# directive's answer.
# ---------------------------------------------------------------------------
resolve_reset() {
    RESOLVED=""; RESOLVED_BASE=""; RESOLVED_RULE=$R_MANIFEST
    RESOLVED_DISP="apply"; RESOLVED_PATCH=""; RESOLVED_RETIRED=""
    RESOLVED_NOTE=""
}

# ---------------------------------------------------------------------------
# try_jar_redirect <rest>  ->  0 resolved / 1 not a jar to redirect
#
# A jar the manifest names in the GENERIC library directory follows JAR_DIR.
# Paths already naming the java library directory are never redirected, and a
# non-jar in the generic directory is left alone.
#
# Shared by BOTH types: JAR_DIR is a SETTING, not a convention inferred from
# the target, so there is nothing for a verbatim rollout to decline to infer.
# The glob is anchored at the start of the path, so it can never claim a jar
# sitting under a REFS subtree.
# ---------------------------------------------------------------------------
try_jar_redirect() {
    [ -n "$SET_JAR_DIR" ] || return 1
    case $1 in
        lib/*.jar) ;;
        *) return 1 ;;
    esac

    path_base "$1"
    if is_abs "$SET_JAR_DIR"; then
        RESOLVED="$SET_JAR_DIR/$PATH_BASE"; RESOLVED_BASE=$SET_JAR_DIR
    else
        RESOLVED="$TARGET_DIR/$SET_JAR_DIR/$PATH_BASE"; RESOLVED_BASE="$TARGET_DIR/$SET_JAR_DIR"
    fi
    RESOLVED_RULE=$R_JAR
    normalize_path "$RESOLVED";      RESOLVED=$NORMALIZED
    normalize_path "$RESOLVED_BASE"; RESOLVED_BASE=$NORMALIZED
    return 0
}

# ---------------------------------------------------------------------------
# resolve_manifest <root> <rest>  -- the manifest path stands.
#
# The last rule of both types, and the ONLY rule of a rollout that names no
# REFS variable. <root> doubles as the pruning floor.
# ---------------------------------------------------------------------------
resolve_manifest() {
    normalize_path "$1/$2"
    RESOLVED=$NORMALIZED
    RESOLVED_BASE=$1
    return 0
}

# ---------------------------------------------------------------------------
# resolve_destination <manifest-spec>
#
# THE single resolution point. Apply, remove and undo all come through here, so
# they cannot disagree about where a file lives -- whichever type is active.
#
# The type is tested in exactly one place: here. Both resolvers write the same
# RESOLVED_* globals, so everything downstream of this call is type-blind.
# ---------------------------------------------------------------------------
resolve_destination() {
    resolve_reset

    split_var "$1"

    # --- a literal path passes through untouched, and disables pruning ------
    # Shared: a path with no leading variable means the same thing under both
    # types, and an empty base tells prune_empty_dirs to leave the tree alone.
    if [ -z "$SPEC_VAR" ]; then
        normalize_path "$1"
        RESOLVED=$NORMALIZED
        RESOLVED_BASE=""
        return 0
    fi

    if [ "$ROLLOUT_MODE" -eq 1 ]; then
        resolve_rollout "$SPEC_VAR" "$SPEC_REST"
    else
        resolve_hotfix "$SPEC_VAR" "$SPEC_REST"
    fi
}

# ---------------------------------------------------------------------------
# resolve_hotfix <var> <rest>
#
# Decision order, first match wins (SPEC.md 9.1):
#   1. the deployed web tree            -> skip
#   2. a convention override applies    -> the declared location
#   3. otherwise                        -> the manifest path stands
# ---------------------------------------------------------------------------
resolve_hotfix() {
    local var=$1 rest=$2 root base

    # --- 1. the deployed web tree (SPEC.md 5) ------------------------------
    # Decided from the manifest alone. $REFSDIR is a virtual root whose web
    # subtree has no single real path, and nothing is written there anyway.
    if [ -n "$D_WEB_SEG" ]; then
        case $rest in
            "$D_WEB_SEG"/*)
                RESOLVED=""
                RESOLVED_RULE=$R_WEB
                RESOLVED_DISP="skip"
                return 0
                ;;
        esac
    fi

    # --- the root this variable maps to ------------------------------------
    # Every variable maps to the target directory. The ONLY name-specific
    # branch is REFSDIR, and only when a refs root was actually derived.
    case $var in
        REFSDIR) root=${D_REFS_ROOT:-$TARGET_DIR} ;;
        *)       root=$TARGET_DIR ;;
    esac
    base=$root

    # --- 2a. deploy artifacts: deployed shape -> source shape --------------
    if [ "$var" = "REFSDIR" ] && [ -n "$D_REFS_ROOT" ]; then
        case $rest in
            deploy/*)
                if deploy_unwrap "${rest#deploy/}"; then
                    if [ -n "$DU_WRAPPER" ]; then
                        rest="deploy/$DU_REST"
                        RESOLVED_RULE=$R_DEPLOY
                    fi
                else
                    # No valid kind: the destination no longer has this kind.
                    # Nothing is copied -- the content is assembled into the
                    # surviving kind instead (SPEC.md 4.7), so leaving a
                    # destination here would invite writing the obsolete tree
                    # this tool exists to prevent.
                    RESOLVED=""
                    RESOLVED_RULE=$R_RETIRED
                    RESOLVED_DISP="report"
                    RESOLVED_RETIRED=${rest#deploy/}
                    return 0
                fi
                ;;
        esac
    fi

    # --- 2b. webclient patch sources ---------------------------------------
    # Under the refs root ONLY. A "known patch name anywhere" escape clause was
    # tried and removed: source kinds carry generic words such as "util" and
    # "view", so an unrelated program-source directory ending in one of them
    # matched the <patch>/<kind> shape and its files were redirected into the
    # patch tree. Patch sources live under the refs tree by definition, so the
    # containment test is both sufficient and safe.
    local abs under_refs=0
    if [ -n "$D_REFS_ROOT" ]; then
        normalize_path "$root/$rest"; abs=$NORMALIZED
        case $abs in
            "$D_REFS_ROOT"/*) under_refs=1 ;;
        esac
    fi

    if [ "$RESOLVED_RULE" = "$R_MANIFEST" ] && [ -n "$D_PATCH_SRC" ] \
       && [ "$under_refs" -eq 1 ] && find_kind_split "$rest"; then
        case $abs in
            "$D_PATCH_SRC"/*) ;;                      # already in source shape
            *)
                RESOLVED="$D_PATCH_SRC/$KS_PATCH/$KS_KIND/$KS_REST"
                RESOLVED_BASE=$D_PATCH_SRC
                RESOLVED_RULE=$R_PATCH_SRC
                RESOLVED_PATCH=$KS_PATCH
                normalize_path "$RESOLVED"; RESOLVED=$NORMALIZED
                return 0
                ;;
        esac
    fi

    # --- 2b-ii. patch-root files: the entry point and the shared files -----
    # A file sitting directly in a patch directory carries no <kind>, so it is
    # placed by the patch's identity instead. The patch set comes from what the
    # destination already declares plus what this package's own kind-carrying
    # directives established (the planner seeds it before resolving), so a
    # patch the target has never seen still resolves.
    if [ "$RESOLVED_RULE" = "$R_MANIFEST" ] && [ -n "$D_PATCH_SRC" ]; then
        case $rest in
            */*)
                local pbase=${rest##*/}
                local pdir=${rest%/*}
                local pname=${pdir##*/}
                if [ "$under_refs" -eq 1 ] && list_has "$D_PATCH_NAMES" "$pname"; then
                    if is_shared_file "$pbase" "$pname"; then
                        RESOLVED=""
                        RESOLVED_RULE=$R_SHARED
                        RESOLVED_DISP="merge"
                        RESOLVED_PATCH=$pname
                        [ "$SHARED_KNOWN" -eq 1 ] || \
                            RESOLVED_NOTE="patch-root xml is neither the build file nor the declared patch config"
                        return 0
                    fi
                    case $abs in
                        "$D_PATCH_SRC"/*) ;;          # already in source shape
                        *)
                            RESOLVED="$D_PATCH_SRC/$pname/$pbase"
                            RESOLVED_BASE=$D_PATCH_SRC
                            RESOLVED_RULE=$R_PATCH_SRC
                            RESOLVED_PATCH=$pname
                            normalize_path "$RESOLVED"; RESOLVED=$NORMALIZED
                            return 0
                            ;;
                    esac
                fi
                ;;
        esac
    fi

    # --- 2c. jars (SPEC.md 4.4) --------------------------------------------
    if [ "$RESOLVED_RULE" = "$R_MANIFEST" ] && try_jar_redirect "$rest"; then
        return 0
    fi

    # --- 3. the manifest path stands ---------------------------------------
    resolve_manifest "$base" "$rest"
    return 0
}

# ---------------------------------------------------------------------------
# inside_target <path>
#
# A resolved destination must stay inside the target directory. One that would
# escape it is a SETUP error, rejected before the run starts -- not logged and
# continued, because it means the package or the settings are wrong about where
# they are writing.
# ---------------------------------------------------------------------------
inside_target() {
    case $1 in
        "$TARGET_DIR") return 0 ;;
        "$TARGET_DIR"/*) return 0 ;;
        *) return 1 ;;
    esac
}
