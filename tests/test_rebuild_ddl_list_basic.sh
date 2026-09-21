#!/usr/bin/env bash
# --rebuild-ddl-list rebuilds the include list from whatever schema files are
# CURRENTLY in the resolved version directory. No package, no plan, nothing
# copied in. It resolves the version directory exactly like --combine does
# (find_upgrade_for, or --target-version to override it), is idempotent, and
# picks up a file added between two runs without being told about it.
set -u
. "$(dirname "$0")/lib/harness.sh"
sandbox_new

vdir="$TARGET_DIR/app/upgrade/1.0.0"
mkdir -p "$TARGET_DIR/app/data/load" "$vdir"

cat > "$vdir/sample_table.tbl" <<'EOF'
CREATE_TABLE(sample_table)
EOF

run_rollout --rebuild-ddl-list "$TARGET_DIR/app/data/load"
assert_exit 0 "$STATUS" "a clean rebuild exits 0"

list="$vdir/001-ddl_alters.sql"
assert_file_exists "$list" "the include list is created when none existed"
assert_file_contains "$list" '#include "sample_table.tbl"' "the schema file is included"
assert_contains "$OUT" "every include resolves" "validation confirms every include names a real file"

before=$(cksum "$list")
run_rollout --rebuild-ddl-list "$TARGET_DIR/app/data/load"
after=$(cksum "$list")
assert_eq "$before" "$after" "rebuilding again with nothing changed produces byte-identical output"

# A second schema file lands, unrelated to any package or manifest --
# rebuild_ddl_list derives from the directory's CURRENT contents, not from
# what a specific run delivered.
cat > "$vdir/sample_table__new_col.iesql" <<'EOF'
ALTER_TABLE_TABLE_INFO(sample_table)
ALTER_TABLE_ADD_COLUMN_START(new_col)
EOF

run_rollout --rebuild-ddl-list "$TARGET_DIR/app/data/load"
assert_exit 0 "$STATUS" "picking up a newly added schema file still exits 0"
assert_file_contains "$list" '#include "sample_table__new_col.iesql"' \
    "the new file is discovered and included without being named anywhere"
assert_file_contains "$list" '#include "sample_table.tbl"' \
    "the original entry is still present"

sandbox_clean
echo "ok"
