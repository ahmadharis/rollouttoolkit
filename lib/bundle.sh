#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bundle -- correct the web application segment in delivered deploy bundles.
#
# A deploy bundle names the scripts it loads by a path whose FIRST segment is
# the web application directory the build deploys assets into:
#
#     scripts:
#       - '<web-app>/les.usr.<patch>.{client-mode}.js'
#
# A package deploys each patch to a directory of its own -- its build file
# declares <web-dir> = <refs>/web/<its own appId> -- so it writes its own patch
# name there. A destination that consolidates several patches into ONE
# application declares a single web directory instead, and every bundle must
# name that one. Copied verbatim, the bundle points at a directory the
# destination never builds, and the scripts never load.
#
# Both sides state the answer in their build file, so nothing is assumed:
#
#     package     ${web.dir}     = ${env.REFSDIR}/web/${appId}   -> <patch>
#     destination ${appWebDir}   = ${env.REFSDIR}/web/app        -> app
#
# The segment is therefore the BASENAME OF THE DIRECTORY THE BUILD FILE COPIES
# ASSETS INTO -- the same expression the copy entries write to, already derived
# as D_COPY_DEST_PROP (derive.sh). Nothing is configured and nothing is fixed.
#
# Substitution happens IN TRANSIT, on the way to the destination, exactly as
# the version override does. THE PACKAGE IS NEVER MODIFIED.
#
# Author: Haris Ahmad -- Smart IS
# ---------------------------------------------------------------------------

BUN_REWRITES=0          # lines rewritten across the run
BUN_FILES=0             # files in which at least one line was rewritten

# ---------------------------------------------------------------------------
# bundle_rewrite_line <line>  -> $BR_LINE, returns 0 when changed
#
# Retarget a script path whose leading segment is a KNOWN PATCH NAME.
#
# That guard is what makes this safe without parsing YAML structure. A bundle
# also carries bundle ids, library names and localization namespaces, none of
# which contain a path separator, and a leading segment that is not a patch
# this destination knows is left alone rather than guessed at.
# ---------------------------------------------------------------------------
bundle_rewrite_line() {
    local line=$1 p
    BR_LINE=$line
    [ -n "$D_WEB_APP" ] || return 1

    # a sequence entry only
    case $line in
        *-[[:space:]]*) ;;
        *) return 1 ;;
    esac

    # Split and rejoin explicitly. ${var//pat/rep} is NOT usable here: bash
    # takes the first slash as the pattern/replacement separator even inside
    # quotes, and every pattern below ends in one -- which silently produced
    # a literal "/$D_WEB_APP/" in the output.
    local lead pre post
    for p in $D_PATCH_NAMES; do
        [ "$p" = "$D_WEB_APP" ] && continue      # already correct
        for lead in "'" '"' '- '; do
            case $line in
                *"$lead$p/"*)
                    pre=${line%%"$lead$p/"*}
                    post=${line#*"$lead$p/"}
                    BR_LINE="$pre$lead$D_WEB_APP/$post"
                    return 0
                    ;;
            esac
        done
    done
    return 1
}

# ---------------------------------------------------------------------------
# bundle_applies <plan-index>
#
# Deploy files only, and only where the destination declares a web application
# to retarget to. HOTFIX ONLY: a rollout corrects nothing, by definition.
#
# The test is deliberately broad -- any delivered file under the deploy tree --
# because the precision lives in bundle_rewrite_line, which changes a line only
# when its leading segment is a patch this destination knows. A bundle that
# already names the right directory passes through untouched.
# ---------------------------------------------------------------------------
bundle_applies() {
    local i=$1
    [ "$ROLLOUT_MODE" -eq 0 ] || return 1
    [ -n "$D_WEB_APP" ] || return 1
    [ -n "$D_DEPLOY_DIR" ] || return 1
    case ${P_DEST[$i]} in
        "$D_DEPLOY_DIR"/*) return 0 ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# same_but_for_web_app <package-file> <target-file>
#
# Undo tolerance. The delivered file differs from the package copy by exactly
# the substitution made on the way in, so byte equality would refuse to remove
# a file this tool itself wrote -- the same problem the version override has,
# and solved the same way: a line may differ only where applying the identical
# rewrite to the package's line reproduces the target's.
#
# The end-of-file handling matches same_but_for_year deliberately. A read
# yields content when it succeeds OR when it fails having filled the variable,
# which is how a final line with no trailing newline arrives; conflating those
# two once let a target with an appended blank line compare equal and an EDITED
# FILE WAS DELETED.
# ---------------------------------------------------------------------------
same_but_for_web_app() {
    local pkg=$1 tgt=$2 pl tl prc trc phas thas ok=0

    [ -n "$D_WEB_APP" ] || return 1

    exec 3<"$pkg" || return 1
    exec 4<"$tgt" || { exec 3<&-; return 1; }

    while :; do
        IFS= read -r pl <&3; prc=$?
        IFS= read -r tl <&4; trc=$?

        phas=0; thas=0
        { [ "$prc" -eq 0 ] || [ -n "$pl" ]; } && phas=1
        { [ "$trc" -eq 0 ] || [ -n "$tl" ]; } && thas=1

        [ "$phas" -eq 0 ] && [ "$thas" -eq 0 ] && { ok=0; break; }   # both ended
        [ "$phas" -ne "$thas" ] && { ok=1; break; }                  # one is longer

        [ "$pl" = "$tl" ] && continue

        # Tolerated only when this run's own substitution explains it.
        if bundle_rewrite_line "$pl" && [ "$BR_LINE" = "$tl" ]; then
            continue
        fi
        ok=1; break
    done

    exec 3<&-; exec 4<&-
    return $ok
}
