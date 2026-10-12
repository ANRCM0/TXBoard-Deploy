#!/usr/bin/env python3
"""Signed, durable upgrade runner. The first executable profile is an isolated shadow rehearsal.

No executable, SQL, URL, or plugin supplied by a manifest is ever executed. Production
authority switches, cluster leases and database restoration are deliberately unavailable.
"""
import argparse
import base64
import gzip
import hashlib
import json
import os
import re
import sqlite3
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid
from pathlib import Path

VERSION = "txboard.upgrade-manifest/v1"
PROFILE = "subscription-shadow/v1"
CATALOG_PROFILE = "plan-catalog-shadow/v1"
COMMERCE_PROFILE = "commerce-shadow/v1"
CHECKPOINT_VERSION = 1
PHASES = ("expand", "backfill", "verify", "observe")
MIGRATION_FILE = "2026_10_12_000001_create_subscription_shadow_tables"
# IDs, probe IDs and recovery semantics are bound together in shipped code.
MIGRATIONS = {
    "subscription-shadow-expand-v1": ("expand", "subscription-shadow-shape-v1", "probe_then_continue", "ddl-step"),
    "subscription-shadow-backfill-v1": ("backfill", "subscription-shadow-progress-v1", "resume_cursor", "legacy-user-id"),
    "subscription-shadow-verify-v1": ("verify", "subscription-shadow-reconcile-v1", "read_only_repeat", None),
}
CATALOG_MIGRATION_FILE = "2026_10_12_000002_create_plan_catalog_shadow_tables"
CATALOG_MIGRATIONS = {
    "plan-catalog-shadow-expand-v1": ("expand", "plan-catalog-shadow-shape-v1", "probe_then_continue", "ddl-step"),
    "plan-catalog-shadow-backfill-v1": ("backfill", "plan-catalog-shadow-progress-v1", "resume_cursor", "legacy-plan-id"),
    "plan-catalog-shadow-verify-v1": ("verify", "plan-catalog-shadow-reconcile-v1", "read_only_repeat", None),
}
COMMERCE_MIGRATION_FILE = "2026_10_12_000004_create_commerce_shadow_tables"
COMMERCE_MIGRATIONS = {
    "commerce-shadow-expand-v1": ("expand", "commerce-shadow-shape-v1", "probe_then_continue", "ddl-step"),
    "commerce-shadow-backfill-v1": ("backfill", "commerce-shadow-progress-v1", "resume_cursor", "legacy-user-order-id"),
    "commerce-shadow-verify-v1": ("verify", "commerce-shadow-reconcile-v1", "read_only_repeat", None),
}
PROFILES = {PROFILE: MIGRATIONS, CATALOG_PROFILE: CATALOG_MIGRATIONS, COMMERCE_PROFILE: COMMERCE_MIGRATIONS}
COMMERCE_TABLES = tuple("tx_commerce_shadow_" + suffix for suffix in
    ("money_account", "money_journal", "money_posting", "user_opening", "order", "checkpoint", "exception"))
COMMERCE_INDEXES = ("tx_commerce_shadow_money_account_business_uq", "tx_commerce_shadow_money_journal_business_uq",
    "tx_commerce_shadow_money_posting_line_uq", "tx_commerce_shadow_user_currency_uq",
    "tx_commerce_shadow_order_legacy_order_id_unique", "tx_commerce_shadow_checkpoint_run_key_unique",
    "tx_commerce_shadow_exception_business_uq")
CATALOG_TABLES = ("tx_plan_revision", "tx_plan_offer", "tx_plan_offer_availability", "tx_plan_catalog_shadow", "tx_plan_catalog_checkpoint", "tx_plan_catalog_exception")
CATALOG_INDEXES = ("tx_revision_number_uq", "tx_revision_owner_uq", "tx_offer_version_uq")
IDENT = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\Z")
SHA = re.compile(r"[0-9a-f]{64}\Z")
OCI = re.compile(r"(?:[a-z0-9]+(?:[._-][a-z0-9]+)*\.)*[a-z0-9]+(?::[0-9]+)?/(?:[a-z0-9._-]+/)*[a-z0-9._-]+@sha256:[0-9a-f]{64}\Z")
DECIMAL = re.compile(r"(?:0|[1-9][0-9]*)\Z")
BACKUP_DATASETS = {"mysql", "core-key-material", "plugin-private-data", "persistent-files", "deployment-config", "usage-receipts"}


class UpgradeError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def require(condition, code):
    if not condition:
        raise UpgradeError(code)


def shape(value, required, optional=()):
    require(type(value) is dict and set(required) <= value.keys() and value.keys() <= set(required) | set(optional), "invalid_object_fields")


def safe_int(value, minimum=0):
    require(type(value) is int and minimum <= value <= 9007199254740991, "invalid_integer")


def identifier(value):
    require(type(value) is str and IDENT.fullmatch(value), "invalid_identifier")


def unique_list(value, validator):
    require(type(value) is list and value and len(value) <= 256, "invalid_list")
    for item in value:
        validator(item)
    require(len(set(value)) == len(value), "duplicate_list_item")


def no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate_json_key")
        result[key] = value
    return result


def parse_json(raw):
    require(len(raw) <= 1024 * 1024, "json_too_large")
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=no_duplicates,
                          parse_constant=lambda _: (_ for _ in ()).throw(UpgradeError("invalid_json_number")))
    except (UnicodeError, ValueError) as exc:
        raise UpgradeError("invalid_json") from exc


def read_regular(path, limit=1024 * 1024):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), "regular_file_required")
    require(path.stat().st_size <= limit, "file_too_large")
    return path.read_bytes()


def hash_regular(path):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), "regular_file_required")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def validate_manifest(manifest):
    shape(manifest, ("manifest_version", "profile", "release_id", "created_at", "components", "compatibility", "schema", "migrations", "upgrade_policy", "backup_policy", "billing"))
    require(manifest["manifest_version"] == VERSION, "unsupported_manifest_version")
    require(type(manifest["profile"]) is str and manifest["profile"] in PROFILES, "unsupported_upgrade_profile")
    allowed_migrations = PROFILES[manifest["profile"]]
    identifier(manifest["release_id"])
    require(len(manifest["release_id"]) <= 64, "release_id_too_long_for_core")
    safe_int(manifest["created_at"])
    require(manifest["created_at"] <= int(time.time()) + 300, "future_manifest")
    components = manifest["components"]
    shape(components, ("core", "deploy"), ("gateway", "node", "frontend", "credential_provider", "installer"))
    for name, component in components.items():
        shape(component, ("version", "required"), ("artifact", "archive_sha256"))
        identifier(component["version"])
        require(type(component["required"]) is bool, "invalid_required_flag")
        require(("artifact" in component) != ("archive_sha256" in component), "one_artifact_required")
        if "artifact" in component:
            require(type(component["artifact"]) is str and OCI.fullmatch(component["artifact"]), "unpinned_artifact")
        else:
            require(type(component["archive_sha256"]) is str and SHA.fullmatch(component["archive_sha256"]), "invalid_artifact_digest")
        require(name in ("core", "deploy") or component["required"] is False, "unsupported_required_role")
    require(components["core"]["required"] and components["deploy"]["required"] and "artifact" in components["core"], "missing_required_component")
    compat = manifest["compatibility"]
    shape(compat, ("tested_tuple", "core_schema_read_epochs", "core_schema_write_epochs", "internal_api_major", "secure_channel_major", "node_protocol_majors", "credential_provider_major", "required_node_capabilities"))
    shape(compat["tested_tuple"], components.keys())
    require(all(compat["tested_tuple"][k] == v["version"] for k, v in components.items()), "inconsistent_tested_tuple")
    for name in ("core_schema_read_epochs", "core_schema_write_epochs", "node_protocol_majors"):
        unique_list(compat[name], lambda v: safe_int(v, 1))
    require(compat["core_schema_read_epochs"] == [1] and compat["core_schema_write_epochs"] == [1], "unsupported_schema_epoch")
    # These versions are declarations for the isolated pilot, never evidence of a live integration.
    for name in ("internal_api_major", "secure_channel_major", "credential_provider_major"):
        safe_int(compat[name], 1)
    require(compat["internal_api_major"] == 1 and compat["secure_channel_major"] == 2 and compat["credential_provider_major"] == 1, "unsupported_protocol_major")
    require(compat["node_protocol_majors"] == [1] and compat["required_node_capabilities"] == [], "unsupported_node_upgrade")
    schema = manifest["schema"]
    shape(schema, ("family", "allowed_source_epochs", "expanded_epoch", "target_epoch"))
    require(schema == {"family": "native_tx", "allowed_source_epochs": [1], "expanded_epoch": 1, "target_epoch": 1}, "unsupported_schema_transition")
    migrations = manifest["migrations"]
    require(type(migrations) is list and len(migrations) == len(allowed_migrations), "unsupported_migration_list")
    require([m.get("id") for m in migrations if type(m) is dict] == list(allowed_migrations), "unsupported_migration_order")
    for migration in migrations:
        phase, probe, recovery, checkpoint = allowed_migrations[migration["id"]]
        shape(migration, ("id", "phase", "probe", "recovery"), ("checkpoint", "from_epoch", "to_epoch"))
        require((migration["phase"], migration["probe"], migration["recovery"], migration.get("checkpoint")) == (phase, probe, recovery, checkpoint), "unsupported_migration_semantics")
        if phase == "expand":
            require(migration.get("from_epoch") == 1 and migration.get("to_epoch") == 1, "unsupported_schema_epoch")
        else:
            require("from_epoch" not in migration and "to_epoch" not in migration, "unexpected_migration_epochs")
    policy = manifest["upgrade_policy"]
    shape(policy, ("mode", "order", "old_image_allowed_after_migration", "contract_deferred"))
    require(policy == {"mode": "isolated_shadow", "order": list(PHASES), "old_image_allowed_after_migration": False, "contract_deferred": True}, "unsupported_upgrade_policy")
    backup = manifest["backup_policy"]
    shape(backup, ("required", "checksum_required", "restore_rehearsal_required", "receipt_recovery_coverage_required"))
    unique_list(backup["required"], identifier)
    require(set(backup["required"]) == BACKUP_DATASETS and all(backup[k] is True for k in backup if k != "required"), "unsafe_backup_policy")
    billing = manifest["billing"]
    shape(billing, ("currency", "billing_timezone"))
    require(type(billing["currency"]) is str and re.fullmatch(r"[A-Z]{3}", billing["currency"]), "invalid_currency")
    require(type(billing["billing_timezone"]) is str and re.fullmatch(r"[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+)*", billing["billing_timezone"]), "invalid_timezone")
    return manifest


def load_signed_manifest(path, signature_path, trust_dir, openssl="openssl"):
    raw = read_regular(path)
    manifest = validate_manifest(parse_json(raw))
    envelope = parse_json(read_regular(signature_path))
    shape(envelope, ("algorithm", "key_id", "manifest_sha256", "signature"))
    identifier(envelope["key_id"])
    digest = hashlib.sha256(raw).hexdigest()
    require(envelope["algorithm"] == "rsa-pkcs1-sha256", "unsupported_signature_algorithm")
    require(envelope["manifest_sha256"] == digest, "manifest_digest_mismatch")
    key = Path(trust_dir) / (envelope["key_id"] + ".pem")
    read_regular(key, 16384)
    if os.name == "posix":
        require(key.stat().st_uid in (0, os.geteuid()) and not key.stat().st_mode & 0o022, "unsafe_trust_key_permissions")
        require(not Path(trust_dir).is_symlink() and not Path(trust_dir).stat().st_mode & 0o022, "unsafe_trust_directory_permissions")
    try:
        signature = base64.b64decode(envelope["signature"], validate=True)
        require(256 <= len(signature) <= 1024, "invalid_signature_length")
        with tempfile.TemporaryDirectory(prefix="txboard-signature-") as tmp:
            input_path, sig_path = Path(tmp) / "manifest", Path(tmp) / "signature"
            input_path.write_bytes(raw)
            sig_path.write_bytes(signature)
            result = subprocess.run([openssl, "dgst", "-sha256", "-verify", str(key), "-signature", str(sig_path), str(input_path)],
                                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15, check=False)
        require(result.returncode == 0, "untrusted_manifest_signature")
    except (ValueError, TypeError, OSError, subprocess.SubprocessError) as exc:
        raise UpgradeError("signature_verification_failed") from exc
    return manifest, digest


def fsync_directory(path):
    if os.name == "posix":
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def atomic_json(path, data):
    fd, temporary = tempfile.mkstemp(prefix=".intent-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(data, stream, separators=(",", ":"))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        fsync_directory(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class InstallLock:
    """Same inode and Linux flock protocol as update.sh/tools-only/restore."""
    def __init__(self, install_dir):
        self.path = Path(install_dir) / ".upgrade.lock"
        self.file = None

    def __enter__(self):
        require(not self.path.is_symlink(), "unsafe_lock_path")
        self.file = open(self.path, "a+b")
        try:
            if os.name == "posix":
                import fcntl
                fcntl.flock(self.file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            else:
                import msvcrt
                self.file.seek(0)
                if self.file.read(1) == b"":
                    self.file.write(b"\0")
                    self.file.flush()
                self.file.seek(0)
                msvcrt.locking(self.file.fileno(), msvcrt.LK_NBLCK, 1)
            os.chmod(self.path, 0o600)
        except OSError as exc:
            self.file.close()
            self.file = None
            raise UpgradeError("upgrade_lock_held") from exc
        return self

    def __exit__(self, *_):
        if self.file:
            self.file.close()


class Journal:
    """SQLite FULL commits preserve intent before the external side effect.

    A monotonic generation guards every write. It is a local fence only; no
    multi-host exclusion or production writer fence is inferred from it.
    """
    def __init__(self, install_dir, readonly=False):
        self.install_dir = Path(install_dir).resolve()
        self.directory = self.install_dir / ".upgrade"
        path = self.directory / "state.sqlite3"
        require(not self.directory.is_symlink() and not path.is_symlink(), "unsafe_checkpoint_path")
        if readonly:
            require(path.is_file(), "checkpoint_missing")
            self.db = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)
        else:
            self.directory.mkdir(mode=0o700, exist_ok=True)
            os.chmod(self.directory, 0o700)
            self.db = sqlite3.connect(path)
            os.chmod(path, 0o600)
            self.db.execute("PRAGMA synchronous=FULL")
            self.db.execute("PRAGMA journal_mode=DELETE")
            self.db.executescript("""
                CREATE TABLE IF NOT EXISTS meta (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL,
                    instance_id TEXT NOT NULL, generation INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS runs (release_id TEXT PRIMARY KEY, manifest_sha256 TEXT NOT NULL,
                    upgrade_id TEXT NOT NULL, status TEXT NOT NULL, fence INTEGER NOT NULL, next_step INTEGER NOT NULL,
                    source TEXT NOT NULL, backup TEXT NOT NULL, error_code TEXT, updated_at INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS steps (release_id TEXT NOT NULL, step TEXT NOT NULL, attempt INTEGER NOT NULL,
                    intent TEXT NOT NULL, result TEXT, fence INTEGER NOT NULL, updated_at INTEGER NOT NULL,
                    PRIMARY KEY(release_id,step));
            """)
            self.db.execute("INSERT OR IGNORE INTO meta VALUES(1,?,?,0)", (CHECKPOINT_VERSION, str(uuid.uuid4())))
            self.db.commit()
            fsync_directory(self.directory)
        try:
            self.db.row_factory = sqlite3.Row
            meta = self.db.execute("SELECT * FROM meta WHERE id=1").fetchone()
            require(meta and meta["version"] == CHECKPOINT_VERSION, "unsupported_checkpoint_version")
            require(self.db.execute("PRAGMA integrity_check").fetchone()[0] == "ok", "checkpoint_corrupt")
            self.instance_id = meta["instance_id"]
            self.token = None
        except BaseException:
            self.db.close()
            raise

    def close(self):
        self.db.close()

    def acquire_fence(self):
        with self.db:
            self.db.execute("UPDATE meta SET generation=generation+1 WHERE id=1")
            self.token = self.db.execute("SELECT generation FROM meta WHERE id=1").fetchone()[0]
        return self.token

    def assert_fence(self):
        require(self.token is not None and self.db.execute("SELECT generation FROM meta WHERE id=1").fetchone()[0] == self.token, "stale_executor_fence")

    def run(self, release):
        row = self.db.execute("SELECT * FROM runs WHERE release_id=?", (release,)).fetchone()
        return dict(row) if row else None

    def begin(self, manifest, digest, source, backup):
        self.assert_fence()
        release = manifest["release_id"]
        existing = self.run(release)
        require(not existing or existing["manifest_sha256"] == digest, "release_id_reused")
        marker = self.install_dir / ".upgrade-in-progress"
        if marker.exists():
            active = parse_json(read_regular(marker))
            shape(active, ("checkpoint_version", "release_id", "manifest_sha256", "instance_id", "fencing_token", "old_image_allowed"))
            require(existing is not None and active["release_id"] == release and active["manifest_sha256"] == digest
                    and active["instance_id"] == self.instance_id and active["old_image_allowed"] is False, "unknown_active_upgrade")
        other = self.db.execute("SELECT release_id FROM runs WHERE status != 'completed' AND release_id != ?", (release,)).fetchone()
        require(other is None, "another_upgrade_incomplete")
        with self.db:
            self.assert_fence()
            if not existing:
                self.db.execute("INSERT INTO runs VALUES(?,?,?,'checked',?,0,?,?,NULL,?)",
                                (release, digest, str(uuid.uuid4()), self.token, json.dumps(source, sort_keys=True), json.dumps(backup, sort_keys=True), int(time.time())))
            else:
                require(json.loads(existing["source"])["installation_id"] == source["installation_id"], "installation_changed")
                require(json.loads(existing["source"]) == source, "source_or_target_artifact_changed")
                require(json.loads(existing["backup"]) == backup, "backup_evidence_changed")
                self.db.execute("UPDATE runs SET fence=?,updated_at=? WHERE release_id=?", (self.token, int(time.time()), release))

    def status(self, release, status, error=None, next_step=None):
        with self.db:
            self.assert_fence()
            require(status in ("checked", "fenced", "backup_verified", "expanding", "backfilling", "verifying", "observing", "paused_failed", "recovering", "recovery_required", "completed"), "invalid_run_state")
            self.db.execute("UPDATE runs SET status=?,error_code=?,next_step=COALESCE(?,next_step),fence=?,updated_at=? WHERE release_id=?",
                            (status, error, next_step, self.token, int(time.time()), release))

    def step(self, release, step):
        row = self.db.execute("SELECT * FROM steps WHERE release_id=? AND step=?", (release, step)).fetchone()
        return dict(row) if row else None

    def intent(self, release, step, checkpoint):
        with self.db:
            self.assert_fence()
            previous = self.step(release, step)
            attempt = previous["attempt"] + 1 if previous else 1
            self.db.execute("INSERT OR REPLACE INTO steps VALUES(?,?,?,?,NULL,?,?)", (release, step, attempt,
                            json.dumps({"checkpoint": checkpoint, "fence": self.token}), self.token, int(time.time())))

    def result(self, release, step, observation):
        with self.db:
            self.assert_fence()
            self.db.execute("UPDATE steps SET result=?,fence=?,updated_at=? WHERE release_id=? AND step=?",
                            (json.dumps(observation, sort_keys=True), self.token, int(time.time()), release, step))

    def report(self, release):
        run = self.run(release)
        require(run is not None, "upgrade_not_found")
        require(run["status"] in ("checked", "fenced", "backup_verified", "expanding", "backfilling", "verifying", "observing", "paused_failed", "recovering", "recovery_required", "completed"), "unknown_checkpoint_state")
        run["source"], run["backup"] = json.loads(run["source"]), json.loads(run["backup"])
        run["instance_id"] = self.instance_id
        run["checkpoint_version"] = CHECKPOINT_VERSION
        run["steps"] = [dict(r) for r in self.db.execute("SELECT * FROM steps WHERE release_id=? ORDER BY rowid", (release,))]
        for item in run["steps"]:
            item["intent"] = json.loads(item["intent"])
            item["result"] = json.loads(item["result"]) if item["result"] else None
        return run


def validate_observation(value):
    shape(value, ("status", "checkpoint"), ("error_code",))
    require(value["status"] in ("not_started", "partial", "applied", "unknown", "failed"), "invalid_probe_result")
    require(value["checkpoint"] is None or type(value["checkpoint"]) is dict, "invalid_probe_checkpoint")
    if value["checkpoint"] is not None:
        shape(value["checkpoint"], (), ("cursor_user_id", "high_water_user_id", "cursor_order_id", "high_water_order_id", "cursor_plan_id", "high_water_plan_id", "processed_count", "next_cursor", "aggregate_type", "checked_count", "authority", "migration", "backup_id"))
        for key, item in value["checkpoint"].items():
            require(type(item) is str and len(item) <= 128, "invalid_probe_checkpoint_value")
            if key.endswith("id") or key.endswith("count") or key == "next_cursor":
                if key != "backup_id":
                    require(DECIMAL.fullmatch(item), "invalid_probe_decimal")
    if "error_code" in value:
        identifier(value["error_code"])
    return value


class Runner:
    def __init__(self, journal, backend, manifest, digest, max_batches=1000, hook=None):
        self.journal, self.backend, self.manifest, self.digest = journal, backend, manifest, digest
        self.release = manifest["release_id"]
        self.max_batches = max_batches
        self.hook = hook or (lambda *_: None)

    def checkpoint_marker(self):
        atomic_json(self.journal.install_dir / ".upgrade-in-progress", {
            "checkpoint_version": CHECKPOINT_VERSION, "release_id": self.release,
            "manifest_sha256": self.digest, "instance_id": self.journal.instance_id,
            "fencing_token": self.journal.token, "old_image_allowed": False,
        })

    def execute(self, recover=False):
        self.journal.acquire_fence()
        source, backup = self.backend.check(self.manifest, recovering=recover)
        self.journal.begin(self.manifest, self.digest, source, backup)
        state = self.journal.report(self.release)
        if state["status"] == "completed":
            require(recover, "upgrade_already_completed")
            # A completed rehearsal is rechecked through every probe, including
            # a fresh read-only reconciliation. It never starts a binary.
        require(recover or not state["steps"], "recovery_command_required")
        self.checkpoint_marker()
        self.journal.status(self.release, "recovering" if recover else "fenced")
        self.journal.status(self.release, "backup_verified")
        try:
            for index, migration in enumerate(self.manifest["migrations"]):
                self.journal.status(self.release, {"expand": "expanding", "backfill": "backfilling", "verify": "verifying"}[migration["phase"]], next_step=index)
                self.execute_step(migration)
            self.journal.status(self.release, "observing", next_step=3)
            observe = {PROFILE: "subscription-shadow-observe-v1", CATALOG_PROFILE: "plan-catalog-shadow-observe-v1",
                COMMERCE_PROFILE: "commerce-shadow-observe-v1"}[self.manifest["profile"]]
            self.execute_step({"id": observe, "phase": "observe", "recovery": "read_only_repeat"})
            self.journal.status(self.release, "completed", next_step=4)
            self.journal.assert_fence()
            # The profile explicitly forbids starting an old image after DDL.
            # A successful shadow rehearsal does not prove binary compatibility;
            # preserve the guard and keep the isolated copy stopped.
            self.checkpoint_marker()
            return self.journal.report(self.release)
        except UpgradeError as exc:
            self.journal.status(self.release, "recovery_required" if exc.code in ("unknown_step_result", "completed_step_drift") else "paused_failed", exc.code)
            raise

    def execute_step(self, migration):
        step = migration["id"]
        previous = self.journal.step(self.release, step)
        for _ in range(self.max_batches):
            self.journal.assert_fence()
            observation = validate_observation(self.backend.probe(step))
            if observation["status"] in ("unknown", "failed"):
                raise UpgradeError(observation.get("error_code", "unknown_step_result" if observation["status"] == "unknown" else "verification_failed"))
            if previous and previous["result"]:
                old = parse_json(previous["result"].encode("utf-8"))
                require(migration["recovery"] == "read_only_repeat" or old["status"] != "applied" or observation["status"] == "applied", "completed_step_drift")
            if observation["status"] == "applied":
                if not previous:
                    self.journal.intent(self.release, step, observation["checkpoint"])
                self.journal.result(self.release, step, observation)
                return
            require(observation["status"] != "partial" or migration["recovery"] in ("resume_cursor", "read_only_repeat"), "partial_ddl_requires_investigation")
            self.journal.intent(self.release, step, observation["checkpoint"])
            self.hook("after_intent", step)
            self.journal.assert_fence()
            self.backend.perform(step, self.journal.token, observation["checkpoint"])
            self.hook("after_side_effect", step)
            self.journal.assert_fence()
            after = validate_observation(self.backend.probe(step))
            self.journal.result(self.release, step, after)
            self.hook("after_result", step)
            require(after["status"] in ("partial", "applied"), after.get("error_code", "unknown_step_result" if after["status"] == "unknown" else "step_did_not_progress"))
            if after["status"] == "applied":
                return
            require(after != observation, "step_did_not_progress")
            previous = self.journal.step(self.release, step)
        raise UpgradeError("batch_budget_exhausted")


def backup_check(directory, evidence_path, manifest_sha256):
    """Verify bytes locally; rehearsal/coverage remain separately identified operator attestations."""
    require(not Path(directory).is_symlink(), "unsafe_backup_path")
    directory = Path(directory).resolve()
    evidence = parse_json(read_regular(evidence_path))
    shape(evidence, ("evidence_version", "backup_id", "manifest_sha256", "datasets", "rehearsal", "recovery_coverage"))
    require(evidence["evidence_version"] == "txboard.backup-evidence/v1" and evidence["manifest_sha256"] == manifest_sha256, "backup_evidence_binding_mismatch")
    identifier(evidence["backup_id"])
    require(evidence["backup_id"] == directory.name, "backup_id_mismatch")
    shape(evidence["datasets"], BACKUP_DATASETS)
    checksums = {}
    for line in read_regular(directory / "CHECKSUMS.sha256").decode("utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64}) [ *]([A-Za-z0-9][A-Za-z0-9._-]*)", line)
        require(match and match[2] not in checksums, "invalid_backup_checksum_list")
        checksums[match[2]] = match[1]
    require({"env", "db.sql.gz", "deploy.env", "compose.yaml"} <= checksums.keys(), "incomplete_backup_files")
    for name, digest in checksums.items():
        require(hash_regular(directory / name) == digest, "backup_checksum_mismatch")
        if name.endswith(".gz"):
            try:
                with gzip.open(directory / name, "rb") as stream:
                    while stream.read(1024 * 1024):
                        pass
            except (OSError, EOFError) as exc:
                raise UpgradeError("invalid_backup_gzip") from exc
    require(re.search(rb"^APP_KEY=.+$", read_regular(directory / "env"), re.M), "backup_key_material_missing")
    for name, files in evidence["datasets"].items():
        require(type(files) is list, "invalid_backup_dataset")
        # Empty plugin-private-data is allowed only when the operator records no installed provider.
        require(files or name == "plugin-private-data", "missing_backup_dataset")
        require(all(type(f) is str and f in checksums for f in files), "unverified_backup_dataset")
    require(evidence["datasets"]["mysql"] == ["db.sql.gz"] and "env" in evidence["datasets"]["core-key-material"], "invalid_backup_dataset_mapping")
    rehearsal = evidence["rehearsal"]
    shape(rehearsal, ("passed", "report_file", "backup_checksum"))
    coverage = evidence["recovery_coverage"]
    shape(coverage, ("passed", "report_file", "receipt_generation", "revocation_version", "post_backup_changes"))
    require(rehearsal["passed"] is True and coverage["passed"] is True, "restore_evidence_required")
    for report in (rehearsal["report_file"], coverage["report_file"]):
        require(type(report) is str and report in checksums, "unverified_recovery_report")
    checksum = hashlib.sha256(read_regular(directory / "CHECKSUMS.sha256")).hexdigest()
    # Bind rehearsal to the database archive digest, avoiding self-referential checksum lists.
    require(rehearsal["backup_checksum"] == checksums["db.sql.gz"], "rehearsal_backup_mismatch")
    for name in ("receipt_generation", "revocation_version"):
        require(type(coverage[name]) is str and DECIMAL.fullmatch(coverage[name]), "invalid_recovery_generation")
    require(coverage["post_backup_changes"] == "none-isolated-copy", "post_backup_changes_uncovered")
    return {"backup_id": directory.name, "checksum": checksum, "evidence_sha256": hashlib.sha256(read_regular(evidence_path)).hexdigest(),
            "rehearsal": "operator-attested", "recovery_coverage": "operator-attested-isolated-copy"}


def verify_deploy_bundle(path, manifest):
    require(path is not None, "deploy_bundle_required")
    raw = read_regular(path, 64 * 1024 * 1024)
    require(hashlib.sha256(raw).hexdigest() == manifest["components"]["deploy"].get("archive_sha256"), "deploy_bundle_digest_mismatch")
    root = Path(__file__).resolve().parent.parent
    try:
        with tarfile.open(path, "r:gz") as archive:
            members = archive.getmembers()
            require(len(members) <= 512 and len({m.name for m in members}) == len(members), "invalid_deploy_bundle")
            for member in members:
                require(not member.issym() and not member.islnk() and (member.isfile() or member.isdir())
                        and not member.name.startswith("/") and ".." not in Path(member.name).parts, "unsafe_deploy_bundle_member")
            for filename in ("scripts/upgrade.py", "lib/detect.sh"):
                member = archive.getmember(filename)
                require(member.isfile() and member.size <= 1024 * 1024, "invalid_deploy_bundle_runtime")
                with archive.extractfile(member) as stream:
                    require(stream.read() == read_regular(root / filename), "installed_deploy_runtime_mismatch")
    except (tarfile.TarError, KeyError, OSError) as exc:
        raise UpgradeError("invalid_deploy_bundle") from exc


class DockerShadowBackend:
    """Fixed Artisan adapter, restricted to an explicitly isolated local/testing database."""
    def __init__(self, install_dir, backup_dir, evidence_path, digest, manifest, deploy_bundle=None):
        self.install_dir = Path(install_dir).resolve()
        self.backup_dir, self.evidence_path, self.digest = backup_dir, evidence_path, digest
        self.manifest = manifest
        self.deploy_bundle = deploy_bundle
        self.run_key = manifest["release_id"]
        self.verified = False
        self.verify_cursor = "0"
        self.verify_count = 0
        self.verify_aggregate = "user"
        self.verify_context = None

    def command(self, args, input_bytes=None):
        try:
            result = subprocess.run(args, cwd=self.install_dir, input=input_bytes, stdin=subprocess.DEVNULL if input_bytes is None else None,
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=120, check=False)
        except (OSError, subprocess.SubprocessError) as exc:
            raise UpgradeError("runtime_command_unavailable") from exc
        require(result.returncode == 0, "runtime_command_failed")
        require(len(result.stdout) <= 1024 * 1024, "runtime_response_too_large")
        return result.stdout

    def sql(self, query):
        return self.command(["docker", "compose", "run", "-T", "--rm", "--no-deps", "--entrypoint", "sh", "backup", "-ec",
                             'MYSQL_PWD="$DB_PASSWORD" exec mysql --batch --skip-column-names --connect-timeout=10 --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USERNAME" --database="$DB_DATABASE" --execute="$1"', "sh", query]).decode("utf-8").strip()

    def artisan(self, *args):
        artifact = self.manifest["components"]["core"]["artifact"]
        # docker compose run --no-deps with explicit image via environment avoids editing .env.
        env = os.environ.copy()
        env["TXBOARD_IMAGE"] = artifact
        command = ["docker", "compose", "run", "-T", "--rm", "--no-deps", "-e", "CACHE_DRIVER=array", "-e", "SETTING_CACHE_STORE=array",
                   "-e", "QUEUE_CONNECTION=sync", "-e", "SESSION_DRIVER=array", "--entrypoint", "php", "txboard", "/www/artisan", *args, "--no-interaction"]
        try:
            result = subprocess.run(command, cwd=self.install_dir, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, timeout=120, check=False)
        except (OSError, subprocess.SubprocessError) as exc:
            raise UpgradeError("runtime_command_unavailable") from exc
        require(result.returncode == 0 and len(result.stdout) <= 1024 * 1024, "core_command_failed")
        return result.stdout

    def check(self, manifest, recovering=False):
        require(os.name == "posix", "docker_profile_requires_linux")
        verify_deploy_bundle(self.deploy_bundle, manifest)
        for name in ("compose.yaml", ".env", "api.env"):
            read_regular(self.install_dir / name)
        env = read_regular(self.install_dir / "api.env")
        require(re.search(rb"^CORE_SHADOW_ISOLATED_COPY=(?:true|1)$", env, re.M) and re.search(rb"^APP_ENV=(?:testing|local)$", env, re.M), "isolated_copy_marker_required")
        self.command(["docker", "compose", "version"])
        self.command(["docker", "info", "--format", "{{.ID}}"])
        # Reuse the existing ownership guard instead of relying on a service name.
        module = Path(__file__).resolve().parent.parent / "lib" / "detect.sh"
        require(module.is_file(), "service_discovery_module_missing")
        identity = self.command(["bash", "-c", 'source "$1"; txboard_detect_scan "$2" >/dev/null || exit 1; (( TXBOARD_DETECT_TARGET_COUNT == 1 && TXBOARD_DETECT_FOREIGN_COUNT == 0 )) || exit 1; [[ "$TXBOARD_DETECT_TARGET_STATE" == exited ]] || exit 1; cid=$(cd "$2" && docker compose ps -a -q txboard) || exit 1; [[ -n "$cid" && "${TXBOARD_DETECT_TARGET_ID:0:${#cid}}" == "$cid" ]] || exit 1; printf "%s\\n" "$TXBOARD_DETECT_TARGET_ID"', "txboard-upgrade", str(module), str(self.install_dir)]).decode().strip()
        require(identity, "container_identity_missing")
        info = parse_json(self.command(["docker", "inspect", identity]))
        require(type(info) is list and len(info) == 1, "ambiguous_container_identity")
        require(info[0]["State"]["Status"] == "exited", "isolated_writers_must_be_stopped")
        require(self.command(["docker", "compose", "ps", "--status", "running", "-q", "backup"]).strip() == b"", "rolling_backup_must_be_stopped")
        inventory = self.sql("SELECT SUM(LEFT(TABLE_NAME,3)='v2_'),SUM(TABLE_NAME='tx_user'),SUM(TABLE_NAME='tx_order'),SUM(TABLE_NAME='tx_settings'),SUM(TABLE_NAME='migrations') FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_TYPE='BASE TABLE'")
        require(inventory.split() == ["0", "1", "1", "1", "1"], "non_native_or_incomplete_database")
        artifact = manifest["components"]["core"]["artifact"]
        target = parse_json(self.command(["docker", "image", "inspect", artifact]))
        require(type(target) is list and len(target) == 1 and artifact in target[0].get("RepoDigests", []), "target_artifact_not_verified_locally")
        # Compose may use a hardcoded image instead of TXBOARD_IMAGE. Check its
        # actual rendered service before permitting the fixed Artisan adapter.
        env_override = os.environ.copy()
        env_override["TXBOARD_IMAGE"] = artifact
        try:
            rendered = subprocess.run(["docker", "compose", "config", "--format", "json"], cwd=self.install_dir, env=env_override,
                                      stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30, check=False)
        except (OSError, subprocess.SubprocessError) as exc:
            raise UpgradeError("compose_render_failed") from exc
        require(rendered.returncode == 0, "compose_render_failed")
        config = parse_json(rendered.stdout)
        require(config.get("services", {}).get("txboard", {}).get("image") == artifact, "compose_does_not_use_pinned_target")
        commands = self.artisan("list", "--raw").decode()
        required_commands = {PROFILE: ("core:subscriptions-backfill", "core:subscriptions-reconcile"),
            CATALOG_PROFILE: ("core:catalog-shadow",), COMMERCE_PROFILE: ("core:commerce-shadow",)}[manifest["profile"]]
        require(all(command in commands for command in required_commands), "core_shadow_commands_missing")
        self.backup = backup_check(self.backup_dir, self.evidence_path, self.digest)
        return {"installation_id": hashlib.sha256(str(self.install_dir).encode()).hexdigest(), "container_id": identity,
                "source_image_id": info[0]["Image"], "target_image_id": target[0]["Id"], "target_digest": artifact,
                "deployment_config_sha256": hashlib.sha256(b"\0".join(read_regular(self.install_dir / name) for name in ("api.env", ".env", "compose.yaml"))).hexdigest(),
                "schema_epoch": "1", "authority": "legacy", "runtime_profile": manifest["profile"]}, self.backup

    def progress(self):
        # The reconciliation command is read-only. A missing run is an explicit
        # not-started condition; other runtime failures never imply that state.
        conflicts = self.sql("SELECT (SELECT COUNT(*) FROM tx_legacy_subscription_map WHERE run_key='" + self.run_key + "' AND state='source_changed')+(SELECT COUNT(*) FROM tx_legacy_subscription_exception WHERE run_key='" + self.run_key + "' AND state='unresolved')")
        require(conflicts == "0", "core_shadow_source_conflict")
        rows = self.sql("SELECT phase,cursor_user_id,high_water_user_id,processed_count FROM tx_migration_checkpoint WHERE run_key='" + self.run_key + "'")
        if not rows:
            return None
        phase, cursor, highwater, count = rows.split()
        require(all(DECIMAL.fullmatch(v) for v in (cursor, highwater, count)), "invalid_core_checkpoint")
        return phase, {"cursor_user_id": cursor, "high_water_user_id": highwater, "processed_count": count}

    def catalog_progress(self):
        conflicts = self.sql("SELECT COUNT(*) FROM tx_plan_catalog_exception WHERE legacy_plan_id <= (SELECT high_water_plan_id FROM tx_plan_catalog_checkpoint WHERE run_key='" + self.run_key + "') AND state='unresolved'")
        require(conflicts == "0", "core_catalog_source_conflict")
        rows = self.sql("SELECT phase,cursor_plan_id,high_water_plan_id,processed_count FROM tx_plan_catalog_checkpoint WHERE run_key='" + self.run_key + "'")
        if not rows:
            return None
        phase, cursor, highwater, count = rows.split()
        require(phase in ("processing", "complete") and all(DECIMAL.fullmatch(v) for v in (cursor, highwater, count)), "invalid_core_catalog_checkpoint")
        require(int(cursor) <= int(highwater), "invalid_core_catalog_checkpoint")
        return phase, {"cursor_plan_id": cursor, "high_water_plan_id": highwater, "processed_count": count}

    def probe(self, step):
        if step in COMMERCE_MIGRATIONS or step == "commerce-shadow-observe-v1":
            require(self.manifest["profile"] == COMMERCE_PROFILE, "unknown_migration_id")
            return self.commerce_probe(step)
        if step in CATALOG_MIGRATIONS or step == "plan-catalog-shadow-observe-v1":
            require(self.manifest["profile"] == CATALOG_PROFILE, "unknown_migration_id")
            return self.catalog_probe(step)
        require(self.manifest["profile"] == PROFILE, "unknown_migration_id")
        if step == "subscription-shadow-expand-v1":
            rows = self.sql("SELECT migration FROM migrations WHERE migration='" + MIGRATION_FILE + "'")
            if rows == MIGRATION_FILE:
                tables = self.sql("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME IN ('tx_migration_checkpoint','tx_subscription','tx_subscription_terms','tx_subscription_terms_transition','tx_subscription_slot','tx_usage_period','tx_usage_adjustment','tx_access_subject','tx_legacy_subscription_map','tx_legacy_subscription_exception')")
                indexes = self.sql("SELECT COUNT(DISTINCT INDEX_NAME) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND INDEX_NAME IN ('tx_sub_owner_uq','tx_terms_version_uq','tx_terms_owner_uq','tx_slot_capacity_uq','tx_slot_sub_uq','tx_period_number_uq','tx_legacy_map_user_uq','tx_legacy_map_key_uq') AND NON_UNIQUE=0")
                require(tables == "10" and indexes == "8", "shadow_schema_shape_mismatch")
                return {"status": "applied", "checkpoint": {"migration": MIGRATION_FILE}}
            # A committed table with missing migration history is ambiguous DDL,
            # not permission to rerun a migration with implicit commits.
            partial = self.sql("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME IN ('tx_migration_checkpoint','tx_subscription','tx_subscription_terms','tx_subscription_terms_transition','tx_subscription_slot','tx_usage_period','tx_usage_adjustment','tx_access_subject','tx_legacy_subscription_map','tx_legacy_subscription_exception')")
            return {"status": "not_started" if partial == "0" else "unknown", "checkpoint": None}
        if step == "subscription-shadow-backfill-v1":
            result = self.progress()
            if result is None:
                return {"status": "not_started", "checkpoint": None}
            phase, checkpoint = result
            require(phase in ("backfilling", "backfilled", "blocked"), "unknown_core_shadow_phase")
            return {"status": "failed" if phase == "blocked" else "applied" if phase == "backfilled" else "partial", "checkpoint": checkpoint,
                    **({"error_code": "core_shadow_source_conflict"} if phase == "blocked" else {})}
        if step in ("subscription-shadow-verify-v1", "subscription-shadow-observe-v1"):
            if step.endswith("observe-v1"):
                require(self.verified, "reconciliation_required")
                return {"status": "applied", "checkpoint": {"authority": "legacy", "checked_count": str(self.verify_count)}}
            return {"status": "applied" if self.verified else "partial" if self.verify_cursor != "0" else "not_started",
                    "checkpoint": {"next_cursor": self.verify_cursor, "checked_count": str(self.verify_count), "authority": "legacy"}}
        raise UpgradeError("unknown_migration_id")

    def catalog_probe(self, step):
        if step == "plan-catalog-shadow-expand-v1":
            tables = self.sql("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME IN ('" + "','".join(CATALOG_TABLES) + "')")
            history = self.sql("SELECT migration FROM migrations WHERE migration='" + CATALOG_MIGRATION_FILE + "'")
            if history == CATALOG_MIGRATION_FILE:
                indexes = self.sql("SELECT COUNT(DISTINCT INDEX_NAME) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND INDEX_NAME IN ('" + "','".join(CATALOG_INDEXES) + "') AND NON_UNIQUE=0")
                require(tables == str(len(CATALOG_TABLES)) and indexes == str(len(CATALOG_INDEXES)), "catalog_schema_shape_mismatch")
                return {"status": "applied", "checkpoint": {"migration": CATALOG_MIGRATION_FILE}}
            return {"status": "not_started" if tables == "0" else "unknown", "checkpoint": None}
        if step == "plan-catalog-shadow-backfill-v1":
            result = self.catalog_progress()
            if result is None: return {"status": "not_started", "checkpoint": None}
            phase, checkpoint = result
            return {"status": "applied" if phase == "complete" else "partial", "checkpoint": checkpoint}
        if step == "plan-catalog-shadow-observe-v1":
            require(self.verified, "reconciliation_required")
            return {"status": "applied", "checkpoint": {"authority": "legacy", "checked_count": str(self.verify_count)}}
        return {"status": "applied" if self.verified else "partial" if self.verify_cursor != "0" else "not_started",
                "checkpoint": {"next_cursor": self.verify_cursor, "checked_count": str(self.verify_count), "authority": "legacy"}}

    def perform(self, step, fence, checkpoint):
        if step in COMMERCE_MIGRATIONS:
            require(self.manifest["profile"] == COMMERCE_PROFILE, "unsupported_runtime_action")
            return self.commerce_perform(step)
        if step in CATALOG_MIGRATIONS:
            require(self.manifest["profile"] == CATALOG_PROFILE, "unsupported_runtime_action")
            return self.catalog_perform(step)
        require(self.manifest["profile"] == PROFILE, "unsupported_runtime_action")
        if step == "subscription-shadow-expand-v1":
            self.artisan("migrate", "--force", "--path=database/migrations/" + MIGRATION_FILE + ".php")
        elif step == "subscription-shadow-backfill-v1":
            result = parse_json(self.artisan("core:subscriptions-backfill", "--run=" + self.run_key, "--limit=1000",
                                            "--billing-timezone=" + self.manifest["billing"]["billing_timezone"], "--currency=" + self.manifest["billing"]["currency"], "--isolated-copy"))
            require(type(result) is dict and result.get("run_key") == self.run_key and type(result.get("results")) is list, "invalid_core_backfill_response")
            require(not any(row.get("status") in ("source_changed", "exception") for row in result["results"]), "core_shadow_source_conflict")
        elif step == "subscription-shadow-verify-v1":
            # Repeat read-only reconciliation from zero after a process restart;
            # never trust an earlier aggregate or in-memory successful page.
            result = parse_json(self.artisan("core:subscriptions-reconcile", "--run=" + self.run_key, "--limit=1000", "--after-id=" + self.verify_cursor, "--json"))
            require(type(result) is dict and result.get("run_key") == self.run_key and result.get("authority") == "legacy", "invalid_core_reconcile_response")
            require(result.get("passed") is True and result.get("differences") == [], "reconciliation_failed")
            require(type(result.get("complete")) is bool and type(result.get("next_cursor")) is str and DECIMAL.fullmatch(result["next_cursor"]) and type(result.get("checked_count")) is str and DECIMAL.fullmatch(result["checked_count"]), "invalid_core_reconcile_cursor")
            self.verify_cursor = result["next_cursor"]
            self.verify_count += int(result["checked_count"])
            self.verified = result["complete"]
        else:
            raise UpgradeError("unsupported_runtime_action")

    def commerce_progress(self):
        require(self.sql("SELECT COUNT(*) FROM tx_commerce_shadow_exception WHERE state='unresolved'") == "0", "core_commerce_source_conflict")
        rows = self.sql("SELECT phase,cursor_user_id,cursor_order_id,high_water_user_id,high_water_order_id,processed_count FROM tx_commerce_shadow_checkpoint WHERE run_key='" + self.run_key + "'")
        if not rows:
            return None
        fields = rows.split()
        require(len(fields) == 6 and fields[0] in ("processing", "complete") and all(DECIMAL.fullmatch(value) for value in fields[1:]), "invalid_core_commerce_checkpoint")
        phase, user_cursor, order_cursor, user_high, order_high, count = fields
        require(int(user_cursor) <= int(user_high) and int(order_cursor) <= int(order_high), "invalid_core_commerce_checkpoint")
        return phase, {"cursor_user_id": user_cursor, "cursor_order_id": order_cursor,
            "high_water_user_id": user_high, "high_water_order_id": order_high, "processed_count": count}

    def commerce_probe(self, step):
        if step == "commerce-shadow-expand-v1":
            tables = self.sql("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME IN ('" + "','".join(COMMERCE_TABLES) + "')")
            history = self.sql("SELECT migration FROM migrations WHERE migration='" + COMMERCE_MIGRATION_FILE + "'")
            if history == COMMERCE_MIGRATION_FILE:
                indexes = self.sql("SELECT COUNT(DISTINCT INDEX_NAME) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND INDEX_NAME IN ('" + "','".join(COMMERCE_INDEXES) + "') AND NON_UNIQUE=0")
                require(tables == str(len(COMMERCE_TABLES)) and indexes == str(len(COMMERCE_INDEXES)), "commerce_schema_shape_mismatch")
                return {"status": "applied", "checkpoint": {"migration": COMMERCE_MIGRATION_FILE}}
            return {"status": "not_started" if tables == "0" else "unknown", "checkpoint": None}
        if step == "commerce-shadow-backfill-v1":
            progress = self.commerce_progress()
            if progress is None: return {"status": "not_started", "checkpoint": None}
            phase, checkpoint = progress
            return {"status": "applied" if phase == "complete" else "partial", "checkpoint": checkpoint}
        if step == "commerce-shadow-observe-v1":
            require(self.verified, "reconciliation_required")
            return {"status": "applied", "checkpoint": {"authority": "legacy", "checked_count": str(self.verify_count)}}
        return {"status": "applied" if self.verified else "partial" if self.verify_count else "not_started",
            "checkpoint": {"next_cursor": self.verify_cursor, "aggregate_type": self.verify_aggregate,
                "checked_count": str(self.verify_count), "authority": "legacy"}}

    def commerce_perform(self, step):
        if step == "commerce-shadow-expand-v1":
            self.artisan("migrate", "--force", "--path=database/migrations/" + COMMERCE_MIGRATION_FILE + ".php")
        elif step == "commerce-shadow-backfill-v1":
            result = parse_json(self.artisan("core:commerce-shadow", "--run=" + self.run_key, "--snapshot=" + self.run_key,
                "--currency=" + self.manifest["billing"]["currency"], "--limit=1000", "--isolated-copy"))
            require(type(result) is dict and result.get("run_key") == self.run_key and result.get("mode") == "isolated_shadow"
                and result.get("legacy_authority") == "retained" and type(result.get("results")) is list, "invalid_core_commerce_response")
            require(result.get("unresolved_count") == "0" and all(type(row) is dict and row.get("status") in ("mapped", "unchanged") for row in result["results"]), "core_commerce_source_conflict")
        elif step == "commerce-shadow-verify-v1":
            result = parse_json(self.artisan("core:commerce-shadow", "--run=" + self.run_key, "--reconcile=" + self.verify_aggregate,
                "--snapshot=" + self.run_key, "--currency=" + self.manifest["billing"]["currency"],
                "--cursor=" + self.verify_cursor, "--limit=1000", "--isolated-copy"))
            require(type(result) is dict and result.get("run_key") == self.run_key and result.get("mode") == "isolated_shadow"
                and result.get("legacy_authority") == "retained" and result.get("aggregate_type") == self.verify_aggregate
                and result.get("read_only") is True and result.get("scope") == "current-user-order-evidence", "invalid_core_commerce_reconcile_response")
            require(result.get("snapshot_key") == self.run_key and result.get("currency") == self.manifest["billing"]["currency"], "core_commerce_context_changed")
            require(result.get("run_phase") == "complete" and type(result.get("context_hash")) is str and SHA.fullmatch(result["context_hash"])
                and all(type(result.get(key)) is str and DECIMAL.fullmatch(result[key]) for key in
                    ("checkpoint_version", "high_water_user_id", "high_water_order_id", "source_high_water_user_id", "source_high_water_order_id")), "invalid_core_commerce_reconcile_response")
            context = tuple(result[key] for key in ("context_hash", "checkpoint_version", "high_water_user_id", "high_water_order_id"))
            require(self.verify_context is None or context == self.verify_context, "core_commerce_context_changed")
            require(int(result["source_high_water_user_id"]) <= int(result["high_water_user_id"])
                and int(result["source_high_water_order_id"]) <= int(result["high_water_order_id"]), "reconciliation_failed")
            require(result.get("page_ok") is True and result.get("global_issues") == [] and result.get("difference_count") == "0"
                and result.get("unresolved_count") == "0", "reconciliation_failed")
            require(type(result.get("has_more")) is bool and result.get("after_cursor") == self.verify_cursor
                and all(type(result.get(key)) is str and DECIMAL.fullmatch(result[key]) for key in ("cursor", "checked_count", "high_water_id")), "invalid_core_reconcile_cursor")
            require(int(result["cursor"]) >= int(self.verify_cursor) and int(result["checked_count"]) <= 1000
                and int(result["cursor"]) <= int(result["high_water_id"])
                and (not result["has_more"] or int(result["cursor"]) > int(self.verify_cursor)), "invalid_core_reconcile_cursor")
            require(type(result.get("results")) is list and len(result["results"]) == int(result["checked_count"])
                and all(type(row) is dict and row.get("status") == "match" and row.get("differences") == []
                    and row.get("aggregate_type") == self.verify_aggregate for row in result["results"]), "reconciliation_failed")
            previous_id = int(self.verify_cursor)
            for row in result["results"]:
                row_id = row.get("legacy_id")
                require(type(row_id) is str and DECIMAL.fullmatch(row_id) and previous_id < int(row_id) <= int(result["cursor"]), "invalid_core_reconcile_cursor")
                previous_id = int(row_id)
            require(previous_id == int(result["cursor"]), "invalid_core_reconcile_cursor")
            self.verify_count += int(result["checked_count"])
            self.verify_context = context
            self.verify_cursor = result["cursor"]
            if not result["has_more"]:
                if self.verify_aggregate == "user":
                    self.verify_aggregate, self.verify_cursor = "order", "0"
                else:
                    self.verified = True
        else:
            raise UpgradeError("unsupported_runtime_action")

    def catalog_perform(self, step):
        if step == "plan-catalog-shadow-expand-v1":
            self.artisan("migrate", "--force", "--path=database/migrations/" + CATALOG_MIGRATION_FILE + ".php")
        elif step == "plan-catalog-shadow-backfill-v1":
            result = parse_json(self.artisan("core:catalog-shadow", "--run=" + self.run_key, "--limit=1000",
                "--billing-timezone=" + self.manifest["billing"]["billing_timezone"], "--currency=" + self.manifest["billing"]["currency"], "--isolated-copy"))
            require(type(result) is dict and result.get("run_key") == self.run_key and type(result.get("results")) is list, "invalid_core_catalog_response")
            require(result.get("unresolved_count") == "0" and all(type(row) is dict and row.get("status") in ("mapped", "unchanged", "revised") for row in result["results"]), "core_catalog_source_conflict")
        elif step == "plan-catalog-shadow-verify-v1":
            result = parse_json(self.artisan("core:catalog-shadow", "--isolated-copy", "--reconcile", "--run=" + self.run_key, "--limit=1000", "--after-id=" + self.verify_cursor))
            require(type(result) is dict and result.get("run_key") == self.run_key and result.get("scope") == "current-pointer-and-offers" and result.get("read_only") is True, "invalid_core_catalog_reconcile_response")
            require(result.get("page_ok") is True and result.get("global_issues") == [] and result.get("mismatch_count") == "0" and result.get("unresolved_count") == "0", "reconciliation_failed")
            require(type(result.get("has_more")) is bool and result.get("after_id") == self.verify_cursor
                and type(result.get("next_after_id")) is str and DECIMAL.fullmatch(result["next_after_id"])
                and type(result.get("checked_count")) is str and DECIMAL.fullmatch(result["checked_count"])
                and type(result.get("high_water_plan_id")) is str and DECIMAL.fullmatch(result["high_water_plan_id"])
                and type(result.get("source_high_water_plan_id")) is str and DECIMAL.fullmatch(result["source_high_water_plan_id"]), "invalid_core_reconcile_cursor")
            require(int(result["next_after_id"]) >= int(self.verify_cursor)
                and int(result["next_after_id"]) <= int(result["high_water_plan_id"])
                and int(result["source_high_water_plan_id"]) <= int(result["high_water_plan_id"])
                and int(result["checked_count"]) <= 1000
                and (not result["has_more"] or int(result["next_after_id"]) > int(self.verify_cursor)), "invalid_core_reconcile_cursor")
            require(type(result.get("results")) is list and len(result["results"]) == int(result["checked_count"])
                and all(type(row) is dict and row.get("ok") is True and row.get("issues") == [] for row in result["results"]), "reconciliation_failed")
            previous_id = int(self.verify_cursor)
            for row in result["results"]:
                row_id = row.get("legacy_plan_id")
                require(type(row_id) is str and DECIMAL.fullmatch(row_id)
                    and previous_id < int(row_id) <= int(result["next_after_id"]), "invalid_core_reconcile_cursor")
                previous_id = int(row_id)
            require(previous_id == int(result["next_after_id"]), "invalid_core_reconcile_cursor")
            self.verify_cursor = result["next_after_id"]
            self.verify_count += int(result["checked_count"])
            self.verified = not result["has_more"]
        else:
            raise UpgradeError("unsupported_runtime_action")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "check", "apply", "status", "recover", "restore-check"))
    parser.add_argument("--dir", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--signature", required=True, type=Path)
    parser.add_argument("--trust-dir", required=True, type=Path)
    parser.add_argument("--backup", type=Path)
    parser.add_argument("--backup-evidence", type=Path)
    parser.add_argument("--deploy-bundle", type=Path)
    parser.add_argument("--max-batches", type=int, default=1000)
    args = parser.parse_args(argv)
    manifest, digest = load_signed_manifest(args.manifest, args.signature, args.trust_dir)
    require(args.dir.is_dir() and not args.dir.is_symlink(), "installation_directory_required")
    require(1 <= args.max_batches <= 100000, "invalid_batch_budget")
    if args.command == "plan":
        return {"release_id": manifest["release_id"], "manifest_sha256": digest, "profile": manifest["profile"],
                "phases": list(PHASES), "authority": "legacy", "deployment_validation": "not_performed",
                "requirements": ["stopped isolated Linux copy", "locally verified pinned Core image", "complete checksummed backup", "operator restore/receipt coverage attestations"],
                "unsupported": ["production cutover", "cluster execution", "binary rollback", "automatic database restore", "contract deletion"]}
    if args.command == "status":
        journal = Journal(args.dir, readonly=True)
        try:
            report = journal.report(manifest["release_id"])
            require(report["manifest_sha256"] == digest, "manifest_digest_mismatch")
            report["runtime_observation"] = "not_performed"
            report["binary_start_allowed"] = False
            return report
        finally:
            journal.close()
    require(args.backup is not None and args.backup_evidence is not None, "backup_and_evidence_required")
    if args.command == "restore-check":
        return {"backup": backup_check(args.backup, args.backup_evidence, digest), "restore_executed": False,
                "boundary": "isolated-copy only; production increments require external payment/receipt/revocation reconciliation"}
    backend = DockerShadowBackend(args.dir, args.backup, args.backup_evidence, digest, manifest, args.deploy_bundle)
    if args.command == "check":
        source, backup = backend.check(manifest)
        return {"source": source, "backup": backup, "manifest_sha256": digest, "mutation_performed": False}
    with InstallLock(args.dir):
        journal = Journal(args.dir)
        try:
            return Runner(journal, backend, manifest, digest, args.max_batches).execute(recover=args.command == "recover")
        finally:
            journal.close()


if __name__ == "__main__":
    try:
        print(json.dumps(main(), ensure_ascii=False, indent=2))
    except (UpgradeError, sqlite3.Error, OSError, KeyError) as exc:
        # Runtime stderr/SQL/credential-bearing environment values are never logged.
        print(json.dumps({"error_code": exc.code if isinstance(exc, UpgradeError) else "checkpoint_or_runtime_failure"}), file=sys.stderr)
        sys.exit(1)
