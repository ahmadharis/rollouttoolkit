#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# version -- the --version override, and undo's tolerance of it.
#
# A package may carry a platform version stamped into its resource-bundle
# declarations. Where the same package content is valid for more than one
# platform version, that stamp is the only thing that differs.
#
# The rule is a SHAPE, not a name: rewrite the leading component of a version
# value, and ONLY when that leading component is a four-digit year. Everything
# after the first separator is preserved. No library, filename or path is
# hardcoded, so it applies to any package with a year-versioned dependency.
#
#     version: <year>.1.MAX.MAX   override 2024  ->  version: 2024.1.MAX.MAX
#     version: 9.3.1              override 2024  ->  unchanged, 9 is not a year
#     version: '1.0'              override 2024  ->  unchanged, 1 is not a year
#
# The match is line-oriented on the version value, because the surrounding
# declaration is formatted inconsistently between packages -- indentation
# differs and the neighbouring name may or may not be quoted. Structural
# parsing would be brittle where a line match is not.
#
# THE PACKAGE IS NEVER MODIFIED. Substitution happens in transit, on the way to
# the destination.
#
# Author: Haris Ahmad -- Smart IS
# ---------------------------------------------------------------------------

VER_REWRITES=0          # how many values this run rewrote
VER_FILES=0             # in how many files

# ---------------------------------------------------------------------------
# is_year <string>  -- exactly four digits
# ---------------------------------------------------------------------------
is_year() {
    case $1 in
        [0-9][0-9][0-9][0-9]) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# version_rewrite_line <line> <new-year> -> $VR_LINE, returns 0 when changed
#
# Rewrites   <anything>version:<ws><year><sep><rest>   keeping <anything>, the
# whitespace, the separator and the rest exactly as they were. A quoted value
# keeps its quote, which is why the quote is stripped and restored rather than
# matched around.
# ---------------------------------------------------------------------------
version_rewrite_line() {
    local line=$1 year=$2 head val q="" rest lead
    VR_LINE=$line

    case $line in
        *version:*) ;;
        *) return 1 ;;
    esac

    head=${line%%version:*}
    val=${line#*version:}

    # keep the whitespace between the colon and the value
    local ws=${val%%[![:space:]]*}
    val=${val#"$ws"}
    [ -n "$val" ] || return 1

    case $val in
        \'*) q="'"; val=${val#\'} ;;
        \"*) q='"'; val=${val#\"} ;;
    esac

    case $val in
        *.*) lead=${val%%.*}; rest=${val#*.} ;;
        *) return 1 ;;
    esac

    is_year "$lead" || return 1
    [ "$lead" = "$year" ] && return 1          # already that year: not a change

    VR_LINE="${head}version:${ws}${q}${year}.${rest}"
    return 0
}

# ---------------------------------------------------------------------------
# copy_with_transforms <src> <dest> <plan-index>
#
# Copy a file line by line, through every IN-TRANSIT correction that applies to
# it. The package is never written to; the substitution happens on the way out.
#
# One loop, not one per correction. A second copy routine would have to repeat
# the temp-file handling, the failure path and the counters, and the two would
# be free to drift -- and a file needing BOTH corrections would have to be
# written twice.
# ---------------------------------------------------------------------------
copy_with_transforms() {
    local src=$1 dest=$2 i=$3 line tmp="$2.tmp$$"
    local do_ver=0 do_bun=0 vchanged=0 bchanged=0

    version_applies "$i" && do_ver=1
    bundle_applies  "$i" && do_bun=1

    # A file whose last line carries NO trailing newline must come out the same
    # way. Writing every line with a trailing newline silently appended one --
    # harmless while only the version override used this path, but it made the
    # copy lossy for every deploy file once a second transform shared it, and a
    # one-byte difference is enough to defeat undo's byte comparison.
    local rc
    : >"$tmp" 2>/dev/null || return 1
    while :; do
        IFS= read -r line; rc=$?
        [ "$rc" -eq 0 ] || [ -n "$line" ] || break

        if [ "$do_ver" -eq 1 ] && version_rewrite_line "$line" "$VERSION_OVERRIDE"; then
            line=$VR_LINE; vchanged=$((vchanged + 1))
        fi
        if [ "$do_bun" -eq 1 ] && bundle_rewrite_line "$line"; then
            line=$BR_LINE; bchanged=$((bchanged + 1))
        fi

        if [ "$rc" -eq 0 ]; then
            printf '%s\n' "$line" >>"$tmp"
        else
            printf '%s' "$line" >>"$tmp"      # final line, no trailing newline
            break
        fi
    done <"$src"

    if ! mv -f "$tmp" "$dest" 2>/dev/null; then rm -f "$tmp"; return 1; fi

    if [ "$vchanged" -gt 0 ]; then
        VER_REWRITES=$((VER_REWRITES + vchanged))
        VER_FILES=$((VER_FILES + 1))
        log_info "  version: rewrote $vchanged value(s) to $VERSION_OVERRIDE in ${dest##*/}"
    fi
    if [ "$bchanged" -gt 0 ]; then
        BUN_REWRITES=$((BUN_REWRITES + bchanged))
        BUN_FILES=$((BUN_FILES + 1))
        log_info "  bundle: retargeted $bchanged script path(s) to '$D_WEB_APP' in ${dest##*/}"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# version_applies <plan-index>
#
# Scope: bundle declarations on the REFS side only. Bundles are a deploy kind,
# and deploy artifacts are REFS-side by definition -- no LES-side package
# carries them. Recognised by the resolved destination lying under the deploy
# tree, which is derived, so no filename or path is hardcoded.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# set_version_scope
#
# Fix the root of the override's scope ONCE, in stage 1, for both types.
#
# Binding the test to the derived deploy directory instead would make
# --version silently match nothing under rollout, where nothing is derived --
# and report_version would then blame the package for what is really a
# setting. One global, set in one place, keeps the two types from drifting.
# ---------------------------------------------------------------------------
set_version_scope() {
    if [ "$ROLLOUT_MODE" -eq 1 ]; then
        refs_root; refs_deploy
        if is_abs "$REFS_ROOT"; then
            VERSION_SCOPE_DIR="$REFS_ROOT/$REFS_DEPLOY"
        else
            VERSION_SCOPE_DIR="$TARGET_DIR/$REFS_ROOT/$REFS_DEPLOY"
        fi
        normalize_path "$VERSION_SCOPE_DIR"; VERSION_SCOPE_DIR=$NORMALIZED
    else
        VERSION_SCOPE_DIR=$D_DEPLOY_DIR
    fi
    return 0
}

# ---------------------------------------------------------------------------
# version_scope <plan-index>
#
# True when the resolved destination lies under the scope root, AT ANY DEPTH.
# A case glob is not path-aware -- its '*' spans '/' -- so a bundle sitting
# directly beneath the deploy tree and one nested many directories below it
# both match, while a prefix-sibling such as "deployX/" does not.
#
# The test is on the RESOLVED DESTINATION, never on the manifest path, so it
# follows the file to wherever this run is actually placing it. No depth,
# wrapper shape or filename is assumed anywhere.
# ---------------------------------------------------------------------------
version_scope() {
    local i=$1
    [ -n "$VERSION_SCOPE_DIR" ] || return 1
    case ${P_DEST[$i]} in
        "$VERSION_SCOPE_DIR"/*) return 0 ;;
    esac
    return 1
}

version_applies() {
    local i=$1
    [ -n "$VERSION_OVERRIDE" ] || return 1
    [ "${P_KIND[$i]}" = "REPLACE" ] || return 1
    version_scope "$i"
}

# ---------------------------------------------------------------------------
# report_version -- a version supplied but matching nothing is REPORTED.
# Asking for a year that is not present usually means the wrong package.
# ---------------------------------------------------------------------------
report_version() {
    [ -n "$VERSION_OVERRIDE" ] || return 0
    if [ "$VER_REWRITES" -eq 0 ]; then
        # The scope root is named because it is now a possible CAUSE. Under
        # rollout it comes from REFSDIR_ROOT and REFSDIR_DEPLOY, so a package
        # can be blameless and the settings simply pointed elsewhere.
        log_warn "version override $VERSION_OVERRIDE matched nothing in this package -- no version value under the deploy tree has a four-digit year leading component. This usually means the wrong package, or a deploy tree that is not where the run looked."
        log_warn "  searched: ${VERSION_SCOPE_DIR:-<no deploy tree located>}"
    else
        if [ "$DRY_RUN" -eq 1 ]; then
            log_info "version override: would rewrite $VER_REWRITES value(s) across $VER_FILES file(s) to $VERSION_OVERRIDE"
        else
            log_info "version override: rewrote $VER_REWRITES value(s) across $VER_FILES file(s) to $VERSION_OVERRIDE"
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# preview_version <src> <year>
#
# A dry run creates nothing but must still report WHICH version values would be
# rewritten. This is the same line test the real copy uses, so the preview and
# the write cannot drift.
# ---------------------------------------------------------------------------
preview_version() {
    local src=$1 year=$2 line changed=0
    [ -f "$src" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        version_rewrite_line "$line" "$year" && changed=$((changed + 1))
    done <"$src"
    [ "$changed" -gt 0 ] || return 1
    VER_REWRITES=$((VER_REWRITES + changed))
    VER_FILES=$((VER_FILES + 1))
    log_info "  version: would rewrite $changed value(s) to $year in ${src##*/}"
    return 0
}

# ---------------------------------------------------------------------------
# same_but_for_year <package-file> <target-file>
#
# Undo removes a file only while it still matches the package's copy. A file
# delivered with a rewritten version does not match the package as stored, so
# the comparison treats a difference CONFINED TO the leading four-digit year of
# a version value as a match. Any other difference leaves the file in place.
#
# This is what makes undo independent of the override: a package applied with a
# version stamp is fully reversed by an undo that was never told which stamp
# was used. The alternative -- substituting the version into the package's copy
# before comparing -- was rejected, because an undo run without the flag would
# then find a mismatch on every delivered bundle file and silently refuse to
# remove them.
#
# Byte equality is tried first, by the caller. This is the second pass.
# ---------------------------------------------------------------------------
same_but_for_year() {
    local pkg=$1 tgt=$2 pl tl prc trc phas thas pv ok=0

    exec 3<"$pkg" || return 1
    exec 4<"$tgt" || { exec 3<&-; return 1; }

    while :; do
        IFS= read -r pl <&3; prc=$?
        IFS= read -r tl <&4; trc=$?

        # A read yields content when it succeeds, OR when it fails but filled
        # the variable -- which is how a final line with no trailing newline
        # arrives. Conflating those two was a bug: a blank line appended to the
        # target compared equal to the package's end-of-file and an EDITED FILE
        # WAS DELETED, defeating the one guard that stops undo clobbering a
        # later rollout's work.
        phas=0; thas=0
        { [ "$prc" -eq 0 ] || [ -n "$pl" ]; } && phas=1
        { [ "$trc" -eq 0 ] || [ -n "$tl" ]; } && thas=1

        [ "$phas" -eq 0 ] && [ "$thas" -eq 0 ] && { ok=0; break; }   # both ended
        [ "$phas" -ne "$thas" ] && { ok=1; break; }                  # one is longer

        [ "$pl" = "$tl" ] && continue

        # They differ. Tolerated only when both are version values whose
        # leading component is a four-digit year and the rest is identical.
        version_year_strip "$pl" || { ok=1; break; }
        pv=$VY_LINE
        version_year_strip "$tl" || { ok=1; break; }
        [ "$pv" = "$VY_LINE" ] || { ok=1; break; }
    done

    exec 3<&- 4<&-
    return $ok
}

# version_year_strip <line> -> $VY_LINE with a year-leading version value's
# year replaced by a placeholder; returns 1 when the line is not one.
version_year_strip() {
    local line=$1 head val ws q="" lead rest
    VY_LINE=""
    case $line in *version:*) ;; *) return 1 ;; esac
    head=${line%%version:*}
    val=${line#*version:}
    ws=${val%%[![:space:]]*}
    val=${val#"$ws"}
    case $val in
        \'*) q="'"; val=${val#\'} ;;
        \"*) q='"'; val=${val#\"} ;;
    esac
    case $val in *.*) lead=${val%%.*}; rest=${val#*.} ;; *) return 1 ;; esac
    is_year "$lead" || return 1
    VY_LINE="${head}version:${ws}${q}YYYY.${rest}"
    return 0
}
