#!/usr/bin/env bash
# Functional smoke test for a built postgres-rdkit image (SPEC R8).
#
# Runs against the runtime image as a user would use it, which is what makes it
# a real backstop for the derived runtime package list (R3): a missing shared
# library fails here at LOAD time.
set -euo pipefail

image="${1:?usage: smoke_test.sh <image-ref>}"

docker image inspect "$image" >/dev/null 2>&1 \
    || docker pull "$image" >/dev/null 2>&1 \
    || { echo "ERROR: image ${image} not available locally or in a registry" >&2; exit 1; }

container="smoke-$(date +%s)-$$"
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "Starting ${image} as ${container}"
docker run -d --name "$container" -e POSTGRES_PASSWORD=smoke "$image" >/dev/null

# 1. Wait for readiness.
#
# pg_isready is probed over TCP on 127.0.0.1, not the default unix socket.
# The official postgres entrypoint runs initdb, then starts a TEMPORARY server
# with -c listen_addresses='' to execute /docker-entrypoint-initdb.d/* (which
# is where enable_extension.sql runs), stops it, and only then starts the real
# server. That temporary server already serves the unix socket, so a bare
# `pg_isready` can report ready before the init scripts have run -- a flake
# that looks exactly like a broken cartridge. The temporary server accepts no
# TCP, so probing 127.0.0.1 is true precisely when the real server is up.
for _ in $(seq 1 60); do
    if docker exec "$container" pg_isready -h 127.0.0.1 -U postgres -q 2>/dev/null; then
        break
    fi
    sleep 2
done
docker exec "$container" pg_isready -h 127.0.0.1 -U postgres -q || {
    echo "ERROR: container never became ready" >&2
    docker logs "$container" >&2
    exit 1
}
echo "ok: container ready"

# q <sql> -- run one or more ;-separated statements in a single session,
# printing only the unaligned result rows. -q suppresses command-completion
# tags (e.g. "SET") that psql would otherwise print for non-SELECT statements
# ahead of a SELECT's output in the same invocation.
q() { docker exec "$container" psql -U postgres -tAXq -c "$1"; }

# 2. CREATE EXTENSION. enable_extension.sql already runs it at initdb time, so
#    confirm the extension is installed rather than creating it twice.
installed=$(q "SELECT extversion FROM pg_extension WHERE extname = 'rdkit';")
[ -n "$installed" ] || { echo "ERROR: CREATE EXTENSION rdkit did not take effect" >&2; exit 1; }
echo "ok: CREATE EXTENSION rdkit (version ${installed})"

# 3. The mol type round-trips through the parser.
benzene=$(q "SELECT 'c1ccccc1'::mol;")
[ "$benzene" = "c1ccccc1" ] || { echo "ERROR: 'c1ccccc1'::mol returned '${benzene}'" >&2; exit 1; }
echo "ok: mol cast"

# 4. A substructure query using the GiST operator returns the expected row.
q "CREATE TABLE smoke (id int primary key, m mol);" >/dev/null
q "INSERT INTO smoke VALUES (1, 'Cc1ccccc1O'::mol), (2, 'CCO'::mol);" >/dev/null
q "CREATE INDEX smoke_m_idx ON smoke USING gist (m);" >/dev/null
q "ANALYZE smoke;" >/dev/null
hits=$(q "SET enable_seqscan = off; SELECT count(*) FROM smoke WHERE m @> 'c1ccccc1'::qmol;")
[ "$hits" = "1" ] || { echo "ERROR: GiST substructure query returned ${hits}, expected 1" >&2; exit 1; }
echo "ok: GiST substructure query"

# 5. A mol inserted in one session is byte-identical when read back in another,
#    compared as mol_send (the pickle path, SPEC section 3.2). The text form is
#    canonical SMILES, not the pickle, so comparing it would prove nothing.
stored=$(q "SELECT encode(mol_send(m), 'hex') FROM smoke WHERE id = 1;")
fresh=$(q "SELECT encode(mol_send('Cc1ccccc1O'::mol), 'hex');")
[ -n "$stored" ] || { echo "ERROR: mol_send returned nothing for the stored row" >&2; exit 1; }
[ "$stored" = "$fresh" ] || {
    echo "ERROR: mol_send round-trip differs" >&2
    echo "  stored: ${stored}" >&2
    echo "  fresh:  ${fresh}" >&2
    exit 1
}
echo "ok: mol_send round-trip is byte-identical across sessions"

# 6. mol_to_svg exercises the freetype dependency that deb-collector used to
#    ship and that RDKit's own test suite may not reach in the runtime image.
#    mol_to_svg returns cstring, not text, so length() needs an explicit cast.
svg_len=$(q "SELECT length(mol_to_svg('c1ccccc1'::mol)::text);")
[ -n "$svg_len" ] && [ "$svg_len" -gt 0 ] || {
    echo "ERROR: mol_to_svg returned empty output (freetype missing?)" >&2
    exit 1
}
echo "ok: mol_to_svg returned ${svg_len} bytes"

echo "SMOKE TEST PASSED: ${image}"
