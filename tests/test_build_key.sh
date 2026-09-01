#!/usr/bin/env bash
# The build key must be stable across identical inputs and change when any
# input that affects image content changes -- and must NOT change when
# versions.json changes (SPEC R6).
. "$(dirname "$0")/lib.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${REPO_ROOT}/scripts/build_key.sh"
D1="sha256:1111111111111111111111111111111111111111111111111111111111111111"
D2="sha256:2222222222222222222222222222222222222222222222222222222222222222"

cd "$REPO_ROOT"

# tests/test_build_key.sh mutates the TRACKED Dockerfile and versions.json in
# place below (to prove they're build-key inputs / non-inputs) and restores
# them afterward. Backups live in a private mktemp -d, not a fixed /tmp path
# (collision-prone, and a stale leftover from a previous interrupted run could
# be silently "restored" over a legitimate edit) -- and a trap on EXIT
# restores both files unconditionally, so a mid-test abort or an interrupt
# (this file's lib.sh sets no -e) can't leave the working tree corrupted.
BACKUP_DIR="$(mktemp -d)"
cp Dockerfile "${BACKUP_DIR}/Dockerfile.bak"
cp versions.json "${BACKUP_DIR}/versions.json.bak"
_restore_tracked_files() {
    cp "${BACKUP_DIR}/Dockerfile.bak" Dockerfile
    cp "${BACKUP_DIR}/versions.json.bak" versions.json
    rm -rf "$BACKUP_DIR"
}
trap _restore_tracked_files EXIT

base=$("$KEY" --rdkit 2025_09_2 --debian bookworm --base-digest "$D1")

echo "--- shape ---"
assert_eq "12" "${#base}" "key is 12 characters"
assert_eq "" "$(printf '%s' "$base" | tr -d '0-9a-f')" "key is lowercase hex"

echo "--- stability ---"
again=$("$KEY" --rdkit 2025_09_2 --debian bookworm --base-digest "$D1")
assert_eq "$base" "$again" "identical inputs give an identical key"

echo "--- sensitivity ---"
while IFS= read -r args; do
    [ -n "$args" ] || continue
    other=$("$KEY" $args)
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$other" != "$base" ]; then
        pass "key changes for: $args"
    else
        _fail "key did NOT change for: $args"
    fi
done <<ARGS
--rdkit 2025_03_6 --debian bookworm --base-digest $D1
--rdkit 2025_09_2 --debian trixie --base-digest $D1
--rdkit 2025_09_2 --debian bookworm --base-digest $D2
--rdkit 2025_09_2 --debian bookworm --base-digest $D1 --core-digest $D2
ARGS

echo "--- Dockerfile content is an input ---"
printf '\n# build-key sensitivity probe\n' >> Dockerfile
mutated=$("$KEY" --rdkit 2025_09_2 --debian bookworm --base-digest "$D1")
cp "${BACKUP_DIR}/Dockerfile.bak" Dockerfile
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$mutated" != "$base" ]; then
    pass "editing Dockerfile changes the key"
else
    _fail "editing Dockerfile did not change the key"
fi

echo "--- versions.json is NOT an input ---"
python3 - <<'PY'
import json
c = json.load(open("versions.json"))
c["postgres_majors"].append("99")
json.dump(c, open("versions.json", "w"))
PY
unaffected=$("$KEY" --rdkit 2025_09_2 --debian bookworm --base-digest "$D1")
cp "${BACKUP_DIR}/versions.json.bak" versions.json
assert_eq "$base" "$unaffected" "adding a pair does not invalidate existing keys"

echo "--- bad input is rejected ---"
assert_fails "missing --rdkit rejected" "$KEY" --debian bookworm --base-digest "$D1"
assert_fails "missing --base-digest rejected" "$KEY" --rdkit 2025_09_2 --debian bookworm
assert_fails "unknown flag rejected" "$KEY" --rdkit 2025_09_2 --debian bookworm --base-digest "$D1" --wat x

finish
