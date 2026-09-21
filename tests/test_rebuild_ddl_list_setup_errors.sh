#!/usr/bin/env bash
# --rebuild-ddl-list is its own mode: it requires a base path (there is no
# default, same reasoning as --combine), and it cannot be combined with
# --combine or --version in one invocation -- each is a complete run with its
# own tallies and exit status, so doing more than one at once would mean
# silently picking one.
set -u
. "$(dirname "$0")/lib/harness.sh"
sandbox_new

run_rollout --rebuild-ddl-list
assert_exit 2 "$STATUS" "--rebuild-ddl-list without a base path is a setup error"
assert_contains "$OUT" "needs a base path" "the reason is named"

run_rollout --combine "$TARGET_DIR" --rebuild-ddl-list "$TARGET_DIR"
assert_exit 2 "$STATUS" "--combine and --rebuild-ddl-list together is a setup error"

run_rollout --rebuild-ddl-list "$TARGET_DIR" --version 5
assert_exit 2 "$STATUS" "--version has no meaning with --rebuild-ddl-list"

sandbox_clean
echo "ok"
