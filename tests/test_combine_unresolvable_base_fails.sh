#!/usr/bin/env bash
# --combine must fail the run when it cannot even get to a table folder --
# a missing base path, a base with no upgrade-shaped ancestor, or a
# --target-version that was never created. Before this fix, combine_run
# logged an error and `continue`d past each of these without touching any
# counter, so the run always exited 0 -- a renamed or missing upgrade
# version directory would make the job report success while regenerating
# nothing.
set -u
. "$(dirname "$0")/lib/harness.sh"

# --- base path does not exist at all ---------------------------------------
sandbox_new
run_rollout --combine "$TARGET_DIR/does-not-exist" --folders sample_table
assert_exit 1 "$STATUS" "a nonexistent base path must fail the run"
assert_contains "$OUT" "base path not found" "the reason is reported"
sandbox_clean

# --- base path exists but has no upgrade-shaped ancestor above it ----------
sandbox_new
mkdir -p "$TARGET_DIR/app/data/load/sample_table"
run_rollout --combine "$TARGET_DIR/app/data/load" --folders sample_table
assert_exit 1 "$STATUS" "a base with no locatable version directory must fail the run"
assert_contains "$OUT" "no version directory could be located" "the reason is reported"
sandbox_clean

# --- --target-version names a version directory that was never created ----
sandbox_new
mkdir -p "$TARGET_DIR/app/data/load/sample_table" "$TARGET_DIR/app/upgrade/1.0.0"
run_rollout --combine "$TARGET_DIR/app/data/load" --folders sample_table --target-version 9.9.9
assert_exit 1 "$STATUS" "a --target-version that was never created must fail the run"
assert_contains "$OUT" "version directory does not exist" "the reason is reported"
sandbox_clean

echo "ok"
