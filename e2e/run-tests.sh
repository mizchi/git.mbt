#!/bin/bash
#
# Run all moongit e2e tests

set -e

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"

# Parse arguments
VERBOSE=0
FILTER=""
while [ $# -gt 0 ]; do
    case "$1" in
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        *)
            FILTER="$1"
            shift
            ;;
    esac
done

# Build moongit first
echo "Building moongit..."
(cd "$PROJECT_ROOT" && moon build --target native --release 2>/dev/null)

echo ""
echo "Running moongit e2e tests..."
echo "=============================="
echo ""

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
FAILED_TESTS=()

for test_file in "$TEST_DIR"/t[0-9]*.sh; do
    if [ -n "$FILTER" ] && [[ ! "$test_file" == *"$FILTER"* ]]; then
        continue
    fi

    test_name=$(basename "$test_file")
    echo "*** $test_name ***"

    if [ $VERBOSE -eq 1 ]; then
        if bash "$test_file"; then
            :
        else
            FAILED_TESTS+=("$test_name")
        fi
    else
        if output=$(bash "$test_file" 2>&1); then
            echo "$output"
        else
            echo "$output"
            FAILED_TESTS+=("$test_name")
        fi
    fi

    # Parse results from output
    pass=$(echo "$output" | grep -c "^ok " || true)
    fail=$(echo "$output" | grep -c "^not ok " || true)
    skip=$(echo "$output" | grep -c "# SKIP" || true)

    TOTAL_PASS=$((TOTAL_PASS + pass))
    TOTAL_FAIL=$((TOTAL_FAIL + fail))
    TOTAL_SKIP=$((TOTAL_SKIP + skip))

    echo ""
done

echo "=============================="
echo "Summary:"
echo "  Passed: $TOTAL_PASS"
echo "  Failed: $TOTAL_FAIL"
echo "  Skipped: $TOTAL_SKIP"

if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
    echo ""
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi

echo ""
echo "All tests passed!"
exit 0
