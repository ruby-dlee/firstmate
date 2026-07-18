from __future__ import annotations

import builtins
import hashlib
import io
import json
import os
import signal
import shutil
import subprocess
import sys
import textwrap
import unittest
from pathlib import Path
from unittest import mock


SCRIPT_DIR = Path(__file__).resolve().parents[1] / "tools" / "bridge-cutover"
sys.path.insert(0, str(SCRIPT_DIR))

import bridge_worker_state_transaction as worker_state  # noqa: E402
from tests.test_prepare_bridge_cutover import (  # noqa: E402
    CutoverPreparationFixture,
    prepare,
)


@unittest.skipUnless(sys.platform == "darwin", "worker-state cutover is macOS-only")
class WorkerStateTransactionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = CutoverPreparationFixture()
        self.fixture.prepare()
        bundle = json.loads(
            (self.fixture.bundle_dir / "bundle.json").read_text(encoding="utf-8")
        )
        adoption = prepare._load_adoption_driver()
        adoption.apply(
            adoption.load_manifest(Path(bundle["adoption_manifest_path"]))
        )
        self.manifest_path = self.fixture.bundle_dir / "worker-state.manifest.json"
        self.manifest = worker_state.load_manifest(self.manifest_path)
        for path in self.manifest.identity_bundles.values():
            path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)

    def tearDown(self) -> None:
        self.fixture.cleanup()

    @staticmethod
    def _canonical(value: object) -> bytes:
        return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")

    def _materialize_provisioned_workers(self) -> None:
        bundle = json.loads(
            (self.fixture.bundle_dir / "bundle.json").read_text(encoding="utf-8")
        )
        contract = bundle["activation_plan"]["provision"]["sealed_contract"]
        closed = self._canonical(contract["closed_claude_state"]["payload"])
        for profile_id, sealed in contract["plans"].items():
            plan = sealed["plan"]
            home = Path(plan["home"])
            home.mkdir(parents=True, mode=0o700, exist_ok=True)
            home.chmod(0o700)
            for entry in plan["entries"]:
                relative = entry["relative_path"]
                if relative == ".":
                    continue
                path = home / relative
                if entry["type"] == "dir":
                    path.mkdir(parents=True, mode=int(entry["mode"], 8), exist_ok=True)
                    path.chmod(int(entry["mode"], 8))
                elif entry["type"] == "symlink":
                    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
                    os.symlink(entry["target"], path)
                else:
                    payload = (
                        closed
                        if relative == ".claude.json"
                        else self._canonical({"profile": profile_id, "path": relative})
                    )
                    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
                    path.write_bytes(payload)
                    path.chmod(int(entry["mode"], 8))

    def _write_identity_bundles(self) -> None:
        for provider, path in self.manifest.identity_bundles.items():
            path.write_text(
                json.dumps({"schema": 1, "provider": provider}), encoding="utf-8"
            )
            path.chmod(0o600)

    def test_snapshot_verify_and_finalize_exact_six_workers(self) -> None:
        started = worker_state.begin(self.manifest)
        self.assertEqual(started["phase"], "snapshotted")
        self.assertEqual(started["workers"], sorted(worker_state.WORKERS))
        self.assertFalse(started["reserves_touched"])
        self._materialize_provisioned_workers()
        verified = worker_state.verify_provisioned(self.manifest)
        self.assertEqual(verified["phase"], "provision_verified")
        self._write_identity_bundles()
        finalized = worker_state.finalize(self.manifest)
        self.assertEqual(finalized["phase"], "complete")
        self.assertTrue(finalized["worker_state_ready"])
        with self.assertRaisesRegex(worker_state.WorkerStateError, "irreversible"):
            worker_state.rollback(self.manifest)
        cleaned = worker_state.cleanup(self.manifest)
        self.assertEqual(cleaned["phase"], "cleaned")
        self.assertFalse(cleaned["snapshot_bytes_present"])
        self.assertFalse(self.manifest.snapshot_path.exists())

    def test_restartable_rollback_restores_exact_absence(self) -> None:
        worker_state.begin(self.manifest)
        self._materialize_provisioned_workers()
        self._write_identity_bundles()
        with self.assertRaises(worker_state.InjectedFailure):
            worker_state.rollback(
                self.manifest,
                worker_state.BoundaryController(fail_after=1),
            )
        result = worker_state.rollback(self.manifest)
        self.assertEqual(result["phase"], "rolled_back")
        for value in self.manifest.workers:
            self.assertFalse(os.path.lexists(value.home))
        for path in self.manifest.identity_bundles.values():
            self.assertFalse(os.path.lexists(path))

    def test_identity_rollback_resumes_sigkill_after_exchange_and_preserves_foreign_state(self) -> None:
        worker_state.begin(self.manifest)
        self._materialize_provisioned_workers()
        self._write_identity_bundles()
        injector = textwrap.dedent(
            f"""\
            import os, signal, sys
            from pathlib import Path
            sys.path.insert(0, {str(SCRIPT_DIR)!r})
            import bridge_worker_state_transaction as module
            class KillAfterIdentityExchange(module.BoundaryController):
                def hit(self, label):
                    super().hit(label)
                    if label == "after_exchange:identity:claude":
                        os.kill(os.getpid(), signal.SIGKILL)
            manifest = module.load_manifest(Path({str(self.manifest_path)!r}))
            module.rollback(manifest, KillAfterIdentityExchange())
            """
        )
        killed = subprocess.run(
            [sys.executable, "-c", injector],
            check=False,
            capture_output=True,
            text=True,
            timeout=120,
            env={
                **os.environ,
                "PYTHONDONTWRITEBYTECODE": "1",
            },
        )
        self.assertEqual(killed.returncode, -signal.SIGKILL)
        journal = json.loads(
            self.manifest.journal_path.read_text(encoding="utf-8")
        )
        self.assertEqual(journal["identity_restore"]["provider"], "claude")
        self.assertEqual(journal["identity_restore"]["phase"], "exchanged")
        identity = self.manifest.identity_bundles["claude"]
        temporary = list(identity.parent.glob(f".{identity.name}.restore-*"))
        self.assertEqual(len(temporary), 1)

        identity.write_text('{"foreign-after-crash":true}', encoding="utf-8")
        identity.chmod(0o600)
        with self.assertRaisesRegex(
            worker_state.WorkerStateError,
            "ambiguous interrupted absent restore",
        ):
            worker_state.rollback(self.manifest)
        self.assertEqual(
            identity.read_text(encoding="utf-8"), '{"foreign-after-crash":true}'
        )
        self.assertEqual(list(identity.parent.glob(f".{identity.name}.restore-*")), temporary)

        identity.unlink()
        result = worker_state.rollback(self.manifest)
        self.assertEqual(result["phase"], "rolled_back")
        self.assertFalse(os.path.lexists(identity))
        self.assertFalse(list(identity.parent.glob(f".{identity.name}.restore-*")))

    def test_file_identity_rollback_resumes_sigkill_and_preserves_foreign_state(self) -> None:
        identity = self.manifest.identity_bundles["claude"]
        original = b'{"original-file-identity":true}'
        identity.write_bytes(original)
        identity.chmod(0o600)
        worker_state.begin(self.manifest)
        self._materialize_provisioned_workers()
        self._write_identity_bundles()
        injector = textwrap.dedent(
            f"""\
            import os, signal, sys
            from pathlib import Path
            sys.path.insert(0, {str(SCRIPT_DIR)!r})
            import bridge_worker_state_transaction as module
            class KillAfterIdentityExchange(module.BoundaryController):
                def hit(self, label):
                    super().hit(label)
                    if label == "after_exchange:identity:claude":
                        os.kill(os.getpid(), signal.SIGKILL)
            manifest = module.load_manifest(Path({str(self.manifest_path)!r}))
            module.rollback(manifest, KillAfterIdentityExchange())
            """
        )
        killed = subprocess.run(
            [sys.executable, "-c", injector],
            check=False,
            capture_output=True,
            text=True,
            timeout=120,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        self.assertEqual(killed.returncode, -signal.SIGKILL)
        journal = json.loads(
            self.manifest.journal_path.read_text(encoding="utf-8")
        )
        self.assertEqual(journal["identity_restore"]["phase"], "exchanged")
        self.assertEqual(journal["identity_restore"]["restore_state"]["type"], "file")
        self.assertIn("data", journal["identity_restore"]["restore_state"])
        temporary = list(identity.parent.glob(f".{identity.name}.restore-*"))
        self.assertEqual(len(temporary), 1)
        self.assertEqual(identity.read_bytes(), original)

        foreign = b'{"foreign-after-file-exchange":true}'
        identity.unlink()
        identity.write_bytes(foreign)
        identity.chmod(0o600)
        foreign_identity = os.lstat(identity)
        with self.assertRaisesRegex(
            worker_state.WorkerStateError, "ambiguous interrupted restore"
        ):
            worker_state.rollback(self.manifest)
        self.assertEqual(identity.read_bytes(), foreign)
        self.assertEqual(
            (os.lstat(identity).st_dev, os.lstat(identity).st_ino),
            (foreign_identity.st_dev, foreign_identity.st_ino),
        )
        self.assertEqual(
            list(identity.parent.glob(f".{identity.name}.restore-*")), temporary
        )

        identity.unlink()
        identity.write_bytes(original)
        identity.chmod(0o600)
        result = worker_state.rollback(self.manifest)
        self.assertEqual(result["phase"], "rolled_back")
        self.assertEqual(identity.read_bytes(), original)
        self.assertFalse(list(identity.parent.glob(f".{identity.name}.restore-*")))

    def test_credential_guard_blocks_verification_and_secret_is_not_snapshotted(self) -> None:
        target_worker = next(
            value for value in self.manifest.workers if value.profile == "codex-1"
        )
        target_worker.home.mkdir(parents=True, mode=0o700)
        credential = target_worker.home / "auth.json"
        secret = b'\x00super-secret-auth-token\xff'
        credential.write_bytes(secret)
        credential.chmod(0o600)
        worker_state.begin(self.manifest)
        for path in self.manifest.snapshot_path.rglob("*"):
            if path.is_file():
                self.assertNotIn(secret, path.read_bytes())
        journal = self.manifest.journal_path.read_bytes()
        self.assertNotIn(secret, journal)
        credential.write_bytes(b"changed-secret")
        credential.chmod(0o600)
        with self.assertRaisesRegex(worker_state.WorkerStateError, "credential guard changed"):
            worker_state.verify_provisioned(self.manifest)

    def test_post_canary_token_rotation_never_blocks_or_gets_overwritten_by_rollback(self) -> None:
        target_worker = next(
            value for value in self.manifest.workers if value.profile == "codex-1"
        )
        target_worker.home.mkdir(parents=True, mode=0o700)
        credential = target_worker.home / "auth.json"
        credential.write_bytes(b"pre-canary-token")
        credential.chmod(0o600)
        worker_state.begin(self.manifest)
        self._materialize_provisioned_workers()
        credential.write_bytes(b"rotated-during-canary")
        credential.chmod(0o600)
        result = worker_state.rollback(self.manifest)
        self.assertEqual(result["phase"], "rolled_back")
        self.assertEqual(credential.read_bytes(), b"rotated-during-canary")
        journal = json.loads(self.manifest.journal_path.read_text(encoding="utf-8"))
        self.assertEqual(journal["credential_drift"], ["codex-1"])
        self.assertFalse((target_worker.home / "config.toml").exists())

    def test_credential_drift_invalidates_prior_provider_bundle(self) -> None:
        target_worker = next(
            value for value in self.manifest.workers if value.profile == "codex-1"
        )
        target_worker.home.mkdir(parents=True, mode=0o700)
        credential = target_worker.home / "auth.json"
        credential.write_bytes(b"before")
        credential.chmod(0o600)
        self._write_identity_bundles()
        claude_before = self.manifest.identity_bundles["claude"].read_bytes()
        worker_state.begin(self.manifest)
        self._materialize_provisioned_workers()
        self.manifest.identity_bundles["codex"].write_text(
            '{"schema":1,"provider":"codex","fresh":true}', encoding="utf-8"
        )
        credential.write_bytes(b"rotated-or-replaced")
        credential.chmod(0o600)
        worker_state.rollback(self.manifest)
        self.assertEqual(credential.read_bytes(), b"rotated-or-replaced")
        self.assertFalse(os.path.lexists(self.manifest.identity_bundles["codex"]))
        self.assertEqual(
            self.manifest.identity_bundles["claude"].read_bytes(), claude_before
        )

    def test_absent_home_new_credential_survives_rollback_and_invalidates_bundle(self) -> None:
        worker_state.begin(self.manifest)
        self._materialize_provisioned_workers()
        self._write_identity_bundles()
        target_worker = next(
            value for value in self.manifest.workers if value.profile == "codex-1"
        )
        credential = target_worker.home / "auth.json"
        credential.write_bytes(b"new-token")
        credential.chmod(0o600)
        worker_state.rollback(self.manifest)
        self.assertEqual(credential.read_bytes(), b"new-token")
        self.assertTrue(target_worker.home.is_dir())
        self.assertFalse(os.path.lexists(self.manifest.identity_bundles["codex"]))

    def test_rollback_refuses_substituted_worker_home_symlink(self) -> None:
        worker_state.begin(self.manifest)
        target_worker = next(
            value for value in self.manifest.workers if value.profile == "codex-1"
        )
        external = self.fixture.root / "external-do-not-touch"
        external.mkdir(mode=0o700)
        sentinel = external / "config.toml"
        sentinel.write_text("external\n", encoding="utf-8")
        target_worker.home.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        os.symlink(external, target_worker.home)
        with self.assertRaisesRegex(worker_state.WorkerStateError, "cannot bind worker home"):
            worker_state.rollback(self.manifest)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "external\n")

    def test_cleanup_restarts_at_every_durability_boundary(self) -> None:
        worker_state.begin(self.manifest)
        worker_state.rollback(self.manifest)
        saved_journal = self.manifest.journal_path.read_bytes()
        saved_snapshot = self.fixture.root / "saved-worker-snapshot"
        shutil.copytree(self.manifest.snapshot_path, saved_snapshot, symlinks=True)
        for fail_after in (1, 2, 3):
            with self.subTest(fail_after=fail_after):
                if os.path.lexists(self.manifest.snapshot_path):
                    shutil.rmtree(self.manifest.snapshot_path)
                shutil.copytree(saved_snapshot, self.manifest.snapshot_path, symlinks=True)
                self.manifest.journal_path.write_bytes(saved_journal)
                self.manifest.journal_path.chmod(0o600)
                with self.assertRaises(worker_state.InjectedFailure):
                    worker_state.cleanup(
                        self.manifest,
                        worker_state.BoundaryController(fail_after=fail_after),
                    )
                if fail_after == 1:
                    # Model a process death in the middle of recursive deletion.
                    (self.manifest.snapshot_path / "snapshot.json").unlink()
                result = worker_state.cleanup(self.manifest)
                self.assertEqual(result["phase"], "cleaned")
                self.assertFalse(os.path.lexists(self.manifest.snapshot_path))
                self.assertEqual(worker_state.rollback(self.manifest)["phase"], "cleaned")

    def test_begin_restarts_at_every_durability_boundary(self) -> None:
        for fail_after in (1, 2, 3):
            with self.subTest(fail_after=fail_after):
                if os.path.lexists(self.manifest.snapshot_path):
                    shutil.rmtree(self.manifest.snapshot_path)
                if os.path.lexists(self.manifest.journal_path):
                    self.manifest.journal_path.unlink()
                with self.assertRaises(worker_state.InjectedFailure):
                    worker_state.begin(
                        self.manifest,
                        worker_state.BoundaryController(fail_after=fail_after),
                    )
                recovered = worker_state.begin(self.manifest)
                self.assertEqual(recovered["phase"], "snapshotted")
                self.assertTrue(self.manifest.snapshot_path.is_dir())

    def test_failed_restore_removes_deterministic_temporary_artifact(self) -> None:
        target_worker = next(
            value for value in self.manifest.workers if value.profile == "claude-1"
        )
        target_worker.home.mkdir(parents=True, mode=0o700)
        settings = target_worker.home / "settings.json"
        settings.write_text('{"before":true}', encoding="utf-8")
        settings.chmod(0o600)
        worker_state.begin(self.manifest)
        self._materialize_provisioned_workers()
        original = worker_state._materialize_node_at
        raised = False

        def fail_after_materialize(*args: object, **kwargs: object) -> None:
            nonlocal raised
            original(*args, **kwargs)
            if not raised:
                raised = True
                raise worker_state.InjectedFailure("restore materialization")

        with mock.patch.object(
            worker_state, "_materialize_node_at", side_effect=fail_after_materialize
        ):
            with self.assertRaises(worker_state.InjectedFailure):
                worker_state.rollback(self.manifest)
        self.assertEqual(list(target_worker.home.glob(".*.restore-*")), [])
        worker_state.rollback(self.manifest)
        self.assertEqual(settings.read_text(encoding="utf-8"), '{"before":true}')

    def test_rollback_refuses_and_preserves_unattributed_managed_drift(self) -> None:
        target_worker = next(
            value for value in self.manifest.workers if value.profile == "claude-1"
        )
        target_worker.home.mkdir(parents=True, mode=0o700)
        settings = target_worker.home / "settings.json"
        settings.write_text('{"before":true}', encoding="utf-8")
        settings.chmod(0o600)
        worker_state.begin(self.manifest)
        settings.write_text('{"foreign":true}', encoding="utf-8")
        settings.chmod(0o600)
        with self.assertRaisesRegex(
            worker_state.WorkerStateError, "managed state drift is not attributable"
        ):
            worker_state.rollback(self.manifest)
        self.assertEqual(settings.read_text(encoding="utf-8"), '{"foreign":true}')

    def test_rollback_rechecks_attribution_immediately_before_replace(self) -> None:
        worker_state.begin(self.manifest)
        self._materialize_provisioned_workers()
        target_worker = next(
            value for value in self.manifest.workers if value.profile == "claude-1"
        )
        target = target_worker.home / ".claude.json"
        original_assert = worker_state._assert_worker_entry_attributed
        calls = 0

        def race_on_second_check(
            manifest: worker_state.Manifest,
            worker: worker_state.Worker,
            snapshot: object,
            home_fd: int | None,
            relative: str,
        ) -> None:
            nonlocal calls
            if worker.profile == "claude-1" and relative == ".claude.json":
                calls += 1
                if calls == 2:
                    target.write_text('{"foreign":true}', encoding="utf-8")
                    target.chmod(0o600)
            original_assert(manifest, worker, snapshot, home_fd, relative)

        with mock.patch.object(
            worker_state,
            "_assert_worker_entry_attributed",
            side_effect=race_on_second_check,
        ):
            with self.assertRaisesRegex(
                worker_state.WorkerStateError,
                "managed state drift is not attributable",
            ):
                worker_state.rollback(self.manifest)
        self.assertEqual(target.read_text(encoding="utf-8"), '{"foreign":true}')
        self.assertEqual(list(target_worker.home.glob(".*.restore-*")), [])

    def test_rollback_preserves_foreign_state_arriving_at_exchange_syscall(self) -> None:
        worker_state.begin(self.manifest)
        self._materialize_provisioned_workers()
        target_worker = next(
            value for value in self.manifest.workers if value.profile == "claude-1"
        )
        target = target_worker.home / ".claude.json"

        class ChangeAtExchange(worker_state.BoundaryController):
            def hit(self, label: str) -> None:
                super().hit(label)
                if label == "immediately_before_exchange:worker:claude-1:.claude.json":
                    target.write_text('{"foreign-at-syscall":true}', encoding="utf-8")
                    target.chmod(0o600)

        with self.assertRaisesRegex(worker_state.WorkerStateError, "not attributable"):
            worker_state.rollback(self.manifest, ChangeAtExchange())
        self.assertEqual(
            target.read_text(encoding="utf-8"), '{"foreign-at-syscall":true}'
        )
        self.assertEqual(list(target_worker.home.glob(".*.restore-*")), [])

    def test_manifest_rejects_worker_overlap_with_candidate_release(self) -> None:
        raw = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        worker = next(value for value in raw["workers"] if value["profile"] == "claude-1")
        plan = raw["sealed_plans"]["claude-1"]["plan"]
        worker["home"] = raw["candidate_release"]
        plan["home"] = raw["candidate_release"]
        digest = hashlib.sha256(self._canonical(plan)).hexdigest()
        worker["plan_sha256"] = digest
        raw["sealed_plans"]["claude-1"]["plan_sha256"] = digest
        self.manifest_path.write_bytes(self._canonical(raw))
        self.manifest_path.chmod(0o600)
        with self.assertRaisesRegex(worker_state.WorkerStateError, "overlaps immutable"):
            worker_state.load_manifest(self.manifest_path)

    def test_journal_restore_keys_are_closed_and_unique(self) -> None:
        worker_state.begin(self.manifest)
        original = json.loads(self.manifest.journal_path.read_text(encoding="utf-8"))
        for invalid in (["not-a-restore-key"], ["identity:claude", "identity:claude"]):
            with self.subTest(invalid=invalid):
                journal = dict(original)
                journal["restore_completed"] = invalid
                self.manifest.journal_path.write_bytes(self._canonical(journal))
                self.manifest.journal_path.chmod(0o600)
                with self.assertRaisesRegex(worker_state.WorkerStateError, "restore list"):
                    worker_state.plan(self.manifest)

    def test_credential_digest_is_absent_from_every_public_artifact(self) -> None:
        target_worker = next(
            value for value in self.manifest.workers if value.profile == "codex-1"
        )
        target_worker.home.mkdir(parents=True, mode=0o700)
        secret = b"public-digest-must-not-leak"
        credential = target_worker.home / "auth.json"
        credential.write_bytes(secret)
        credential.chmod(0o600)
        worker_state.begin(self.manifest)
        digest = hashlib.sha256(secret).hexdigest().encode()
        public_payloads = (
            self.manifest_path.read_bytes(),
            self.manifest.bundle_path.read_bytes(),
            self.manifest.journal_path.read_bytes(),
            self._canonical(worker_state.plan(self.manifest)),
        )
        for payload in public_payloads:
            self.assertNotIn(secret, payload)
            self.assertNotIn(digest, payload)

    def test_begin_never_lstats_or_opens_reserve_homes(self) -> None:
        share = self.fixture.root / "fleet-share" / "accounts"
        reserves = (
            share / "claude" / "claude-3",
            share / "codex" / "codex-5",
        )
        for reserve in reserves:
            reserve.mkdir(parents=True, mode=0o700)
            (reserve / "sentinel").write_text("reserve", encoding="utf-8")
        original_lstat = os.lstat
        original_open = builtins.open
        original_io_open = io.open

        def guarded_lstat(path: object, *args: object, **kwargs: object) -> os.stat_result:
            observed = Path(os.fspath(path))
            if any(observed == root or root in observed.parents for root in reserves):
                raise AssertionError(f"reserve lstat: {observed}")
            return original_lstat(path, *args, **kwargs)

        def guarded_open(path: object, *args: object, **kwargs: object) -> object:
            if isinstance(path, (str, os.PathLike)):
                observed = Path(os.fspath(path))
                if any(observed == root or root in observed.parents for root in reserves):
                    raise AssertionError(f"reserve open: {observed}")
            return original_open(path, *args, **kwargs)

        def guarded_io_open(path: object, *args: object, **kwargs: object) -> object:
            if isinstance(path, (str, os.PathLike)):
                observed = Path(os.fspath(path))
                if any(observed == root or root in observed.parents for root in reserves):
                    raise AssertionError(f"reserve io.open: {observed}")
            return original_io_open(path, *args, **kwargs)

        with mock.patch("os.lstat", side_effect=guarded_lstat), mock.patch(
            "builtins.open", side_effect=guarded_open
        ), mock.patch(
            "io.open", side_effect=guarded_io_open
        ):
            result = worker_state.begin(self.manifest)
        self.assertEqual(result["phase"], "snapshotted")
        for reserve in reserves:
            self.assertEqual((reserve / "sentinel").read_text(encoding="utf-8"), "reserve")

    def test_manifest_contains_no_reserve_paths_or_automatic_commands(self) -> None:
        manifest_bytes = self.manifest_path.read_bytes()
        self.assertNotIn(b"claude-3", manifest_bytes)
        self.assertNotIn(b"codex-5", manifest_bytes)
        self.assertNotIn(b"login", manifest_bytes.lower())
        self.assertNotIn(b"browser", manifest_bytes.lower())
        self.assertNotIn(b"keychain", manifest_bytes.lower())
        self.assertNotIn(b"command", manifest_bytes.lower())
        bundle = json.loads(
            (self.fixture.bundle_dir / "bundle.json").read_text(encoding="utf-8")
        )
        self.assertNotIn("claude-captain", json.dumps(bundle, sort_keys=True))
        self.assertNotIn(
            "claude-captain",
            self.manifest.candidate_registry_path.read_text(encoding="utf-8"),
        )
        self.assertEqual(bundle["activation_plan"]["commands"], [])
        manual = bundle["activation_plan"]["manual_profile_login"]
        self.assertTrue(manual["enabled"])
        self.assertEqual(manual["commands"], [])
        self.assertFalse(manual["automatic_execution"])
        self.assertFalse(manual["automatic_browser_open"])
        self.assertFalse(manual["automatic_profile_enable"])
        self.assertEqual(
            manual["profiles"],
            ["claude-1", "claude-2", "codex-1", "codex-2", "codex-3", "codex-4"],
        )
        serialized = json.dumps(manual, sort_keys=True)
        self.assertNotIn("claude-3", serialized)
        self.assertNotIn("codex-5", serialized)


if __name__ == "__main__":
    unittest.main()
