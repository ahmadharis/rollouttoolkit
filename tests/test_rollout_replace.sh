#!/usr/bin/env bash
# TYPE=rollout (the default -- no settings file at all): a $VAR-prefixed
# manifest path is substituted and appended verbatim, with no correction.
set -u
. "$(dirname "$0")/lib/harness.sh"
sandbox_new

mkdir -p "$PACKAGE_DIR/pkg"
echo "hello" > "$PACKAGE_DIR/pkg/hello.txt"
printf 'REPLACE pkg/hello.txt $LESDIR/some/path/hello.txt\n' > "$PACKAGE_DIR/package"

run_rollout "$PACKAGE_DIR" "$TARGET_DIR"

assert_exit 0 "$STATUS" "a clean rollout apply exits 0"
assert_file_exists "$TARGET_DIR/some/path/hello.txt" "the file lands exactly where the manifest said"
assert_eq "hello" "$(cat "$TARGET_DIR/some/path/hello.txt")" "content is copied verbatim"

sandbox_clean
echo "ok"
