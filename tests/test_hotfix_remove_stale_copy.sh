#!/usr/bin/env bash
# TYPE=hotfix: a package that REMOVEs an asset also drops the build file's copy
# entry that still names it. The copy entries carry failonerror, so an entry
# left pointing at a removed file would stop the build.
#
# The rule is narrow. An entry goes only when its source is gone AND this run
# REMOVEs exactly that file. An entry for a file the package never mentions
# stays, even when the file is absent. A dry run says it would drop the entry
# and writes nothing, and a second apply changes nothing.
set -u
. "$(dirname "$0")/lib/harness.sh"
sandbox_new
write_conf "TYPE=hotfix"

refs="$TARGET_DIR/webclient"
mkdir -p "$refs/deploy/web" "$refs/patches/demo/css" "$refs/patches/old/css" "$refs/patches/demo/util"

cat > "$refs/build.xml" <<'XML'
<project name="webclient" default="build">
    <property name="configFile" value="patch.xml"/>
    <property name="customerWebDir" value="${env.REFSDIR}/web/customer"/>
    <target name="build-web-app-assets">
        <mkdir dir="${customerWebDir}"/>
        <copy file="./patches/old/css/old.css"
              tofile="${customerWebDir}/old.css"
              overwrite="true"
              failonerror="true"/>
        <copy file="./patches/demo/css/keep.css"
              tofile="${customerWebDir}/keep.css"
              overwrite="true"
              failonerror="true"/>
        <copy file="./patches/demo/css/ghost.css"
              tofile="${customerWebDir}/ghost.css"
              overwrite="true"
              failonerror="true"/>
    </target>
</project>
XML
cat > "$refs/patch.xml" <<'XML'
<project name="patch" default="deploy">
    <target name="load-target" type="load">
        <include name="deploy/web"/>
    </target>
    <target name="demo" type="bundle" source-dir="patches">
        <include name="demo/util/existing.mcmd"/>
    </target>
</project>
XML
echo "old"   > "$refs/patches/old/css/old.css"
echo "keep"  > "$refs/patches/demo/css/keep.css"
# ghost.css has an entry but no file, and the package says nothing about it.

mkdir -p "$PACKAGE_DIR/pkg/demo/css"
echo "new" > "$PACKAGE_DIR/pkg/demo/css/new.css"
{
    printf 'REPLACE pkg/demo/css/new.css $LESDIR/webclient/demo/css/new.css\n'
    printf 'REMOVE $LESDIR/webclient/old/css/old.css\n'
} > "$PACKAGE_DIR/package"

before=$(tree_checksum "$TARGET_DIR")
run_rollout --dry-run "$PACKAGE_DIR" "$TARGET_DIR"
assert_exit 0 "$STATUS" "the dry run exits 0"
assert_contains "$OUT" "would remove 1 copy entr" "the dry run announces the entry it would drop"
assert_eq "$before" "$(tree_checksum "$TARGET_DIR")" "the dry run leaves the tree untouched"

run_rollout "$PACKAGE_DIR" "$TARGET_DIR"
assert_exit 0 "$STATUS" "the apply exits 0"
assert_file_absent "$refs/patches/old/css/old.css" "the REMOVE deleted the file"
assert_contains "$OUT" "removed 1 copy entr" "the apply reports the entry it dropped"
build=$(cat "$refs/build.xml")
assert_not_contains "$build" "patches/old/css/old.css" "the copy entry for the removed file is gone"
assert_not_contains "$build" "tofile=\"\${customerWebDir}/old.css\"" "the removed entry's tofile line went with it"
assert_contains "$build" "patches/demo/css/keep.css" "an entry for a file that still exists stays"
assert_contains "$build" "patches/demo/css/ghost.css" "an absent file the package never names keeps its entry"
assert_contains "$build" "patches/demo/css/new.css" "the delivered asset is registered"

after_first=$(tree_checksum "$TARGET_DIR")
run_rollout "$PACKAGE_DIR" "$TARGET_DIR"
assert_exit 0 "$STATUS" "the second apply exits 0"
assert_eq "$after_first" "$(tree_checksum "$TARGET_DIR")" "a second apply changes nothing"

sandbox_clean
echo "ok"
