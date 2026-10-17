#!/usr/bin/env python3
"""Durable orchestration regression tests; actual Core/image proof runs in Core CI."""
import importlib.util
import json
import tempfile
import unittest
from types import SimpleNamespace
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("native_runtime", Path(__file__).with_name("native-runtime.py"))
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
OLD, NEW = "sha256:" + "1" * 64, "sha256:" + "2" * 64


class Interrupted(Exception):
    pass


class Backend:
    def __init__(self):
        self.calls, self.image, self.running, self.backups = [], OLD, True, 0

    def pin(self, image):
        native.require(image in (OLD, NEW), "IMAGE_ID_INVALID")
        return image

    def container(self, healthy=False):
        native.require(not healthy or self.running, "CORE_NOT_HEALTHY")
        return {"id": "container-original" if self.image == OLD else "container-target", "image": self.image, "running": self.running}

    def compose(self, *args):
        self.calls.append(("compose", args))
        if args[0] == "stop":
            self.running = False
        if args[0] == "up":
            self.image, self.running = NEW, True

    def artisan(self, *args):
        self.calls.append(("artisan", args))
        return "Ran" if args[0] == "migrate:status" else ""

    def report(self, *args, running=False):
        self.calls.append(("report", args, running))
        if args[:2] == ("core:installation", "runtime"):
            return {"ready": True, "authority_epoch": "2", "composition_fingerprint": "old" if self.image == OLD else "new"}
        if args[:2] == ("core:installation", "preflight"):
            return {"ready_to_activate": True, "next_worker_epoch": "2", "configuration_digest": "digest", "expected_version": "1"}
        if args[:2] == ("core:module-release", "preflight"):
            return {"ready_to_adopt": True, "active_fingerprint": "old", "candidate_fingerprint": "new"}
        return {"drained": True}

    def sql(self, query):
        return "0"

    def snapshot(self):
        return "1\t0\t0\t1\t100"

    def backup(self, operation_id):
        self.backups += 1
        self.calls.append(("backup", operation_id))
        return {"operation_id": operation_id, "verified": True}

    def verify_backup(self, record):
        self.calls.append(("verify_backup", record))
        native.require(record["verified"], "BACKUP_CHECKSUM_MISMATCH")


class NativeDeploymentTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "native").mkdir()
        (self.root / "backups").mkdir()
        (self.root / ".env").write_text("TXBOARD_IMAGE=" + OLD + "\n")
        (self.root / "api.env").write_text("APP_KEY=private\nCORE_INSTALLATION_MODE=native\nCORE_CREDENTIAL_PROVIDER_ID=provider\n")
        (self.root / "compose.yaml").write_text("services: {}\n")
        for name in native.REQUIRED_FILES:
            (self.root / "native" / name).write_text("private-original")
        for name in ("module-secrets.json", "outbound-policy.json"):
            (self.root / "native" / name).write_text("{}\n")
        self.backend = Backend()

    def target(self):
        target = self.root / "target"
        target.mkdir()
        for child in (self.root / "native").iterdir():
            (target / child.name).write_bytes(child.read_bytes())
        (target / "modules.json").write_text(json.dumps({"schema": "native-module-preparation/v1", "operations": [
            {"code": "portal", "action": "update"}, {"code": "portal", "action": "enable"}]}))
        (target / "module-secrets.json").write_text('{"portal":"new-private"}\n')
        return target

    def crash(self, stage):
        def hook(current):
            if current == stage:
                raise Interrupted(stage)
        return hook

    def test_resume_each_persisted_stage_with_original_intent(self):
        for stage in native.STAGES[1:-1]:
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as folder:
                # Each case uses an independent installation and durable journal.
                original_root, original_backend = self.root, self.backend
                fresh = Path(folder)
                import shutil
                shutil.copytree(original_root, fresh, dirs_exist_ok=True)
                self.root, self.backend = fresh, Backend()
                try:
                    target = self.target()
                    with self.assertRaises(Interrupted):
                        native.Runner(fresh, self.backend, hook=self.crash(stage)).execute("update", NEW, configuration=target)
                    intent = native.Journal(fresh).load()
                    operation = intent["operation_id"]
                    self.assertEqual(stage, intent["stage"])
                    if native.STAGES.index(stage) >= native.STAGES.index("stopping"):
                        self.assertFalse(self.backend.running)
                    result = native.Runner(fresh, self.backend).execute(recover=True)
                    self.assertEqual(operation, result["operation_id"])
                    self.assertEqual("completed", result["stage"])
                    self.assertEqual(1, self.backend.backups)
                    self.assertFalse(native.Journal(fresh).guard.exists())
                    self.assertEqual("new", result["active_fingerprint"])
                    self.assertIn("new-private", (fresh / "native/module-secrets.json").read_text())
                    calls = self.backend.calls
                    first_drain = next(i for i, c in enumerate(calls) if c[0] == "report" and "drain" in c[1])
                    first_backup = next(i for i, c in enumerate(calls) if c[0] == "backup")
                    first_migrate = next(i for i, c in enumerate(calls) if c[0] == "artisan" and c[1][0] == "migrate")
                    self.assertLess(first_drain, first_backup)
                    self.assertLess(first_backup, first_migrate)
                    self.assertTrue(any(c[0] == "verify_backup" for c in calls[:first_migrate]))
                finally:
                    self.root, self.backend = original_root, original_backend

    def test_directory_rename_gap_recovers_without_active_configuration(self):
        target = self.target()
        original = native.os.rename
        def rename(source, destination):
            original(source, destination)
            if Path(destination).name == "previous-native":
                raise Interrupted("rename gap")
        with patch.object(native.os, "rename", rename), self.assertRaises(Interrupted):
            native.Runner(self.root, self.backend).execute("update", NEW, configuration=target)
        self.assertFalse((self.root / "native").exists())
        self.assertEqual("configuration_applying", native.Journal(self.root).load()["stage"])
        self.assertEqual("completed", native.Runner(self.root, self.backend).execute(recover=True)["stage"])

    def test_old_configuration_cannot_replace_committed_target(self):
        with self.assertRaises(Interrupted):
            native.Runner(self.root, self.backend, hook=self.crash("configuration_ready")).execute("update", NEW, configuration=self.target())
        intent = native.Journal(self.root).load()
        old = native.Runner(self.root, self.backend).candidate_directory(intent) / "previous-native"
        (self.root / "native/module-secrets.json").write_bytes((old / "module-secrets.json").read_bytes())
        (self.root / "native/modules.json").unlink()
        with self.assertRaisesRegex(native.NativeError, "RECOVERY_CONFIGURATION_CHANGED"):
            native.Runner(self.root, self.backend).execute(recover=True)

    def test_status_is_read_only_and_original_guard_recovers_first_write(self):
        journal = native.Journal(self.root)
        self.assertIsNone(journal.load())
        self.assertFalse(journal.folder.exists())
        with patch.object(journal, "save", side_effect=Interrupted("first intent")), self.assertRaises(Interrupted):
            native.Runner(self.root, self.backend, journal=journal).execute("update", NEW)
        operation = journal.load()["operation_id"]
        self.assertEqual(operation, native.Runner(self.root, self.backend).execute(recover=True)["operation_id"])

    def test_tampered_backup_rejects_before_another_migration(self):
        with self.assertRaises(Interrupted):
            native.Runner(self.root, self.backend, hook=self.crash("schema_applying")).execute("update", NEW)
        journal = native.Journal(self.root)
        intent = journal.load()
        intent["backup"]["verified"] = False
        journal.save(intent, intent["stage"])
        self.backend.calls.clear()
        with self.assertRaisesRegex(native.NativeError, "BACKUP_CHECKSUM_MISMATCH"):
            native.Runner(self.root, self.backend).execute(recover=True)
        self.assertFalse(any(c[0] == "artisan" for c in self.backend.calls))

    def test_completion_receipt_before_guard_removal_is_recoverable(self):
        original = Path.unlink
        def unlink(path, *args, **kwargs):
            if path == self.root / ".upgrade-in-progress":
                raise Interrupted("completed receipt, retained guard")
            return original(path, *args, **kwargs)
        with patch.object(Path, "unlink", unlink), self.assertRaises(Interrupted):
            native.Runner(self.root, self.backend).execute("update", NEW)
        intent = native.Journal(self.root).load()
        self.assertEqual("completed", intent["stage"])
        self.assertTrue(self.backend.running)
        result = native.Runner(self.root, self.backend).execute(recover=True)
        self.assertEqual(intent["operation_id"], result["operation_id"])
        self.assertFalse(native.Journal(self.root).guard.exists())

    def test_failed_core_handshake_exposes_only_a_bounded_error_code(self):
        result = SimpleNamespace(returncode=1, stdout=b'{"error_code":"MODULE_DRAIN_REQUIRED"}\n', stderr=b'private details')
        with patch.object(native.subprocess, 'run', return_value=result), self.assertRaisesRegex(native.NativeError, '^CORE_MODULE_DRAIN_REQUIRED$'):
            native.Docker(self.root).run(['ignored'])
        result.stdout = b'{"error_code":"private unstructured content"}\n'
        with patch.object(native.subprocess, 'run', return_value=result), self.assertRaisesRegex(native.NativeError, '^DOCKER_COMMAND_FAILED$'):
            native.Docker(self.root).run(['ignored'])


if __name__ == "__main__":
    unittest.main()
