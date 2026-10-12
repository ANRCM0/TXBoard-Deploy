#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

INSTALL_DIR="$TMP/txnode" \
APP_NAME="tx-node-test" \
CLI_LINK="$TMP/txnode-cli" \
bash -c '
  set -euo pipefail
  source "$1"

  parse_install_args \
    --mode machine \
    --provider txboard \
    --channel dev \
    --panel-url "https://panel.example.com/" \
    --machine-id 42 \
    --token "machine-token-123" \
    --kernel singbox \
    --log-level info

  [ "$NONINTERACTIVE_INSTALL" = "1" ]
  [ "$MODE_STR" = "machine" ]
  [ "$PANEL_PROVIDER" = "txboard" ]
  [ "$INSTALL_CHANNEL" = "dev" ]
  [ "$PANEL_URL" = "https://panel.example.com" ]
  [ "$MACHINE_ID" = "42" ]
  [ "$MACHINE_TOKEN" = "machine-token-123" ]
  [ "$AUDIT_ENABLED" = "false" ]

  write_config_files

  grep -Fxq "  url: \"https://panel.example.com\"" "$CONFIG_FILE"
  grep -Fxq "  provider: \"txboard\"" "$CONFIG_FILE"
  grep -Fxq "machine:" "$CONFIG_FILE"
  grep -Fxq "  machine_id: 42" "$CONFIG_FILE"
  grep -Fxq "  token: \"machine-token-123\"" "$CONFIG_FILE"
  grep -Fxq "  type: \"singbox\"" "$CONFIG_FILE"
  grep -Fxq "  enabled: false" "$CONFIG_FILE"

  grep -Fxq "    image: ghcr.io/anrcm0/tx-node:dev" "$COMPOSE_FILE"
  grep -Fxq "    network_mode: host" "$COMPOSE_FILE"
  grep -Fxq "    command: [\"-c\", \"/etc/txnode/config.yml\"]" "$COMPOSE_FILE"
  grep -Fxq "      - $INSTALL_DIR/data:/etc/txnode" "$COMPOSE_FILE"
  grep -Fxq "      - $CONFIG_FILE:/etc/txnode/config.yml:ro" "$COMPOSE_FILE"
  [ -d "$INSTALL_DIR/data" ]
  if grep -Fq "$CONFIG_FILE:/etc/xboard-node/config.yml:ro" "$COMPOSE_FILE"; then
    echo "new install still writes the legacy container config target" >&2
    exit 1
  fi
' _ "$ROOT/deploy.sh"

echo "non-interactive machine install config: ok"

# Existing docker deployment + non-interactive install must append a panel
# instance instead of overwriting the existing config.
INSTALL_DIR="$TMP/existing" \
APP_NAME="tx-node-existing" \
CLI_LINK="$TMP/txnode-existing-cli" \
bash -c '
  set -euo pipefail
  source "$1"

  ensure_docker() { :; }
  detect_deploy_mode() { DEPLOY_MODE="docker"; }
  is_installed() { return 0; }
  appended=0
  current_compose_channel() { echo stable; }
  do_add_panel_instance() {
    [ "${NONINTERACTIVE_INSTALL:-0}" = "1" ]
    [ "$MODE_STR" = "machine" ]
    [ "$PANEL_URL" = "https://panel-b.example.com" ]
    [ "$MACHINE_ID" = "7" ]
    [ "$MACHINE_TOKEN" = "token-b" ]
    appended=1
  }

  do_install \
    --mode machine \
    --panel-url "https://panel-b.example.com/" \
    --machine-id 7 \
    --token "token-b"

  [ "$appended" = "1" ]
' _ "$ROOT/deploy.sh"

echo "existing install non-interactive append path: ok"
