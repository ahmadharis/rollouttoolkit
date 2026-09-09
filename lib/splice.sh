#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# splice -- read a document into lines, locate a segment, replace it, write it
# back.
#
# STRUCTURAL ONLY. Nothing here knows what a patch, a kind or a rollout is; it
# knows elements, targets and line boundaries. What belongs in a segment is
# decided by register.sh, which calls these.
#
# Editing is always a SPLICE and never a re-serialisation: the boundaries are
# located, the lines between them are replaced, and every other byte of the
# document is preserved. A document this tool does not fully own must come back
# byte-identical everywhere it was not asked to change.
#
# Author: Haris Ahmad -- Smart IS
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# read_lines <file>  -> $RL[] , $RL_EOL
#
# Read a file into an array, remembering whether it ended with a newline so a
# rewrite can reproduce the original exactly. bash 3.2 has no mapfile.
# ---------------------------------------------------------------------------
read_lines() {
    local line
    RL=(); RL_EOL=1
    [ -f "$1" ] || return 1
    while IFS= read -r line || { [ -n "$line" ] && RL_EOL=0; }; do
        RL[${#RL[@]}]=$line
        [ "$RL_EOL" -eq 0 ] && break
    done <"$1"
    return 0
}
# write_lines <file>  -- from $RL[] , honouring $RL_EOL
write_lines() {
    local out=$1 i=0 n=${#RL[@]}
    : >"$out" || return 1
    while [ "$i" -lt "$n" ]; do
        if [ "$i" -eq $((n - 1)) ] && [ "$RL_EOL" -eq 0 ]; then
            printf '%s' "${RL[$i]}" >>"$out"
        else
            printf '%s\n' "${RL[$i]}" >>"$out"
        fi
        i=$((i + 1))
    done
    return 0
}
# ---------------------------------------------------------------------------
# find_target_block <target-name>  -> $TB_OPEN, $TB_CLOSE, $TB_FIRST_INC, $TB_INDENT
#
# Locate a <target name="..."> ... </target> segment in $RL[]. Returns 1 when
# the target is not declared, which is how a brand-new patch is detected.
# ---------------------------------------------------------------------------
find_target_block() {
    local want=$1 i=0 n=${#RL[@]} in_t=0
    TB_OPEN=-1; TB_CLOSE=-1; TB_FIRST_INC=-1; TB_INDENT="        "

    while [ "$i" -lt "$n" ]; do
        case ${RL[$i]} in
            *'<target'*)
                in_t=1
                if xml_line_attr "${RL[$i]}" "name" && [ "$XML_ATTR_VALUE" = "$want" ]; then
                    TB_OPEN=$i
                fi
                ;;
        esac
        if [ "$TB_OPEN" -ge 0 ] && [ "$i" -ge "$TB_OPEN" ]; then
            case ${RL[$i]} in
                *'<include'*)
                    if [ "$TB_FIRST_INC" -lt 0 ]; then
                        TB_FIRST_INC=$i
                        TB_INDENT=${RL[$i]%%<*}
                    fi
                    ;;
                *'</target>'*) TB_CLOSE=$i; break ;;
            esac
        fi
        case ${RL[$i]} in
            *'</target>'*) in_t=0 ;;
        esac
        i=$((i + 1))
    done
    [ "$TB_OPEN" -ge 0 ] && [ "$TB_CLOSE" -gt "$TB_OPEN" ]
}
# ---------------------------------------------------------------------------
# splice_includes <file> <target-name> <merged-list>
#
# Replace the include lines of one target, leaving every other byte untouched.
# ---------------------------------------------------------------------------
splice_includes() {
    local file=$1 tname=$2 merged=$3
    local i last_inc=-1 kept_tail="" inc

    read_lines "$file" || return 1
    find_target_block "$tname" || return 1

    if [ "$TB_FIRST_INC" -lt 0 ]; then
        TB_FIRST_INC=$TB_CLOSE                    # target declares no includes yet
        last_inc=$((TB_CLOSE - 1))
    else
        i=$TB_FIRST_INC
        while [ "$i" -lt "$TB_CLOSE" ]; do
            case ${RL[$i]} in
                *'<include'*) last_inc=$i ;;
                *) case ${RL[$i]} in
                       ""|*[![:space:]]*)
                           # Anything that is not an include inside the block is
                           # preserved rather than dropped: this tool does not
                           # own it and must not discard it.
                           [ -n "${RL[$i]}" ] && kept_tail="$kept_tail${RL[$i]}
" ;;
                   esac ;;
            esac
            i=$((i + 1))
        done
    fi
    [ "$last_inc" -ge "$TB_FIRST_INC" ] || last_inc=$((TB_FIRST_INC - 1))

    local NEW=() n=0 j
    j=0
    while [ "$j" -lt "$TB_FIRST_INC" ]; do NEW[$n]=${RL[$j]}; n=$((n + 1)); j=$((j + 1)); done

    split_lines "$merged"
    for inc in ${SPLIT[@]+"${SPLIT[@]}"}; do
        [ -n "$inc" ] || continue
        NEW[$n]="${TB_INDENT}<include name=\"$inc\" />"; n=$((n + 1))
    done

    split_lines "$kept_tail"
    for inc in ${SPLIT[@]+"${SPLIT[@]}"}; do
        [ -n "$inc" ] || continue
        NEW[$n]=$inc; n=$((n + 1))
    done

    j=$((last_inc + 1))
    local total=${#RL[@]}
    while [ "$j" -lt "$total" ]; do NEW[$n]=${RL[$j]}; n=$((n + 1)); j=$((j + 1)); done

    RL=( ${NEW[@]+"${NEW[@]}"} )
    [ "$DRY_RUN" -eq 1 ] && return 0
    write_lines "$file"
}
# ---------------------------------------------------------------------------
# insert_new_target <file> <target-name> <merged-list>
#
# A patch the destination has never seen has no target to splice, so one is
# generated from the delivered files and inserted before the closing element.
# ---------------------------------------------------------------------------
insert_new_target() {
    local file=$1 tname=$2 merged=$3 srcdir=$4
    local i n=0 close=-1 inc

    read_lines "$file" || return 1
    i=0
    while [ "$i" -lt "${#RL[@]}" ]; do
        case ${RL[$i]} in *'</project>'*) close=$i ;; esac
        i=$((i + 1))
    done
    [ "$close" -ge 0 ] || return 1

    local NEW=()
    i=0
    while [ "$i" -lt "$close" ]; do NEW[$n]=${RL[$i]}; n=$((n + 1)); i=$((i + 1)); done
    NEW[$n]=""; n=$((n + 1))
    NEW[$n]="    <target name=\"$tname\""; n=$((n + 1))
    NEW[$n]="          type=\"js\""; n=$((n + 1))
    NEW[$n]="          source-dir=\"$srcdir\">"; n=$((n + 1))
    split_lines "$merged"
    for inc in ${SPLIT[@]+"${SPLIT[@]}"}; do
        [ -n "$inc" ] || continue
        NEW[$n]="        <include name=\"$inc\" />"; n=$((n + 1))
    done
    NEW[$n]="    </target>"; n=$((n + 1))
    while [ "$i" -lt "${#RL[@]}" ]; do NEW[$n]=${RL[$i]}; n=$((n + 1)); i=$((i + 1)); done

    RL=( ${NEW[@]+"${NEW[@]}"} )
    log_warn "  register: generated a new bundle target for a patch the destination did not declare: $tname"
    REG_CHANGES=$((REG_CHANGES + 1)); REG_WARNINGS=$((REG_WARNINGS + 1))
    [ "$DRY_RUN" -eq 1 ] && return 0
    write_lines "$file"
}
# ---------------------------------------------------------------------------
# splice_copies <file> <new-entries>
#
# Insert copy entries after the last existing one, and drop entries whose
# source file is gone. Existing entries are left byte-identical.
#
# Only copy entries cross over. A package's build file may define targets that
# FAIL the build on a missing or empty input; the shared file has no such
# target and complying with the destination means that protection is not
# merged. If it is wanted it belongs once in the shared file (SPEC.md 6.3).
# ---------------------------------------------------------------------------
splice_copies() {
    local file=$1 entries=$2
    local i n=0 last_copy=-1 in_copy=0 line

    [ -n "$entries" ] || return 0
    read_lines "$file" || return 1

    # Anchor on the LAST copy entry. A copy element spans several lines, so the
    # anchor advances from its opening tag to its own closing tag -- and stops
    # there.
    #
    # The scan must be BOUNDED by the element that opened it. An unbounded
    # "advance to any later />" walked past the end of the copy target entirely:
    # every <delete dir="..."/> in a later clean target also ends in '/>', so the
    # anchor landed on the last one and new copy entries were spliced into the
    # CLEAN target, where they would delete-then-copy or never run at all.
    i=0
    while [ "$i" -lt "${#RL[@]}" ]; do
        case ${RL[$i]} in
            *'<copy'*) last_copy=$i; in_copy=1 ;;
        esac
        if [ "$in_copy" -eq 1 ]; then
            case ${RL[$i]} in
                *'/>'*|*'</copy>'*) last_copy=$i; in_copy=0 ;;
            esac
        fi
        i=$((i + 1))
    done
    # No copy entry survives to anchor on. That is the BASELINE state, not an
    # error: undo removes every copy entry this package delivered, and a
    # destination that has never carried the app has none to begin with.
    # Refusing here left the build file permanently empty -- undo took the
    # entries out and no later apply could put them back.
    #
    # Fall back to the END of the target that OWNS the copies, identified by the
    # <mkdir> writing to the same destination the copies do -- derived, not
    # named. Entries land just inside that target's close, which keeps them
    # above every target that follows it.
    if [ "$last_copy" -lt 0 ] && [ -n "$D_COPY_DEST_PROP" ]; then
        local in_t=0 mk=0
        i=0
        while [ "$i" -lt "${#RL[@]}" ]; do
            case ${RL[$i]} in
                *'<target'*) in_t=1; mk=0 ;;
            esac
            if [ "$in_t" -eq 1 ]; then
                case ${RL[$i]} in
                    *'<mkdir'*)
                        if xml_line_attr "${RL[$i]}" "dir"; then
                            case $XML_ATTR_VALUE in
                                "$D_COPY_DEST_PROP"*) mk=1 ;;
                            esac
                        fi
                        ;;
                esac
                case ${RL[$i]} in
                    *'</target>'*)
                        if [ "$mk" -eq 1 ]; then last_copy=$((i - 1)); break; fi
                        in_t=0
                        ;;
                esac
            fi
            i=$((i + 1))
        done
    fi
    [ "$last_copy" -ge 0 ] || { log_warn "  register: build file declares no copy entry and no copy target to anchor to; skipping asset registration"; return 1; }

    local NEW=()
    i=0
    while [ "$i" -le "$last_copy" ]; do NEW[$n]=${RL[$i]}; n=$((n + 1)); i=$((i + 1)); done
    split_lines "$entries"
    for line in ${SPLIT[@]+"${SPLIT[@]}"}; do
        [ -n "$line" ] || continue
        NEW[$n]=$line; n=$((n + 1))
    done
    while [ "$i" -lt "${#RL[@]}" ]; do NEW[$n]=${RL[$i]}; n=$((n + 1)); i=$((i + 1)); done

    RL=( ${NEW[@]+"${NEW[@]}"} )
    [ "$DRY_RUN" -eq 1 ] && return 0
    write_lines "$file"
}
# ---------------------------------------------------------------------------
# remove_target_block <file> <target-name>
#
# Delete a whole <target> ... </target> section, plus one blank line ahead of it
# so the surrounding file does not accumulate gaps. Used when undo leaves a
# bundle target with no source left to build.
#
# Only this section is touched; every other byte of the document is preserved.
# ---------------------------------------------------------------------------
remove_target_block() {
    local file=$1 tname=$2 i n m=0 from

    read_lines "$file" || return 1
    find_target_block "$tname" || return 1
    n=${#RL[@]}

    from=$TB_OPEN
    if [ "$from" -gt 0 ]; then
        case ${RL[$((from - 1))]} in
            ""|*[![:space:]]*) : ;;
        esac
        # swallow a single blank separator line above the block
        local prev=${RL[$((from - 1))]}
        case $prev in
            *[![:space:]]*) ;;
            *) from=$((from - 1)) ;;
        esac
    fi

    local NEW=()
    i=0
    while [ "$i" -lt "$from" ]; do NEW[$m]=${RL[$i]}; m=$((m + 1)); i=$((i + 1)); done
    i=$((TB_CLOSE + 1))
    while [ "$i" -lt "$n" ]; do NEW[$m]=${RL[$i]}; m=$((m + 1)); i=$((i + 1)); done

    RL=( ${NEW[@]+"${NEW[@]}"} )
    REG_CHANGES=$((REG_CHANGES + 1)); REG_WARNINGS=$((REG_WARNINGS + 1))
    [ "$DRY_RUN" -eq 1 ] && return 0
    write_lines "$file"
}
