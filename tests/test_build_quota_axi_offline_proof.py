from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import signal
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools/bridge-cutover/build_quota_axi_offline_proof.py"
SPEC = importlib.util.spec_from_file_location("build_quota_axi_offline_proof", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
quota_proof = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = quota_proof
SPEC.loader.exec_module(quota_proof)

BUILDER_SCRIPT = ROOT / "tools/bridge-cutover/build_sealed_bridge_runtimes.py"
BUILDER_SPEC = importlib.util.spec_from_file_location(
    "build_sealed_bridge_runtimes_for_quota_proof", BUILDER_SCRIPT
)
assert BUILDER_SPEC is not None and BUILDER_SPEC.loader is not None
sealed_builder = importlib.util.module_from_spec(BUILDER_SPEC)
sys.modules[BUILDER_SPEC.name] = sealed_builder
BUILDER_SPEC.loader.exec_module(sealed_builder)


class QuotaOfflineProofTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="quota-offline-proof-test-")
        self.root = Path(os.path.realpath(self.temporary.name))

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_fake_node(self) -> Path:
        path = self.root / "node"
        path.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/python3
                import io
                import json
                import os
                import sys
                import tarfile
                from pathlib import Path

                args = sys.argv[1:]
                if args == ["--version"]:
                    print("v20.19.0")
                    raise SystemExit(0)
                program = Path(args[0]).name
                command = args[1] if len(args) > 1 else ""
                if program == "npm-cli.js" and command == "--version":
                    print("10.8.2")
                    raise SystemExit(0)
                if program == "npm-cli.js" and command == "ci":
                    raise SystemExit(0)
                if program == "compiler.js":
                    output = Path("dist/bin/quota-axi.js")
                    output.parent.mkdir(parents=True, exist_ok=True)
                    output.write_text("console.log('sealed quota');\\n", encoding="utf-8")
                    raise SystemExit(0)
                if program == "npm-cli.js" and command == "pack":
                    destination = Path(args[args.index("--pack-destination") + 1])
                    filename = "quota-axi-0.1.7.tgz"
                    with tarfile.open(destination / filename, mode="w") as archive:
                        for relative in ("package.json", "dist/bin/quota-axi.js"):
                            payload = Path(relative).read_bytes()
                            member = tarfile.TarInfo("package/" + relative)
                            member.size = len(payload)
                            member.mode = 0o644
                            member.mtime = 0
                            member.uid = member.gid = 0
                            member.uname = member.gname = ""
                            archive.addfile(member, io.BytesIO(payload))
                    print(json.dumps([{"filename": filename}], sort_keys=True))
                    raise SystemExit(0)
                raise SystemExit("unsupported fake Node invocation: " + repr(args))
                """
            ),
            encoding="utf-8",
        )
        path.chmod(0o700)
        return path

    def _git_source(self) -> tuple[Path, str, str]:
        source = self.root / "source"
        source.mkdir(mode=0o700)
        (source / "package.json").write_text(
            json.dumps(
                {
                    "name": "quota-axi",
                    "version": "0.1.7",
                    "bin": {"quota-axi": "dist/bin/quota-axi.js"},
                },
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        compiler = source / "compiler.js"
        compiler.write_text("// pinned compiler fixture\n", encoding="utf-8")
        subprocess.run(["/usr/bin/git", "init", "-q", str(source)], check=True)
        subprocess.run(
            [
                "/usr/bin/git",
                "-C",
                str(source),
                "-c",
                "user.name=Fixture",
                "-c",
                "user.email=fixture@example.invalid",
                "add",
                ".",
            ],
            check=True,
        )
        subprocess.run(
            [
                "/usr/bin/git",
                "-C",
                str(source),
                "-c",
                "user.name=Fixture",
                "-c",
                "user.email=fixture@example.invalid",
                "commit",
                "-qm",
                "fixture",
            ],
            check=True,
            env={
                "PATH": "/usr/bin:/bin",
                "HOME": str(self.root),
                "GIT_AUTHOR_DATE": "2020-01-01T00:00:00Z",
                "GIT_COMMITTER_DATE": "2020-01-01T00:00:00Z",
            },
        )
        commit = subprocess.run(
            ["/usr/bin/git", "-C", str(source), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        archive = self.root / "archive"
        archive.mkdir()
        members = quota_proof._archive_source(Path("/usr/bin/git"), source, commit, archive)
        return source, commit, quota_proof._archive_digest(members)

    def test_offline_builder_emits_deterministic_complete_proof(self) -> None:
        source, commit, source_tree = self._git_source()
        node = self._write_fake_node()
        npm = self.root / "npm"
        npm.mkdir()
        (npm / "npm-cli.js").write_text("// npm fixture\n", encoding="utf-8")
        cache = self.root / "npm-cache"
        cache.mkdir()
        (cache / "artifact").write_bytes(b"offline-cache")
        lock = self.root / "package-lock.json"
        lock.write_text(
            json.dumps(
                {
                    "lockfileVersion": 3,
                    "packages": {
                        "": {"dependencies": {"quota-axi": "0.1.7"}},
                        "node_modules/quota-axi": {
                            "version": "0.1.7",
                            "resolved": "https://registry.npmjs.org/quota-axi/-/quota-axi-0.1.7.tgz",
                            "integrity": "sha512-AAAAAAAAAAAAAAAAAAAAAA==",
                        },
                    },
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        package = self.root / "quota-axi.tgz"
        proof = self.root / "quota-build-proof.json"
        scratch = self.root / "scratch"
        scratch.mkdir()
        spec = {
            "schema_version": 1,
            "role": "candidate",
            "version": "0.1.7",
            "source_repo": str(source),
            "source_commit": commit,
            "source_tree_sha256": source_tree,
            "git": {
                "path": "/usr/bin/git",
                "sha256": quota_proof._sha(Path("/usr/bin/git")),
            },
            "node": {
                "path": str(node),
                "sha256": quota_proof._sha(node),
                "version": "20.19.0",
            },
            "npm": {
                "root": str(npm),
                "tree_sha256": quota_proof._tree(npm),
                "entry": "npm-cli.js",
                "version": "10.8.2",
            },
            "npm_cache": {
                "path": str(cache),
                "tree_sha256": quota_proof._tree(cache),
            },
            "build_lock": {
                "path": str(lock),
                "sha256": quota_proof._sha(lock),
            },
            "build_package_json": {
                "path": str(source / "package.json"),
                "sha256": quota_proof._sha(source / "package.json"),
            },
            "resolved_artifacts": [],
            "compiler": {
                "relative_path": "compiler.js",
                "sha256": quota_proof._sha(source / "compiler.js"),
                "args": [],
            },
            "package_tarball": str(package),
            "proof": str(proof),
            "scratch_parent": str(scratch),
        }
        spec_path = self.root / "spec.json"
        spec_path.write_bytes(quota_proof._canonical(spec))
        published_package, published_proof = quota_proof.build(spec_path)
        self.assertEqual((published_package, published_proof), (package, proof))
        value = json.loads(proof.read_text(encoding="utf-8"))
        self.assertEqual(value["builds"], 2)
        self.assertTrue(value["member_maps_match"])
        self.assertTrue(value["tar_digests_match"])
        self.assertEqual(value["package_tarball_sha256"], quota_proof._sha(package))
        self.assertEqual(
            [record["path"] for record in value["generated_members"]],
            ["dist/bin/quota-axi.js"],
        )
        role = sealed_builder.QuotaRole(
            role="candidate",
            release_path="quota/releases/candidate",
            version="0.1.7",
            source_repo=source,
            source_commit=commit,
            source_tree_sha256=source_tree,
            package_tarball=package,
            package_sha256=quota_proof._sha(package),
            package_lock=lock,
            package_lock_sha256=quota_proof._sha(lock),
            build_proof=proof,
            build_proof_sha256=quota_proof._sha(proof),
            dependencies=(),
        )
        source_members = {
            relative: ("file", (source / relative).read_bytes())
            for relative in ("compiler.js", "package.json")
        }
        sealed_builder._validate_quota_build_proof(
            role,
            source_members,
            quota_proof._package_members(package),
        )
        controls = sorted(path.name for path in scratch.iterdir())
        self.assertEqual(len(controls), 2)
        self.assertTrue(any(name.endswith(".journal.json") for name in controls))
        self.assertTrue(any(name.endswith(".lock") for name in controls))
        self.assertEqual(quota_proof.build(spec_path), (package, proof))

        build_id = hashlib.sha256(
            b"bridge-quota-offline-build-v1\0"
            + bytes.fromhex(quota_proof._sha(spec_path))
        ).hexdigest()
        held_lock = quota_proof._open_build_lock(
            quota_proof._lock_path(scratch, build_id)
        )
        try:
            concurrent = subprocess.run(
                [sys.executable, str(SCRIPT), "--spec", str(spec_path)],
                check=False,
                capture_output=True,
                text=True,
                timeout=30,
            )
        finally:
            quota_proof.fcntl.flock(held_lock, quota_proof.fcntl.LOCK_UN)
            os.close(held_lock)
        self.assertNotEqual(concurrent.returncode, 0)
        self.assertIn("already running", concurrent.stderr)

        for phase in quota_proof.JOURNAL_PHASES:
            with self.subTest(kill_after_phase=phase):
                crash_root = self.root / f"crash-{phase}"
                crash_root.mkdir()
                crash_scratch = crash_root / "scratch"
                crash_scratch.mkdir()
                crash_spec = dict(spec)
                crash_spec.update(
                    {
                        "package_tarball": str(crash_root / "quota-axi.tgz"),
                        "proof": str(crash_root / "quota-build-proof.json"),
                        "scratch_parent": str(crash_scratch),
                    }
                )
                crash_spec_path = crash_root / "spec.json"
                crash_spec_path.write_bytes(quota_proof._canonical(crash_spec))
                injector = textwrap.dedent(
                    f"""\
                    import importlib.util, os, signal
                    from pathlib import Path
                    source = Path({str(SCRIPT)!r})
                    spec = importlib.util.spec_from_file_location("quota_crash", source)
                    module = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(module)
                    original = module._replace_owned_json
                    fired = False
                    def replace(path, previous, value):
                        global fired
                        identity = original(path, previous, value)
                        if not fired and value.get("phase") == {phase!r}:
                            fired = True
                            os.kill(os.getpid(), signal.SIGKILL)
                        return identity
                    module._replace_owned_json = replace
                    module.build(Path({str(crash_spec_path)!r}))
                    """
                )
                killed = subprocess.run(
                    [sys.executable, "-c", injector],
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=120,
                )
                self.assertEqual(killed.returncode, -signal.SIGKILL)
                recovered = quota_proof.build(crash_spec_path)
                self.assertEqual(
                    recovered,
                    (
                        Path(crash_spec["package_tarball"]),
                        Path(crash_spec["proof"]),
                    ),
                )
                self.assertEqual(
                    Path(crash_spec["package_tarball"]).read_bytes(),
                    package.read_bytes(),
                )
                self.assertEqual(
                    Path(crash_spec["proof"]).read_bytes(), proof.read_bytes()
                )
                self.assertFalse(
                    any(
                        path.name.endswith("-a") or path.name.endswith("-b")
                        for path in crash_scratch.iterdir()
                    )
                )

        forged_package = self.root / "forged-quota-axi.tgz"
        forged_members = quota_proof._package_members(package)
        forged_members["dist/bin/quota-axi.js"] = b"console.log('forged');\n"
        with tarfile.open(forged_package, mode="w") as archive:
            for relative, payload in sorted(forged_members.items()):
                member = tarfile.TarInfo(f"package/{relative}")
                member.size = len(payload)
                member.mode = 0o644
                member.mtime = 0
                member.uid = member.gid = 0
                member.uname = member.gname = ""
                archive.addfile(member, io.BytesIO(payload))
        forged_value = json.loads(proof.read_text(encoding="utf-8"))
        forged_value["package_tarball_sha256"] = quota_proof._sha(forged_package)
        forged_value["package_members"] = [
            {
                "path": relative,
                "sha256": hashlib.sha256(payload).hexdigest(),
                "size": len(payload),
            }
            for relative, payload in sorted(forged_members.items())
        ]
        forged_value["generated_members"] = [
            record
            for record in forged_value["package_members"]
            if record["path"].startswith("dist/")
        ]
        forged_proof = self.root / "forged-quota-build-proof.json"
        forged_proof.write_bytes(quota_proof._canonical(forged_value))
        forged_role = sealed_builder.QuotaRole(
            role="candidate",
            release_path="quota/releases/candidate",
            version="0.1.7",
            source_repo=source,
            source_commit=commit,
            source_tree_sha256=source_tree,
            package_tarball=forged_package,
            package_sha256=quota_proof._sha(forged_package),
            package_lock=lock,
            package_lock_sha256=quota_proof._sha(lock),
            build_proof=forged_proof,
            build_proof_sha256=quota_proof._sha(forged_proof),
            dependencies=(),
        )
        with self.assertRaisesRegex(
            sealed_builder.BuildError, "independent Quota producer replay"
        ):
            sealed_builder._validate_quota_build_proof(
                forged_role,
                source_members,
                quota_proof._package_members(forged_package),
            )

        proof.write_bytes(proof.read_bytes() + b" ")
        with self.assertRaisesRegex(sealed_builder.BuildError, "manifest pin"):
            sealed_builder._validate_quota_build_proof(
                role,
                source_members,
                quota_proof._package_members(package),
            )

    def test_output_writer_recovers_only_exact_partial_staging(self) -> None:
        output = self.root / "proof.json"
        payload = b"deterministic-proof\n"
        digest = hashlib.sha256(payload).hexdigest()
        staging = output.with_name(f".{output.name}.bridge-write-{digest[:32]}")
        staging.write_bytes(payload[:7])
        staging.chmod(0o600)
        quota_proof._publish_bytes_no_replace(output, payload)
        self.assertEqual(output.read_bytes(), payload)
        self.assertFalse(staging.exists())

        foreign_output = self.root / "foreign.json"
        foreign_staging = foreign_output.with_name(
            f".{foreign_output.name}.bridge-write-{digest[:32]}"
        )
        foreign_staging.write_bytes(b"foreign")
        foreign_staging.chmod(0o600)
        with self.assertRaisesRegex(quota_proof.ProofError, "not attributable"):
            quota_proof._publish_bytes_no_replace(foreign_output, payload)
        self.assertEqual(foreign_staging.read_bytes(), b"foreign")


if __name__ == "__main__":
    unittest.main()
