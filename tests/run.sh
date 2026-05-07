#!/bin/bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0
COUNT=0

for test_file in "$ROOT_DIR"/tests/test_*.sh; do
    [ -f "$test_file" ] || continue
    COUNT=$((COUNT + 1))
    echo "==> $(basename "$test_file")"
    if bash "$test_file"; then
        echo "PASS $(basename "$test_file")"
    else
        echo "FAIL $(basename "$test_file")"
        FAILED=$((FAILED + 1))
    fi
    echo ""
done

if [ "$COUNT" -eq 0 ]; then
    echo "No tests found"
    exit 1
fi

if [ "$FAILED" -ne 0 ]; then
    echo "$FAILED/$COUNT test files failed"
    exit 1
fi

echo "$COUNT test files passed"
