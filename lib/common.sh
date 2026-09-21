#!/usr/bin/env bash

TXBOARD_INSTALL_DIR="${TXBOARD_INSTALL_DIR:-/opt/txboard}"
TXBOARD_DEPLOY_BASE_URL="${TXBOARD_DEPLOY_BASE_URL:-https://raw.githubusercontent.com/PaiMonCai/TXBoard-Deploy/main}"

tx_log() { printf '[TXBoard] %s\n' "$*"; }
tx_warn() { printf '[TXBoard] WARNING: %s\n' "$*" >&2; }
tx_die() { printf '[TXBoard] ERROR: %s\n' "$*" >&2; exit 1; }

tx_require_docker() {
  command -v docker >/dev/null 2>&1 || tx_die "Docker Engine is required."
  docker compose version >/dev/null 2>&1 || tx_die "Docker Compose v2 is required."
  docker info >/dev/null 2>&1 || tx_die "Docker daemon is not reachable."
}

tx_require_install() {
  [[ -f "$TXBOARD_INSTALL_DIR/compose.yaml" && -f "$TXBOARD_INSTALL_DIR/.env" && -f "$TXBOARD_INSTALL_DIR/api.env" ]] ||
    tx_die "no TXBoard deployment found in $TXBOARD_INSTALL_DIR"
}

tx_compose() {
  (cd "$TXBOARD_INSTALL_DIR" && docker compose "$@")
}

tx_confirm() {
  local prompt="${1:-Continue?}" default="${2:-N}" answer
  if [[ ! -r /dev/tty ]]; then
    return 1
  fi
  printf '%s [%s]: ' "$prompt" "$default" > /dev/tty
  IFS= read -r answer < /dev/tty || true
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

tx_pause() {
  [[ -r /dev/tty ]] || return 0
  printf '\nPress Enter to continue...' > /dev/tty
  IFS= read -r _ < /dev/tty || true
}

tx_env_get() {
  local key="$1" file="${2:-$TXBOARD_INSTALL_DIR/.env}"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); value=$0} END {print value}' "$file"
}

tx_env_set() {
  local key="$1" value="$2" file="${3:-$TXBOARD_INSTALL_DIR/.env}" tmp
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { done=0 }
    index($0, key "=")==1 { print key "=" value; done=1; next }
    { print }
    END { if (!done) print key "=" value }
  ' "$file" > "$tmp"
  chmod --reference="$file" "$tmp" 2>/dev/null || chmod 600 "$tmp"
  mv "$tmp" "$file"
}
