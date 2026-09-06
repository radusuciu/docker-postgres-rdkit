#!/usr/bin/env python3
"""Unit tests for scripts/matrix.py."""
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import matrix  # noqa: E402


BASE = {
    "debian": "bookworm",
    "postgres_majors": ["14", "15", "16", "17", "18"],
    "rdkit_versions": ["2025_09_2", "2025_03_6"],
    "exclude": [],
}


class TestExpand(unittest.TestCase):
    def test_cross_product_size(self):
        self.assertEqual(len(matrix.expand(BASE)), 10)

    def test_entry_shape(self):
        entry = matrix.expand(BASE)[0]
        self.assertEqual(set(entry), {"postgres_major", "rdkit", "debian"})
        self.assertEqual(entry["debian"], "bookworm")

    def test_exclusion_removes_exactly_one_pair(self):
        cfg = dict(BASE, exclude=[
            {"postgres_major": "18", "rdkit": "2025_03_6", "reason": "x"}
        ])
        entries = matrix.expand(cfg)
        self.assertEqual(len(entries), 9)
        self.assertNotIn(
            {"postgres_major": "18", "rdkit": "2025_03_6", "debian": "bookworm"},
            entries,
        )

    def test_exclusion_without_reason_is_rejected(self):
        cfg = dict(BASE, exclude=[{"postgres_major": "18", "rdkit": "2025_03_6"}])
        with self.assertRaises(ValueError):
            matrix.expand(cfg)

    def test_ordering_is_deterministic(self):
        self.assertEqual(matrix.expand(BASE), matrix.expand(BASE))

    def test_rdkit_ordering_is_numeric_not_lexicographic(self):
        cfg = dict(BASE, rdkit_versions=["2025_03_6", "2025_03_10"])
        self.assertEqual(matrix.latest_pair(cfg)["rdkit"], "2025_03_10")

    def test_postgres_ordering_is_numeric(self):
        cfg = dict(BASE, postgres_majors=["9", "18"])
        self.assertEqual(matrix.latest_pair(cfg)["postgres_major"], "18")


class TestLatest(unittest.TestCase):
    def test_latest_is_highest_of_both_axes(self):
        self.assertEqual(
            matrix.latest_pair(BASE),
            {"postgres_major": "18", "rdkit": "2025_09_2", "debian": "bookworm"},
        )

    def test_latest_skips_excluded_pair_by_yielding_postgres(self):
        cfg = dict(BASE, exclude=[
            {"postgres_major": "18", "rdkit": "2025_09_2", "reason": "x"}
        ])
        self.assertEqual(
            matrix.latest_pair(cfg),
            {"postgres_major": "17", "rdkit": "2025_09_2", "debian": "bookworm"},
        )

    def test_empty_matrix_raises(self):
        cfg = dict(BASE, postgres_majors=[], rdkit_versions=[])
        with self.assertRaises(ValueError):
            matrix.latest_pair(cfg)


class TestValidation(unittest.TestCase):
    def test_missing_key_is_rejected(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump({"debian": "bookworm"}, fh)
            path = fh.name
        with self.assertRaises(ValueError):
            matrix.load_config(path)


class TestCli(unittest.TestCase):
    def _run(self, cfg: dict[str, Any], fmt: str) -> str:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump(cfg, fh)
            path = fh.name
        out = subprocess.run(
            [sys.executable, str(REPO_ROOT / "scripts" / "matrix.py"),
             "--file", path, "--format", fmt],
            capture_output=True, text=True, check=True,
        )
        return out.stdout.strip()

    def test_json_format(self):
        self.assertEqual(len(json.loads(self._run(BASE, "json"))), 10)

    def test_latest_format(self):
        self.assertEqual(json.loads(self._run(BASE, "latest"))["postgres_major"], "18")

    def test_debian_format(self):
        self.assertEqual(self._run(BASE, "debian"), "bookworm")


class TestShippedFile(unittest.TestCase):
    def test_versions_json_is_valid_and_ships_empty_exclude(self):
        cfg = matrix.load_config(REPO_ROOT / "versions.json")
        self.assertEqual(cfg["debian"], "bookworm")
        self.assertEqual(cfg["exclude"], [])
        # Assert shape, not the literal pair: the matrix tracks the two most
        # recent RDKit release families at their latest patch, so this pair
        # changes on every version bump. Pin the format (YYYY_MM_N) and the
        # count instead of the exact values.
        self.assertGreaterEqual(len(cfg["rdkit_versions"]), 1)
        for version in cfg["rdkit_versions"]:
            self.assertRegex(version, r"^\d{4}_\d{2}_\d+$")
        self.assertEqual(
            len(matrix.expand(cfg)),
            len(cfg["postgres_majors"]) * len(cfg["rdkit_versions"]),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
