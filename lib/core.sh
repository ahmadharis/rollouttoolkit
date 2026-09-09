#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# core -- globals, fatal errors, timestamps, small path helpers.
#
# Loaded first; every other module may rely on what is defined here and on
# nothing else. Bash 3.2, POSIX utilities only.
#
# Author: Haris Ahmad -- Smart IS
# ---------------------------------------------------------------------------

# --- run modes ------------------------------------------------------------
DRY_RUN=0                 # --dry-run   : plan and report, write nothing
UNDO=0                    # --undo      : reverse REPLACE directives
COMBINE_MODE=0            # --combine   : manual consolidation, no directives
VERSION_OVERRIDE=""       # --version N : rewrite year-leading version values

# --- run inputs -----------------------------------------------------------
PACKAGE_DIR=""
TARGET_DIR=""
# SCRIPT_DIR is deliberately NOT initialised here: the entry point resolves it
# before loading any module (it needs it to find them), and assigning it again
# would wipe that.
: "${SCRIPT_DIR:=}"

# --- settings (see settings.sh) -------------------------------------------
SET_TYPE=""               # TYPE           : rollout | hotfix, blank = rollout
SET_LOG_DIR=""
SET_JAR_DIR=""
SET_REFS_ROOT=""          # REFSDIR_ROOT   : rollout only, blank = webclient
SET_REFS_WEB=""           # REFSDIR_WEB    : rollout only, blank = web
SET_REFS_DEPLOY=""        # REFSDIR_DEPLOY : rollout only, blank = deploy
SET_COMBINE_PATHS=""
SET_COMBINE_EXCLUDE=""

# --- the resolved type ----------------------------------------------------
# SET_TYPE reduced to one integer, once, in stage 1. Exactly three places test
# it (IMPLEMENTATION.md 2.1); nothing else in the tool knows a type exists.
#
# The DEFAULT IS ROLLOUT, and that is not an arbitrary choice: rollout is the
# no-conventions behaviour, so an absent settings file degrades to the plainest
# reading of the manifest and writes nothing it was not told to write. Hotfix
# is the type that infers, and inference has to be asked for.
ROLLOUT_MODE=1

# Attributes this run's retired deploy kinds contribute, gathered once before
# execution so undo can recognise its OWN edit to a delivered file (yamlmerge.sh).
RETIRED_ATTRS=""

# Accumulate-across-every-config flags for the package-derived kind vocabulary
# (derive.sh). Set for the duration of stage 2 when the DESTINATION declares no
# kinds, so every config the package ships contributes rather than only the
# first -- a package delivers more than one patch, and their kinds differ.
# Cleared afterwards, so the stage 5 call falls back to the emptiness test.
SEED_ASSETS=0
SEED_SOURCES=0

# Root of the version override's scope, set once in stage 1 (version.sh).
# Derived under hotfix, from the REFS settings under rollout, so the two types
# cannot drift apart.
VERSION_SCOPE_DIR=""

# --- scratch globals ------------------------------------------------------
# Functions in the per-directive hot path return values through globals rather
# than through $(...), which would fork a subshell for every directive. Read
# them immediately after the call that sets them.
RESOLVED=""               # resolve_*: the resolved absolute destination
RESOLVED_BASE=""          # resolve_*: pruning floor for that destination
RESOLVED_RULE=""          # resolve_*: which rule decided it
NOW=""                    # now: current timestamp

# ---------------------------------------------------------------------------
# die <msg>...
#
# Report a fatal SETUP error and exit 2. Setup errors only: bad usage, missing
# package, unwritable log, a destination escaping the target. A directive that
# cannot be carried out is logged and the run continues -- never die.
# ---------------------------------------------------------------------------
die() {
    printf 'apply-rollout: %s\n' "$*" >&2
    exit 2
}

# ---------------------------------------------------------------------------
# now
#
# Set $NOW to 'YYYY-MM-DD HH:MM:SS'. Prefers the printf builtin (bash 4.2+,
# Git Bash and most Linux) and falls back to date(1) only on bash 3.2 (macOS),
# so the common case costs no process spawn.
# ---------------------------------------------------------------------------
if printf -v _core_probe '%(%Y)T' -1 2>/dev/null; then
    now() { printf -v NOW '%(%Y-%m-%d %H:%M:%S)T' -1; }
    stamp() { printf -v STAMP '%(%Y%m%d_%H%M%S)T' -1; }
else
    now() { NOW=$(date '+%Y-%m-%d %H:%M:%S'); }
    stamp() { STAMP=$(date '+%Y%m%d_%H%M%S'); }
fi
unset _core_probe

# ---------------------------------------------------------------------------
# Path helpers -- parameter expansion only, no basename/dirname spawns.
# ---------------------------------------------------------------------------

# path_dir <path> -> $PATH_DIR   (dirname; "." when there is no slash)
path_dir() {
    case $1 in
        */*) PATH_DIR=${1%/*}; [ -n "$PATH_DIR" ] || PATH_DIR="/" ;;
        *)   PATH_DIR="." ;;
    esac
}

# path_base <path> -> $PATH_BASE  (basename)
path_base() { PATH_BASE=${1##*/}; }

# strip_slash <path> -> $STRIPPED (drop trailing slashes; keep a bare "/")
# ---------------------------------------------------------------------------
# arr_count <safe-expansion>  -> $ARR_COUNT
#
# The length of an array that may be EMPTY.
#
# bash 3.2 treats an empty array as unset, so under `set -u` both "${ARR[@]}"
# and ${#ARR[@]} abort the run -- the same trap that once broke
# discover_manifests for every single-manifest package. The caller passes the
# guarded expansion and the count comes from the positional parameters:
#
#     arr_count ${ARR[@]+"${ARR[@]}"}
#
# Quoting inside the guard keeps elements containing spaces intact.
#
# An empty array became reachable everywhere once undo started leaving a build
# file with no copy entries at all -- which is the baseline state, not an error.
# ---------------------------------------------------------------------------
ARR_COUNT=0
arr_count() { ARR_COUNT=$#; }

strip_slash() {
    STRIPPED=$1
    while :; do
        case $STRIPPED in
            /) break ;;
            */) STRIPPED=${STRIPPED%/} ;;
            *) break ;;
        esac
    done
}

# strip_cr <line> -> $STRIPPED_CR
# Manifests and settings files may arrive with Windows line endings; drop a
# single trailing carriage return before parsing any line.
strip_cr() {
    STRIPPED_CR=$1
    case $STRIPPED_CR in
        *$'\r') STRIPPED_CR=${STRIPPED_CR%$'\r'} ;;
    esac
}

# is_abs <path> -- true for POSIX absolute and for Windows drive paths (C:/...)
is_abs() {
    case $1 in
        /*) return 0 ;;
        [A-Za-z]:/*) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# normalize_path <path> -> $NORMALIZED
#
# Collapse '//', resolve '.' and '..' lexically. Lexical on purpose: the path
# need not exist yet, and this is what the containment check in the planner
# tests, so a directive cannot escape the target via '..'.
# ---------------------------------------------------------------------------
normalize_path() {
    local path=$1 lead="" out="" seg last
    case $path in
        /*) lead="/"; path=${path#/} ;;
        [A-Za-z]:/*) lead="${path%%/*}/"; path=${path#*/} ;;
    esac

    local IFS=/
    set -f                       # a literal glob char in a path must not expand
    for seg in $path; do
        case $seg in
            ""|.) continue ;;
            ..)
                case $out in */*) last=${out##*/} ;; *) last=$out ;; esac
                if [ -n "$out" ] && [ "$last" != ".." ]; then
                    case $out in */*) out=${out%/*} ;; *) out="" ;; esac
                elif [ -z "$lead" ]; then
                    out="${out:+$out/}.."     # relative path may keep a leading ..
                fi                            # absolute: '..' at root is dropped
                ;;
            *) out="${out:+$out/}$seg" ;;
        esac
    done
    set +f

    NORMALIZED="${lead}${out}"
    [ -n "$NORMALIZED" ] || NORMALIZED="."
}
