#!/usr/bin/env python3
"""Real SQLite mutations and killed child processes, without Docker or network."""
import base64
import copy
from contextlib import contextmanager
import gzip
import hashlib
import importlib.util
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch
from pathlib import Path

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("upgrade", Path(__file__).with_name("upgrade.py"))
upgrade = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upgrade)


@contextmanager
def connect(path):
    db = sqlite3.connect(path)
    try:
        with db:
            yield db
    finally:
        db.close()


def manifest():
    return {
        "manifest_version": upgrade.VERSION, "profile": upgrade.PROFILE, "release_id": "fixture-shadow-1", "created_at": 1700000000,
        "components": {"core": {"version": "fixture-1", "artifact": "ghcr.io/anrcm0/txboard@sha256:" + "a" * 64, "required": True},
                       "deploy": {"version": "fixture-1", "archive_sha256": "b" * 64, "required": True}},
        "compatibility": {"tested_tuple": {"core": "fixture-1", "deploy": "fixture-1"}, "core_schema_read_epochs": [1], "core_schema_write_epochs": [1],
                          "internal_api_major": 1, "secure_channel_major": 2, "node_protocol_majors": [1], "credential_provider_major": 1, "required_node_capabilities": []},
        "schema": {"family": "native_tx", "allowed_source_epochs": [1], "expanded_epoch": 1, "target_epoch": 1},
        "migrations": [{"id": identifier, "phase": phase, "probe": probe, "recovery": recovery,
                        **({"checkpoint": checkpoint} if checkpoint else {}), **({"from_epoch": 1, "to_epoch": 1} if phase == "expand" else {})}
                       for identifier, (phase, probe, recovery, checkpoint) in upgrade.MIGRATIONS.items()],
        "upgrade_policy": {"mode": "isolated_shadow", "order": list(upgrade.PHASES), "old_image_allowed_after_migration": False, "contract_deferred": True},
        "backup_policy": {"required": sorted(upgrade.BACKUP_DATASETS), "checksum_required": True, "restore_rehearsal_required": True, "receipt_recovery_coverage_required": True},
        "billing": {"currency": "CNY", "billing_timezone": "Asia/Shanghai"},
    }


class FixtureBackend:
    """SQLite is actual durable external state, independent of the runner journal.

    This injectable test backend is never selectable from the production CLI.
    Cursor and per-user data commit together; aggregate equality alone cannot pass verify.
    """
    def __init__(self, root):
        self.root = Path(root)
        self.path = self.root / "fixture.sqlite3"
        self.verified = False
        with connect(self.path) as db:
            db.execute("PRAGMA synchronous=FULL")
            db.execute("CREATE TABLE IF NOT EXISTS legacy(id INTEGER PRIMARY KEY,quota INTEGER NOT NULL,owner INTEGER NOT NULL)")
            db.execute("CREATE TABLE IF NOT EXISTS calls(step TEXT NOT NULL)")
            db.executemany("INSERT OR IGNORE INTO legacy VALUES(?,?,?)", [(1, 17, 1), (2, 29, 2), (3, 43, 3)])

    def controls(self):
        path = self.root / "controls.json"
        return json.loads(path.read_text()) if path.exists() else {}

    def check(self, manifest, recovering=False):
        if self.controls().get("preflight_failure"):
            raise upgrade.UpgradeError("fixture_preflight_rejected")
        return {"installation_id": "fixture-installation", "source_image_id": "sha256:old", "target_digest": "sha256:pinned"}, {"backup_id": "fixture-backup", "checksum": "verified"}

    def probe(self, step):
        if self.controls().get("unknown") == step:
            return {"status": "unknown", "checkpoint": None}
        with connect(self.path) as db:
            has = db.execute("SELECT COUNT(*) FROM sqlite_master WHERE name='shadow'").fetchone()[0]
            if step.endswith("expand-v1"):
                return {"status": "applied" if has else "not_started", "checkpoint": None}
            if step.endswith("backfill-v1"):
                cursor = db.execute("SELECT cursor FROM cursor_state").fetchone()[0]
                return {"status": "applied" if cursor == 3 else "partial" if cursor else "not_started",
                        "checkpoint": {"cursor_user_id": str(cursor), "high_water_user_id": "3"}}
            if step.endswith("verify-v1"):
                return {"status": "applied" if self.verified else "not_started", "checkpoint": {"authority": "legacy"}}
            if step.endswith("observe-v1"):
                return {"status": "applied" if self.verified else "unknown", "checkpoint": {"authority": "legacy"}}
        raise upgrade.UpgradeError("unknown_fixture_step")

    def perform(self, step, token, checkpoint):
        with connect(self.path) as db:
            db.execute("PRAGMA synchronous=FULL")
            db.execute("INSERT INTO calls VALUES(?)", (step,))
            if step.endswith("expand-v1"):
                db.execute("CREATE TABLE shadow(id INTEGER PRIMARY KEY,quota INTEGER NOT NULL,owner INTEGER NOT NULL)")
                db.execute("CREATE TABLE cursor_state(cursor INTEGER NOT NULL)")
                db.execute("INSERT INTO cursor_state VALUES(0)")
            elif step.endswith("backfill-v1"):
                cursor = db.execute("SELECT cursor FROM cursor_state").fetchone()[0]
                row = db.execute("SELECT * FROM legacy WHERE id>? ORDER BY id LIMIT 1", (cursor,)).fetchone()
                db.execute("INSERT INTO shadow VALUES(?,?,?)", row)
                db.execute("UPDATE cursor_state SET cursor=?", (row[0],))
            elif step.endswith("verify-v1"):
                mismatch = db.execute("SELECT COUNT(*) FROM legacy l LEFT JOIN shadow s ON l.id=s.id WHERE s.id IS NULL OR l.owner!=s.owner OR l.quota!=s.quota").fetchone()[0]
                if mismatch:
                    raise upgrade.UpgradeError("reconciliation_failed")
                self.verified = True
            else:
                raise upgrade.UpgradeError("unsupported_fixture_action")


def worker(root, hook_event, hook_step):
    root = Path(root)
    def hook(event, step):
        if event == hook_event and step == hook_step:
            print("kill-ready", flush=True)
            # Parent really terminates this process. The runner cannot run an exit trap.
            time.sleep(60)
            raise RuntimeError("parent did not kill child")
    with upgrade.InstallLock(root):
        journal = upgrade.Journal(root)
        upgrade.Runner(journal, FixtureBackend(root), manifest(), "c" * 64, hook=hook).execute()


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.backend = FixtureBackend(self.root)
        self.document = manifest()

    def tearDown(self):
        self.temp.cleanup()

    def execute(self, recover=False, max_batches=1000, digest="c" * 64):
        with upgrade.InstallLock(self.root):
            journal = upgrade.Journal(self.root)
            try:
                return upgrade.Runner(journal, FixtureBackend(self.root), self.document, digest, max_batches).execute(recover)
            finally:
                journal.close()

    def report(self):
        journal = upgrade.Journal(self.root, readonly=True)
        try:
            return journal.report(self.document["release_id"])
        finally:
            journal.close()

    def kill_at(self, event, step):
        child = subprocess.Popen([sys.executable, "-B", __file__, "--worker", str(self.root), event, step], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            line = child.stdout.readline()
            self.assertEqual(line.strip(), "kill-ready", child.stderr.read() if child.poll() is not None else "")
            child.kill()
            child.wait(timeout=10)
            self.assertNotEqual(child.returncode, 0)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=10)
            child.stdout.close()
            child.stderr.close()

    def test_actual_bounded_backfill_and_per_object_reconcile(self):
        report = self.execute()
        self.assertEqual(report["status"], "completed")
        self.assertTrue((self.root / ".upgrade-in-progress").exists())
        with connect(self.backend.path) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM shadow").fetchone()[0], 3)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM calls WHERE step LIKE '%backfill-v1'").fetchone()[0], 3)
        self.assertEqual(report["steps"][1]["attempt"], 3)

    def test_kill_after_ddl_intent_probes_not_started_and_resumes(self):
        self.kill_at("after_intent", "subscription-shadow-expand-v1")
        self.assertIsNone(self.report()["steps"][0]["result"])
        self.assertEqual(self.execute(True)["status"], "completed")

    def test_kill_after_ddl_commit_does_not_repeat_ddl(self):
        self.kill_at("after_side_effect", "subscription-shadow-expand-v1")
        self.assertEqual(self.execute(True)["status"], "completed")
        with connect(self.backend.path) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM calls WHERE step LIKE '%expand-v1'").fetchone()[0], 1)

    def test_kill_after_cursor_commit_replays_only_remaining_rows(self):
        self.kill_at("after_side_effect", "subscription-shadow-backfill-v1")
        self.assertEqual(self.execute(True)["status"], "completed")
        with connect(self.backend.path) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM shadow").fetchone()[0], 3)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM calls WHERE step LIKE '%backfill-v1'").fetchone()[0], 3)

    def test_kill_after_successful_read_only_verify_repeats_verify(self):
        self.kill_at("after_result", "subscription-shadow-verify-v1")
        self.assertEqual(self.execute(True)["status"], "completed")
        with connect(self.backend.path) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM calls WHERE step LIKE '%verify-v1'").fetchone()[0], 2)

    def test_unknown_result_retains_fence_and_never_repeats_effect(self):
        self.kill_at("after_side_effect", "subscription-shadow-expand-v1")
        (self.root / "controls.json").write_text(json.dumps({"unknown": "subscription-shadow-expand-v1"}))
        with self.assertRaisesRegex(upgrade.UpgradeError, "unknown_step_result"):
            self.execute(True)
        self.assertEqual(self.report()["status"], "recovery_required")
        self.assertTrue((self.root / ".upgrade-in-progress").exists())
        with connect(self.backend.path) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM calls").fetchone()[0], 1)

    def test_per_user_owner_mismatch_blocks_even_when_aggregates_equal(self):
        self.kill_at("after_result", "subscription-shadow-backfill-v1")
        with connect(self.backend.path) as db:
            db.execute("UPDATE shadow SET owner=2 WHERE id=1")
        with self.assertRaisesRegex(upgrade.UpgradeError, "reconciliation_failed"):
            self.execute(True)
        self.assertEqual(self.report()["status"], "paused_failed")
        self.assertTrue((self.root / ".upgrade-in-progress").exists())

    def test_resume_requires_explicit_recovery(self):
        self.kill_at("after_intent", "subscription-shadow-expand-v1")
        with self.assertRaisesRegex(upgrade.UpgradeError, "recovery_command_required"):
            self.execute()

    def test_manifest_cannot_change_under_same_release_id(self):
        self.kill_at("after_intent", "subscription-shadow-expand-v1")
        with self.assertRaisesRegex(upgrade.UpgradeError, "release_id_reused"):
            self.execute(True, digest="d" * 64)

    def test_bounded_run_stops_and_resumes_from_durable_cursor(self):
        with self.assertRaisesRegex(upgrade.UpgradeError, "batch_budget_exhausted"):
            self.execute(max_batches=1)
        self.assertEqual(self.report()["status"], "paused_failed")
        self.assertEqual(self.execute(True)["status"], "completed")

    def test_lock_conflict_excludes_a_real_second_process(self):
        self.kill_at("after_intent", "subscription-shadow-expand-v1")
        with upgrade.InstallLock(self.root):
            result = subprocess.run([sys.executable, "-B", __file__, "--worker", str(self.root), "never", "never"], capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"upgrade_lock_held", result.stderr)

    def test_monotonic_fence_rejects_stale_checkpoint_writer(self):
        one, two = upgrade.Journal(self.root), upgrade.Journal(self.root)
        try:
            first = one.acquire_fence()
            second = two.acquire_fence()
            self.assertGreater(second, first)
            with self.assertRaisesRegex(upgrade.UpgradeError, "stale_executor_fence"):
                one.begin(self.document, "c" * 64, {"installation_id": "x"}, {})
        finally:
            one.close()
            two.close()

    def test_unknown_checkpoint_version_and_state_fail_closed(self):
        self.execute()
        path = self.root / ".upgrade" / "state.sqlite3"
        with connect(path) as db:
            db.execute("UPDATE runs SET status='guessed-healthy'")
        with self.assertRaisesRegex(upgrade.UpgradeError, "unknown_checkpoint_state"):
            self.report()
        with connect(path) as db:
            db.execute("UPDATE meta SET version=999")
        with self.assertRaisesRegex(upgrade.UpgradeError, "unsupported_checkpoint_version"):
            upgrade.Journal(self.root, readonly=True)

    def test_corrupt_checkpoint_never_uses_container_health(self):
        directory = self.root / ".upgrade"
        directory.mkdir()
        (directory / "state.sqlite3").write_bytes(b"corrupt database")
        with self.assertRaises(sqlite3.DatabaseError):
            upgrade.Journal(self.root, readonly=True)

    def test_preflight_rejection_has_no_migration_effect(self):
        (self.root / "controls.json").write_text(json.dumps({"preflight_failure": True}))
        with self.assertRaisesRegex(upgrade.UpgradeError, "fixture_preflight_rejected"):
            self.execute()
        with connect(self.backend.path) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM calls").fetchone()[0], 0)
        self.assertFalse((self.root / ".upgrade-in-progress").exists())

    def test_marker_without_matching_journal_is_not_overwritten(self):
        (self.root / ".upgrade-in-progress").write_text(json.dumps({"checkpoint_version": 1, "release_id": "unknown", "manifest_sha256": "e" * 64,
            "instance_id": "lost", "fencing_token": 1, "old_image_allowed": False}))
        with self.assertRaisesRegex(upgrade.UpgradeError, "unknown_active_upgrade"):
            self.execute()

    def test_completed_run_rechecks_read_only_state(self):
        self.execute()
        self.assertEqual(self.execute(True)["status"], "completed")
        with connect(self.backend.path) as db:
            db.execute("UPDATE shadow SET quota=0 WHERE id=1")
        with self.assertRaisesRegex(upgrade.UpgradeError, "reconciliation_failed"):
            self.execute(True)


class ManifestTests(unittest.TestCase):
    def test_strict_fields_types_versions_commands_and_dependencies(self):
        upgrade.validate_manifest(manifest())
        mutations = [lambda m: m.update(shell="curl | bash"), lambda m: m.update(created_at=True),
                     lambda m: m.update(manifest_version="txboard.upgrade-manifest/v999"),
                     lambda m: m["components"]["core"].update(artifact="ghcr.io/anrcm0/txboard:latest"),
                     lambda m: m["schema"].update(target_epoch=2),
                     lambda m: m["migrations"][0].update(id="third-party-command"),
                     lambda m: m["migrations"].reverse(), lambda m: m["migrations"][1].update(probe="run-shell"),
                     lambda m: m["upgrade_policy"].update(mode="cluster"),
                     lambda m: m["upgrade_policy"].update(old_image_allowed_after_migration=True),
                     lambda m: m["compatibility"].update(secure_channel_major=999),
                     lambda m: m["components"]["node"].update(required=True)]
        for mutate in mutations[:-1]:
            with self.subTest(mutation=mutate):
                document = manifest()
                mutate(document)
                with self.assertRaises(upgrade.UpgradeError):
                    upgrade.validate_manifest(document)

    def test_duplicate_keys_and_nonfinite_numbers_rejected(self):
        for raw in (b'{"a":1,"a":2}', b'{"a":NaN}', b'{"a":Infinity}'):
            with self.assertRaises(upgrade.UpgradeError):
                upgrade.parse_json(raw)

    def test_production_cutover_and_restore_have_no_cli_escape_hatch(self):
        source = Path(upgrade.__file__).read_text()
        self.assertNotIn('"restore",', source)
        self.assertNotIn('"--backend"', source)
        self.assertNotIn('"switch":', source)

    def test_deploy_bundle_pins_actual_installed_runtime(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp) / "deploy.tar.gz"
            root = Path(__file__).resolve().parent.parent
            with tarfile.open(bundle, "w:gz") as archive:
                for filename in ("scripts/upgrade.py", "lib/detect.sh"):
                    archive.add(root / filename, arcname=filename)
            document = manifest()
            document["components"]["deploy"]["archive_sha256"] = hashlib.sha256(bundle.read_bytes()).hexdigest()
            upgrade.verify_deploy_bundle(bundle, document)
            document["components"]["deploy"]["archive_sha256"] = "d" * 64
            with self.assertRaisesRegex(upgrade.UpgradeError, "deploy_bundle_digest_mismatch"):
                upgrade.verify_deploy_bundle(bundle, document)


class SignatureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.openssl = os.environ.get("TXBOARD_TEST_OPENSSL") or shutil.which("openssl")
        if not cls.openssl and os.name == "nt":
            git_openssl = Path("D:/devTool/Git/mingw64/bin/openssl.exe")
            cls.openssl = str(git_openssl) if git_openssl.is_file() else None
        if not cls.openssl:
            raise RuntimeError("OpenSSL required for real detached-signature tests")
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.private = cls.root / "private.pem"
        cls.public = cls.root / "release-key.pem"
        for args in (["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", str(cls.private)],
                     ["pkey", "-in", str(cls.private), "-pubout", "-out", str(cls.public)]):
            subprocess.run([cls.openssl, *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def sign(self):
        path = self.root / "manifest.json"
        path.write_text(json.dumps(manifest()), encoding="utf-8")
        signature = self.root / "signature.bin"
        subprocess.run([self.openssl, "dgst", "-sha256", "-sign", str(self.private), "-out", str(signature), str(path)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        envelope = self.root / "signature.json"
        envelope.write_text(json.dumps({"algorithm": "rsa-pkcs1-sha256", "key_id": "release-key", "manifest_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                                        "signature": base64.b64encode(signature.read_bytes()).decode()}))
        return path, envelope

    def test_actual_detached_signature_and_manifest_tamper_rejection(self):
        path, envelope = self.sign()
        document, digest = upgrade.load_signed_manifest(path, envelope, self.root, self.openssl)
        self.assertEqual(document["profile"], upgrade.PROFILE)
        document["release_id"] = "tampered"
        path.write_text(json.dumps(document))
        with self.assertRaisesRegex(upgrade.UpgradeError, "manifest_digest_mismatch"):
            upgrade.load_signed_manifest(path, envelope, self.root, self.openssl)
        data = json.loads(envelope.read_text())
        data["manifest_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        envelope.write_text(json.dumps(data))
        with self.assertRaisesRegex(upgrade.UpgradeError, "untrusted_manifest_signature"):
            upgrade.load_signed_manifest(path, envelope, self.root, self.openssl)

    def test_unknown_trust_key_and_modified_signature_fail(self):
        path, envelope = self.sign()
        data = json.loads(envelope.read_text())
        data["key_id"] = "untrusted"
        envelope.write_text(json.dumps(data))
        with self.assertRaises(upgrade.UpgradeError):
            upgrade.load_signed_manifest(path, envelope, self.root, self.openssl)
        data["key_id"], data["signature"] = "release-key", base64.b64encode(b"\x00" * 256).decode()
        envelope.write_text(json.dumps(data))
        with self.assertRaisesRegex(upgrade.UpgradeError, "untrusted_manifest_signature"):
            upgrade.load_signed_manifest(path, envelope, self.root, self.openssl)


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.document = manifest()
        self.backend = upgrade.DockerShadowBackend(Path.cwd(), None, None, "c" * 64, self.document)

    def test_partial_ddl_is_unknown_instead_of_repeatable(self):
        with patch.object(self.backend, "sql", side_effect=["", "3"]):
            self.assertEqual(self.backend.probe("subscription-shadow-expand-v1")["status"], "unknown")
        with patch.object(self.backend, "sql", side_effect=[upgrade.MIGRATION_FILE, "9", "8"]):
            with self.assertRaisesRegex(upgrade.UpgradeError, "shadow_schema_shape_mismatch"):
                self.backend.probe("subscription-shadow-expand-v1")

    def test_committed_conflict_is_detected_without_replaying_batch(self):
        with patch.object(self.backend, "sql", return_value="1"):
            with self.assertRaisesRegex(upgrade.UpgradeError, "core_shadow_source_conflict"):
                self.backend.probe("subscription-shadow-backfill-v1")

    def test_fixed_migration_path_and_argv_never_use_manifest_commands(self):
        with patch.object(self.backend, "artisan") as call:
            self.backend.perform("subscription-shadow-expand-v1", 1, None)
            call.assert_called_once_with("migrate", "--force", "--path=database/migrations/" + upgrade.MIGRATION_FILE + ".php")
        with self.assertRaisesRegex(upgrade.UpgradeError, "unsupported_runtime_action"):
            self.backend.perform("run-untrusted-script", 1, None)

    def test_verify_requires_every_page_and_repeats_from_zero_after_restart(self):
        response = {"run_key": self.document["release_id"], "authority": "legacy", "passed": True,
                    "checked_count": "1000", "after_id": "0", "next_cursor": "1000", "complete": False, "differences": []}
        with patch.object(self.backend, "artisan", return_value=json.dumps(response).encode()) as call:
            self.backend.perform("subscription-shadow-verify-v1", 1, None)
            self.assertEqual(self.backend.probe("subscription-shadow-verify-v1")["status"], "partial")
            self.assertIn("--after-id=0", call.call_args.args)
        response.update(checked_count="1", after_id="1000", next_cursor="1001", complete=True)
        with patch.object(self.backend, "artisan", return_value=json.dumps(response).encode()) as call:
            self.backend.perform("subscription-shadow-verify-v1", 1, None)
            self.assertEqual(self.backend.probe("subscription-shadow-verify-v1")["status"], "applied")
            self.assertIn("--after-id=1000", call.call_args.args)
        restarted = upgrade.DockerShadowBackend(Path.cwd(), None, None, "c" * 64, self.document)
        self.assertEqual(restarted.verify_cursor, "0")
        self.assertFalse(restarted.verified)

    def test_reconcile_failure_never_passes_on_complete_flag(self):
        response = {"run_key": self.document["release_id"], "authority": "legacy", "passed": False,
                    "checked_count": "1", "next_cursor": "1", "complete": True, "differences": [{"legacy_user_id": "1", "code": "QUOTA_MISMATCH"}]}
        with patch.object(self.backend, "artisan", return_value=json.dumps(response).encode()):
            with self.assertRaisesRegex(upgrade.UpgradeError, "reconciliation_failed"):
                self.backend.perform("subscription-shadow-verify-v1", 1, None)
class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.backup = self.root / "fixture-backup"
        self.backup.mkdir()
        files = {"env": b"APP_KEY=fixture-nonsecret-key\n", "deploy.env": b"fixture\n", "compose.yaml": b"services: {}\n", "receipt-boundary.json": b'{}',
                 "rehearsal.json": b'{"import_verified":true}', "coverage.json": b'{"isolated":true}'}
        for name, raw in files.items():
            (self.backup / name).write_bytes(raw)
        with gzip.open(self.backup / "db.sql.gz", "wb") as stream:
            stream.write(b"CREATE TABLE test(id int);\n")
        with gzip.open(self.backup / "storage-app.tar.gz", "wb") as stream:
            stream.write(b"fixture-storage")
        self.evidence = {"evidence_version": "txboard.backup-evidence/v1", "backup_id": self.backup.name, "manifest_sha256": "c" * 64,
                         "datasets": {"mysql": ["db.sql.gz"], "core-key-material": ["env"], "plugin-private-data": [],
                                      "persistent-files": ["storage-app.tar.gz"], "deployment-config": ["deploy.env", "compose.yaml"], "usage-receipts": ["receipt-boundary.json"]},
                         "rehearsal": {"passed": True, "report_file": "rehearsal.json", "backup_checksum": hashlib.sha256((self.backup / "db.sql.gz").read_bytes()).hexdigest()},
                         "recovery_coverage": {"passed": True, "report_file": "coverage.json", "receipt_generation": "1", "revocation_version": "0", "post_backup_changes": "none-isolated-copy"}}
        self.evidence_path = self.root / "evidence.json"
        self.rehash()

    def tearDown(self):
        self.temp.cleanup()

    def rehash(self):
        files = sorted(p for p in self.backup.iterdir() if p.name != "CHECKSUMS.sha256")
        (self.backup / "CHECKSUMS.sha256").write_text("".join(hashlib.sha256(p.read_bytes()).hexdigest() + "  " + p.name + "\n" for p in files))
        self.evidence_path.write_text(json.dumps(self.evidence))

    def check(self):
        return upgrade.backup_check(self.backup, self.evidence_path, "c" * 64)

    def test_verified_bytes_keep_rehearsal_attestation_distinct(self):
        report = self.check()
        self.assertEqual(report["rehearsal"], "operator-attested")
        self.assertEqual(report["backup_id"], "fixture-backup")

    def test_tampered_backup_and_missing_app_key_block(self):
        (self.backup / "env").write_bytes(b"APP_KEY=changed\n")
        with self.assertRaisesRegex(upgrade.UpgradeError, "backup_checksum_mismatch"):
            self.check()
        (self.backup / "env").write_bytes(b"no-key\n")
        self.rehash()
        with self.assertRaisesRegex(upgrade.UpgradeError, "backup_key_material_missing"):
            self.check()

    def test_uncovered_post_backup_transactions_and_receipts_block(self):
        self.evidence["recovery_coverage"]["post_backup_changes"] = "payment-and-traffic-increments"
        self.rehash()
        with self.assertRaisesRegex(upgrade.UpgradeError, "post_backup_changes_uncovered"):
            self.check()

    def test_missing_dataset_or_rehearsal_cannot_be_waived(self):
        self.evidence["datasets"]["usage-receipts"] = []
        self.rehash()
        with self.assertRaisesRegex(upgrade.UpgradeError, "missing_backup_dataset"):
            self.check()
        self.evidence["datasets"]["usage-receipts"] = ["receipt-boundary.json"]
        self.evidence["rehearsal"]["passed"] = False
        self.rehash()
        with self.assertRaisesRegex(upgrade.UpgradeError, "restore_evidence_required"):
            self.check()

    def test_checksum_path_traversal_is_rejected_without_reading_external_files(self):
        with (self.backup / "CHECKSUMS.sha256").open("a") as stream:
            stream.write("a" * 64 + "  ../outside\n")
        with self.assertRaisesRegex(upgrade.UpgradeError, "invalid_backup_checksum_list"):
            self.check()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--worker":
        worker(*sys.argv[2:])
    else:
        unittest.main()
