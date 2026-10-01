#!/usr/bin/env bash
# A genuine write failure during --combine (the version directory is not
# writable) must fail the run. Before this test existed, consolidate_table's
# failure was only logged -- exit_status() checks T_FAILED alone, which
# --combine never touches, so the run reported success while the combined
# csv was never written. A caller like regenerate-usr-csvs.sh relies on this
# exit code to decide whether to commit and push.
set -u
. "$(dirname "$0")/lib/harness.sh"
sandbox_new

base="$TARGET_DIR/app/data/load"
vdir="$TARGET_DIR/app/upgrade/1.0.0"
mkdir -p "$base/sample_table" "$vdir"
cat > "$base/sample_table.ctl" <<'EOF'
publish data
where table = 'sample_table'
EOF
printf 'id,name\n1,alpha\n' > "$base/sample_table/one.csv"

# Deny write into the version directory so the temp-file write inside
# consolidate_table fails -- a real I/O failure, not the by-design header
# disagreement warning that test_combine_header_mismatch.sh covers.
chmod 555 "$vdir"
run_rollout --combine "$base" --folders sample_table
rc=$STATUS
chmod 755 "$vdir"

assert_exit 1 "$rc" "a write failure during combine must fail the run"
assert_contains "$OUT" "cannot write" "the failure is reported in the log"
assert_file_absent "$vdir/sample_table.csv" "no combined csv was produced"

sandbox_clean
echo "ok"
