#!/usr/bin/env bash
# --dry-run must leave the target tree byte-for-byte identical -- planning is
# fully separated from execution, so a preview can never partially apply.
set -u
. "$(dirname "$0")/lib/harness.sh"
sandbox_new

mkdir -p "$TARGET_DIR/some/path"
echo "existing" > "$TARGET_DIR/some/path/existing.txt"

mkdir -p "$PACKAGE_DIR/pkg"
echo "new" > "$PACKAGE_DIR/pkg/new.txt"
{
    printf 'REPLACE pkg/new.txt $LESDIR/some/path/new.txt\n'
    printf 'REMOVE $LESDIR/some/path/existing.txt\n'
} > "$PACKAGE_DIR/package"

before=$(tree_checksum "$TARGET_DIR")
run_rollout --dry-run "$PACKAGE_DIR" "$TARGET_DIR"
after=$(tree_checksum "$TARGET_DIR")

assert_exit 0 "$STATUS" "a dry run exits 0"
assert_eq "$before" "$after" "the target tree is unchanged by --dry-run"
assert_contains "$OUT" "dry run" "the log identifies itself as a dry run"

sandbox_clean
echo "ok"
