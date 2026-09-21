#!/usr/bin/env bash
# ===========================================================================
# apply-rollout.sh -- apply a rollout package to a repository whose layout
# differs from the shape the package was authored in.
#
# Author: Haris Ahmad -- Smart IS
#
# SPEC.md defines WHAT this does. IMPLEMENTATION.md defines HOW it is built.
# README.md documents it for users. CLAUDE.md is the engineering contract.
#
# Six stages, each with one job, handing a defined result to the next:
#
#   1. Startup         parse arguments, read settings, open the log, banner
#   2. Discovery       locate manifests; derive destination facts from target
#   3. Planning        resolve every directive -- no filesystem writes
#   4. Execution       carry out the planned actions
#   5. Post-processing rebuild combined load data; reconcile shared segments
#   6. Reporting       tallies, exceptions summary, exit status
#
# Planning is separated from execution deliberately: it is what makes
# --dry-run a true preview rather than a second code path, and it is the only
# way collision detection can work.
#
# Portability: bash 3.2, POSIX utilities. Identical on macOS, Linux and Git
# Bash. No process spawns in the per-directive loop beyond the real work.
#
# Exit status:  0 no failures | 1 some action failed | 2 setup error
# ===========================================================================

set -u

# --- locate ourselves ------------------------------------------------------
# Needed regardless: apply-rollout.conf and the default log directory both sit
# beside the script. The library modules load from the same base.
SCRIPT_SELF=$0
case $SCRIPT_SELF in
    */*) SCRIPT_DIR=${SCRIPT_SELF%/*} ;;
    *)   SCRIPT_DIR="." ;;
esac
if [ -d "$SCRIPT_DIR" ]; then
    SCRIPT_DIR=$(cd "$SCRIPT_DIR" 2>/dev/null && pwd) || SCRIPT_DIR="."
fi

# --- load the library ------------------------------------------------------
# A partial load must never run: a missing module means a convention silently
# does nothing, which is precisely the failure mode this tool exists to remove.
ROLLOUT_MODULES="core log settings xml derive resolve rollout manifest plan execute version bundle splice register yamlmerge consolidate ddl report"
for _mod in $ROLLOUT_MODULES; do
    _path="$SCRIPT_DIR/lib/$_mod.sh"
    if [ ! -f "$_path" ]; then
        printf 'apply-rollout: missing module: %s\n' "$_path" >&2
        exit 2
    fi
    # shellcheck source=/dev/null
    . "$_path" || { printf 'apply-rollout: cannot load module: %s\n' "$_path" >&2; exit 2; }
done
unset _mod _path

# ---------------------------------------------------------------------------
usage() {
    cat <<'USAGE'
Usage:
  apply-rollout.sh [options] <package_dir> <target_dir>
  apply-rollout.sh --combine <paths...> --folders <a,b> [--target-version <v>]
  apply-rollout.sh --rebuild-ddl-list <paths...> [--target-version <v>]

Arguments:
  <package_dir>  the rollout package: manifest(s) plus a pkg/ payload tree
  <target_dir>   the destination repository root

Options:
  --dry-run              report what would happen; change nothing
  --undo                 reverse a rollout (REPLACE only; REMOVE cannot be undone)
  --version <N>          rewrite year-leading version values in bundle
                         declarations, in transit. A modifier on apply, dry run
                         or undo -- it has no standalone form
  --combine <paths...>   manual load-data consolidation, processing no directives.
                         Requires --folders; never deletes anything
  --folders <list>       with --combine: the table folders to rebuild (required)
  --rebuild-ddl-list <paths...>
                         manual ddl include-list rebuild, processing no
                         directives. Rebuilds 001-ddl_alters.sql (or whatever
                         it is already named) from the schema files currently
                         in the resolved version directory. It copies
                         nothing in, so a schema file that hasn't already
                         been placed there is not this mode's job. A base
                         path shared with a --combine run resolves to the
                         same version directory, independently of it.
  --target-version <v>   with --combine or --rebuild-ddl-list: write here
                         instead of the highest version
  -h, --help             print this and exit
  --                     end of options

Exit status:
  0  completed with no failed actions
  1  completed, but one or more actions failed
  2  setup error: invalid usage, missing package, or no manifest found
USAGE
}

# ===========================================================================
# Stage 1 -- startup
# ===========================================================================
COMBINE_PATHS_ARG=""
COMBINE_FOLDERS=""
COMBINE_TARGET_VERSION=""
DDL_PATHS_ARG=""

parse_args() {
    local positional=0
    while [ "$#" -gt 0 ]; do
        case $1 in
            --dry-run) DRY_RUN=1 ;;
            --undo)    UNDO=1 ;;
            --combine) COMBINE_MODE=1 ;;
            --rebuild-ddl-list) DDL_MODE=1 ;;
            --version)
                [ "$#" -ge 2 ] || die "--version needs a value"
                shift; VERSION_OVERRIDE=$1 ;;
            --folders)
                [ "$#" -ge 2 ] || die "--folders needs a value"
                shift; COMBINE_FOLDERS=$1 ;;
            --target-version)
                [ "$#" -ge 2 ] || die "--target-version needs a value"
                shift; COMBINE_TARGET_VERSION=$1 ;;
            -h|--help) usage; exit 0 ;;
            --) shift; break ;;
            -*) die "unknown option: $1
$(usage)" ;;
            *)
                if [ "$COMBINE_MODE" -eq 1 ]; then
                    COMBINE_PATHS_ARG="${COMBINE_PATHS_ARG:+$COMBINE_PATHS_ARG }$1"
                elif [ "$DDL_MODE" -eq 1 ]; then
                    DDL_PATHS_ARG="${DDL_PATHS_ARG:+$DDL_PATHS_ARG }$1"
                elif [ "$positional" -eq 0 ]; then
                    PACKAGE_DIR=$1; positional=1
                elif [ "$positional" -eq 1 ]; then
                    TARGET_DIR=$1; positional=2
                else
                    die "unexpected argument: $1"
                fi
                ;;
        esac
        shift
    done
    while [ "$#" -gt 0 ]; do
        if [ "$COMBINE_MODE" -eq 1 ]; then
            COMBINE_PATHS_ARG="${COMBINE_PATHS_ARG:+$COMBINE_PATHS_ARG }$1"
        elif [ "$DDL_MODE" -eq 1 ]; then
            DDL_PATHS_ARG="${DDL_PATHS_ARG:+$DDL_PATHS_ARG }$1"
        elif [ "$positional" -eq 0 ]; then PACKAGE_DIR=$1; positional=1
        elif [ "$positional" -eq 1 ]; then TARGET_DIR=$1; positional=2
        else die "unexpected argument: $1"; fi
        shift
    done

    # Ambiguous, not additive: each is its own complete run with its own
    # tallies and exit status. Doing both would mean silently picking one.
    if [ "$COMBINE_MODE" -eq 1 ] && [ "$DDL_MODE" -eq 1 ]; then
        die "--combine and --rebuild-ddl-list are two separate runs; pass one at a time"
    fi

    # --version has no meaning on its own: there is no package to read a
    # version from without a rollout operation.
    if [ -n "$VERSION_OVERRIDE" ] && { [ "$COMBINE_MODE" -eq 1 ] || [ "$DDL_MODE" -eq 1 ]; }; then
        die "--version is a modifier on apply, dry run or undo; it has no meaning with --combine or --rebuild-ddl-list"
    fi

    if [ "$COMBINE_MODE" -eq 0 ] && [ "$DDL_MODE" -eq 0 ]; then
        [ -n "$PACKAGE_DIR" ] || { usage >&2; die "no package directory given"; }
        [ -n "$TARGET_DIR" ]  || { usage >&2; die "no target directory given"; }
        [ -d "$PACKAGE_DIR" ] || die "package directory not found: $PACKAGE_DIR"
        [ -d "$TARGET_DIR" ]  || die "target directory not found: $TARGET_DIR"
        strip_slash "$PACKAGE_DIR"; PACKAGE_DIR=$(cd "$STRIPPED" && pwd) || die "cannot read package directory"
        strip_slash "$TARGET_DIR";  TARGET_DIR=$(cd "$STRIPPED" && pwd)  || die "cannot read target directory"
    fi
}

banner() {
    log_rule
    log_info "apply-rollout"
    local mode="apply"
    [ "$UNDO" -eq 1 ]         && mode="undo"
    [ "$COMBINE_MODE" -eq 1 ] && mode="combine"
    [ "$DDL_MODE" -eq 1 ]     && mode="rebuild-ddl-list"
    [ "$DRY_RUN" -eq 1 ]      && mode="$mode (dry run -- nothing will be written)"
    log_info "mode             : $mode"
    [ "$COMBINE_MODE" -eq 0 ] && [ "$DDL_MODE" -eq 0 ] && log_info "package          : $PACKAGE_DIR"
    [ "$COMBINE_MODE" -eq 0 ] && [ "$DDL_MODE" -eq 0 ] && log_info "target           : $TARGET_DIR"
    [ -n "$VERSION_OVERRIDE" ] && log_info "version override : $VERSION_OVERRIDE"
    log_info "log              : $LOG_FILE"
    log_settings
    log_rule
}

# ===========================================================================
main() {
    parse_args "$@"

    # Settings are read BEFORE the log is opened: LOG_DIR can move the log.
    # The type is resolved in the same breath, so an unrecognised TYPE is
    # refused before the run creates so much as a log file.
    load_settings
    resolve_type
    open_log
    banner

    if [ "$COMBINE_MODE" -eq 1 ]; then
        combine_run
        report_tallies_combine
        log_blank
        log_info "log written to $LOG_FILE"
        exit_status
        return $?
    fi

    if [ "$DDL_MODE" -eq 1 ]; then
        rebuild_ddl_run
        report_tallies_ddl
        log_blank
        log_info "log written to $LOG_FILE"
        exit_status
        return $?
    fi

    # --- Stage 2 -- discovery ---------------------------------------------
    # A rollout derives NOTHING: it has no use for any destination fact, and
    # deriving facts it would then ignore would invite them being consulted by
    # accident. Every D_* global stays at its initialised empty value, which is
    # also what makes the hotfix conventions stand down on their own.
    if [ "$ROLLOUT_MODE" -eq 0 ]; then
        log_head "destination facts (derived from the target)"
        derive_facts
        # What the destination no longer declares, the package still does. This
        # must run before planning: the planner splits directives on a known
        # kind to seed the patch names, so a vocabulary arriving later arrives
        # after everything that depends on it.
        derive_from_package
        log_facts
    else
        log_head "destination"
        log_info "  type rollout: the manifest decides every destination; nothing is derived"
    fi

    # One global, set once, for both types -- so --version cannot mean one
    # thing here and another in the planner.
    set_version_scope

    discover_manifests || die "no manifest found in $PACKAGE_DIR
  expected one of: <package>, <package>_LES, <package>_REFS"
    log_head "manifests"
    local m
    for m in ${MANIFESTS[@]+"${MANIFESTS[@]}"}; do log_info "  ${m##*/}"; done

    # --- Stage 3 -- planning ----------------------------------------------
    build_plan || die "no REPLACE or REMOVE directive found in any manifest"
    detect_collisions
    check_ignored
    report_plan

    # Gather what the retired kinds contribute BEFORE execution: undo compares
    # content in stage 4, but the merge that changed that content runs in
    # stage 5. Without this, undo refuses to remove a file the tool itself
    # edited on the way in.
    collect_retired_attrs

    # --- Stage 4 -- execution ---------------------------------------------
    log_head "execution"
    execute_plan

    # --- Stage 5 -- post-processing ---------------------------------------
    # Two INDEPENDENT steps: different inputs, different outputs, neither
    # consuming the other's result, so their relative order is immaterial.
    # Both run after every file operation, in apply AND undo, because both
    # derive from the final state of the tree rather than from what the
    # package contained.
    # HOTFIX ONLY. Under rollout no asset is ever regenerated: the run copies
    # files and deletes files, and does nothing else.
    if [ "$ROLLOUT_MODE" -eq 0 ]; then
        merge_retired_kinds
        reconcile
        # The load tree is identified HERE, not in stage 2: the evidence that
        # distinguishes it -- a control file matching the one the version
        # directory already carries -- only exists once this run's files have
        # landed.
        derive_load_trees
        consolidate_run
        # Schema files are inert until they are promoted into the version
        # directory and named by its include list (SPEC.md 7A).
        promote_ddl
    fi

    # --- Stage 6 -- reporting ---------------------------------------------
    # Nothing is skipped under rollout, so this check has nothing to report.
    if [ "$ROLLOUT_MODE" -eq 0 ]; then
        check_web_skips
    fi
    report_version
    report_tallies
    report_exceptions
    log_blank
    log_info "log written to $LOG_FILE"

    exit_status
}

main "$@"
