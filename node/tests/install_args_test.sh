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

  grep -Fxq "    image: ghcr.io/anrcm0/txboard-node:dev" "$COMPOSE_FILE"
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

# Finite signed authorization pins are optional, complete and TXBoard-only.
AUTH_PUBLIC_KEY="$(printf '%43s' '' | tr ' ' 'A')"
INSTALL_DIR="$TMP/auth" APP_NAME="tx-node-auth-test" CLI_LINK="$TMP/txnode-auth" \
bash -c '
  set -euo pipefail
  source "$1"
  parse_install_args --mode machine --provider txboard --panel-url https://core.example.test \
    --machine-id 12 --token synthetic-machine-token \
    --authorization-core-instance-id core-example-01 --authorization-key-id core-key-1 \
    --authorization-key-epoch 1 --authorization-public-key "$2"
  [ "$AUTHORIZATION_ENABLED" = true ]
  write_config_files
  grep -Fxq "authorization:" "$CONFIG_FILE"
  grep -Fxq "  enabled: true" "$CONFIG_FILE"
  ! grep -Eq "^[[:space:]]*state_dir:" "$CONFIG_FILE"
  grep -Fxq "  core_instance_id: \"core-example-01\"" "$CONFIG_FILE"
  grep -Fxq "  key_id: \"core-key-1\"" "$CONFIG_FILE"
  grep -Fxq "  key_epoch: \"1\"" "$CONFIG_FILE"
  grep -Fxq "  public_key: \"$2\"" "$CONFIG_FILE"
  ! grep -Eq "private_seed|private.key|secret" "$CONFIG_FILE"
  if [ "$(uname -s)" = Linux ]; then [ "$(stat -c %a "$CONFIG_FILE")" = 600 ]; fi
' _ "$ROOT/deploy.sh" "$AUTH_PUBLIC_KEY"

for args in \
  '--authorization-key-id partial' \
  '--authorization-core-instance-id core-example-01 --authorization-key-id key --authorization-key-epoch 1 --authorization-public-key AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA --panel-url http://core.example.test' \
  '--authorization-core-instance-id core-example-01 --authorization-key-id key --authorization-key-epoch 0 --authorization-public-key AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' \
  '--authorization-core-instance-id core-example-01 --authorization-key-id key --authorization-key-epoch 1 --authorization-public-key short'; do
  if INSTALL_DIR="$TMP/reject" bash -c 'set -euo pipefail; source "$1"; parse_install_args --mode machine --provider txboard --panel-url https://core.example.test --machine-id 12 --token token $2' _ "$ROOT/deploy.sh" "$args" >/dev/null 2>&1; then
    echo "unsafe authorization pin arguments were accepted: $args" >&2
    exit 1
  fi
done

if INSTALL_DIR="$TMP/reject-xboard" bash -c 'set -euo pipefail; source "$1"; parse_install_args --mode node --provider xboard --panel-url https://core.example.test --node-id 7 --token token --authorization-core-instance-id core-example-01 --authorization-key-id key --authorization-key-epoch 1 --authorization-public-key "$2"' _ "$ROOT/deploy.sh" "$AUTH_PUBLIC_KEY" >/dev/null 2>&1; then
  echo 'Xboard accepted finite TXBoard authorization pins' >&2
  exit 1
fi

INSTALL_DIR="$TMP/auth-instance" bash -c '
  set -euo pipefail
  source "$1"
  mkdir -p "$INSTALL_DIR"
  parse_install_args --mode node --provider txboard --panel-url https://core.example.test \
    --node-id 7 --token synthetic-node-token \
    --authorization-core-instance-id core-example-01 --authorization-key-id core-key-1 \
    --authorization-key-epoch 1 --authorization-public-key "$2"
  render_instance_block > "$INSTALL_DIR/instance.yml"
  grep -Fxq "    authorization:" "$INSTALL_DIR/instance.yml"
  grep -Fxq "      enabled: true" "$INSTALL_DIR/instance.yml"
  grep -Fxq "      public_key: \"$2\"" "$INSTALL_DIR/instance.yml"
' _ "$ROOT/deploy.sh" "$AUTH_PUBLIC_KEY"

NONCANONICAL_KEY="${AUTH_PUBLIC_KEY%?}B"
if INSTALL_DIR="$TMP/reject-key" bash -c 'set -euo pipefail; source "$1"; parse_install_args --mode node --provider txboard --panel-url https://core.example.test --node-id 7 --token token --authorization-core-instance-id core-example-01 --authorization-key-id key --authorization-key-epoch 1 --authorization-public-key "$2"' _ "$ROOT/deploy.sh" "$NONCANONICAL_KEY" >/dev/null 2>&1; then
  echo 'noncanonical Ed25519 public-key encoding was accepted' >&2
  exit 1
fi

# Existing signed state cannot be dropped by a plain rewrite.
cat > "$TMP/existing-signed.yml" <<EOF
authorization:
  enabled: true
  core_instance_id: "core-example-01"
  key_id: "core-key-1"
  key_epoch: "1"
  public_key: "$AUTH_PUBLIC_KEY"
EOF
if CONFIG_FILE="$TMP/existing-signed.yml" INSTALL_DIR="$TMP/refuse-downgrade" bash -c 'set -euo pipefail; source "$1"; authorization_enabled_in_config; AUTHORIZATION_ENABLED=false; write_config_files' _ "$ROOT/deploy.sh" >/dev/null 2>&1; then
  echo 'config rewrite silently removed signed authorization' >&2
  exit 1
fi
INSTALL_DIR="$TMP/inline-signed" bash -c '
  set -euo pipefail
  source "$1"
  mkdir -p "$INSTALL_DIR"
  printf "%s\n" "authorization: { enabled: true }" > "$CONFIG_FILE"
  authorization_enabled_in_config
  printf "%s\n" "authorization: # enrolled" "  enabled: true # keep" > "$CONFIG_FILE"
  authorization_enabled_in_config
' _ "$ROOT/deploy.sh"
echo 'finite signed authorization pin provisioning and downgrade guards: ok'

INSTALL_DIR="$TMP/preserve-signed" bash -c '
  set -euo pipefail
  mkdir -p "$INSTALL_DIR"
  CONFIG_FILE="$INSTALL_DIR/config.yml"
  cat > "$CONFIG_FILE" <<EOF
panel:
  provider: "txboard"
  url: "https://core.example.test"
machine:
  machine_id: 12
  token: "synthetic-machine-token"
authorization:
  enabled: true
  core_instance_id: "core-example-01"
  key_id: "core-key-1"
  key_epoch: "1"
  public_key: "$2"
EOF
  source "$1"
  PANEL_PROVIDER=txboard MODE_STR=machine PANEL_URL=https://core.example.test
  confirm() { return 0; }
  printf "%b" "\n\n\n\n" > "$INSTALL_DIR/answers"
  read_authorization_pin < "$INSTALL_DIR/answers"
  [ "$AUTHORIZATION_ENABLED" = true ]
  [ "$AUTHORIZATION_CORE_INSTANCE_ID" = core-example-01 ]
  [ "$AUTHORIZATION_PUBLIC_KEY" = "$2" ]
  MACHINE_ID=12 MACHINE_TOKEN=synthetic-machine-token PANEL_URL=https://core.example.test
  KERNEL=singbox LOG_LEVEL=info AUDIT_ENABLED=false REPORT_ALL=false
  write_config_files
  grep -Fq "public_key: \"$2\"" "$CONFIG_FILE"
' _ "$ROOT/deploy.sh" "$AUTH_PUBLIC_KEY"
echo 'existing signed authorization pins survive guided reconfiguration: ok'

if INSTALL_DIR="$TMP/preserve-signed" bash -c 'set -euo pipefail; source "$1"; do_restore' _ "$ROOT/deploy.sh" >/dev/null 2>&1; then
  echo 'legacy config restore was allowed to replace an enrolled configuration' >&2
  exit 1
fi
