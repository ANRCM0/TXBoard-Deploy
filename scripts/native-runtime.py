#!/usr/bin/env python3
"""Native init/update handshake with an fsynced intent and exact-input recovery.

The runner never restores a database or downgrades an image. Module migration
recovery belongs to core:module-deploy; Laravel records completed migrations.
"""
import argparse
import base64
import contextlib
import hashlib
import gzip
import json
import os
import re
import secrets
import subprocess
import sys
import tarfile
import tempfile
import uuid
from pathlib import Path

VERSION = "txboard.native-deployment/v1"
STAGES = ("prepared", "draining", "drained", "stopping", "frozen", "backed_up", "configuration_applying", "configuration_ready", "schema_applying", "schema_ready",
          "native_prepared", "preflight_ready", "approved", "starting", "completed")
REQUIRED_FILES = ("prepare.json", "runtime.env", "node-recipients.json", "signer.seed",
                  "provider-ca.pem", "provider-client.pem", "provider-client.key")
OPTIONAL_FILES = ("module-secrets.json", "module-packages.lock.json", "modules.json", "outbound-policy.json")
RUNTIME_FILES = ("node-recipients.json", "signer.seed", "provider-ca.pem", "provider-client.pem", "provider-client.key",
                 "module-secrets.json", "module-packages.lock.json", "outbound-policy.json")
RUNTIME_KEYS = {
    "CORE_CREDENTIAL_PROVIDER_ID", "CORE_CREDENTIAL_PROVIDER_ENDPOINT", "CORE_CREDENTIAL_PROVIDER_EPOCH",
    "CORE_CREDENTIAL_PROVIDER_PROFILES", "NATIVE_SUBSCRIPTION_RENDER_ENDPOINT",
    "NATIVE_NODE_AUTHORIZATION_KEY_ID", "NATIVE_NODE_AUTHORIZATION_KEY_EPOCH",
    "NATIVE_NODE_AUTHORIZATION_POLICY_VERSION", "CORS_ALLOWED_ORIGINS",
}
REQUIRED_RUNTIME_KEYS = RUNTIME_KEYS - {"CORS_ALLOWED_ORIGINS"}
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
IMAGE = re.compile(r"(?:sha256:[0-9a-f]{64}|[a-z0-9][a-z0-9./:_-]{0,220}@sha256:[0-9a-f]{64})")


class NativeError(Exception):
    pass


def require(condition, code):
    if not condition:
        raise NativeError(code)


def encode(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()


def digest(value):
    return hashlib.sha256(value).hexdigest()


def allowed_native_file(name):
    return name in REQUIRED_FILES + OPTIONAL_FILES or re.fullmatch(r"module-config\.[a-z][a-z0-9_]{0,63}\.json", name)


def file_digest(path):
    require(not path.is_symlink() and path.is_file(), "BACKUP_FILE_UNAVAILABLE")
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1048576), b""):
            result.update(chunk)
    return result.hexdigest()


def regular(path, maximum=1048576):
    require(not path.is_symlink() and path.is_file(), "CONFIGURATION_FILE_UNAVAILABLE")
    require(path.stat().st_size <= maximum, "CONFIGURATION_FILE_TOO_LARGE")
    value = path.read_bytes()
    require(len(value) <= maximum, "CONFIGURATION_FILE_TOO_LARGE")
    return value


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result, "DUPLICATE_JSON_KEY")
        result[key] = value
    return result


def document(path, maximum=1048576):
    try:
        result = json.loads(regular(path, maximum), object_pairs_hook=pairs)
        require(isinstance(result, dict), "JSON_OBJECT_REQUIRED")
        return result
    except (ValueError, UnicodeError, RecursionError):
        raise NativeError("JSON_INVALID") from None


def env_read(path):
    result = {}
    for line in regular(path).decode("utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        require("=" in line, "ENVIRONMENT_INVALID")
        key, value = line.split("=", 1)
        require(re.fullmatch(r"[A-Z][A-Z0-9_]*", key) and key not in result, "ENVIRONMENT_INVALID")
        result[key] = value
    return result


def fsync_directory(path):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic(path, value):
    require(not path.is_symlink(), "UNSAFE_DEPLOYMENT_PATH")
    fd, temporary = tempfile.mkstemp(prefix=".native-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(value)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        fsync_directory(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def env_update(path, updates):
    raw = regular(path).decode("utf-8")
    # Validate duplicates before replacing; preserve comments and unrelated settings.
    env_read(path)
    lines = []
    remaining = dict(updates)
    for line in raw.splitlines():
        key = line.split("=", 1)[0]
        lines.append(key + "=" + str(remaining.pop(key)) if key in remaining else line)
    lines.extend(key + "=" + str(value) for key, value in remaining.items())
    atomic(path, ("\n".join(lines) + "\n").encode())


def config_fingerprint(root, native=None):
    files = {}
    for name, ignored in ((".env", {"TXBOARD_IMAGE"}), ("api.env", {"CORE_INSTALLATION_EPOCH", "INSTALLED"})):
        fields = env_read(root / name)
        files[name] = digest(encode({key: value for key, value in fields.items() if key not in ignored}))
    files["compose.yaml"] = digest(regular(root / "compose.yaml"))
    native = native or root / "native"
    require(native.is_dir() and not native.is_symlink(), "NATIVE_CONFIGURATION_REQUIRED")
    children = sorted(native.iterdir())
    require(len(children) <= 75, "NATIVE_CONFIGURATION_TOO_LARGE")
    for child in children:
        require(allowed_native_file(child.name), "UNEXPECTED_NATIVE_CONFIGURATION")
        files["native/" + child.name] = digest(regular(child))
    require(all("native/" + name in files for name in REQUIRED_FILES), "NATIVE_CONFIGURATION_REQUIRED")
    return digest(encode(files))


def module_operations(root, native=None):
    native = native or root / "native"
    path = native / "modules.json"
    if not path.exists():
        return []
    plan = document(path)
    require(set(plan) == {"schema", "operations"} and plan["schema"] == "native-module-preparation/v1"
            and isinstance(plan["operations"], list) and len(plan["operations"]) <= 128, "MODULE_DEPLOYMENT_PLAN_INVALID")
    for operation in plan["operations"]:
        require(isinstance(operation, dict) and set(operation) <= {"code", "action", "configuration"}
                and {"code", "action"} <= operation.keys() and isinstance(operation["code"], str)
                and re.fullmatch(r"[a-z][a-z0-9_]{0,63}", operation["code"])
                and operation["action"] in ("install", "configure", "enable", "disable", "update", "uninstall"), "MODULE_DEPLOYMENT_PLAN_INVALID")
        require((operation["action"] == "configure") == ("configuration" in operation), "MODULE_CONFIGURATION_FILE_INVALID")
        if "configuration" in operation:
            require(operation["configuration"] == "module-config." + operation["code"] + ".json", "MODULE_CONFIGURATION_FILE_INVALID")
            document(native / operation["configuration"], 32768)
    return plan["operations"]


def runtime_permissions(directory):
    # The image's application group is 1000. Bootstrap credentials stay readable only by the deployment owner.
    os.chown(directory, -1, 1000)
    os.chmod(directory, 0o750)
    for name in RUNTIME_FILES:
        path = directory / name
        if path.exists():
            require(not path.is_symlink() and path.is_file(), "UNSAFE_DEPLOYMENT_PATH")
            os.chown(path, -1, 1000)
            os.chmod(path, 0o640)


def prepare_storage(root):
    # Native preparation invokes PHP before the image entrypoint has initialized its bind mount.
    for relative in ("data", "data/storage", "data/storage/app", "data/storage/app/public", "data/storage/framework",
                     "data/storage/framework/cache", "data/storage/framework/cache/data", "data/storage/framework/sessions",
                     "data/storage/framework/views", "data/storage/logs"):
        path = root / relative
        require(not path.is_symlink() and (not path.exists() or path.is_dir()), "UNSAFE_DEPLOYMENT_PATH")
        path.mkdir(mode=0o750, exist_ok=True)
        if relative != "data":
            os.chown(path, 1000, 1000)
            os.chmod(path, 0o750)


def stage_config(root, source):
    require(source.is_dir() and not source.is_symlink() and not (root / "native").exists(), "NATIVE_CONFIGURATION_CONFLICT")
    require(source.resolve() != root.resolve(), "NATIVE_CONFIGURATION_CONFLICT")
    children = list(source.iterdir())
    require(len(children) <= 75, "NATIVE_CONFIGURATION_TOO_LARGE")
    for child in children:
        require(allowed_native_file(child.name), "UNEXPECTED_NATIVE_CONFIGURATION")
        regular(child)
    for name in REQUIRED_FILES:
        regular(source / name)
    preparation = document(source / "prepare.json", 262144)
    installation = preparation.get("installation_id", "")
    require(isinstance(installation, str) and UUID.fullmatch(installation), "INSTALLATION_ID_INVALID")
    configuration = env_read(source / "runtime.env")
    require(REQUIRED_RUNTIME_KEYS <= configuration.keys() <= RUNTIME_KEYS, "NATIVE_ENVIRONMENT_KEYS_INVALID")
    for value in configuration.values():
        require(re.fullmatch(r"[A-Za-z0-9.:/_@,+%~=-]{1,8192}", value), "NATIVE_ENVIRONMENT_VALUE_INVALID")
    require(configuration["NATIVE_NODE_AUTHORIZATION_POLICY_VERSION"] == "native-provider-authorization/v2", "NATIVE_POLICY_UNSUPPORTED")
    require(re.fullmatch(r"[A-Za-z0-9_-]{43}", regular(source / "signer.seed", 128).decode().strip()), "SIGNER_SEED_INVALID")
    recipients = document(source / "node-recipients.json")
    require(0 < len(recipients) <= 128, "NODE_RECIPIENTS_INVALID")
    configuration.update({
        "CORE_INSTALLATION_MODE": "native", "CORE_INSTALLATION_EPOCH": "1",
        "CORE_USAGE_V2_INSTANCE_ID": installation, "CORE_USAGE_V2_RECEIPT_GENERATION": "1",
        "NATIVE_NODE_AUTHORIZATION_ENABLED": "true", "NATIVE_NODE_AUTHORIZATION_CORE_INSTANCE_ID": installation,
        "NATIVE_NODE_AUTHORIZATION_PRIVATE_SEED_FILE": "/run/txboard-native/signer.seed",
        "NATIVE_PROVIDER_NODE_PROVIDER_ID": configuration["CORE_CREDENTIAL_PROVIDER_ID"],
        "NATIVE_PROVIDER_NODE_RECIPIENTS_FILE": "/run/txboard-native/node-recipients.json",
        "CORE_CREDENTIAL_PROVIDER_CA_FILE": "/run/txboard-native/provider-ca.pem",
        "CORE_CREDENTIAL_PROVIDER_CERT_FILE": "/run/txboard-native/provider-client.pem",
        "CORE_CREDENTIAL_PROVIDER_KEY_FILE": "/run/txboard-native/provider-client.key",
        "CORE_MODULE_SECRETS_FILE": "/run/txboard-native/module-secrets.json",
        "CORE_MODULE_OUTBOUND_POLICY_FILE": "/run/txboard-native/outbound-policy.json",
    })
    if (source / "module-packages.lock.json").exists():
        configuration["CORE_MODULE_PACKAGE_LOCK"] = "/run/txboard-native/module-packages.lock.json"
    # Generate once before using --entrypoint php, which intentionally bypasses image bootstrap.
    if not env_read(root / "api.env").get("APP_KEY"):
        configuration["APP_KEY"] = "base64:" + base64.b64encode(secrets.token_bytes(32)).decode()
    (root / "native").mkdir(mode=0o700)
    for child in source.iterdir():
        atomic(root / "native" / child.name, regular(child))
    for name in ("module-secrets.json", "outbound-policy.json"):
        if not (root / "native" / name).exists():
            atomic(root / "native" / name, b"{}\n")
    runtime_permissions(root / "native")
    prepare_storage(root)
    env_update(root / "api.env", configuration)
    module_operations(root)


class Journal:
    def __init__(self, root):
        self.root = root
        self.folder = root / ".native-deploy"
        require(not self.folder.is_symlink(), "UNSAFE_DEPLOYMENT_PATH")
        require(not self.folder.exists() or self.folder.is_dir(), "UNSAFE_DEPLOYMENT_PATH")
        self.path = self.folder / "intent.json"
        self.guard = root / ".upgrade-in-progress"

    def ensure(self):
        self.folder.mkdir(mode=0o700, exist_ok=True)
        fsync_directory(self.root)

    def load(self):
        if not self.path.exists():
            if not self.guard.exists():
                require(not self.guard.is_symlink(), "UNRELATED_UPGRADE_IN_PROGRESS")
                return None
            value = document(self.guard).get("initial_intent", {})
        else:
            value = document(self.path)
        require(value.get("schema") == VERSION and value.get("stage") in STAGES
                and value.get("operation") in ("install", "update")
                and UUID.fullmatch(str(value.get("operation_id", ""))), "DEPLOYMENT_INTENT_INVALID")
        content_hash = value.pop("content_hash", None)
        require(content_hash == digest(encode(value)), "DEPLOYMENT_INTENT_INVALID")
        if value["stage"] != "completed" or self.guard.exists():
            guard = document(self.guard)
            require(guard.get("schema") == VERSION and guard.get("operation_id") == value["operation_id"], "DEPLOYMENT_GUARD_INVALID")
        return value

    def save(self, value, stage):
        self.ensure()
        value["stage"] = stage
        atomic(self.path, encode(value | {"content_hash": digest(encode(value))}))

    def begin(self, value):
        require(not self.guard.exists() and not self.guard.is_symlink(), "UNRELATED_UPGRADE_IN_PROGRESS")
        initial = value | {"content_hash": digest(encode(value))}
        # The guard itself contains enough original input to recover an interrupted first intent write.
        atomic(self.guard, encode({"schema": VERSION, "operation_id": value["operation_id"], "initial_intent": initial}))
        self.save(value, "prepared")

    def complete(self, value):
        self.save(value, "completed")
        self.guard.unlink()
        fsync_directory(self.root)


@contextlib.contextmanager
def installation_lock(root):
    import fcntl
    path = root / ".upgrade.lock"
    require(not path.is_symlink(), "UNSAFE_DEPLOYMENT_PATH")
    fd = os.open(path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise NativeError("DEPLOYMENT_BUSY") from None
        yield
    finally:
        os.close(fd)


class Docker:
    def __init__(self, root):
        self.root = root

    def run(self, args):
        result = subprocess.run(["docker", *args], cwd=self.root, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode != 0:
            for line in result.stdout[-8192:].decode("utf-8", errors="replace").splitlines():
                try:
                    value = json.loads(line)
                except ValueError:
                    continue
                code = value.get("error_code") if isinstance(value, dict) else None
                if isinstance(code, str) and re.fullmatch(r"[A-Z][A-Z0-9_]{1,127}", code):
                    raise NativeError("CORE_" + code)
            output = (result.stdout + result.stderr)[-16384:].decode("utf-8", errors="replace")
            code = re.search(r"\b((?:MODULE|TRUSTED_CONFIGURATION|INSTALLATION_AUTHORITY)_[A-Z_]{1,100})\b", output)
            if code:
                raise NativeError("CORE_" + code.group(1))
            if "Please provide a valid cache path" in output:
                raise NativeError("CORE_RUNTIME_DIRECTORY_REQUIRED")
            sqlstate = re.search(r"SQLSTATE\[([A-Z0-9]{5})\]", output)
            if sqlstate:
                raise NativeError("CORE_SQLSTATE_" + sqlstate.group(1))
            raise NativeError("DOCKER_COMMAND_FAILED")
        return result.stdout.decode("utf-8")

    def compose(self, *args):
        return self.run(["compose", *args])

    def artisan(self, *args, running=False):
        if running:
            command = ["exec", "-T", "txboard", "php", "/www/artisan"]
        else:
            command = ["run", "-T", "--rm", "--no-deps", "-e", "CACHE_DRIVER=array", "-e", "SETTING_CACHE_STORE=array",
                       "-e", "QUEUE_CONNECTION=sync", "-e", "SESSION_DRIVER=array", "--entrypoint", "php", "txboard", "/www/artisan"]
        return self.compose(*command, *args, "--no-interaction")

    def report(self, *args, running=False):
        try:
            value = json.loads(self.artisan(*args, running=running), object_pairs_hook=pairs)
            require(isinstance(value, dict) and "error_code" not in value, "CORE_HANDSHAKE_FAILED")
            return value
        except (ValueError, UnicodeError):
            raise NativeError("CORE_HANDSHAKE_INVALID") from None

    def sql(self, query):
        shell = 'MYSQL_PWD="$DB_PASSWORD" exec mysql --batch --skip-column-names --connect-timeout=10 --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USERNAME" --database="$DB_DATABASE" --execute="$1"'
        return self.compose("run", "-T", "--rm", "--no-deps", "--entrypoint", "sh", "backup", "-ec", shell, "sh", query).strip()

    def pin(self, image):
        require(isinstance(image, str) and IMAGE.fullmatch(image), "IMMUTABLE_IMAGE_REQUIRED")
        if not image.startswith("sha256:"):
            self.run(["pull", image])
        inspected = json.loads(self.run(["image", "inspect", image]))
        require(len(inspected) == 1 and re.fullmatch(r"sha256:[0-9a-f]{64}", inspected[0]["Id"]), "IMAGE_ID_INVALID")
        return inspected[0]["Id"]

    def container(self, healthy=False):
        ids = self.compose("ps", "-a", "-q", "txboard").split()
        require(len(ids) == 1, "CORE_CONTAINER_AMBIGUOUS")
        rows = json.loads(self.run(["inspect", "--type", "container", ids[0]]))
        require(len(rows) == 1, "CORE_CONTAINER_AMBIGUOUS")
        row = rows[0]
        labels = row["Config"].get("Labels") or {}
        require(labels.get("com.docker.compose.service") == "txboard"
                and labels.get("com.docker.compose.project.working_dir") == str(self.root), "CORE_CONTAINER_OWNERSHIP_INVALID")
        if healthy:
            require(row["State"]["Status"] == "running" and row["State"].get("Health", {}).get("Status") == "healthy", "CORE_NOT_HEALTHY")
        return {"id": row["Id"], "image": row["Image"], "running": row["State"]["Status"] == "running"}

    def snapshot(self):
        return self.sql("SELECT (SELECT COUNT(*) FROM tx_user), (SELECT COALESCE(SUM(balance),0) FROM tx_user), (SELECT COALESCE(SUM(commission_balance),0) FROM tx_user), (SELECT COUNT(*) FROM tx_order), (SELECT COALESCE(SUM(total_amount),0) FROM tx_order)")

    def backup(self, operation_id):
        directory = self.root / "backups"
        before = set(directory.iterdir())
        require("CHECKSUMS.sha256" in regular(self.root / "backup.sh").decode(), "VERIFIED_BACKUP_HELPER_REQUIRED")
        self.compose("run", "-T", "--rm", "-e", "BACKUP_INTERVAL=0", "-e", "BACKUP_RETENTION=0", "backup")
        candidates = [path for path in set(directory.iterdir()) - before if re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", path.name)]
        require(len(candidates) == 1, "UNIQUE_BACKUP_REQUIRED")
        target = candidates[0]
        require(target.is_dir() and not target.is_symlink(), "BACKUP_PATH_INVALID")
        checksum = regular(target / "CHECKSUMS.sha256").decode()
        listed = set()
        for line in checksum.splitlines():
            match = re.fullmatch(r"([0-9a-f]{64}) [ *]([A-Za-z0-9_.-]+)", line)
            require(match is not None, "BACKUP_CHECKSUM_INVALID")
            listed.add(match[2])
            require(file_digest(target / match[2]) == match[1], "BACKUP_CHECKSUM_MISMATCH")
        require({"env", "db.sql.gz"} <= listed and b"APP_KEY=" in regular(target / "env"), "BACKUP_INCOMPLETE")
        # Include the exact Compose/config, private native material and legacy plugin/theme assets.
        archive = target / "native-deployment.tar.gz"
        with tarfile.open(archive, "w:gz") as output:
            for name in (".env", "api.env", "compose.yaml", "native", "data/plugins", "data/storage/theme"):
                path = self.root / name
                if path.exists():
                    require(not path.is_symlink(), "BACKUP_SOURCE_SYMLINK")
                    if path.is_dir():
                        require(not any(child.is_symlink() for child in path.rglob("*")), "BACKUP_SOURCE_SYMLINK")
                    output.add(path, arcname=name, recursive=True)
        os.chmod(archive, 0o600)
        with archive.open("rb") as stream:
            os.fsync(stream.fileno())
        checksum += file_digest(archive) + "  native-deployment.tar.gz\n"
        atomic(target / "CHECKSUMS.sha256", checksum.encode())
        fsync_directory(target)
        record = {"archive": target.name, "checksum": digest(checksum.encode()), "operation_id": operation_id}
        self.verify_backup(record)
        return record

    def verify_backup(self, record):
        require(isinstance(record, dict) and re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", str(record.get("archive", ""))), "BACKUP_RECORD_INVALID")
        target = self.root / "backups" / record["archive"]
        require(target.is_dir() and not target.is_symlink(), "BACKUP_PATH_INVALID")
        checksum = regular(target / "CHECKSUMS.sha256")
        require(digest(checksum) == record["checksum"], "BACKUP_RECORD_CHANGED")
        listed = set()
        for line in checksum.decode().splitlines():
            match = re.fullmatch(r"([0-9a-f]{64}) [ *]([A-Za-z0-9_.-]+)", line)
            require(match is not None and match[2] not in listed, "BACKUP_CHECKSUM_INVALID")
            require(file_digest(target / match[2]) == match[1], "BACKUP_CHECKSUM_MISMATCH")
            listed.add(match[2])
        require({"env", "db.sql.gz", "native-deployment.tar.gz"} <= listed, "BACKUP_INCOMPLETE")
        require(re.search(rb"(?m)^APP_KEY=.+$", regular(target / "env")), "BACKUP_KEY_MISSING")
        try:
            with gzip.open(target / "db.sql.gz", "rb") as stream:
                while stream.read(1048576):
                    pass
            with tarfile.open(target / "native-deployment.tar.gz", "r:gz") as archive:
                names = set(archive.getnames())
                require({".env", "api.env", "compose.yaml", "native"} <= names, "BACKUP_INCOMPLETE")
        except (OSError, EOFError, tarfile.TarError):
            raise NativeError("BACKUP_ARCHIVE_INVALID") from None


class Runner:
    def __init__(self, root, backend, journal=None, hook=None):
        self.root, self.backend = root, backend
        self.journal = journal or Journal(root)
        self.hook = hook or (lambda stage: None)

    def checkpoint(self, intent, stage):
        self.journal.save(intent, stage)
        self.hook(stage)

    def execute(self, operation=None, image=None, recover=False, configuration=None):
        intent = self.journal.load()
        if recover:
            require(intent is not None and (intent["stage"] != "completed" or self.journal.guard.exists())
                    and operation is None and image is None and configuration is None, "RECOVERY_INTENT_REQUIRED")
        else:
            require(intent is None or intent["stage"] == "completed" and not self.journal.guard.exists(), "RECOVERY_REQUIRED")
            require(operation in ("install", "update"), "OPERATION_INVALID")
            require(configuration is None or operation == "update", "UNEXPECTED_TARGET_CONFIGURATION")
            require(env_read(self.root / "api.env").get("CORE_INSTALLATION_MODE") == "native", "NATIVE_MODE_REQUIRED")
            target = self.backend.pin(image or env_read(self.root / ".env").get("TXBOARD_IMAGE"))
            current = None
            if operation == "update":
                current = self.backend.container(healthy=True)
                report = self.backend.report("core:installation", "runtime", running=True)
                require(report.get("ready") is True and report.get("authority_epoch") == "2", "CURRENT_NATIVE_READINESS_REQUIRED")
                old_fingerprint = report["composition_fingerprint"]
            else:
                require(self.backend.sql("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_TYPE='BASE TABLE'") == "0", "FRESH_DATABASE_REQUIRED")
                old_fingerprint = None
            operation_id = str(uuid.uuid4())
            target_native = self.stage_target(operation_id, configuration or self.root / "native") if operation == "update" else self.root / "native"
            module_operations(self.root, target_native)
            intent = {"schema": VERSION, "operation_id": operation_id, "operation": operation,
                      "stage": "prepared", "configuration": config_fingerprint(self.root), "target_image": target,
                      "old_container": current, "previous_fingerprint": old_fingerprint,
                      "runner": file_digest(Path(__file__)), "target_configuration": config_fingerprint(self.root, target_native),
                      "apply_modules": operation == "install" or configuration is not None}
            self.journal.begin(intent)
        self.verify_configuration(intent)
        require(intent["runner"] == file_digest(Path(__file__)), "RECOVERY_RUNNER_CHANGED")
        require(self.backend.pin(intent["target_image"]) == intent["target_image"], "TARGET_IMAGE_CHANGED")
        try:
            if recover and STAGES.index(intent["stage"]) >= STAGES.index("stopping"):
                self.backend.compose("stop", "txboard")
            self.advance(intent)
        except BaseException:
            # On any failure after stopping, leave writers stopped. A later run must recover the same intent.
            if STAGES.index(intent["stage"]) >= STAGES.index("stopping") and intent["stage"] != "completed":
                try:
                    self.backend.compose("stop", "txboard")
                except Exception:
                    pass
            raise
        return self.public(intent)

    def candidate_directory(self, intent):
        return self.journal.folder / ("candidate-" + intent["operation_id"])

    def target_native(self, intent):
        candidate = self.candidate_directory(intent) / "native"
        return candidate if candidate.exists() else self.root / "native"

    def stage_target(self, operation_id, source):
        self.journal.ensure()
        require(source.is_dir() and not source.is_symlink(), "TARGET_CONFIGURATION_REQUIRED")
        folder = self.journal.folder / ("candidate-" + operation_id)
        require(not folder.exists() and not folder.is_symlink(), "TARGET_CONFIGURATION_CONFLICT")
        folder.mkdir(mode=0o700)
        target = folder / "native"
        target.mkdir(mode=0o700)
        children = list(source.iterdir())
        require(len(children) <= 75, "NATIVE_CONFIGURATION_TOO_LARGE")
        for child in children:
            require(allowed_native_file(child.name), "UNEXPECTED_NATIVE_CONFIGURATION")
            atomic(target / child.name, regular(child))
        # Provider trust, installation/bootstrap identity and Node bindings have their own transition owners.
        for name in REQUIRED_FILES:
            require(regular(target / name) == regular(self.root / "native" / name), "PROTECTED_NATIVE_CONFIGURATION_CHANGED")
        for name in ("module-packages.lock.json", "module-secrets.json", "outbound-policy.json"):
            require((target / name).exists() == (self.root / "native" / name).exists(), "PACKAGE_CONFIGURATION_LOCATION_CHANGED")
        runtime_permissions(target)
        fsync_directory(folder)
        fsync_directory(self.journal.folder)
        return target

    def verify_configuration(self, intent):
        active = self.root / "native"
        previous = self.candidate_directory(intent) / "previous-native"
        if active.exists():
            fingerprint = config_fingerprint(self.root)
            position = STAGES.index(intent["stage"])
            switching = STAGES.index("configuration_applying")
            allowed = {intent["configuration"]} if position <= switching else {intent["target_configuration"]}
            if position == switching:
                allowed.add(intent["target_configuration"])
            require(fingerprint in allowed, "RECOVERY_CONFIGURATION_CHANGED")
        else:
            require(intent["stage"] == "configuration_applying" and previous.exists()
                    and config_fingerprint(self.root, previous) == intent["configuration"], "RECOVERY_CONFIGURATION_CHANGED")
        if intent["operation"] == "update" and STAGES.index(intent["stage"]) < STAGES.index("configuration_ready"):
            require(config_fingerprint(self.root, self.target_native(intent)) == intent["target_configuration"], "RECOVERY_TARGET_CONFIGURATION_CHANGED")

    def switch_configuration(self, intent):
        if intent["operation"] != "update":
            return
        folder = self.candidate_directory(intent)
        target, previous, active = folder / "native", folder / "previous-native", self.root / "native"
        if target.exists():
            if active.exists():
                require(not previous.exists() and config_fingerprint(self.root) == intent["configuration"], "CONFIGURATION_SWITCH_CONFLICT")
                os.rename(active, previous)
                fsync_directory(self.root)
                fsync_directory(folder)
            require(previous.exists() and not active.exists(), "CONFIGURATION_SWITCH_CONFLICT")
            os.rename(target, active)
            fsync_directory(self.root)
            fsync_directory(folder)
        require(config_fingerprint(self.root) == intent["target_configuration"], "CONFIGURATION_SWITCH_CONFLICT")

    def advance(self, intent):
        def before(stage):
            return STAGES.index(intent["stage"]) < STAGES.index(stage)
        update = intent["operation"] == "update"
        if before("drained"):
            self.checkpoint(intent, "draining")
            if update:
                codes = sorted({item["code"] for item in self.operations(intent) if item["action"] in ("update", "uninstall")})
                for code in codes:
                    key = str(uuid.uuid5(uuid.UUID(intent["operation_id"]), "drain:" + code))
                    self.backend.report("core:module-deploy", code, "disable", key, running=True)
                    result = self.backend.report("core:module-deploy", code, "drain", key, running=True)
                    require(result.get("drained") is True, "MODULE_DRAIN_REQUIRED")
            self.checkpoint(intent, "drained")
        if before("stopping"):
            self.checkpoint(intent, "stopping")
        if before("frozen"):
            if update:
                current = self.backend.container()
                require(current["id"] == intent["old_container"]["id"] and current["image"] == intent["old_container"]["image"], "CURRENT_CONTAINER_CHANGED")
                self.backend.compose("stop", "txboard")
                intent["financial_snapshot"] = self.backend.snapshot()
            self.checkpoint(intent, "frozen")
        if before("backed_up"):
            if update:
                intent["backup"] = self.backend.backup(intent["operation_id"])
            self.checkpoint(intent, "backed_up")
        env_update(self.root / ".env", {"TXBOARD_IMAGE": intent["target_image"]})
        if before("configuration_ready"):
            self.checkpoint(intent, "configuration_applying")
            self.switch_configuration(intent)
            self.checkpoint(intent, "configuration_ready")
        if before("schema_ready"):
            if update:
                self.backend.verify_backup(intent["backup"])
            self.checkpoint(intent, "schema_applying")
            self.backend.artisan("migrate", "--force")
            status = self.backend.artisan("migrate:status")
            require(re.search(r"\bPending\b", status, re.IGNORECASE) is None, "MIGRATIONS_PENDING")
            if update:
                require(self.backend.snapshot() == intent["financial_snapshot"], "FINANCIAL_SNAPSHOT_CHANGED")
            self.checkpoint(intent, "schema_ready")
        if before("native_prepared"):
            if not update:
                self.backend.report("core:native-prepare", "--config-file=/run/txboard-native/prepare.json")
                provider = env_read(self.root / "api.env")["CORE_CREDENTIAL_PROVIDER_ID"]
                self.backend.report("core:provider-register", provider, "--key=native-" + intent["operation_id"])
            self.deploy_modules(intent)
            self.checkpoint(intent, "native_prepared")
        if before("preflight_ready"):
            if update:
                report = self.backend.report("core:module-release", "preflight")
                require(report.get("ready_to_adopt") is True and report.get("active_fingerprint") == intent["previous_fingerprint"], "MODULE_PREFLIGHT_CONFLICT")
                intent["candidate_fingerprint"] = report["candidate_fingerprint"]
            else:
                report = self.backend.report("core:installation", "preflight")
                require(report.get("ready_to_activate") is True and report.get("next_worker_epoch") == "2", "ACTIVATION_PREFLIGHT_INVALID")
                intent["activation_digest"] = report["configuration_digest"]
                intent["expected_version"] = report["expected_version"]
            self.checkpoint(intent, "preflight_ready")
        if before("approved"):
            if update:
                self.backend.report("core:module-release", "adopt", "--key=" + intent["operation_id"],
                                    "--expected=" + intent["previous_fingerprint"], "--candidate=" + intent["candidate_fingerprint"])
            else:
                self.backend.report("core:installation", "activate", "--key=" + intent["operation_id"],
                                    "--expected-version=" + intent["expected_version"], "--configuration-digest=" + intent["activation_digest"])
            self.checkpoint(intent, "approved")
        env_update(self.root / "api.env", {"CORE_INSTALLATION_EPOCH": "2", "INSTALLED": "true"})
        self.checkpoint(intent, "starting")
        self.backend.compose("up", "-d", "--no-deps", "--force-recreate", "--wait", "txboard")
        running = self.backend.container(healthy=True)
        require(running["image"] == intent["target_image"], "STARTED_IMAGE_MISMATCH")
        report = self.backend.report("core:installation", "runtime", running=True)
        require(report.get("ready") is True and report.get("authority_epoch") == "2", "NATIVE_RUNTIME_NOT_READY")
        if update:
            require(report.get("composition_fingerprint") == intent["candidate_fingerprint"], "STARTED_COMPOSITION_MISMATCH")
        intent["active_fingerprint"] = report["composition_fingerprint"]
        self.journal.complete(intent)

    def deploy_modules(self, intent):
        plan = self.operations(intent)
        drained = {item["code"] for item in plan if item["action"] in ("update", "uninstall")} if intent["operation"] == "update" else set()
        for index, operation in enumerate(plan):
            if operation["action"] == "disable" and operation["code"] in drained:
                continue
            key = str(uuid.uuid5(uuid.UUID(intent["operation_id"]), str(index)))
            args = ["core:module-deploy", operation["code"], operation["action"], key]
            if "configuration" in operation:
                require(operation["action"] == "configure"
                        and operation["configuration"] == "module-config." + operation["code"] + ".json", "MODULE_CONFIGURATION_FILE_INVALID")
                regular(self.root / "native" / operation["configuration"], 32768)
                args.append("--config-file=/run/txboard-native/" + operation["configuration"])
            # Completed original deployment IDs replay; interrupted schema work resumes with the same ID.
            self.backend.report(*args)

    def operations(self, intent):
        return module_operations(self.root, self.target_native(intent)) if intent["apply_modules"] else []

    @staticmethod
    def public(intent):
        return {key: intent[key] for key in ("schema", "operation_id", "operation", "stage", "target_image", "active_fingerprint", "candidate_fingerprint") if key in intent}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("stage-config", "install", "update", "status", "recover"))
    parser.add_argument("--dir", type=Path, required=True)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--image")
    parser.add_argument("--configuration", type=Path, help="private target native directory; copied into the original update intent")
    args = parser.parse_args()
    root = args.dir.absolute()
    require(root.is_dir() and not root.is_symlink() and root.resolve() == root, "UNSAFE_INSTALLATION_DIRECTORY")
    if args.operation == "stage-config":
        require(args.source is not None and args.image is None and args.configuration is None, "STAGE_SOURCE_REQUIRED")
        stage_config(root, args.source.absolute())
        result = {"schema": VERSION, "configuration_staged": True}
    else:
        require(args.source is None, "UNEXPECTED_SOURCE")
        if args.operation == "status":
            require(args.configuration is None and args.image is None, "UNEXPECTED_TARGET_CONFIGURATION")
            intent = Journal(root).load()
            result = Runner.public(intent) if intent is not None else {"schema": VERSION, "stage": "none"}
        else:
            with installation_lock(root):
                result = Runner(root, Docker(root)).execute(None if args.operation == "recover" else args.operation,
                                                         args.image, recover=args.operation == "recover", configuration=args.configuration)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except NativeError as error:
        print(json.dumps({"schema": VERSION, "error_code": "NATIVE_DEPLOY_" + str(error)}), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError, TypeError, tarfile.TarError):
        print(json.dumps({"schema": VERSION, "error_code": "NATIVE_DEPLOY_UNAVAILABLE"}), file=sys.stderr)
        sys.exit(1)
