#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export APP_NAME="tx-node-test"
export INSTALL_DIR="$TMP_ROOT/txnode"
export CLI_LINK="$TMP_ROOT/bin/txnode"
export TXNODE_ISOLATED_ROOT_BASE="$TMP_ROOT/txnode"
export TXNODE_ISOLATED_CLI_BASE="$TMP_ROOT/bin/txnode"
mkdir -p "$INSTALL_DIR" "$TMP_ROOT/bin"

source "$ROOT_DIR/deploy.sh"

assert_contains() {
  local haystack="$1" needle="$2"
  if ! grep -Fq "$needle" <<<"$haystack"; then
    echo "ASSERTION FAILED: expected to contain: $needle" >&2
    echo "---- actual ----" >&2
    echo "$haystack" >&2
    exit 1
  fi
}

assert_eq() {
  local want="$1" got="$2"
  if [ "$want" != "$got" ]; then
    echo "ASSERTION FAILED: want=$want got=$got" >&2
    exit 1
  fi
}

cat > "$CONFIG_FILE" <<'YAML'
panel:
  url: "https://panel-a.example.com"
  token: "token-a"
  node_id: 11

kernel:
  type: "singbox"

log:
  level: "info"
YAML

current_target_exists "https://panel-a.example.com" node 11
if current_target_exists "https://panel-a.example.com" node 12; then
  echo "ASSERTION FAILED: unexpected duplicate target" >&2
  exit 1
fi

wrap_config_as_instances
config_uses_instances

PANEL_URL="https://panel-b.example.com"
MODE_STR="node"
NODE_ID="22"
NODE_TOKEN="token-b"
KERNEL="xray"
LOG_LEVEL="debug"
AUDIT_ENABLED="false"
REPORT_ALL="false"

block="$TMP_ROOT/instance.yml"
render_instance_block > "$block"
append_instance_block "$block"

targets="$(config_instance_targets)"
assert_contains "$targets" $'https://panel-a.example.com\tnode\t11'
assert_contains "$targets" $'https://panel-b.example.com\tnode\t22'
current_target_exists "https://panel-b.example.com" node 22

cat > "$CONFIG_FILE" <<'YAML'
instances:
  - panel:
      url: "https://panel-a.example.com"
      token: "token-a"
      node_id: 11
    kernel:
      type: "singbox"
log:
  level: "warn"
YAML

PANEL_URL="https://panel-c.example.com"
MODE_STR="machine"
MACHINE_ID="7"
MACHINE_TOKEN="machine-token"
KERNEL="singbox"
LOG_LEVEL="info"
AUDIT_ENABLED="true"
REPORT_ALL="false"
render_instance_block > "$block"
append_instance_block "$block"

targets="$(config_instance_targets)"
assert_contains "$targets" $'https://panel-a.example.com\tnode\t11'
assert_contains "$targets" $'https://panel-c.example.com\tmachine\t7'

line_machine="$(grep -n 'machine_id: 7' "$CONFIG_FILE" | cut -d: -f1)"
line_log="$(grep -n '^log:' "$CONFIG_FILE" | cut -d: -f1)"
if [ "$line_machine" -ge "$line_log" ]; then
  echo "ASSERTION FAILED: appended instance escaped instances section" >&2
  exit 1
fi

validate_instances_config >/dev/null

docker() {
  if [ "${1:-}" = "ps" ]; then
    return 0
  fi
  return 1
}
mkdir -p "$TXNODE_ISOLATED_ROOT_BASE-2"
touch "$TXNODE_ISOLATED_CLI_BASE-3"
assert_eq "4" "$(find_next_isolated_suffix)"

INSTALL_DIR="$TMP_ROOT/isolated"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CONFIG_FILE="$INSTALL_DIR/config.yml"
BACKUP_DIR="$INSTALL_DIR/backups"
TXNODE_HEALTH_PORT="65539"
MODE_STR="node"
PANEL_URL="https://panel-d.example.com"
NODE_ID="44"
NODE_TOKEN="token-d"
KERNEL="singbox"
LOG_LEVEL="info"
AUDIT_ENABLED="false"
REPORT_ALL="false"
write_config_files >/dev/null
assert_contains "$(cat "$CONFIG_FILE")" "health_port: 65539"
assert_contains "$(cat "$COMPOSE_FILE")" "$INSTALL_DIR/data:/etc/txnode"
[ -d "$INSTALL_DIR/data" ]

echo "deploy multi-instance tests: OK"
