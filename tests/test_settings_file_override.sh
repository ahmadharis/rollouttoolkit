#!/usr/bin/env bash
# ROLLOUT_SETTINGS_FILE overrides where the settings file is read from,
# without disturbing the default (beside the script) when unset. This is
# what lets a shared copy of the tool run on behalf of a target that carries
# its own apply-rollout.conf somewhere else.
set -u
. "$(dirname "$0")/lib/harness.sh"
sandbox_new

base="$TARGET_DIR/app/data/load"
mkdir -p "$base/sample_table" "$TARGET_DIR/app/upgrade/1.0.0"
cat > "$base/sample_table.ctl" <<'EOF'
publish data
where table = 'sample_table'
EOF
printf 'id,name\n1,alpha\n' > "$base/sample_table/one.csv"

# An override pointing at a file that doesn't exist degrades to unchanged
# behaviour, same as the default does when apply-rollout.conf is absent.
# (export, not a prefix assignment -- run_rollout is a shell function, and a
# prefix assignment on a function call never reaches the subprocess it execs.)
export ROLLOUT_SETTINGS_FILE="$SANDBOX/nowhere.conf"
run_rollout --combine "$base" --folders sample_table
assert_exit 0 "$STATUS" "a missing override file degrades to default behaviour"
assert_contains "$OUT" "settings         : none (defaults; no file at $SANDBOX/nowhere.conf)" \
    "the banner reports the overridden path"

# An override pointing at a real file is actually read.
override="$SANDBOX/custom.conf"
printf 'TYPE=hotfix\nCOMBINE_EXCLUDE=sample_table\n' > "$override"
export ROLLOUT_SETTINGS_FILE="$override"
run_rollout --combine "$base" --folders sample_table
assert_exit 0 "$STATUS" "a real override file is read without error"
assert_contains "$OUT" "settings         : $override" "the banner reports the overridden path"
assert_contains "$OUT" "explicitly ignored: sample_table" "the overridden COMBINE_EXCLUDE took effect"
unset ROLLOUT_SETTINGS_FILE

sandbox_clean
echo "ok"
