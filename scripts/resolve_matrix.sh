#!/usr/bin/env bash
# Expand the build matrix into fully-resolved entries, dropping anything whose
# build key already exists in the registry (SPEC R6).
#
# Reads versions.json unless DISPATCH_POSTGRES is set, in which case it produces
# exactly the one on-demand pair (SPEC R11).
#
# Environment:
#   IMAGE_REPO           registry path used for the existence check
#   VERSIONS_FILE        defaults to versions.json
#   DISPATCH_POSTGRES    on-demand: a major or point release
#   DISPATCH_RDKIT       on-demand: an RDKit release tag suffix
#   DISPATCH_DEBIAN      on-demand: suite override, defaults to versions.json
#   SKIP_REGISTRY_CHECK  set to 1 to skip the "already built?" lookup
#
# Prints a JSON array to stdout; progress to stderr.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
versions_file="${VERSIONS_FILE:-versions.json}"

default_debian=$("${here}/matrix.py" --file "$versions_file" --format debian)

if [ -n "${DISPATCH_POSTGRES:-}" ]; then
    : "${DISPATCH_RDKIT:?DISPATCH_RDKIT is required when DISPATCH_POSTGRES is set}"
    export _PG="$DISPATCH_POSTGRES" _RDKIT="$DISPATCH_RDKIT" \
           _DEBIAN="${DISPATCH_DEBIAN:-$default_debian}"
    entries=$(python3 -c '
import json, os
print(json.dumps([{
    "postgres_major": os.environ["_PG"],
    "rdkit": os.environ["_RDKIT"],
    "debian": os.environ["_DEBIAN"],
}]))')
else
    entries=$("${here}/matrix.py" --file "$versions_file" --format json)
fi

resolved="[]"

while read -r entry; do
    [ -n "$entry" ] || continue
    export _ENTRY="$entry"
    pg=$(python3 -c 'import json,os; print(json.loads(os.environ["_ENTRY"])["postgres_major"])')
    rdkit=$(python3 -c 'import json,os; print(json.loads(os.environ["_ENTRY"])["rdkit"])')
    suite=$(python3 -c 'import json,os; print(json.loads(os.environ["_ENTRY"])["debian"])')

    # R4: resolve the point release and base digest before the build so every
    # tag is known up front and the image is built and pushed exactly once.
    # Captured into a plain assignment (not inlined into `eval`'s argument) so
    # a resolve_pg.sh failure trips `set -e` here -- inlined, the failure is
    # invisible to `set -e` and `eval` of the resulting empty string silently
    # leaves the PREVIOUS iteration's postgres_* variables in place, emitting
    # a duplicated, wrong entry instead of erroring.
    pg_output=$("${here}/resolve_pg.sh" "$pg" "$suite")
    eval "$pg_output"

    key=$("${here}/build_key.sh" \
        --rdkit "$rdkit" \
        --debian "$suite" \
        --base-digest "$postgres_base_digest")

    if [ "${SKIP_REGISTRY_CHECK:-}" != "1" ]; then
        key_tag="${IMAGE_REPO:?IMAGE_REPO is required unless SKIP_REGISTRY_CHECK=1}:postgres-${postgres_major_version}-rdkit-${rdkit}-${key}"
        if docker manifest inspect "$key_tag" >/dev/null 2>&1; then
            echo "skip: ${key_tag} already exists" >&2
            continue
        fi
    fi

    export _ACC="$resolved" _MAJOR="$postgres_major_version" \
           _POINT="$postgres_point_version" _IS_CURRENT="$postgres_is_current" \
           _BASE_IMAGE="$postgres_base_image" _BASE_DIGEST="$postgres_base_digest" \
           _RDKIT_V="$rdkit" _SUITE="$suite" _KEY="$key"
    resolved=$(python3 -c '
import json, os
acc = json.loads(os.environ["_ACC"])
acc.append({
    "postgres_major": os.environ["_MAJOR"],
    "postgres_point": os.environ["_POINT"],
    "postgres_is_current": os.environ["_IS_CURRENT"],
    "postgres_base_image": os.environ["_BASE_IMAGE"],
    "postgres_base_digest": os.environ["_BASE_DIGEST"],
    "rdkit": os.environ["_RDKIT_V"],
    "debian": os.environ["_SUITE"],
    "build_key": os.environ["_KEY"],
})
print(json.dumps(acc))')
done < <(printf '%s' "$entries" | python3 -c '
import json, sys
for item in json.load(sys.stdin):
    print(json.dumps(item))')

printf '%s\n' "$resolved"
