#!/usr/bin/env python3
"""Private stopped TX-Node runtime archives (Linux, Python 3.10+).

Shell API: create --install-dir DIR --output FILE --metadata PRIVATE_JSON;
inspect --archive FILE; restore --install-dir DIR --archive FILE --metadata
PRIVATE_JSON; recover --install-dir DIR. The shell certifies stopped/image
availability with metadata: {"format":"txnode.runtime-capture/v1","install_dir":"/etc/txnode",
"component":"tx-node","stopped":true,"image_available":true,
"image_id":"sha256:<64hex>","repo_digests":["...@sha256:<64hex>"],
"layout":<public Node --backup-layout JSON>,"capture":{"kind":"already_stopped"}}
Capture kind can instead be "runtime_checkpoint"; shell verifies the current-process
receipt. Engine does no Docker, HTTP, listener or authorization operations.
Restore compares image_id and layout exactly; capture is informational.

Guard: INSTALL_PARENT/.INSTALL_NAME.runtime-restore.guard. A surviving guard
must block all lifecycle mutations except recover. Completed transactions keep
prior files under the printed safety directory. Diagnostics are fixed codes.
"""
from __future__ import annotations

import argparse
import base64
import contextlib
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tarfile
import tempfile
import uuid
from urllib.parse import urlsplit

FORMAT = "txnode.runtime-backup/v1"
MAX_FILES = 20000
MAX_BYTES = 2 * 1024**3
MAX_FILE = 512 * 1024**2
MAX_MANIFEST = 16 * 1024**2
PARTS = ("config.yml", "docker-compose.yml", "data")
STATE_KEYS = ("version", "core_instance_id", "policy_version", "node_id", "machine_id", "key_id", "public_key", "key_epoch", "revision", "issued_at", "expires_at", "last_observed_at", "payload_digest")
HEX = re.compile(r"[a-f0-9]{64}\Z")
DEC = re.compile(r"[1-9][0-9]{0,18}\Z")

class Refusal(Exception):
    pass

def refuse(code):
    raise Refusal(code)

def canonical(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode()

def pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            refuse("DUPLICATE_JSON_KEY")
        result[key] = value
    return result

def decode(raw):
    try:
        return json.loads(raw, object_pairs_hook=pairs, parse_constant=lambda _: refuse("INVALID_JSON"))
    except (ValueError, UnicodeError, RecursionError):
        refuse("INVALID_JSON")

def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

def path_safe(path, missing=False):
    path = Path(os.path.abspath(path))
    for part in (path, *path.parents):
        try:
            st = part.lstat()
        except FileNotFoundError:
            if missing:
                continue
            refuse("PATH_MISSING")
        if stat.S_ISLNK(st.st_mode):
            refuse("SYMLINK_REFUSED")
        if part != path and not stat.S_ISDIR(st.st_mode):
            refuse("PARENT_NOT_DIRECTORY")
    return path

def install_path(path):
    p = path_safe(path, missing=True)
    if p == p.parent or p.name in ("", ".", ".."):
        refuse("INSTALL_PATH_INVALID")
    path_safe(p.parent)
    return p

def read_regular(path, limit=MAX_FILE, private=False):
    path_safe(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > limit or st.st_nlink != 1:
            refuse("REGULAR_FILE_REQUIRED")
        if private and (stat.S_IMODE(st.st_mode) & 0o077 or st.st_uid != os.geteuid()):
            refuse("PRIVATE_FILE_REQUIRED")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            data = stream.read(limit + 1)
        if len(data) != st.st_size or len(data) > limit:
            refuse("FILE_CHANGED")
        return data, st
    finally:
        os.close(fd)

def write_file(path, raw, mode=0o600, uid=None, gid=None):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=False) as stream:
            stream.write(raw)
            stream.flush()
            if uid is not None:
                os.fchown(fd, uid, gid)
            os.fchmod(fd, mode)
            os.fsync(fd)
    finally:
        os.close(fd)

def safe_name(name):
    if not isinstance(name, str) or not name or len(name) > 2048 or "\\" in name or "\x00" in name:
        refuse("ARCHIVE_PATH_INVALID")
    p = PurePosixPath(name)
    if p.is_absolute() or str(p) != name or any(x in (".", "..") for x in p.parts):
        refuse("ARCHIVE_PATH_INVALID")
    if name not in PARTS and not name.startswith("data/"):
        refuse("ARCHIVE_ENTRY_UNKNOWN")
    return name

def relative_pattern(value, dynamic=False):
    if not isinstance(value, str) or not value or len(value) > 2048 or "\\" in value or "\x00" in value:
        refuse("LAYOUT_PATH_INVALID")
    sample = value.replace("{positive_id}", "1").replace("{hex24}", "a" * 24)
    if "{" in sample or "}" in sample or any(c in sample for c in "*?[]\r\n") or sample.startswith("/") or str(PurePosixPath(sample)) != sample or ".." in PurePosixPath(sample).parts:
        refuse("LAYOUT_PATH_INVALID")
    if not dynamic and "{positive_id}" in value:
        refuse("LAYOUT_PATH_INVALID")
    return value

def validate_layout(layout):
    if not isinstance(layout, dict) or set(layout) != {"format", "data_root", "checkpoint_receipt", "targets"} or layout["format"] != "txnode.backup-layout/v1" or layout["data_root"] != "/etc/txnode" or layout["checkpoint_receipt"] != ".runtime-checkpoint.json":
        refuse("LAYOUT_INVALID")
    targets = layout["targets"]
    if not isinstance(targets, list) or not 1 <= len(targets) <= 4096:
        refuse("LAYOUT_TARGETS_INVALID")
    paths = set()
    for target in targets:
        keys = {"instance_id", "provider", "panel_url", "node_id", "machine_id", "kernel", "kernel_root", "dynamic_children", "authorization", "spool_patterns"}
        if not isinstance(target, dict) or set(target) != keys or target["provider"] != "txboard" or target["kernel"] not in ("singbox", "xray") or not isinstance(target["instance_id"], str) or len(target["instance_id"]) > 128 or type(target["dynamic_children"]) is not bool:
            refuse("LAYOUT_TARGET_INVALID")
        if any(type(target[x]) is not int or target[x] < 0 for x in ("node_id", "machine_id")) or (target["dynamic_children"] and (target["node_id"] != 0 or target["machine_id"] <= 0)) or (not target["dynamic_children"] and target["node_id"] <= 0):
            refuse("LAYOUT_TARGET_ID_INVALID")
        if not isinstance(target["panel_url"], str) or any(ord(c) < 32 or ord(c) == 127 for c in target["panel_url"]):
            refuse("LAYOUT_PANEL_INVALID")
        endpoint = urlsplit(target["panel_url"])
        if endpoint is None or endpoint.scheme not in ("https", "http") or not endpoint.hostname or endpoint.username is not None or endpoint.password is not None or endpoint.query or endpoint.fragment or endpoint.path not in ("", "/"):
            refuse("LAYOUT_PANEL_INVALID")
        kernel_root = relative_pattern(target["kernel_root"])
        trust = target["authorization"]
        if not isinstance(trust, dict) or set(trust) != {"enabled", "core_instance_id", "policy_version", "key_id", "key_epoch", "public_key", "state_pattern"} or type(trust["enabled"]) is not bool:
            refuse("LAYOUT_TRUST_INVALID")
        if trust["enabled"]:
            if endpoint.scheme != "https" or not isinstance(trust["core_instance_id"], str) or not re.fullmatch(r"[A-Za-z0-9:_-]{8,80}", trust["core_instance_id"]) or trust["policy_version"] != "native-node-authorization/v1" or not isinstance(trust["key_id"], str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", trust["key_id"]) or not isinstance(trust["key_epoch"], str) or not DEC.fullmatch(trust["key_epoch"]):
                refuse("LAYOUT_TRUST_INVALID")
            try:
                public = base64.urlsafe_b64decode(trust["public_key"] + "=")
                if len(public) != 32 or base64.urlsafe_b64encode(public).decode().rstrip("=") != trust["public_key"]:
                    refuse("LAYOUT_PUBLIC_KEY_INVALID")
            except (ValueError, TypeError):
                refuse("LAYOUT_PUBLIC_KEY_INVALID")
            state_pattern = relative_pattern(trust["state_pattern"], target["dynamic_children"])
            suffix = "node-{positive_id}/state.json" if target["dynamic_children"] else "node-" + str(target["node_id"]) + "/state.json"
            if not (state_pattern == suffix or state_pattern.endswith("/" + suffix)):
                refuse("LAYOUT_STATE_PATTERN_INVALID")
            if ("state", state_pattern) in paths:
                refuse("LAYOUT_AMBIGUOUS_PATH")
            paths.add(("state", state_pattern))
        elif trust["state_pattern"]:
            refuse("LAYOUT_DISABLED_STATE_INVALID")
        prefix = "" if kernel_root == "." else kernel_root + "/"
        if target["dynamic_children"]:
            pending = prefix + "node-{positive_id}/.txnode-traffic-{hex24}.pending.json"
        else:
            key = (target["panel_url"] + "|" + str(target["node_id"]) + "|" + str(target["machine_id"]) + "|" + target["instance_id"]).encode()
            pending = prefix + ".txnode-traffic-" + hashlib.sha256(key).hexdigest()[:24] + ".pending.json"
        if target["spool_patterns"] != [pending, pending + ".terminal.json"] or ("spool", pending) in paths:
            refuse("LAYOUT_SPOOL_PATTERN_INVALID")
        paths.add(("spool", pending))
    return targets

def pattern_match(pattern, name):
    expr = re.escape("data/" + pattern).replace(re.escape("{positive_id}"), r"(?P<node>[1-9][0-9]{0,18})").replace(re.escape("{hex24}"), r"[a-f0-9]{24}")
    return re.fullmatch(expr, name)

def classified(name, layout):
    matches = []
    for target in layout["targets"]:
        trust = target["authorization"]
        if trust["enabled"]:
            match = pattern_match(trust["state_pattern"], name)
            if match:
                matches.append(("state", target, int(match.groupdict().get("node") or target["node_id"])))
        if any(pattern_match(p, name) for p in target["spool_patterns"]):
            matches.append(("spool", target, None))
    if len(matches) > 1:
        refuse("LAYOUT_AMBIGUOUS_PATH")
    return matches[0] if matches else (None, None, None)

def validate_runtime_files(entries, files, layout):
    validate_layout(layout)
    by_name = {e["path"]: e for e in entries}
    for name, body in files.items():
        kind, target, node_id = classified(name, layout)
        if kind == "state":
            state = state_read(body)
            trust = target["authorization"]
            machine_id = target["machine_id"] or None
            if state["node_id"] != node_id or state["machine_id"] != machine_id or state["core_instance_id"] != trust["core_instance_id"] or state["policy_version"] != trust["policy_version"] or int(state["key_epoch"]) > int(trust["key_epoch"]) or state["key_epoch"] == trust["key_epoch"] and (state["key_id"] != trust["key_id"] or state["public_key"] != trust["public_key"]):
                refuse("AUTHORIZATION_LAYOUT_TRUST_CONFLICT")
            if by_name[name]["mode"] & 0o077:
                refuse("AUTHORIZATION_STATE_NOT_PRIVATE")
        elif kind == "spool":
            if len(body) > 64 * 1024**2:
                refuse("TRAFFIC_SPOOL_TOO_LARGE")
        elif is_spool(name):
            refuse("UNDECLARED_TRAFFIC_SPOOL")
        elif name.startswith("data/") and name.endswith("/state.json"):
            try:
                candidate = decode(body)
            except Refusal:
                continue
            if isinstance(candidate, dict) and ("state" in candidate or "digest" in candidate):
                refuse("UNDECLARED_AUTHORIZATION_STATE")


def metadata_read(path):
    raw, _ = read_regular(path, MAX_MANIFEST, private=True)
    m = decode(raw)
    required = {"format", "install_dir", "component", "stopped", "image_available", "image_id", "repo_digests", "layout", "capture"}
    if not isinstance(m, dict) or not required.issubset(m) or set(m) - required - {"restore_compose"} or m["format"] != "txnode.runtime-capture/v1" or m["component"] != "tx-node":
        refuse("METADATA_INVALID")
    if m["stopped"] is not True or m["image_available"] is not True:
        refuse("STOPPED_AVAILABLE_IMAGE_REQUIRED")
    if not isinstance(m["install_dir"], str) or not m["install_dir"].startswith("/"):
        refuse("METADATA_INSTALL_DIR_INVALID")
    if not isinstance(m["image_id"], str) or not re.fullmatch(r"sha256:[a-f0-9]{64}", m["image_id"]):
        refuse("IMAGE_ID_INVALID")
    digests = m["repo_digests"]
    if not isinstance(digests, list) or len(digests) > 100 or any(not isinstance(d, str) or not re.fullmatch(r"[^\s@]+@sha256:[a-f0-9]{64}", d) for d in digests):
        refuse("IMAGE_DIGEST_INVALID")
    if not isinstance(m["layout"], dict) or not m["layout"] or not isinstance(m["capture"], dict) or m["capture"].get("kind") not in ("already_stopped", "runtime_checkpoint"):
        refuse("LAYOUT_OR_CAPTURE_INVALID")
    if "restore_compose" in m and (not isinstance(m["restore_compose"], str) or len(m["restore_compose"].encode()) > MAX_MANIFEST):
        refuse("RESTORE_COMPOSE_INVALID")
    validate_layout(m["layout"])
    return m

def inventory(root):
    entries, total = [], 0
    for top in PARTS:
        p = root / top
        if not p.exists() and not p.is_symlink():
            refuse("BUNDLE_COMPONENT_MISSING")
        pending = [(top, p)]
        while pending:
            name, p = pending.pop()
            st = p.lstat()
            if st.st_mode & 0o7000:
                refuse("SPECIAL_MODE_REFUSED")
            record = {"path": safe_name(name), "mode": stat.S_IMODE(st.st_mode), "uid": st.st_uid, "gid": st.st_gid}
            if stat.S_ISDIR(st.st_mode):
                if name in PARTS[:2]:
                    refuse("CONFIG_NOT_REGULAR")
                record.update(type="directory", size=0, sha256=None)
                for child in sorted(p.iterdir(), reverse=True):
                    pending.append((name + "/" + child.name, child))
            elif stat.S_ISREG(st.st_mode) and name != "data":
                raw, after = read_regular(p)
                if after.st_ino != st.st_ino or after.st_dev != st.st_dev:
                    refuse("FILE_CHANGED")
                total += len(raw)
                record.update(type="file", size=len(raw), sha256=hashlib.sha256(raw).hexdigest())
            else:
                refuse("LINK_OR_SPECIAL_FILE_REFUSED")
            entries.append(record)
            if len(entries) > MAX_FILES or total > MAX_BYTES:
                refuse("BUNDLE_LIMIT_EXCEEDED")
    return sorted(entries, key=lambda x: x["path"])

def guard_path(root):
    return root.parent / ("." + root.name + ".runtime-restore.guard")

def check_no_guard(root):
    p = guard_path(root)
    if p.exists() or p.is_symlink():
        refuse("RESTORE_RECOVERY_REQUIRED")

def create(root, output, meta):
    root = install_path(root)
    check_no_guard(root)
    path_safe(root)
    m = metadata_read(meta)
    if m["install_dir"] != str(root):
        refuse("METADATA_INSTALL_DIR_MISMATCH")
    entries = inventory(root)
    source_files = {e["path"]: read_regular(root / e["path"])[0] for e in entries if e["type"] == "file"}
    validate_runtime_files(entries, source_files, m["layout"])
    output = path_safe(output, missing=True)
    if output.exists() or output.is_symlink():
        refuse("OUTPUT_EXISTS")
    path_safe(output.parent)
    if output == root or root / "data" in output.parents:
        refuse("OUTPUT_INSIDE_RUNTIME_DATA")
    manifest = {"format": FORMAT, "component": "tx-node", "install_dir": str(root), "image_id": m["image_id"], "repo_digests": m["repo_digests"], "layout": m["layout"], "capture": m["capture"], "entries": entries}
    manifest_raw = canonical(manifest)
    if len(manifest_raw) > MAX_MANIFEST:
        refuse("MANIFEST_TOO_LARGE")
    fd, tmp = tempfile.mkstemp(prefix=".runtime-backup-", dir=output.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as stream:
            with tarfile.open(fileobj=stream, mode="w", format=tarfile.USTAR_FORMAT) as tar:
                info = tarfile.TarInfo("MANIFEST.json")
                info.size, info.mode = len(manifest_raw), 0o600
                tar.addfile(info, io.BytesIO(manifest_raw))
                for item in entries:
                    info = tarfile.TarInfo(item["path"])
                    info.uid, info.gid, info.mode, info.size = item["uid"], item["gid"], item["mode"], item["size"]
                    info.type = tarfile.DIRTYPE if item["type"] == "directory" else tarfile.REGTYPE
                    raw = None
                    if item["type"] == "file":
                        raw, _ = read_regular(root / item["path"])
                        if hashlib.sha256(raw).hexdigest() != item["sha256"]:
                            refuse("SOURCE_CHANGED")
                    tar.addfile(info, io.BytesIO(raw) if raw is not None else None)
            stream.flush()
            os.fsync(stream.fileno())
        # Exclusive publication never overwrites another backup.
        os.link(tmp, output, follow_symlinks=False)
        fsync_dir(output.parent)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)
    return {"format": FORMAT, "result": "created", "file_count": len(entries), "capture_kind": m["capture"]["kind"]}

def validate_manifest(m):
    keys = {"format", "component", "install_dir", "image_id", "repo_digests", "layout", "capture", "entries"}
    if not isinstance(m, dict) or set(m) != keys or m["format"] != FORMAT or m["component"] != "tx-node":
        refuse("MANIFEST_INVALID")
    if not isinstance(m["install_dir"], str) or not m["install_dir"].startswith("/") or str(Path(m["install_dir"])) != m["install_dir"]:
        refuse("MANIFEST_INSTALL_PATH_INVALID")
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", str(m["image_id"])) or not isinstance(m["layout"], dict) or not isinstance(m["capture"], dict) or m["capture"].get("kind") not in ("already_stopped", "runtime_checkpoint"):
        refuse("MANIFEST_IDENTITY_INVALID")
    digests = m["repo_digests"]
    if not isinstance(digests, list) or len(digests) > 100 or any(not isinstance(d, str) or not re.fullmatch(r"[^\s@]+@sha256:[a-f0-9]{64}", d) for d in digests):
        refuse("MANIFEST_IMAGE_DIGEST_INVALID")
    validate_layout(m["layout"])
    entries = m["entries"]
    if not isinstance(entries, list) or len(entries) > MAX_FILES:
        refuse("MANIFEST_LIMIT_EXCEEDED")
    names, total = set(), 0
    for e in entries:
        if not isinstance(e, dict) or set(e) != {"path", "mode", "uid", "gid", "type", "size", "sha256"}:
            refuse("MANIFEST_ENTRY_INVALID")
        name = safe_name(e["path"])
        if name in names:
            refuse("ARCHIVE_DUPLICATE_ENTRY")
        names.add(name)
        if any(type(e[x]) is not int or e[x] < 0 for x in ("mode", "uid", "gid", "size")) or e["mode"] > 0o777 or e["uid"] > 2**32 - 1 or e["gid"] > 2**32 - 1 or e["size"] > MAX_FILE:
            refuse("MANIFEST_ATTRIBUTES_INVALID")
        if e["type"] == "file":
            if not isinstance(e["sha256"], str) or not HEX.fullmatch(e["sha256"]) or name == "data":
                refuse("MANIFEST_HASH_INVALID")
        elif e["type"] == "directory":
            if e["size"] != 0 or e["sha256"] is not None or name in PARTS[:2]:
                refuse("MANIFEST_DIRECTORY_INVALID")
        else:
            refuse("MANIFEST_TYPE_INVALID")
        total += e["size"]
    if total > MAX_BYTES or entries != sorted(entries, key=lambda x: x["path"]) or not set(PARTS).issubset(names):
        refuse("MANIFEST_INVENTORY_INVALID")
    directories = {e["path"] for e in entries if e["type"] == "directory"}
    for name in names:
        if "/" in name and str(PurePosixPath(name).parent) not in directories:
            refuse("MANIFEST_PARENT_MISSING")

def load_archive(path):
    path_safe(path)
    raw, _ = read_regular(path, MAX_BYTES + MAX_FILES * 1024 + MAX_MANIFEST)
    try:
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as tar:
            first = tar.next()
            if first is None or first.name != "MANIFEST.json" or not first.isreg() or first.size > MAX_MANIFEST or first.pax_headers:
                refuse("MANIFEST_MISSING")
            manifest = decode(tar.extractfile(first).read())
            validate_manifest(manifest)
            expected = {e["path"]: e for e in manifest["entries"]}
            files, seen = {}, set()
            for member in tar:
                if member is first:
                    continue
                name = safe_name(member.name)
                if name in seen:
                    refuse("ARCHIVE_DUPLICATE_ENTRY")
                seen.add(name)
                e = expected.get(name)
                if e is None or member.pax_headers or member.type not in (tarfile.REGTYPE, tarfile.DIRTYPE) or member.linkname or member.size != e["size"] or member.mode != e["mode"] or member.uid != e["uid"] or member.gid != e["gid"] or member.isdir() != (e["type"] == "directory"):
                    refuse("ARCHIVE_ENTRY_MISMATCH")
                if member.isreg():
                    body = tar.extractfile(member).read(MAX_FILE + 1)
                    if len(body) != e["size"] or hashlib.sha256(body).hexdigest() != e["sha256"]:
                        refuse("ARCHIVE_HASH_MISMATCH")
                    files[name] = body
            if seen != set(expected):
                refuse("ARCHIVE_INCOMPLETE")
            # tarfile ignores trailing garbage; only zero trailer padding is allowed.
            offset = tar.offset
            if any(raw[offset:]):
                refuse("ARCHIVE_TRAILING_DATA")
            validate_runtime_files(manifest["entries"], files, manifest["layout"])
            return manifest, files
    except (tarfile.TarError, EOFError, OSError):
        refuse("ARCHIVE_INVALID")

def state_read(raw):
    if len(raw) > 8192:
        refuse("AUTHORIZATION_STATE_INVALID")
    record = decode(raw)
    if not isinstance(record, dict) or set(record) != {"state", "digest"} or not isinstance(record["state"], dict) or set(record["state"]) != set(STATE_KEYS):
        refuse("AUTHORIZATION_STATE_INVALID")
    state = record["state"]
    ordered = {k: state[k] for k in STATE_KEYS}
    # Go encoding/json escapes HTML and these Unicode line separators.
    encoded = canonical(ordered).replace(b"<", b"\\u003c").replace(b">", b"\\u003e").replace(b"&", b"\\u0026").replace("\u2028".encode(), b"\\u2028").replace("\u2029".encode(), b"\\u2029")
    if record["digest"] != hashlib.sha256(encoded).hexdigest():
        refuse("AUTHORIZATION_STATE_DIGEST_INVALID")
    if type(state["version"]) is not int or state["version"] != 1 or type(state["node_id"]) is not int or state["node_id"] <= 0 or state["machine_id"] is not None and (type(state["machine_id"]) is not int or state["machine_id"] <= 0):
        refuse("AUTHORIZATION_STATE_INVALID")
    if any(not isinstance(state[k], str) or not state[k] for k in ("core_instance_id", "policy_version", "key_id", "public_key", "key_epoch", "revision", "payload_digest")):
        refuse("AUTHORIZATION_STATE_INVALID")
    if not DEC.fullmatch(state["key_epoch"]) or not DEC.fullmatch(state["revision"]) or not HEX.fullmatch(state["payload_digest"]):
        refuse("AUTHORIZATION_STATE_INVALID")
    if any(type(state[k]) is not int or state[k] < 0 for k in ("issued_at", "expires_at", "last_observed_at")) or not 0 < state["expires_at"] - state["issued_at"] <= 120:
        refuse("AUTHORIZATION_STATE_INVALID")
    return state

def state_merge(archived, current):
    a, c = state_read(archived), state_read(current)
    for k in ("core_instance_id", "policy_version", "node_id", "machine_id", "key_id", "public_key"):
        if a[k] != c[k]:
            refuse("AUTHORIZATION_TRUST_CONFLICT")
    av = (int(a["key_epoch"]), int(a["revision"]), a["issued_at"], a["last_observed_at"])
    cv = (int(c["key_epoch"]), int(c["revision"]), c["issued_at"], c["last_observed_at"])
    if av[:2] == cv[:2] and archived != current:
        refuse("AUTHORIZATION_EQUAL_REVISION_CONFLICT")
    if all(cval >= aval for aval, cval in zip(av, cv)):
        return current
    if all(aval >= cval for aval, cval in zip(av, cv)):
        return archived
    refuse("AUTHORIZATION_HIGH_WATER_CONFLICT")

def is_spool(name):
    base = PurePosixPath(name).name
    return name.startswith("data/") and base.startswith(".txnode-traffic-") and (base.endswith(".pending.json") or base.endswith(".pending.json.terminal.json"))

def add_current(entries, files, current, current_files, layout):
    by_name = {e["path"]: dict(e) for e in entries}
    current_by = {e["path"]: e for e in current}
    validate_runtime_files(current, current_files, layout)
    for name, body in current_files.items():
        kind, _, _ = classified(name, layout)
        if kind == "state":
            state_read(body)
            if name in files:
                body = state_merge(files[name], body)
                if body == files[name]:
                    continue
            entry = current_by[name]
        elif kind == "spool":
            if name in files:
                if files[name] != body:
                    refuse("TRAFFIC_SPOOL_CONFLICT")
                continue
            entry = current_by[name]
        else:
            continue
        for parent in PurePosixPath(name).parents:
            parent_name = str(parent)
            if parent_name == ".":
                break
            if parent_name not in by_name:
                if parent_name not in current_by or current_by[parent_name]["type"] != "directory":
                    refuse("PRESERVATION_PARENT_INVALID")
                by_name[parent_name] = dict(current_by[parent_name])
        by_name[name] = dict(entry)
        files[name] = body
    result = sorted(by_name.values(), key=lambda x: x["path"])
    validate_runtime_files(result, files, layout)
    return result

def materialize(root, entries, files):
    root.mkdir(mode=0o700)
    for e in sorted(entries, key=lambda x: (len(PurePosixPath(x["path"]).parts), x["path"])):
        target = root / e["path"]
        if e["type"] == "directory":
            target.mkdir(mode=0o700)
        else:
            write_file(target, files[e["path"]], e["mode"], e["uid"], e["gid"])
    for e in sorted(entries, key=lambda x: len(PurePosixPath(x["path"]).parts), reverse=True):
        if e["type"] == "directory":
            target = root / e["path"]
            os.chown(target, e["uid"], e["gid"], follow_symlinks=False)
            os.chmod(target, e["mode"], follow_symlinks=False)
            fsync_dir(target)
    fsync_dir(root)

def atomic_json(path, value):
    fd, tmp = tempfile.mkstemp(prefix=".intent-", dir=path.parent)
    os.close(fd)
    os.unlink(tmp)
    try:
        write_file(tmp, canonical(value))
        os.replace(tmp, path)
        fsync_dir(path.parent)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)

def fault(point):
    # Explicit test-only process failure, never used by the installer.
    if os.environ.get("TXNODE_RUNTIME_BACKUP_TEST_FAIL_AFTER") == point:
        raise Refusal("TEST_INTERRUPTION_" + point.upper().replace("-", "_"))

def restore(root, archive, meta, before_publish=None):
    root = install_path(root)
    check_no_guard(root)
    metadata = metadata_read(meta)
    manifest, files = load_archive(archive)
    if manifest["install_dir"] != str(root) or metadata["install_dir"] != str(root) or metadata["image_id"] != manifest["image_id"] or metadata["layout"] != manifest["layout"]:
        refuse("SAME_DEPLOYMENT_AND_IMAGE_REQUIRED")
    current = []
    current_files = {}
    if root.exists():
        path_safe(root)
        present = [(root / p).exists() or (root / p).is_symlink() for p in PARTS]
        if any(present) and not all(present):
            refuse("PARTIAL_DEPLOYMENT_REFUSED")
        if all(present):
            current = inventory(root)
            for e in current:
                if e["type"] == "file":
                    current_files[e["path"]], _ = read_regular(root / e["path"])
            if current_files["config.yml"] != files["config.yml"]:
                refuse("CONFIGURATION_CHANGED_REENROLL_REQUIRED")
    entries = add_current(manifest["entries"], files, current, current_files, manifest["layout"])
    if "restore_compose" in metadata:
        body = metadata["restore_compose"].encode()
        # The caller supplies canonical Compose JSON pinned to the verified image.
        composition = decode(body)
        services = composition.get("services", {}) if isinstance(composition, dict) else {}
        if set(services) != {"tx-node"} or not isinstance(services["tx-node"], dict) or services["tx-node"].get("image") != metadata["image_id"] or services["tx-node"].get("restart") != "no":
            refuse("RESTORE_COMPOSE_NOT_PINNED_AND_STOPPED")
        files["docker-compose.yml"] = body
        for entry in entries:
            if entry["path"] == "docker-compose.yml":
                entry["size"] = len(body)
                entry["sha256"] = hashlib.sha256(body).hexdigest()
    txn = root.parent / ("." + root.name + ".runtime-restore-" + uuid.uuid4().hex)
    txn.mkdir(mode=0o700)
    stage, previous = txn / "new", txn / "previous"
    materialize(stage, entries, files)
    previous.mkdir(mode=0o700)
    fsync_dir(txn)
    intent = {"format": "txnode.runtime-restore/v1", "install_dir": str(root), "transaction": str(txn), "entries": entries, "layout": manifest["layout"], "old_entries": current, "old_present": {p: (root / p).exists() for p in PARTS}}
    atomic_json(txn / "intent.json", intent)
    # The orchestrator can recheck the stopped container incarnation and disable
    # its restart policy only after every private file/layout arbitration passed.
    # A refused callback leaves durable orphan staging, with no guard/live rename.
    if before_publish is not None:
        before_publish()
    # Guard publication is exclusive. Intent/staging are already durable.
    write_file(guard_path(root), canonical({"format": "txnode.runtime-guard/v1", "transaction": str(txn)}))
    fsync_dir(root.parent)
    fault("guard")
    return recover(root)

def match_part(base, part, entries):
    expected = [e for e in entries if e["path"] == part or e["path"].startswith(part + "/")]
    # Verify only one component while retaining the complete inventory validator.
    path = base / part
    if not path.exists() and not path.is_symlink():
        return False
    actual = []
    pending = [(part, path)]
    while pending:
        name, p = pending.pop()
        st = p.lstat()
        e = {"path": name, "mode": stat.S_IMODE(st.st_mode), "uid": st.st_uid, "gid": st.st_gid}
        if stat.S_ISDIR(st.st_mode):
            e.update(type="directory", size=0, sha256=None)
            pending += [(name + "/" + c.name, c) for c in p.iterdir()]
        elif stat.S_ISREG(st.st_mode):
            body, _ = read_regular(p)
            e.update(type="file", size=len(body), sha256=hashlib.sha256(body).hexdigest())
        else:
            refuse("RECOVERY_PATH_UNSAFE")
        actual.append(e)
    return sorted(actual, key=lambda e: e["path"]) == expected

def recover(root):
    root = install_path(root)
    guard = guard_path(root)
    raw, _ = read_regular(guard, MAX_MANIFEST, private=True)
    g = decode(raw)
    if not isinstance(g, dict) or set(g) != {"format", "transaction"} or g["format"] != "txnode.runtime-guard/v1" or not isinstance(g["transaction"], str):
        refuse("RECOVERY_GUARD_INVALID")
    txn = Path(g["transaction"])
    if txn.parent != root.parent or not re.fullmatch(re.escape("." + root.name + ".runtime-restore-") + r"[a-f0-9]{32}", txn.name):
        refuse("RECOVERY_TRANSACTION_INVALID")
    path_safe(txn)
    st = txn.lstat()
    if st.st_uid != os.geteuid() or stat.S_IMODE(st.st_mode) != 0o700:
        refuse("RECOVERY_TRANSACTION_INVALID")
    raw, _ = read_regular(txn / "intent.json", MAX_MANIFEST, private=True)
    intent = decode(raw)
    if not isinstance(intent, dict) or set(intent) != {"format", "install_dir", "transaction", "entries", "layout", "old_entries", "old_present"} or intent["format"] != "txnode.runtime-restore/v1" or intent["install_dir"] != str(root) or intent["transaction"] != str(txn) or not isinstance(intent["old_present"], dict) or set(intent["old_present"]) != set(PARTS) or any(type(x) is not bool for x in intent["old_present"].values()):
        refuse("RECOVERY_INTENT_INVALID")
    # Reuse manifest schema checks for all recorded file evidence.
    skeleton = {"format": FORMAT, "component": "tx-node", "install_dir": str(root), "image_id": "sha256:" + "0" * 64, "repo_digests": [], "layout": intent["layout"], "capture": {"kind": "already_stopped"}, "entries": intent["entries"]}
    validate_manifest(skeleton)
    if intent["old_entries"]:
        validate_manifest(dict(skeleton, entries=intent["old_entries"]))
    elif any(intent["old_present"].values()):
        refuse("RECOVERY_OLD_EVIDENCE_INVALID")
    stage, previous = txn / "new", txn / "previous"
    path_safe(stage)
    path_safe(previous)
    if set(p.name for p in txn.iterdir()) - {"new", "previous", "intent.json", "complete.json"} or set(p.name for p in stage.iterdir()) - set(PARTS) or set(p.name for p in previous.iterdir()) - set(PARTS):
        refuse("RECOVERY_UNKNOWN_EVIDENCE")
    if (txn / "complete.json").exists():
        completed_raw, _ = read_regular(txn / "complete.json", MAX_MANIFEST, private=True)
        if decode(completed_raw) != {"format": "txnode.runtime-restore-complete/v1", "install_dir": str(root)}:
            refuse("RECOVERY_COMPLETION_INVALID")
    root.mkdir(mode=0o700, exist_ok=True)
    path_safe(root)
    fsync_dir(root.parent)
    # Validate *every* old/new placement before the first recovery mutation.
    states = []
    for p in PARTS:
        live, new, old = root / p, stage / p, previous / p
        has_live = live.exists() or live.is_symlink()
        has_new = new.exists() or new.is_symlink()
        has_old = old.exists() or old.is_symlink()
        if has_old and (not intent["old_present"][p] or not match_part(previous, p, intent["old_entries"])):
            refuse("RECOVERY_OLD_EVIDENCE_INVALID")
        if has_new:
            if not match_part(stage, p, intent["entries"]) or has_live and has_old:
                refuse("RECOVERY_NEW_EVIDENCE_INVALID")
            if has_live and (not intent["old_present"][p] or not match_part(root, p, intent["old_entries"])):
                refuse("RECOVERY_LIVE_EVIDENCE_INVALID")
            if intent["old_present"][p] and not has_live and not has_old:
                refuse("RECOVERY_PREVIOUS_MISSING")
        elif not has_live or not match_part(root, p, intent["entries"]) or intent["old_present"][p] != has_old:
            refuse("RECOVERY_PUBLISHED_EVIDENCE_INVALID")
        states.append((p, has_live, has_new))
    for p, has_live, has_new in states:
        if not has_new:
            continue
        if has_live:
            os.rename(root / p, previous / p)
            fsync_dir(root)
            fsync_dir(previous)
            fault("old-" + p.replace(".", "-"))
        os.rename(stage / p, root / p)
        fsync_dir(stage)
        fsync_dir(root)
        fault("new-" + p.replace(".", "-"))
    # Durable completion receipt survives the final guard removal.
    atomic_json(txn / "complete.json", {"format": "txnode.runtime-restore-complete/v1", "install_dir": str(root)})
    fault("complete")
    guard.unlink()
    fsync_dir(root.parent)
    return {"format": FORMAT, "result": "restored_stopped", "safety_dir": str(previous)}

def inspect(archive):
    manifest, _ = load_archive(archive)
    return {k: manifest[k] for k in ("format", "component", "install_dir", "image_id", "repo_digests", "layout", "capture")} | {"file_count": len(manifest["entries"])}

@contextlib.contextmanager
def operation_lock(root):
    root = install_path(root)
    path = root.parent / ("." + root.name + ".runtime-operation.lock")
    inherited = os.environ.get("TXNODE_RUNTIME_LOCK_FD")
    if inherited is not None:
        if not inherited.isdigit():
            refuse("OPERATION_LOCK_INVALID")
        fd = int(inherited)
        st = os.fstat(fd)
        disk = path.lstat()
        if stat.S_ISLNK(disk.st_mode) or (st.st_dev, st.st_ino) != (disk.st_dev, disk.st_ino):
            refuse("OPERATION_LOCK_INVALID")
        owns_fd = False
    else:
        path_safe(path, missing=True)
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        st = os.fstat(fd)
        owns_fd = True
    try:
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or stat.S_IMODE(st.st_mode) != 0o600 or st.st_nlink != 1:
            refuse("OPERATION_LOCK_INVALID")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            refuse("OPERATION_ALREADY_RUNNING")
        yield
    finally:
        if owns_fd:
            os.close(fd)


def main():
    parser = argparse.ArgumentParser(description="Private same-deployment TX-Node runtime archive")
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("create")
    p.add_argument("--install-dir", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--metadata", required=True)
    p = commands.add_parser("inspect")
    p.add_argument("--archive", required=True)
    p = commands.add_parser("restore")
    p.add_argument("--install-dir", required=True)
    p.add_argument("--archive", required=True)
    p.add_argument("--metadata", required=True)
    p = commands.add_parser("recover")
    p.add_argument("--install-dir", required=True)
    args = parser.parse_args()
    if sys.platform != "linux" or sys.version_info < (3, 10):
        refuse("LINUX_PYTHON_310_REQUIRED")
    if args.command == "inspect":
        result = inspect(args.archive)
    else:
        with operation_lock(args.install_dir):
            if args.command == "create":
                result = create(args.install_dir, args.output, args.metadata)
            elif args.command == "restore":
                result = restore(args.install_dir, args.archive, args.metadata)
            else:
                result = recover(args.install_dir)
    print(json.dumps(result, separators=(",", ":")))

if __name__ == "__main__":
    try:
        main()
    except Refusal as exc:
        print("TXNODE_RUNTIME_BACKUP_" + str(exc), file=sys.stderr)
        sys.exit(2)
    except (OSError, ValueError, TypeError, KeyError, OverflowError, RecursionError):
        print("TXNODE_RUNTIME_BACKUP_OPERATION_REFUSED", file=sys.stderr)
        sys.exit(2)
