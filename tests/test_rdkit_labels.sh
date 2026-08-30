#!/usr/bin/env bash
# Tests scripts/rdkit_labels.sh against a fixture mirroring Release_2025_09_2.
. "$(dirname "$0")/lib.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/rdkit_labels.sh"
FIXTURE="${REPO_ROOT}/tests/fixtures/rdkit-source"

out=$("$SCRIPT" "$FIXTURE")
assert_contains "$out" "rdkit_pickle_version=16.2.0" "pickle version matches SPEC 3.2 for 2025_09"
assert_contains "$out" "rdkit_cartridge_version=4.8.0" "cartridge version read from rdkit.control"
assert_eq "" "$(printf '%s\n' "$out" | grep -v '^[a-z_]*=' || true)" "every line is key=value"

assert_fails "missing source dir rejected" "$SCRIPT" /nonexistent
assert_fails "no argument rejected" "$SCRIPT"

finish
