#!/usr/bin/env bash
# TYPE=hotfix's signature behavior: a manifest path that no longer matches
# the target's layout is corrected against conventions the target itself
# declares (its patch config and build file), not taken literally.
#
# The fixture is a minimal but real Ant-shaped build file + patch config,
# read by lib/xml.sh exactly as a real one would be.
set -u
. "$(dirname "$0")/lib/harness.sh"
sandbox_new
write_conf "TYPE=hotfix"

refs="$TARGET_DIR/webclient"
mkdir -p "$refs/deploy/web" "$refs/patches/demo/util"

cat > "$refs/build.xml" <<'EOF'
<project name="webclient" default="deploy">
    <property name="configFile" value="patch.xml"/>
    <target name="build-web-app-assets">
        <mkdir dir="${appWebDir}"/>
    </target>
</project>
EOF
cat > "$refs/patch.xml" <<'EOF'
<project name="patch" default="deploy">
    <target name="load-target" type="load">
        <include name="deploy/web"/>
    </target>
    <target name="demo" type="bundle" source-dir="patches">
        <include name="demo/util/existing.mcmd"/>
    </target>
</project>
EOF

mkdir -p "$PACKAGE_DIR/pkg/demo/util"
echo "payload" > "$PACKAGE_DIR/pkg/demo/util/newfile.js"
# The manifest names a plain LESDIR-relative path under webclient. Nothing
# about it says "this belongs to the demo patch's source tree" except its
# own shape -- <patch>/<kind>/<rest> -- matched against what patch.xml
# declares as a source kind ("util").
printf 'REPLACE pkg/demo/util/newfile.js $LESDIR/webclient/demo/util/newfile.js\n' \
    > "$PACKAGE_DIR/package"

run_rollout "$PACKAGE_DIR" "$TARGET_DIR"

assert_exit 0 "$STATUS" "the hotfix apply exits 0"
assert_contains "$OUT" "patch-source" "the run reports the patch-source correction rule"
assert_file_exists "$refs/patches/demo/util/newfile.js" \
    "the file lands in the declared patch source tree, not the manifest's literal path"
assert_file_absent "$TARGET_DIR/demo/util/newfile.js" \
    "the uncorrected literal destination was never created"

sandbox_clean
echo "ok"
