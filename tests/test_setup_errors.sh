#!/usr/bin/env bash
# Setup errors exit 2, before anything is touched: an unrecognized TYPE, and a
# package directory with no manifest the tool can find.
set -u
. "$(dirname "$0")/lib/harness.sh"
sandbox_new

# --- unrecognized TYPE --------------------------------------------------
write_conf "TYPE=not-a-real-type"
mkdir -p "$PACKAGE_DIR/pkg"
echo "x" > "$PACKAGE_DIR/pkg/x.txt"
printf 'REPLACE pkg/x.txt $LESDIR/x.txt\n' > "$PACKAGE_DIR/package"

run_rollout "$PACKAGE_DIR" "$TARGET_DIR"
assert_exit 2 "$STATUS" "an unrecognized TYPE is a setup error, not a silent fallback"
assert_file_absent "$TARGET_DIR/x.txt" "nothing is written when setup fails"

# --- no manifest found ---------------------------------------------------
sandbox_clean
sandbox_new
mkdir -p "$PACKAGE_DIR/pkg"
echo "x" > "$PACKAGE_DIR/pkg/x.txt"
# deliberately no manifest file named after the package directory

run_rollout "$PACKAGE_DIR" "$TARGET_DIR"
assert_exit 2 "$STATUS" "a package with no discoverable manifest is a setup error"

sandbox_clean
echo "ok"
