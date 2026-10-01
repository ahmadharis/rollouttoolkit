#!/usr/bin/env bash
# A genuine write failure during --rebuild-ddl-list (the version directory is
# not writable) must fail the run -- the ddl.sh counterpart to
# test_combine_write_failure.sh. DDL_WARNINGS absorbed this before; exit_status()
# never looked at it, so the run reported success with no include list written.
set -u
. "$(dirname "$0")/lib/harness.sh"
sandbox_new

vdir="$TARGET_DIR/app/upgrade/1.0.0"
mkdir -p "$TARGET_DIR/app/data/load" "$vdir"
cat > "$vdir/sample_table.tbl" <<'EOF'
CREATE_TABLE(sample_table)
EOF

chmod 555 "$vdir"
run_rollout --rebuild-ddl-list "$TARGET_DIR/app/data/load"
rc=$STATUS
chmod 755 "$vdir"

assert_exit 1 "$rc" "a write failure during ddl list rebuild must fail the run"
assert_contains "$OUT" "could not write" "the failure is reported in the log"
assert_file_absent "$vdir/001-ddl_alters.sql" "no include list was produced"

sandbox_clean
echo "ok"
