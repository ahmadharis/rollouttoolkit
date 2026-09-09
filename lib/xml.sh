#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# xml -- read the declarations the target's shared files carry.
#
# The environment has no XML parser and one is NOT to be added. What is needed
# here is narrow: attribute values in files the platform generates in a stable
# form. So:
#
#   * match line-oriented, tolerating single or double quotes, surrounding
#     whitespace, and whitespace around the '='
#   * never assume attribute order
#   * treat a value that does not match as absent, and let the convention that
#     depends on it stand down (derive.sh)
#
# Elements span several lines (each attribute on its own line), so the readers
# below track element context across lines rather than parsing one line as a
# whole element.
#
# Writing back is a SEGMENT SPLICE, never a re-serialisation: locate the
# boundaries, replace the lines between them, leave every other byte untouched.
# A whole-document rewrite would reformat regions this tool does not own.
#
# Author: Haris Ahmad -- Smart IS
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# xml_line_attr <line> <attr> -> $XML_ATTR_VALUE
#
# Extract attr="value" / attr='value' from one line. Returns 1 when the line
# does not carry that attribute.
#
# Requires a word boundary before the name so that looking for "dir" does not
# match "source-dir", and skips to the next occurrence when the boundary or the
# quoting does not hold.
# ---------------------------------------------------------------------------
xml_line_attr() {
    local line=$1 attr=$2 pre rest after q
    XML_ATTR_VALUE=""
    rest=$line
    while :; do
        case $rest in
            *"$attr"*) ;;
            *) return 1 ;;
        esac
        pre=${rest%%"$attr"*}
        rest=${rest#*"$attr"}

        case $pre in
            ""|*[[:space:]\<]) ;;          # start of line, whitespace, or '<'
            *) continue ;;
        esac

        after=${rest#"${rest%%[![:space:]]*}"}
        case $after in
            =*) after=${after#=} ;;
            *) continue ;;
        esac
        after=${after#"${after%%[![:space:]]*}"}
        case $after in
            \"*) q='"'; after=${after#\"} ;;
            \'*) q="'"; after=${after#\'} ;;
            *) continue ;;
        esac
        case $after in
            *"$q"*) XML_ATTR_VALUE=${after%%"$q"*}; return 0 ;;
            *) continue ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Property map -- name/value pairs used to expand ${...} references.
# Parallel indexed arrays: bash 3.2 has no associative arrays.
# ---------------------------------------------------------------------------
XP_NAME=(); XP_VALUE=()

xp_reset() { XP_NAME=(); XP_VALUE=(); }

xp_set() {
    local i=0 n=${#XP_NAME[@]}
    while [ "$i" -lt "$n" ]; do
        if [ "${XP_NAME[$i]}" = "$1" ]; then XP_VALUE[$i]=$2; return 0; fi
        i=$((i + 1))
    done
    XP_NAME[$n]=$1
    XP_VALUE[$n]=$2
}

xp_get() {
    local i=0 n=${#XP_NAME[@]}
    XP_GOT=""
    while [ "$i" -lt "$n" ]; do
        if [ "${XP_NAME[$i]}" = "$1" ]; then XP_GOT=${XP_VALUE[$i]}; return 0; fi
        i=$((i + 1))
    done
    return 1
}

# ---------------------------------------------------------------------------
# xml_expand <value> -> $XML_EXPANDED
#
# Resolve ${name} references against the property map, repeatedly, so
# ${js-dir} -> ${project-dir}/src/js -> ./src/js. Bounded, so a cycle or an
# unresolvable reference terminates: an unknown ${name} is left verbatim and
# the caller decides whether the value is usable.
# ---------------------------------------------------------------------------
xml_expand() {
    local value=$1 pass=0 head name tail out
    while [ "$pass" -lt 10 ]; do
        case $value in
            *'${'*) ;;
            *) break ;;
        esac
        out=""
        local work=$value changed=0
        while :; do
            case $work in
                *'${'*) ;;
                *) out="$out$work"; break ;;
            esac
            head=${work%%'${'*}
            tail=${work#*'${'}
            case $tail in
                *'}'*) name=${tail%%'}'*}; tail=${tail#*'}'} ;;
                *) out="$out$work"; break ;;      # unterminated: leave as-is
            esac
            if xp_get "$name"; then
                out="$out$head$XP_GOT"; changed=1
            else
                out="$out$head\${$name}"          # unknown: keep verbatim
            fi
            work=$tail
        done
        value=$out
        [ "$changed" -eq 1 ] || break
        pass=$((pass + 1))
    done
    XML_EXPANDED=$value
}

# ---------------------------------------------------------------------------
# xml_read_patch_config <file>
#
# Read a patch-config document (the target's shared patches.xml, or a package's
# per-patch config). Populates, in declaration order:
#
#   PC_TGT_NAME[]     target name        (the bundle target name)
#   PC_TGT_TYPE[]     target type        ("js", "load", ...)
#   PC_TGT_SRCDIR[]   source-dir         (expanded)
#   PC_TGT_INC[]      newline-separated include names for that target
#
# Project-level attributes become properties, so source-dir expands.
# ---------------------------------------------------------------------------
PC_TGT_NAME=(); PC_TGT_TYPE=(); PC_TGT_SRCDIR=(); PC_TGT_INC=()

xml_read_patch_config() {
    local file=$1 line in_project=0 in_target=0 idx=-1
    PC_TGT_NAME=(); PC_TGT_TYPE=(); PC_TGT_SRCDIR=(); PC_TGT_INC=()
    xp_reset
    [ -f "$file" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        strip_cr "$line"; line=$STRIPPED_CR

        case $line in
            *'<project'*) in_project=1 ;;
        esac

        # Project attributes are the property map for this document.
        if [ "$in_project" -eq 1 ]; then
            local a
            for a in project-dir css-dir js-dir config-dir app-id; do
                if xml_line_attr "$line" "$a"; then xp_set "$a" "$XML_ATTR_VALUE"; fi
            done
            case $line in
                *'>'*) in_project=0 ;;
            esac
        fi

        case $line in
            *'<target'*)
                in_target=1
                idx=$((idx + 1))
                PC_TGT_NAME[$idx]=""; PC_TGT_TYPE[$idx]=""
                PC_TGT_SRCDIR[$idx]=""; PC_TGT_INC[$idx]=""
                ;;
        esac

        if [ "$in_target" -eq 1 ] && [ "$idx" -ge 0 ]; then
            case $line in
                *'<include'*) ;;                    # an include's name is not the target's
                *) if xml_line_attr "$line" "name"; then
                       [ -n "${PC_TGT_NAME[$idx]}" ] || PC_TGT_NAME[$idx]=$XML_ATTR_VALUE
                   fi ;;
            esac
            if xml_line_attr "$line" "type"; then
                [ -n "${PC_TGT_TYPE[$idx]}" ] || PC_TGT_TYPE[$idx]=$XML_ATTR_VALUE
            fi
            if xml_line_attr "$line" "source-dir"; then
                xml_expand "$XML_ATTR_VALUE"
                [ -n "${PC_TGT_SRCDIR[$idx]}" ] || PC_TGT_SRCDIR[$idx]=$XML_EXPANDED
            fi
            case $line in
                *'<include'*)
                    if xml_line_attr "$line" "name"; then
                        PC_TGT_INC[$idx]="${PC_TGT_INC[$idx]}${XML_ATTR_VALUE}
"
                    fi
                    ;;
            esac
            case $line in
                *'</target>'*) in_target=0 ;;
            esac
        fi
    done <"$file"

    [ "$idx" -ge 0 ]
}

# ---------------------------------------------------------------------------
# xml_read_build <file>
#
# Read an ant build file. Populates:
#
#   BF_COPY_FILE[]    the copy's source path   (raw, unexpanded)
#   BF_COPY_TO[]      the copy's tofile value  (raw, unexpanded)
#   BF_COPY_OW[]      its overwrite attribute
#   BF_COPY_FE[]      its failonerror attribute
#
# and leaves <property name= value=> pairs in the property map so a caller can
# expand either side. Raw values are kept because the destination expression
# itself -- not what it expands to -- is what merged entries must adopt
# (SPEC.md 6.3).
# ---------------------------------------------------------------------------
BF_COPY_FILE=(); BF_COPY_TO=(); BF_COPY_OW=(); BF_COPY_FE=()

xml_read_build() {
    local file=$1 line in_copy=0 idx=-1 pname pvalue
    BF_COPY_FILE=(); BF_COPY_TO=(); BF_COPY_OW=(); BF_COPY_FE=()
    xp_reset
    [ -f "$file" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        strip_cr "$line"; line=$STRIPPED_CR

        case $line in
            *'<property'*)
                pname=""; pvalue=""
                xml_line_attr "$line" "name"  && pname=$XML_ATTR_VALUE
                xml_line_attr "$line" "value" && pvalue=$XML_ATTR_VALUE
                [ -n "$pname" ] && xp_set "$pname" "$pvalue"
                ;;
        esac

        case $line in
            *'<copy'*) in_copy=1; idx=$((idx + 1))
                       BF_COPY_FILE[$idx]=""; BF_COPY_TO[$idx]=""
                       BF_COPY_OW[$idx]=""; BF_COPY_FE[$idx]="" ;;
        esac

        if [ "$in_copy" -eq 1 ] && [ "$idx" -ge 0 ]; then
            if xml_line_attr "$line" "file"; then
                [ -n "${BF_COPY_FILE[$idx]}" ] || BF_COPY_FILE[$idx]=$XML_ATTR_VALUE
            fi
            if xml_line_attr "$line" "tofile"; then
                [ -n "${BF_COPY_TO[$idx]}" ] || BF_COPY_TO[$idx]=$XML_ATTR_VALUE
            fi
            if xml_line_attr "$line" "overwrite"; then
                [ -n "${BF_COPY_OW[$idx]}" ] || BF_COPY_OW[$idx]=$XML_ATTR_VALUE
            fi
            if xml_line_attr "$line" "failonerror"; then
                [ -n "${BF_COPY_FE[$idx]}" ] || BF_COPY_FE[$idx]=$XML_ATTR_VALUE
            fi
            case $line in
                */\>*|*'</copy>'*) in_copy=0 ;;
            esac
        fi
    done <"$file"

    # A build file with no copy entries is READ, not unreadable. It is the
    # baseline state: undo removes every copy entry this package delivered, and
    # a destination that has never carried an app has none to begin with.
    #
    # Reporting failure here made stage 2 stand every derived fact down, so the
    # next apply placed files from the manifest alone -- and could not write the
    # copy entries back, because the caller had already given up on the file.
    # The property map above is populated either way, which is what the
    # destination-vocabulary fallbacks read.
    [ -f "$file" ]
}
