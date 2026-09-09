#!/usr/bin/env bash
# When record files disagree on their header, the first (in stable order)
# wins and the disagreement is a WARNING -- reported, but not fatal to exit
# status, since the run still produced a usable file.
set -u
. "$(dirname "$0")/lib/harness.sh"
sandbox_new

base="$TARGET_DIR/app/data/load"
mkdir -p "$base/mixed_table" "$TARGET_DIR/app/upgrade/1.0.0"
cat > "$base/mixed_table.ctl" <<'EOF'
publish data
where table = 'mixed_table'
EOF
printf 'id,name\n1,alpha\n'        > "$base/mixed_table/a_first.csv"
printf 'id,name,extra\n2,beta,x\n' > "$base/mixed_table/b_second.csv"

run_rollout --combine "$base" --folders mixed_table

assert_exit 0 "$STATUS" "a header mismatch does not fail the run"
assert_contains "$OUT" "disagree on their header" "the mismatch is reported"
out_csv="$TARGET_DIR/app/upgrade/1.0.0/mixed_table.csv"
assert_eq "id,name" "$(sed -n '1p' "$out_csv")" "the first file's header wins"

sandbox_clean
echo "ok"
