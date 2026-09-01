#!/usr/bin/env bash
# Resolve a PostgreSQL major-or-point reference against the official images.
#
# The matrix declares majors only (SPEC R4): PostgreSQL ships patch releases for
# every supported major roughly quarterly, and pinning point releases in a
# tracked file would mean a config change, a PR and a full rebuild every cycle
# for images that already exist immutably in the registry. Building against the
# major tag picks up patch and CVE updates at zero configuration cost.
#
# The concrete point release is read from the base image's own PG_VERSION env
# var, without pulling layers. Resolving BEFORE the build means every tag is
# known up front and the image is built and pushed exactly once.
#
# Usage: resolve_pg.sh <major|major.minor> <debian-suite>
# Emits key=value lines suitable for `eval`, `source`, or >> "$GITHUB_OUTPUT".
#
# Test seam: set PG_FIXTURE_DIR to read captured JSON instead of the registry.
set -euo pipefail

ref="${1:-}"
suite="${2:-}"

[ -n "$ref" ]   || { echo "usage: resolve_pg.sh <major|major.minor> <debian-suite>" >&2; exit 1; }
[ -n "$suite" ] || { echo "usage: resolve_pg.sh <major|major.minor> <debian-suite>" >&2; exit 1; }

case "$ref" in
    *[!0-9.]*|.*|*.) echo "ERROR: '${ref}' is not a PostgreSQL major or point release" >&2; exit 1 ;;
esac

major="${ref%%.*}"
[ -n "$major" ] || { echo "ERROR: could not derive a major from '${ref}'" >&2; exit 1; }

_fixture_name() {
    # docker.io/postgres:17-bookworm -> postgres_17-bookworm
    printf '%s' "${1#docker.io/}" | tr '/:' '__'
}

# _image_json <image-ref> -- the per-platform image config map
_image_json() {
    if [ -n "${PG_FIXTURE_DIR:-}" ]; then
        cat "${PG_FIXTURE_DIR}/$(_fixture_name "$1").image.json"
    else
        docker buildx imagetools inspect "$1" --format '{{json .Image}}'
    fi
}

# _manifest_json <image-ref> -- the manifest (or index) descriptor
_manifest_json() {
    if [ -n "${PG_FIXTURE_DIR:-}" ]; then
        cat "${PG_FIXTURE_DIR}/$(_fixture_name "$1").manifest.json"
    else
        docker buildx imagetools inspect "$1" --format '{{json .Manifest}}'
    fi
}

# _full_json <image-ref> -- {"image": ..., "manifest": ...} in ONE round trip.
# For a major reference, base_image_tag and major_ref are the same string, so
# resolving both the point version and the digest against it would otherwise
# mean two separate `docker buildx imagetools inspect` calls (i.e. two
# anonymous Docker Hub manifest requests) for the same image. Used only by
# that shared-ref case below; the point-pinned branch queries two genuinely
# different refs and still makes two calls.
#
# Verified against a live `docker buildx imagetools inspect ... --format
# '{{json .}}'` response: unlike `{{json .Image}}` / `{{json .Manifest}}`
# (which address Go struct fields directly, capitalized), marshaling the
# WHOLE object serializes struct field names via their lowercase json tags --
# "image", "manifest", "name" -- not "Image"/"Manifest". Do not "fix" the
# casing below to match the Go field names; it was checked against the real
# registry, not assumed.
_full_json() {
    if [ -n "${PG_FIXTURE_DIR:-}" ]; then
        python3 -c '
import json, sys
image = json.load(open(sys.argv[1]))
manifest = json.load(open(sys.argv[2]))
print(json.dumps({"image": image, "manifest": manifest}))
' "${PG_FIXTURE_DIR}/$(_fixture_name "$1").image.json" "${PG_FIXTURE_DIR}/$(_fixture_name "$1").manifest.json"
    else
        docker buildx imagetools inspect "$1" --format '{{json .}}'
    fi
}

# _point_version <image-ref>
# PG_VERSION looks like "17.11-1.pgdg12+2"; the point version is the part before
# the first '-'. On a multi-arch manifest list {{json .Image}} returns a
# per-platform map, and we build only linux/amd64 (SPEC section 11).
_point_version() {
    _image_json "$1" | python3 -c '
import json, sys
data = json.load(sys.stdin)
config = data.get("linux/amd64", data) if isinstance(data, dict) else data
if "config" not in config:
    sys.exit("ERROR: no linux/amd64 image config in registry metadata")
for entry in config["config"].get("Env", []):
    if entry.startswith("PG_VERSION="):
        print(entry.split("=", 1)[1].split("-", 1)[0])
        break
else:
    sys.exit("ERROR: PG_VERSION not found in image config")
'
}

_digest() {
    _manifest_json "$1" | python3 -c '
import json, sys
digest = json.load(sys.stdin).get("digest")
if not digest:
    sys.exit("ERROR: no digest in manifest metadata")
print(digest)
'
}

# Same extraction as _point_version/_digest above, but reading from a single
# already-fetched _full_json response instead of issuing its own inspect call.
_point_version_from_full() {
    python3 -c '
import json, sys
data = json.load(sys.stdin)
config = data.get("image")
config = config.get("linux/amd64", config) if isinstance(config, dict) else config
if "config" not in config:
    sys.exit("ERROR: no linux/amd64 image config in registry metadata")
for entry in config["config"].get("Env", []):
    if entry.startswith("PG_VERSION="):
        print(entry.split("=", 1)[1].split("-", 1)[0])
        break
else:
    sys.exit("ERROR: PG_VERSION not found in image config")
'
}

_digest_from_full() {
    python3 -c '
import json, sys
digest = (json.load(sys.stdin).get("manifest") or {}).get("digest")
if not digest:
    sys.exit("ERROR: no digest in manifest metadata")
print(digest)
'
}

major_ref="docker.io/postgres:${major}-${suite}"

if [ "$ref" = "$major" ]; then
    # A major reference builds against the moving major tag: base_image_tag
    # and major_ref are the SAME ref, so the point version and the digest are
    # both read from one fetch instead of two.
    base_image_tag="$major_ref"
    full=$(_full_json "$major_ref")
    current_point=$(printf '%s' "$full" | _point_version_from_full)
    point="$current_point"
    digest=$(printf '%s' "$full" | _digest_from_full)
else
    # A point reference pins an immutable base image, but the major's current
    # point release is still resolved so the moving-tag guard can be applied.
    # major_ref and base_image_tag are genuinely different refs here, so this
    # is still two calls.
    current_point=$(_point_version "$major_ref")
    point="$ref"
    base_image_tag="docker.io/postgres:${ref}-${suite}"
    digest=$(_digest "$base_image_tag")
fi

if [ "$point" = "$current_point" ]; then
    is_current=true
else
    is_current=false
fi

cat <<OUT
postgres_major_version=${major}
postgres_point_version=${point}
postgres_current_point_version=${current_point}
postgres_is_current=${is_current}
postgres_base_digest=${digest}
postgres_base_image=${base_image_tag}@${digest}
OUT
