from __future__ import annotations

import hashlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT_DIR = Path(__file__).resolve().parents[1] / "tools" / "bridge-cutover"
sys.path.insert(0, str(SCRIPT_DIR))

import bridge_cutover_transaction as transaction  # noqa: E402
import bridge_sealed_adoption as adoption  # noqa: E402


PROFILE_IDS = tuple(
    sorted(
        (
            "claude-1",
            "claude-2",
            "claude-3",
            "codex-1",
            "codex-2",
            "codex-3",
            "codex-4",
            "codex-5",
        )
    )
)
WORKER_PROFILE_IDS = tuple(
    profile for profile in PROFILE_IDS if profile not in {"claude-3", "codex-5"}
)
RESERVE_PROFILE_IDS = ("claude-3", "codex-5")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Fixture:
    def __init__(self, *, apply_opt_in: bool = True) -> None:
        real_temp = Path(os.path.realpath(tempfile.gettempdir()))
        self._temporary = tempfile.TemporaryDirectory(
            prefix="bridge-sealed-adoption-test-", dir=real_temp
        )
        self.base = Path(self._temporary.name)
        self.root = self.base / "adoption-root"
        self.root.mkdir(mode=0o700)
        self.private = self.root / "private"
        self.private.mkdir(mode=0o700)
        self.state = self.root / "state"
        self.state.mkdir(mode=0o700)
        self.config = self.root / "firstmate-config"
        self.config.mkdir(mode=0o700)
        self.backend = self.config / "backend"
        self.backend.write_text("tmux\n", encoding="utf-8")
        self.backend.chmod(0o600)
        self.ps_binary = self.root / "fake-ps"
        self.ps_binary.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.ps_binary.chmod(0o755)
        self.routing = self.config / "account-routing-mode"
        self.quiet_paths = tuple(
            self.state / name for name in ("leases", "sessions", "locks")
        )
        for path in self.quiet_paths:
            path.mkdir(mode=0o700)

        self.link_operations: list[dict[str, object]] = []
        self.links: list[Path] = []
        self.sealed_releases: list[Path] = []
        for ordinal, name in enumerate(("quota", "agent-fleet"), start=1):
            product = self.root / name
            releases = product / "releases"
            releases.mkdir(parents=True)
            sealed = releases / "0.1.5-sealed"
            sealed.mkdir()
            sentinel = sealed / "sentinel"
            sentinel.write_text(f"sealed-{name}-{ordinal}\n", encoding="utf-8")
            sentinel.chmod(0o644)
            runtime = sealed / "runtime"
            runtime.write_text(f"runtime-{ordinal}\n", encoding="utf-8")
            runtime.chmod(0o755)
            if name == "agent-fleet":
                operator = sealed / "operator"
                operator.mkdir()
                sealed_front = operator / "agent-fleet"
                sealed_front.write_bytes(b"sealed-native-front-door\n")
                sealed_front.chmod(0o555)
                self.sealed_front = sealed_front
            current = product / "current"
            initial_target = "releases/untrusted-legacy"
            sealed_target = "releases/0.1.5-sealed"
            os.symlink(initial_target, current)
            self.links.append(current)
            self.sealed_releases.append(sealed)
            self.link_operations.append(
                {
                    "name": f"{name}-current",
                    "path": str(current),
                    "initial_target": initial_target,
                    "sealed_target": sealed_target,
                    "sealed_release": str(sealed),
                    "sealed_proofs": [
                        transaction.compute_release_proof(sealed, "sentinel")
                    ],
                    "sealed_tree_sha256": transaction.compute_release_tree_sha256(
                        sealed
                    ),
                }
            )

        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.front_door = self.bin / "agent-fleet"
        self.initial_front_target = "../agent-fleet/current/bin/agent-fleet"
        os.symlink(self.initial_front_target, self.front_door)

        self.initial_source = self.root / "registry.initial.toml"
        self.sealed_source = self.root / "registry.sealed.toml"
        self.registry = self.root / "accounts.toml"
        self._write_registry(self.initial_source, "untrusted/quota.js")
        self._write_registry(self.sealed_source, "sealed/quota.js")
        self.registry.write_bytes(self.initial_source.read_bytes())
        self.registry.chmod(0o600)
        self.lock = self.private / "sealed-adoption.lock"
        self.journal = self.private / "sealed-adoption.journal.json"
        self.lock.write_bytes(b"")
        self.lock.chmod(0o600)
        self.manifest_path = self.base / "sealed-adoption.manifest.json"
        self.manifest_data: dict[str, object] = {
            "schema_version": 1,
            "transaction_id": "sealed-adoption-fixture",
            "apply_opt_in": apply_opt_in,
            "allowed_roots": [str(self.root)],
            "lock_path": str(self.lock),
            "journal_path": str(self.journal),
            "quiet_point": {
                "profile_ids": list(PROFILE_IDS),
                "worker_profile_ids": list(WORKER_PROFILE_IDS),
                "never_enroll_profile_ids": list(RESERVE_PROFILE_IDS),
                "routing_absent_paths": [str(self.routing)],
                "backend_path": str(self.backend),
                "backend_sha256": sha256(self.backend),
                "state_quiet_paths": [str(path) for path in self.quiet_paths],
                "forbidden_process_tokens": [
                    str(self.root / "bin" / "agent-fleet"),
                    str(self.root / "agent-fleet" / "releases") + "/",
                    str(self.root / "quota") + "/",
                ],
                "ps_binary": str(self.ps_binary),
                "ps_binary_sha256": sha256(self.ps_binary),
            },
            "link_operations": self.link_operations,
            "front_door_operation": {
                "name": "agent-fleet-front-door",
                "path": str(self.front_door),
                "initial_target": self.initial_front_target,
                "sealed_source": str(self.sealed_front),
                "sealed_sha256": sha256(self.sealed_front),
                "mode": "0555",
            },
            "registry_operation": {
                "name": "accounts-registry",
                "path": str(self.registry),
                "initial_source": str(self.initial_source),
                "sealed_source": str(self.sealed_source),
                "initial_sha256": sha256(self.initial_source),
                "sealed_sha256": sha256(self.sealed_source),
                "mode": "0600",
            },
        }
        self.write_manifest()

    def _write_registry(self, path: Path, quota: str) -> None:
        lines = ["version = 1", "", "[settings]", f"quota_binary = {json.dumps(quota)}"]
        for profile in PROFILE_IDS:
            policy = "desktop_shared" if profile in RESERVE_PROFILE_IDS else "worker"
            lines.extend(
                (
                    "",
                    f"[profiles.{json.dumps(profile)}]",
                    "enabled = false",
                    f"safety_policy = {json.dumps(policy)}",
                )
            )
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        path.chmod(0o600)

    def write_manifest(self) -> None:
        self.manifest_path.write_text(
            json.dumps(self.manifest_data, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        self.manifest_path.chmod(0o600)

    def load(self) -> adoption.Manifest:
        return adoption.load_manifest(self.manifest_path)

    def assert_initial(self, testcase: unittest.TestCase) -> None:
        manifest = self.load()
        states, prefix = adoption.observe(manifest)
        testcase.assertEqual(states, ["initial", "initial", "initial", "initial"])
        testcase.assertEqual(prefix, 0)
        testcase.assertEqual(
            [os.readlink(path) for path in self.links],
            ["releases/untrusted-legacy", "releases/untrusted-legacy"],
        )
        testcase.assertEqual(self.registry.read_bytes(), self.initial_source.read_bytes())
        testcase.assertTrue(self.front_door.is_symlink())
        testcase.assertEqual(os.readlink(self.front_door), self.initial_front_target)

    def assert_sealed(self, testcase: unittest.TestCase) -> None:
        manifest = self.load()
        states, prefix = adoption.observe(manifest)
        testcase.assertEqual(states, ["sealed", "sealed", "sealed", "sealed"])
        testcase.assertEqual(prefix, 4)
        testcase.assertEqual(
            [os.readlink(path) for path in self.links],
            ["releases/0.1.5-sealed", "releases/0.1.5-sealed"],
        )
        testcase.assertEqual(self.registry.read_bytes(), self.sealed_source.read_bytes())
        testcase.assertTrue(self.front_door.is_file())
        testcase.assertFalse(self.front_door.is_symlink())
        testcase.assertEqual(self.front_door.read_bytes(), self.sealed_front.read_bytes())
        testcase.assertEqual(self.front_door.stat().st_nlink, 1)
        testcase.assertEqual(self.front_door.stat().st_mode & 0o7777, 0o555)

    def close(self) -> None:
        self._temporary.cleanup()


class BridgeSealedAdoptionTests(unittest.TestCase):
    def test_front_door_rollback_restores_exact_legacy_symlink(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        with self.assertRaises(adoption.InjectedFailure):
            adoption.apply(
                fixture.load(),
                adoption.BoundaryController(
                    "after_replace:forward:agent-fleet-front-door"
                ),
            )
        self.assertTrue(fixture.front_door.is_file())
        self.assertFalse(fixture.front_door.is_symlink())
        adoption.recover(fixture.load())
        self.assertTrue(fixture.front_door.is_symlink())
        self.assertEqual(
            os.readlink(fixture.front_door), fixture.initial_front_target
        )

    def test_front_door_refuses_unknown_symlink_and_hardlinked_regular_file(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        fixture.front_door.unlink()
        os.symlink(str(fixture.root / "unknown"), fixture.front_door)
        with self.assertRaisesRegex(adoption.AdoptionError, "unknown initial target"):
            adoption.observe(fixture.load())
        fixture.front_door.unlink()
        os.symlink(fixture.initial_front_target, fixture.front_door)
        adoption.apply(fixture.load())
        alias = fixture.root / "front-door-hardlink"
        os.link(fixture.front_door, alias)
        with self.assertRaisesRegex(adoption.AdoptionError, "exactly one hard link"):
            adoption.observe(fixture.load())

    def test_manifest_home_safety_ignores_hostile_ambient_home(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        with mock.patch.dict(os.environ, {"HOME": str(fixture.root)}):
            loaded = fixture.load()
        self.assertEqual(loaded.allowed_roots, (fixture.root,))

    def test_adopts_both_runtimes_and_registry_then_is_irreversible(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        manifest = fixture.load()
        planned = adoption.plan(manifest)
        self.assertEqual(planned["sealed_prefix"], 0)

        result = adoption.apply(manifest)
        again = adoption.apply(fixture.load())

        self.assertTrue(result["sealed"])
        self.assertTrue(again["converged"])
        fixture.assert_sealed(self)

    def test_quiet_point_structurally_excludes_reserves_from_worker_policy(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        payload = fixture.initial_source.read_text(encoding="utf-8").replace(
            'safety_policy = "desktop_shared"',
            'safety_policy = "worker"',
            1,
        )
        fixture.initial_source.write_text(payload, encoding="utf-8")
        fixture.initial_source.chmod(0o600)
        fixture.registry.write_bytes(fixture.initial_source.read_bytes())
        fixture.registry.chmod(0o600)
        registry_operation = fixture.manifest_data["registry_operation"]
        registry_operation["initial_sha256"] = sha256(fixture.initial_source)
        fixture.write_manifest()

        with self.assertRaisesRegex(adoption.AdoptionError, "safety_policy"):
            adoption.plan(fixture.load())
        with self.assertRaisesRegex(adoption.AdoptionError, "safety_policy"):
            adoption.recover(fixture.load())

    def test_initial_targets_may_be_dangling_and_are_never_read(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        for link in fixture.links:
            self.assertFalse(link.exists())
            self.assertTrue(os.path.lexists(link))

        adoption.apply(fixture.load())

        fixture.assert_sealed(self)

    def test_quiet_point_refuses_routing_backend_and_enabled_profile(self) -> None:
        routing_fixture = Fixture()
        self.addCleanup(routing_fixture.close)
        routing_fixture.routing.write_text("observe\n", encoding="utf-8")
        with self.assertRaisesRegex(adoption.AdoptionError, "routing enable path"):
            adoption.plan(routing_fixture.load())

        backend_fixture = Fixture()
        self.addCleanup(backend_fixture.close)
        backend_fixture.backend.write_text("herdr\n", encoding="utf-8")
        with self.assertRaisesRegex(adoption.AdoptionError, "SHA-256 changed"):
            adoption.plan(backend_fixture.load())

        profile_fixture = Fixture()
        self.addCleanup(profile_fixture.close)
        profile_fixture.registry.write_text(
            profile_fixture.registry.read_text(encoding="utf-8").replace(
                "enabled = false", "enabled = true", 1
            ),
            encoding="utf-8",
        )
        profile_fixture.registry.chmod(0o600)
        profile_fixture.manifest_data["registry_operation"][
            "initial_sha256"
        ] = sha256(profile_fixture.registry)
        profile_fixture.initial_source.write_bytes(profile_fixture.registry.read_bytes())
        profile_fixture.initial_source.chmod(0o600)
        profile_fixture.write_manifest()
        with self.assertRaisesRegex(adoption.AdoptionError, "enabled profile"):
            adoption.plan(profile_fixture.load())

    def test_quiet_point_refuses_leases_sessions_and_locks(self) -> None:
        for index, state_name in enumerate(("lease.json", "session.json", "registry.lock")):
            with self.subTest(state=state_name):
                fixture = Fixture()
                try:
                    (fixture.quiet_paths[index] / state_name).write_text(
                        "busy\n", encoding="utf-8"
                    )
                    with self.assertRaisesRegex(adoption.AdoptionError, "not empty"):
                        adoption.plan(fixture.load())
                finally:
                    fixture.close()

    def test_quiet_point_refuses_matching_fleet_process(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        fixture.ps_binary.write_text(
            "#!/bin/sh\nprintf '123 /bin/sleep 30\\n'\n",
            encoding="utf-8",
        )
        fixture.ps_binary.chmod(0o755)
        fixture.manifest_data["quiet_point"]["forbidden_process_tokens"] = [
            "/bin/sleep"
        ]
        fixture.manifest_data["quiet_point"]["ps_binary_sha256"] = sha256(
            fixture.ps_binary
        )
        fixture.write_manifest()

        with self.assertRaisesRegex(adoption.AdoptionError, "process token is active"):
            adoption.plan(fixture.load())

    def test_refuses_unknown_link_and_corrupted_sealed_tree(self) -> None:
        unknown_fixture = Fixture()
        self.addCleanup(unknown_fixture.close)
        os.unlink(unknown_fixture.links[0])
        os.symlink("releases/unknown", unknown_fixture.links[0])
        with self.assertRaisesRegex(adoption.AdoptionError, "unknown raw target"):
            adoption.plan(unknown_fixture.load())

        corrupt_fixture = Fixture()
        self.addCleanup(corrupt_fixture.close)
        (corrupt_fixture.sealed_releases[0] / "runtime").write_text(
            "corrupted\n", encoding="utf-8"
        )
        with self.assertRaisesRegex(adoption.AdoptionError, "sealed tree SHA-256"):
            corrupt_fixture.load()

    def test_refuses_external_hardlink_in_sealed_tree(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        os.link(
            fixture.sealed_releases[0] / "sentinel",
            fixture.root / "external-hardlink",
        )

        with self.assertRaisesRegex(adoption.AdoptionError, "exactly one hard link"):
            fixture.load()

    def test_apply_opt_in_is_required(self) -> None:
        fixture = Fixture(apply_opt_in=False)
        self.addCleanup(fixture.close)

        with self.assertRaisesRegex(adoption.AdoptionError, "apply_opt_in is false"):
            adoption.apply(fixture.load())
        fixture.assert_initial(self)

    def test_ordinary_failure_after_mutation_recovers_backward(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)

        class FailAfterFirstReplace(adoption.BoundaryController):
            def hit(self, label: str) -> None:
                super().hit(label)
                if label == "after_replace:forward:quota-current":
                    raise adoption.AdoptionError("ordinary injected failure")

        with self.assertRaisesRegex(adoption.AdoptionError, "ordinary injected failure"):
            adoption.apply(fixture.load(), FailAfterFirstReplace())
        fixture.assert_initial(self)

    def test_recovery_refuses_if_quiet_point_was_lost(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        with self.assertRaises(adoption.InjectedFailure):
            adoption.apply(
                fixture.load(),
                adoption.BoundaryController(
                    "after_replace:forward:agent-fleet-current"
                ),
            )
        lease = fixture.quiet_paths[0] / "started-after-crash.json"
        lease.write_text("busy\n", encoding="utf-8")

        with self.assertRaisesRegex(adoption.AdoptionError, "not empty"):
            adoption.recover(fixture.load())
        states, prefix = adoption.observe(fixture.load())
        self.assertEqual(states, ["sealed", "sealed", "initial", "initial"])
        self.assertEqual(prefix, 2)

        lease.unlink()
        adoption.recover(fixture.load())
        fixture.assert_initial(self)

    def test_registry_path_substitution_during_quiet_read_is_refused(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        manifest = fixture.load()
        original = transaction._require_stable_regular_fd
        replaced = False

        def swap_after_fd_validation(
            fd: int,
            before: os.stat_result,
            path: Path,
            label: str,
        ) -> None:
            nonlocal replaced
            original(fd, before, path, label)
            if label == "live adoption registry" and not replaced:
                replaced = True
                saved = fixture.root / "registry-before-swap.toml"
                malicious = fixture.root / "registry-malicious.toml"
                malicious.write_text(
                    fixture.registry.read_text(encoding="utf-8").replace(
                        "enabled = false", "enabled = true", 1
                    ),
                    encoding="utf-8",
                )
                malicious.chmod(0o600)
                os.replace(fixture.registry, saved)
                os.replace(malicious, fixture.registry)

        with mock.patch.object(
            transaction,
            "_require_stable_regular_fd",
            side_effect=swap_after_fd_validation,
        ):
            with self.assertRaisesRegex(adoption.AdoptionError, "path changed while reading"):
                adoption.plan(manifest)

    def test_front_door_change_after_quiet_point_is_not_overwritten(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        manifest = fixture.load()
        operation = manifest.front_door_operation
        temporary = transaction._temp_path(
            operation.path, manifest.transaction_id, "forward"
        )
        original_quiet = adoption._validate_quiet_point
        changed = False

        def quiet_then_change(value: adoption.Manifest) -> None:
            nonlocal changed
            original_quiet(value)
            if os.path.lexists(temporary) and not changed:
                changed = True
                racer = fixture.front_door.with_name(".agent-fleet.racer")
                os.symlink("foreign-front-door", racer)
                os.replace(racer, fixture.front_door)

        with mock.patch.object(
            adoption, "_validate_quiet_point", side_effect=quiet_then_change
        ):
            with self.assertRaisesRegex(
                adoption.AdoptionError, "unknown|changed before replacement"
            ):
                adoption.apply(manifest)
        self.assertEqual(os.readlink(fixture.front_door), "foreign-front-door")

    def test_registry_change_after_quiet_point_is_not_overwritten(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        manifest = fixture.load()
        operation = manifest.registry_operation
        temporary = transaction._temp_path(
            operation.path, manifest.transaction_id, "forward"
        )
        original_quiet = adoption._validate_quiet_point
        changed = False
        racer = b'version = 1\nmode = "racer"\n'

        def quiet_then_change(value: adoption.Manifest) -> None:
            nonlocal changed
            original_quiet(value)
            if os.path.lexists(temporary) and not changed:
                changed = True
                fixture.registry.write_bytes(racer)
                fixture.registry.chmod(0o600)

        with mock.patch.object(
            adoption, "_validate_quiet_point", side_effect=quiet_then_change
        ):
            with self.assertRaisesRegex(
                adoption.AdoptionError, "unknown|changed before replacement"
            ):
                adoption.apply(manifest)
        self.assertEqual(fixture.registry.read_bytes(), racer)

    def test_link_change_at_exchange_syscall_is_swapped_back_and_preserved(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        foreign_target = "releases/foreign-at-syscall"

        class ChangeAtExchange(adoption.BoundaryController):
            def hit(self, label: str) -> None:
                super().hit(label)
                if label == "immediately_before_exchange:forward:quota-current":
                    temp = fixture.links[0].with_name(".foreign-link.tmp")
                    os.symlink(foreign_target, temp)
                    os.replace(temp, fixture.links[0])

        with self.assertRaisesRegex(adoption.AdoptionError, "displaced live state"):
            adoption.apply(fixture.load(), ChangeAtExchange())
        self.assertEqual(os.readlink(fixture.links[0]), foreign_target)

    def test_state_directory_substitution_during_scan_is_refused(self) -> None:
        fixture = Fixture()
        self.addCleanup(fixture.close)
        manifest = fixture.load()
        original_listdir = os.listdir
        swapped = False

        def swap_scanned_directory(path: object) -> list[str]:
            nonlocal swapped
            names = original_listdir(path)
            if isinstance(path, int) and not swapped:
                swapped = True
                original = fixture.quiet_paths[0]
                saved = fixture.state / "leases-before-swap"
                replacement = fixture.state / "leases-replacement"
                os.rename(original, saved)
                replacement.mkdir(mode=0o700)
                os.rename(replacement, original)
            return names

        with mock.patch.object(os, "listdir", side_effect=swap_scanned_directory):
            with self.assertRaisesRegex(
                adoption.AdoptionError, "(changed|substituted) while scanning"
            ):
                adoption.plan(manifest)

    def test_every_forward_boundary_is_sealed_or_recovers_backward(self) -> None:
        discovery = Fixture()
        self.addCleanup(discovery.close)
        recorder = adoption.BoundaryController()
        adoption.apply(discovery.load(), recorder)
        boundaries = tuple(dict.fromkeys(recorder.seen))
        self.assertEqual(len(boundaries), 52)

        for boundary in boundaries:
            with self.subTest(boundary=boundary):
                fixture = Fixture()
                try:
                    with self.assertRaises(adoption.InjectedFailure):
                        adoption.apply(
                            fixture.load(), adoption.BoundaryController(boundary)
                        )
                    journal = adoption._load_journal(fixture.load())
                    if journal and journal["sealed"]:
                        fixture.assert_sealed(self)
                    else:
                        adoption.recover(fixture.load())
                        fixture.assert_initial(self)
                        adoption.apply(fixture.load())
                        fixture.assert_sealed(self)
                finally:
                    fixture.close()

    def test_every_recovery_boundary_restarts_to_initial(self) -> None:
        discovery = Fixture()
        self.addCleanup(discovery.close)
        with self.assertRaises(adoption.InjectedFailure):
            adoption.apply(
                discovery.load(),
                adoption.BoundaryController(
                    "after_replace:forward:agent-fleet-current"
                ),
            )
        recorder = adoption.BoundaryController()
        adoption.recover(discovery.load(), recorder)
        boundaries = tuple(dict.fromkeys(recorder.seen))
        self.assertEqual(len(boundaries), 32)

        for boundary in boundaries:
            with self.subTest(boundary=boundary):
                fixture = Fixture()
                try:
                    with self.assertRaises(adoption.InjectedFailure):
                        adoption.apply(
                            fixture.load(),
                            adoption.BoundaryController(
                                "after_replace:forward:agent-fleet-current"
                            ),
                        )
                    with self.assertRaises(adoption.InjectedFailure):
                        adoption.recover(
                            fixture.load(), adoption.BoundaryController(boundary)
                        )
                    adoption.recover(fixture.load())
                    fixture.assert_initial(self)
                finally:
                    fixture.close()


if __name__ == "__main__":
    unittest.main()
