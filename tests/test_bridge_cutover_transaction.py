from __future__ import annotations

import hashlib
import fcntl
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT_DIR = Path(__file__).resolve().parents[1] / "tools" / "bridge-cutover"
sys.path.insert(0, str(SCRIPT_DIR))

import bridge_cutover_transaction as cutover  # noqa: E402


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    digest.update(path.read_bytes())
    return digest.hexdigest()


def atomic_link(path: Path, target: Path) -> None:
    temp = path.with_name(f".{path.name}.test-replace")
    os.symlink(str(target), temp)
    os.replace(temp, path)


class Fixture:
    def __init__(
        self, *, apply_opt_in: bool = True, relative_targets: bool = False
    ) -> None:
        real_temp_root = Path(os.path.realpath(tempfile.gettempdir()))
        self._temporary = tempfile.TemporaryDirectory(
            prefix="bridge-cutover-driver-test-", dir=real_temp_root
        )
        self.base = Path(self._temporary.name)
        self.root = self.base / "exact-transaction-root"
        self.root.mkdir(mode=0o700)
        self.releases = self.root / "releases"
        self.releases.mkdir()
        self.state = self.root / "state"
        self.state.mkdir()
        self.private = self.root / "private"
        self.private.mkdir(mode=0o700)
        self.quiet = self.root / "quiet"
        self.quiet.mkdir(mode=0o700)
        self.backend = self.quiet / "backend"
        self.backend.write_text("tmux\n", encoding="utf-8")
        self.backend.chmod(0o600)
        self.routing = self.quiet / "account-routing-mode"
        self.quiet_state_paths = tuple(
            self.quiet / name for name in ("leases", "sessions", "locks")
        )
        for path in self.quiet_state_paths:
            path.mkdir(mode=0o700)
        self.ps_binary = self.quiet / "fake-ps"
        self.ps_binary.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.ps_binary.chmod(0o755)

        self.release_paths: list[Path] = []
        self.link_paths: list[Path] = []
        self.proof_paths: dict[tuple[str, str], Path] = {}
        self.raw_targets: dict[tuple[str, str], str] = {}
        link_operations: list[dict[str, object]] = []
        for ordinal, name in enumerate(("quota", "agent-fleet"), start=1):
            if relative_targets:
                product_root = self.root / name
                product_root.mkdir()
                product_releases = product_root / "releases"
                product_releases.mkdir()
                old_release = product_releases / "0.1.5-old"
                new_release = product_releases / "0.2.0-new"
                current = product_root / "current"
                old_target = "releases/0.1.5-old"
                new_target = "releases/0.2.0-new"
            else:
                old_release = self.releases / f"{name}-old"
                new_release = self.releases / f"{name}-new"
                current = self.state / f"{name}-current"
                old_target = str(old_release)
                new_target = str(new_release)
            old_release.mkdir()
            new_release.mkdir()
            old_proof = old_release / "sentinel"
            new_proof = new_release / "sentinel"
            old_proof.write_text(f"old-{ordinal}\n", encoding="utf-8")
            new_proof.write_text(f"new-{ordinal}\n", encoding="utf-8")
            old_proof.chmod(0o644)
            new_proof.chmod(0o644)
            old_runtime = old_release / "runtime.py"
            new_runtime = new_release / "runtime.py"
            old_runtime.write_text(f"RUNTIME = 'old-{ordinal}'\n", encoding="utf-8")
            new_runtime.write_text(f"RUNTIME = 'new-{ordinal}'\n", encoding="utf-8")
            old_runtime.chmod(0o644)
            new_runtime.chmod(0o644)
            os.symlink(old_target, current)
            self.release_paths.extend((old_release, new_release))
            self.link_paths.append(current)
            self.proof_paths[(name, "old")] = old_proof
            self.proof_paths[(name, "new")] = new_proof
            self.raw_targets[(name, "old")] = old_target
            self.raw_targets[(name, "new")] = new_target
            link_operations.append(
                {
                    "kind": "symlink",
                    "name": f"{name}-current",
                    "path": str(current),
                    "old_target": old_target,
                    "new_target": new_target,
                    "old_proofs": [
                        {
                            "relative_path": "sentinel",
                            "sha256": sha256(old_proof),
                            "mode": "0644",
                        }
                    ],
                    "new_proofs": [
                        {
                            "relative_path": "sentinel",
                            "sha256": sha256(new_proof),
                            "mode": "0644",
                        }
                    ],
                    "old_tree_sha256": cutover.compute_release_tree_sha256(old_release),
                    "new_tree_sha256": cutover.compute_release_tree_sha256(new_release),
                }
            )

        self.old_source = self.state / "registry.old.source"
        self.new_source = self.state / "registry.new.source"
        self.registry = self.state / "accounts.toml"
        self.old_source.write_text(
            'version = 1\nmode = "old"\n\n'
            '[profiles.reserve]\nenabled = false\nsafety_policy = "desktop_shared"\n\n'
            '[profiles.worker]\nenabled = false\nsafety_policy = "worker"\n',
            encoding="utf-8",
        )
        self.new_source.write_text(
            'version = 1\nmode = "new"\n\n'
            '[profiles.reserve]\nenabled = false\nsafety_policy = "desktop_shared"\n\n'
            '[profiles.worker]\nenabled = false\nsafety_policy = "worker"\n',
            encoding="utf-8",
        )
        self.registry.write_bytes(self.old_source.read_bytes())
        for path in (self.old_source, self.new_source, self.registry):
            path.chmod(0o600)

        self.old_front_door = self.state / "agent-fleet-front-door.old"
        self.new_front_door = self.state / "agent-fleet-front-door.new"
        self.front_door = self.state / "agent-fleet"
        self.old_front_door.write_bytes(b"old native front door\n")
        self.new_front_door.write_bytes(b"new native front door\n")
        self.front_door.write_bytes(self.old_front_door.read_bytes())
        for path in (self.old_front_door, self.new_front_door, self.front_door):
            path.chmod(0o555)

        self.journal = self.private / "cutover-journal.json"
        self.lock = self.private / "cutover.lock"
        self.lock.write_bytes(b"")
        self.lock.chmod(0o600)
        self.manifest_path = self.base / "manifest.json"
        self.manifest_data: dict[str, object] = {
            "schema_version": 1,
            "transaction_id": "test-cutover-001",
            "apply_opt_in": apply_opt_in,
            "allowed_roots": [str(self.root)],
            "lock_path": str(self.lock),
            "journal_path": str(self.journal),
            "quiet_point": {
                "profile_ids": ["reserve", "worker"],
                "worker_profile_ids": ["worker"],
                "never_enroll_profile_ids": ["reserve"],
                "routing_absent_paths": [str(self.routing)],
                "backend_path": str(self.backend),
                "backend_sha256": sha256(self.backend),
                "state_quiet_paths": [str(path) for path in self.quiet_state_paths],
                "forbidden_process_tokens": [str(self.root / "fleet-process-token")],
                "ps_binary": str(self.ps_binary),
                "ps_binary_sha256": sha256(self.ps_binary),
            },
            "operations": [
                *link_operations,
                {
                    "kind": "regular-file",
                    "name": "agent-fleet-front-door",
                    "path": str(self.front_door),
                    "old_source": str(self.old_front_door),
                    "new_source": str(self.new_front_door),
                    "old_sha256": sha256(self.old_front_door),
                    "new_sha256": sha256(self.new_front_door),
                    "mode": "0555",
                },
                {
                    "kind": "registry",
                    "name": "accounts-registry",
                    "path": str(self.registry),
                    "old_source": str(self.old_source),
                    "new_source": str(self.new_source),
                    "old_sha256": sha256(self.old_source),
                    "new_sha256": sha256(self.new_source),
                    "mode": "0600",
                },
            ],
        }
        self.write_manifest()

    def write_manifest(self) -> None:
        self.manifest_path.write_text(
            json.dumps(self.manifest_data, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    def load(self) -> cutover.Manifest:
        return cutover.load_manifest(str(self.manifest_path))

    def close(self) -> None:
        self._temporary.cleanup()

    def assert_old(self, testcase: unittest.TestCase) -> None:
        manifest = self.load()
        states, prefix = cutover.observe(manifest)
        testcase.assertEqual(states, ["old", "old", "old", "old"])
        testcase.assertEqual(prefix, 0)
        testcase.assertEqual(self.registry.read_bytes(), self.old_source.read_bytes())
        testcase.assertEqual(self.front_door.read_bytes(), self.old_front_door.read_bytes())

    def assert_new(self, testcase: unittest.TestCase) -> None:
        manifest = self.load()
        states, prefix = cutover.observe(manifest)
        testcase.assertEqual(states, ["new", "new", "new", "new"])
        testcase.assertEqual(prefix, 4)
        testcase.assertEqual(self.registry.read_bytes(), self.new_source.read_bytes())
        testcase.assertEqual(self.front_door.read_bytes(), self.new_front_door.read_bytes())

    def assert_no_payload_deletion(self, testcase: unittest.TestCase) -> None:
        for release in self.release_paths:
            testcase.assertTrue(release.is_dir())
            testcase.assertTrue((release / "sentinel").is_file())
        testcase.assertTrue(self.old_source.is_file())
        testcase.assertTrue(self.new_source.is_file())
        testcase.assertTrue(self.old_front_door.is_file())
        testcase.assertTrue(self.new_front_door.is_file())


class BridgeCutoverTransactionTests(unittest.TestCase):
    @unittest.skipUnless(
        Path("/bin/ps").is_file() and os.lstat("/bin/ps").st_uid == 0,
        "requires a root-owned system ps binary",
    )
    def test_manifest_accepts_hash_pinned_root_owned_ps_binary(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        ps_binary = Path("/bin/ps")
        quiet_point = fixture.manifest_data["quiet_point"]
        quiet_point["ps_binary"] = str(ps_binary)
        quiet_point["ps_binary_sha256"] = sha256(ps_binary)
        fixture.write_manifest()
        self.assertEqual(fixture.load().quiet_point.ps_binary, ps_binary)

    def test_manifest_refuses_mutable_state_owned_by_a_different_uid(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        with mock.patch.object(cutover.os, "getuid", return_value=os.getuid() + 1):
            with self.assertRaisesRegex(cutover.CutoverError, "owner uid"):
                fixture.load()

    def test_observe_refuses_hardlinked_live_front_door(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        fixture.front_door.unlink()
        os.link(fixture.old_front_door, fixture.front_door)
        with self.assertRaisesRegex(cutover.CutoverError, "exactly one hard link"):
            cutover.observe(fixture.load())

    def test_manifest_home_safety_ignores_hostile_ambient_home(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        with mock.patch.dict(os.environ, {"HOME": str(fixture.root)}):
            loaded = fixture.load()
        self.assertEqual(loaded.allowed_roots, (fixture.root,))

    def test_default_plan_is_read_only(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        before_names = sorted(str(path.relative_to(fixture.root)) for path in fixture.root.rglob("*"))

        result = cutover.plan(fixture.load())

        after_names = sorted(str(path.relative_to(fixture.root)) for path in fixture.root.rglob("*"))
        self.assertEqual(before_names, after_names)
        self.assertFalse(fixture.journal.exists())
        self.assertEqual(result["forward_pending"], [
            "quota-current",
            "agent-fleet-current",
            "agent-fleet-front-door",
            "accounts-registry",
        ])
        fixture.assert_old(self)

    def test_plan_seals_observed_operation_and_journal_parents(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        recorder = cutover.BoundaryController()

        cutover.plan(fixture.load(), recorder)

        self.assertIn(
            "before_fsync:recovery-operation-dir:quota-current", recorder.seen
        )
        self.assertIn(
            "after_fsync:recovery-operation-dir:quota-current", recorder.seen
        )
        self.assertIn("before_fsync:recovery-journal-dir", recorder.seen)
        self.assertIn("after_fsync:recovery-journal-dir", recorder.seen)
        self.assertFalse(fixture.journal.exists())

    def test_concurrent_driver_is_refused_by_private_lock(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        lock_fd = os.open(fixture.lock, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(cutover.CutoverError, "another cutover driver"):
                cutover.plan(fixture.load())
            with self.assertRaisesRegex(cutover.CutoverError, "another cutover driver"):
                cutover.execute(fixture.load(), "forward")
        finally:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            os.close(lock_fd)
        fixture.assert_old(self)

    def test_forward_is_idempotent_and_journal_is_private(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        manifest = fixture.load()

        first = cutover.execute(manifest, "forward")
        first_targets = [os.readlink(path) for path in fixture.link_paths]
        first_registry = fixture.registry.read_bytes()
        second = cutover.execute(fixture.load(), "forward")

        self.assertTrue(first["converged"])
        self.assertTrue(second["converged"])
        self.assertEqual([os.readlink(path) for path in fixture.link_paths], first_targets)
        self.assertEqual(fixture.registry.read_bytes(), first_registry)
        self.assertEqual(stat.S_IMODE(os.lstat(fixture.journal).st_mode), 0o600)
        fixture.assert_new(self)
        fixture.assert_no_payload_deletion(self)

    def test_apply_requires_both_cli_equivalent_and_manifest_opt_in(self) -> None:
        fixture = Fixture(apply_opt_in=False)
        self.addCleanup(fixture.close)
        manifest = fixture.load()

        plan = cutover.plan(manifest)
        self.assertFalse(plan["apply_opt_in"])
        with self.assertRaisesRegex(cutover.CutoverError, "apply_opt_in is false"):
            cutover.execute(manifest, "forward")
        fixture.assert_old(self)
        self.assertFalse(fixture.journal.exists())

    def test_crash_at_every_forward_boundary_restarts_to_new(self) -> None:
        discovery = Fixture()
        self.addCleanup(discovery.close)
        recorder = cutover.BoundaryController()
        cutover.execute(discovery.load(), "forward", recorder)
        boundaries = list(dict.fromkeys(recorder.seen))
        self.assertGreater(len(boundaries), 50)
        for family in (
            "before_journal:",
            "after_journal:",
            "before_replace:",
            "after_replace:",
            "before_fsync:",
            "after_fsync:",
        ):
            self.assertTrue(any(label.startswith(family) for label in boundaries), family)

        for boundary in boundaries:
            with self.subTest(boundary=boundary):
                fixture = Fixture()
                try:
                    with self.assertRaises(cutover.InjectedFailure):
                        cutover.execute(
                            fixture.load(),
                            "forward",
                            cutover.BoundaryController(boundary),
                        )
                    cutover.execute(fixture.load(), "forward")
                    fixture.assert_new(self)
                    fixture.assert_no_payload_deletion(self)
                finally:
                    fixture.close()

    def test_crash_at_every_rollback_boundary_restarts_to_old(self) -> None:
        discovery = Fixture()
        self.addCleanup(discovery.close)
        cutover.execute(discovery.load(), "forward")
        recorder = cutover.BoundaryController()
        cutover.execute(discovery.load(), "rollback", recorder)
        boundaries = list(dict.fromkeys(recorder.seen))
        self.assertGreater(len(boundaries), 50)

        for boundary in boundaries:
            with self.subTest(boundary=boundary):
                fixture = Fixture()
                try:
                    cutover.execute(fixture.load(), "forward")
                    with self.assertRaises(cutover.InjectedFailure):
                        cutover.execute(
                            fixture.load(),
                            "rollback",
                            cutover.BoundaryController(boundary),
                        )
                    cutover.execute(fixture.load(), "rollback")
                    fixture.assert_old(self)
                    fixture.assert_no_payload_deletion(self)
                finally:
                    fixture.close()

    def test_actual_relative_shape_preserves_raw_target_forward_and_rollback(self) -> None:
        fixture = Fixture(relative_targets=True)
        self.addCleanup(fixture.close)

        cutover.execute(fixture.load(), "forward")
        self.assertEqual(
            [os.readlink(path) for path in fixture.link_paths],
            [
                fixture.raw_targets[("quota", "new")],
                fixture.raw_targets[("agent-fleet", "new")],
            ],
        )
        cutover.execute(fixture.load(), "rollback")
        self.assertEqual(
            [os.readlink(path) for path in fixture.link_paths],
            [
                fixture.raw_targets[("quota", "old")],
                fixture.raw_targets[("agent-fleet", "old")],
            ],
        )

    def test_actual_relative_shape_interrupts_at_every_forward_boundary(self) -> None:
        discovery = Fixture(relative_targets=True)
        self.addCleanup(discovery.close)
        recorder = cutover.BoundaryController()
        cutover.execute(discovery.load(), "forward", recorder)
        boundaries = list(dict.fromkeys(recorder.seen))
        self.assertGreater(len(boundaries), 80)

        for boundary in boundaries:
            with self.subTest(boundary=boundary):
                fixture = Fixture(relative_targets=True)
                try:
                    with self.assertRaises(cutover.InjectedFailure):
                        cutover.execute(
                            fixture.load(),
                            "forward",
                            cutover.BoundaryController(boundary),
                        )
                    cutover.execute(fixture.load(), "forward")
                    fixture.assert_new(self)
                    self.assertEqual(
                        [os.readlink(path) for path in fixture.link_paths],
                        [
                            fixture.raw_targets[("quota", "new")],
                            fixture.raw_targets[("agent-fleet", "new")],
                        ],
                    )
                finally:
                    fixture.close()

    def test_actual_relative_shape_interrupts_at_every_rollback_boundary(self) -> None:
        discovery = Fixture(relative_targets=True)
        self.addCleanup(discovery.close)
        cutover.execute(discovery.load(), "forward")
        recorder = cutover.BoundaryController()
        cutover.execute(discovery.load(), "rollback", recorder)
        boundaries = list(dict.fromkeys(recorder.seen))
        self.assertGreater(len(boundaries), 80)

        for boundary in boundaries:
            with self.subTest(boundary=boundary):
                fixture = Fixture(relative_targets=True)
                try:
                    cutover.execute(fixture.load(), "forward")
                    with self.assertRaises(cutover.InjectedFailure):
                        cutover.execute(
                            fixture.load(),
                            "rollback",
                            cutover.BoundaryController(boundary),
                        )
                    cutover.execute(fixture.load(), "rollback")
                    fixture.assert_old(self)
                    self.assertEqual(
                        [os.readlink(path) for path in fixture.link_paths],
                        [
                            fixture.raw_targets[("quota", "old")],
                            fixture.raw_targets[("agent-fleet", "old")],
                        ],
                    )
                finally:
                    fixture.close()

    def test_rollback_before_irreversible_boundary_and_idempotence(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)

        cutover.execute(fixture.load(), "forward")
        cutover.execute(fixture.load(), "rollback")
        cutover.execute(fixture.load(), "rollback")

        fixture.assert_old(self)
        fixture.assert_no_payload_deletion(self)

    def test_post_install_irreversible_boundary_is_idempotent_and_blocks_rollback(
        self,
    ) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        cutover.execute(fixture.load(), "forward")

        with mock.patch.object(
            cutover.subprocess,
            "run",
            wraps=cutover.subprocess.run,
        ) as run:
            first = cutover.mark_post_install_irreversible_boundary(fixture.load())
            recorder = cutover.BoundaryController()
            second = cutover.mark_post_install_irreversible_boundary(
                fixture.load(), recorder
            )
        self.assertTrue(run.call_args_list)
        self.assertTrue(
            all(call.args[0][0] == str(fixture.ps_binary) for call in run.call_args_list)
        )

        self.assertTrue(first["post_install_irreversible_boundary"])
        self.assertTrue(second["post_install_irreversible_boundary"])
        self.assertIn("after_fsync:recovery-journal-dir", recorder.seen)
        self.assertFalse(any(label.startswith("before_journal:") for label in recorder.seen))
        with self.assertRaisesRegex(cutover.CutoverError, "rollback is forbidden"):
            cutover.execute(fixture.load(), "rollback")
        fixture.assert_new(self)

    def test_quiet_point_structurally_excludes_reserve_from_worker_policy(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        payload = fixture.old_source.read_text(encoding="utf-8").replace(
            'safety_policy = "desktop_shared"',
            'safety_policy = "worker"',
            1,
        )
        fixture.old_source.write_text(payload, encoding="utf-8")
        fixture.old_source.chmod(0o600)
        fixture.registry.write_bytes(fixture.old_source.read_bytes())
        fixture.registry.chmod(0o600)
        operation = fixture.manifest_data["operations"][-1]
        operation["old_sha256"] = sha256(fixture.old_source)
        fixture.write_manifest()

        with self.assertRaisesRegex(cutover.CutoverError, "safety_policy"):
            cutover.plan(fixture.load())

    def test_restart_seals_operation_parent_after_replace_before_fsync_gap(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        with self.assertRaises(cutover.InjectedFailure):
            cutover.execute(
                fixture.load(),
                "forward",
                cutover.BoundaryController("after_replace:forward:quota-current"),
            )

        recorder = cutover.BoundaryController()
        cutover.execute(fixture.load(), "forward", recorder)

        seal = "after_fsync:recovery-operation-dir:quota-current"
        self.assertIn(seal, recorder.seen)
        self.assertLess(recorder.seen.index(seal), recorder.seen.index("before_journal:forward.start"))
        fixture.assert_new(self)

    def test_restart_seals_registry_parent_after_replace_before_fsync_gap(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        with self.assertRaises(cutover.InjectedFailure):
            cutover.execute(
                fixture.load(),
                "forward",
                cutover.BoundaryController("after_replace:forward:accounts-registry"),
            )

        recorder = cutover.BoundaryController()
        cutover.execute(fixture.load(), "forward", recorder)

        seal = "after_fsync:recovery-operation-dir:quota-current"
        self.assertIn(seal, recorder.seen)
        self.assertLess(recorder.seen.index(seal), recorder.seen.index("before_journal:forward.start"))
        fixture.assert_new(self)

    def test_restart_seals_journal_parent_after_replace_before_fsync_gap(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        with self.assertRaises(cutover.InjectedFailure):
            cutover.execute(
                fixture.load(),
                "forward",
                cutover.BoundaryController("after_replace:journal:forward.start"),
            )

        recorder = cutover.BoundaryController()
        cutover.execute(fixture.load(), "forward", recorder)

        seal = "after_fsync:recovery-journal-dir"
        self.assertIn(seal, recorder.seen)
        self.assertLess(recorder.seen.index(seal), recorder.seen.index("before_journal:forward.start"))
        fixture.assert_new(self)

    def test_cannot_mark_irreversible_boundary_before_forward_completion(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        with self.assertRaisesRegex(cutover.CutoverError, "fully forward"):
            cutover.mark_post_install_irreversible_boundary(fixture.load())
        fixture.assert_old(self)

    def test_unknown_link_target_is_refused_without_mutation(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        unknown = fixture.releases / "unknown"
        unknown.mkdir()
        atomic_link(fixture.link_paths[0], unknown)

        with self.assertRaisesRegex(cutover.CutoverError, "unknown target"):
            cutover.execute(fixture.load(), "forward")
        self.assertFalse(fixture.journal.exists())
        self.assertEqual(os.readlink(fixture.link_paths[0]), str(unknown))

    def test_relative_target_dotdot_and_nonnormal_forms_are_refused(self) -> None:
        for unsafe in ("../releases/old", "releases/../old", "./releases/old"):
            with self.subTest(target=unsafe):
                fixture = Fixture(relative_targets=True)
                try:
                    fixture.manifest_data["operations"][0]["old_target"] = unsafe
                    fixture.write_manifest()
                    with self.assertRaisesRegex(
                        cutover.CutoverError, "normalized relative path|may not contain"
                    ):
                        fixture.load()
                finally:
                    fixture.close()

    def test_release_proof_relative_escape_is_refused(self) -> None:
        fixture = Fixture(relative_targets=True)
        self.addCleanup(fixture.close)
        fixture.manifest_data["operations"][0]["old_proofs"][0][
            "relative_path"
        ] = "../sentinel"
        fixture.write_manifest()

        with self.assertRaisesRegex(cutover.CutoverError, "may not contain"):
            fixture.load()

    def test_release_proof_symlink_is_refused(self) -> None:
        fixture = Fixture(relative_targets=True)
        self.addCleanup(fixture.close)
        proof = fixture.proof_paths[("quota", "new")]
        real = proof.with_name("sentinel.real")
        os.replace(proof, real)
        os.symlink("sentinel.real", proof)

        with self.assertRaisesRegex(cutover.CutoverError, "cannot safely open"):
            fixture.load()

    def test_release_proof_group_writable_mode_is_refused(self) -> None:
        fixture = Fixture(relative_targets=True)
        self.addCleanup(fixture.close)
        fixture.manifest_data["operations"][0]["new_proofs"][0]["mode"] = "0664"
        fixture.write_manifest()

        with self.assertRaisesRegex(cutover.CutoverError, "group- or other-writable"):
            fixture.load()

    def test_release_proof_mode_drift_is_refused(self) -> None:
        fixture = Fixture(relative_targets=True)
        self.addCleanup(fixture.close)
        manifest = fixture.load()
        fixture.proof_paths[("quota", "new")].chmod(0o600)

        with self.assertRaisesRegex(cutover.CutoverError, "mode is 0600"):
            cutover.plan(manifest)

    def test_release_tree_detects_added_runtime_file(self) -> None:
        fixture = Fixture(relative_targets=True)
        self.addCleanup(fixture.close)
        manifest = fixture.load()
        operation = manifest.operations[0]
        self.assertIsInstance(operation, cutover.SymlinkOperation)
        injected = operation.new_target_path / "sitecustomize.py"
        injected.write_text("raise RuntimeError('injected')\n", encoding="utf-8")
        injected.chmod(0o644)

        with self.assertRaisesRegex(cutover.CutoverError, "tree SHA-256"):
            cutover.plan(manifest)

    def test_release_tree_detects_changed_nonproof_runtime_file(self) -> None:
        fixture = Fixture(relative_targets=True)
        self.addCleanup(fixture.close)
        manifest = fixture.load()
        operation = manifest.operations[0]
        self.assertIsInstance(operation, cutover.SymlinkOperation)
        runtime = operation.new_target_path / "runtime.py"
        runtime.write_text("RUNTIME = 'tampered'\n", encoding="utf-8")
        runtime.chmod(0o644)

        with self.assertRaisesRegex(cutover.CutoverError, "tree SHA-256"):
            cutover.plan(manifest)

    def test_release_tree_refuses_escaping_symlink(self) -> None:
        fixture = Fixture(relative_targets=True)
        self.addCleanup(fixture.close)
        manifest = fixture.load()
        operation = manifest.operations[0]
        self.assertIsInstance(operation, cutover.SymlinkOperation)
        os.symlink("/etc/passwd", operation.new_target_path / "escape")

        with self.assertRaisesRegex(cutover.CutoverError, "symlink escapes"):
            cutover.plan(manifest)

    def test_forward_refuses_external_hardlink_to_candidate_release_file(self) -> None:
        fixture = Fixture(relative_targets=True)
        self.addCleanup(fixture.close)
        manifest = fixture.load()
        proof = fixture.proof_paths[("quota", "new")]
        alias = fixture.state / "candidate-proof-hardlink"
        os.link(proof, alias)

        with self.assertRaisesRegex(cutover.CutoverError, "exactly one hard link"):
            cutover.execute(manifest, "forward")
        self.assertEqual(
            [os.readlink(path) for path in fixture.link_paths],
            [
                fixture.raw_targets[("quota", "old")],
                fixture.raw_targets[("agent-fleet", "old")],
            ],
        )
        self.assertEqual(fixture.registry.read_bytes(), fixture.old_source.read_bytes())

    def test_forward_and_recovery_refuse_hardlinked_staged_registry(self) -> None:
        fixture = Fixture(relative_targets=True)
        self.addCleanup(fixture.close)
        manifest = fixture.load()
        operation = manifest.operations[-1]
        self.assertIsInstance(operation, cutover.RegistryOperation)
        temp = cutover._temp_path(operation.path, manifest.transaction_id, "forward")
        alias = fixture.state / "staged-registry-hardlink"

        class HardlinkStagedRegistry(cutover.BoundaryController):
            def hit(self, label: str) -> None:
                super().hit(label)
                if label == "before_replace:forward:accounts-registry":
                    os.link(temp, alias)

        with self.assertRaisesRegex(cutover.CutoverError, "exactly one hard link"):
            cutover.execute(manifest, "forward", HardlinkStagedRegistry())
        self.assertEqual(
            [os.readlink(path) for path in fixture.link_paths],
            [
                fixture.raw_targets[("quota", "new")],
                fixture.raw_targets[("agent-fleet", "new")],
            ],
        )
        self.assertEqual(fixture.registry.read_bytes(), fixture.old_source.read_bytes())

        with self.assertRaisesRegex(cutover.CutoverError, "exactly one hard link"):
            cutover.execute(manifest, "forward")

    def test_partial_rollback_recovery_refuses_old_release_hardlink(self) -> None:
        fixture = Fixture(relative_targets=True)
        self.addCleanup(fixture.close)
        manifest = fixture.load()
        cutover.execute(manifest, "forward")
        with self.assertRaises(cutover.InjectedFailure):
            cutover.execute(
                manifest,
                "rollback",
                cutover.BoundaryController(
                    "after_replace:rollback:accounts-registry"
                ),
            )
        proof = fixture.proof_paths[("quota", "old")]
        os.link(proof, fixture.state / "rollback-proof-hardlink")

        with self.assertRaisesRegex(cutover.CutoverError, "exactly one hard link"):
            cutover.execute(manifest, "rollback")
        self.assertEqual(
            [os.readlink(path) for path in fixture.link_paths],
            [
                fixture.raw_targets[("quota", "new")],
                fixture.raw_targets[("agent-fleet", "new")],
            ],
        )
        self.assertEqual(fixture.registry.read_bytes(), fixture.old_source.read_bytes())

    def test_partial_forward_recovery_refuses_corrupted_new_release_proof(self) -> None:
        fixture = Fixture(relative_targets=True)
        self.addCleanup(fixture.close)
        manifest = fixture.load()
        with self.assertRaises(cutover.InjectedFailure):
            cutover.execute(
                manifest,
                "forward",
                cutover.BoundaryController("after_replace:forward:quota-current"),
            )
        proof = fixture.proof_paths[("quota", "new")]
        proof.write_text("corrupted-after-partial-forward\n", encoding="utf-8")
        proof.chmod(0o644)

        with self.assertRaisesRegex(cutover.CutoverError, r"proof\[0\] SHA-256"):
            cutover.execute(manifest, "forward")
        self.assertEqual(os.readlink(fixture.link_paths[0]), fixture.raw_targets[("quota", "new")])
        self.assertEqual(
            os.readlink(fixture.link_paths[1]), fixture.raw_targets[("agent-fleet", "old")]
        )
        self.assertEqual(fixture.registry.read_bytes(), fixture.old_source.read_bytes())

    def test_release_proof_corruption_during_prepare_blocks_replace(self) -> None:
        fixture = Fixture(relative_targets=True)
        self.addCleanup(fixture.close)
        manifest = fixture.load()

        class CorruptProofAtPrepare(cutover.BoundaryController):
            def hit(self, label: str) -> None:
                super().hit(label)
                if label == "after_prepare:forward:quota-current":
                    proof = fixture.proof_paths[("quota", "new")]
                    proof.write_text("changed-during-prepare\n", encoding="utf-8")
                    proof.chmod(0o644)

        with self.assertRaisesRegex(cutover.CutoverError, r"proof\[0\] SHA-256"):
            cutover.execute(manifest, "forward", CorruptProofAtPrepare())
        self.assertEqual(
            os.readlink(fixture.link_paths[0]), fixture.raw_targets[("quota", "old")]
        )
        self.assertEqual(fixture.registry.read_bytes(), fixture.old_source.read_bytes())

    def test_out_of_order_exact_states_are_refused(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        second_new = Path(fixture.manifest_data["operations"][1]["new_target"])
        atomic_link(fixture.link_paths[1], second_new)

        with self.assertRaisesRegex(cutover.CutoverError, "not a valid transaction prefix"):
            cutover.plan(fixture.load())
        self.assertFalse(fixture.journal.exists())

    def test_unknown_registry_hash_is_refused(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        fixture.registry.write_text("unexpected = true\n", encoding="utf-8")
        fixture.registry.chmod(0o600)

        with self.assertRaisesRegex(cutover.CutoverError, "unknown SHA-256"):
            cutover.execute(fixture.load(), "forward")
        self.assertFalse(fixture.journal.exists())

    def test_wrong_registry_mode_is_refused(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        fixture.registry.chmod(0o644)

        with self.assertRaisesRegex(cutover.CutoverError, "mode is 0644"):
            cutover.plan(fixture.load())
        self.assertFalse(fixture.journal.exists())

    def test_wrong_source_hash_is_refused(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        fixture.new_source.write_text("tampered = true\n", encoding="utf-8")
        fixture.new_source.chmod(0o600)

        with self.assertRaisesRegex(cutover.CutoverError, "new source SHA-256"):
            cutover.execute(fixture.load(), "forward")
        self.assertEqual(
            [os.readlink(path) for path in fixture.link_paths],
            [
                str(fixture.releases / "quota-old"),
                str(fixture.releases / "agent-fleet-old"),
            ],
        )
        self.assertEqual(fixture.registry.read_bytes(), fixture.old_source.read_bytes())
        self.assertFalse(fixture.journal.exists())

    def test_symlink_source_or_allowed_root_is_refused(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        real_source = fixture.new_source.with_name("registry.new.real")
        os.replace(fixture.new_source, real_source)
        os.symlink(str(real_source), fixture.new_source)
        with self.assertRaisesRegex(cutover.CutoverError, "cannot safely open|regular non-symlink"):
            cutover.plan(fixture.load())

        other = Fixture()
        self.addCleanup(other.close)
        root_alias = other.base / "root-alias"
        os.symlink(str(other.root), root_alias)
        other.manifest_data["allowed_roots"] = [str(root_alias)]
        for operation in other.manifest_data["operations"]:
            for key in ("path", "old_target", "new_target", "old_source", "new_source"):
                if key in operation:
                    operation[key] = str(operation[key]).replace(str(other.root), str(root_alias), 1)
        other.manifest_data["journal_path"] = str(other.journal).replace(
            str(other.root), str(root_alias), 1
        )
        other.write_manifest()
        with self.assertRaisesRegex(cutover.CutoverError, "real directory"):
            other.load()

    def test_broad_root_and_home_are_refused(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        for broad in ("/", str(Path.home())):
            with self.subTest(root=broad):
                fixture.manifest_data["allowed_roots"] = [broad]
                fixture.write_manifest()
                with self.assertRaisesRegex(cutover.CutoverError, "root/home/broad"):
                    fixture.load()

    def test_manifest_symlink_is_refused_before_read(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        alias = fixture.base / "manifest-alias.json"
        os.symlink(str(fixture.manifest_path), alias)

        with self.assertRaisesRegex(cutover.CutoverError, "manifest path has a symlinked"):
            cutover.load_manifest(str(alias))

    def test_unexpected_temporary_symlink_is_refused(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        manifest = fixture.load()
        operation = manifest.operations[0]
        self.assertIsInstance(operation, cutover.SymlinkOperation)
        temp = cutover._temp_path(operation.path, manifest.transaction_id, "forward")
        os.symlink(str(fixture.releases / "unknown"), temp)

        with self.assertRaisesRegex(cutover.CutoverError, "exact expected staged symlink"):
            cutover.execute(fixture.load(), "forward")
        self.assertEqual(os.readlink(fixture.link_paths[0]), str(fixture.releases / "quota-old"))
        self.assertEqual(os.readlink(fixture.link_paths[1]), str(fixture.releases / "agent-fleet-old"))
        self.assertEqual(fixture.registry.read_bytes(), fixture.old_source.read_bytes())
        self.assertFalse(fixture.journal.exists())

    def test_derived_temporary_path_collision_is_refused(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        first_path = Path(fixture.manifest_data["operations"][0]["path"])
        fixture.manifest_data["operations"][1]["path"] = str(
            cutover._temp_path(first_path, "test-cutover-001", "forward")
        )
        fixture.write_manifest()

        with self.assertRaisesRegex(cutover.CutoverError, "temporary path collides"):
            fixture.load()

    def test_external_change_during_preparation_is_not_overwritten(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        unknown = fixture.releases / "unknown-concurrent"
        unknown.mkdir()

        class ChangeAtPrepare(cutover.BoundaryController):
            def hit(self, label: str) -> None:
                super().hit(label)
                if label == "after_prepare:forward:quota-current":
                    atomic_link(fixture.link_paths[0], unknown)

        with self.assertRaisesRegex(cutover.CutoverError, "unknown target"):
            cutover.execute(fixture.load(), "forward", ChangeAtPrepare())
        self.assertEqual(os.readlink(fixture.link_paths[0]), str(unknown))
        self.assertEqual(os.readlink(fixture.link_paths[1]), str(fixture.releases / "agent-fleet-old"))
        self.assertEqual(fixture.registry.read_bytes(), fixture.old_source.read_bytes())

    def test_symlink_change_after_quiet_point_is_not_overwritten(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        unknown = fixture.releases / "unknown-post-quiet"
        unknown.mkdir()
        manifest = fixture.load()
        operation = manifest.operations[0]
        temporary = cutover._temp_path(
            operation.path, manifest.transaction_id, "forward"
        )
        original_quiet = cutover._validate_quiet_point
        changed = False

        def quiet_then_change(value: cutover.Manifest) -> None:
            nonlocal changed
            original_quiet(value)
            if os.path.lexists(temporary) and not changed:
                changed = True
                atomic_link(fixture.link_paths[0], unknown)

        with mock.patch.object(
            cutover, "_validate_quiet_point", side_effect=quiet_then_change
        ):
            with self.assertRaisesRegex(
                cutover.CutoverError,
                "(unknown target|immediately before replacement)",
            ):
                cutover.execute(manifest, "forward")
        self.assertEqual(os.readlink(fixture.link_paths[0]), str(unknown))

    def test_regular_file_change_after_quiet_point_is_not_overwritten(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        racer = b'version = 1\nmode = "racer"\n'
        manifest = fixture.load()
        operation = manifest.operations[-1]
        temporary = cutover._temp_path(
            operation.path, manifest.transaction_id, "forward"
        )
        original_quiet = cutover._validate_quiet_point
        changed = False

        def quiet_then_change(value: cutover.Manifest) -> None:
            nonlocal changed
            original_quiet(value)
            if os.path.lexists(temporary) and not changed:
                changed = True
                fixture.registry.write_bytes(racer)
                fixture.registry.chmod(0o600)

        with mock.patch.object(
            cutover, "_validate_quiet_point", side_effect=quiet_then_change
        ):
            with self.assertRaisesRegex(
                cutover.CutoverError,
                "(unknown (content|SHA-256)|immediately before replacement)",
            ):
                cutover.execute(manifest, "forward")
        self.assertEqual(fixture.registry.read_bytes(), racer)

    def test_symlink_change_at_exchange_syscall_is_swapped_back_and_preserved(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        unknown = fixture.releases / "unknown-at-exchange"
        unknown.mkdir()

        class ChangeAtExchange(cutover.BoundaryController):
            def hit(self, label: str) -> None:
                super().hit(label)
                if label == "immediately_before_exchange:forward:quota-current":
                    atomic_link(fixture.link_paths[0], unknown)

        with self.assertRaisesRegex(cutover.CutoverError, "displaced live state"):
            cutover.execute(fixture.load(), "forward", ChangeAtExchange())
        self.assertEqual(os.readlink(fixture.link_paths[0]), str(unknown))
        self.assertEqual(
            os.readlink(fixture.link_paths[1]), str(fixture.releases / "agent-fleet-old")
        )

    def test_regular_change_at_exchange_syscall_is_swapped_back_and_preserved(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        racer = b'version = 1\nmode = "syscall-racer"\n'

        class ChangeAtExchange(cutover.BoundaryController):
            def hit(self, label: str) -> None:
                super().hit(label)
                if label == "immediately_before_exchange:forward:accounts-registry":
                    fixture.registry.write_bytes(racer)
                    fixture.registry.chmod(0o600)

        with self.assertRaisesRegex(cutover.CutoverError, "displaced live state"):
            cutover.execute(fixture.load(), "forward", ChangeAtExchange())
        self.assertEqual(fixture.registry.read_bytes(), racer)

    def test_activity_appearing_between_operations_stops_cutover_and_recovery(self) -> None:
        fixture = Fixture(relative_targets=True)
        self.addCleanup(fixture.close)
        lease = fixture.quiet_state_paths[0] / "appeared-between-operations.json"

        class StartFleetWorkAfterFirstReplace(cutover.BoundaryController):
            def hit(self, label: str) -> None:
                super().hit(label)
                if label == "after_replace:forward:quota-current":
                    lease.write_text("busy\n", encoding="utf-8")

        with self.assertRaisesRegex(cutover.CutoverError, "state path is not empty"):
            cutover.execute(
                fixture.load(), "forward", StartFleetWorkAfterFirstReplace()
            )
        self.assertEqual(
            [os.readlink(path) for path in fixture.link_paths],
            [
                fixture.raw_targets[("quota", "new")],
                fixture.raw_targets[("agent-fleet", "old")],
            ],
        )
        with self.assertRaisesRegex(cutover.CutoverError, "state path is not empty"):
            cutover.execute(fixture.load(), "rollback")

        lease.unlink()
        cutover.execute(fixture.load(), "rollback")
        fixture.assert_old(self)

    def test_parent_directory_symlink_swap_during_preparation_is_refused(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        real_state = fixture.root / "state-before-swap"
        attacker_state = fixture.root / "state-attacker"

        class SwapParentAtPrepare(cutover.BoundaryController):
            def hit(self, label: str) -> None:
                super().hit(label)
                if label == "after_prepare:forward:quota-current":
                    os.rename(fixture.state, real_state)
                    attacker_state.mkdir()
                    os.symlink(str(attacker_state), fixture.state)

        with self.assertRaisesRegex(
            cutover.CutoverError, "parent component is missing, not a directory, or a symlink"
        ):
            cutover.execute(fixture.load(), "forward", SwapParentAtPrepare())
        self.assertEqual(
            os.readlink(real_state / "quota-current"),
            str(fixture.releases / "quota-old"),
        )
        self.assertFalse((attacker_state / "quota-current").exists())

    def test_manifest_fingerprint_change_refuses_existing_journal(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        cutover.execute(fixture.load(), "forward")
        fixture.manifest_data["apply_opt_in"] = False
        fixture.write_manifest()

        with self.assertRaisesRegex(cutover.CutoverError, "manifest SHA-256"):
            cutover.plan(fixture.load())
        fixture.assert_no_payload_deletion(self)

    def test_history_at_entry_limit_prunes_oldest_and_stays_readable(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        manifest = fixture.load()
        journal = cutover._new_journal(manifest)
        journal["sequence"] = cutover.MAX_JOURNAL_HISTORY_ENTRIES
        journal["history"] = [
            {
                "sequence": sequence,
                "phase": "seed",
                "moment": "checkpoint",
                "observed": ["old", "old", "old"],
            }
            for sequence in range(1, cutover.MAX_JOURNAL_HISTORY_ENTRIES + 1)
        ]
        fixture.journal.write_text(
            json.dumps(journal, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        fixture.journal.chmod(0o600)

        cutover.execute(manifest, "forward")

        loaded = cutover._load_journal(fixture.load())
        self.assertIsNotNone(loaded)
        self.assertEqual(len(loaded["history"]), cutover.MAX_JOURNAL_HISTORY_ENTRIES)
        self.assertGreater(loaded["history"][0]["sequence"], 1)
        self.assertEqual(loaded["history"][-1]["phase"], "forward")
        self.assertEqual(loaded["history"][-1]["moment"], "complete")
        self.assertLessEqual(fixture.journal.stat().st_size, cutover.MAX_JOURNAL_BYTES)

    def test_near_size_limit_journal_prunes_to_latest_suffix_before_write(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        manifest = fixture.load()
        journal = cutover._new_journal(manifest)
        journal["sequence"] = 1
        journal["history"] = [
            {
                "sequence": 1,
                "phase": "large-seed",
                "moment": "checkpoint",
                "observed": ["old", "old", "old"],
                "note": "",
            }
        ]
        initial = (
            json.dumps(journal, sort_keys=True, separators=(",", ":")) + "\n"
        ).encode("utf-8")
        headroom = 32
        journal["history"][0]["note"] = "x" * (
            cutover.MAX_JOURNAL_BYTES - headroom - len(initial)
        )
        payload = (
            json.dumps(journal, sort_keys=True, separators=(",", ":")) + "\n"
        ).encode("utf-8")
        self.assertEqual(len(payload), cutover.MAX_JOURNAL_BYTES - headroom)
        fixture.journal.write_bytes(payload)
        fixture.journal.chmod(0o600)

        cutover.execute(manifest, "forward")

        loaded = cutover._load_journal(fixture.load())
        self.assertIsNotNone(loaded)
        self.assertLessEqual(fixture.journal.stat().st_size, cutover.MAX_JOURNAL_BYTES)
        self.assertFalse(any(entry.get("phase") == "large-seed" for entry in loaded["history"]))
        self.assertEqual(loaded["history"][-1]["moment"], "complete")

    def test_single_oversized_checkpoint_refuses_before_journal_replace(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        manifest = fixture.load()
        journal = cutover._new_journal(manifest)
        recorder = cutover.BoundaryController()

        with self.assertRaisesRegex(cutover.CutoverError, "latest journal checkpoint alone"):
            cutover._checkpoint(
                manifest,
                journal,
                "oversized",
                "before-write",
                ["new"] * 700_000,
                recorder,
            )
        self.assertFalse(fixture.journal.exists())
        self.assertFalse(any(label.startswith("before_journal:") for label in recorder.seen))

    def test_oversized_manifest_is_refused_before_parse(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        fixture.manifest_path.write_bytes(b" " * (cutover.MAX_MANIFEST_BYTES + 1))

        with self.assertRaisesRegex(cutover.CutoverError, "manifest exceeds"):
            fixture.load()

    def test_partial_known_forward_state_without_journal_reconciles(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        first_new = Path(fixture.manifest_data["operations"][0]["new_target"])
        atomic_link(fixture.link_paths[0], first_new)
        self.assertFalse(fixture.journal.exists())

        result = cutover.execute(fixture.load(), "forward")

        self.assertTrue(result["converged"])
        fixture.assert_new(self)

    def test_driver_does_not_delete_unrelated_files(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        unrelated = fixture.root / "unrelated-do-not-delete"
        unrelated.write_text("keep\n", encoding="utf-8")

        cutover.execute(fixture.load(), "forward")
        cutover.execute(fixture.load(), "rollback")

        self.assertEqual(unrelated.read_text(encoding="utf-8"), "keep\n")
        fixture.assert_no_payload_deletion(self)


if __name__ == "__main__":
    unittest.main()
