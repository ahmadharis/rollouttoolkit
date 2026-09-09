#!/usr/bin/env bash
# --combine requires --folders (a setup error without it) and never sweeps a
# whole tree by default; a named folder that doesn't exist is a warning, not
# an error, and nothing is deleted.
set -u
. "$(dirname "$0")/lib/harness.sh"
sandbox_new

base="$TARGET_DIR/app/data/load"
mkdir -p "$base/real_table" "$TARGET_DIR/app/upgrade/1.0.0"
cat > "$base/real_table.ctl" <<'EOF'
publish data
EOF
printf 'id\n1\n' > "$base/real_table/one.csv"

run_rollout --combine "$base"
assert_exit 2 "$STATUS" "--combine without --folders is a setup error"

run_rollout --combine "$base" --folders does_not_exist
assert_exit 0 "$STATUS" "a missing named folder is a warning, not a failure"
assert_contains "$OUT" "no such folder" "the missing folder is named in the log"
assert_file_absent "$TARGET_DIR/app/upgrade/1.0.0/real_table.csv" \
    "an unrelated real table is left alone -- --combine never sweeps by default"

sandbox_clean
echo "ok"
