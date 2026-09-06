#!/usr/bin/env python3
"""Resolve the build matrix into fully specified entries.

Expands versions.json (or the one pair a workflow_dispatch asked for) through
matrix.py, resolves each PostgreSQL reference to its current point release and
base-image digest from Docker Hub metadata, and drops entries whose point tag
is already published. Resolving before the build means every tag is known up
front and each image is built and pushed exactly once.

    resolve_matrix.py [--format matrix|cores|latest|debian] [--force] [--entries FILE]
    resolve_matrix.py resolve-pg <major|major.minor> <suite>

Environment:
  IMAGE_REPO           registry path for the existence check, e.g.
                       ghcr.io/owner/repo/postgres-rdkit
  VERSIONS_FILE        defaults to versions.json (or pass --file)
  DISPATCH_POSTGRES    on-demand: a major (17) or point release (17.11)
  DISPATCH_RDKIT       on-demand: an RDKit release tag suffix (2026_03_6)
  DISPATCH_DEBIAN      on-demand: Debian suite; defaults to versions.json
  FORCE                1/true: keep entries whose tag is already published
  SKIP_REGISTRY_CHECK  1: never consult the registry for published tags
  PG_FIXTURE_DIR       tests: read <dir>/postgres_<tag>.json instead of the
                       registry

The matrix is a JSON array on stdout; progress goes to stderr.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import matrix  # noqa: E402

# Dispatch inputs flow into image tags and into the workflow's $GITHUB_OUTPUT
# heredoc, so anything outside these shapes (including an embedded newline)
# is rejected where it enters the system.
RDKIT_RE = re.compile(r"[0-9]{4}_[0-9]{2}_[0-9]+")
SUITE_RE = re.compile(r"[a-z]+")
POSTGRES_RE = re.compile(r"[0-9]+(\.[0-9]+)?")

# The registry's ways of saying "no such tag". Any other failure (auth,
# network, a missing plugin) is a hard error: treating it as "not built" would
# silently rebuild the whole matrix on every run while CI stayed green.
NOT_FOUND_RE = re.compile(
    r"not found|no such manifest|manifest unknown|name unknown|name_unknown",
    re.IGNORECASE,
)


class ResolveError(Exception):
    pass


def log(message):
    print(message, file=sys.stderr)


def run(cmd):
    """Run a command and return (returncode, combined stdout+stderr)."""
    proc = subprocess.run(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )
    return proc.returncode, proc.stdout


def truthy(value):
    return str(value or "").strip().lower() in ("1", "true", "yes")


# ---------------------------------------------------------------------------
# PostgreSQL resolution
# ---------------------------------------------------------------------------

_inspect_cache: dict[str, dict] = {}


def _fixture_path(ref):
    # docker.io/postgres:17-bookworm -> postgres_17-bookworm.json
    name = ref.removeprefix("docker.io/").replace("/", "_").replace(":", "_")
    return Path(os.environ["PG_FIXTURE_DIR"]) / f"{name}.json"


def inspect_image(ref):
    """Registry metadata for one image reference, without pulling layers.

    Returns the whole `docker buildx imagetools inspect --format '{{json .}}'`
    object, whose keys are the lowercase json tags "image" and "manifest"
    (checked against a live response; `{{json .Image}}` would use the Go field
    name instead). Memoised per reference, so a matrix with several RDKit
    versions still costs one Docker Hub request per PostgreSQL tag.
    """
    if ref in _inspect_cache:
        return _inspect_cache[ref]
    if os.environ.get("PG_FIXTURE_DIR"):
        with open(_fixture_path(ref)) as fh:
            data = json.load(fh)
    else:
        rc, out = run(
            ["docker", "buildx", "imagetools", "inspect", ref, "--format", "{{json .}}"]
        )
        if rc != 0:
            raise ResolveError(f"could not inspect {ref}:\n{out.strip()}")
        data = json.loads(out)
    _inspect_cache[ref] = data
    return data


def point_version(inspected, ref):
    """The point release from the linux/amd64 config's PG_VERSION.

    PG_VERSION looks like "17.11-1.pgdg12+2"; the point version is the part
    before the first '-'. A multi-arch image's "image" is a per-platform map.
    """
    image = inspected.get("image") or {}
    config = image.get("linux/amd64", image)
    env = (config.get("config") or {}).get("Env")
    if env is None:
        raise ResolveError(f"no linux/amd64 image config in the metadata for {ref}")
    for entry in env:
        if entry.startswith("PG_VERSION="):
            return entry.split("=", 1)[1].split("-", 1)[0]
    raise ResolveError(f"PG_VERSION not found in the image config for {ref}")


def digest(inspected, ref):
    value = (inspected.get("manifest") or {}).get("digest")
    if not value:
        raise ResolveError(f"no digest in the manifest metadata for {ref}")
    return value


def resolve_pg(ref, suite):
    """Resolve a PostgreSQL major or point reference for one Debian suite.

    The matrix declares majors only: building against the moving major tag picks
    up patch and CVE updates with no config change. A point reference pins an
    immutable base image, but the major's current point is still resolved so
    the workflow can withhold the moving tags from an older build.
    """
    if not POSTGRES_RE.fullmatch(ref):
        raise ResolveError(f"'{ref}' is not a PostgreSQL major or point release")
    if not SUITE_RE.fullmatch(suite):
        raise ResolveError(
            f"'{suite}' is not a valid Debian suite name "
            "(expected lowercase letters, e.g. bookworm)"
        )
    major = ref.split(".")[0]
    major_ref = f"docker.io/postgres:{major}-{suite}"
    major_meta = inspect_image(major_ref)
    current = point_version(major_meta, major_ref)
    if ref == major:
        point = current
        base_tag = major_ref
        base_digest = digest(major_meta, major_ref)
    else:
        point = ref
        base_tag = f"docker.io/postgres:{ref}-{suite}"
        base_digest = digest(inspect_image(base_tag), base_tag)
    return {
        "postgres_major_version": major,
        "postgres_point_version": point,
        "postgres_current_point_version": current,
        "postgres_is_current": "true" if point == current else "false",
        "postgres_base_digest": base_digest,
        "postgres_base_image": f"{base_tag}@{base_digest}",
    }


# ---------------------------------------------------------------------------
# Matrix resolution
# ---------------------------------------------------------------------------


def requested_entries(config):
    """The unresolved {postgres_major, rdkit, debian} entries to consider."""
    postgres = os.environ.get("DISPATCH_POSTGRES", "")
    if not postgres:
        return matrix.expand(config)
    rdkit = os.environ.get("DISPATCH_RDKIT", "")
    suite = os.environ.get("DISPATCH_DEBIAN") or config["debian"]
    if not rdkit:
        raise ResolveError("DISPATCH_RDKIT is required when DISPATCH_POSTGRES is set")
    if not RDKIT_RE.fullmatch(rdkit):
        raise ResolveError(
            f"'{rdkit}' is not a valid RDKit release tag "
            "(expected YYYY_MM_N, e.g. 2026_03_6)"
        )
    if not SUITE_RE.fullmatch(suite):
        raise ResolveError(
            f"'{suite}' is not a valid Debian suite name "
            "(expected lowercase letters, e.g. bookworm)"
        )
    if not POSTGRES_RE.fullmatch(postgres):
        raise ResolveError(f"'{postgres}' is not a PostgreSQL major or point release")
    return [{"postgres_major": postgres, "rdkit": rdkit, "debian": suite}]


def point_tag(entry, default_debian):
    """The reproducible point tag; a non-default suite gets a suffix."""
    tag = f"postgres-{entry['postgres_point']}-rdkit-{entry['rdkit']}"
    if entry["debian"] != default_debian:
        tag += f"-{entry['debian']}"
    return tag


def is_published(ref):
    rc, out = run(["docker", "manifest", "inspect", ref])
    if rc == 0:
        return True
    if NOT_FOUND_RE.search(out):
        return False
    raise ResolveError(f"existence check failed for {ref}:\n{out.strip()}")


def resolve(config, force=False):
    """Fully resolved entries, minus those already published (unless forced)."""
    check = not force and not truthy(os.environ.get("SKIP_REGISTRY_CHECK"))
    image_repo = os.environ.get("IMAGE_REPO", "")
    if check and not image_repo:
        raise ResolveError("IMAGE_REPO is required unless SKIP_REGISTRY_CHECK=1 or --force")

    resolved = []
    for entry in requested_entries(config):
        pg = resolve_pg(entry["postgres_major"], entry["debian"])
        item = {
            "postgres_major": pg["postgres_major_version"],
            "postgres_point": pg["postgres_point_version"],
            "postgres_is_current": pg["postgres_is_current"],
            "postgres_base_image": pg["postgres_base_image"],
            "postgres_base_digest": pg["postgres_base_digest"],
            "rdkit": entry["rdkit"],
            "debian": entry["debian"],
        }
        if check:
            ref = f"{image_repo}:{point_tag(item, config['debian'])}"
            if is_published(ref):
                log(f"skip: {ref} already exists")
                continue
        resolved.append(item)
    return resolved


def cores(entries):
    """Distinct {rdkit, debian} pairs: one rdkit-core image serves every major."""
    seen = []
    for entry in entries:
        pair = {"rdkit": entry["rdkit"], "debian": entry["debian"]}
        if pair not in seen:
            seen.append(pair)
    return seen


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--file",
        default=os.environ.get("VERSIONS_FILE", "versions.json"),
        type=Path,
    )
    parser.add_argument(
        "--format", default="matrix", choices=("matrix", "cores", "latest", "debian")
    )
    parser.add_argument(
        "--force", action="store_true", help="keep entries whose tag is already published"
    )
    parser.add_argument(
        "--entries",
        type=argparse.FileType("r"),
        help="already-resolved entries (JSON array; '-' for stdin) to project "
        "with --format cores instead of resolving again",
    )
    sub = parser.add_subparsers(dest="command")
    pg = sub.add_parser("resolve-pg", help="print key=value lines for one PostgreSQL reference")
    pg.add_argument("ref")
    pg.add_argument("suite")
    args = parser.parse_args(argv)

    try:
        if args.command == "resolve-pg":
            for key, value in resolve_pg(args.ref, args.suite).items():
                print(f"{key}={value}")
            return 0

        config = matrix.load_config(args.file)
        if args.format == "debian":
            print(config["debian"])
        elif args.format == "latest":
            print(json.dumps(matrix.latest_pair(config)))
        elif args.format == "cores":
            if args.entries:
                entries = json.load(args.entries)
            else:
                entries = resolve(config, force=args.force or truthy(os.environ.get("FORCE")))
            print(json.dumps(cores(entries)))
        else:
            print(json.dumps(resolve(config, force=args.force or truthy(os.environ.get("FORCE")))))
        return 0
    except (ResolveError, ValueError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
