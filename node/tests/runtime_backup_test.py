#!/usr/bin/env python3
"""Isolated, synthetic Linux tests for the runtime archive engine."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tarfile
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("runtime_backup", Path(__file__).parents[1] / "runtime_backup.py")
engine = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(engine)

@unittest.skipUnless(os.name == "posix", "Linux durable filesystem operations")
class RuntimeBackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="txnode-runtime-test-")
        self.base = Path(self.temp.name)
        self.root = self.base / "deployment"
        self.root.mkdir(mode=0o700)
        (self.root / "data" / "node" / "authorization" / "node-1").mkdir(mode=0o700, parents=True)
        (self.root / "config.yml").write_bytes(b"panel:\n  token: PRIVATE_TEST_TOKEN\n")
        (self.root / "docker-compose.yml").write_bytes(b"services:\n  tx-node:\n    image: synthetic:old\n")
        for p in (self.root / "config.yml", self.root / "docker-compose.yml"):
            p.chmod(0o600)
        self.meta = self.base / "metadata.json"
        pending = "node/.txnode-traffic-" + hashlib.sha256(b"https://core.invalid|1|0|default").hexdigest()[:24] + ".pending.json"
        self.metadata = {
            "format": "txnode.runtime-capture/v1", "install_dir": str(self.root), "component": "tx-node",
            "stopped": True, "image_available": True, "image_id": "sha256:" + "a" * 64,
            "repo_digests": ["registry.invalid/synthetic@sha256:" + "b" * 64],
            "layout": {"format": "txnode.backup-layout/v1", "data_root": "/etc/txnode", "checkpoint_receipt": ".runtime-checkpoint.json", "targets": [{"instance_id": "default", "provider": "txboard", "panel_url": "https://core.invalid", "node_id": 1, "machine_id": 0, "kernel": "singbox", "kernel_root": "node", "dynamic_children": False, "authorization": {"enabled": True, "core_instance_id": "core_instance_test", "policy_version": "native-node-authorization/v1", "key_id": "key_1", "key_epoch": "1", "public_key": "A" * 43, "state_pattern": "node/authorization/node-1/state.json"}, "spool_patterns": [pending, pending + ".terminal.json"]}]},
            "capture": {"kind": "already_stopped"},
        }
        self.write_meta()
        self.archive = self.base / "backup.tar"
        self.spool = self.root / "data" / pending
        self.auth = self.root / "data" / "node" / "authorization" / "node-1" / "state.json"

    def tearDown(self):
        self.temp.cleanup()

    def write_meta(self):
        self.meta.write_bytes(engine.canonical(self.metadata))
        self.meta.chmod(0o600)

    def create(self):
        return engine.create(self.root, self.archive, self.meta)

    def restore(self):
        return engine.restore(self.root, self.archive, self.meta)

    def assertRefuses(self, expected, fn, *args):
        with self.assertRaises(engine.Refusal) as caught:
            fn(*args)
        self.assertEqual(str(caught.exception), expected)

    def state(self, revision=1, issued=100, observed=100, epoch=1, **changes):
        state = {
            "version": 1, "core_instance_id": "core_instance_test", "policy_version": "native-node-authorization/v1", "node_id": 1,
            "machine_id": None, "key_id": "key_1", "public_key": "A" * 43, "key_epoch": str(epoch),
            "revision": str(revision), "issued_at": issued, "expires_at": issued + 120,
            "last_observed_at": observed, "payload_digest": "c" * 64,
        }
        state.update(changes)
        data = engine.canonical({k: state[k] for k in engine.STATE_KEYS})
        return engine.canonical({"state": state, "digest": hashlib.sha256(data).hexdigest()})

    def private(self, path, body):
        path.write_bytes(body)
        path.chmod(0o600)

    def rewrite_archive(self, mutate):
        with tarfile.open(self.archive, "r:") as tf:
            members = [(m, tf.extractfile(m).read() if m.isreg() else None) for m in tf.getmembers()]
        members = mutate(members)
        self.archive.unlink()
        with tarfile.open(self.archive, "w", format=tarfile.USTAR_FORMAT) as tf:
            for info, body in members:
                if body is not None:
                    info.size = len(body)
                tf.addfile(info, io.BytesIO(body) if body is not None else None)
        self.archive.chmod(0o600)

    def test_full_round_trip_private_atomic_archive_and_safety_copy(self):
        body = b'{"Payload":{"BatchID":"original-batch"},"RecoveryTail":[]}\n'
        self.private(self.spool, body)
        self.private(self.auth, self.state())
        result = self.create()
        self.assertEqual(result["result"], "created")
        self.assertEqual(stat.S_IMODE(self.archive.stat().st_mode), 0o600)
        manifest, files = engine.load_archive(self.archive)
        self.assertEqual(files[str(self.spool.relative_to(self.root))], body)
        self.assertEqual(manifest["entries"], sorted(manifest["entries"], key=lambda e: e["path"]))
        self.assertNotIn("PRIVATE_TEST_TOKEN", json.dumps(engine.inspect(self.archive)))
        extra = self.root / "data" / "obsolete-cache"
        extra.write_bytes(b"new cache")
        output = self.restore()
        self.assertEqual(output["result"], "restored_stopped")
        self.assertEqual(self.spool.read_bytes(), body)
        self.assertFalse(extra.exists())
        self.assertEqual((Path(output["safety_dir"]) / "data" / "obsolete-cache").read_bytes(), b"new cache")
        self.assertFalse(engine.guard_path(self.root).exists())

    def test_restore_preserves_newer_authorization_raw_bytes(self):
        self.private(self.auth, self.state())
        self.create()
        newer = self.state(2, 105, 108) + b"\n"
        self.private(self.auth, newer)
        self.restore()
        self.assertEqual(self.auth.read_bytes(), newer)

    def test_restore_preserves_archive_newer_authorization(self):
        newer = self.state(3, 110, 110)
        self.private(self.auth, newer)
        self.create()
        self.private(self.auth, self.state())
        self.restore()
        self.assertEqual(self.auth.read_bytes(), newer)

    def test_current_only_authorization_and_both_spools_are_retained(self):
        self.create()
        terminal = Path(str(self.spool) + ".terminal.json")
        self.private(self.spool, b'{"id":"unchanged-current-pending"}')
        self.private(terminal, b'{"id":"unchanged-current-terminal"}')
        self.private(self.auth, self.state(2, 102, 102))
        bodies = {p: p.read_bytes() for p in (self.spool, terminal, self.auth)}
        self.restore()
        self.assertEqual({p: p.read_bytes() for p in bodies}, bodies)

    def test_spool_conflict_refuses_before_live_mutation(self):
        self.private(self.spool, b"old immutable batch")
        self.create()
        self.private(self.spool, b"different batch")
        before = engine.inventory(self.root)
        self.assertRefuses("TRAFFIC_SPOOL_CONFLICT", self.restore)
        self.assertEqual(engine.inventory(self.root), before)
        self.assertFalse(engine.guard_path(self.root).exists())

    def test_equal_authorization_revision_with_different_bytes_refused(self):
        self.private(self.auth, self.state())
        self.create()
        self.private(self.auth, self.state(observed=101))
        self.assertRefuses("AUTHORIZATION_EQUAL_REVISION_CONFLICT", self.restore)

    def test_authorization_crossed_high_water_and_trust_conflict_refused(self):
        self.private(self.auth, self.state(2, 110, 110))
        self.create()
        self.private(self.auth, self.state(3, 109, 111))
        self.assertRefuses("AUTHORIZATION_HIGH_WATER_CONFLICT", self.restore)
        self.private(self.auth, self.state(3, 111, 111, public_key="B" * 43))
        self.assertRefuses("AUTHORIZATION_LAYOUT_TRUST_CONFLICT", self.restore)

    def test_corrupt_authorization_refuses_even_current_only(self):
        self.create()
        self.private(self.auth, self.state().replace(b'"digest":"', b'"digest":"0'))
        self.assertRefuses("AUTHORIZATION_STATE_DIGEST_INVALID", self.restore)

    def test_machine_dynamic_children_preserve_actual_patterns_and_scope(self):
        target = self.metadata["layout"]["targets"][0]
        target.update(node_id=0, machine_id=41, dynamic_children=True)
        target["authorization"]["state_pattern"] = "node/authorization/node-{positive_id}/state.json"
        target["spool_patterns"] = ["node/node-{positive_id}/.txnode-traffic-{hex24}.pending.json", "node/node-{positive_id}/.txnode-traffic-{hex24}.pending.json.terminal.json"]
        self.write_meta()
        self.create()
        child_auth = self.root / "data/node/authorization/node-2/state.json"
        child_auth.parent.mkdir(mode=0o700)
        self.private(child_auth, self.state(4, 110, 111, node_id=2, machine_id=41))
        child_spool = self.root / "data/node/node-2/.txnode-traffic-0123456789abcdef01234567.pending.json"
        child_spool.parent.mkdir(mode=0o700)
        self.private(child_spool, b'{"Payload":{"BatchID":"original-machine-batch"}}')
        expected_auth, expected_spool = child_auth.read_bytes(), child_spool.read_bytes()
        self.restore()
        self.assertEqual(child_auth.read_bytes(), expected_auth)
        self.assertEqual(child_spool.read_bytes(), expected_spool)
        self.private(child_auth, self.state(5, 112, 112, node_id=2, machine_id=42))
        self.assertRefuses("AUTHORIZATION_LAYOUT_TRUST_CONFLICT", self.restore)

    def test_undeclared_current_auth_or_spool_is_refused_before_mutation(self):
        self.create()
        other_state = self.root / "data/node/authorization/node-9/state.json"
        other_state.parent.mkdir(mode=0o700)
        self.private(other_state, self.state(node_id=9))
        self.assertRefuses("UNDECLARED_AUTHORIZATION_STATE", self.restore)
        other_state.unlink()
        unknown_spool = self.root / "data/node/.txnode-traffic-0123456789abcdef01234567.pending.json"
        self.private(unknown_spool, b"unclassified original batch")
        self.assertRefuses("UNDECLARED_TRAFFIC_SPOOL", self.restore)

    def test_stored_authorization_must_match_declared_target_pin_and_policy(self):
        self.private(self.auth, self.state(node_id=2))
        self.assertRefuses("AUTHORIZATION_LAYOUT_TRUST_CONFLICT", self.create)
        self.private(self.auth, self.state(policy_version="foreign-policy"))
        self.assertRefuses("AUTHORIZATION_LAYOUT_TRUST_CONFLICT", self.create)
        self.private(self.auth, self.state(epoch=2))
        self.assertRefuses("AUTHORIZATION_LAYOUT_TRUST_CONFLICT", self.create)

    def test_configuration_reenrollment_refused(self):
        self.create()
        (self.root / "config.yml").write_bytes(b"new credentials")
        self.assertRefuses("CONFIGURATION_CHANGED_REENROLL_REQUIRED", self.restore)

    def test_before_publish_runs_after_arbitration_and_intent_before_guard(self):
        self.private(self.spool, b"immutable archived batch")
        self.create()
        callback = mock.Mock()
        self.private(self.spool, b"conflicting current batch")
        self.assertRefuses("TRAFFIC_SPOOL_CONFLICT", engine.restore, self.root, self.archive, self.meta, callback)
        callback.assert_not_called()
        self.private(self.spool, b"immutable archived batch")
        original = engine.inventory(self.root)
        def verify_boundary():
            self.assertEqual(engine.inventory(self.root), original)
            self.assertFalse(engine.guard_path(self.root).exists())
            intents = list(self.base.glob(".deployment.runtime-restore-*/intent.json"))
            self.assertEqual(len(intents), 1)
            intent = json.loads(intents[0].read_bytes())
            self.assertEqual(intent["install_dir"], str(self.root))
            self.assertTrue((intents[0].parent / "new/config.yml").exists())
        engine.restore(self.root, self.archive, self.meta, verify_boundary)

    def test_before_publish_refusal_leaves_live_and_guard_untouched(self):
        self.create()
        before = engine.inventory(self.root)
        def refuse_restart_policy_change():
            raise engine.Refusal("CONTAINER_INCARNATION_CHANGED")
        self.assertRefuses("CONTAINER_INCARNATION_CHANGED", engine.restore, self.root, self.archive, self.meta, refuse_restart_policy_change)
        self.assertEqual(engine.inventory(self.root), before)
        self.assertFalse(engine.guard_path(self.root).exists())
        self.assertEqual(len(list(self.base.glob(".deployment.runtime-restore-*/intent.json"))), 1)

    def test_pinned_compose_is_supported_and_archived_compose_does_not_override_it(self):
        self.create()
        compose = {"services": {"tx-node": {"image": self.metadata["image_id"], "restart": "no"}}}
        self.metadata["restore_compose"] = json.dumps(compose)
        self.write_meta()
        self.restore()
        self.assertEqual(json.loads((self.root / "docker-compose.yml").read_bytes()), compose)
        # A second restore succeeds with config identity fixed despite compose re-pinning.
        self.restore()

    def test_unavailable_image_and_running_refuse(self):
        self.create()
        for field in ("image_available", "stopped"):
            self.metadata[field] = False
            self.write_meta()
            self.assertRefuses("STOPPED_AVAILABLE_IMAGE_REQUIRED", self.restore)
            self.metadata[field] = True

    def test_wrong_layout_image_install_dir_and_partial_target_refuse(self):
        self.create()
        old = self.metadata["layout"]
        self.metadata["layout"] = json.loads(json.dumps(old))
        self.metadata["layout"]["targets"][0]["authorization"]["enabled"] = False
        self.metadata["layout"]["targets"][0]["authorization"]["state_pattern"] = ""
        self.write_meta()
        self.assertRefuses("SAME_DEPLOYMENT_AND_IMAGE_REQUIRED", self.restore)
        self.metadata["layout"] = old
        self.metadata["image_id"] = "sha256:" + "d" * 64
        self.write_meta()
        self.assertRefuses("SAME_DEPLOYMENT_AND_IMAGE_REQUIRED", self.restore)
        self.metadata["image_id"] = "sha256:" + "a" * 64
        self.write_meta()
        (self.root / "config.yml").unlink()
        self.assertRefuses("PARTIAL_DEPLOYMENT_REFUSED", self.restore)

    def test_source_links_and_special_modes_refused(self):
        link = self.root / "data" / "linked"
        link.symlink_to(self.root / "config.yml")
        self.assertRefuses("LINK_OR_SPECIAL_FILE_REFUSED", self.create)
        link.unlink()
        os.link(self.root / "config.yml", link)
        self.assertRefuses("REGULAR_FILE_REQUIRED", self.create)
        link.unlink()
        (self.root / "config.yml").chmod(0o4600)
        self.assertRefuses("SPECIAL_MODE_REFUSED", self.create)

    def test_source_ancestry_symlink_refused(self):
        alias = self.base / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        self.assertRefuses("SYMLINK_REFUSED", engine.create, alias, self.archive, self.meta)

    def test_archive_duplicate_traversal_absolute_unknown_and_links_refused(self):
        self.create()
        original = self.archive.read_bytes()
        for name, kind, expected in [
            ("../outside", tarfile.REGTYPE, "ARCHIVE_PATH_INVALID"),
            ("/outside", tarfile.REGTYPE, "ARCHIVE_PATH_INVALID"),
            ("unknown", tarfile.REGTYPE, "ARCHIVE_ENTRY_UNKNOWN"),
            ("data/link", tarfile.SYMTYPE, "ARCHIVE_ENTRY_MISMATCH"),
            ("data/hard", tarfile.LNKTYPE, "ARCHIVE_ENTRY_MISMATCH"),
        ]:
            with self.subTest(name=name):
                self.archive.write_bytes(original)
                def mutate(members):
                    info = tarfile.TarInfo(name)
                    info.type = kind
                    if kind != tarfile.REGTYPE:
                        info.linkname = "config.yml"
                    return members + [(info, b"" if kind == tarfile.REGTYPE else None)]
                self.rewrite_archive(mutate)
                self.assertRefuses(expected, engine.load_archive, self.archive)
        self.archive.write_bytes(original)
        self.rewrite_archive(lambda members: members + [members[-1]])
        self.assertRefuses("ARCHIVE_DUPLICATE_ENTRY", engine.load_archive, self.archive)

    def test_archive_hash_incomplete_and_trailing_data_refused(self):
        self.create()
        original = self.archive.read_bytes()
        def corrupt(members):
            return [(m, b"corrupt" if m.name == "config.yml" else body) for m, body in members]
        self.rewrite_archive(corrupt)
        self.assertRefuses("ARCHIVE_ENTRY_MISMATCH", engine.load_archive, self.archive)
        self.archive.write_bytes(original)
        self.rewrite_archive(lambda members: members[:-1])
        self.assertRefuses("ARCHIVE_INCOMPLETE", engine.load_archive, self.archive)
        self.archive.write_bytes(original + b"not padding")
        self.assertRefuses("ARCHIVE_TRAILING_DATA", engine.load_archive, self.archive)
        self.archive.write_bytes(original)
        def same_size(members):
            return [(m, bytes([body[0] ^ 1]) + body[1:] if m.name == "config.yml" else body) for m, body in members]
        self.rewrite_archive(same_size)
        self.assertRefuses("ARCHIVE_HASH_MISMATCH", engine.load_archive, self.archive)

    def test_private_metadata_and_archive_publication_collision_refused(self):
        self.meta.chmod(0o644)
        self.assertRefuses("PRIVATE_FILE_REQUIRED", self.create)
        self.meta.chmod(0o600)
        self.create()
        original = self.archive.read_bytes()
        self.assertRefuses("OUTPUT_EXISTS", self.create)
        self.assertEqual(self.archive.read_bytes(), original)

    def test_every_publish_rename_interruption_rolls_forward_with_guard(self):
        self.private(self.auth, self.state())
        self.create()
        points = ["guard", "old-config-yml", "new-config-yml", "old-docker-compose-yml", "new-docker-compose-yml", "old-data", "new-data", "complete"]
        for point in points:
            with self.subTest(point=point):
                with mock.patch.dict(os.environ, {"TXNODE_RUNTIME_BACKUP_TEST_FAIL_AFTER": point}):
                    self.assertRefuses("TEST_INTERRUPTION_" + point.upper().replace("-", "_"), self.restore)
                self.assertTrue(engine.guard_path(self.root).exists())
                self.assertRefuses("RESTORE_RECOVERY_REQUIRED", self.create)
                result = engine.recover(self.root)
                self.assertEqual(result["result"], "restored_stopped")
                self.assertEqual(self.auth.read_bytes(), self.state())
                self.assertTrue(Path(result["safety_dir"]).exists())

    def test_corrupted_recovery_intent_or_stage_refuses_without_mutation(self):
        self.create()
        with mock.patch.dict(os.environ, {"TXNODE_RUNTIME_BACKUP_TEST_FAIL_AFTER": "guard"}):
            self.assertRefuses("TEST_INTERRUPTION_GUARD", self.restore)
        guard = json.loads(engine.guard_path(self.root).read_bytes())
        stage_config = Path(guard["transaction"]) / "new" / "config.yml"
        stage_config.write_bytes(b"corrupt staged credentials")
        old_live = (self.root / "config.yml").read_bytes()
        self.assertRefuses("RECOVERY_NEW_EVIDENCE_INVALID", engine.recover, self.root)
        self.assertEqual((self.root / "config.yml").read_bytes(), old_live)
        self.assertTrue(engine.guard_path(self.root).exists())

    def test_complete_fresh_restore_only_at_original_path(self):
        self.create()
        # Preserve rather than delete the previous synthetic deployment.
        self.root.rename(self.base / "manually-kept-old")
        self.restore()
        self.assertTrue((self.root / "data").is_dir())
        self.assertIn(b"PRIVATE_TEST_TOKEN", (self.root / "config.yml").read_bytes())

    def test_bounds_and_duplicate_json_refused(self):
        self.create()
        with mock.patch.object(engine, "MAX_FILES", 1):
            self.assertRefuses("MANIFEST_LIMIT_EXCEEDED", engine.load_archive, self.archive)
        self.assertRefuses("DUPLICATE_JSON_KEY", engine.decode, b'{"a":1,"a":2}')

    def test_operation_lock_refuses_concurrent_owner(self):
        import subprocess
        with engine.operation_lock(self.root):
            proc = subprocess.run(["python3", str(Path(engine.__file__)), "create", "--install-dir", str(self.root), "--output", str(self.archive), "--metadata", str(self.meta)], capture_output=True, text=True)
            self.assertEqual(proc.returncode, 2)
            self.assertIn("OPERATION_ALREADY_RUNNING", proc.stderr)
            self.assertNotIn("PRIVATE_TEST_TOKEN", proc.stderr)

if __name__ == "__main__":
    unittest.main(verbosity=2)
