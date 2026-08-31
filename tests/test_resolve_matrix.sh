#!/usr/bin/env bash
# Tests scripts/resolve_matrix.sh with the registry check disabled and
# resolve_pg.sh backed by fixtures.
. "$(dirname "$0")/lib.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVE="${REPO_ROOT}/scripts/resolve_matrix.sh"
cd "$REPO_ROOT"

export SKIP_REGISTRY_CHECK=1
export IMAGE_REPO="ghcr.io/example/postgres-rdkit"

# jqlike <json> <python-expr over `d`>
jqlike() { printf '%s' "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print($2)"; }

echo "--- matrix mode: one entry per non-excluded pair ---"
# The registry fixtures only cover PostgreSQL 17, so restrict the matrix here.
# The full 10-entry cross product is covered by tests/test_matrix.py.
# rdkit_versions are the pair versions.json actually ships (C3): the 2025_03
# family (and 2025_09_2) are documented UNBUILDABLE and must not appear here.
cat > /tmp/versions-one.json <<'JSON'
{"debian":"bookworm","postgres_majors":["17"],"rdkit_versions":["2026_03_6","2025_09_6"],"exclude":[]}
JSON
out=$(env -u DISPATCH_POSTGRES \
      PG_FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/registry" \
      VERSIONS_FILE=/tmp/versions-one.json "$RESOLVE")
assert_eq "2" "$(jqlike "$out" 'len(d)')" "one entry per rdkit version"
assert_eq "17" "$(jqlike "$out" 'd[0]["postgres_major"]')" "major carried through"
assert_eq "17.11" "$(jqlike "$out" 'd[0]["postgres_point"]')" "point resolved"
assert_eq "true" "$(jqlike "$out" 'd[0]["postgres_is_current"]')" "major build is current"
assert_eq "2026_03_6" "$(jqlike "$out" 'd[0]["rdkit"]')" "highest rdkit first"
assert_eq "12" "$(jqlike "$out" 'len(d[0]["build_key"])')" "build key is 12 chars"

echo "--- build keys differ per rdkit version ---"
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$(jqlike "$out" 'd[0]["build_key"]')" != "$(jqlike "$out" 'd[1]["build_key"]')" ]; then
    pass "each rdkit version gets its own build key"
else
    _fail "build keys collided across rdkit versions"
fi

echo "--- --cores de-duplicates by (rdkit, debian) ---"
# /tmp/versions-one.json (written above) cross-products 1 postgres major with
# 2 rdkit versions -- 2 matrix entries, but --cores reports the R7 build
# (SPEC R7): one PostgreSQL-independent rdkit-core image per distinct
# {rdkit_version, debian}, not one per matrix entry. len(d) == 2 here would
# also pass if --cores just echoed the un-deduplicated matrix back (this
# fixture happens to have only one postgres major), so it alone does not
# prove de-duplication -- but combined with the second assertion (each core
# entry carries ONLY rdkit and debian, not postgres_major) it does: an
# unimplemented/removed --cores that instead returned the full matrix
# entries would fail THAT assertion, since matrix entries also carry
# postgres_major. Both assertions fail if the flag is dropped entirely (the
# command would then error on an unknown argument).
out=$(env -u DISPATCH_POSTGRES PG_FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/registry" \
      VERSIONS_FILE=/tmp/versions-one.json "$RESOLVE" --cores)
assert_eq "2" "$(jqlike "$out" 'len(d)')" "two rdkit versions give two core images"
assert_eq "debian,rdkit" "$(jqlike "$out" '",".join(sorted(d[0]))')" "core entries carry only rdkit and debian"

echo "--- dispatch mode: exactly the requested pair ---"
out=$(DISPATCH_POSTGRES=17.9 DISPATCH_RDKIT=2023_09_6 \
      PG_FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/registry" "$RESOLVE")
assert_eq "1" "$(jqlike "$out" 'len(d)')" "dispatch produces exactly one entry"
assert_eq "17.9" "$(jqlike "$out" 'd[0]["postgres_point"]')" "point ref used directly"
assert_eq "false" "$(jqlike "$out" 'd[0]["postgres_is_current"]')" "older point is not current"
assert_eq "2023_09_6" "$(jqlike "$out" 'd[0]["rdkit"]')" "requested rdkit used"
assert_eq "bookworm" "$(jqlike "$out" 'd[0]["debian"]')" "debian defaults to versions.json"

echo "--- dispatch mode honours the debian override ---"
# C1: the bullseye fixtures are a distinguishable copy of the bookworm ones
# (different manifest digest), so a passing assertion here proves the suite
# actually reached resolve_pg.sh rather than merely being echoed back.
bullseye_digest=$(python3 -c "
import json
print(json.load(open('${REPO_ROOT}/tests/fixtures/registry/postgres_17-bullseye.manifest.json'))['digest'])
")
out=$(DISPATCH_POSTGRES=17 DISPATCH_RDKIT=2023_09_6 DISPATCH_DEBIAN=bullseye \
      PG_FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/registry" "$RESOLVE")
assert_eq "bullseye" "$(jqlike "$out" 'd[0]["debian"]')" "debian override reaches the entry"
assert_eq "$bullseye_digest" "$(jqlike "$out" 'd[0]["postgres_base_digest"]')" \
    "debian override reaches resolve_pg.sh (base digest is bullseye's, not bookworm's)"

echo "--- dispatch mode validates DISPATCH_RDKIT / DISPATCH_DEBIAN (Ruling 39) ---"
# "a valid value passes" is already covered above: every dispatch-mode test
# so far used DISPATCH_RDKIT=2023_09_6 (and DISPATCH_DEBIAN=bullseye) and
# succeeded. These cases cover rejection, including the embedded-newline
# case Ruling 39 calls out by name -- the exact value that could otherwise
# close the workflow's $GITHUB_OUTPUT heredoc early. PG_FIXTURE_DIR is passed
# to every case (even though a correctly-rejecting script never reaches it)
# so that if the validation ever regresses away, the fallback path still
# can't reach the live network.
#
# assert_rejects_with (not a bare assert_fails) is deliberate: I mutation-
# tested this by temporarily deleting the new validation block and re-running
# this file. The two DISPATCH_RDKIT cases below correctly flipped to FAIL, as
# expected -- but the two DISPATCH_DEBIAN cases kept passing anyway, because
# an unvalidated DISPATCH_DEBIAN still makes resolve_pg.sh's PG_FIXTURE_DIR
# lookup fail on its own (no fixture file matches a mangled suite name), so
# the script still exited non-zero for an UNRELATED reason. A bare exit-code
# check on those two would therefore have passed even with the validation
# deleted -- exactly what Ruling 39 says not to write. Matching each
# rejection's specific error text pins every assertion to the guard actually
# added for Ruling 39, not to an incidental downstream failure.
assert_rejects_with() {
    local desc="$1" expected_msg="$2"; shift 2
    TESTS_RUN=$((TESTS_RUN + 1))
    local out rc
    out=$("$@" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
        _fail "$desc (command unexpectedly succeeded)"
    elif printf '%s' "$out" | grep -qF -- "$expected_msg"; then
        pass "$desc"
    else
        _fail "$desc (failed, but not with the expected message)"
        printf '  expected to contain: %s\n  actual output: %s\n' "$expected_msg" "$out" >&2
    fi
}

assert_rejects_with "rdkit with an embedded newline is rejected" \
    "is not a valid RDKit release tag" \
    env DISPATCH_POSTGRES=17 "DISPATCH_RDKIT=$(printf '2023_09_6\nEXTRA=malicious')" \
        PG_FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/registry" "$RESOLVE"

assert_rejects_with "rdkit with a non-matching shape is rejected" \
    "is not a valid RDKit release tag" \
    env DISPATCH_POSTGRES=17 DISPATCH_RDKIT="not-a-version" \
        PG_FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/registry" "$RESOLVE"

assert_rejects_with "debian with an embedded newline is rejected" \
    "is not a valid Debian suite name" \
    env DISPATCH_POSTGRES=17 DISPATCH_RDKIT=2023_09_6 \
        "DISPATCH_DEBIAN=$(printf 'bookworm\nEXTRA=malicious')" \
        PG_FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/registry" "$RESOLVE"

assert_rejects_with "debian with disallowed characters is rejected" \
    "is not a valid Debian suite name" \
    env DISPATCH_POSTGRES=17 DISPATCH_RDKIT=2023_09_6 DISPATCH_DEBIAN="Bookworm2" \
        PG_FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/registry" "$RESOLVE"

echo "--- output always parses as a JSON list ---"
out=$(DISPATCH_POSTGRES=17.9 DISPATCH_RDKIT=2023_09_6 \
      PG_FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/registry" "$RESOLVE")
assert_eq "list" "$(jqlike "$out" 'type(d).__name__')" "output parses as a JSON array (list)"

echo "--- registry check (for real) skips entries that already exist ---"
# C2(b): a stub `docker` ahead of PATH whose `manifest inspect` always
# succeeds, with SKIP_REGISTRY_CHECK unset, must yield an empty result -- this
# is the only coverage the R6 skip branch gets (the live GHCR repo cannot be
# read anonymously, so Step 5's dry run can never exercise it).
STUB_BIN="$(mktemp -d)"
cat > "${STUB_BIN}/docker" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "manifest" ] && [ "$2" = "inspect" ]; then
    exit 0
fi
exit 1
STUB
chmod +x "${STUB_BIN}/docker"

out=$(env -u SKIP_REGISTRY_CHECK PATH="${STUB_BIN}:${PATH}" \
      PG_FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/registry" \
      VERSIONS_FILE=/tmp/versions-one.json "$RESOLVE")
assert_eq "0" "$(jqlike "$out" 'len(d)')" "registry check (for real) skips entries that already exist"
rm -rf "$STUB_BIN"

finish
