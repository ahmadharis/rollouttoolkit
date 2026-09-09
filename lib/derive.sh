#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# derive -- destination facts, read once from the TARGET repository.
#
# Never from an external artifact, never from a setting. A platform rename is
# therefore followed without touching apply-rollout.conf.
#
# A fact that cannot be derived is ABSENT, not fatal. Every convention checks
# for its fact and stands down when it is missing, so an unfamiliar target
# degrades to manifest-only resolution rather than failing or guessing.
#
# Author: Haris Ahmad -- Smart IS
# ---------------------------------------------------------------------------

D_REFS_ROOT=""          # dir holding the shared patch config + build file
D_PATCH_CONFIG=""       # that patch config's path
D_BUILD_FILE=""         # that build file's path
D_PATCH_SRC=""          # patch source tree (absolute)
D_DEPLOY_DIR=""         # refs root + /deploy
D_DEPLOY_KINDS=""       # space-separated, declared by the load target
D_DEPLOY_KINDS_DISK=""  # space-separated, present on disk
D_ASSET_KINDS=""        # space-separated, kinds the build file copies out of
D_SOURCE_KINDS=""       # space-separated, kinds the config's includes read from
D_BUNDLE_TARGETS=""     # space-separated, declared bundle target names
D_COPY_DEST_PROP=""     # the ${...} expression existing copy entries write to
D_WEB_APP=""            # basename of the directory those copies land in
D_INCLUDE_SEP="/"       # separator the existing include entries use
D_UPGRADE_PARENT=""     # dir holding version-named subdirectories
D_UPGRADE_VERSION=""    # highest version present there
D_PATCH_NAMES=""        # space-separated, patches the target already knows
D_WEB_SEG=""            # manifest segment naming the DEPLOYED web tree
D_DDL_ROOT=""           # dir holding the schema subdirectories (ddl.sh)

# The segment between a patch config's js-directory and a patch directory:
#
#     <js-dir>/<D_PATCH_SUBDIR>/<patch>/<kind>/<file>
#
# Fixed, and consulted ONLY to write a bundle target the destination does not
# declare -- after every target has been undone, or for an application this
# destination has never carried. Wherever a source-directory IS declared it is
# read from there and this is not used, so a destination that disagrees is
# followed rather than overridden.
D_PATCH_SUBDIR="patches"



# ---------------------------------------------------------------------------
# list_has <list> <word>  -- word-membership test on a space-separated list.
# ---------------------------------------------------------------------------
list_has() {
    case " $1 " in
        *" $2 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# list_add <listvar> <word> -- append when not already present.
list_add() {
    local cur=${!1}
    list_has "$cur" "$2" && return 0
    eval "$1=\"\${cur:+\$cur }\$2\""
}

# ---------------------------------------------------------------------------
# split_lines <newline-separated-string> -> $SPLIT[]
#
# Splitting with a locally-scoped IFS and then unsetting it is fragile in bash
# 3.2 (unset on a local can expose the global). Save and restore explicitly.
# set -f guards a literal glob character in a path.
# ---------------------------------------------------------------------------
split_lines() {
    local oldifs=$IFS
    IFS='
'
    set -f
    set -- $1
    set +f
    IFS=$oldifs
    SPLIT=( "$@" )
}

# ---------------------------------------------------------------------------
# derive_refs_root
#
# The refs root is the directory holding the shared patch config and build
# file. Located by SHAPE, not by name: a build file declaring a configFile that
# exists beside it. Nothing is hardcoded, so a renamed platform tree is found.
#
# A repository can hold more than one such pair -- a platform tree typically
# has one per application. They are told apart by what they DECLARE, again not
# by name:
#
#   +2  the directory carries a deploy tree
#   +2  its config's load target declares deploy kinds
#   +1  its config declares at least one named bundle target
#
# The highest score wins; every candidate and its score is logged, so the
# choice is auditable rather than dependent on directory-walk order. When
# nothing scores, the first found is used and that is stated plainly.
# ---------------------------------------------------------------------------
score_refs_candidate() {
    local dir=$1 cfg=$2 score=0 i n

    [ -d "$dir/deploy" ] && score=$((score + 2))

    if xml_read_patch_config "$cfg" >/dev/null 2>&1; then
        arr_count ${PC_TGT_NAME[@]+"${PC_TGT_NAME[@]}"}; i=0; n=$ARR_COUNT
        while [ "$i" -lt "$n" ]; do
            if [ "${PC_TGT_TYPE[$i]}" = "load" ]; then
                case ${PC_TGT_INC[$i]} in
                    *deploy/*|*deploy\\*) score=$((score + 2)) ;;
                esac
            elif [ -n "${PC_TGT_NAME[$i]}" ] && [ -n "${PC_TGT_INC[$i]}" ]; then
                score=$((score + 1))
            fi
            i=$((i + 1))
        done
    fi
    REFS_SCORE=$score
}

derive_refs_root() {
    local candidates bf dir cfg best=-1 first=""

    # One spawn, in stage 2 only -- never in the per-directive loop.
    candidates=$(find "$TARGET_DIR" -name .git -prune -o -type f -name 'build.xml' -print 2>/dev/null)
    [ -n "$candidates" ] || return 1

    split_lines "$candidates"
    for bf in ${SPLIT[@]+"${SPLIT[@]}"}; do
        [ -n "$bf" ] || continue
        path_dir "$bf"; dir=$PATH_DIR

        xml_read_build "$bf" >/dev/null 2>&1
        xp_get "configFile" || continue
        cfg=$XP_GOT
        [ -n "$cfg" ] && [ -f "$dir/$cfg" ] || continue

        [ -n "$first" ] || first=$dir
        score_refs_candidate "$dir" "$dir/$cfg"
        log_info "derive: refs-root candidate (score $REFS_SCORE): $dir"

        if [ "$REFS_SCORE" -gt "$best" ]; then
            best=$REFS_SCORE
            D_REFS_ROOT=$dir
            D_BUILD_FILE=$bf
            D_PATCH_CONFIG="$dir/$cfg"
        fi
    done

    [ -n "$D_REFS_ROOT" ] || return 1
    if [ "$best" -le 0 ]; then
        log_warn "derive: no refs-root candidate declares a deploy tree or bundle target; using the first found: $first"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# derive_from_patch_config
#
# Patch source tree, bundle target names, source kinds, valid deploy kinds and
# the separator style the existing include entries use.
# ---------------------------------------------------------------------------
derive_from_patch_config() {
    [ -n "$D_PATCH_CONFIG" ] || return 1
    xml_read_patch_config "$D_PATCH_CONFIG" || return 1

    local i=0 n inc rest kind
    arr_count ${PC_TGT_NAME[@]+"${PC_TGT_NAME[@]}"}; n=$ARR_COUNT
    while [ "$i" -lt "$n" ]; do
        local name=${PC_TGT_NAME[$i]} type=${PC_TGT_TYPE[$i]} src=${PC_TGT_SRCDIR[$i]}

        if [ "$type" = "load" ]; then
            # Valid deploy kinds: the load target's "deploy/<kind>" includes.
            split_lines "${PC_TGT_INC[$i]}"
            for inc in ${SPLIT[@]+"${SPLIT[@]}"}; do
                case $inc in
                    deploy/*|deploy\\*)
                        rest=${inc#deploy}; rest=${rest#/}; rest=${rest#\\}
                        kind=${rest%%[/\\]*}
                        [ -n "$kind" ] && list_add D_DEPLOY_KINDS "$kind"
                        ;;
                esac
            done
        elif [ -n "$name" ]; then
            list_add D_BUNDLE_TARGETS "$name"

            # The patch source tree: source-dir resolved against the refs root.
            if [ -z "$D_PATCH_SRC" ] && [ -n "$src" ]; then
                if is_abs "$src"; then
                    normalize_path "$src"
                else
                    normalize_path "$D_REFS_ROOT/$src"
                fi
                D_PATCH_SRC=$NORMALIZED
            fi

            # Source kinds: "<patch><sep><kind><sep><file>" -- kind is segment 2.
            split_lines "${PC_TGT_INC[$i]}"
            for inc in ${SPLIT[@]+"${SPLIT[@]}"}; do
                case $inc in
                    *\\*) D_INCLUDE_SEP="\\" ;;
                esac
                local flat=${inc//\\//}
                case $flat in
                    */*/*) kind=${flat#*/}; kind=${kind%%/*}
                           [ -n "$kind" ] && list_add D_SOURCE_KINDS "$kind"
                           list_add D_PATCH_NAMES "${flat%%/*}" ;;
                    */*)   list_add D_PATCH_NAMES "${flat%%/*}" ;;
                esac
            done
        fi
        i=$((i + 1))
    done

    # No bundle target survived to declare the patch source tree -- either every
    # one has been undone, or this destination has never carried the application
    # the package introduces. Fall back to the configured segment, one level
    # under this document's own js-directory. The js-directory itself is still
    # READ, from the project header, which is base structure and is never
    # removed; only the segment below it is fixed.
    #
    # Without this, undo deletes the only line stating where patch sources live
    # and the next apply has nothing to resolve against -- it degrades to
    # manifest-only placement while reporting success. That is the one-way door
    # this fallback closes.
    if [ -z "$D_PATCH_SRC" ]; then
        xml_expand '${js-dir}'
        case $XML_EXPANDED in
            ""|'${js-dir}') : ;;                  # header declares no js-dir
            *)
                if is_abs "$XML_EXPANDED"; then
                    normalize_path "$XML_EXPANDED/$D_PATCH_SUBDIR"
                else
                    normalize_path "$D_REFS_ROOT/$XML_EXPANDED/$D_PATCH_SUBDIR"
                fi
                D_PATCH_SRC=$NORMALIZED
                ;;
        esac
    fi

    D_DEPLOY_DIR="$D_REFS_ROOT/deploy"

    # Fallback and cross-check: what is actually on disk under the deploy tree.
    if [ -d "$D_DEPLOY_DIR" ]; then
        local d
        for d in "$D_DEPLOY_DIR"/*/; do
            [ -d "$d" ] || continue
            d=${d%/}; list_add D_DEPLOY_KINDS_DISK "${d##*/}"
        done
    fi
    # "the kinds the load target declares, ELSE the directories present"
    [ -n "$D_DEPLOY_KINDS" ] || D_DEPLOY_KINDS=$D_DEPLOY_KINDS_DISK

    return 0
}

# ---------------------------------------------------------------------------
# derive_from_build_file
#
# Asset kinds and the destination expression merged copy entries must adopt.
# ---------------------------------------------------------------------------
derive_from_build_file() {
    [ -n "$D_BUILD_FILE" ] || return 1
    xml_read_build "$D_BUILD_FILE" || return 1

    local i=0 n src to rest kind prop
    arr_count ${BF_COPY_FILE[@]+"${BF_COPY_FILE[@]}"}; n=$ARR_COUNT
    while [ "$i" -lt "$n" ]; do
        src=${BF_COPY_FILE[$i]}
        to=${BF_COPY_TO[$i]}

        # Asset kind: the segment after the patch name, under the source tree.
        if [ -n "$src" ] && [ -n "$D_PATCH_SRC" ]; then
            local abs
            if is_abs "$src"; then abs=$src; else normalize_path "$D_REFS_ROOT/$src"; abs=$NORMALIZED; fi
            case $abs in
                "$D_PATCH_SRC"/*)
                    rest=${abs#"$D_PATCH_SRC"/}     # <patch>/<kind>/<file>
                    case $rest in
                        */*/*) kind=${rest#*/}; kind=${kind%%/*}
                               [ -n "$kind" ] && list_add D_ASSET_KINDS "$kind"
                               list_add D_PATCH_NAMES "${rest%%/*}" ;;
                    esac
                    ;;
            esac
        fi

        # Copy destination property: the ${...} the existing entries write to.
        if [ -z "$D_COPY_DEST_PROP" ]; then
            case $to in
                '${'*'}'*) prop=${to#'${'}; prop=${prop%%'}'*}
                           [ -n "$prop" ] && D_COPY_DEST_PROP="\${$prop}" ;;
            esac
        fi
        i=$((i + 1))
    done

    # No copy entry survived to declare where assets land. The target that
    # holds them still says so, and that line is base structure:
    #
    #   <target name="build-web-app-assets" ...>
    #     <mkdir dir="${appWebDir}" />              <-- never removed
    #
    # Same one-way door as the patch source tree: undo takes the last copy
    # entry and, with it, the only other statement of the destination property.
    [ -n "$D_COPY_DEST_PROP" ] || derive_copy_dest_from_mkdir "$D_BUILD_FILE"

    # The web application the assets are deployed INTO, as a plain name.
    #
    # A deploy bundle names its scripts "<web-app>/<file>", and a package writes
    # its own patch there because it deploys each patch separately. A
    # destination consolidating several patches into one application needs that
    # segment retargeted (bundle.sh), and the answer is the basename of the
    # directory the copy entries already write to. The leading ${env...} stays
    # unexpanded -- it is an environment property, not a document one -- which
    # does not matter, because only the last segment is wanted.
    if [ -z "$D_WEB_APP" ] && [ -n "$D_COPY_DEST_PROP" ]; then
        xml_expand "$D_COPY_DEST_PROP"
        case $XML_EXPANDED in
            */*) D_WEB_APP=${XML_EXPANDED##*/} ;;
        esac
    fi

    derive_web_seg || :
    return 0
}

# ---------------------------------------------------------------------------
# derive_copy_dest_from_mkdir <build-file>
#
# The first <mkdir dir="${...}"/> in the document, as a property expression.
#
# The expression is kept, not what it expands to: a merged entry must adopt the
# destination's own vocabulary rather than a resolved path (SPEC.md 6.3).
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# derive_from_package
#
# Fill the kind vocabulary from the PACKAGE payload when the destination
# declares none. Runs in stage 2, and it has to: the planner seeds the patch
# names by splitting each directive on a known kind (find_kind_split), so a
# vocabulary that arrives any later arrives after every decision that needs it.
#
# On a destination whose targets have all been undone -- or one that has never
# carried the app a rollout introduces -- the kinds are exactly what is
# missing. Without them nothing splits, no patch name is seeded, the patch-root
# shared files are not recognised as shared, and the run copies build.xml and
# the patch config into the tree as ordinary files instead of merging them.
#
# One find, once per run, outside the per-directive loop (CLAUDE.md).
# The destination always wins; this only fills silence.
# ---------------------------------------------------------------------------
derive_from_package() {
    [ -n "$PACKAGE_DIR" ] && [ -d "$PACKAGE_DIR/pkg" ] || return 0

    # Decide ONCE whether the destination is silent, then accumulate across
    # EVERY config the package ships. A package delivers more than one patch --
    # this one ships two, and their kinds do not agree: one declares "utility",
    # the other "util". Stopping as soon as a list became non-empty took only
    # the first patch's vocabulary, so "util" was never a known kind and both
    # files under it fell through to manifest placement, landing in the patch
    # root instead of the patch source tree.
    SEED_ASSETS=0; SEED_SOURCES=0
    [ -z "$D_ASSET_KINDS" ]  && SEED_ASSETS=1
    [ -z "$D_SOURCE_KINDS" ] && SEED_SOURCES=1
    [ "$SEED_ASSETS" -eq 1 ] || [ "$SEED_SOURCES" -eq 1 ] || return 0

    local f dir base
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        dir=${f%/*}; base=${dir##*/}
        if [ "${f##*/}" = "build.xml" ]; then
            seed_kinds_from_package "$f" ""
        elif [ "${f##*/}" = "$base.xml" ]; then
            seed_kinds_from_package "" "$f"
        fi
    done <<EOF
$(find "$PACKAGE_DIR/pkg" -type f -name '*.xml' 2>/dev/null)
EOF

    [ "$SEED_ASSETS" -eq 1 ] && [ -n "$D_ASSET_KINDS" ] && \
        log_info "derive: asset kinds taken from the package: $D_ASSET_KINDS"
    [ "$SEED_SOURCES" -eq 1 ] && [ -n "$D_SOURCE_KINDS" ] && \
        log_info "derive: source kinds taken from the package: $D_SOURCE_KINDS"

    # Back to the emptiness test, so the stage 5 call behaves as before.
    SEED_ASSETS=0; SEED_SOURCES=0
    return 0
}

derive_copy_dest_from_mkdir() {
    local line prop
    [ -f "$1" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        strip_cr "$line"; line=$STRIPPED_CR
        case $line in
            *'<mkdir'*) ;;
            *) continue ;;
        esac
        xml_line_attr "$line" "dir" || continue
        case $XML_ATTR_VALUE in
            '${'*'}'*)
                prop=${XML_ATTR_VALUE#'${'}; prop=${prop%%'}'*}
                if [ -n "$prop" ]; then
                    D_COPY_DEST_PROP="\${$prop}"
                    return 0
                fi
                ;;
        esac
    done <"$1"
    return 1
}

# ---------------------------------------------------------------------------
# derive_web_seg
#
# The manifest segment naming the DEPLOYED web tree (SPEC.md 5) -- build output
# plus copies of source assets, both reproducible, neither belonging in the
# repository. Every directive landing under it is skipped.
#
# This is a SEGMENT NAME, not a path, and that is deliberate. The manifests'
# $REFSDIR is a virtual root: its deploy subtree and its web subtree live in
# different real directories, so no single filesystem path stands behind it.
# SPEC.md 5 accordingly decides the skip "from the manifest alone" -- and since
# nothing is ever written there, the real location is never needed.
#
# Derived from the build file's own copy destination rather than assumed: the
# expression is "<${refsdir-ref}>/<segment>/<app>", so the segment is the first
# component after the leading property reference. A platform that renames the
# tree is followed without a code change.
# ---------------------------------------------------------------------------
derive_web_seg() {
    local rest

    if [ -n "$D_COPY_DEST_PROP" ]; then
        # Expand one level only: the leading ${env.REFSDIR} must stay a
        # reference, because it has no filesystem value here.
        xml_expand "$D_COPY_DEST_PROP"
        rest=$XML_EXPANDED
        case $rest in
            '${'*'}'/*)
                rest=${rest#*'}'}; rest=${rest#/}
                D_WEB_SEG=${rest%%/*}
                [ -n "$D_WEB_SEG" ] && return 0
                ;;
        esac
    fi

    log_warn "derive: the build file does not name a deployed web tree; no directive will be skipped as build output"
    return 1
}

# ---------------------------------------------------------------------------
# derive_upgrade_dir
#
# The upgrade parent is a directory whose immediate subdirectories are ALL
# version-named, and the version is the highest present. Shape again, not a
# name -- so a target that calls the directory something else still works.
# ---------------------------------------------------------------------------
derive_upgrade_dir() {
    local found parent sub kids vers all_versions

    # Go straight at the version-named directories rather than walking every
    # directory in the target and globbing each one.
    found=$(find "$TARGET_DIR" -name .git -prune -o -type d -name '[0-9]*.[0-9]*' -print 2>/dev/null)
    [ -n "$found" ] || return 1

    split_lines "$found"
    local cand candidates=""
    for cand in ${SPLIT[@]+"${SPLIT[@]}"}; do
        [ -n "$cand" ] || continue
        path_dir "$cand"
        list_add candidates "$PATH_DIR"
    done

    for parent in $candidates; do
        # Qualify only when EVERY immediate subdirectory is version-named.
        kids=0; vers=0
        for sub in "$parent"/*/; do
            [ -d "$sub" ] || continue
            sub=${sub%/}; sub=${sub##*/}
            kids=$((kids + 1))
            case $sub in
                [0-9]*.[0-9]*) vers=$((vers + 1)) ;;
            esac
        done
        [ "$kids" -gt 0 ] && [ "$kids" -eq "$vers" ] || continue
        if [ -n "$D_UPGRADE_PARENT" ]; then
            log_warn "derive: a second candidate upgrade parent was found and ignored: $parent"
            continue
        fi
        D_UPGRADE_PARENT=$parent
    done

    [ -n "$D_UPGRADE_PARENT" ] || return 1

    all_versions=""
    for sub in "$D_UPGRADE_PARENT"/*/; do
        [ -d "$sub" ] || continue
        sub=${sub%/}
        all_versions="$all_versions${sub##*/}
"
    done
    # sort -V is GNU-only; a numeric field sort is portable and enough here.
    D_UPGRADE_VERSION=$(printf '%s' "$all_versions" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1)
    [ -n "$D_UPGRADE_VERSION" ]
}

# ---------------------------------------------------------------------------
# derive_facts -- run every derivation and report the outcome to the log.
# ---------------------------------------------------------------------------
derive_facts() {
    if derive_refs_root; then
        derive_from_patch_config || log_warn "derive: patch config unreadable: $D_PATCH_CONFIG"
        derive_from_build_file  || log_warn "derive: build file unreadable: $D_BUILD_FILE"
    fi
    derive_upgrade_dir >/dev/null 2>&1 || :
    # The ddl root is NOT derived here: a package commonly creates the tree
    # itself, so in stage 2 there is nothing to find. promote_ddl recognises
    # its files from the resolved path instead (SPEC.md 7A.1).
    return 0
}

# ---------------------------------------------------------------------------
# log_facts -- echo the derived facts into the run banner, so a dry run is a
# complete audit of what would happen AND why.
# ---------------------------------------------------------------------------
log_facts() {
    local none="<not derived -- convention stands down>"
    log_info "  refs root      : ${D_REFS_ROOT:-$none}"
    log_info "  patch config   : ${D_PATCH_CONFIG:-$none}"
    log_info "  build file     : ${D_BUILD_FILE:-$none}"
    log_info "  patch sources  : ${D_PATCH_SRC:-$none}"
    log_info "  deploy tree    : ${D_DEPLOY_DIR:-$none}"
    log_info "  deploy kinds   : ${D_DEPLOY_KINDS:-$none}"
    log_info "  asset kinds    : ${D_ASSET_KINDS:-$none}"
    log_info "  source kinds   : ${D_SOURCE_KINDS:-$none}"
    log_info "  bundle targets : ${D_BUNDLE_TARGETS:-$none}"
    log_info "  copy dest prop : ${D_COPY_DEST_PROP:-$none}"
    if [ "$D_INCLUDE_SEP" = "\\" ]; then
        log_info "  include sep    : backslash"
    else
        log_info "  include sep    : forward slash"
    fi
    log_info "  patches known  : ${D_PATCH_NAMES:-$none}"
    if [ -n "$D_WEB_SEG" ]; then
        log_info "  deployed web   : \$<var>/$D_WEB_SEG/...  (skipped -- build output)"
    else
        log_info "  deployed web   : $none"
    fi
    log_info "  upgrade dir    : ${D_UPGRADE_PARENT:-$none}"
    log_info "  upgrade version: ${D_UPGRADE_VERSION:-$none}"
    log_info "  ddl root       : from the resolved path (the package may create it)"

    # Surface a declared/on-disk discrepancy: a kind present but undeclared is
    # not treated as valid (SPEC.md 3.2 says declared wins), and a reader has
    # to be able to see that from the log.
    # A kind present but undeclared is not treated as valid (SPEC.md 3.2: the
    # declaration wins). Distinguish a PLACEHOLDER -- a directory holding only
    # a README, which the platform keeps as a marker -- from one holding real
    # content, which is a genuine discrepancy a reader needs to see.
    local k f content
    for k in $D_DEPLOY_KINDS_DISK; do
        list_has "$D_DEPLOY_KINDS" "$k" && continue
        content=0
        for f in "$D_DEPLOY_DIR/$k"/*; do
            [ -e "$f" ] || continue
            case ${f##*/} in README|README.*) continue ;; esac
            content=1; break
        done
        if [ "$content" -eq 1 ]; then
            log_warn "derive: deploy kind '$k' holds content but is not declared by the load target; directives naming it are treated as retired"
        else
            log_info "derive: deploy kind '$k' is an empty placeholder and is not declared; ignored"
        fi
    done
}
