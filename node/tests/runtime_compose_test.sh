#!/usr/bin/env bash
# Restored immutable-image Compose JSON must remain operable by the Installer.
set -euo pipefail
ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export INSTALL_DIR="$TMP/runtime" APP_NAME=runtime-compose-proof CLI_LINK="$TMP/txnode"
source "$ROOT/deploy.sh"
mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/remote-update"
printf '%s\n' 'synthetic private config' > "$CONFIG_FILE"
image_id="sha256:$(printf '%64s' '' | tr ' ' a)"
other_id="sha256:$(printf '%64s' '' | tr ' ' b)"

# These helpers manipulate a local document; no container or network operation
# is needed to verify their post-restore behavior.
docker() { printf '%s\n' "$*" >> "$TMP/unexpected-docker"; return 99; }
require_runtime_restore_clear() { return 0; }

write_fixture() {
  local origin="${1:-$REMOTE_UPDATE_IMAGE_PREFIX:latest}" bound_id="${2:-$image_id}"
  python3 - "$COMPOSE_FILE" "$INSTALL_DIR" "$APP_NAME" "$image_id" "$origin" "$bound_id" <<'PYFIXTURE'
import json, os, sys
from pathlib import Path
output, root, app, image, origin, bound = sys.argv[1:]
root = Path(root)
value = {"name": "runtime-compose-proof", "x-txnode-origin-image": origin,
         "x-txnode-origin-id": bound, "services": {"tx-node": {
    "container_name": app, "image": image, "restart": "no", "network_mode": "host",
    "command": ["-c", "/etc/txnode/config.yml"], "volumes": [
        {"type": "bind", "source": str(root / "data"), "target": "/etc/txnode"},
        {"type": "bind", "source": str(root / "config.yml"), "target": "/etc/txnode/config.yml", "read_only": True},
        {"type": "bind", "source": str(root / "remote-update"), "target": "/run/txnode-update"}]}}}
Path(output).write_text(json.dumps(value, separators=(",", ":")) + "\n")
os.chmod(output, 0o600)
PYFIXTURE
}

assert_restart() {
  python3 - "$COMPOSE_FILE" "$1" <<'PYCHECK'
import json, sys
from pathlib import Path
value = json.loads(Path(sys.argv[1]).read_text())
assert value["services"]["tx-node"]["restart"] == sys.argv[2], "restart policy was not persisted as a JSON string"
PYCHECK
}

assert_three_mounts() {
  python3 - "$COMPOSE_FILE" "$INSTALL_DIR" <<'PYCHECK'
import json, sys
from pathlib import Path
value = json.loads(Path(sys.argv[1]).read_text())
root = Path(sys.argv[2])
mounts = value["services"]["tx-node"]["volumes"]
assert len(mounts) == 3, "canonical mounts were duplicated"
assert {(m["source"], m["target"], m.get("read_only", False)) for m in mounts} == {
    (str(root / "data"), "/etc/txnode", False),
    (str(root / "config.yml"), "/etc/txnode/config.yml", True),
    (str(root / "remote-update"), "/run/txnode-update", False)}, "canonical mounts changed"
PYCHECK
}

write_fixture
[ "$(current_compose_image)" = "$image_id" ]
[ "$(current_compose_channel)" = stable ]
ensure_remote_update_mount
assert_three_mounts
compose_set_restart_policy unless-stopped
assert_restart unless-stopped
[ "$(current_compose_image)" = "$image_id" ]
[ "$(current_compose_channel)" = stable ]
compose_set_restart_policy no
assert_restart no

# Explicit upgrade selects an approved tag; pinned origin hints are consumed so
# a subsequent upgrade cannot confuse the former immutable image with the tag.
set_compose_channel dev
[ "$(current_compose_image)" = "$REMOTE_UPDATE_IMAGE_PREFIX:dev" ]
[ "$(current_compose_channel)" = dev ]
python3 - "$COMPOSE_FILE" <<'PYCHECK'
import json, sys
from pathlib import Path
value = json.loads(Path(sys.argv[1]).read_text())
assert "x-txnode-origin-image" not in value and "x-txnode-origin-id" not in value, "stale immutable-origin hints survived channel selection"
PYCHECK
assert_three_mounts
cp "$COMPOSE_FILE" "$TMP/expected"
if set_compose_channel 'ghcr.io/foreign/arbitrary:latest' >/dev/null 2>&1; then
  echo 'arbitrary channel reference was accepted' >&2
  exit 1
fi
cmp "$TMP/expected" "$COMPOSE_FILE"

# An origin hint is meaningful only for the same immutable service image.
write_fixture "$REMOTE_UPDATE_IMAGE_PREFIX:latest" "$other_id"
[ "$(current_compose_image)" = "$image_id" ]
cp "$COMPOSE_FILE" "$TMP/expected"
if current_compose_channel >/dev/null 2>&1; then
  echo 'origin hint bound to another immutable image was accepted' >&2
  exit 1
fi
if set_compose_channel dev >/dev/null 2>&1; then
  echo 'mismatched origin hint permitted automatic upgrade' >&2
  exit 1
fi
cmp "$TMP/expected" "$COMPOSE_FILE"

write_fixture 'ghcr.io/foreign/arbitrary:latest' "$image_id"
cp "$COMPOSE_FILE" "$TMP/expected"
if current_compose_channel >/dev/null 2>&1; then
  echo 'arbitrary origin reference became an official channel' >&2
  exit 1
fi
if set_compose_channel stable >/dev/null 2>&1; then
  echo 'arbitrary origin reference permitted automatic upgrade' >&2
  exit 1
fi
cmp "$TMP/expected" "$COMPOSE_FILE"

# A JSON mount with the right destination but another source is not repaired
# silently: the bounded host bridge must remain the Installer-owned directory.
write_fixture
python3 - "$COMPOSE_FILE" <<'PYCHECK'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
value = json.loads(p.read_text())
value["services"]["tx-node"]["volumes"][2]["source"] += "-foreign"
p.write_text(json.dumps(value, separators=(",", ":")) + "\n")
PYCHECK
cp "$COMPOSE_FILE" "$TMP/expected"
if ensure_remote_update_mount >/dev/null 2>&1; then
  echo 'foreign JSON update-bridge source was accepted' >&2
  exit 1
fi
cmp "$TMP/expected" "$COMPOSE_FILE"

write_fixture "$REMOTE_UPDATE_IMAGE_PREFIX:dev" "$image_id"
[ "$(current_compose_channel)" = dev ]
[ ! -e "$TMP/unexpected-docker" ]
echo 'restored immutable Compose JSON: restart, canonical mounts, approved channels and origin binding passed'
