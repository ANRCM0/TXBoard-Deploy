#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export APP_NAME="tx-node-test"
export INSTALL_DIR="$TMP_ROOT/txnode"
export CLI_LINK="$TMP_ROOT/txnode-cli"
export IMAGE="ghcr.io/anrcm0/tx-node:latest"

# shellcheck source=../deploy.sh
source "$ROOT_DIR/deploy.sh"

mkdir -p "$INSTALL_DIR"
cat > "$CONFIG_FILE" <<'YAML'
panel:
  url: "https://panel.example.com"
machine:
  machine_id: 12
  token: "test-token"
YAML

cat > "$COMPOSE_FILE" <<EOF
services:
  tx-node:
    image: ghcr.io/anrcm0/tx-node:latest
    container_name: $APP_NAME
    restart: unless-stopped
    network_mode: host
    command: ["-c", "/etc/txnode/config.yml"]
    volumes:
      - $CONFIG_FILE:/etc/txnode/config.yml:ro
EOF

echo "[test] official latest compose is eligible"
remote_update_compose_supported

echo "[test] development channel is eligible for the remote bridge"
set_compose_channel dev
remote_update_compose_supported
set_compose_channel stable

echo "[test] control mount is added exactly once"
ensure_remote_update_mount
ensure_remote_update_mount
[ "$(grep -Fc "$REMOTE_UPDATE_DIR:$REMOTE_UPDATE_CONTAINER_DIR" "$COMPOSE_FILE")" -eq 1 ]

echo "[test] old Compose config target remains repairable"
cat > "$COMPOSE_FILE" <<EOF
services:
  tx-node:
    image: ghcr.io/anrcm0/tx-node:latest
    container_name: $APP_NAME
    restart: unless-stopped
    network_mode: host
    volumes:
      - $CONFIG_FILE:/etc/xboard-node/config.yml:ro
EOF
ensure_remote_update_mount
[ "$(grep -Fc "$REMOTE_UPDATE_DIR:$REMOTE_UPDATE_CONTAINER_DIR" "$COMPOSE_FILE")" -eq 1 ]

echo "[test] capability marker is bounded"
write_remote_update_capability
grep -qx 'schema=1' "$REMOTE_UPDATE_CAPABILITIES"
grep -qx 'updater_available=true' "$REMOTE_UPDATE_CAPABILITIES"
grep -qx 'target=latest,dev' "$REMOTE_UPDATE_CAPABILITIES"

echo "[test] valid latest request parses"
cat > "$REMOTE_UPDATE_REQUEST" <<'EOF'
schema=1
request_id=mup_test-01
target=latest
EOF
parse_remote_update_request "$REMOTE_UPDATE_REQUEST"
[ "$REMOTE_REQUEST_ID" = "mup_test-01" ]
[ "$REMOTE_REQUEST_TARGET" = "latest" ]

echo "[test] dev update target is accepted"
sed -i 's/^target=latest$/target=dev/' "$REMOTE_UPDATE_REQUEST"
parse_remote_update_request "$REMOTE_UPDATE_REQUEST"
[ "$REMOTE_REQUEST_TARGET" = "dev" ]

echo "[test] arbitrary image/version target is rejected"
cat > "$REMOTE_UPDATE_REQUEST" <<'EOF'
schema=1
request_id=mup_test-02
target=ghcr.io/example/other:latest
EOF
if parse_remote_update_request "$REMOTE_UPDATE_REQUEST"; then
  echo "arbitrary target unexpectedly accepted" >&2
  exit 1
fi

echo "[test] unknown execution field is rejected"
cat > "$REMOTE_UPDATE_REQUEST" <<'EOF'
schema=1
request_id=mup_test-03
target=latest
command=docker ps
EOF
if parse_remote_update_request "$REMOTE_UPDATE_REQUEST"; then
  echo "unknown field unexpectedly accepted" >&2
  exit 1
fi

echo "[test] malformed request id is rejected"
cat > "$REMOTE_UPDATE_REQUEST" <<'EOF'
schema=1
request_id=../../escape
target=latest
EOF
if parse_remote_update_request "$REMOTE_UPDATE_REQUEST"; then
  echo "unsafe request id unexpectedly accepted" >&2
  exit 1
fi

echo "[test] status writer strips line breaks and separators"
write_remote_update_status "mup_test-04" "latest" "failed" $'bad\nmessage=secret'
grep -qx 'request_id=mup_test-04' "$REMOTE_UPDATE_STATUS"
grep -qx 'target=latest' "$REMOTE_UPDATE_STATUS"
grep -qx 'status=failed' "$REMOTE_UPDATE_STATUS"
if grep -q '^message=.*=' "$REMOTE_UPDATE_STATUS"; then
  echo "status message kept an unsafe separator" >&2
  exit 1
fi
[ "$(grep -c '^message=' "$REMOTE_UPDATE_STATUS")" -eq 1 ]

echo "[test] custom compose image disables remote updater"
sed -i 's#ghcr.io/anrcm0/tx-node:latest#example.invalid/custom:latest#' "$COMPOSE_FILE"
if remote_update_compose_supported; then
  echo "custom image unexpectedly eligible" >&2
  exit 1
fi

echo "remote update bridge tests passed"
