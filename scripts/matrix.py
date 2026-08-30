#!/usr/bin/env python3
"""Expand versions.json into the automatic build matrix.

The matrix declares what is REBUILT AUTOMATICALLY. It is not the set of
combinations the project can build -- any pair can be built on demand via
workflow_dispatch or `make runtime POSTGRES=... RDKIT=...` (SPEC R11). That is
what makes it reasonable for the matrix to be small.

Two independent axes plus an exclusion list; the build set is the cross product
minus the exclusions.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REQUIRED_KEYS = ("debian", "postgres_majors", "rdkit_versions", "exclude")


def load_config(path):
    """Read and validate versions.json."""
    with open(path) as fh:
        config = json.load(fh)
    missing = [k for k in REQUIRED_KEYS if k not in config]
    if missing:
        raise ValueError(f"{path}: missing required key(s): {', '.join(missing)}")
    if not isinstance(config["debian"], str):
        raise ValueError(f"{path}: 'debian' must be a string")
    return config


def _pg_sort_key(major):
    return int(major)


def _rdkit_sort_key(version):
    """2025_03_10 sorts above 2025_03_6, which lexicographic order gets wrong."""
    return tuple(int(part) for part in version.split("_"))


def _excluded_set(config):
    excluded = set()
    for item in config["exclude"]:
        if not str(item.get("reason", "")).strip():
            raise ValueError(
                f"exclude entry {item!r} is missing a non-empty 'reason' "
                "(required by SPEC R1)"
            )
        excluded.add((str(item["postgres_major"]), str(item["rdkit"])))
    return excluded


def expand(config):
    """Return the build matrix, sorted (rdkit desc, postgres_major desc)."""
    excluded = _excluded_set(config)
    debian = config["debian"]
    entries = []
    for rdkit in sorted(config["rdkit_versions"], key=_rdkit_sort_key, reverse=True):
        for major in sorted(config["postgres_majors"], key=_pg_sort_key, reverse=True):
            if (str(major), str(rdkit)) in excluded:
                continue
            entries.append(
                {"postgres_major": str(major), "rdkit": str(rdkit), "debian": debian}
            )
    return entries


def latest_pair(config):
    """The pair that receives the moving `latest` tag.

    expand() is already ordered (rdkit desc, postgres_major desc), so the first
    surviving entry is the highest RDKit paired with the highest PostgreSQL
    major available for it. RDKit takes priority because it is the
    client/server compatibility contract (SPEC section 3.2).
    """
    entries = expand(config)
    if not entries:
        raise ValueError("versions.json expands to an empty matrix")
    return entries[0]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", default="versions.json", type=Path)
    parser.add_argument("--format", default="json", choices=("json", "latest", "debian"))
    args = parser.parse_args(argv)

    config = load_config(args.file)
    if args.format == "json":
        print(json.dumps(expand(config)))
    elif args.format == "latest":
        print(json.dumps(latest_pair(config)))
    else:
        print(config["debian"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
