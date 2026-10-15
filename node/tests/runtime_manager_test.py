#!/usr/bin/env python3
"""Unit acceptance of Docker orchestration boundaries; never invokes Docker."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

sys.dont_write_bytecode = True
NODE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(NODE))
spec = importlib.util.spec_from_file_location("node_runtime_manager_under_test", NODE / "runtime_manager.py")
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)
rb = manager.rb
IMAGE = "sha256:" + "a" * 64
OTHER_IMAGE = "sha256:" + "b" * 64
CID = "c" * 64
BOOT = "11111111-2222-3333-4444-555555555555"
TICKS = "123456"
STARTED = "2026-10-15T01:02:03.000000000Z"


def encoded(value):
    return json.dumps(value, separators=(",", ":")).encode()


class FakeDocker:
    """Only approved read/probe/stop commands; an unknown command fails the test."""
    def __init__(self, root, *, running=True):
        self.root = root
        self.commands = []
        self.image = {"Id": IMAGE, "RepoDigests": [], "Config": {"Env": ["PATH=/usr/local/bin:/usr/bin:/bin"]}}
        self.compose = {"name": "isolated", "services": {"tx-node": {
            "image": "ghcr.io/example/synthetic-node:test", "container_name": "fixture-node",
            "restart": "unless-stopped", "network_mode": "host", "command": ["-c", manager.CONFIG],
            "volumes": [{"type": "bind", "source": src, "target": dst, "read_only": not rw,
                         "bind": {"create_host_path": True}}
                        for dst, (src, rw) in manager.expected_mounts(root).items()]}}}
        self.container = {"Id": CID, "Name": "/fixture-node", "Image": IMAGE, "RestartCount": 0,
            "Config": {"Entrypoint": ["tx-node"], "Cmd": ["-c", manager.CONFIG],
                "Env": list(self.image["Config"]["Env"]), "Labels": {
                    "com.docker.compose.service": "tx-node", "com.docker.compose.project.working_dir": str(root),
                    "com.docker.compose.project.config_files": str(root / "docker-compose.yml"),
                    "com.docker.compose.oneoff": "False"}},
            "HostConfig": {"NetworkMode": "host", "Tmpfs": {}},
            "Mounts": [{"Type": "bind", "Source": src, "Destination": dst, "RW": rw}
                       for dst, (src, rw) in manager.expected_mounts(root).items()],
            "State": {"Running": running, "Status": "running" if running else "exited", "StartedAt": STARTED,
                      "Paused": False, "Restarting": False, "Dead": False, "ExitCode": 0,
                      "OOMKilled": False, "Error": ""}}
        self.layout = {"format": "txnode.backup-layout/v1", "data_root": manager.ROOT,
                       "checkpoint_receipt": ".runtime-checkpoint.json", "targets": [{"node_id": 42}]}
        self.capabilities = {"protocol_version": 1, "runtime": "tx-node", "capabilities": ["node_runtime_checkpoint_v1"]}
        self.stay_running = False
        self.restart_after_signal = False
        self.daemon_down = False
        self.missing = False

    def __call__(self, args, **kwargs):
        args = list(args)
        self.commands.append(args)
        if args[:2] != ["docker", "info"] and self.daemon_down:
            raise AssertionError("orchestrator continued after Docker daemon failure")
        if args[:2] == ["docker", "info"]:
            return subprocess.CompletedProcess(args, 1 if self.daemon_down else 0, b"27.0\n")
        if args[:2] == ["docker", "compose"]:
            body = encoded(self.compose)
        elif args[:3] == ["docker", "image", "inspect"]:
            body = encoded([self.image])
        elif args[:2] == ["docker", "inspect"]:
            body = encoded([self.container])
        elif args[:2] == ["docker", "ps"]:
            body = b"" if self.missing else b"fixture-node\n"
        elif args[:2] == ["docker", "run"]:
            body = encoded(self.capabilities if "--capabilities" in args else self.layout)
        elif args[:2] == ["docker", "exec"]:
            body = ("1 (tx-node) " + " ".join(["S"] + ["0"] * 18 + [TICKS]) + "\n" + BOOT + "\n").encode()
        elif args[:2] == ["docker", "update"]:
            body = b""
        elif args[:2] == ["docker", "kill"]:
            if not self.stay_running:
                self.container["State"]["Running"] = False
                self.container["State"]["Status"] = "exited"
            if self.restart_after_signal:
                self.container["State"]["StartedAt"] = "2026-10-15T01:02:04.000000000Z"
                self.container["RestartCount"] += 1
            body = b""
        else:
            raise AssertionError("unexpected Docker invocation: " + repr(args))
        return subprocess.CompletedProcess(args, 0, body)

    def mutations(self):
        return [x for x in self.commands if len(x) > 1 and x[1] in {"update", "kill", "stop", "start", "restart", "rm"}]


class RuntimeManagerBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="node-manager-unit-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "node"
        self.root.mkdir()
        for name in ("data", "remote-update"):
            (self.root / name).mkdir()
        (self.root / "config.yml").write_text("synthetic private config\n")
        (self.root / "docker-compose.yml").write_text("synthetic compose sentinel\n")
        self.backend = FakeDocker(self.root)
        self.args = SimpleNamespace(app_name="fixture-node", output=str(Path(self.temp.name) / "bundle.tar"), timeout=1, archive="synthetic-backup.tar")
        self.runner = mock.patch.object(manager.subprocess, "run", side_effect=self.backend)
        self.runner.start()
        self.addCleanup(self.runner.stop)

    def refused_backup_without_effects(self, code):
        old = (self.root / "docker-compose.yml").read_bytes()
        with mock.patch.object(manager, "atomic_compose") as publish, mock.patch.object(rb, "create") as create:
            with self.assertRaisesRegex(rb.Refusal, "^" + code + "$"):
                manager.backup(self.args, self.root)
            publish.assert_not_called()
            create.assert_not_called()
        self.assertEqual(self.backend.mutations(), [])
        self.assertEqual((self.root / "docker-compose.yml").read_bytes(), old)
        self.assertFalse(Path(self.args.output).exists())

    def test_foreign_container_labels_refused_before_mutation(self):
        for field, value in (("com.docker.compose.service", "other"),
                             ("com.docker.compose.project.working_dir", str(self.root.parent / "foreign")),
                             ("com.docker.compose.project.config_files", "/tmp/foreign.yml"),
                             ("com.docker.compose.oneoff", "True")):
            with self.subTest(field=field):
                self.backend = FakeDocker(self.root)
                self.runner.stop()
                self.runner = mock.patch.object(manager.subprocess, "run", side_effect=self.backend)
                self.runner.start()
                self.addCleanup(self.runner.stop)
                self.backend.container["Config"]["Labels"][field] = value
                self.refused_backup_without_effects("FOREIGN_CONTAINER")

    def test_container_name_cannot_substitute_for_ownership(self):
        self.backend.container["Config"]["Labels"] = {}
        self.refused_backup_without_effects("FOREIGN_CONTAINER")

    def test_configuration_environment_override_is_refused(self):
        self.backend.container["Config"]["Env"].append("API_KEY=synthetic-override")
        self.refused_backup_without_effects("CONTAINER_ENVIRONMENT_UNSUPPORTED")

    def test_entrypoint_and_command_override_are_refused(self):
        for field, value in (("Entrypoint", ["sh", "-c"]), ("Cmd", ["-c", "/elsewhere/config.yml"])):
            with self.subTest(field=field):
                previous = self.backend.container["Config"][field]
                self.backend.container["Config"][field] = value
                self.refused_backup_without_effects("CONTAINER_COMMAND_UNSUPPORTED")
                self.backend.container["Config"][field] = previous

    def test_exact_image_id_is_required(self):
        self.backend.image["Id"] = OTHER_IMAGE
        self.refused_backup_without_effects("IMMUTABLE_IMAGE_UNAVAILABLE")

    def test_noncanonical_mounts_are_refused(self):
        original = copy.deepcopy(self.backend.container["Mounts"])
        changes = [lambda v: v.append({"Type": "bind", "Source": "/tmp/extra", "Destination": manager.ROOT + "/hidden", "RW": True}),
                   lambda v: v.append(copy.deepcopy(v[0])),
                   lambda v: v[0].update(Source=str(self.root.parent / "foreign")),
                   lambda v: v[1].update(RW=True),
                   lambda v: v[0].update(Type="volume")]
        for index, change in enumerate(changes):
            with self.subTest(case=index):
                self.backend.container["Mounts"] = copy.deepcopy(original)
                change(self.backend.container["Mounts"])
                self.refused_backup_without_effects("CONTAINER_MOUNTS_UNSUPPORTED")
        self.backend.container["Mounts"] = original

    def test_normalized_null_entrypoint_preserves_image_entrypoint(self):
        # Docker Compose v2 config emits entrypoint:null for an inherited image
        # entrypoint. Runtime inspection still verifies the actual entrypoint.
        self.backend.compose["services"]["tx-node"]["entrypoint"] = None
        service = manager.validate_compose(self.backend.compose, self.root, "fixture-node")
        self.assertIs(service, self.backend.compose["services"]["tx-node"])
        self.assertIsNone(service["entrypoint"])
        self.assertEqual(self.backend.commands, [])

    def test_explicit_compose_entrypoint_override_is_refused_before_probe(self):
        self.backend.compose["services"]["tx-node"]["entrypoint"] = ["sh", "-c"]
        self.refused_backup_without_effects("COMPOSE_UNSUPPORTED")
        self.assertFalse(any(x[:2] == ["docker", "inspect"] for x in self.backend.commands))

    def test_unsupported_compose_service_refused_before_container_probe(self):
        self.backend.compose["services"]["other"] = {"image": "synthetic"}
        self.refused_backup_without_effects("COMPOSE_UNSUPPORTED")
        self.assertFalse(any(x[:2] == ["docker", "inspect"] for x in self.backend.commands))

    def test_unsupported_compose_mount_refused_before_container_probe(self):
        self.backend.compose["services"]["tx-node"]["volumes"][0]["source"] = "/tmp/foreign"
        self.refused_backup_without_effects("COMPOSE_MOUNTS_UNSUPPORTED")

    def test_unavailable_daemon_does_not_mean_missing_container(self):
        self.backend.daemon_down = True
        with self.assertRaisesRegex(rb.Refusal, "DOCKER_COMMAND_FAILED"):
            manager.inspect_container("fixture-node", missing=True)
        self.assertEqual(len(self.backend.commands), 1)

    def test_probe_uses_immutable_image_and_neither_network_nor_data_mount(self):
        layout = manager.probe_layout(IMAGE, self.root / "config.yml")
        self.assertEqual(layout, self.backend.layout)
        for args in self.backend.commands:
            self.assertEqual(args[:2], ["docker", "run"])
            self.assertIn(IMAGE, args)
            self.assertEqual(args[args.index("--network") + 1], "none")
            self.assertIn("--read-only", args)
            self.assertNotIn(str(self.root / "data"), " ".join(args))
        self.assertNotIn("--mount", self.backend.commands[0])

    def receipt(self, **changes):
        # This is the exact public receipt schema emitted by checkpoint_linux.go.
        value = {"format": "txnode.runtime-checkpoint/v1", "pid": 1, "boot_id": BOOT,
                 "process_start_ticks": TICKS, "completed_at": "2026-10-15T01:02:05Z"}
        value.update(changes)
        return encoded(value)

    def call_checkpoint(self, receipt):
        with mock.patch.object(manager, "atomic_compose"), mock.patch.object(rb, "read_regular", return_value=(receipt, None)):
            return manager.checkpoint(self.root, copy.deepcopy(self.backend.container), copy.deepcopy(self.backend.compose), 1)

    def test_current_process_receipt_is_accepted(self):
        capture = self.call_checkpoint(self.receipt())
        self.assertEqual(capture["kind"], "runtime_checkpoint")
        self.assertEqual(capture["container_id"], CID)
        self.assertEqual(capture["started_at"], STARTED)
        mutations = self.backend.mutations()
        self.assertEqual(mutations[0], ["docker", "update", "--restart=no", CID])
        self.assertEqual(mutations[1], ["docker", "kill", "--signal=SIGUSR1", CID])
        self.assertTrue(all(x[-1] == CID for x in mutations))

    def test_stale_process_receipt_is_refused(self):
        with self.assertRaisesRegex(rb.Refusal, "CHECKPOINT_RECEIPT_INVALID"):
            self.call_checkpoint(self.receipt(process_start_ticks="999999"))

    def test_restarted_container_cannot_certify_checkpoint(self):
        self.backend.restart_after_signal = True
        with self.assertRaisesRegex(rb.Refusal, "CHECKPOINT_CONTAINER_RESTARTED"):
            self.call_checkpoint(self.receipt())

    def test_oom_or_nonzero_exit_cannot_certify_checkpoint(self):
        for key, value in (("OOMKilled", True), ("ExitCode", 137)):
            with self.subTest(field=key):
                self.backend.container["State"][key] = value
                with self.assertRaisesRegex(rb.Refusal, "CHECKPOINT_PROCESS_FAILED"):
                    self.call_checkpoint(self.receipt())
                self.backend.container["State"][key] = False if key == "OOMKilled" else 0

    def test_timeout_never_sends_force_kill_or_creates_bundle(self):
        self.backend.stay_running = True
        with mock.patch.object(manager.time, "monotonic", side_effect=[0, 2]):
            with self.assertRaisesRegex(rb.Refusal, "CHECKPOINT_TIMEOUT_RESTART_DISABLED"):
                self.call_checkpoint(self.receipt())
        mutations = self.backend.mutations()
        self.assertEqual([x[1] for x in mutations], ["update", "kill"])
        self.assertEqual(mutations[1][2], "--signal=SIGUSR1")
        self.assertFalse(Path(self.args.output).exists())

    def test_running_target_restore_is_refused_before_mutation(self):
        manifest = {"install_dir": str(self.root), "image_id": IMAGE}
        with mock.patch.object(rb, "load_archive", return_value=(manifest, {})), mock.patch.object(rb, "restore") as restore:
            with self.assertRaisesRegex(rb.Refusal, "RESTORE_STOPPED_REQUIRED"):
                manager.restore(self.args, self.root)
            restore.assert_not_called()
        self.assertEqual(self.backend.mutations(), [])

    def test_invalid_restore_layout_leaves_existing_container_policy_untouched(self):
        self.backend.container["State"].update(Running=False, Status="exited")
        manifest = {"install_dir": str(self.root), "image_id": IMAGE, "layout": {"different": True}}
        with mock.patch.object(rb, "load_archive", return_value=(manifest, {"config.yml": b"synthetic"})), mock.patch.object(rb, "restore") as restore:
            with self.assertRaisesRegex(rb.Refusal, "RESTORE_LAYOUT_MISMATCH"):
                manager.restore(self.args, self.root)
            restore.assert_not_called()
        self.assertEqual(self.backend.mutations(), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
