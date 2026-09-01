#!/usr/bin/env bash
# Tests scripts/resolve_pg.sh. Parsing is tested against captured registry
# fixtures; one case hits the live registry to catch metadata-shape drift.
. "$(dirname "$0")/lib.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVE="${REPO_ROOT}/scripts/resolve_pg.sh"
export PG_FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/registry"

# get <output> <key> -> value
get() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

echo "--- major reference resolves to the current point release ---"
out=$("$RESOLVE" 17 bookworm)
assert_eq "17" "$(get "$out" postgres_major_version)" "major is 17"
assert_eq "17.11" "$(get "$out" postgres_point_version)" "point resolved from PG_VERSION"
assert_eq "17.11" "$(get "$out" postgres_current_point_version)" "current point is itself"
assert_eq "true" "$(get "$out" postgres_is_current)" "a major build is always current"
assert_contains "$(get "$out" postgres_base_digest)" "sha256:" "digest looks like a digest"
assert_contains "$(get "$out" postgres_base_image)" "docker.io/postgres:17-bookworm@sha256:" "base image is tag@digest"

echo "--- point reference older than current: moving tags must be withheld ---"
out=$("$RESOLVE" 17.9 bookworm)
assert_eq "17" "$(get "$out" postgres_major_version)" "major derived from the point ref"
assert_eq "17.9" "$(get "$out" postgres_point_version)" "point ref used directly"
assert_eq "17.11" "$(get "$out" postgres_current_point_version)" "current point still resolved"
assert_eq "false" "$(get "$out" postgres_is_current)" "older point is not current"
assert_contains "$(get "$out" postgres_base_image)" "postgres:17.9-bookworm@sha256:" "base image pins the point tag"

echo "--- output is shell-sourceable and GITHUB_OUTPUT-shaped ---"
out=$("$RESOLVE" 17 bookworm)
assert_eq "" "$(printf '%s\n' "$out" | grep -v '^[a-z_]*=' || true)" "every line is key=value"
TESTS_RUN=$((TESTS_RUN + 1))
if ( eval "$out"; [ "$postgres_major_version" = "17" ] ); then
    pass "output evals cleanly"
else
    _fail "output does not eval cleanly"
fi

echo "--- bad input is rejected ---"
assert_fails "empty ref rejected" "$RESOLVE" "" bookworm
assert_fails "missing suite rejected" "$RESOLVE" 17
assert_fails "non-numeric ref rejected" "$RESOLVE" seventeen bookworm

echo "--- live registry (no fixtures): metadata shape has not drifted ---"
if [ -z "${SKIP_LIVE:-}" ] && docker buildx version >/dev/null 2>&1; then
    out=$(env -u PG_FIXTURE_DIR "$RESOLVE" 17 bookworm)
    assert_contains "$out" "postgres_point_version=17." "live lookup returns a 17.x point version"
    assert_contains "$out" "postgres_base_digest=sha256:" "live lookup returns a digest"
else
    echo "skip: docker buildx unavailable or SKIP_LIVE set"
fi

finish
