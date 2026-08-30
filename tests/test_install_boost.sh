#!/usr/bin/env bash
# Exercises scripts/install_boost.sh inside throwaway Debian containers.
# Requires docker and network access.
. "$(dirname "$0")/lib.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# run_in_suite <suite> <fixture-floor> -> prints combined output, sets RC
run_in_suite() {
    local suite="$1" floor="$2"
    docker run --rm \
        -v "${REPO_ROOT}/scripts:/scripts:ro" \
        -v "${REPO_ROOT}/tests/fixtures/cmakelists/floor-${floor}:/src:ro" \
        "debian:${suite}-slim" \
        bash -c 'apt-get update -qq >/dev/null 2>&1 && /scripts/install_boost.sh /src' 2>&1
}

# run_in_suite_stdout_only <suite> <fixture-floor> -> prints ONLY stdout, sets RC
run_in_suite_stdout_only() {
    local suite="$1" floor="$2"
    docker run --rm \
        -v "${REPO_ROOT}/scripts:/scripts:ro" \
        -v "${REPO_ROOT}/tests/fixtures/cmakelists/floor-${floor}:/src:ro" \
        "debian:${suite}-slim" \
        bash -c 'apt-get update -qq >/dev/null 2>&1 && /scripts/install_boost.sh /src 2>/dev/null'
}

echo "--- bookworm, floor 1.58.0: expect the LOWEST family (1.74), not 1.81 ---"
out=$(run_in_suite bookworm 1.58.0); rc=$?
assert_eq "0" "$rc" "bookworm/1.58.0 exits 0"
assert_contains "$out" "Selected Boost family 1.74" "bookworm/1.58.0 picks 1.74, not 1.81"
assert_contains "$out" "1.74.0" "bookworm/1.58.0 prints the dotted version"

echo "--- bookworm, floor 1.81.0: expect 1.81, not the 1.74 suite default ---"
out=$(run_in_suite bookworm 1.81.0); rc=$?
assert_eq "0" "$rc" "bookworm/1.81.0 exits 0"
assert_contains "$out" "Selected Boost family 1.81" "bookworm/1.81.0 picks 1.81"
assert_contains "$out" "1.81.0" "bookworm/1.81.0 prints the dotted version"

echo "--- bookworm, floor 1.81.0: stdout must be exactly the dotted version, nothing else ---"
stdout_only=$(run_in_suite_stdout_only bookworm 1.81.0); rc=$?
assert_eq "0" "$rc" "bookworm/1.81.0 stdout-only run exits 0"
assert_eq "1.81.0" "$stdout_only" "bookworm/1.81.0 stdout is exactly the dotted version"

echo "--- bookworm, floor 9.99.0: expect the R2 preflight failure ---"
out=$(run_in_suite bookworm 9.99.0); rc=$?
assert_eq "1" "$rc" "unsatisfiable floor exits 1"
assert_contains "$out" "requires Boost >= 9.99.0" "error names the floor"
assert_contains "$out" "libboost1.81-dev" "error lists what the suite offers"
assert_contains "$out" "versions.json" "error tells the operator to change the suite"

finish
