#!/usr/bin/env bash

if [[ -n "${TXBOARD_INSTALL_DIR:-}" ]]; then
  TXBOARD_INSTALL_DIR="$TXBOARD_INSTALL_DIR"
elif [[ -n "${SCRIPT_DIR:-}" && -f "$SCRIPT_DIR/compose.yaml" ]]; then
  TXBOARD_INSTALL_DIR="$SCRIPT_DIR"
else
  TXBOARD_INSTALL_DIR="/opt/txboard"
fi
TXBOARD_DEPLOY_RAW_BASE="${TXBOARD_DEPLOY_RAW_BASE:-https://raw.githubusercontent.com/ANRCM0/TXBoard-Deploy/main}"

log() { printf '[TXBoard] %s\n' "$*"; }
warn() { printf '[TXBoard] WARNING: %s\n' "$*" >&2; }
die() { printf '[TXBoard] ERROR: %s\n' "$*" >&2; exit 1; }

require_tty() { [[ -r /dev/tty ]] || die "interactive TTY required"; }

docker_ok() {
  command -v docker >/dev/null 2>&1 || die "Docker Engine is required"
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"
  docker info >/dev/null 2>&1 || die "Docker daemon is not reachable"
}

need_install() {
  [[ -f "$TXBOARD_INSTALL_DIR/compose.yaml" && -f "$TXBOARD_INSTALL_DIR/.env" && -f "$TXBOARD_INSTALL_DIR/api.env" ]] ||
    die "no TXBoard deployment found in $TXBOARD_INSTALL_DIR"
}

compose() {
  (cd "$TXBOARD_INSTALL_DIR" && docker compose "$@")
}

prompt() {
  require_tty
  local label="$1" default="${2-}" value=""
  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$label" "$default" > /dev/tty
  else
    printf '%s: ' "$label" > /dev/tty
  fi
  IFS= read -r value < /dev/tty || true
  printf '%s' "${value:-$default}"
}

choose() {
  local label="$1" default="$2" max="$3" value=""
  while true; do
    value="$(prompt "$label" "$default")"
    [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 0 && value <= max )) && {
      printf '%s' "$value"
      return
    }
    warn "please choose a number from 0 to $max"
  done
}

confirm() {
  local answer
  answer="$(prompt "$1" "${2:-N}")"
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

pause() {
  [[ -r /dev/tty ]] || return 0
  printf '\n按回车键继续……' > /dev/tty
  IFS= read -r _ < /dev/tty || true
}

env_get() {
  local file="$1" key="$2" value
  value="$(grep -E "^$key=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  if [[ "$value" == \'*\' && ${#value} -ge 2 ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

database_mode() {
  local mode
  mode="$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_DB_MODE)"
  case "$mode" in
    external) printf 'external' ;;
    host) printf 'host' ;;
    *) printf 'local' ;;
  esac
}

env_set() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { done=0 }
    index($0,key"=")==1 { print key "=" value; done=1; next }
    { print }
    END { if (!done) print key "=" value }
  ' "$file" > "$tmp"
  chmod --reference="$file" "$tmp" 2>/dev/null || chmod 600 "$tmp"
  mv "$tmp" "$file"
}

fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$1"
  else
    die "curl or wget is required"
  fi
}

valid_domain() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

detect_mode() {
  local mode site bind
  mode="$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_MODE)"
  case "$mode" in
    auto-https|external-https|http) printf '%s' "$mode"; return ;;
  esac
  site="$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_SITE_ADDRESS)"
  bind="$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_HTTP_BIND)"
  if [[ -n "$site" && "$site" != ":80" ]]; then
    printf 'auto-https'
  elif [[ "$bind" == "127.0.0.1" ]]; then
    printf 'external-https'
  else
    printf 'http'
  fi
}
