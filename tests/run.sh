#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run.sh -- discover and run every tests/test_*.sh, report a summary, and
# exit non-zero if any failed. bash 3.2 / POSIX, matching the tool itself --
# no dependency this suite would need that the tool doesn't already assume.
#
#     tests/run.sh              run everything
#     tests/run.sh combine      run only tests whose name contains "combine"
# ---------------------------------------------------------------------------
set -u
cd "$(dirname "$0")"

filter=${1:-}
pass=0
fail=0
failed_names=""

for t in test_*.sh; do
    [ -f "$t" ] || continue
    case $t in
        *"$filter"*) ;;
        *) continue ;;
    esac

    printf '%-52s' "$t"
    if out=$(bash "$t" 2>&1); then
        echo "PASS"
        pass=$((pass + 1))
    else
        echo "FAIL"
        printf '%s\n' "$out" | sed 's/^/    /'
        fail=$((fail + 1))
        failed_names="$failed_names $t"
    fi
done

echo "---------------------------------------------------------------------"
echo "passed: $pass   failed: $fail"

if [ "$fail" -gt 0 ]; then
    echo "failing tests:$failed_names"
    exit 1
fi
exit 0
