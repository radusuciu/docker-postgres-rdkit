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

echo "--- --cores projects to {rdkit, debian} only (no postgres_major) ---"
# /tmp/versions-one.json (written above) has only ONE postgres major, so on
# its own this assertion does not distinguish "--cores dedupes" from
# "--cores just re-shapes the same 2 entries" -- it only proves the output
# carries the right keys. The de-duplication claim itself is proven by the
# next block, against a fixture with TWO postgres majors (Ruling 44: the
# reviewer showed this fixture alone makes len(d)==2 true whether or not
# de-duplication is implemented, since it already has only two distinct
# {rdkit, debian} pairs -- that was a wrong-reason assertion and is why this
# block is now split from the real de-duplication test below).
out=$(env -u DISPATCH_POSTGRES PG_FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/registry" \
      VERSIONS_FILE=/tmp/versions-one.json "$RESOLVE" --cores)
assert_eq "debian,rdkit" "$(jqlike "$out" '",".join(sorted(d[0]))')" "core entries carry only rdkit and debian"

echo "--- --cores de-duplicates by (rdkit, debian) (Ruling 44) ---"
# TWO postgres majors x TWO rdkit versions = 4 matrix entries (verified
# directly below, against the SAME fixture, with no --cores flag) but only 2
# distinct {rdkit, debian} pairs. This is the assertion that actually falls
# over if de-duplication is removed and --cores instead returns one entry
# per matrix entry (4, not 2) -- unlike the single-postgres-major fixture
# above, which stays green either way. No registry fixture is needed: --cores
# exits before resolve_pg.sh is ever called, so a second postgres major here
# costs nothing.
cat > /tmp/versions-cores.json <<'JSON'
{"debian":"bookworm","postgres_majors":["17","16"],"rdkit_versions":["2026_03_6","2025_09_6"],"exclude":[]}
JSON
cores_fixture_matrix=$(env -u DISPATCH_POSTGRES VERSIONS_FILE=/tmp/versions-cores.json \
      "${REPO_ROOT}/scripts/matrix.py" --file /tmp/versions-cores.json --format json)
assert_eq "4" "$(jqlike "$cores_fixture_matrix" 'len(d)')" "fixture sanity check: 2 majors x 2 rdkit versions is 4 matrix entries"
out=$(env -u DISPATCH_POSTGRES PG_FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/registry" \
      VERSIONS_FILE=/tmp/versions-cores.json "$RESOLVE" --cores)
assert_eq "2" "$(jqlike "$out" 'len(d)')" "4 matrix entries de-duplicate to 2 core images"

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
# assert_rejects_with (not a bare assert_fails; now shared in tests/lib.sh)
# is deliberate: I mutation-tested this by temporarily deleting the new
# validation block and re-running this file. The two DISPATCH_RDKIT cases
# below correctly flipped to FAIL, as expected -- but the two DISPATCH_DEBIAN
# cases kept passing anyway, because an unvalidated DISPATCH_DEBIAN still
# makes resolve_pg.sh's PG_FIXTURE_DIR lookup fail on its own (no fixture
# file matches a mangled suite name), so the script still exited non-zero for
# an UNRELATED reason. A bare exit-code check on those two would therefore
# have passed even with the validation deleted -- exactly what Ruling 39 says
# not to write. Matching each rejection's specific error text pins every
# assertion to the guard actually added for Ruling 39, not to an incidental
# downstream failure.
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
# read anonymously, so Step 5's dry run can never exercise it). The core
# digest lookup (`buildx imagetools inspect`, R7) runs first in every
# iteration regardless of the postgres-side check below, so this stub must
# answer it too -- "not found" (a real, benign shape, per Ruling 48) rather
# than falling through to the catch-all `exit 1`, which the digest lookup
# would now (correctly) treat as a genuine failure and abort the whole run.
STUB_BIN="$(mktemp -d)"
cat > "${STUB_BIN}/docker" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "buildx" ] && [ "$2" = "imagetools" ] && [ "$3" = "inspect" ]; then
    echo "ERROR: $4: not found" >&2
    exit 1
fi
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

echo "--- rdkit-core digest lookup: 'not found' is benign, not an error (Ruling 48) ---"
# A stub `docker` whose `buildx imagetools inspect` logs the queried ref and
# reports a "not found" error (the shape a brand-new {rdkit, debian} pair --
# not yet pushed by build-rdkit-core -- actually produces), and whose
# `manifest inspect` (the key_tag "already built?" check, also "not found"-
# shaped: this is a brand-new pair, so neither lookup has anything to find)
# never short-circuits this entry, so the run reaches the resolved output.
# This proves two things a bare "did it crash" check would not: the exact
# ref queried (${IMAGE_REPO%/*}/rdkit-core:<rdkit>-<suite>), and that a
# "not found" lookup does NOT abort the run.
STUB_BIN="$(mktemp -d)"
CORE_REF_LOG="$(mktemp)"
cat > "${STUB_BIN}/docker" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "buildx" ] && [ "\$2" = "imagetools" ] && [ "\$3" = "inspect" ]; then
    echo "\$4" >> "${CORE_REF_LOG}"
    echo "ERROR: \$4: not found" >&2
    exit 1
fi
if [ "\$1" = "manifest" ] && [ "\$2" = "inspect" ]; then
    echo "ERROR: \$2: manifest unknown" >&2
    exit 1
fi
exit 1
STUB
chmod +x "${STUB_BIN}/docker"

out=$(env -u SKIP_REGISTRY_CHECK PATH="${STUB_BIN}:${PATH}" \
      PG_FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/registry" \
      VERSIONS_FILE=/tmp/versions-one.json "$RESOLVE")
rc=$?
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$rc" -eq 0 ]; then
    pass "'not found' core digest lookup does not fail the run"
else
    _fail "'not found' core digest lookup unexpectedly failed the run"
fi
assert_eq "2" "$(jqlike "$out" 'len(d)')" "entries still resolve when the core digest is merely unpublished"
assert_eq "ghcr.io/example/rdkit-core:2026_03_6-bookworm" "$(head -n1 "$CORE_REF_LOG")" \
    "core_ref is constructed from IMAGE_REPO's registry/owner/repo, not postgres-rdkit's own name"
rm -rf "$STUB_BIN" "$CORE_REF_LOG"

echo "--- rdkit-core digest lookup: a genuine failure is NOT silently swallowed (Ruling 48) ---"
# Same shape, but the stub reports an unrelated failure (auth/network/a
# missing buildx plugin), not "not found". Before this fix, `2>/dev/null ||
# echo ""` made this indistinguishable from "not published yet" and the run
# stayed green forever with a build key silently missing this input.
STUB_BIN="$(mktemp -d)"
cat > "${STUB_BIN}/docker" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "buildx" ] && [ "$2" = "imagetools" ] && [ "$3" = "inspect" ]; then
    echo "denied: authentication required" >&2
    exit 1
fi
if [ "$1" = "manifest" ] && [ "$2" = "inspect" ]; then
    exit 1
fi
exit 1
STUB
chmod +x "${STUB_BIN}/docker"

err_out=$(env -u SKIP_REGISTRY_CHECK PATH="${STUB_BIN}:${PATH}" \
      PG_FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/registry" \
      VERSIONS_FILE=/tmp/versions-one.json "$RESOLVE" 2>&1)
rc=$?
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$rc" -ne 0 ]; then
    pass "a genuine core digest lookup failure fails the run"
else
    _fail "a genuine core digest lookup failure was silently swallowed (exited 0)"
fi
assert_contains "$err_out" "digest lookup failed" "the failure names what failed"
rm -rf "$STUB_BIN"

echo "--- build-key existence check: a genuine AUTH failure is NOT silently swallowed (Ruling 57) ---"
# Same shape as the two Ruling 48 blocks above, but for the OTHER `docker`
# lookup in this loop: the postgres-side "already built?" check at
# scripts/resolve_matrix.sh's key_tag block. The core digest lookup
# ('buildx imagetools inspect') reports a benign "not found" (a brand-new
# {rdkit, debian} pair, GHCR's normal shape on the very first run) so the
# loop reaches the key_tag check; THAT lookup ('docker manifest inspect')
# then fails with an auth-shaped error, not "not found" -- exactly the
# scenario the brief calls out: rdkit-core is public but postgres-rdkit is
# not yet readable. Before this fix, `docker manifest inspect ...
# >/dev/null 2>&1` made this indistinguishable from "does not exist yet", so
# the entry would be silently INCLUDED (never skipped) -- the exact same
# collapse Ruling 48 already fixed for the core digest lookup, just on the
# other call. Mutation-tested: reverting resolve_matrix.sh's key_tag block
# to the old `if docker manifest inspect "$key_tag" >/dev/null 2>&1; then`
# form makes this block wrongly PASS the "run succeeds" assertions below
# (auth failure treated as "not built", entry silently included) while this
# new assertion correctly flips to FAIL.
STUB_BIN="$(mktemp -d)"
cat > "${STUB_BIN}/docker" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "buildx" ] && [ "$2" = "imagetools" ] && [ "$3" = "inspect" ]; then
    echo "ERROR: $4: not found" >&2
    exit 1
fi
if [ "$1" = "manifest" ] && [ "$2" = "inspect" ]; then
    echo "denied: requested access to the resource is denied" >&2
    exit 1
fi
exit 1
STUB
chmod +x "${STUB_BIN}/docker"

err_out=$(env -u SKIP_REGISTRY_CHECK PATH="${STUB_BIN}:${PATH}" \
      PG_FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/registry" \
      VERSIONS_FILE=/tmp/versions-one.json "$RESOLVE" 2>&1)
rc=$?
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$rc" -ne 0 ]; then
    pass "a genuine build-key existence check failure fails the run"
else
    _fail "a genuine build-key existence check failure was silently swallowed (exited 0, entry included)"
fi
assert_contains "$err_out" "build-key existence check failed" "the failure names what failed"
rm -rf "$STUB_BIN"

finish
