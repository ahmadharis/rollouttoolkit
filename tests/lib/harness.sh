#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# harness -- shared helpers for the test scripts in tests/.
#
# Portability matches the tool itself: bash 3.2, POSIX utilities only. No
# associative arrays, no ${var,,}, no external test framework -- one test
# script per behavior, each a standalone process that exits 0 on pass, 1 on
# the first failed assertion. run.sh tallies the results.
#
# A test script does:
#
#     . "$(dirname "$0")/lib/harness.sh"
#     sandbox_new
#     ... build a fixture under $PACKAGE_DIR and $TARGET_DIR ...
#     run_rollout "$PACKAGE_DIR" "$TARGET_DIR"
#     assert_exit 0 "$STATUS" "..."
#     sandbox_clean
# ---------------------------------------------------------------------------

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd)

fail() {
    echo "  FAIL: $1" >&2
    sandbox_clean
    exit 1
}

assert_eq() {
    [ "$1" = "$2" ] || fail "${3:-values differ}: expected [$1] got [$2]"
}

assert_exit() {
    [ "$1" = "$2" ] || fail "${3:-wrong exit status}: expected $1 got $2"
}

assert_file_exists() {
    [ -f "$1" ] || fail "${2:-expected file missing}: $1"
}

assert_file_absent() {
    [ ! -e "$1" ] || fail "${2:-file should not exist}: $1"
}

assert_dir_exists() {
    [ -d "$1" ] || fail "${2:-expected directory missing}: $1"
}

assert_contains() {
    case $1 in
        *"$2"*) ;;
        *) fail "${3:-expected text not found}: looked for [$2]" ;;
    esac
}

assert_not_contains() {
    case $1 in
        *"$2"*) fail "${3:-unexpected text found}: found [$2]" ;;
    esac
}

assert_file_contains() {
    grep -qF "$2" "$1" 2>/dev/null || fail "${3:-file does not contain expected text}: $1 / [$2]"
}

# ---------------------------------------------------------------------------
# sandbox_new -- a fresh, isolated sandbox for one test:
#
#   $SANDBOX      the temp root, removed by sandbox_clean
#   $PACKAGE_DIR  empty, ready for the test to build a package into
#   $TARGET_DIR   empty, ready for the test to build a target repo into
#   $TOOL_SH      a PRIVATE COPY of apply-rollout.sh + lib/, so the settings
#                 file it reads (beside the script, by design -- settings.sh)
#                 is this sandbox's own, never the developer's real
#                 apply-rollout.conf one directory up.
#
# The tool copy starts with no apply-rollout.conf at all, which is a valid,
# fully-defaulted state (TYPE=rollout, no derivation). A test that needs
# hotfix or other settings writes its own $TOOL_SH/../apply-rollout.conf --
# see hotfix_conf() below.
# ---------------------------------------------------------------------------
sandbox_new() {
    SANDBOX=$(mktemp -d) || fail "could not create a sandbox directory"
    PACKAGE_DIR="$SANDBOX/package"
    TARGET_DIR="$SANDBOX/target"
    mkdir -p "$PACKAGE_DIR" "$TARGET_DIR"

    local toolcopy="$SANDBOX/.tool"
    mkdir -p "$toolcopy"
    cp "$REPO_ROOT/apply-rollout.sh" "$toolcopy/"
    cp -R "$REPO_ROOT/lib" "$toolcopy/"
    TOOL_SH="$toolcopy/apply-rollout.sh"
}

sandbox_clean() {
    [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
}

# write_conf <lines...> -- give this sandbox's tool copy a settings file.
# One argument per line, e.g.:  write_conf "TYPE=hotfix" "COMBINE_EXCLUDE=x"
write_conf() {
    local conf="${TOOL_SH%/*}/apply-rollout.conf"
    : >"$conf"
    local line
    for line in "$@"; do printf '%s\n' "$line" >>"$conf"; done
}

# ---------------------------------------------------------------------------
# run_rollout [args...] -- invoke this sandbox's isolated tool copy.
# Sets $OUT (combined stdout+stderr) and $STATUS (exit code).
# ---------------------------------------------------------------------------
run_rollout() {
    OUT=$("$TOOL_SH" "$@" 2>&1)
    STATUS=$?
}

# tree_checksum <dir> -- a stable, order-independent fingerprint of every
# tracked byte under <dir>, used to assert a dry run left the tree untouched.
tree_checksum() {
    find "$1" -type f -exec cksum {} \; 2>/dev/null | sort
}
