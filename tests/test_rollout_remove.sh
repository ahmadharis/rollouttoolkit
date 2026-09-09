#!/usr/bin/env bash
# A REMOVE directive deletes the destination it names, and only that.
set -u
. "$(dirname "$0")/lib/harness.sh"
sandbox_new

mkdir -p "$TARGET_DIR/some/path"
echo "old" > "$TARGET_DIR/some/path/gone.txt"
echo "keep" > "$TARGET_DIR/some/path/stays.txt"

mkdir -p "$PACKAGE_DIR/pkg"
printf 'REMOVE $LESDIR/some/path/gone.txt\n' > "$PACKAGE_DIR/package"

run_rollout "$PACKAGE_DIR" "$TARGET_DIR"

assert_exit 0 "$STATUS" "a clean removal exits 0"
assert_file_absent "$TARGET_DIR/some/path/gone.txt" "the named file is removed"
assert_file_exists "$TARGET_DIR/some/path/stays.txt" "an unrelated file in the same directory is untouched"

sandbox_clean
echo "ok"
