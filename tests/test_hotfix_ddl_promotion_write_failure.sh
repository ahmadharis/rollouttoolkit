#!/usr/bin/env bash
# The automatic path: ddl promotion also runs as stage-5 post-processing on
# every TYPE=hotfix apply (promote_ddl), not only under manual
# --rebuild-ddl-list. A write failure there (here: the upgrade version
# directory is not writable, so the schema file cannot be copied in) must
# fail the whole apply -- it did not, before this fix, because promote_ddl
# never fed T_FAILED and DDL_FAILED did not exist.
set -u
. "$(dirname "$0")/lib/harness.sh"
sandbox_new
write_conf "TYPE=hotfix"

mkdir -p "$TARGET_DIR/app/ddl/table" "$TARGET_DIR/app/upgrade/1.0.0"

mkdir -p "$PACKAGE_DIR/pkg"
cat > "$PACKAGE_DIR/pkg/sample_table.tbl" <<'EOF'
CREATE_TABLE(sample_table)
EOF
printf 'REPLACE pkg/sample_table.tbl $LESDIR/app/ddl/table/sample_table.tbl\n' \
    > "$PACKAGE_DIR/package"

chmod 555 "$TARGET_DIR/app/upgrade/1.0.0"
run_rollout "$PACKAGE_DIR" "$TARGET_DIR"
rc=$STATUS
chmod 755 "$TARGET_DIR/app/upgrade/1.0.0"

assert_exit 1 "$rc" "a ddl promotion write failure during a hotfix apply must fail the run"
assert_contains "$OUT" "failed to promote" "the failure is reported in the log"
assert_file_exists "$TARGET_DIR/app/ddl/table/sample_table.tbl" \
    "stage 4 still placed the source schema file (REPLACE itself succeeded)"
assert_file_absent "$TARGET_DIR/app/upgrade/1.0.0/sample_table.tbl" \
    "the schema file was never promoted into the version directory"

sandbox_clean
echo "ok"
