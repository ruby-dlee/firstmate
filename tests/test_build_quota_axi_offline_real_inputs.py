from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import tarfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _load(name: str, relative: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


quota_proof = _load(
    "build_quota_axi_offline_proof_real",
    "tools/bridge-cutover/build_quota_axi_offline_proof.py",
)
sealed_builder = _load(
    "build_sealed_bridge_runtimes_real_quota",
    "tools/bridge-cutover/build_sealed_bridge_runtimes.py",
)

REQUIRED_ENVIRONMENT = (
    "BRIDGE_REAL_NODE20",
    "BRIDGE_REAL_NPM_ROOT",
    "BRIDGE_REAL_QUOTA_CANDIDATE_REPO",
    "BRIDGE_REAL_QUOTA_CANDIDATE_ARTIFACT",
    "BRIDGE_REAL_QUOTA_ROLLBACK_REPO",
    "BRIDGE_REAL_QUOTA_ROLLBACK_ARTIFACT",
    "BRIDGE_REAL_QUOTA_NODE_MODULES",
    "BRIDGE_REAL_PYTHON3119",
)

REQUIRED_AGENT_ENVIRONMENT = (
    "BRIDGE_REAL_AGENT_CANDIDATE_REPO",
    "BRIDGE_REAL_AGENT_CANDIDATE_COMMIT",
    "BRIDGE_REAL_AGENT_CANDIDATE_WHEEL",
    "BRIDGE_REAL_AGENT_ROLLBACK_REPO",
    "BRIDGE_REAL_AGENT_ROLLBACK_COMMIT",
    "BRIDGE_REAL_AGENT_ROLLBACK_WHEEL",
)


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _git_archive(repo: Path, commit: str) -> dict[str, tuple[str, bytes]]:
    completed = subprocess.run(
        ["/usr/bin/git", "--no-replace-objects", "-C", str(repo), "archive", commit],
        check=True,
        capture_output=True,
        env={
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "HOME": "/var/empty",
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin",
        },
    )
    members: dict[str, tuple[str, bytes]] = {}
    with tarfile.open(fileobj=io.BytesIO(completed.stdout), mode="r:") as archive:
        for member in archive.getmembers():
            if member.isdir():
                continue
            if member.isfile():
                extracted = archive.extractfile(member)
                assert extracted is not None
                members[member.name] = ("file", extracted.read())
            elif member.issym():
                members[member.name] = ("symlink", member.linkname.encode("utf-8"))
            else:
                raise AssertionError(f"unsupported Git archive member: {member.name}")
    return members


@unittest.skipUnless(
    all(os.environ.get(name) for name in REQUIRED_ENVIRONMENT),
    "exact retained macOS rehearsal inputs were not supplied",
)
class RealQuotaOfflineProofTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="bridge-real-quota-proof-")
        self.root = Path(self.temporary.name).resolve()
        self.node = Path(os.environ["BRIDGE_REAL_NODE20"]).resolve()
        retained_npm_root = Path(os.environ["BRIDGE_REAL_NPM_ROOT"]).resolve()
        self.npm_root = self.root / "npm"
        shutil.copytree(retained_npm_root, self.npm_root, symlinks=True)
        self.npm_entry = self.npm_root / "bin/npm-cli.js"
        self.modules = Path(os.environ["BRIDGE_REAL_QUOTA_NODE_MODULES"]).resolve()
        self.python = Path(os.environ["BRIDGE_REAL_PYTHON3119"]).resolve()
        self.repos = {
            "candidate": Path(os.environ["BRIDGE_REAL_QUOTA_CANDIDATE_REPO"]).resolve(),
            "rollback": Path(os.environ["BRIDGE_REAL_QUOTA_ROLLBACK_REPO"]).resolve(),
        }
        self.rehearsal_artifacts = {
            "candidate": Path(os.environ["BRIDGE_REAL_QUOTA_CANDIDATE_ARTIFACT"]).resolve(),
            "rollback": Path(os.environ["BRIDGE_REAL_QUOTA_ROLLBACK_ARTIFACT"]).resolve(),
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _run(self, *arguments: str, cwd: Path | None = None) -> str:
        completed = subprocess.run(
            [str(self.node), str(self.npm_entry), *arguments],
            cwd=cwd,
            env={
                "HOME": str(self.root / "home"),
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin",
                "TMPDIR": str(self.root / "tmp"),
                "npm_config_audit": "false",
                "npm_config_fund": "false",
                "npm_config_offline": "true",
                "npm_config_update_notifier": "false",
            },
            check=False,
            capture_output=True,
            text=True,
            timeout=600,
        )
        if completed.returncode:
            self.fail(completed.stderr or completed.stdout)
        return completed.stdout.strip()

    def _pack(self, source: Path, destination: Path) -> Path:
        result = json.loads(
            self._run(
                "pack",
                "--ignore-scripts",
                "--json",
                "--pack-destination",
                str(destination),
                str(source),
            )
        )
        return destination / result[0]["filename"]

    def _source(self, role: str, destination: Path):
        repo = self.repos[role]
        commit = subprocess.run(
            ["/usr/bin/git", "-C", str(repo), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
            env={
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_NOSYSTEM": "1",
                "HOME": "/var/empty",
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin",
            },
        ).stdout.strip()
        members = quota_proof._archive_source(Path("/usr/bin/git"), repo, commit, destination)
        return repo, commit, members

    def test_actual_candidate_and_rollback_producer_consumer(self) -> None:
        (self.root / "home").mkdir()
        (self.root / "tmp").mkdir()
        artifacts = self.root / "artifacts"
        artifacts.mkdir()
        package_roots = {
            "@toon-format/toon": (self.modules / "@toon-format/toon").resolve(),
            "@types/node": (self.modules / "@types/node").resolve(),
            "axi-sdk-js": (self.modules / "axi-sdk-js").resolve(),
            "typescript": (self.modules / "typescript").resolve(),
            "undici-types": (
                self.modules / ".pnpm/undici-types@6.11.1/node_modules/undici-types"
            ).resolve(),
        }
        packed = {name: self._pack(path, artifacts) for name, path in package_roots.items()}
        self.assertEqual(
            subprocess.run(
                [str(self.python), "--version"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip(),
            "Python 3.11.9",
        )
        self.assertEqual(
            subprocess.run(
                [str(self.node), "--version"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip(),
            "v20.19.0",
        )
        npm_version = self._run("--version")
        for role, version in (("candidate", "0.1.7"), ("rollback", "0.1.5")):
            with self.subTest(role=role):
                role_root = self.root / role
                role_root.mkdir()
                source_root = role_root / "archive"
                source_root.mkdir()
                repo, commit, source_members = self._source(role, source_root)
                source_package = json.loads(source_members["package.json"][1])
                dependencies = {
                    "@toon-format/toon": f"file:{packed['@toon-format/toon']}",
                    "undici-types": f"file:{packed['undici-types']}",
                }
                if role == "candidate":
                    dependencies["axi-sdk-js"] = f"file:{packed['axi-sdk-js']}"
                build_package = {
                    "name": "quota-axi",
                    "version": version,
                    "type": "module",
                    "dependencies": dependencies,
                    "devDependencies": {
                        "@types/node": f"file:{packed['@types/node']}",
                        "typescript": f"file:{packed['typescript']}",
                    },
                }
                build_package_path = role_root / "package.json"
                build_package_path.write_text(
                    json.dumps(build_package, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
                cache = role_root / "npm-cache"
                cache.mkdir()
                self._run(
                    "install",
                    "--package-lock-only",
                    "--ignore-scripts",
                    "--offline",
                    "--cache",
                    str(cache),
                    cwd=role_root,
                )
                lock = role_root / "package-lock.json"
                scratch = role_root / "scratch"
                scratch.mkdir()
                output = role_root / f"quota-axi-{version}.tgz"
                proof = role_root / "quota-build-proof.json"
                resolved = sorted({path.resolve() for path in packed.values()}, key=str)
                if role == "rollback":
                    resolved.remove(packed["axi-sdk-js"].resolve())
                spec = {
                    "schema_version": 1,
                    "role": role,
                    "version": version,
                    "source_repo": str(repo),
                    "source_commit": commit,
                    "source_tree_sha256": quota_proof._archive_digest(source_members),
                    "git": {
                        "path": "/usr/bin/git",
                        "sha256": _sha(Path("/usr/bin/git")),
                    },
                    "node": {
                        "path": str(self.node),
                        "sha256": _sha(self.node),
                        "version": "20.19.0",
                    },
                    "npm": {
                        "root": str(self.npm_root),
                        "tree_sha256": quota_proof._tree(self.npm_root),
                        "entry": "bin/npm-cli.js",
                        "version": npm_version,
                    },
                    "npm_cache": {
                        "path": str(cache),
                        "tree_sha256": quota_proof._tree(cache),
                    },
                    "build_lock": {
                        "path": str(lock),
                        "sha256": _sha(lock),
                    },
                    "build_package_json": {
                        "path": str(build_package_path),
                        "sha256": _sha(build_package_path),
                    },
                    "resolved_artifacts": [
                        {"path": str(path), "sha256": _sha(path)} for path in resolved
                    ],
                    "compiler": {
                        "relative_path": "node_modules/typescript/bin/tsc",
                        "sha256": _sha(package_roots["typescript"] / "bin/tsc"),
                        "args": [],
                    },
                    "package_tarball": str(output),
                    "proof": str(proof),
                    "scratch_parent": str(scratch),
                }
                spec_path = role_root / "spec.json"
                spec_path.write_bytes(quota_proof._canonical(spec))
                quota_proof.build(spec_path)
                package_members = quota_proof._package_members(output)
                self.assertEqual(
                    package_members,
                    quota_proof._package_members(self.rehearsal_artifacts[role]),
                )
                self.assertEqual(
                    json.loads(package_members["package.json"])["version"],
                    version,
                )
                quota_role = sealed_builder.QuotaRole(
                    role=role,
                    release_path=f"quota/releases/{role}",
                    version=version,
                    source_repo=repo,
                    source_commit=commit,
                    source_tree_sha256=spec["source_tree_sha256"],
                    package_tarball=output,
                    package_sha256=_sha(output),
                    package_lock=lock,
                    package_lock_sha256=_sha(lock),
                    build_proof=proof,
                    build_proof_sha256=_sha(proof),
                    dependencies=(),
                )
                sealed_builder._validate_quota_build_proof(
                    quota_role, source_members, package_members
                )
                self.assertEqual(source_package["version"], version)


@unittest.skipUnless(
    all(os.environ.get(name) for name in REQUIRED_AGENT_ENVIRONMENT),
    "exact retained Agent Fleet source commits and wheels were not supplied",
)
class RealAgentFleetWheelTests(unittest.TestCase):
    def test_actual_candidate_and_rollback_wheel_consumer(self) -> None:
        roles = {
            "candidate": {
                "repo": Path(os.environ["BRIDGE_REAL_AGENT_CANDIDATE_REPO"]).resolve(),
                "commit": os.environ["BRIDGE_REAL_AGENT_CANDIDATE_COMMIT"],
                "wheel": Path(os.environ["BRIDGE_REAL_AGENT_CANDIDATE_WHEEL"]).resolve(),
                "version": "0.2.0",
                "contract": 2,
                "source_subdirectory": "tools/agent-fleet",
            },
            "rollback": {
                "repo": Path(os.environ["BRIDGE_REAL_AGENT_ROLLBACK_REPO"]).resolve(),
                "commit": os.environ["BRIDGE_REAL_AGENT_ROLLBACK_COMMIT"],
                "wheel": Path(os.environ["BRIDGE_REAL_AGENT_ROLLBACK_WHEEL"]).resolve(),
                "version": "0.1.5",
                "contract": 1,
                "source_subdirectory": ".",
            },
        }
        for role, value in roles.items():
            with self.subTest(role=role):
                observed = subprocess.run(
                    ["/usr/bin/git", "-C", str(value["repo"]), "rev-parse", "HEAD"],
                    check=True,
                    capture_output=True,
                    text=True,
                    env={
                        "GIT_CONFIG_GLOBAL": "/dev/null",
                        "GIT_CONFIG_NOSYSTEM": "1",
                        "HOME": "/var/empty",
                        "LANG": "C",
                        "LC_ALL": "C",
                        "PATH": "/usr/bin:/bin",
                    },
                ).stdout.strip()
                self.assertEqual(observed, value["commit"])
                source = _git_archive(value["repo"], value["commit"])
                agent_role = sealed_builder.AgentRole(
                    role=role,
                    release_path=f"agent/releases/{role}",
                    version=value["version"],
                    contract_version=value["contract"],
                    source_repo=value["repo"],
                    source_commit=value["commit"],
                    source_tree_sha256=sealed_builder._archive_tree_sha256(source),
                    source_subdirectory=value["source_subdirectory"],
                    wheel=value["wheel"],
                    wheel_sha256=_sha(value["wheel"]),
                )
                members = sealed_builder._wheel_members(agent_role, source)
                self.assertIn("agent_fleet/__init__.py", members)


if __name__ == "__main__":
    unittest.main()
