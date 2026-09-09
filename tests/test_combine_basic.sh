#!/usr/bin/env bash
# --combine rebuilds a table's combined csv from every record file currently
# in its folder, under one header, into the highest version directory found.
set -u
. "$(dirname "$0")/lib/harness.sh"
sandbox_new

base="$TARGET_DIR/app/data/load"
mkdir -p "$base/sample_table" "$TARGET_DIR/app/upgrade/1.0.0"
cat > "$base/sample_table.ctl" <<'EOF'
publish data
where table = 'sample_table'
and id = '@id@'
EOF
printf 'id,name\n1,alpha\n' > "$base/sample_table/one.csv"
printf 'id,name\n2,beta\n'  > "$base/sample_table/two.csv"

run_rollout --combine "$base" --folders sample_table

assert_exit 0 "$STATUS" "a clean combine exits 0"
out_csv="$TARGET_DIR/app/upgrade/1.0.0/sample_table.csv"
assert_file_exists "$out_csv" "the combined csv is written into the version directory"
assert_eq "id,name" "$(sed -n '1p' "$out_csv")" "the header is the record files' own header"
assert_contains "$(cat "$out_csv")" "1,alpha" "the first record's row is present"
assert_contains "$(cat "$out_csv")" "2,beta" "the second record's row is present"
assert_file_exists "$TARGET_DIR/app/upgrade/1.0.0/sample_table.ctl" "the control file is placed alongside it"
assert_file_exists "$TARGET_DIR/app/upgrade/1.0.0/sample_table.mload" "a loader descriptor is generated"

sandbox_clean
echo "ok"
