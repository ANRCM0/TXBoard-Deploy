#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export INSTALL_DIR="$TMP_ROOT/txnode"
export CLI_LINK="$TMP_ROOT/bin/txnode"
export XBCTL_COMPAT_PATH="$TMP_ROOT/bin/xbctl-compat"
mkdir -p "$INSTALL_DIR" "$TMP_ROOT/bin"

# shellcheck source=../deploy.sh
source "$ROOT_DIR/deploy.sh"

LEGACY_INSTALL_ROOT="$TMP_ROOT/xboard-node"
LEGACY_CONFIG_FILE="$LEGACY_INSTALL_ROOT/config.yml"
LEGACY_CREDENTIALS_FILE="$LEGACY_INSTALL_ROOT/credentials.env"
LEGACY_META_FILE="$LEGACY_INSTALL_ROOT/install-meta.json"
SERVICE_NAME="xboard-node-test.service"
SERVICE_PATH="$TMP_ROOT/${SERVICE_NAME}"
SB_BINARY="$TMP_ROOT/bin/xboard-node"
XBCTL_PATH="$TMP_ROOT/bin/xbctl"
XBCTL_COMPAT_PATH="$TMP_ROOT/bin/xbctl-compat"
SYSTEMCTL_LOG="$TMP_ROOT/systemctl.log"

systemctl() {
  printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
  return 0
}

seed_legacy() {
  mkdir -p "$LEGACY_INSTALL_ROOT" "$TMP_ROOT/bin"
  printf 'panel:\n  url: https://panel.example.com\n' > "$LEGACY_CONFIG_FILE"
  printf 'TOKEN=test\n' > "$LEGACY_CREDENTIALS_FILE"
  printf '[Unit]\nDescription=legacy\n' > "$SERVICE_PATH"
  printf '#!/bin/sh\nexit 0\n' > "$SB_BINARY"
  printf '#!/bin/sh\nexit 0\n' > "$XBCTL_PATH"
  chmod +x "$SB_BINARY" "$XBCTL_PATH"
  ln -sf "$XBCTL_PATH" "$XBCTL_COMPAT_PATH"
}

echo "[test] default cleanup removes runtime but preserves config"
seed_legacy
do_legacy_cleanup --yes

[ ! -e "$SERVICE_PATH" ]
[ ! -e "$SB_BINARY" ]
[ ! -e "$XBCTL_PATH" ]
[ ! -e "$XBCTL_COMPAT_PATH" ]
[ -f "$LEGACY_CONFIG_FILE" ]
[ -f "$LEGACY_CREDENTIALS_FILE" ]
grep -qx "stop $SERVICE_NAME" "$SYSTEMCTL_LOG"
grep -qx "disable $SERVICE_NAME" "$SYSTEMCTL_LOG"
grep -qx "daemon-reload" "$SYSTEMCTL_LOG"

echo "[test] purge also removes preserved legacy config"
: > "$SYSTEMCTL_LOG"
seed_legacy
do_legacy_cleanup --purge --yes

[ ! -e "$SERVICE_PATH" ]
[ ! -e "$SB_BINARY" ]
[ ! -e "$XBCTL_PATH" ]
[ ! -e "$XBCTL_COMPAT_PATH" ]
[ ! -e "$LEGACY_INSTALL_ROOT" ]

echo "legacy cleanup tests: OK"
