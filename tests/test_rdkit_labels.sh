#!/usr/bin/env bash
# Tests scripts/rdkit_labels.sh against a fixture mirroring Release_2025_09_2.
. "$(dirname "$0")/lib.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/rdkit_labels.sh"
FIXTURE="${REPO_ROOT}/tests/fixtures/rdkit-source"
FIXTURE_MISSING_MAJOR="${REPO_ROOT}/tests/fixtures/rdkit-source-missing-major"
FIXTURE_MULTI_MAJOR="${REPO_ROOT}/tests/fixtures/rdkit-source-multi-major"

# Test successful extraction with valid source
out=$("$SCRIPT" "$FIXTURE")

# Verify exact version strings
assert_eq "rdkit_pickle_version=16.2.0" "$(printf '%s' "$out" | sed -n '1p')" "pickle version line is exact"
assert_eq "rdkit_cartridge_version=4.8.0" "$(printf '%s' "$out" | sed -n '2p')" "cartridge version line is exact"

# Verify output is exactly 2 lines (add final newline for accurate count)
assert_eq "2" "$(printf '%s\n' "$out" | wc -l)" "output is exactly 2 lines"

# Verify every line is key=value format
assert_eq "" "$(printf '%s\n' "$out" | grep -v '^[a-z_]*=' || true)" "every line is key=value"

# Test error cases
assert_fails "missing source dir rejected" "$SCRIPT" /nonexistent
assert_fails "no argument rejected" "$SCRIPT"
assert_fails "missing versionMajor rejected" "$SCRIPT" "$FIXTURE_MISSING_MAJOR"
assert_fails "multiple versionMajor rejected" "$SCRIPT" "$FIXTURE_MULTI_MAJOR"

finish
