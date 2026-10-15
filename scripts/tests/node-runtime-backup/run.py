#!/usr/bin/env python3
"""Actual local Docker/Installer smoke; synthetic HTTP fixture, NOT real Core.

Usage: run.py INSTALLER_SNAPSHOT NODE_STATIC_ELF EVIDENCE_NEW CAT_STATIC_ELF
Requires root Linux, Python3.10+, Docker Compose and the dedicated task daemon
unix:///opt/txboard-baseline/p1-docker-r1/docker.sock. It imports a scratch rootfs
from supplied local binaries without any registry/network build dependency.
No explicit cleanup or deletion commands are issued. Compose may recreate its
own stopped test container during startup; directories, images and prior failed
run evidence are preserved. Successful runtimes are left stopped; failed
runtimes/evidence are preserved for review. Only loopback service
traffic is generated. Full signed native authorization/real Core acceptance and
VMess traffic are explicitly outside this smoke.
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import socket
import socketserver
import stat
import struct
import subprocess
import sys
import tarfile
import threading
import time
import traceback
import uuid

DAEMON = "unix:///opt/txboard-baseline/p1-docker-r1/docker.sock"
USER_UUID = "9d8fd990-7097-4330-8ad0-fd077295c497"
TOKEN = "isolated-smoke-synthetic-bearer-only"
PERIOD = "synthetic-installer-smoke-period"
PREFIX = "/txapi/node/v1/"


class SmokeFailure(Exception):
    pass


def demand(condition, code):
    if not condition:
        raise SmokeFailure(code)


def digest(path):
    hashed = hashlib.sha256()
    with open(path, "rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            hashed.update(block)
    return hashed.hexdigest()


def private_json(path, value):
    with open(path, "x", encoding="utf-8") as stream:
        os.chmod(path, 0o600)
        json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


def available_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Fixture:
    """Wire shape reused from txboard/client_test.go; no authority emulation."""
    def __init__(self, node_port, kernel, echo_port):
        self.node_port = node_port
        demand(kernel in ("singbox", "xray") and 1024 <= echo_port <= 65535, "FIXTURE_ROUTE_SCOPE_INVALID")
        self.origin_route = ({"type": "field", "network": "tcp", "ip": ["127.0.0.1/32"],
                              "port": str(echo_port), "outboundTag": "direct"}
                             if kernel == "xray" else
                             {"network": "tcp", "ip_cidr": ["127.0.0.1/32"],
                              "port": [echo_port], "outbound": "direct"})
        self.calls = []
        self.reports = []
        self.lock = threading.Lock()
        self.server = None
        self.thread = None

    def __enter__(self):
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                self.respond()

            def do_POST(self):
                self.respond()

            def respond(self):
                length = int(self.headers.get("Content-Length", "0"))
                if length > 2 * 1024 * 1024:
                    self.send_error(413)
                    return
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw) if raw else None
                except (ValueError, TypeError):
                    self.send_error(400)
                    return
                if self.headers.get("Authorization") != "Bearer " + TOKEN or self.headers.get("X-TX-Node-ID") != "42":
                    self.send_error(401)
                    return
                with fixture.lock:
                    fixture.calls.append({"method": self.command, "path": self.path})
                if self.path == PREFIX + "handshake":
                    data = {"protocol_version": 1, "mode": "node", "node_id": 42,
                            "websocket": {"enabled": False},
                            "settings": {"push_interval": 3600, "pull_interval": 3600}}
                    status = 200
                elif self.path == PREFIX + "config":
                    data = {"protocol_version": 1, "node_id": 42, "config": {
                        "protocol": "vless", "listen_ip": "127.0.0.1", "server_port": fixture.node_port,
                        "custom_routes": [fixture.origin_route]}}
                    status = 200
                elif self.path == PREFIX + "users":
                    data = {"protocol_version": 1, "node_id": 42, "users": [{
                        "id": 7, "uuid": USER_UUID, "speed_limit": 0, "device_limit": 0,
                        "traffic_period": PERIOD}]}
                    status = 200
                elif self.path == PREFIX + "report" and self.command == "POST":
                    with fixture.lock:
                        fixture.reports.append(body)
                        receipt = len(fixture.reports)
                    data = {"protocol_version": 1, "accepted": True,
                            "traffic_batch_id": body.get("traffic_batch_id", ""),
                            "settlement": "queued", "receipt_status": "persisted", "receipt_id": str(receipt)}
                    status = 202
                else:
                    self.send_error(404)
                    return
                encoded = json.dumps({"data": data, "request_id": "synthetic-smoke"}, separators=(",", ":")).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        return self

    @property
    def port(self):
        return self.server.server_address[1]

    def __exit__(self, *_):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


class EchoHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(10)
        with contextlib.suppress(OSError):
            while True:
                block = self.request.recv(65536)
                if not block:
                    return
                self.request.sendall(block)


class EchoServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = False
    daemon_threads = True


def vless_roundtrip(node_port, echo_port):
    payload = b"TXNODE-ISOLATED-INSTALLER-SMOKE\n" * 2048
    with socket.create_connection(("127.0.0.1", node_port), timeout=5) as stream:
        stream.settimeout(10)
        header = bytes([0]) + uuid.UUID(USER_UUID).bytes + bytes([0, 1]) + struct.pack("!H", echo_port) + bytes([1]) + socket.inet_aton("127.0.0.1")
        stream.sendall(header + payload)
        def receive_exact(count):
            blocks = bytearray()
            while len(blocks) < count:
                block = stream.recv(count - len(blocks))
                demand(block, "VLESS_EARLY_EOF")
                blocks.extend(block)
            return bytes(blocks)
        response = receive_exact(2)
        demand(response[0] == 0, "VLESS_RESPONSE_VERSION")
        receive_exact(response[1])
        demand(receive_exact(len(payload)) == payload, "VLESS_PAYLOAD_MISMATCH")
    return len(payload)


class Harness:
    def __init__(self, args):
        self.installer = Path(args.installer_snapshot).resolve(strict=True)
        self.node_binary = Path(args.node_binary).resolve(strict=True)
        self.cat_binary = Path(args.cat_binary).resolve(strict=True)
        self.evidence = Path(os.path.abspath(args.evidence_new))
        demand(sys.platform == "linux" and os.geteuid() == 0, "ROOT_LINUX_REQUIRED")
        demand(os.environ.get("DOCKER_HOST") == DAEMON, "DEDICATED_DOCKER_HOST_REQUIRED")
        demand(self.evidence.is_absolute() and not self.evidence.exists(), "NEW_EVIDENCE_REQUIRED")
        demand(self.evidence.parent.is_dir(), "EVIDENCE_PARENT_REQUIRED")
        demand(not any(item.is_symlink() for item in (self.evidence.parent, *self.evidence.parent.parents)), "EVIDENCE_SYMLINK_REFUSED")
        self.evidence.mkdir(mode=0o700)
        (self.evidence / "logs").mkdir(mode=0o700)
        self.count = 0
        self.artifacts = []
        self.cases = []
        self.current_case = None
        self.env = dict(os.environ, DOCKER_HOST=DAEMON, PYTHONDONTWRITEBYTECODE="1")
        self.app_suffix = uuid.uuid4().hex[:12]
        demand((self.installer / "node" / "deploy.sh").is_file(), "INSTALLER_SNAPSHOT_INVALID")
        for item in (self.node_binary, self.cat_binary):
            demand(item.is_file(), "STATIC_ELF_REQUIRED")
            with open(item,"rb") as source:
                demand(source.read(4) == b"\x7fELF", "STATIC_ELF_REQUIRED")

    def command(self, name, arguments, *, env=None, expected=0, timeout=90):
        self.count += 1
        output = self.evidence / "logs" / f"{self.count:03d}-{name}.log"
        with open(output, "xb") as log:
            os.chmod(output, 0o600)
            try:
                result = subprocess.run(arguments, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                        env=env or self.env, timeout=timeout, check=False)
            except (OSError, subprocess.TimeoutExpired):
                raise SmokeFailure(name.upper().replace("-", "_") + "_COMMAND_FAILED") from None
        self.artifacts.append({"step": name, "exit_code": result.returncode, "log": str(output), "sha256": digest(output)})
        if expected == "failure":
            demand(result.returncode != 0, name.upper().replace("-", "_") + "_EXPECTED_REFUSAL")
        else:
            demand(result.returncode == expected, name.upper().replace("-", "_") + "_FAILED")
        return output.read_bytes()

    def docker(self, name, *arguments, **kwargs):
        return self.command(name, ["docker", *arguments], **kwargs)

    def inspect(self, app):
        value = json.loads(self.docker("inspect-container", "inspect", "--type", "container", app))
        demand(isinstance(value, list) and len(value) == 1, "CONTAINER_INSPECT_INVALID")
        return value[0]

    def installer_call(self, name, root, app, *arguments, extra_env=None, **kwargs):
        env = dict(self.env, INSTALL_DIR=str(root), APP_NAME=app,
                   CLI_LINK=str(self.evidence / "unused-cli-link"),
                   SCRIPT_RAW_URL="https://invalid.invalid/never-download/deploy.sh")
        env.update(extra_env or {})
        return self.command(name, ["bash", str(self.installer / "node" / "deploy.sh"), *arguments], env=env, **kwargs)

    def compose(self, name, root, *arguments):
        return self.docker(name, "compose", "--project-directory", str(root), "-f", str(root / "docker-compose.yml"), *arguments)

    def create_image(self):
        rootfs = self.evidence / "scratch-rootfs.tar"
        with tarfile.open(rootfs, "w") as archive:
            for directory in ("usr", "usr/local", "usr/local/bin", "usr/bin", "etc", "etc/txnode", "run", "run/txnode-update", "tmp"):
                entry = tarfile.TarInfo(directory)
                entry.type = tarfile.DIRTYPE
                entry.mode = 0o755
                archive.addfile(entry)
            for source, target in ((self.node_binary, "usr/local/bin/tx-node"), (self.cat_binary, "usr/bin/cat")):
                entry = tarfile.TarInfo(target)
                entry.mode = 0o755
                entry.size = source.stat().st_size
                with open(source,"rb") as binary:
                    archive.addfile(entry, binary)
        os.chmod(rootfs, 0o600)
        response = self.docker("import-local-scratch", "import", "--change", 'ENTRYPOINT ["/usr/local/bin/tx-node"]',
                               "--change", "ENV PATH=/usr/local/bin:/usr/bin:/bin", str(rootfs),
                               "txnode-p1-smoke:" + self.app_suffix, timeout=180).decode().strip()
        demand(re.fullmatch(r"sha256:[a-f0-9]{64}", response), "LOCAL_IMAGE_ID_INVALID")
        return response

    def wait_listener(self, port, app, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=.2):
                    return
            except OSError:
                time.sleep(.1)
        self.docker("startup-container-logs", "logs", "--tail", "100", app)
        raise SmokeFailure("NODE_LISTENER_TIMEOUT")

    def validate_stopped(self, app, expected_id=None):
        value = self.inspect(app)
        state = value["State"]
        demand(not state.get("Running") and state.get("ExitCode") == 0 and not state.get("OOMKilled"), "CHECKPOINT_NOT_CLEAN_STOPPED")
        demand(value.get("HostConfig", {}).get("RestartPolicy", {}).get("Name") == "no", "RESTART_POLICY_NOT_DISABLED")
        if expected_id:
            demand(value["Id"] == expected_id, "CONTAINER_REPLACED_UNEXPECTEDLY")
        return value

    def write_deployment(self, root, app, image_id, kernel, fixture_port, restart="no"):
        config = f"""panel:
  provider: txboard
  url: http://127.0.0.1:{fixture_port}
  token: {TOKEN}
  node_id: 42
kernel:
  type: {kernel}
  config_dir: /etc/txnode/runtime
  log_level: error
cert:
  cert_mode: none
node:
  push_interval: 3600
  pull_interval: 3600
  track_interval: 3600
  device_report_interval: 3600
ws:
  discovery_interval: 3600
log:
  level: error
  output: stdout
"""
        (root / "config.yml").write_text(config)
        os.chmod(root / "config.yml", 0o600)
        compose = {"services": {"tx-node": {"image": image_id, "container_name": app,
                   "restart": restart, "network_mode": "host",
                   "command": ["-c", "/etc/txnode/config.yml"], "volumes": [
                   {"type": "bind", "source": str(root / "data"), "target": "/etc/txnode"},
                   {"type": "bind", "source": str(root / "config.yml"), "target": "/etc/txnode/config.yml", "read_only": True},
                   {"type": "bind", "source": str(root / "remote-update"), "target": "/run/txnode-update"}]}}}
        private_json(root / "docker-compose.yml", compose)

    def case(self, kernel, image_id):
        root = self.evidence / ("deployment-" + kernel)
        root.mkdir(mode=0o700)
        for item in ("data", "remote-update"):
            (root / item).mkdir(mode=0o700)
        app = "txnode-p1-" + kernel + "-" + self.app_suffix
        self.current_case = {"kernel": kernel, "scenario": "runtime_backup_restore_checkpoint",
                             "container": app, "deployment": str(root), "result": "incomplete"}
        self.cases.append(self.current_case)
        node_port = available_port()
        with EchoServer(("127.0.0.1", 0), EchoHandler) as echo, Fixture(node_port, kernel, echo.server_address[1]) as fixture:
            echo_thread = threading.Thread(target=echo.serve_forever, daemon=True)
            echo_thread.start()
            try:
                self.write_deployment(root, app, image_id, kernel, fixture.port, restart="unless-stopped")
                probe = root / "data" / "restore-probe.txt"
                probe.write_bytes(b"original-runtime-file\n")
                os.chmod(probe, 0o600)
                self.compose("compose-start-" + kernel, root, "up", "-d", "--pull", "never")
                self.wait_listener(node_port, app)
                before = self.inspect(app)
                proc = self.docker("process-identity-" + kernel, "exec", app, "cat", "/proc/1/stat", "/proc/sys/kernel/random/boot_id").decode().splitlines()
                demand(len(proc) == 2, "PROCESS_IDENTITY_INVALID")
                ticks = proc[0][proc[0].rfind(")") + 1:].split()[19]
                sent = vless_roundtrip(node_port, echo.server_address[1])
                first = self.evidence / (kernel + "-initial.tar.gz")
                self.installer_call("installer-full-backup-" + kernel, root, app, "backup", "--full", str(first))
                stopped = self.validate_stopped(app, before["Id"])
                demand(stopped["State"]["StartedAt"] == before["State"]["StartedAt"], "PROCESS_INCARNATION_CHANGED")
                receipt = json.loads((root / "data" / ".runtime-checkpoint.json").read_bytes())
                demand(receipt.get("format") == "txnode.runtime-checkpoint/v1" and receipt.get("pid") == 1
                       and receipt.get("boot_id") == proc[1] and str(receipt.get("process_start_ticks")) == ticks,
                       "CURRENT_PROCESS_RECEIPT_MISMATCH")
                terminal = list((root / "data").rglob("*.pending.json.terminal.json"))
                demand(len(terminal) == 1, "FINAL_TERMINAL_SPOOL_MISSING")
                terminal_path = terminal[0].relative_to(root / "data")
                terminal_body = terminal[0].read_bytes()
                batch = json.loads(terminal_body)
                payload = batch["Payload"]
                batch_id = payload["BatchID"]
                traffic = payload.get("Traffic", {}).get("7", [0, 0])
                demand(len(traffic) == 2 and all(value >= sent for value in traffic), "FINAL_COUNTERS_INCOMPLETE")
                segments = payload.get("traffic_segments", [])
                demand(segments and all(item.get("period") == PERIOD for item in segments), "ORIGINAL_PERIOD_MISSING")
                demand(isinstance(batch_id, str) and batch_id, "ORIGINAL_BATCH_ID_MISSING")
                demand(stat.S_IMODE(first.stat().st_mode) == 0o600, "ARCHIVE_NOT_PRIVATE")
                with tarfile.open(first, "r:*") as saved:
                    manifest = json.load(saved.extractfile("MANIFEST.json"))
                demand(manifest.get("capture", {}).get("kind") == "runtime_checkpoint" and manifest.get("image_id") == image_id, "MANIFEST_CAPTURE_INVALID")
                with fixture.lock:
                    demand(not fixture.reports, "CHECKPOINT_STARTED_REPORT_HTTP")
                probe.write_bytes(b"post-backup-change\n")
                self.installer_call("installer-full-restore-" + kernel, root, app, "restore", "--full", str(first))
                self.validate_stopped(app, before["Id"])
                demand(probe.read_bytes() == b"original-runtime-file\n", "RESTORE_DID_NOT_REPLACE_DATA")
                demand((root / "data" / terminal_path).read_bytes() == terminal_body, "RESTORE_CHANGED_ORIGINAL_BATCH_BYTES")
                restored_compose = json.loads((root / "docker-compose.yml").read_text())
                demand(restored_compose["services"]["tx-node"]["image"] == image_id and restored_compose["services"]["tx-node"]["restart"] == "no", "RESTORE_NOT_PINNED_STOPPED")
                self.installer_call("interrupt-restore-" + kernel, root, app, "restore", "--full", str(first),
                                    extra_env={"TXNODE_RUNTIME_BACKUP_TEST_FAIL_AFTER": "old-data"}, expected="failure")
                guard = root.parent / ("." + root.name + ".runtime-restore.guard")
                demand(guard.is_file(), "INTERRUPTION_GUARD_MISSING")
                guard_bin = self.evidence / (kernel + "-guard-no-docker-bin")
                guard_bin.mkdir(mode=0o700)
                docker_log = self.evidence / (kernel + "-guard-docker-invocations.txt")
                wrapper = guard_bin / "docker"
                wrapper.write_text('#!/bin/sh\nprintf "%s\\n" invoked >> "$TXNODE_SMOKE_DOCKER_CALL_LOG"\nexit 89\n')
                wrapper.chmod(0o700)
                guard_env = {"PATH": str(guard_bin) + ":" + self.env.get("PATH", "/usr/bin:/bin"),
                             "TXNODE_SMOKE_DOCKER_CALL_LOG": str(docker_log)}
                for action in ("start", "restart", "upgrade", "reconfigure", "purge"):
                    refused = self.installer_call("guard-refuses-" + action + "-" + kernel, root, app, action,
                                                 extra_env=guard_env, expected="failure", timeout=20)
                    demand(b"runtime-recover" in refused, "LIFECYCLE_GUARD_REASON_MISSING")
                    demand(not docker_log.exists(), "GUARDED_LIFECYCLE_INVOKED_DOCKER")
                    self.validate_stopped(app, before["Id"])
                self.installer_call("installer-runtime-recover-" + kernel, root, app, "runtime-recover")
                demand(not guard.exists(), "RECOVERY_GUARD_REMAINS")
                self.validate_stopped(app, before["Id"])
                demand((root / "data" / terminal_path).read_bytes() == terminal_body, "RECOVERY_CHANGED_ORIGINAL_BATCH_BYTES")
                self.compose("compose-replay-start-" + kernel, root, "up", "-d", "--pull", "never")
                self.wait_listener(node_port, app)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    with fixture.lock:
                        replayed = [body for body in fixture.reports if body.get("traffic_batch_id") == batch_id]
                    if replayed:
                        break
                    time.sleep(.1)
                demand(replayed, "ORIGINAL_BATCH_NOT_REPLAYED")
                demand(replayed[0].get("traffic_segments") == segments, "REPLAY_CHANGED_ORIGINAL_PERIOD_SEGMENTS")
                sent_after = vless_roundtrip(node_port, echo.server_address[1])
                final = self.evidence / (kernel + "-final.tar.gz")
                self.installer_call("installer-final-backup-" + kernel, root, app, "backup", "--full", str(final))
                self.validate_stopped(app)
                self.current_case.update(result="passed", protocol="vless", payload_bytes=sent,
                                         post_restore_payload_bytes=sent_after, original_batch_id=batch_id,
                                         terminal_sha256=hashlib.sha256(terminal_body).hexdigest(),
                                         initial_archive_sha256=digest(first), final_archive_sha256=digest(final),
                                         current_process_receipt_verified=True, restore_interruption_recovered=True,
                                         replayed_original_batch=True)
            finally:
                with fixture.lock:
                    private_json(self.evidence / (kernel + "-synthetic-fixture-observations.json"),
                                 {"fixture": "synthetic HTTP, not Core", "calls": fixture.calls, "reports": fixture.reports})
                echo.shutdown()
                echo_thread.join(timeout=5)
                # Preserve container logs privately, including on an earlier failure.
                with contextlib.suppress(Exception):
                    self.docker("preserved-node-logs-" + kernel, "logs", "--tail", "200", app)

    def negative_checkpoint_case(self, kernel, image_id, normal_sigterm=False):
        scenario = "normal_sigterm_no_checkpoint_receipt" if normal_sigterm else "checkpoint_receipt_persistence_refusal"
        short = "sigterm" if normal_sigterm else "receipt-refusal"
        root = self.evidence / (short + "-" + kernel)
        root.mkdir(mode=0o700)
        for part in ("data", "remote-update"):
            (root / part).mkdir(mode=0o700)
        app = "txnode-p1-" + short + "-" + kernel + "-" + self.app_suffix
        record = {"kernel": kernel, "scenario": scenario, "container": app,
                  "deployment": str(root), "result": "incomplete"}
        self.current_case = record
        self.cases.append(record)
        node_port = available_port()
        receipt = root / "data" / ".runtime-checkpoint.json"
        if not normal_sigterm:
            # A directory at the receipt filename guarantees atomic receipt
            # publication fails; no runtime filesystem permissions are weakened.
            receipt.mkdir(mode=0o700)
        with EchoServer(("127.0.0.1", 0), EchoHandler) as echo, Fixture(node_port, kernel, echo.server_address[1]) as fixture:
            echo_thread = threading.Thread(target=echo.serve_forever, daemon=True)
            echo_thread.start()
            try:
                self.write_deployment(root, app, image_id, kernel, fixture.port)
                self.compose("negative-start-" + short + "-" + kernel, root, "up", "-d", "--pull", "never")
                self.wait_listener(node_port, app)
                before = self.inspect(app)
                demand(before.get("HostConfig", {}).get("RestartPolicy", {}).get("Name") == "no", "NEGATIVE_RESTART_POLICY_NOT_DISABLED")
                sent = vless_roundtrip(node_port, echo.server_address[1])
                if normal_sigterm:
                    demand(not receipt.exists(), "NORMAL_STOP_STALE_RECEIPT")
                    self.docker("normal-sigterm-" + kernel, "kill", "--signal=SIGTERM", app)
                    observed_exit = self.docker("wait-normal-sigterm-" + kernel, "wait", app, timeout=25).decode().strip()
                    demand(observed_exit == "0", "NORMAL_SIGTERM_EXIT_FAILED")
                    stopped = self.validate_stopped(app, before["Id"])
                    demand(not receipt.exists() and not receipt.is_symlink(), "NORMAL_SIGTERM_CREATED_CHECKPOINT_RECEIPT")
                    demand(not list((root / "data").glob(".runtime-checkpoint-*")), "NORMAL_SIGTERM_CREATED_CHECKPOINT_TEMP")
                    record.update(expectation="ordinary stop creates no checkpoint receipt", receipt_absent=True)
                else:
                    archive = self.evidence / (kernel + "-receipt-refusal-must-not-exist.tar.gz")
                    refused = self.installer_call("negative-backup-receipt-refusal-" + kernel, root, app,
                                                  "backup", "--full", str(archive), expected="failure")
                    demand(b"CHECKPOINT_PROCESS_FAILED" in refused, "RECEIPT_REFUSAL_REASON_MISSING")
                    stopped = self.inspect(app)
                    state = stopped["State"]
                    demand(stopped["Id"] == before["Id"] and not state.get("Running")
                           and state.get("Status") == "exited" and state.get("ExitCode") != 0
                           and not state.get("OOMKilled"), "RECEIPT_FAILURE_NOT_NONZERO_STOPPED")
                    demand(stopped.get("HostConfig", {}).get("RestartPolicy", {}).get("Name") == "no", "RECEIPT_FAILURE_RESTART_NOT_DISABLED")
                    demand(not archive.exists() and not archive.is_symlink(), "FAILED_CHECKPOINT_PUBLISHED_ARCHIVE")
                    demand(receipt.is_dir() and not receipt.is_symlink() and not list(receipt.iterdir()), "RECEIPT_FAILURE_FALSE_SUCCESS_RECEIPT")
                    demand(not list((root / "data").glob(".runtime-checkpoint-*")), "RECEIPT_FAILURE_LEFT_CHECKPOINT_TEMP")
                    terminal = list((root / "data").rglob("*.pending.json.terminal.json"))
                    demand(len(terminal) == 1, "RECEIPT_FAILURE_LOST_DURABLE_TAIL")
                    record.update(expectation="backup refused on receipt publication failure", archive_absent=True,
                                  false_success_receipt_absent=True, durable_tail_sha256=digest(terminal[0]))
                demand(stopped["State"]["StartedAt"] == before["State"]["StartedAt"], "NEGATIVE_PROCESS_INCARNATION_CHANGED")
                record.update(result="passed", protocol="vless", payload_bytes=sent,
                              observed_process_exit_code=stopped["State"]["ExitCode"],
                              restart_policy="no", native_authorization=False)
            finally:
                with fixture.lock:
                    private_json(self.evidence / (short + "-" + kernel + "-synthetic-fixture-observations.json"),
                                 {"fixture": "synthetic HTTP, not Core", "calls": fixture.calls, "reports": fixture.reports})
                echo.shutdown()
                echo_thread.join(timeout=5)
                with contextlib.suppress(Exception):
                    self.docker("preserved-negative-node-logs-" + short + "-" + kernel, "logs", "--tail", "200", app)

    def execute(self):
        result = "failed"
        code = None
        try:
            info = json.loads(self.docker("dedicated-daemon-info", "info", "--format", "{{json .}}"))
            demand(str(info.get("DockerRootDir", "")).startswith("/opt/txboard-baseline/p1-docker-r1/"), "FOREIGN_DOCKER_DAEMON")
            self.docker("compose-version", "compose", "version")
            image = self.create_image()
            for kernel in ("singbox", "xray"):
                self.case(kernel, image)
                self.negative_checkpoint_case(kernel, image)
                self.negative_checkpoint_case(kernel, image, normal_sigterm=True)
            result = "passed"
        except Exception as error:
            code = str(error) if isinstance(error, SmokeFailure) else "SMOKE_UNEXPECTED_FAILURE"
            diagnostic = self.evidence / "failure-private.json"
            private_json(diagnostic, {"exception_type": type(error).__module__ + "." + type(error).__qualname__,
                                      "traceback": traceback.format_exc()})
            self.artifacts.append({"step": "private-exception-diagnostic", "log": str(diagnostic),
                                   "sha256": digest(diagnostic)})
        finally:
            report = {"format": "txnode.installer-docker-smoke/v1", "result": result,
                      "failure_code": code, "docker_host": DAEMON, "cases": self.cases,
                      "node_binary_sha256": digest(self.node_binary), "cat_binary_sha256": digest(self.cat_binary),
                      "fixture": "synthetic local HTTP; not real Core", "native_authorization": False,
                      "limitations": ["No real Core database/receipt acceptance", "No finite signed authorization/TLS/offline refusal acceptance",
                                      "VLESS TCP only; no VMess or complete protocol matrix", "No full installation/update/rollback acceptance"],
                      "preserved": "No explicit cleanup; Compose may recreate its own stopped test container. Images/data/prior failed runs retained; completed scenarios stopped, receipt-refusal scenarios intentionally exit nonzero, incomplete scenarios may still run",
                      "artifacts": self.artifacts}
            private_json(self.evidence / "report.json", report)
        print(json.dumps({"result": result, "failure_code": code, "report": str(self.evidence / "report.json")}, separators=(",", ":")))
        return 0 if result == "passed" else 1


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("installer_snapshot")
    parser.add_argument("node_binary")
    parser.add_argument("evidence_new")
    parser.add_argument("cat_binary")
    args = parser.parse_args()
    try:
        return Harness(args).execute()
    except SmokeFailure as error:
        print(json.dumps({"result": "refused", "failure_code": str(error)}, separators=(",", ":")))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
