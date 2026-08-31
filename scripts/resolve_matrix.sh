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
#   DISPATCH_RDKIT       on-demand: an RDKit release tag suffix, validated
#                         against ^[0-9]{4}_[0-9]{2}_[0-9]+$ (Ruling 39)
#   DISPATCH_DEBIAN      on-demand: suite override, validated against
#                         ^[a-z]+$ when set (Ruling 39); defaults to
#                         versions.json
#   SKIP_REGISTRY_CHECK  set to 1 to skip the "already built?" lookup
#
# Prints a JSON array to stdout; progress to stderr.
#
# --cores: print the distinct {rdkit, debian} pairs the resolved entries need
# a PostgreSQL-independent rdkit-core image for (R7), instead of the normal
# per-postgres-major matrix. One rdkit-core image is shared across every
# PostgreSQL major built for the same {rdkit, debian}, so this list is a
# de-duplication of the same entries the normal mode expands -- computed
# before the postgres-resolution loop below, so it needs no registry access
# and no resolve_pg.sh call.
set -euo pipefail

cores_only=0
while [ $# -gt 0 ]; do
    case "$1" in
        --cores) cores_only=1; shift ;;
        *) echo "ERROR: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

here="$(cd "$(dirname "$0")" && pwd)"
versions_file="${VERSIONS_FILE:-versions.json}"

default_debian=$("${here}/matrix.py" --file "$versions_file" --format debian)

if [ -n "${DISPATCH_POSTGRES:-}" ]; then
    : "${DISPATCH_RDKIT:?DISPATCH_RDKIT is required when DISPATCH_POSTGRES is set}"

    # DISPATCH_POSTGRES is validated downstream by resolve_pg.sh's own ref
    # check; DISPATCH_RDKIT and DISPATCH_DEBIAN have no such downstream gate,
    # so an unvalidated workflow_dispatch value would flow straight into an
    # image tag and into the "Compute tags" step's $GITHUB_OUTPUT heredoc
    # body (Ruling 39). Rejecting anything outside the expected shape here --
    # where dispatch values enter the system -- also rules out an embedded
    # newline, which could otherwise close a fixed-delimiter heredoc early.
    if [[ ! "$DISPATCH_RDKIT" =~ ^[0-9]{4}_[0-9]{2}_[0-9]+$ ]]; then
        echo "ERROR: '${DISPATCH_RDKIT}' is not a valid RDKit release tag (expected YYYY_MM_N, e.g. 2026_03_6)" >&2
        exit 1
    fi
    if [ -n "${DISPATCH_DEBIAN:-}" ] && [[ ! "$DISPATCH_DEBIAN" =~ ^[a-z]+$ ]]; then
        echo "ERROR: '${DISPATCH_DEBIAN}' is not a valid Debian suite name (expected lowercase letters, e.g. bookworm)" >&2
        exit 1
    fi

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

if [ "$cores_only" = 1 ]; then
    printf '%s' "$entries" | python3 -c '
import json, sys
items = json.load(sys.stdin)
seen = []
for item in items:
    pair = {"rdkit": item["rdkit"], "debian": item["debian"]}
    if pair not in seen:
        seen.append(pair)
print(json.dumps(seen))'
    exit 0
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

    # R7: fold the rdkit-core image's digest into the build key too, so a
    # core rebuild (a new RDKit patch, a Dockerfile.rdkit-core change) is
    # noticed the same way a new postgres base digest already is (R6).
    # `build_key.sh` already hashes Dockerfile.rdkit-core's own content, but
    # that alone is not enough: the core is `FROM debian:<suite>-slim`, a
    # moving tag, so its actual contents can change with no change to any
    # hashed input. The digest is the only thing that notices that.
    # IMAGE_REPO is "<registry>/<owner>/<repo>/postgres-rdkit" (see build.yml);
    # stripping the last path segment and appending "rdkit-core:<rdkit>-
    # <suite>" reaches the sibling repository build-rdkit-core publishes to.
    # Skipped under SKIP_REGISTRY_CHECK=1 like the postgres check below.
    #
    # Ruling 48: a lookup that FAILS (auth, network, missing buildx) must not
    # collapse into the same empty-string result as a core image that
    # genuinely does not exist yet -- those two cases are indistinguishable
    # from `2>/dev/null || echo ""`, and silently swallowing a real failure
    # here means the build key would silently, permanently omit a declared
    # input every future run, while CI stays green throughout. "Not found"
    # (the image doesn't exist yet for this {rdkit, debian} -- e.g. a brand
    # new pair, resolved before build-rdkit-core has ever pushed it) is the
    # one error shape this loop treats as benign; every other failure exits
    # loudly.
    #
    # Ruling 45's residual: resolve-matrix always runs BEFORE
    # build-rdkit-core, so this digest is always at best the PREVIOUS run's
    # (or, for a brand-new pair, empty on the very first run). A newly added
    # pair therefore builds twice before converging: run N publishes the
    # runtime image under a key with an empty core digest (K0) and
    # build-rdkit-core pushes the core for the first time; run N+1 resolves
    # the now-published digest, computes a different key (K1), finds no
    # `K1` tag yet, and rebuilds once more; run N+2 resolves the same
    # (provenance: false, so byte-stable) digest again, computes K1 again,
    # finds it already built, and converges. This is accepted, not a bug to
    # chase -- see Ruling 45.
    core_digest=""
    if [ "${SKIP_REGISTRY_CHECK:-}" != "1" ]; then
        : "${IMAGE_REPO:?IMAGE_REPO is required unless SKIP_REGISTRY_CHECK=1}"
        core_ref="${IMAGE_REPO%/*}/rdkit-core:${rdkit}-${suite}"
        # `if var=$(cmd)` (not a bare `var=$(cmd)`), so a nonzero exit from
        # `docker` here does not trip `set -e` before `$?` can be read -- a
        # bare assignment's exit status IS the command substitution's exit
        # status, and set -e aborts the script on it immediately outside a
        # conditional, before the `elif` below ever runs.
        if core_inspect_output=$(docker buildx imagetools inspect "$core_ref" --format '{{json .Manifest}}' 2>&1); then
            core_inspect_rc=0
        else
            core_inspect_rc=$?
        fi
        if [ "$core_inspect_rc" -eq 0 ]; then
            core_digest=$(printf '%s' "$core_inspect_output" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("digest",""))')
        elif printf '%s' "$core_inspect_output" | grep -qiE 'not found|no such manifest|manifest unknown|name unknown|name_unknown'; then
            core_digest=""
        else
            echo "ERROR: rdkit-core digest lookup failed for ${core_ref}:" >&2
            printf '%s\n' "$core_inspect_output" >&2
            exit 1
        fi
    fi

    key=$("${here}/build_key.sh" \
        --rdkit "$rdkit" \
        --debian "$suite" \
        --base-digest "$postgres_base_digest" \
        --core-digest "$core_digest")

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
