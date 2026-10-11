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

# Shared terminal presentation. No ANSI is emitted to piped output, dumb
# terminals, NO_COLOR sessions or when TXBOARD_COLOR=never.
ui_color_enabled() {
  [[ -z "${NO_COLOR+x}" && "${TXBOARD_COLOR:-auto}" != never ]] || return 1
  [[ "${TERM:-dumb}" != dumb && -t 0 && -w /dev/tty ]] || return 1
}
ui_color() {
  local color="$1"
  if ui_color_enabled; then
    case "$color" in
      blue) printf '\033[1;94m' ;;
      cyan) printf '\033[1;96m' ;;
      green) printf '\033[1;92m' ;;
      yellow) printf '\033[1;93m' ;;
      red) printf '\033[1;91m' ;;
      muted) printf '\033[90m' ;;
      bold) printf '\033[1m' ;;
      reset) printf '\033[0m' ;;
    esac
  fi
}
ui_screen() {
  require_tty
  if [[ -t 0 && "${TERM:-dumb}" != dumb ]]; then
    printf '\033[2J\033[H' > /dev/tty
  else
    printf '\n' > /dev/tty
  fi
}
ui_header() {
  local title="$1" subtitle="${2:-}" blue muted reset
  blue="$(ui_color blue)"; muted="$(ui_color muted)"; reset="$(ui_color reset)"
  {
    printf '\n%b  ◆ TXBoard%b  %b%s%b\n' "$blue" "$reset" "$(ui_color bold)" "$title" "$reset"
    printf '%b  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n' "$blue" "$reset"
    [[ -z "$subtitle" ]] || printf '  %b%s%b\n' "$muted" "$subtitle" "$reset"
  } > /dev/tty
}
ui_section() {
  printf '\n  %b%s%b\n' "$(ui_color cyan)" "$1" "$(ui_color reset)" > /dev/tty
}
ui_item() {
  local index="$1" caption="$2" hint="${3:-}" shade
  [[ "$index" == 0 ]] && shade=muted || shade=yellow
  if [[ -n "$hint" ]]; then
    printf '  %b%2s%b  %-24s %b%s%b\n' "$(ui_color "$shade")" "$index" "$(ui_color reset)" "$caption" "$(ui_color muted)" "$hint" "$(ui_color reset)" > /dev/tty
  else
    printf '  %b%2s%b  %s\n' "$(ui_color "$shade")" "$index" "$(ui_color reset)" "$caption" > /dev/tty
  fi
}
ui_danger_item() {
  local index="$1" caption="$2" hint="${3:-}"
  printf '  %b%2s  %s%b %b%s%b\n' "$(ui_color red)" "$index" "$caption" "$(ui_color reset)" "$(ui_color muted)" "$hint" "$(ui_color reset)" > /dev/tty
}
ui_footer() {
  printf '\n  %b──────────────────────────────────────────────%b\n' "$(ui_color muted)" "$(ui_color reset)" > /dev/tty
}

# Run ONLY non-interactive operations whose output is non-sensitive. Do NOT
# use for credential resets, DB restore or upgrades with interactive recovery.
# Foreground mode keeps command output identical for scripts and non-TTY use.
ui_run() {
  local title="$1" status=0 log_file pid frame=0
  shift
  if [[ "${TXBOARD_UI_VERBOSE:-false}" == true || ! -t 0 || "${TERM:-dumb}" == dumb || ! -w /dev/tty ]]; then
    "$@"
    return $?
  fi
  local log_dir="$TXBOARD_INSTALL_DIR/backups/manager"
  umask 077
  mkdir -p -m 700 -- "$log_dir" || return 1
  chmod 700 -- "$log_dir" || return 1
  log_file="$log_dir/operations.log"
  touch "$log_file" && chmod 600 "$log_file" || return 1
  printf '\n[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$title" >> "$log_file"
  "$@" >> "$log_file" 2>&1 &
  pid=$!
  local glyphs=('|' '/' '-' '\')
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r\033[2K  %b%s%b  %s' "$(ui_color cyan)" "${glyphs[$((frame % 4))]}" "$(ui_color reset)" "$title" > /dev/tty
    frame=$((frame + 1))
    sleep 0.15
  done
  if wait "$pid"; then
    printf '\r\033[2K  %b✓%b  %s\n' "$(ui_color green)" "$(ui_color reset)" "$title" > /dev/tty
    return 0
  else
    status=$?
  fi
  printf '\r\033[2K  %b✗%b  %s\n' "$(ui_color red)" "$(ui_color reset)" "$title" > /dev/tty
  tail -n 15 "$log_file" >&2 || true
  warn "操作失败，完整日志：$log_file"
  return "$status"
}

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
