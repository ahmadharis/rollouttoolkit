#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# yamlmerge -- assemble a retired deploy kind's content into the surviving one.
#
# When a manifest names a deploy kind the destination no longer has, the file
# is not copied -- writing it would create the obsolete tree this tool exists
# to prevent -- and it is not dropped either. Its content is merged instead
# (SPEC.md 4.7):
#
#   1. read the retired file's entity, node identity, and every other
#      attribute on that node
#   2. find the surviving-kind files declaring the SAME node identity
#   3. merge those attributes into the parent node of the FIRST such file in
#      manifest order, leaving its children untouched
#   4. leave the other declaring files unchanged -- they contribute only children
#   5. drop the retired file's directive
#
# Exactly one file carries the merged attributes, so no conflicting values load.
#
# There is no YAML parser here for the same reason there is no XML one: the
# documents are platform-generated and regular, and a dependency is not to be
# added. Editing is a splice -- insert the attribute lines after the identity
# line, at the indentation its siblings already use, and leave every other byte
# alone.
#
# Author: Haris Ahmad -- Smart IS
# ---------------------------------------------------------------------------

YM_MERGED=0
YM_WARNINGS=0

# ---------------------------------------------------------------------------
# yaml_read_node <file> -> $Y_ENTITY, $Y_KEY, $Y_VALUE, $Y_ATTRS
#
# Read the first data node: its entity, its identity (the first key on the list
# item), and the scalar attributes beside it.
#
# A key with an empty value opens a nested block -- those are CHILDREN, and
# children are never carried across. Only scalars move.
# ---------------------------------------------------------------------------
yaml_read_node() {
    local file=$1 line key value trimmed in_data=0 got_id=0 id_indent=""
    Y_ENTITY=""; Y_KEY=""; Y_VALUE=""; Y_ATTRS=""
    [ -f "$file" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        strip_cr "$line"; line=$STRIPPED_CR
        trimmed=${line#"${line%%[![:space:]]*}"}
        [ -n "$trimmed" ] || continue

        case $trimmed in
            \#*) continue ;;
            entity:*) Y_ENTITY=${trimmed#entity:}
                      Y_ENTITY=${Y_ENTITY#"${Y_ENTITY%%[![:space:]]*}"} ; continue ;;
            data:*)   in_data=1; continue ;;
        esac
        [ "$in_data" -eq 1 ] || continue

        if [ "$got_id" -eq 0 ]; then
            case $trimmed in
                -*)
                    trimmed=${trimmed#-}
                    trimmed=${trimmed#"${trimmed%%[![:space:]]*}"}
                    case $trimmed in
                        *:*) Y_KEY=${trimmed%%:*}
                             Y_VALUE=${trimmed#*:}
                             Y_VALUE=${Y_VALUE#"${Y_VALUE%%[![:space:]]*}"}
                             got_id=1 ;;
                    esac
                    ;;
            esac
            continue
        fi

        # a second list item ends the node
        case $trimmed in
            -*) break ;;
        esac

        case $trimmed in
            *:*)
                key=${trimmed%%:*}
                value=${trimmed#*:}
                value=${value#"${value%%[![:space:]]*}"}
                # empty value opens a nested block: a child, not an attribute
                [ -n "$value" ] || break
                Y_ATTRS="$Y_ATTRS$key: $value
"
                ;;
            *) break ;;
        esac
    done <"$file"

    [ -n "$Y_KEY" ]
}

# ---------------------------------------------------------------------------
# yaml_declares <file> <entity> <key> <value>
#
# True when this file declares the same entity and the same node identity.
# ---------------------------------------------------------------------------
yaml_declares() {
    local file=$1 entity=$2 key=$3 value=$4
    yaml_read_node "$file" || return 1
    [ "$Y_ENTITY" = "$entity" ] || return 1
    [ "$Y_KEY" = "$key" ] || return 1
    [ "$Y_VALUE" = "$value" ] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# yaml_merge_into <file> <key> <value> <attrs>
#
# Splice the attribute lines in immediately after the identity line, indented
# the way this file's own sibling attributes are. Children stay untouched.
# An attribute the node already carries is left as it stands -- the destination
# wins over the retired file, because the destination is the current shape.
# ---------------------------------------------------------------------------
yaml_merge_into() {
    local file=$1 key=$2 value=$3 attrs=$4
    local i n idline=-1 indent="" line trimmed a akey added=0

    read_lines "$file" || return 1
    n=${#RL[@]}

    i=0
    while [ "$i" -lt "$n" ]; do
        trimmed=${RL[$i]#"${RL[$i]%%[![:space:]]*}"}
        case $trimmed in
            -*)
                trimmed=${trimmed#-}
                trimmed=${trimmed#"${trimmed%%[![:space:]]*}"}
                if [ "${trimmed%%:*}" = "$key" ]; then
                    local v=${trimmed#*:}
                    v=${v#"${v%%[![:space:]]*}"}
                    if [ "$v" = "$value" ]; then idline=$i; fi
                fi
                ;;
        esac
        [ "$idline" -ge 0 ] && break
        i=$((i + 1))
    done
    [ "$idline" -ge 0 ] || return 1

    # sibling indentation: the next line that is not another list item
    if [ $((idline + 1)) -lt "$n" ]; then
        line=${RL[$((idline + 1))]}
        indent=${line%%[![:space:]]*}
    fi
    [ -n "$indent" ] || indent="    "

    local NEW=() m=0
    i=0
    while [ "$i" -le "$idline" ]; do NEW[$m]=${RL[$i]}; m=$((m + 1)); i=$((i + 1)); done

    split_lines "$attrs"
    for a in ${SPLIT[@]+"${SPLIT[@]}"}; do
        [ -n "$a" ] || continue
        akey=${a%%:*}
        # already present on this node? leave the destination's value alone
        local j=$((idline + 1)) present=0
        while [ "$j" -lt "$n" ]; do
            trimmed=${RL[$j]#"${RL[$j]%%[![:space:]]*}"}
            case $trimmed in
                -*) break ;;
                "$akey":*) present=1; break ;;
            esac
            j=$((j + 1))
        done
        [ "$present" -eq 1 ] && continue
        NEW[$m]="${indent}${a}"; m=$((m + 1)); added=$((added + 1))
    done

    i=$((idline + 1))
    while [ "$i" -lt "$n" ]; do NEW[$m]=${RL[$i]}; m=$((m + 1)); i=$((i + 1)); done

    [ "$added" -gt 0 ] || return 2          # nothing to add: already merged
    RL=( ${NEW[@]+"${NEW[@]}"} )
    [ "$DRY_RUN" -eq 1 ] && return 0
    write_lines "$file"
}

# ---------------------------------------------------------------------------
# merge_retired_kinds
#
# Walk the plan for directives whose deploy kind the destination no longer has,
# and assemble each into the surviving kind.
#
# The surviving kind is found by ENTITY, not by name similarity: the retired
# file declares what it is, and the destination's declared kinds are searched
# for files declaring the same thing. "First in manifest order" is the plan's
# own order, which is manifest order by construction.
#
# Runs in stage 5, after execution: the surviving-kind files this package
# delivers must be in place before anything is merged into them.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# collect_retired_attrs
#
# Gather every attribute this run's retired kinds would contribute, ONCE,
# before execution. Undo needs it during stage 4, but the merge itself happens
# in stage 5 -- so the answer has to exist before the merge runs.
#
# This is what lets undo tell its own edit apart from someone else's: apply
# splices these attributes into a delivered file, so at undo time that file no
# longer matches the package copy byte for byte, and a plain comparison would
# refuse to remove a file the tool itself modified.
# ---------------------------------------------------------------------------
collect_retired_attrs() {
    RETIRED_ATTRS=""
    local i=0 src
    while [ "$i" -lt "$P_COUNT" ]; do
        if [ "${P_RULE[$i]}" = "$R_RETIRED" ] && [ "${P_KIND[$i]}" = "REPLACE" ]; then
            src="$PACKAGE_DIR/${P_SOURCE[$i]}"
            if [ -f "$src" ] && yaml_read_node "$src" && [ -n "$Y_ATTRS" ]; then
                RETIRED_ATTRS="$RETIRED_ATTRS$Y_ATTRS"
            fi
        fi
        i=$((i + 1))
    done
    return 0
}

# ---------------------------------------------------------------------------
# same_but_for_merged_attrs <package-copy> <target>  -> 0 same / 1 differs
#
# True when the target is the package copy plus attribute lines THIS PACKAGE'S
# retired kinds contribute, and nothing else.
#
# The same shape as same_but_for_year (version.sh): apply modifies content on
# the way in, so undo has to tolerate exactly that modification and nothing
# more. Reversing the merge first was rejected -- it would mean rewriting a
# file purely to delete it, and would force post-processing to run BEFORE the
# removal pass in undo only, giving undo a stage order apply does not have.
#
# The tolerance is narrow by construction: an extra line must match an
# attribute the package's own retired-kind source declares. Any other
# difference still refuses, so a genuine edit by someone else is still safe.
# ---------------------------------------------------------------------------
same_but_for_merged_attrs() {
    local pkg=$1 tgt=$2 nl='
'
    [ -n "$RETIRED_ATTRS" ] || return 1

    local P=() n=0 line trimmed i=0
    while IFS= read -r line || [ -n "$line" ]; do
        strip_cr "$line"; P[$n]=$STRIPPED_CR; n=$((n + 1))
    done <"$pkg"

    while IFS= read -r line || [ -n "$line" ]; do
        strip_cr "$line"; line=$STRIPPED_CR
        if [ "$i" -lt "$n" ] && [ "$line" = "${P[$i]+${P[$i]}}" ]; then
            i=$((i + 1)); continue
        fi
        trimmed=${line#"${line%%[![:space:]]*}"}
        case "$nl$RETIRED_ATTRS" in
            *"$nl$trimmed$nl"*) continue ;;
        esac
        return 1
    done <"$tgt"

    [ "$i" -eq "$n" ]
}

merge_retired_kinds() {
    local i=0 any=0 src entity key value attrs target rc

    while [ "$i" -lt "$P_COUNT" ]; do
        [ "${P_RULE[$i]}" = "$R_RETIRED" ] || { i=$((i + 1)); continue; }
        [ "${P_KIND[$i]}" = "REPLACE" ]    || { i=$((i + 1)); continue; }

        if [ "$any" -eq 0 ]; then log_head "retired deploy kinds"; any=1; fi

        src="$PACKAGE_DIR/${P_SOURCE[$i]}"
        if [ ! -f "$src" ]; then
            log_error "  retired kind: source not found, nothing to assemble: ${P_SOURCE[$i]}"
            YM_WARNINGS=$((YM_WARNINGS + 1)); i=$((i + 1)); continue
        fi
        if ! yaml_read_node "$src"; then
            log_warn "  retired kind: cannot read a node identity from ${src##*/}; left unassembled"
            YM_WARNINGS=$((YM_WARNINGS + 1)); i=$((i + 1)); continue
        fi
        entity=$Y_ENTITY; key=$Y_KEY; value=$Y_VALUE; attrs=$Y_ATTRS

        if [ -z "$attrs" ]; then
            log_info "  retired kind: ${src##*/} carries no attribute beyond its identity; nothing to assemble"
            i=$((i + 1)); continue
        fi

        target=$(find_declaring_file "$entity" "$key" "$value")
        if [ -z "$target" ]; then
            log_warn "  retired kind: no surviving-kind file declares $key: $value; ${src##*/} could not be assembled"
            YM_WARNINGS=$((YM_WARNINGS + 1)); i=$((i + 1)); continue
        fi

        yaml_merge_into "$target" "$key" "$value" "$attrs"; rc=$?
        case $rc in
            0) if [ "$DRY_RUN" -eq 1 ]; then
                   log_warn "  retired kind: would assemble $(printf '%s' "$attrs" | tr '\n' ' ')from ${src##*/} into ${target#"$TARGET_DIR"/}"
               else
                   log_warn "  retired kind: assembled $(printf '%s' "$attrs" | tr '\n' ' ')from ${src##*/} into ${target#"$TARGET_DIR"/}"
               fi
               YM_MERGED=$((YM_MERGED + 1)) ;;
            2) log_info "  retired kind: ${target##*/} already carries the attributes from ${src##*/}" ;;
            *) log_error "  retired kind: could not splice into ${target#"$TARGET_DIR"/}"
               YM_WARNINGS=$((YM_WARNINGS + 1)) ;;
        esac
        i=$((i + 1))
    done
    return 0
}

# ---------------------------------------------------------------------------
# find_declaring_file <entity> <key> <value>
#
# The first file, in manifest order, that this run placed under a declared
# deploy kind and that declares the same node identity. Prints the path.
# ---------------------------------------------------------------------------
find_declaring_file() {
    local entity=$1 key=$2 value=$3 i=0 dest
    while [ "$i" -lt "$P_COUNT" ]; do
        dest=${P_DEST[$i]}
        if [ "${P_DISP[$i]}" = "apply" ] && [ "${P_KIND[$i]}" = "REPLACE" ] && [ -n "$dest" ]; then
            case $dest in
                "$D_DEPLOY_DIR"/*)
                    # In a dry run the destination has not been written yet, so
                    # the declaration is read from the copy that WOULD be placed.
                    local probe=$dest
                    [ -f "$probe" ] || probe="$PACKAGE_DIR/${P_SOURCE[$i]}"
                    if [ -f "$probe" ] && yaml_declares "$probe" "$entity" "$key" "$value"; then
                        printf '%s' "$dest"
                        return 0
                    fi
                    ;;
            esac
        fi
        i=$((i + 1))
    done
    return 1
}
