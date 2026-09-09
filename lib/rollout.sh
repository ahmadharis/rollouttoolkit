#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# rollout -- destination resolution for TYPE=rollout.
#
# The manifest decides every destination. Nothing is derived, nothing is
# inferred, and no path is corrected: the leading directory variable is
# substituted and the rest of the path is appended verbatim.
#
# This is the tool's ORIGINAL behaviour, restored. It predates the conventions
# in resolve.sh, and it is the default -- because "no settings file" and "no
# conventions" have to mean the same thing (SPEC.md 3).
#
# Called only from resolve_destination, which owns the RESOLVED_* contract and
# is the single point apply, remove and undo all come through. This module adds
# no entry point of its own, and everything it shares with the hotfix type it
# CALLS rather than copies -- a duplicated rule would be free to drift.
#
# Author: Haris Ahmad -- Smart IS
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# resolve_rollout <var> <rest>
#
#   $<REFS>/web/<rest>     ->  <target>/<ROOT>/<WEB>/<rest>
#   $<REFS>/deploy/<rest>  ->  <target>/<ROOT>/<DEPLOY>/<rest>
#   $<REFS>/<rest>         ->  <target>/<ROOT>/<rest>
#   $<any-other>/<rest>    ->  <target>/<rest>
#
# REFSDIR_WEB and REFSDIR_DEPLOY REPLACE the segment that selected them; they
# do not nest beneath it. That is the original meaning of these settings, and
# changing it would silently misplace every file for anyone carrying a settings
# file from the original tool.
#
# Nothing here can return a "skip", "merge" or "report" disposition: a rollout
# delivers everything the manifest names, including the deployed web tree and
# the shared config files.
# ---------------------------------------------------------------------------
resolve_rollout() {
    local var=$1 rest=$2 sub root

    # --- jars (SPEC.md 4.4) ------------------------------------------------
    # A SETTING, not an inferred convention, so it is honoured under both
    # types. The glob is anchored at the start of the path, so this can never
    # claim a jar that lives under a REFS web or deploy subtree.
    if try_jar_redirect "$rest"; then
        return 0
    fi

    # --- every variable but REFS maps to the target ------------------------
    # The REFS variable is the ONLY name-specific branch, exactly as under
    # hotfix. LES-side content is therefore never relocated.
    if [ "$var" != "REFSDIR" ]; then
        resolve_manifest "$TARGET_DIR" "$rest"
        return 0
    fi

    refs_root
    case $rest in
        web/*)
            refs_web
            sub=$REFS_WEB; rest=${rest#web/}
            RESOLVED_RULE=$R_REFS_WEB
            ;;
        deploy/*)
            refs_deploy
            sub=$REFS_DEPLOY; rest=${rest#deploy/}
            RESOLVED_RULE=$R_REFS_DEPLOY
            ;;
        *)
            sub=""
            RESOLVED_RULE=$R_REFS_ROOT
            ;;
    esac

    # An absolute root is honoured, as JAR_DIR's is. One that leaves the target
    # is caught by the escape check before the run starts.
    if is_abs "$REFS_ROOT"; then
        root="$REFS_ROOT${sub:+/$sub}"
    else
        root="$TARGET_DIR/$REFS_ROOT${sub:+/$sub}"
    fi
    normalize_path "$root"; root=$NORMALIZED

    # <root> doubles as the pruning floor, so an empty directory left by a
    # REMOVE is cleaned up no further than the configured subtree.
    resolve_manifest "$root" "$rest"
    return 0
}
