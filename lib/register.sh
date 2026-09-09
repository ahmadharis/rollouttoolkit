#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# register -- make a placed file take effect.
#
# A file placed in the patch source tree is INERT until it is registered.
# Neither shared file errors on an unregistered source; the build simply omits
# it. This module edits the shared files so a delivered source is built.
#
#   asset kind                       -> build file, as a copy entry
#   source kind, and the patch root  -> patch config, as an include
#   anything else                    -> neither; skipped and logged
#
# Patch and kind come from the path; the bundle target comes from the patch.
# Nothing is looked up by application name.
#
# This module decides WHAT belongs in a segment. The mechanics of locating and
# replacing one live in splice.sh, which knows nothing about patches or kinds.
# Other patches' entries and all surrounding infrastructure stay byte-identical;
# the file is never re-serialised, which would reformat regions this tool does
# not own.
#
# Author: Haris Ahmad -- Smart IS
# ---------------------------------------------------------------------------

REG_CHANGES=0
REG_WARNINGS=0


# ---------------------------------------------------------------------------
# to_target_include <patch> <package-include>
#
# Translate an include from the PACKAGE's vocabulary into the TARGET's.
#
# The package config's source-dir is the patch root, so it declares an include
# relative to that root -- "<kind>/<File>.js". The target's source-dir is the
# directory ABOVE the patches, so its entries are prefixed with the patch name
# and joined with the separator its existing entries use, which is derived
# rather than assumed.
# ---------------------------------------------------------------------------
to_target_include() {
    local patch=$1 inc=$2 flat seg out=""
    flat=${inc//\\//}
    # Packages are authored inconsistently -- one writes "store/MainStore.js",
    # another "/store/MainStore.js" for the same thing. Strip any leading
    # separator so both produce the same registered entry.
    while :; do
        case $flat in /*) flat=${flat#/} ;; *) break ;; esac
    done
    # An empty patch means the include is already patch-prefixed (it came from
    # a resolved destination rather than from the package's own config).
    [ -n "$patch" ] && flat="$patch/$flat"

    if [ "$D_INCLUDE_SEP" = "/" ]; then
        TARGET_INC=$flat
        return 0
    fi

    # Join explicitly rather than with ${flat//\//\\}: bash's handling of a
    # backslash in a replacement string is not consistent across versions, and
    # it produced a DOUBLED separator after the first segment -- which made the
    # duplicate check miss and re-added includes the target already had.
    while :; do
        case $flat in
            */*) seg=${flat%%/*}; flat=${flat#*/} ;;
            *)   seg=$flat; flat="" ;;
        esac
        [ -n "$seg" ] && out="${out:+$out$D_INCLUDE_SEP}$seg"
        [ -n "$flat" ] || break
    done
    TARGET_INC=$out
}

# include_path <target-include> -> $INC_PATH  (absolute path under the source tree)
include_path() {
    local flat=${1//\\//}
    INC_PATH="$D_PATCH_SRC/$flat"
}


# ---------------------------------------------------------------------------
# ships_include <package-list> <delivered-list> <entry>
#
# Does THIS package's rollout account for this entry -- either its own patch
# config declares it, or this run delivers the file it names?
#
# This is the guard on every drop. Without it a run reconciles the whole
# document against the tree, and a destination that declares includes for files
# which have never existed in the repository loses them all -- on APPLY as well
# as on undo. The build file and the patch config are shared property: this
# package edits its own lines and leaves every other one alone.
# ---------------------------------------------------------------------------
ships_include() {
    [ -n "$3" ] || return 1
    case "
$1
$2" in
        *"
$3
"*) return 0 ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# merge_includes <patch> <existing-list> <package-list> <delivered-list>
#   -> $MERGED (newline separated, target vocabulary)
#
# Include order IS load order, so entries are MERGED, never regenerated:
#
#   * existing entries keep their place and relative order
#   * new entries are inserted immediately BEFORE the trailing entry-point
#     include, which is last in every target
#   * an entry is dropped ONLY when THIS package accounts for the file and the
#     file is not there after the run -- see ships_include
#
# Touching only what the package accounts for is what makes the outcome
# order-independent: a small package cannot strip entries belonging to an
# earlier one, and it cannot strip a declaration that predates every package.
# ---------------------------------------------------------------------------
merge_includes() {
    local existing=$2 package=$3 delivered=$4
    local entry="" kept="" e p
    MERGED=""

    # What this package accounts for, kept intact: the two working copies below
    # are blanked on undo (nothing is being added), but the drop guard must
    # still know which entries are ours.
    local own_pkg=$package own_del=$delivered

    # the entry point is the last existing include (else the package's last)
    split_lines "$existing"
    local n; arr_count ${SPLIT[@]+"${SPLIT[@]}"}; n=$ARR_COUNT
    if [ "$n" -gt 0 ]; then entry=${SPLIT[$((n - 1))]}; fi
    if [ -z "$entry" ]; then
        split_lines "$package"
        arr_count ${SPLIT[@]+"${SPLIT[@]}"}; n=$ARR_COUNT
        [ "$n" -gt 0 ] && entry=${SPLIT[$((n - 1))]}
    fi

    # ---- reconcile THIS PACKAGE'S entries against the tree ------------------
    #
    # An entry is dropped only when both are true: this package accounts for it
    # (ships_include), and its file is not there after this run's file
    # operations. An entry the package knows nothing about is carried through
    # untouched however the tree looks -- it belongs to someone else.
    #
    # Order is what makes a rebuild safe, since include order IS load order:
    #
    #   1. surviving entries keep their existing relative order
    #   2. then whatever the package declares that is not registered yet,
    #      in the package's own declared order
    #   3. then anything delivered that nothing registers at all
    #   4. the entry point stays last
    #
    # Order therefore comes from the documents, never from the plan -- the plan
    # is in manifest order, which is alphabetical, and drawing from it re-sorted
    # the whole target on the first attempt.
    #
    # Deriving from the tree rather than from this package's own file list is
    # what keeps a small package from stripping an earlier one's entries: a file
    # another package delivered is still on disk, so it still survives.
    split_lines "$existing"
    for e in ${SPLIT[@]+"${SPLIT[@]}"}; do
        [ -n "$e" ] || continue
        [ "$e" = "$entry" ] && continue
        include_path "$e"
        if will_exist "$INC_PATH"; then
            kept="$kept$e
"
        elif ships_include "$own_pkg" "$own_del" "$e"; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log_warn "  register: would drop the include for a file this package removes: $e"
            else
                log_warn "  register: dropped the include for a file this package removes: $e"
            fi
            REG_CHANGES=$((REG_CHANGES + 1)); REG_WARNINGS=$((REG_WARNINGS + 1))
        else
            # Not ours. The file may never have existed here; that is between
            # the destination and whoever declared it.
            kept="$kept$e
"
        fi
    done

    # Add anything the package declares that is not registered yet.
    # Skipped while undoing: those entries are being reversed, not applied.
    [ "$UNDO" -eq 1 ] && package=""
    [ "$UNDO" -eq 1 ] && delivered=""
    split_lines "$package"
    for p in ${SPLIT[@]+"${SPLIT[@]}"}; do
        [ -n "$p" ] || continue
        [ "$p" = "$entry" ] && continue
        case "
$kept" in *"
$p
"*) continue ;; esac
        include_path "$p"
        will_exist "$INC_PATH" || continue
        kept="$kept$p
"
        if [ "$DRY_RUN" -eq 1 ]; then
            log_info "  register: would add an include from the package config: $p"
        else
            log_info "  register: adding include from the package config: $p"
        fi
        REG_CHANGES=$((REG_CHANGES + 1))
    done

    # auto-add anything delivered that nothing registers
    split_lines "$delivered"
    for p in ${SPLIT[@]+"${SPLIT[@]}"}; do
        [ -n "$p" ] || continue
        [ "$p" = "$entry" ] && continue
        case "
$kept" in *"
$p
"*) continue ;; esac
        include_path "$p"
        will_exist "$INC_PATH" || continue
        kept="$kept$p
"
        log_warn "  register: AUTO-ADDED an include for a delivered source nothing registered: $p"
        REG_CHANGES=$((REG_CHANGES + 1)); REG_WARNINGS=$((REG_WARNINGS + 1))
    done

    if [ -n "$entry" ]; then
        include_path "$entry"
        if will_exist "$INC_PATH"; then
            kept="$kept$entry
"
        else
            log_warn "  register: dropping stale entry-point include: $entry"
            REG_CHANGES=$((REG_CHANGES + 1)); REG_WARNINGS=$((REG_WARNINGS + 1))
        fi
    fi
    MERGED=$kept
}


# ---------------------------------------------------------------------------
# derive_copy_style <file>  -> $COPY_IND, $COPY_ATTR_IND, $COPY_SRC_PREFIX
#
# Match the formatting the build file already uses, rather than imposing one.
# ---------------------------------------------------------------------------
derive_copy_style() {
    local i=0 seen=0
    COPY_IND="    "; COPY_ATTR_IND="          "
    read_lines "$1" || return 1
    while [ "$i" -lt "${#RL[@]}" ]; do
        case ${RL[$i]} in
            *'<copy'*)
                if [ "$seen" -eq 0 ]; then
                    COPY_IND=${RL[$i]%%<*}
                    seen=1
                    case ${RL[$((i + 1))]} in
                        *tofile*) COPY_ATTR_IND=${RL[$((i + 1))]%%tofile*} ;;
                    esac
                fi
                ;;
        esac
        i=$((i + 1))
    done

    # The relative form the existing entries write their sources in. When none
    # survives -- every copy entry undone, or an app this destination has never
    # carried -- the written convention applies: "./" plus the patch source tree
    # relative to the refs root, which is the form this destination uses.
    local rel=${D_PATCH_SRC#"$D_REFS_ROOT"/}
    arr_count ${BF_COPY_FILE[@]+"${BF_COPY_FILE[@]}"}
    if [ "$seen" -eq 1 ] && [ "$ARR_COUNT" -gt 0 ]; then
        case ${BF_COPY_FILE[0]} in
            ./*) COPY_SRC_PREFIX="./$rel" ;;
            *)   COPY_SRC_PREFIX="$rel" ;;
        esac
    else
        COPY_SRC_PREFIX="./$rel"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# reconcile
#
# The driver. Derives everything it needs from the PLAN -- what was delivered,
# and which shared files the package shipped as inputs.
#
# Both this and consolidation derive from the FINAL STATE of the tree, not from
# the subset of files this package touched, which is why they run after every
# file operation and why they are idempotent.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# seed_kinds_from_package <package-build-file> <package-patch-config>
#
# Fill D_ASSET_KINDS / D_SOURCE_KINDS from the package when the DESTINATION
# declares none.
#
# These two lists are what separate an asset (a copy entry in the build file)
# from a source (an include in the patch config), and both are normally read
# out of the very entries stage 5 can remove. Once the last copy entry and the
# last include are gone, every delivered file classifies as "not a declared
# kind" and is registered nowhere -- so the next apply cannot put back what the
# undo took out.
#
# The package declares the same vocabulary: its <patch>/build.xml copies out of
# the asset kinds, its <patch>/<patch>.xml includes read from the source kinds.
#
# The destination ALWAYS wins where it has spoken. This only fills silence.
# ---------------------------------------------------------------------------
seed_kinds_from_package() {
    local pkg_build=$1 pkg_cfg=$2 i n inc flat kind

    if { [ "$SEED_ASSETS" -eq 1 ] || [ -z "$D_ASSET_KINDS" ]; } \
       && [ -n "$pkg_build" ] && [ -f "$pkg_build" ]; then
        if xml_read_build "$pkg_build"; then
            arr_count ${BF_COPY_FILE[@]+"${BF_COPY_FILE[@]}"}; i=0; n=$ARR_COUNT
            while [ "$i" -lt "$n" ]; do
                xml_expand "${BF_COPY_FILE[$i]}"
                # <...>/<kind>/<file> -- the segment above the basename
                flat=${XML_EXPANDED%/*}
                case $flat in
                    */*) kind=${flat##*/}
                         case $kind in
                             ""|'${'*) ;;          # unresolved property, not a kind
                             *) list_add D_ASSET_KINDS "$kind" ;;
                         esac ;;
                esac
                i=$((i + 1))
            done
        fi
    fi

    if { [ "$SEED_SOURCES" -eq 1 ] || [ -z "$D_SOURCE_KINDS" ]; } \
       && [ -n "$pkg_cfg" ] && [ -f "$pkg_cfg" ]; then
        if xml_read_patch_config "$pkg_cfg"; then
            arr_count ${PC_TGT_NAME[@]+"${PC_TGT_NAME[@]}"}; i=0; n=$ARR_COUNT
            while [ "$i" -lt "$n" ]; do
                if [ -n "${PC_TGT_NAME[$i]}" ] && [ "${PC_TGT_TYPE[$i]}" = "js" ]; then
                    split_lines "${PC_TGT_INC[$i]}"
                    for inc in ${SPLIT[@]+"${SPLIT[@]}"}; do
                        [ -n "$inc" ] || continue
                        flat=${inc//\\//}
                        flat=${flat#/}
                        case $flat in
                            */*) kind=${flat%%/*}
                                 [ -n "$kind" ] && list_add D_SOURCE_KINDS "$kind" ;;
                        esac
                    done
                fi
                i=$((i + 1))
            done
        fi
    fi
    return 0
}

reconcile() {
    local patches="" i=0 rel patch kind rest

    [ -n "$D_PATCH_SRC" ] && [ -n "$D_PATCH_CONFIG" ] || return 0

    # UNDO regenerates the sections THIS PACKAGE owns, and only those.
    #
    # Scoping is what makes it safe. Undo prunes the existing entry list in
    # place -- survivors keep their relative order -- and never injects from the
    # plan, whose order is the manifest's and therefore alphabetical. Rebuilding
    # from the plan re-sorted the survivors, and include order is load order.
    #
    # A section left with no includes is REMOVED outright: the patch's sources
    # are gone from the destination, so its bundle target has nothing to build.
    # Other patches' sections are never read or written (SPEC.md 6.5).

    # --- which patches did this run touch? --------------------------------
    while [ "$i" -lt "$P_COUNT" ]; do
        [ -n "${P_PATCH[$i]}" ] && list_add patches "${P_PATCH[$i]}"
        i=$((i + 1))
    done
    [ -n "$patches" ] || return 0

    log_head "registration"

    for patch in $patches; do
        local inc_delivered="" asset_delivered="" pkg_cfg="" pkg_build=""

        # The shared files FIRST, before anything is classified: the kinds that
        # tell an asset from a source are read out of the destination's copy
        # entries and includes, and undo can legitimately have removed the last
        # of both. The package declares the same kinds, so it can stand in --
        # but only after we know which files it ships.
        i=0
        while [ "$i" -lt "$P_COUNT" ]; do
            if [ "${P_PATCH[$i]}" = "$patch" ] && [ "${P_RULE[$i]}" = "$R_SHARED" ]; then
                case ${P_SOURCE[$i]##*/} in
                    build.xml) pkg_build="$PACKAGE_DIR/${P_SOURCE[$i]}" ;;
                    *)         pkg_cfg="$PACKAGE_DIR/${P_SOURCE[$i]}" ;;
                esac
            fi
            i=$((i + 1))
        done
        seed_kinds_from_package "$pkg_build" "$pkg_cfg"

        i=0
        while [ "$i" -lt "$P_COUNT" ]; do
            if [ "${P_PATCH[$i]}" = "$patch" ]; then
                case ${P_RULE[$i]} in
                    "$R_PATCH_SRC")
                        rel=${P_DEST[$i]#"$D_PATCH_SRC"/}
                        rest=${rel#*/}
                        if [ "$rest" = "$rel" ]; then
                            kind=""                       # patch-root file
                        else
                            kind=${rest%%/*}
                            [ "$kind" = "$rest" ] && kind=""
                        fi
                        if [ -n "$kind" ] && list_has "$D_ASSET_KINDS" "$kind"; then
                            asset_delivered="$asset_delivered$rel
"
                        elif [ -n "$kind" ] && list_has "$D_SOURCE_KINDS" "$kind"; then
                            to_target_include "" "$rel"; inc_delivered="$inc_delivered$TARGET_INC
"
                        elif [ -z "$kind" ]; then
                            case $rel in
                                *.js) to_target_include "" "$rel"; inc_delivered="$inc_delivered$TARGET_INC
" ;;
                                *) log_warn "  register: $patch: not a handled kind, registered nowhere: $rel" ;;
                            esac
                        else
                            log_warn "  register: $patch: '$kind' is not a declared kind, registered nowhere: $rel"
                        fi
                        ;;
                    "$R_SHARED")
                        case ${P_SOURCE[$i]##*/} in
                            build.xml) pkg_build="$PACKAGE_DIR/${P_SOURCE[$i]}" ;;
                            *)         pkg_cfg="$PACKAGE_DIR/${P_SOURCE[$i]}" ;;
                        esac
                        ;;
                esac
            fi
            i=$((i + 1))
        done

        register_includes "$patch" "$pkg_cfg" "$inc_delivered"
        register_assets   "$patch" "$pkg_build" "$asset_delivered"
    done

    if [ "$REG_CHANGES" -eq 0 ]; then
        log_info "  no registration change needed."
    else
        log_info "  registration changes: $REG_CHANGES ($REG_WARNINGS needing attention)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# register_includes <patch> <package-config> <delivered-includes>
# ---------------------------------------------------------------------------
register_includes() {
    local patch=$1 pkg_cfg=$2 delivered=$3
    local tname="" existing="" package="" srcdir="" inc i

    # the bundle target for this patch: named by the package's own config when
    # it ships one, otherwise the declared target whose includes name the patch
    if [ -n "$pkg_cfg" ] && [ -f "$pkg_cfg" ]; then
        if xml_read_patch_config "$pkg_cfg"; then
            i=0
            arr_count ${PC_TGT_NAME[@]+"${PC_TGT_NAME[@]}"}
            while [ "$i" -lt "$ARR_COUNT" ]; do
                if [ -n "${PC_TGT_NAME[$i]}" ]; then
                    tname=${PC_TGT_NAME[$i]}
                    split_lines "${PC_TGT_INC[$i]}"
                    for inc in ${SPLIT[@]+"${SPLIT[@]}"}; do
                        [ -n "$inc" ] || continue
                        to_target_include "$patch" "$inc"
                        package="$package$TARGET_INC
"
                    done
                    break
                fi
                i=$((i + 1))
            done
        fi
    fi

    xml_read_patch_config "$D_PATCH_CONFIG" || return 1
    i=0
    arr_count ${PC_TGT_NAME[@]+"${PC_TGT_NAME[@]}"}
    while [ "$i" -lt "$ARR_COUNT" ]; do
        if [ -n "${PC_TGT_NAME[$i]}" ] && [ "${PC_TGT_TYPE[$i]}" = "js" ]; then
            case "${PC_TGT_INC[$i]}" in
                "$patch"[/\\]*|*"
$patch"[/\\]*)
                    [ -n "$tname" ] || tname=${PC_TGT_NAME[$i]}
                    if [ "${PC_TGT_NAME[$i]}" = "$tname" ]; then
                        existing=${PC_TGT_INC[$i]}
                        srcdir=${PC_TGT_SRCDIR[$i]}
                    fi
                    ;;
            esac
        fi
        i=$((i + 1))
    done

    if [ -z "$tname" ]; then
        log_warn "  register: $patch: no bundle target could be identified; sources are placed but not registered"
        REG_WARNINGS=$((REG_WARNINGS + 1))
        return 1
    fi

    local before=$REG_CHANGES
    merge_includes "$patch" "$existing" "$package" "$delivered"
    [ "$REG_CHANGES" -eq "$before" ] && return 0

    if [ -z "$MERGED" ]; then
        if remove_target_block "$D_PATCH_CONFIG" "$tname"; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log_warn "  register: $patch: would remove the bundle target ${tname} -- no source remains"
            else
                log_warn "  register: $patch: removed the bundle target ${tname} -- no source remains"
            fi
        fi
        return 0
    fi

    read_lines "$D_PATCH_CONFIG" || return 1
    if find_target_block "$tname"; then
        if splice_includes "$D_PATCH_CONFIG" "$tname" "$MERGED"; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log_info "  register: $patch: would splice ${tname} in ${D_PATCH_CONFIG##*/}"
            else
                log_info "  register: $patch: spliced ${tname} in ${D_PATCH_CONFIG##*/}"
            fi
        fi
    else
        insert_new_target "$D_PATCH_CONFIG" "$tname" "$MERGED" "\${js-dir}/patches"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# register_assets <patch> <package-build> <delivered-assets>
#
# Regenerate copy entries for the files THIS package delivers. Entries for
# files the package does not ship are left untouched, which is what makes the
# outcome order-independent -- a package cannot drop assets it knows nothing of.
# ---------------------------------------------------------------------------
register_assets() {
    local patch=$1 pkg_build=$2 delivered=$3
    local rel base i entries="" ow fe have

    # Undoing removes this patch's assets, so its copy entries go with them --
    # ITS assets, named by the plan. One patch directory can carry entries
    # contributed by several packages, so undoing one must never take another's.
    if [ "$UNDO" -eq 1 ]; then
        remove_stale_copies "$patch" "$delivered"
        return 0
    fi

    [ -n "$delivered" ] || return 0
    [ -n "$D_BUILD_FILE" ] && [ -n "$D_COPY_DEST_PROP" ] || return 0

    xml_read_build "$D_BUILD_FILE" || return 1
    derive_copy_style "$D_BUILD_FILE"

    # per-entry specifics from the package's own build file, when it ships one
    local PB_FILE=() PB_OW=() PB_FE=()
    if [ -n "$pkg_build" ] && [ -f "$pkg_build" ]; then
        # Guarded: bash 3.2 calls an EMPTY array unbound under set -u, and the
        # destination legitimately has no copy entries at baseline.
        local save_file=(${BF_COPY_FILE[@]+"${BF_COPY_FILE[@]}"})
        local save_to=(${BF_COPY_TO[@]+"${BF_COPY_TO[@]}"})
        local save_ow=(${BF_COPY_OW[@]+"${BF_COPY_OW[@]}"})
        local save_fe=(${BF_COPY_FE[@]+"${BF_COPY_FE[@]}"})
        if xml_read_build "$pkg_build"; then
            i=0
            arr_count ${BF_COPY_FILE[@]+"${BF_COPY_FILE[@]}"}
            while [ "$i" -lt "$ARR_COUNT" ]; do
                xml_expand "${BF_COPY_FILE[$i]}"
                PB_FILE[$i]=${XML_EXPANDED##*/}
                PB_OW[$i]=${BF_COPY_OW[$i]}; PB_FE[$i]=${BF_COPY_FE[$i]}
                i=$((i + 1))
            done
        fi
        BF_COPY_FILE=(${save_file[@]+"${save_file[@]}"})
        BF_COPY_TO=(${save_to[@]+"${save_to[@]}"})
        BF_COPY_OW=(${save_ow[@]+"${save_ow[@]}"})
        BF_COPY_FE=(${save_fe[@]+"${save_fe[@]}"})
    fi

    split_lines "$delivered"
    for rel in ${SPLIT[@]+"${SPLIT[@]}"}; do
        [ -n "$rel" ] || continue
        base=${rel##*/}

        have=0
        i=0
        arr_count ${BF_COPY_FILE[@]+"${BF_COPY_FILE[@]}"}
        while [ "$i" -lt "$ARR_COUNT" ]; do
            xml_expand "${BF_COPY_FILE[$i]}"
            case $XML_EXPANDED in *"/$rel") have=1; break ;; esac
            i=$((i + 1))
        done
        [ "$have" -eq 1 ] && continue

        ow="true"; fe="true"
        i=0
        while [ "$i" -lt "${#PB_FILE[@]}" ]; do
            if [ "${PB_FILE[$i]}" = "$base" ]; then
                [ -n "${PB_OW[$i]}" ] && ow=${PB_OW[$i]}
                [ -n "${PB_FE[$i]}" ] && fe=${PB_FE[$i]}
                break
            fi
            i=$((i + 1))
        done

        entries="$entries${COPY_IND}<copy file=\"$COPY_SRC_PREFIX/$rel\"
${COPY_ATTR_IND}tofile=\"$D_COPY_DEST_PROP/$base\"
${COPY_ATTR_IND}overwrite=\"$ow\"
${COPY_ATTR_IND}failonerror=\"$fe\"/>
"
        log_warn "  register: AUTO-ADDED a copy entry for a delivered asset nothing registered: $rel"
        REG_CHANGES=$((REG_CHANGES + 1)); REG_WARNINGS=$((REG_WARNINGS + 1))
    done

    [ -n "$entries" ] || return 0
    if splice_copies "$D_BUILD_FILE" "$entries"; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log_info "  register: $patch: would splice copy entries into ${D_BUILD_FILE##*/}"
        else
            log_info "  register: $patch: spliced copy entries into ${D_BUILD_FILE##*/}"
        fi
    fi
    return 0
}


# ---------------------------------------------------------------------------
# remove_stale_copies <patch> <delivered-assets>
#
# Drop the build file's copy entries for the assets THIS PACKAGE delivers,
# whose file is gone. The counterpart of the auto-add on the apply side: undo
# of a patch's rollout de-registers its own assets, and nothing else.
#
# Two conditions, both required. Under the patch directory is not enough on its
# own: several rollouts deliver into the same patch, and a destination can
# carry copy entries older than every package. Dropping on absence alone
# emptied the copy target, and with it the only statement of where assets land
# -- after which no later apply could write a copy entry at all.
#
# A <copy> element spans several lines, so the whole element is removed -- from
# its opening line to the line that closes it.
# ---------------------------------------------------------------------------
remove_stale_copies() {
    local patch=$1 delivered=$2 file=$D_BUILD_FILE
    local i n m=0 start=-1 src abs rel removed=0

    [ -n "$file" ] || return 1
    read_lines "$file" || return 1
    n=${#RL[@]}

    local NEW=() pending=() p=0 drop=0
    i=0
    while [ "$i" -lt "$n" ]; do
        case ${RL[$i]} in
            *'<copy'*) start=$i; pending=(); p=0; drop=0 ;;
        esac

        if [ "$start" -ge 0 ]; then
            pending[$p]=${RL[$i]}; p=$((p + 1))

            if xml_line_attr "${RL[$i]}" "file"; then
                src=$XML_ATTR_VALUE
                xml_expand "$src"; src=$XML_EXPANDED
                if is_abs "$src"; then abs=$src; else normalize_path "$D_REFS_ROOT/$src"; abs=$NORMALIZED; fi
                case $abs in
                    "$D_PATCH_SRC/$patch"/*)
                        rel=${abs#"$D_PATCH_SRC"/}
                        if [ ! -f "$abs" ] && ships_include "" "$delivered" "$rel"; then
                            drop=1
                        fi
                        ;;
                esac
            fi

            case ${RL[$i]} in
                */\>*|*'</copy>'*)
                    if [ "$drop" -eq 1 ]; then
                        removed=$((removed + 1))
                        # swallow one blank separator line that followed it, so
                        # the surrounding target does not accumulate gaps
                        case ${RL[$((i + 1))]} in
                            *[![:space:]]*) ;;
                            *) [ $((i + 1)) -lt "$n" ] && i=$((i + 1)) ;;
                        esac
                    else
                        local k=0
                        while [ "$k" -lt "$p" ]; do NEW[$m]=${pending[$k]}; m=$((m + 1)); k=$((k + 1)); done
                    fi
                    start=-1
                    ;;
            esac
        else
            NEW[$m]=${RL[$i]}; m=$((m + 1))
        fi
        i=$((i + 1))
    done

    [ "$removed" -gt 0 ] || return 1
    RL=( ${NEW[@]+"${NEW[@]}"} )
    REG_CHANGES=$((REG_CHANGES + removed)); REG_WARNINGS=$((REG_WARNINGS + removed))
    if [ "$DRY_RUN" -eq 1 ]; then
        log_warn "  register: $patch: would remove $removed copy entr(ies) whose asset no longer exists"
        return 0
    fi
    write_lines "$file" && log_warn "  register: $patch: removed $removed copy entr(ies) whose asset no longer exists"
    return 0
}
