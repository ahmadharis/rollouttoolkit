#!/usr/bin/env bash
# The automatic path: load-data consolidation also runs as stage-5
# post-processing on every TYPE=hotfix apply, not only under manual
# --combine. A write failure there (here: the upgrade version directory is
# not writable) must fail the whole apply the same way a failed REPLACE
# does -- it did not, before this fix, because consolidate_run never fed
# T_FAILED and CON_FAILED did not exist.
set -u
. "$(dirname "$0")/lib/harness.sh"
sandbox_new
write_conf "TYPE=hotfix"

mkdir -p "$TARGET_DIR/app/data/load/sample_table" "$TARGET_DIR/app/upgrade/1.0.0"
cat > "$TARGET_DIR/app/data/load/sample_table.ctl" <<'EOF'
publish data
where table = 'sample_table'
EOF

mkdir -p "$PACKAGE_DIR/pkg"
printf 'id,name\n1,alpha\n' > "$PACKAGE_DIR/pkg/one.csv"
printf 'REPLACE pkg/one.csv $LESDIR/app/data/load/sample_table/one.csv\n' > "$PACKAGE_DIR/package"

chmod 555 "$TARGET_DIR/app/upgrade/1.0.0"
run_rollout "$PACKAGE_DIR" "$TARGET_DIR"
rc=$STATUS
chmod 755 "$TARGET_DIR/app/upgrade/1.0.0"

assert_exit 1 "$rc" "a consolidation write failure during a hotfix apply must fail the run"
assert_contains "$OUT" "cannot write" "the failure is reported in the log"
assert_file_exists "$TARGET_DIR/app/data/load/sample_table/one.csv" \
    "stage 4 still placed the source record (REPLACE itself succeeded)"
assert_file_absent "$TARGET_DIR/app/upgrade/1.0.0/sample_table.csv" \
    "no combined csv was produced"

sandbox_clean
echo "ok"
