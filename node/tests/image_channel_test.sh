#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export INSTALL_DIR="$TMP/runtime"
export APP_NAME="channel-test"
export CLI_LINK="$TMP/txnode-cli"
source "$ROOT/deploy.sh"
mkdir -p "$INSTALL_DIR"
cat > "$COMPOSE_FILE" <<EOF
services:
  tx-node:
    image: ghcr.io/anrcm0/tx-node:latest
    volumes:
      - $INSTALL_DIR/data:/etc/txnode
EOF
[ "$(official_image_for_channel stable)" = 'ghcr.io/anrcm0/tx-node:latest' ]
[ "$(official_image_for_channel dev)" = 'ghcr.io/anrcm0/tx-node:dev' ]
if official_image_for_channel 'other/image:latest' >/dev/null; then exit 1; fi
[ "$(current_compose_channel)" = stable ]
set_compose_channel dev
[ "$(current_compose_channel)" = dev ]
set_compose_channel stable
[ "$(current_compose_channel)" = stable ]

docker() {
  if [ "$1" = "inspect" ]; then printf 'sha256:existing\n'; return 0; fi
  if [ "$1" = "image" ] || [ "$1" = "tag" ]; then return 0; fi
  return 0
}
dc() { if [ "$1" = pull ] && [ "$PULL_RESULT" = fail ]; then return 1; fi; return 0; }
reset_container() { return 0; }
guarded_compose_start() {
  if [ "$GUARD_RESULT" = fail ]; then GUARD_RESULT=ok; return 1; fi
  return 0
}
PULL_RESULT=ok
GUARD_RESULT=ok
perform_docker_upgrade dev
[ "$UPGRADE_OUTCOME" = succeeded ]
[ "$(current_compose_channel)" = dev ]
PULL_RESULT=fail
if perform_docker_upgrade stable; then echo "pull failure accepted" >&2; exit 1; fi
[ "$(current_compose_channel)" = dev ]
PULL_RESULT=ok
GUARD_RESULT=fail
if perform_docker_upgrade stable; then echo "bad health accepted" >&2; exit 1; fi
[ "$UPGRADE_OUTCOME" = rolled_back ]
[ "$(current_compose_channel)" = dev ]
if set_compose_channel 'ghcr.io/evil/test:latest'; then echo "arbitrary image accepted" >&2; exit 1; fi
grep -Fq "$INSTALL_DIR/data:/etc/txnode" "$COMPOSE_FILE"
echo "image channel and rollback tests passed"
