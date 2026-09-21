#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# report -- per-manifest tallies, the exceptions summary, and the exit status.
#
# The exceptions summary is A FILTER OVER THE PLAN plus the execution outcomes,
# not a second set of bookkeeping. The plan already records each action's
# disposition and the rule that decided it; no handler collects anything
# specially for this.
#
# Author: Haris Ahmad -- Smart IS
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# check_web_skips  (SPEC.md 5.1)
#
# Skipping the deployed web tree must not hide a packaging error. For each
# skipped file:
#
#   the name matches a declared bundle target -> expected build output, silent
#   a source-shape counterpart exists         -> expected duplicate, silent
#   neither                                   -> NOTIFY
#
# The third case means an asset would be LOST: delivered to the deployed tree
# with no source anywhere. The tool reports it rather than compensating,
# because the fix belongs in the package -- ship the file in source shape.
# ---------------------------------------------------------------------------
WEB_NOSOURCE=0
check_web_skips() {
    local i=0 spec base patch rest t f found

    while [ "$i" -lt "$P_COUNT" ]; do
        [ "${P_RULE[$i]}" = "$R_WEB" ] || { i=$((i + 1)); continue; }

        spec=${P_SPEC[$i]}
        base=${spec##*/}

        # build output? the bundle target's name leads the filename
        found=0
        for t in $D_BUNDLE_TARGETS; do
            case $base in "$t".*) found=1; break ;; esac
        done
        if [ "$found" -eq 1 ]; then i=$((i + 1)); continue; fi

        # a source-shape counterpart in the target?
        split_var "$spec"
        rest=${SPEC_REST#"$D_WEB_SEG"/}
        patch=${rest%%/*}
        if [ -n "$D_PATCH_SRC" ] && [ -n "$patch" ]; then
            for f in "$D_PATCH_SRC/$patch/$base" "$D_PATCH_SRC/$patch"/*/"$base"; do
                if [ -f "$f" ]; then found=1; break; fi
            done
        fi
        if [ "$found" -eq 1 ]; then i=$((i + 1)); continue; fi

        P_NOTE[$i]="no source counterpart"
        WEB_NOSOURCE=$((WEB_NOSOURCE + 1))
        i=$((i + 1))
    done
    return 0
}

# ---------------------------------------------------------------------------
# report_plan
#
# Every directive resolved by the manifest ALONE is the signal that a package
# may not be converted for this destination -- and the main reason to read a
# dry run. It is called out explicitly rather than left to be inferred.
# ---------------------------------------------------------------------------
report_plan() {
    local i=0 by_manifest="" m
    log_head "plan"
    log_info "actions planned  : $P_COUNT"

    local n_manifest=0 n_conv=0 n_skip=0 n_merge=0 n_report=0
    while [ "$i" -lt "$P_COUNT" ]; do
        case ${P_DISP[$i]} in
            skip)   n_skip=$((n_skip + 1)) ;;
            merge)  n_merge=$((n_merge + 1)) ;;
            report) n_report=$((n_report + 1)) ;;
            *) if [ "${P_RULE[$i]}" = "$R_MANIFEST" ]; then n_manifest=$((n_manifest + 1))
               else n_conv=$((n_conv + 1)); fi ;;
        esac
        i=$((i + 1))
    done

    # A rollout has no conventions to report, and its skip/merge/report
    # counts are structurally zero. Printing them anyway would imply the tool
    # considered a correction and declined -- it never looked.
    if [ "$ROLLOUT_MODE" -eq 1 ]; then
        log_info "  by settings    : $n_conv   (the REFS variable)"
        log_info "  by manifest    : $n_manifest   (everything else, verbatim)"
    else
        log_info "  by convention  : $n_conv"
        log_info "  by manifest    : $n_manifest   (destination declares no standard for these)"
        log_info "  skipped        : $n_skip   (deployed web tree -- build output)"
        log_info "  merged         : $n_merge   (shared files -- registered, not copied)"
        log_info "  reported only  : $n_report"
    fi
    [ "$COLLISION_COUNT" -gt 0 ] && log_warn "  collisions     : $COLLISION_COUNT destinations claimed twice"
    [ "$IGNORED_COUNT" -gt 0 ]   && log_warn "  vcs-ignored    : $IGNORED_COUNT destinations the VCS cannot see"
    return 0
}

# ---------------------------------------------------------------------------
# report_tallies -- the run summary. Mode-aware.
# ---------------------------------------------------------------------------
report_tallies() {
    log_head "summary"
    if [ "$UNDO" -eq 1 ]; then
        log_info "removed          : $T_UNDONE"
        log_info "absent           : $T_ABSENT"
        log_info "skipped          : $T_UNDO_SKIPPED   (changed since apply, unverifiable, or a REMOVE)"
    else
        log_info "replaced         : $T_REPLACED"
        log_info "removed          : $T_REMOVED"
        log_info "absent           : $T_ABSENT"
    fi
    if [ "$ROLLOUT_MODE" -eq 0 ]; then
        log_info "skipped (web)    : $T_SKIPPED"
        log_info "merged (shared)  : $T_MERGE"
    fi
    log_info "failed           : $T_FAILED"
    return 0
}

# ---------------------------------------------------------------------------
# report_exceptions
#
# EVERYTHING that did not land where it was meant to, one line each, naming the
# file, the destination involved and the reason.
#
# Ordered so the items needing attention come first: a reader who stops after
# the first few has seen the ones that matter. The reason is the ACTUAL cause,
# never a generic failure -- "no source counterpart", "claimed by another
# directive" and "ignored by version control" are different problems with
# different fixes, and this is where that distinction has to survive.
#
# Printed even when empty, with an explicit statement, so a clean run is never
# mistaken for a summary that failed to print.
# ---------------------------------------------------------------------------
report_exceptions() {
    EX_SHOWN=0

    log_head "exceptions -- everything that did not land as written"

    # --- needs attention, most serious first -------------------------------
    emit_exceptions note "claimed by another directive"               "collision"
    emit_exceptions note "destination is ignored by version control"  "destination ignored"
    emit_exceptions note "source not found"                           "not placed"
    emit_exceptions note "no source counterpart"                      "SKIPPED WITH NO SOURCE -- this content is lost"
    emit_exceptions rule "$R_RETIRED"                                 "retired deploy kind"
    emit_exceptions note "patch-root xml is neither the build file nor the declared patch config" \
                                                                      "unrecognised patch config"

    # --- review: correct, but worth seeing ---------------------------------
    emit_exceptions rule "$R_WEB"    "skipped, deployed web tree (build output)"
    emit_exceptions rule "$R_SHARED" "merged into a shared file, not copied"

    if [ "$EX_SHOWN" -eq 0 ]; then
        log_info "none -- every directive landed exactly as expected."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# emit_exceptions <field> <value> <reason>
#
# Adds to the global EX_SHOWN rather than returning a count. Capturing a count
# with $(...) would run this in a subshell, where the log lines and the count
# compete for stdout -- and a command substitution per report line is exactly
# the spawn this codebase avoids.
# ---------------------------------------------------------------------------
emit_exceptions() {
    local field=$1 value=$2 reason=$3 i=0 hit
    while [ "$i" -lt "$P_COUNT" ]; do
        hit=0
        case $field in
            note) [ "${P_NOTE[$i]}" = "$value" ] && hit=1 ;;
            rule) [ "${P_RULE[$i]}" = "$value" ] && hit=1 ;;
        esac
        if [ "$hit" -eq 1 ]; then
            EX_SHOWN=$((EX_SHOWN + 1))
            log_warn "  $reason: ${P_MANIFEST[$i]}:${P_LINE[$i]} ${P_SPEC[$i]}${P_DEST[$i]:+ -> ${P_DEST[$i]}}"
        fi
        i=$((i + 1))
    done
    return 0
}

# ---------------------------------------------------------------------------
# report_tallies_combine -- the summary for manual consolidation, which
# processes no directives and so has no directive tallies to print.
# ---------------------------------------------------------------------------
report_tallies_combine() {
    log_head "summary"
    log_info "tables rebuilt   : $CON_REBUILT"
    log_info "tables removed   : $CON_REMOVED"
    log_info "warnings         : $CON_WARNINGS"
    return 0
}

# ---------------------------------------------------------------------------
# report_tallies_ddl -- the summary for --rebuild-ddl-list, the ddl
# counterpart to report_tallies_combine.
# ---------------------------------------------------------------------------
report_tallies_ddl() {
    log_head "summary"
    log_info "ddl lists rebuilt: $DDL_LISTS_REBUILT"
    log_info "warnings         : $DDL_WARNINGS"
    return 0
}

# ---------------------------------------------------------------------------
# exit_status
#   0  completed with no failed actions
#   1  completed, one or more actions failed
#   2  setup error (raised by die, never here)
#
# Absent removal targets, skipped deployed-web files and auto-added
# registrations are NOT failures.
# ---------------------------------------------------------------------------
exit_status() {
    [ "$T_FAILED" -gt 0 ] && return 1
    return 0
}
