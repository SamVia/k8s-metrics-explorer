#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
SCRIPT="$PROJECT_DIR/discover-metrics.sh"
FAILURES=0

pass() {
    printf 'PASS: %s\n' "$1"
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAILURES=$((FAILURES + 1))
}

if bash -n "$SCRIPT"; then
    pass "shell syntax"
else
    fail "shell syntax"
fi

HELP_OUTPUT=$(bash "$SCRIPT" --help 2>&1)
if [[ "$HELP_OUTPUT" == *"--name NAME"* &&
    "$HELP_OUTPUT" == *"--name-contains TEXT"* ]]; then
    pass "name filter help"
else
    fail "name filter help"
fi

if bash "$SCRIPT" --unknown-option >/dev/null 2>&1; then
    fail "unknown option rejected"
else
    pass "unknown option rejected"
fi

if bash "$SCRIPT" --name >/dev/null 2>&1; then
    fail "missing option value rejected"
else
    pass "missing option value rejected"
fi

if ((FAILURES > 0)); then
    printf '%s validation check(s) failed.\n' "$FAILURES" >&2
    exit 1
fi

printf 'All validation checks passed.\n'
