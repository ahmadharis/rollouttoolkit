#!/usr/bin/env bash
# Two directives resolving to the same destination must be REPORTED, never
# silently resolved by picking a winner.
set -u
. "$(dirname "$0")/lib/harness.sh"
sandbox_new

mkdir -p "$PACKAGE_DIR/pkg"
echo "one" > "$PACKAGE_DIR/pkg/one.txt"
echo "two" > "$PACKAGE_DIR/pkg/two.txt"
{
    printf 'REPLACE pkg/one.txt $LESDIR/some/path/shared.txt\n'
    printf 'REPLACE pkg/two.txt $LESDIR/some/path/shared.txt\n'
} > "$PACKAGE_DIR/package"

run_rollout "$PACKAGE_DIR" "$TARGET_DIR"

assert_contains "$OUT" "claimed twice" "the collision is reported in the tallies"
assert_contains "$OUT" "collision: package:1" "the exceptions summary names the first colliding directive"
assert_contains "$OUT" "collision: package:2" "the exceptions summary names the second colliding directive"

sandbox_clean
echo "ok"
