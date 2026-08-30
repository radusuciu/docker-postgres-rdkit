# Shared assertion helpers for tests/test_*.sh
# Usage:
#   . "$(dirname "$0")/lib.sh"
#   assert_eq "expected" "$actual" "description"
#   finish
set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0

_fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL: %s\n' "$1" >&2
}

pass() {
    printf 'ok: %s\n' "$1"
}

assert_eq() {
    local expected="$1" actual="$2" desc="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        pass "$desc"
    else
        _fail "$desc"
        printf '  expected: %s\n  actual:   %s\n' "$expected" "$actual" >&2
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        pass "$desc"
    else
        _fail "$desc"
        printf '  expected to contain: %s\n  actual: %s\n' "$needle" "$haystack" >&2
    fi
}

# assert_fails <desc> <command...> -- asserts a non-zero exit status
assert_fails() {
    local desc="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" >/dev/null 2>&1; then
        _fail "$desc (command unexpectedly succeeded)"
    else
        pass "$desc"
    fi
}

finish() {
    printf '\n%s: %d assertions, %d failed\n' "$(basename "$0")" "$TESTS_RUN" "$TESTS_FAILED"
    [ "$TESTS_FAILED" -eq 0 ]
}
