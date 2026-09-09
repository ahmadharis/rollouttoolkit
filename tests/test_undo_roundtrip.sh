#!/usr/bin/env bash
# apply, then --undo the same package against the same target: a REPLACE that
# created a new file is reversed, and the tree returns to its pre-apply state.
set -u
. "$(dirname "$0")/lib/harness.sh"
sandbox_new

mkdir -p "$PACKAGE_DIR/pkg"
echo "payload" > "$PACKAGE_DIR/pkg/new.txt"
printf 'REPLACE pkg/new.txt $LESDIR/some/path/new.txt\n' > "$PACKAGE_DIR/package"

before=$(tree_checksum "$TARGET_DIR")

run_rollout "$PACKAGE_DIR" "$TARGET_DIR"
assert_exit 0 "$STATUS" "the apply exits 0"
assert_file_exists "$TARGET_DIR/some/path/new.txt" "the apply created the file"

run_rollout --undo "$PACKAGE_DIR" "$TARGET_DIR"
assert_exit 0 "$STATUS" "the undo exits 0"
assert_file_absent "$TARGET_DIR/some/path/new.txt" "undo removes the file the apply created"

after=$(tree_checksum "$TARGET_DIR")
assert_eq "$before" "$after" "apply -> undo returns the tree to its original state"

sandbox_clean
echo "ok"
