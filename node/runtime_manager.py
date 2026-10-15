#!/usr/bin/env python3
"""Installer orchestration for the private, same-deployment Node bundle.

Docker is called with argument arrays. Output is private until validated; errors
are fixed codes. The separate archive engine never invokes Docker or the network.
"""
from __future__ import annotations
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time
import runtime_backup as rb

IMAGE_ID = re.compile(r"sha256:[a-f0-9]{64}\Z")
CONTAINER_ID = re.compile(r"[a-f0-9]{64}\Z")
ROOT = "/etc/txnode"
CONFIG = ROOT + "/config.yml"
BRIDGE = "/run/txnode-update"


def refuse(code):
    raise rb.Refusal(code)


def run(args, *, timeout=30, limit=4*1024*1024):
    try:
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        refuse("DOCKER_COMMAND_FAILED")
    if result.returncode or len(result.stdout) > limit:
        refuse("DOCKER_COMMAND_FAILED")
    return result.stdout


def docker(*args, **kw):
    return run(["docker", *args], **kw)


def json_command(args):
    return rb.decode(run(args))


def inspect_container(name, missing=False):
    # Distinguish an absent container from a failed/unreachable Docker daemon.
    docker("info", "--format", "{{.ServerVersion}}", limit=1024)
    if missing:
        names = docker("ps", "-a", "--no-trunc", "--format", "{{.Names}}", limit=1024*1024).decode().splitlines()
        if name not in names:
            return None
    items = rb.decode(docker("inspect", "--type", "container", name))
    if not isinstance(items, list) or len(items) != 1 or not isinstance(items[0], dict):
        refuse("CONTAINER_IDENTITY_INVALID")
    value = items[0]
    if not CONTAINER_ID.fullmatch(value.get("Id", "")):
        refuse("CONTAINER_IDENTITY_INVALID")
    return value


def image_info(image_id):
    if not isinstance(image_id, str) or not IMAGE_ID.fullmatch(image_id):
        refuse("IMAGE_ID_INVALID")
    items = rb.decode(docker("image", "inspect", image_id))
    if not isinstance(items, list) or len(items) != 1 or items[0].get("Id") != image_id:
        refuse("IMMUTABLE_IMAGE_UNAVAILABLE")
    return items[0]


def compose_config(compose, root):
    value = json_command(["docker", "compose", "--project-directory", str(root), "-f", str(compose), "config", "--format", "json"])
    if not isinstance(value, dict):
        refuse("COMPOSE_UNSUPPORTED")
    return value


def expected_mounts(root):
    return {ROOT: (str(root / "data"), True), CONFIG: (str(root / "config.yml"), False),
            BRIDGE: (str(root / "remote-update"), True)}


def validate_compose(value, root, app):
    if set(value) - {"name", "services", "x-txnode-origin-image", "x-txnode-origin-id"} or set(value.get("services", {})) != {"tx-node"}:
        refuse("COMPOSE_UNSUPPORTED")
    svc = value["services"]["tx-node"]
    allowed = {"image", "container_name", "restart", "network_mode", "command", "volumes", "entrypoint"}
    if not isinstance(svc, dict) or set(svc) - allowed or svc.get("entrypoint") is not None or svc.get("container_name") != app or svc.get("network_mode") != "host" or svc.get("command") != ["-c", CONFIG] or not isinstance(svc.get("image"), str):
        refuse("COMPOSE_UNSUPPORTED")
    origin_keys = {"x-txnode-origin-image", "x-txnode-origin-id"} & set(value)
    if origin_keys:
        if len(origin_keys) != 2 or value["x-txnode-origin-id"] != svc["image"] or not IMAGE_ID.fullmatch(svc["image"]) or value["x-txnode-origin-image"] not in ("ghcr.io/anrcm0/txboard-node:latest", "ghcr.io/anrcm0/txboard-node:dev"):
            refuse("RESTORE_ORIGIN_INVALID")
    mounts = {}
    for volume in svc.get("volumes", []):
        if not isinstance(volume, dict) or volume.get("type") != "bind" or set(volume) - {"type", "source", "target", "read_only", "bind"}:
            refuse("COMPOSE_MOUNTS_UNSUPPORTED")
        bind = volume.get("bind", {})
        if not isinstance(bind, dict) or set(bind) - {"create_host_path"}:
            refuse("COMPOSE_MOUNTS_UNSUPPORTED")
        dst = volume.get("target")
        if dst in mounts:
            refuse("COMPOSE_MOUNTS_UNSUPPORTED")
        mounts[dst] = (volume.get("source"), not volume.get("read_only", False))
    if mounts != expected_mounts(root):
        refuse("COMPOSE_MOUNTS_UNSUPPORTED")
    return svc


def validate_container(value, root, app, image, *, allow_missing_config=False):
    labels = value.get("Config", {}).get("Labels") or {}
    if value.get("Name") != "/" + app or labels.get("com.docker.compose.service") != "tx-node" or labels.get("com.docker.compose.project.working_dir") != str(root) or labels.get("com.docker.compose.project.config_files") != str(root / "docker-compose.yml") or labels.get("com.docker.compose.oneoff", "False").lower() != "false":
        refuse("FOREIGN_CONTAINER")
    cfg = value.get("Config", {})
    if value.get("Image") != image.get("Id") or cfg.get("Entrypoint") not in (["tx-node"], ["/usr/local/bin/tx-node"]) or cfg.get("Cmd") != ["-c", CONFIG]:
        refuse("CONTAINER_COMMAND_UNSUPPORTED")
    if sorted(cfg.get("Env") or []) != sorted(image.get("Config", {}).get("Env") or []):
        refuse("CONTAINER_ENVIRONMENT_UNSUPPORTED")
    if value.get("HostConfig", {}).get("NetworkMode") != "host" or value.get("HostConfig", {}).get("Tmpfs") or value.get("HostConfig", {}).get("Privileged") or value.get("HostConfig", {}).get("Devices") or value.get("HostConfig", {}).get("CapAdd"):
        refuse("CONTAINER_LAYOUT_UNSUPPORTED")
    mounts = {}
    for mount in value.get("Mounts", []):
        if mount.get("Type") != "bind" or mount.get("Destination") in mounts:
            refuse("CONTAINER_MOUNTS_UNSUPPORTED")
        mounts[mount.get("Destination")] = (mount.get("Source"), mount.get("RW"))
    if mounts != expected_mounts(root):
        refuse("CONTAINER_MOUNTS_UNSUPPORTED")
    state = value.get("State", {})
    if state.get("Status") not in ("running", "exited", "created") or state.get("Paused") or state.get("Restarting") or state.get("Dead"):
        refuse("CONTAINER_STATE_UNSUPPORTED")
    for candidate in (root, root / "data", root / "remote-update"):
        rb.path_safe(candidate, missing=allow_missing_config)
    return state


def probe_layout(image_id, config):
    caps = rb.decode(docker("run", "--rm", "--network", "none", "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--entrypoint", "/usr/local/bin/tx-node", image_id, "--capabilities", limit=8192))
    if not isinstance(caps, dict) or caps.get("protocol_version") != 1 or caps.get("runtime") != "tx-node" or "node_runtime_checkpoint_v1" not in caps.get("capabilities", []):
        refuse("RUNTIME_CHECKPOINT_UNSUPPORTED")
    layout = rb.decode(docker("run", "--rm", "--network", "none", "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--mount", "type=bind,src=" + str(config) + ",dst=" + CONFIG + ",readonly", "--entrypoint", "/usr/local/bin/tx-node", image_id, "-c", CONFIG, "--backup-layout", limit=1024*1024))
    if not isinstance(layout, dict) or layout.get("format") != "txnode.backup-layout/v1" or layout.get("data_root") != ROOT or layout.get("checkpoint_receipt") != ".runtime-checkpoint.json" or not isinstance(layout.get("targets"), list) or not layout["targets"]:
        refuse("RUNTIME_LAYOUT_INVALID")
    return layout


def atomic_compose(root, value):
    fd, name = tempfile.mkstemp(prefix=".runtime-compose-", dir=root)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(rb.canonical(value) + b"\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(name, root / "docker-compose.yml")
        rb.fsync_dir(root)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def private_metadata(directory, metadata):
    path = Path(directory) / "capture.json"
    rb.write_file(path, rb.canonical(metadata))
    return path


def metadata(root, image, layout, capture):
    return {"format": "txnode.runtime-capture/v1", "component": "tx-node", "install_dir": str(root),
            "stopped": True, "image_available": True, "image_id": image["Id"],
            "repo_digests": image.get("RepoDigests") or [], "layout": layout, "capture": capture}


def checkpoint(root, current, compose, timeout):
    cid = current["Id"]
    before = current["State"]["StartedAt"]
    # Read public process identity before sending a signal; never accept a stale
    # receipt left by an earlier PID 1 incarnation in the same container.
    identity = docker("exec", cid, "cat", "/proc/1/stat", "/proc/sys/kernel/random/boot_id", limit=8192).decode()
    statline, boot = identity.strip().splitlines()
    end = statline.rfind(")")
    ticks = statline[end + 2:].split()[19]
    docker("update", "--restart=no", cid)
    compose["services"]["tx-node"]["restart"] = "no"
    atomic_compose(root, compose)
    docker("kill", "--signal=SIGUSR1", cid)
    deadline = time.monotonic() + timeout
    while True:
        after = inspect_container(cid)
        state = after["State"]
        if state.get("StartedAt") != before or after.get("RestartCount") != current.get("RestartCount"):
            refuse("CHECKPOINT_CONTAINER_RESTARTED")
        if not state.get("Running"):
            if state.get("Status") != "exited" or state.get("ExitCode") != 0 or state.get("OOMKilled") or state.get("Error"):
                refuse("CHECKPOINT_PROCESS_FAILED")
            break
        if time.monotonic() >= deadline:
            refuse("CHECKPOINT_TIMEOUT_RESTART_DISABLED")
        time.sleep(0.2)
    raw, _ = rb.read_regular(root / "data" / ".runtime-checkpoint.json", 16384, private=True)
    receipt = rb.decode(raw)
    # Schema finalized with the runtime implementation; any absent identity is
    # a refusal. The archive includes the original private receipt bytes.
    if not isinstance(receipt, dict) or receipt.get("format") != "txnode.runtime-checkpoint/v1" or receipt.get("pid") != 1 or receipt.get("boot_id") != boot or str(receipt.get("process_start_ticks")) != ticks:
        refuse("CHECKPOINT_RECEIPT_INVALID")
    return {"kind": "runtime_checkpoint", "container_id": cid, "started_at": before,
            "receipt_sha256": hashlib.sha256(raw).hexdigest(), "receipt": receipt}


def backup(args, root):
    rb.check_no_guard(root)
    rb.path_safe(root / "config.yml")
    compose = compose_config(root / "docker-compose.yml", root)
    validate_compose(compose, root, args.app_name)
    current = inspect_container(args.app_name)
    image = image_info(current.get("Image"))
    state = validate_container(current, root, args.app_name, image)
    layout = probe_layout(image["Id"], root / "config.yml")
    if state.get("Running"):
        capture = checkpoint(root, current, compose, args.timeout)
    else:
        docker("update", "--restart=no", current["Id"])
        compose["services"]["tx-node"]["restart"] = "no"
        atomic_compose(root, compose)
        capture = {"kind": "already_stopped", "container_id": current["Id"], "started_at": state.get("StartedAt")}
    # Bind the capture to the exact stopped incarnation again before archiving.
    final = inspect_container(current["Id"])
    if final["State"].get("Running") or final["State"].get("StartedAt") != state.get("StartedAt"):
        refuse("CONTAINER_CHANGED_DURING_CAPTURE")
    with tempfile.TemporaryDirectory(prefix=".node-capture-", dir=root.parent) as work:
        meta = private_metadata(work, metadata(root, image, layout, capture))
        return rb.create(root, args.output, meta)


def restore(args, root):
    rb.check_no_guard(root)
    manifest, bodies = rb.load_archive(args.archive)
    if manifest["install_dir"] != str(root):
        refuse("RESTORE_DEPLOYMENT_MISMATCH")
    image = image_info(manifest["image_id"])
    current = inspect_container(args.app_name, missing=True)
    if current is not None:
        current_image = image_info(current.get("Image"))
        state = validate_container(current, root, args.app_name, current_image, allow_missing_config=True)
        if state.get("Running"):
            refuse("RESTORE_STOPPED_REQUIRED")
    with tempfile.TemporaryDirectory(prefix=".node-restore-probe-", dir=root.parent) as work:
        cfg = Path(work) / "config.yml"
        rb.write_file(cfg, bodies["config.yml"])
        layout = probe_layout(image["Id"], cfg)
        if layout != manifest["layout"]:
            refuse("RESTORE_LAYOUT_MISMATCH")
        saved_compose = Path(work) / "docker-compose.yml"
        rb.write_file(saved_compose, bodies["docker-compose.yml"])
        compose = compose_config(saved_compose, root)
        svc = validate_compose(compose, root, args.app_name)
        original_ref = compose.get("x-txnode-origin-image", svc["image"])
        if original_ref in ("ghcr.io/anrcm0/txboard-node:latest", "ghcr.io/anrcm0/txboard-node:dev"):
            compose["x-txnode-origin-image"] = original_ref
            compose["x-txnode-origin-id"] = image["Id"]
        svc["image"] = image["Id"]
        svc["restart"] = "no"
        meta = metadata(root, image, layout, manifest["capture"])
        meta["restore_compose"] = rb.canonical(compose).decode() + "\n"
        path = private_metadata(work, meta)
        def before_publish():
            latest = inspect_container(args.app_name, missing=True)
            if current is None:
                if latest is not None:
                    refuse("CONTAINER_CHANGED_DURING_RESTORE")
            else:
                if latest is None or latest["Id"] != current["Id"] or latest["State"].get("StartedAt") != current["State"].get("StartedAt"):
                    refuse("CONTAINER_CHANGED_DURING_RESTORE")
                state = validate_container(latest, root, args.app_name, current_image, allow_missing_config=True)
                if state.get("Running"):
                    refuse("RESTORE_STOPPED_REQUIRED")
                docker("update", "--restart=no", latest["Id"])
        result = rb.restore(root, args.archive, path, before_publish=before_publish)
    return result


def recovery_image(root):
    # Only inspect the intent-bound Compose candidate. rb.recover subsequently
    # validates all old/new placements before the first rename.
    raw, _ = rb.read_regular(rb.guard_path(root), rb.MAX_MANIFEST, private=True)
    guard = rb.decode(raw)
    if not isinstance(guard, dict) or set(guard) != {"format", "transaction"} or guard["format"] != "txnode.runtime-guard/v1":
        refuse("RECOVERY_GUARD_INVALID")
    txn = Path(guard["transaction"])
    if txn.parent != root.parent or not re.fullmatch(re.escape("." + root.name + ".runtime-restore-") + r"[a-f0-9]{32}", txn.name):
        refuse("RECOVERY_TRANSACTION_INVALID")
    raw, _ = rb.read_regular(txn / "intent.json", rb.MAX_MANIFEST, private=True)
    intent = rb.decode(raw)
    if not isinstance(intent, dict) or intent.get("install_dir") != str(root) or intent.get("transaction") != str(txn):
        refuse("RECOVERY_INTENT_INVALID")
    entries = [e for e in intent.get("entries", []) if isinstance(e, dict) and e.get("path") == "docker-compose.yml"]
    if len(entries) != 1:
        refuse("RECOVERY_COMPOSE_INVALID")
    candidate = txn / "new/docker-compose.yml"
    if not candidate.exists():
        candidate = root / "docker-compose.yml"
    raw, _ = rb.read_regular(candidate, rb.MAX_MANIFEST)
    if len(raw) != entries[0].get("size") or hashlib.sha256(raw).hexdigest() != entries[0].get("sha256"):
        refuse("RECOVERY_COMPOSE_INVALID")
    value = rb.decode(raw)
    image = value.get("services", {}).get("tx-node", {}).get("image") if isinstance(value, dict) else None
    image_info(image)


def recover(args, root):
    recovery_image(root)
    current = inspect_container(args.app_name, missing=True)
    if current:
        image = image_info(current.get("Image"))
        state = validate_container(current, root, args.app_name, image, allow_missing_config=True)
        if state.get("Running"):
            refuse("RECOVERY_STOPPED_REQUIRED")
        docker("update", "--restart=no", current["Id"])
    return rb.recover(root)


@contextlib.contextmanager
def deployment_lock(root, inherited):
    path = root.parent / ("." + root.name + ".runtime-operation.lock")
    rb.path_safe(path, missing=True)
    if inherited is None:
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    else:
        fd = inherited
    try:
        value = os.fstat(fd)
        actual = path.lstat()
        if not stat.S_ISREG(value.st_mode) or (value.st_dev, value.st_ino) != (actual.st_dev, actual.st_ino) or value.st_mode & 0o077 or value.st_uid != os.geteuid():
            refuse("OPERATION_LOCK_INVALID")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            refuse("OPERATION_BUSY")
        yield
    finally:
        if inherited is None:
            os.close(fd)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description="TX-Node private runtime backup/restore")
    parser.add_argument("--install-dir", required=True)
    parser.add_argument("--app-name", default="tx-node")
    parser.add_argument("--lock-fd", type=int)
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("backup")
    p.add_argument("--output", required=True)
    p.add_argument("--timeout", type=int, default=45)
    p = commands.add_parser("restore")
    p.add_argument("--archive", required=True)
    commands.add_parser("runtime-recover")
    args = parser.parse_args()
    root = rb.install_path(args.install_dir)
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}", args.app_name):
        refuse("CONTAINER_NAME_INVALID")
    with deployment_lock(root, args.lock_fd):
        if args.command == "backup":
            result = backup(args, root)
        elif args.command == "restore":
            result = restore(args, root)
        else:
            result = recover(args, root)
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    try:
        if sys.platform != "linux" or sys.version_info < (3, 10):
            refuse("LINUX_PYTHON_310_REQUIRED")
        main()
    except rb.Refusal as exc:
        print("TXNODE_RUNTIME_" + str(exc), file=sys.stderr)
        sys.exit(2)
    except (OSError, ValueError, TypeError, KeyError, IndexError, OverflowError, RecursionError):
        print("TXNODE_RUNTIME_OPERATION_REFUSED", file=sys.stderr)
        sys.exit(2)
