#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# settings -- read apply-rollout.conf.
#
# Eight keys, five of them read under one type only. Everything the target can
# declare for itself is DERIVED at run time (see derive.sh) rather than
# configured, because a stale setting would be worse than no setting.
#
# Under TYPE=rollout nothing is derived, so the three REFSDIR_* keys are the
# only thing that can place the REFS variable. They are the tool's original
# settings, restored with their original meaning: REFSDIR_WEB and
# REFSDIR_DEPLOY are relative to REFSDIR_ROOT, and each REPLACES the segment
# that selected it rather than nesting beneath it.
#
# The file is READ, never sourced. Sourcing would execute arbitrary code and
# could clobber script globals (TARGET_DIR, LOG_FILE, ...). Do not change this.
#
# An absent or partial file degrades to unchanged behaviour. That is what makes
# the tool safe to run against an unfamiliar target, and it is non-negotiable.
#
# Author: Haris Ahmad -- Smart IS
# ---------------------------------------------------------------------------

SETTINGS_FILE=""
SETTINGS_LOADED=0

# ---------------------------------------------------------------------------
# load_settings
#
# Read the known KEY=value pairs into SET_*. Ignores comments, blank lines and
# unknown keys -- so a settings file still carrying the superseded REFSDIR_*
# keys does not break a run. Tolerates CRLF, strips surrounding quotes and
# trailing slashes.
#
# Runs BEFORE the log is opened, because LOG_DIR can move the log file. Do not
# add a log call in here; there is nowhere for it to go yet.
# ---------------------------------------------------------------------------
load_settings() {
    SETTINGS_FILE="$SCRIPT_DIR/apply-rollout.conf"
    [ -f "$SETTINGS_FILE" ] || return 0

    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        strip_cr "$line"; line=$STRIPPED_CR

        # trim leading and trailing whitespace
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}

        case $line in
            ""|\#*) continue ;;
            *=*) ;;
            *) continue ;;
        esac

        key=${line%%=*}
        value=${line#*=}
        key=${key%"${key##*[![:space:]]}"}
        value=${value#"${value%%[![:space:]]*}"}
        value=${value%"${value##*[![:space:]]}"}

        # strip one layer of surrounding quotes
        case $value in
            \"*\") value=${value#\"}; value=${value%\"} ;;
            \'*\') value=${value#\'}; value=${value%\'} ;;
        esac

        case $key in
            TYPE)          SET_TYPE=$value ;;
            LOG_DIR)       strip_slash "$value"; SET_LOG_DIR=$STRIPPED ;;
            JAR_DIR)       strip_slash "$value"; SET_JAR_DIR=$STRIPPED ;;
            REFSDIR_ROOT)   strip_slash "$value"; SET_REFS_ROOT=$STRIPPED ;;
            REFSDIR_WEB)    strip_slash "$value"; SET_REFS_WEB=$STRIPPED ;;
            REFSDIR_DEPLOY) strip_slash "$value"; SET_REFS_DEPLOY=$STRIPPED ;;
            COMBINE_PATHS)   SET_COMBINE_PATHS=$value ;;
            COMBINE_EXCLUDE) SET_COMBINE_EXCLUDE=$value ;;
            *) : ;;                       # unknown key: ignored by design
        esac
    done <"$SETTINGS_FILE"

    SETTINGS_LOADED=1
    return 0
}

# ---------------------------------------------------------------------------
# resolve_type
#
# Reduce TYPE to ROLLOUT_MODE, once. Called immediately after load_settings and
# BEFORE the log is opened, so an unrecognised value is refused before the run
# creates anything at all.
#
# Matched with a case glob rather than ${var,,}, which bash 3.2 does not have.
#
# An unrecognised value is a SETUP ERROR, never a fallback to the default. A
# misspelled type that silently selected the other resolution would write the
# wrong tree while reporting success -- which is the failure this tool exists
# to remove, arriving through the one door meant to prevent it.
# ---------------------------------------------------------------------------
resolve_type() {
    case $SET_TYPE in
        "")                           ROLLOUT_MODE=1 ;;
        [Rr][Oo][Ll][Ll][Oo][Uu][Tt]) ROLLOUT_MODE=1 ;;
        [Hh][Oo][Tt][Ff][Ii][Xx])     ROLLOUT_MODE=0 ;;
        *) die "unrecognised TYPE: $SET_TYPE
  expected 'rollout' or 'hotfix' (blank means rollout)
  in $SETTINGS_FILE" ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# The REFS settings, read through resolvers rather than at the call site, so a
# default lives in exactly one place. Rollout only -- under hotfix the refs
# root and the wrapper are derived instead.
#
# A leading slash is stripped from the two subpaths: they are relative to the
# root by definition, and an operator writing "/web/usr" means the same thing.
# ---------------------------------------------------------------------------
refs_root() {
    REFS_ROOT=${SET_REFS_ROOT:-webclient}
}

refs_web() {
    REFS_WEB=${SET_REFS_WEB:-web}
    REFS_WEB=${REFS_WEB#/}
}

refs_deploy() {
    REFS_DEPLOY=${SET_REFS_DEPLOY:-deploy}
    REFS_DEPLOY=${REFS_DEPLOY#/}
}

# ---------------------------------------------------------------------------
# log_settings
#
# Echo what was loaded into the run banner, so a dry run is a complete audit of
# what would happen and why. Called after the log is open.
# ---------------------------------------------------------------------------
log_settings() {
    if [ "$SETTINGS_LOADED" -eq 1 ]; then
        log_info "settings         : $SETTINGS_FILE"
    else
        log_info "settings         : none (defaults; no file at $SCRIPT_DIR/apply-rollout.conf)"
    fi

    if [ "$ROLLOUT_MODE" -eq 1 ]; then
        log_setting "TYPE           " "$SET_TYPE" "rollout"
    else
        log_setting "TYPE           " "$SET_TYPE" "hotfix"
    fi
    log_setting "LOG_DIR        " "$SET_LOG_DIR" "${SET_LOG_DIR:-log/ beside script}"
    log_setting "JAR_DIR        " "$SET_JAR_DIR" "${SET_JAR_DIR:-the manifest decides}"

    # Only the keys the ACTIVE type reads are echoed as live; the rest are
    # named as inert. A dry run is meant to be a complete audit of what would
    # happen, and a setting listed without qualification implies it is in
    # force -- which, for the other type's keys, would be a lie.
    if [ "$ROLLOUT_MODE" -eq 1 ]; then
        refs_root; refs_web; refs_deploy
        log_setting "REFSDIR_ROOT   " "$SET_REFS_ROOT"   "$REFS_ROOT"
        log_setting "REFSDIR_WEB    " "$SET_REFS_WEB"    "$REFS_WEB"
        log_setting "REFSDIR_DEPLOY " "$SET_REFS_DEPLOY" "$REFS_DEPLOY"
        if [ -n "$SET_COMBINE_PATHS" ] || [ -n "$SET_COMBINE_EXCLUDE" ]; then
            log_info "  hotfix keys    : set, but inert under TYPE=rollout"
        fi
    else
        if [ -n "$SET_REFS_ROOT" ] || [ -n "$SET_REFS_WEB" ] || [ -n "$SET_REFS_DEPLOY" ]; then
            log_info "  REFSDIR_*      : set, but inert under TYPE=hotfix (derived from the target)"
        fi
        log_setting "COMBINE_PATHS  " "$SET_COMBINE_PATHS" "${SET_COMBINE_PATHS:-unset}"
        log_setting "COMBINE_EXCLUDE" "$SET_COMBINE_EXCLUDE" "${SET_COMBINE_EXCLUDE:-none}"
    fi
}

# ---------------------------------------------------------------------------
# log_setting <padded-label> <raw-value> <effective-value>
#
# One banner line, marking a value that came from a default rather than from
# the file -- so the reader can tell "this is what the file says" from "this is
# what you get when the file says nothing".
# ---------------------------------------------------------------------------
log_setting() {
    if [ -n "$2" ]; then
        log_info "  $1: $3"
    else
        log_info "  $1: $3   <unset, default>"
    fi
}
