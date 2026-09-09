#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# log -- the run log. The ONLY output channel.
#
# Nothing in this tool prints directly: every message goes through log(), so it
# lands in both the file and on stdout and no output can be lost from either.
#
# Author: Haris Ahmad -- Smart IS
# ---------------------------------------------------------------------------

LOG_FILE=""
LOG_SEQ_MAX=100           # bound on the collision-suffix search; see open_log

# ---------------------------------------------------------------------------
# log <level> <msg>...
#
# One timestamped line to $LOG_FILE and stdout. Levels: INFO, WARN, ERROR.
#
# Hot path: called once per directive. Formats once with printf -v, then writes
# with two builtin printfs. No tee, no subshell, no date -- see CLAUDE.md.
# ---------------------------------------------------------------------------
log() {
    local level=$1; shift
    now
    local line
    printf -v line '%s [%-5s] %s' "$NOW" "$level" "$*"
    printf '%s\n' "$line"
    [ -n "$LOG_FILE" ] && printf '%s\n' "$line" >>"$LOG_FILE"
    return 0
}

log_info()  { log INFO  "$@"; }
log_warn()  { log WARN  "$@"; }
log_error() { log ERROR "$@"; }

# ---------------------------------------------------------------------------
# log_blank / log_rule / log_head -- structure for a log a human has to read.
# Still routed through the same two sinks; never printed directly.
# ---------------------------------------------------------------------------
log_raw() {
    printf '%s\n' "$*"
    [ -n "$LOG_FILE" ] && printf '%s\n' "$*" >>"$LOG_FILE"
    return 0
}
log_blank() { log_raw ""; }
log_rule()  { log_raw "---------------------------------------------------------------------------"; }
log_head()  { log_blank; log_raw "== $* =="; }

# ---------------------------------------------------------------------------
# resolve_log_dir -> $LOG_DIR
#
# LOG_DIR setting: absolute is used as-is, relative is placed beside the script,
# blank or absent keeps the default log/ beside the script. The log must never
# land inside the target tree or the package by default.
# ---------------------------------------------------------------------------
resolve_log_dir() {
    if [ -z "$SET_LOG_DIR" ]; then
        LOG_DIR="$SCRIPT_DIR/log"
    elif is_abs "$SET_LOG_DIR"; then
        LOG_DIR="$SET_LOG_DIR"
    else
        LOG_DIR="$SCRIPT_DIR/$SET_LOG_DIR"
    fi
    strip_slash "$LOG_DIR"; LOG_DIR=$STRIPPED
}

# ---------------------------------------------------------------------------
# open_log
#
# Create this run's log file. One file per run, timestamped, tagged with the
# active modes.
#
# The timestamp resolves only to the second, so two runs starting in the same
# second would choose the same name and the second would truncate the first.
# Sub-second stamps are not available portably (date '+%3N' is GNU-only and
# yields a literal "3N" on macOS; EPOCHREALTIME needs bash 5), so uniqueness
# comes from a suffix counter instead. Three parts, all required:
#
#   1. append _2, _3, ... until an unused name is found
#   2. create under `set -o noclobber` so the test and the create cannot race
#      between two concurrent runs
#   3. bound the loop by LOG_SEQ_MAX -- a writability test alone is not enough,
#      because Git Bash maps Windows ACLs imperfectly and can report an
#      unwritable directory as writable, which would spin forever
#
# Failing to create a log file is a setup error.
# ---------------------------------------------------------------------------
open_log() {
    resolve_log_dir

    [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null \
        || die "cannot create log directory: $LOG_DIR"

    local tag=""
    [ "$UNDO" -eq 1 ]         && tag="${tag}_undo"
    [ "$COMBINE_MODE" -eq 1 ] && tag="${tag}_combine"
    [ "$DRY_RUN" -eq 1 ]      && tag="${tag}_dryrun"

    stamp
    local base="$LOG_DIR/rollout_${STAMP}${tag}" candidate seq=1

    while [ "$seq" -le "$LOG_SEQ_MAX" ]; do
        if [ "$seq" -eq 1 ]; then candidate="${base}.log"; else candidate="${base}_${seq}.log"; fi
        # noclobber makes "test and create" a single atomic step
        if ( set -o noclobber; : >"$candidate" ) 2>/dev/null; then
            LOG_FILE=$candidate
            return 0
        fi
        seq=$((seq + 1))
    done

    die "cannot create a log file in $LOG_DIR (tried $LOG_SEQ_MAX names)"
}
