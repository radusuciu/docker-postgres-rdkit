#!/usr/bin/env bash
# Meta-test: the smoke test must pass on a real image and fail on a plain one.
# Set SMOKE_IMAGE to the runtime image built by `make runtime`.
. "$(dirname "$0")/lib.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SMOKE="${REPO_ROOT}/scripts/smoke_test.sh"
IMAGE="${SMOKE_IMAGE:-postgres-rdkit:postgres-17-rdkit-2026_03_6}"

echo "--- rejects bad input ---"
assert_fails "no argument rejected" "$SMOKE"
assert_fails "nonexistent image rejected" "$SMOKE" "does-not-exist.invalid/nope:nope"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "skip: ${IMAGE} not built; run 'make runtime' first (set SMOKE_IMAGE to override)"
    finish
    exit $?
fi

echo "--- passes on the built runtime image ---"
out=$("$SMOKE" "$IMAGE" 2>&1); rc=$?
printf '%s\n' "$out" | tail -20
assert_eq "0" "$rc" "smoke test passes on the runtime image"
assert_contains "$out" "CREATE EXTENSION" "reports the extension check"
assert_contains "$out" "mol_to_svg" "reports the SVG check"
assert_contains "$out" "mol_send round-trip" "reports the pickle round-trip check"

echo "--- fails on a stock postgres image with no cartridge ---"
# Not a bare assert_fails: that passes on ANY non-zero exit, including a
# failed image pull or a timed-out readiness loop, neither of which proves
# the smoke test actually detected the missing cartridge. Pin the specific
# failure: `CREATE EXTENSION rdkit did not take effect` is what smoke_test.sh
# prints when the extension genuinely isn't there (scripts/smoke_test.sh:54).
assert_rejects_with "stock postgres image fails the smoke test" \
    "CREATE EXTENSION rdkit did not take effect" \
    "$SMOKE" "docker.io/postgres:17-bookworm"

finish
