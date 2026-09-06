#!/usr/bin/env python3
"""Tests for scripts/resolve_matrix.py.

PostgreSQL metadata comes from the fixtures under tests/fixtures/registry; the
registry existence check is exercised through a stub `docker` placed ahead of
PATH. Nothing here touches the network unless SKIP_LIVE is unset and buildx is
available, in which case one case checks the live metadata shape.
"""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "scripts" / "resolve_matrix.py"
FIXTURES = REPO_ROOT / "tests" / "fixtures" / "registry"
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import resolve_matrix  # noqa: E402

BOOKWORM_DIGEST = json.loads((FIXTURES / "postgres_17-bookworm.json").read_text())["manifest"]["digest"]
BULLSEYE_DIGEST = json.loads((FIXTURES / "postgres_17-bullseye.json").read_text())["manifest"]["digest"]

ONE_MAJOR = {
    "debian": "bookworm",
    "postgres_majors": ["17"],
    "rdkit_versions": ["2026_03_6", "2025_09_6"],
    "exclude": [],
}

# Environment for every subprocess: fixtures only, no registry check unless a
# test overrides it, and none of the caller's DISPATCH_* variables leaking in.
BASE_ENV = {
    k: v for k, v in os.environ.items()
    if not k.startswith("DISPATCH_") and k not in ("FORCE", "SKIP_REGISTRY_CHECK", "IMAGE_REPO")
}
BASE_ENV.update({
    "PG_FIXTURE_DIR": str(FIXTURES),
    "SKIP_REGISTRY_CHECK": "1",
    "IMAGE_REPO": "ghcr.io/example/postgres-rdkit",
})


def write_json(data: Any) -> str:
    fh = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump(data, fh)
    fh.close()
    return fh.name


def run(
    args: list[str],
    env_overrides: dict[str, str] | None = None,
    unset: tuple[str, ...] = (),
    stdin: str | None = None,
) -> subprocess.CompletedProcess[str]:
    env = dict(BASE_ENV)
    for key in unset:
        env.pop(key, None)
    env.update(env_overrides or {})
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        env=env, input=stdin, capture_output=True, text=True,
    )


def stub_docker(script_body: str) -> str:
    """A temp dir holding a `docker` stub; prepend it to PATH."""
    directory = tempfile.mkdtemp()
    stub = Path(directory) / "docker"
    stub.write_text("#!/usr/bin/env bash\n" + script_body)
    stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
    return directory


class ResolveMatrixTest(unittest.TestCase):
    def setUp(self) -> None:
        self.versions = write_json(ONE_MAJOR)
        self.addCleanup(os.unlink, self.versions)
        resolve_matrix._inspect_cache.clear()

    def resolve(self, *args: str, **kwargs: Any) -> Any:
        proc = run(["--file", self.versions, *args], **kwargs)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return json.loads(proc.stdout)


class TestMatrixMode(ResolveMatrixTest):
    def test_one_entry_per_pair_with_resolved_fields(self):
        out = self.resolve()
        self.assertEqual(len(out), 2)
        first = out[0]
        self.assertEqual(first["postgres_major"], "17")
        self.assertEqual(first["postgres_point"], "17.11")
        self.assertEqual(first["postgres_is_current"], "true")
        self.assertEqual(first["postgres_base_digest"], BOOKWORM_DIGEST)
        self.assertEqual(first["postgres_base_image"], f"docker.io/postgres:17-bookworm@{BOOKWORM_DIGEST}")
        self.assertEqual(first["rdkit"], "2026_03_6", "highest rdkit first")
        self.assertEqual(first["debian"], "bookworm")

    def test_entry_fields_are_exactly_what_the_workflow_reads(self):
        expected = {
            "postgres_major", "postgres_point", "postgres_is_current",
            "postgres_base_image", "postgres_base_digest", "rdkit", "debian",
        }
        for entry in self.resolve():
            self.assertEqual(set(entry), expected)

    def test_output_is_a_json_list(self):
        self.assertIsInstance(self.resolve(), list)

    def test_default_format_is_matrix(self):
        self.assertEqual(self.resolve(), self.resolve("--format", "matrix"))


class TestCores(ResolveMatrixTest):
    def test_cores_dedupe_across_postgres_majors(self):
        entries = [
            {"postgres_major": m, "rdkit": r, "debian": "bookworm"}
            for r in ("2026_03_6", "2025_09_6") for m in ("17", "16")
        ]
        self.assertEqual(len(entries), 4)
        self.assertEqual(
            resolve_matrix.cores(entries),
            [{"rdkit": "2026_03_6", "debian": "bookworm"}, {"rdkit": "2025_09_6", "debian": "bookworm"}],
        )

    def test_cores_from_stdin_project_the_resolved_matrix(self):
        matrix_json = json.dumps(self.resolve())
        out = self.resolve("--format", "cores", "--entries", "-", stdin=matrix_json)
        self.assertEqual(out, [{"rdkit": "2026_03_6", "debian": "bookworm"}, {"rdkit": "2025_09_6", "debian": "bookworm"}])

    def test_cores_from_an_empty_matrix_is_empty(self):
        out = self.resolve("--format", "cores", "--entries", "-", stdin="[]")
        self.assertEqual(out, [])

    def test_cores_without_entries_resolve_themselves(self):
        out = self.resolve("--format", "cores")
        self.assertEqual({tuple(sorted(e)) for e in out}, {("debian", "rdkit")})
        self.assertEqual(len(out), 2)


class TestOtherFormats(ResolveMatrixTest):
    def test_latest(self):
        self.assertEqual(
            self.resolve("--format", "latest"),
            {"postgres_major": "17", "rdkit": "2026_03_6", "debian": "bookworm"},
        )

    def test_debian(self):
        proc = run(["--file", self.versions, "--format", "debian"])
        self.assertEqual(proc.stdout.strip(), "bookworm")


class TestDispatchMode(ResolveMatrixTest):
    def test_exactly_the_requested_pair(self):
        out = self.resolve(env_overrides={"DISPATCH_POSTGRES": "17.9", "DISPATCH_RDKIT": "2023_09_6"})
        self.assertEqual(len(out), 1)
        entry = out[0]
        self.assertEqual(entry["postgres_major"], "17")
        self.assertEqual(entry["postgres_point"], "17.9")
        self.assertEqual(entry["postgres_is_current"], "false", "older point is not current")
        self.assertEqual(entry["rdkit"], "2023_09_6")
        self.assertEqual(entry["debian"], "bookworm", "suite defaults to versions.json")
        self.assertIn("postgres:17.9-bookworm@sha256:", entry["postgres_base_image"])

    def test_debian_override_reaches_the_registry_lookup(self):
        out = self.resolve(env_overrides={
            "DISPATCH_POSTGRES": "17", "DISPATCH_RDKIT": "2023_09_6", "DISPATCH_DEBIAN": "bullseye",
        })
        self.assertEqual(out[0]["debian"], "bullseye")
        # The bullseye fixture has a different digest, so this proves the suite
        # reached the lookup rather than merely being echoed back.
        self.assertEqual(out[0]["postgres_base_digest"], BULLSEYE_DIGEST)

    def test_rdkit_is_required(self):
        proc = run(["--file", self.versions], env_overrides={"DISPATCH_POSTGRES": "17"})
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("DISPATCH_RDKIT is required", proc.stderr)

    def assert_rejected(self, message: str, **env: str) -> None:
        proc = run(["--file", self.versions], env_overrides=env)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn(message, proc.stderr)

    def test_rdkit_with_embedded_newline_is_rejected(self):
        self.assert_rejected("is not a valid RDKit release tag",
                             DISPATCH_POSTGRES="17", DISPATCH_RDKIT="2023_09_6\nEXTRA=malicious")

    def test_rdkit_with_trailing_newline_is_rejected(self):
        self.assert_rejected("is not a valid RDKit release tag",
                             DISPATCH_POSTGRES="17", DISPATCH_RDKIT="2023_09_6\n")

    def test_rdkit_with_wrong_shape_is_rejected(self):
        self.assert_rejected("is not a valid RDKit release tag",
                             DISPATCH_POSTGRES="17", DISPATCH_RDKIT="not-a-version")

    def test_debian_with_embedded_newline_is_rejected(self):
        self.assert_rejected("is not a valid Debian suite name",
                             DISPATCH_POSTGRES="17", DISPATCH_RDKIT="2023_09_6",
                             DISPATCH_DEBIAN="bookworm\nEXTRA=malicious")

    def test_debian_with_disallowed_characters_is_rejected(self):
        self.assert_rejected("is not a valid Debian suite name",
                             DISPATCH_POSTGRES="17", DISPATCH_RDKIT="2023_09_6", DISPATCH_DEBIAN="Bookworm2")

    def test_postgres_must_be_major_or_point(self):
        for bad in ("seventeen", "17.", ".17", "17.9.1", "17\n"):
            with self.subTest(bad=bad):
                self.assert_rejected("is not a PostgreSQL major or point release",
                                     DISPATCH_POSTGRES=bad, DISPATCH_RDKIT="2023_09_6")


class TestRegistryCheck(ResolveMatrixTest):
    """The existence check runs through a stub `docker` ahead of PATH."""

    def with_stub(
        self, body: str, *args: str, env_overrides: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        directory = stub_docker(body)
        self.addCleanup(shutil.rmtree, directory)
        env = {"PATH": f"{directory}:{os.environ['PATH']}"}
        env.update(env_overrides or {})
        return run(["--file", self.versions, *args], env_overrides=env, unset=("SKIP_REGISTRY_CHECK",))

    def test_published_tags_are_skipped(self):
        proc = self.with_stub('[ "$1" = manifest ] && [ "$2" = inspect ] && exit 0\nexit 1\n')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout), [])
        self.assertIn("skip: ghcr.io/example/postgres-rdkit:postgres-17.11-rdkit-2026_03_6 already exists", proc.stderr)

    def test_unpublished_tags_are_kept(self):
        proc = self.with_stub('echo "ERROR: $3: manifest unknown" >&2\nexit 1\n')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(json.loads(proc.stdout)), 2)

    def test_not_found_is_also_benign(self):
        proc = self.with_stub('echo "no such manifest: $3" >&2\nexit 1\n')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(json.loads(proc.stdout)), 2)

    def test_any_other_failure_is_a_hard_error(self):
        proc = self.with_stub('echo "denied: requested access to the resource is denied" >&2\nexit 1\n')
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("existence check failed for ghcr.io/example/postgres-rdkit:postgres-17.11-rdkit-2026_03_6", proc.stderr)
        self.assertIn("denied", proc.stderr)

    def test_checked_ref_is_the_point_tag(self):
        log = tempfile.NamedTemporaryFile(delete=False)
        log.close()
        self.addCleanup(os.unlink, log.name)
        proc = self.with_stub(f'echo "$3" >> {log.name}\necho "manifest unknown" >&2\nexit 1\n')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            Path(log.name).read_text().split(),
            ["ghcr.io/example/postgres-rdkit:postgres-17.11-rdkit-2026_03_6",
             "ghcr.io/example/postgres-rdkit:postgres-17.11-rdkit-2025_09_6"],
        )

    def test_non_default_suite_gets_a_suffixed_tag(self):
        log = tempfile.NamedTemporaryFile(delete=False)
        log.close()
        self.addCleanup(os.unlink, log.name)
        proc = self.with_stub(
            f'echo "$3" >> {log.name}\necho "manifest unknown" >&2\nexit 1\n',
            env_overrides={"DISPATCH_POSTGRES": "17", "DISPATCH_RDKIT": "2023_09_6", "DISPATCH_DEBIAN": "bullseye"},
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            Path(log.name).read_text().split(),
            ["ghcr.io/example/postgres-rdkit:postgres-17.11-rdkit-2023_09_6-bullseye"],
        )

    def test_force_skips_the_lookup_and_keeps_everything(self):
        log = tempfile.NamedTemporaryFile(delete=False)
        log.close()
        self.addCleanup(os.unlink, log.name)
        for how in ({"FORCE": "true"}, {"FORCE": "1"}):
            with self.subTest(how=how):
                proc = self.with_stub(f'echo "$3" >> {log.name}\nexit 0\n', env_overrides=how)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(len(json.loads(proc.stdout)), 2)
        proc = self.with_stub(f'echo "$3" >> {log.name}\nexit 0\n', "--force")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(json.loads(proc.stdout)), 2)
        self.assertEqual(Path(log.name).read_text(), "", "docker was never called")

    def test_image_repo_is_required_for_the_check(self):
        proc = self.with_stub("exit 0\n", env_overrides={"IMAGE_REPO": ""})
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("IMAGE_REPO is required", proc.stderr)


class TestResolvePg(unittest.TestCase):
    def setUp(self) -> None:
        resolve_matrix._inspect_cache.clear()
        self.env_patch = mock.patch.dict(os.environ, {"PG_FIXTURE_DIR": str(FIXTURES)})
        self.env_patch.start()
        self.addCleanup(self.env_patch.stop)

    def test_major_resolves_to_the_current_point(self):
        out = resolve_matrix.resolve_pg("17", "bookworm")
        self.assertEqual(out, {
            "postgres_major_version": "17",
            "postgres_point_version": "17.11",
            "postgres_current_point_version": "17.11",
            "postgres_is_current": "true",
            "postgres_base_digest": BOOKWORM_DIGEST,
            "postgres_base_image": f"docker.io/postgres:17-bookworm@{BOOKWORM_DIGEST}",
        })

    def test_older_point_is_not_current_and_pins_its_own_digest(self):
        out = resolve_matrix.resolve_pg("17.9", "bookworm")
        self.assertEqual(out["postgres_major_version"], "17")
        self.assertEqual(out["postgres_point_version"], "17.9")
        self.assertEqual(out["postgres_current_point_version"], "17.11")
        self.assertEqual(out["postgres_is_current"], "false")
        self.assertTrue(out["postgres_base_image"].startswith("docker.io/postgres:17.9-bookworm@sha256:"))
        self.assertNotEqual(out["postgres_base_digest"], BOOKWORM_DIGEST)

    def test_one_lookup_per_distinct_reference(self):
        with mock.patch.object(resolve_matrix, "inspect_image", wraps=resolve_matrix.inspect_image) as spy:
            resolve_matrix.resolve_pg("17", "bookworm")
            resolve_matrix.resolve_pg("17", "bookworm")
            resolve_matrix.resolve_pg("17.9", "bookworm")
        # Memoisation is inside inspect_image, so count the fixture reads
        # instead: the same reference is fetched once however often it is asked.
        refs = [call.args[0] for call in spy.call_args_list]
        self.assertEqual(refs.count("docker.io/postgres:17-bookworm"), 3)
        with mock.patch.object(resolve_matrix, "run") as fake_run:
            os.environ.pop("PG_FIXTURE_DIR")
            resolve_matrix._inspect_cache.clear()
            fake_run.return_value = (0, json.dumps(json.loads((FIXTURES / "postgres_17-bookworm.json").read_text())))
            resolve_matrix.resolve_pg("17", "bookworm")
            resolve_matrix.resolve_pg("17", "bookworm")
            self.assertEqual(fake_run.call_count, 1)

    def test_missing_pg_version_is_an_error(self):
        with self.assertRaises(resolve_matrix.ResolveError):
            resolve_matrix.point_version({"image": {"linux/amd64": {"config": {"Env": []}}}}, "x")

    def test_missing_digest_is_an_error(self):
        with self.assertRaises(resolve_matrix.ResolveError):
            resolve_matrix.digest({"manifest": {}}, "x")

    def test_bad_input_is_rejected(self):
        for ref, suite in (("", "bookworm"), ("seventeen", "bookworm"), ("17", ""), ("17", "Bookworm")):
            with self.subTest(ref=ref, suite=suite):
                with self.assertRaises(resolve_matrix.ResolveError):
                    resolve_matrix.resolve_pg(ref, suite)

    def test_cli_emits_sourceable_key_value_lines(self):
        proc = run(["resolve-pg", "17", "bookworm"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = proc.stdout.strip().splitlines()
        self.assertEqual(len(lines), 6)
        for line in lines:
            self.assertRegex(line, r"^[a-z_]+=\S+$")
        shell = subprocess.run(
            ["bash", "-c", f'eval "$(cat)"; echo "$postgres_major_version $postgres_is_current"'],
            input=proc.stdout, capture_output=True, text=True,
        )
        self.assertEqual(shell.stdout.strip(), "17 true")

    def test_cli_rejects_bad_input(self):
        for args in (["resolve-pg", "seventeen", "bookworm"], ["resolve-pg", "17", "Bookworm"]):
            proc = run(args)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("ERROR", proc.stderr)

    @unittest.skipIf(
        os.environ.get("SKIP_LIVE") or shutil.which("docker") is None
        or subprocess.run(["docker", "buildx", "version"], capture_output=True).returncode != 0,
        "SKIP_LIVE set or docker buildx unavailable",
    )
    def test_live_metadata_shape_has_not_drifted(self):
        proc = run(["resolve-pg", "17", "bookworm"], unset=("PG_FIXTURE_DIR",))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("postgres_point_version=17.", proc.stdout)
        self.assertIn("postgres_base_digest=sha256:", proc.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
