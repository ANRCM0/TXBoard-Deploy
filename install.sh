#!/usr/bin/env bash
set -Eeuo pipefail

bootstrap_piped_installer() {
  # When Bash executes the installer directly from stdin (for example
  # curl ... | sudo bash), the script source and child-process stdin share the
  # same pipe. Slow network producers can expose races where Docker/Compose or
  # another child consumes bytes that Bash has not parsed yet. Re-run the
  # installer from a real file so runtime commands never share the source fd.
  # In a function defined on stdin Bash may report the shell executable as
  # BASH_SOURCE[0]. Only the caller frame denotes a real installer file.
  [[ -z "${BASH_SOURCE[1]:-}" ]] || return 0

  local raw_base="${TXBOARD_DEPLOY_RAW_BASE:-https://raw.githubusercontent.com/ANRCM0/TXBoard-Deploy/main}"
  local tmp drain_pid status=0
  tmp="$(mktemp /tmp/txboard-install.XXXXXX.sh)" ||
    { printf '[TXBoard Deploy] ERROR: cannot create temporary installer file\n' >&2; exit 1; }

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$raw_base/install.sh" -o "$tmp" ||
      { rm -f "$tmp"; printf '[TXBoard Deploy] ERROR: failed to materialize installer from %s/install.sh\n' "$raw_base" >&2; exit 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$raw_base/install.sh" ||
      { rm -f "$tmp"; printf '[TXBoard Deploy] ERROR: failed to materialize installer from %s/install.sh\n' "$raw_base" >&2; exit 1; }
  else
    rm -f "$tmp"
    printf '[TXBoard Deploy] ERROR: curl or wget is required to materialize a piped installer\n' >&2
    exit 1
  fi
  chmod 700 "$tmp"

  # Drain the original producer so curl/wget can finish cleanly, while the real
  # installer runs with stdin detached from the source-code pipe. Interactive
  # prompts continue to use /dev/tty.
  cat >/dev/null &
  drain_pid=$!

  if bash "$tmp" "$@" </dev/null; then
    status=0
  else
    status=$?
  fi

  wait "$drain_pid" 2>/dev/null || true
  rm -f "$tmp"
  exit "$status"
}

bootstrap_piped_installer "$@"

# Keep the reviewed checkout location after changing into the installation dir.
INSTALLER_SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Route before Core prompts, Docker discovery or database initialization.
# All other arguments keep their original order and are passed literally.
COMPONENT=core
COMPONENT_SET=0
component_args=()
while (($#)); do
  case "$1" in
    --component)
      [[ $# -ge 2 && "$COMPONENT_SET" == 0 ]] || { printf '[TXBoard Deploy] ERROR: missing/duplicate --component\n' >&2; exit 1; }
      COMPONENT="$2"; COMPONENT_SET=1; shift 2 ;;
    *) component_args+=("$1"); shift ;;
  esac
done
set -- "${component_args[@]}"
case "$COMPONENT" in gateway) printf '[TXBoard Deploy] ERROR: Gateway is retired; browser ingress is included in Core\n' >&2; exit 1 ;; core|node) ;; *) printf '[TXBoard Deploy] ERROR: component must be core or node\n' >&2; exit 1 ;; esac
if [[ "$COMPONENT" != core ]]; then
  component_module="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/components.sh"
  component_tmp=''
  if [[ ! -f "$component_module" ]]; then
    component_tmp="$(mktemp -d /tmp/txboard-components.XXXXXXXX)"
    mkdir "$component_tmp/lib"
    component_module="$component_tmp/lib/components.sh"
    component_url="${TXBOARD_DEPLOY_RAW_BASE:-https://raw.githubusercontent.com/ANRCM0/TXBoard-Deploy/main}/lib/components.sh"
    if command -v curl >/dev/null 2>&1; then curl -fsSL --connect-timeout 10 --max-time 60 "$component_url" -o "$component_module";
    elif command -v wget >/dev/null 2>&1; then wget -q -T 60 -O "$component_module" "$component_url";
    else printf '[TXBoard Deploy] ERROR: curl or wget is required\n' >&2; exit 1; fi
  fi
  bash -n "$component_module"
  component_result=0
  bash "$component_module" "$COMPONENT" install "$@" || component_result=$?
  if [[ -n "$component_tmp" ]]; then rm -f -- "$component_module"; rmdir "$component_tmp/lib" "$component_tmp"; fi
  exit "$component_result"
fi

IMAGE_REPO="${TXBOARD_IMAGE_REPO:-ghcr.io/anrcm0/txboard-core}"
# Docker repository names must be lowercase, including operator-supplied overrides.
IMAGE_REPO="${IMAGE_REPO,,}"
IMAGE_TAG="${TXBOARD_IMAGE_TAG:-latest}"
INSTALL_DIR="${TXBOARD_INSTALL_DIR:-/opt/txboard}"
NATIVE_CONFIG_DIR="${TXBOARD_NATIVE_CONFIG_DIR:-}"
NATIVE_IMAGE="${TXBOARD_NATIVE_IMAGE:-}"
ADMIN_EMAIL="${TXBOARD_ADMIN_EMAIL:-}"
MODE="${TXBOARD_MODE:-}"
DOMAIN="${TXBOARD_DOMAIN:-}"
PUBLIC_HOST="${TXBOARD_PUBLIC_HOST:-}"
REQUESTED_HTTP_BIND="${TXBOARD_HTTP_BIND:-}"
HTTP_PORT="${TXBOARD_HTTP_PORT:-}"
HTTPS_PORT="${TXBOARD_HTTPS_PORT:-}"
BACKUP_RETENTION="${TXBOARD_BACKUP_RETENTION:-7}"
DEPLOY_PROFILE="${TXBOARD_RESOURCE_PROFILE:-auto}"
RESOURCE_HELPER=""
RESOURCE_HELPER_TEMP=""
RESOURCE_PLAN=""
NATIVE_HELPER=""
NATIVE_HELPER_TEMP=""
TEST_MODE="${TXBOARD_TEST_MODE:-false}"
AUTO_INSTALL_DOCKER="${TXBOARD_AUTO_INSTALL_DOCKER:-false}"
DB_MODE="${TXBOARD_DB_MODE:-}"
DB_HOST="${TXBOARD_DB_HOST:-}"
DB_PORT="${TXBOARD_DB_PORT:-3306}"
DB_DATABASE="${TXBOARD_DB_DATABASE:-txboard}"
DB_USERNAME="${TXBOARD_DB_USERNAME:-txboard}"
DB_PASSWORD="${TXBOARD_DB_PASSWORD:-}"
DB_ROOT_PASSWORD="${TXBOARD_DB_ROOT_PASSWORD:-}"
DB_ADMIN_PASSWORD="${TXBOARD_DB_ADMIN_PASSWORD:-}"
DB_SYSTEM_SOCKET="${TXBOARD_DB_SYSTEM_SOCKET:-}"
DB_CONTAINER="${TXBOARD_DB_CONTAINER:-}"
DB_HOST_KIND=""
DB_LINK_NETWORK="${TXBOARD_DB_LINK_NETWORK:-txboard-db-link}"
DB_PROXY_REQUIRED=0
DB_PROXY_BIND=""
DB_PROXY_PORT="${TXBOARD_DB_PROXY_PORT:-13306}"
DB_SOURCE_PORT=""
DEPLOY_RAW_BASE="${TXBOARD_DEPLOY_RAW_BASE:-https://raw.githubusercontent.com/ANRCM0/TXBoard-Deploy/main}"
ASSUME_YES=0
RENDER_ONLY=0
RESET_LOCAL_DB=0
LOCAL_DB_RESET_PENDING=0
INSTALL_TYPE="${TXBOARD_INSTALL_TYPE:-fresh}"
LEGACY_COMPAT="${TXBOARD_LEGACY_COMPAT:-false}"
XBOARD_DUMP="${TXBOARD_XBOARD_DUMP:-}"
XBOARD_ENV_FILE="${TXBOARD_XBOARD_ENV_FILE:-}"
XBOARD_AUTO_DUMP="${TXBOARD_XBOARD_AUTO_DUMP:-false}"
XBOARD_SOURCE_CONTAINER="${TXBOARD_XBOARD_SOURCE_CONTAINER:-}"
XBOARD_SOURCE_DATABASE="${TXBOARD_XBOARD_SOURCE_DATABASE:-}"
DISCARD_LEGACY_AUDIT="${TXBOARD_DISCARD_LEGACY_AUDIT:-false}"
CLEAN_INSTALL_DIR="${TXBOARD_CLEAN_INSTALL_DIR:-false}"
ARCHIVE_ORPHAN_DIR="${TXBOARD_ARCHIVE_ORPHAN_DIR:-false}"
INSTALL_VERBOSE="${TXBOARD_INSTALL_VERBOSE:-false}"
INSTALL_LOG_FILE=""
INSTALL_PROGRESS_TOTAL=0
INSTALL_PROGRESS_DONE=0
COMPOSE_PROJECT_NAME="txboard"
LOCAL_DB_VOLUME="${COMPOSE_PROJECT_NAME}_database-data"

log() { printf '[TXBoard Deploy] %s\n' "$*"; }
warn() { printf '[TXBoard Deploy] WARNING: %s\n' "$*" >&2; }
die() { printf '[TXBoard Deploy] ERROR: %s\n' "$*" >&2; exit 1; }

# Interactive stage spinner, never a simulated percentage. A private full log
# preserves every underlying command's output for error diagnosis.
# Install wizard colors are strictly opt-in for real terminals. No ANSI in
# CI logs, piped output, NO_COLOR or TERM=dumb sessions.
install_ui_color() {
  [[ -t 2 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR+x}" && "${TXBOARD_COLOR:-auto}" != never ]] || return 0
  case "$1" in
    blue) printf '\033[1;94m' ;;
    cyan) printf '\033[1;96m' ;;
    green) printf '\033[1;92m' ;;
    red) printf '\033[1;91m' ;;
    yellow) printf '\033[1;93m' ;;
    muted) printf '\033[90m' ;;
    reset) printf '\033[0m' ;;
  esac
}
install_ui_banner() {
  [[ "$ASSUME_YES" -eq 0 ]] || return 0
  printf '\n%b  ◆ TXBoard Installer%b\n' "$(install_ui_color blue)" "$(install_ui_color reset)" > /dev/tty
  printf '%b  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n' "$(install_ui_color blue)" "$(install_ui_color reset)" > /dev/tty
  printf '  %b安全部署 · 数据库迁移 · 自动备份%b\n\n' "$(install_ui_color muted)" "$(install_ui_color reset)" > /dev/tty
}
install_ui_section() {
  [[ "$ASSUME_YES" -eq 0 ]] || return 0
  printf '\n  %b◆ %s%b\n' "$(install_ui_color cyan)" "$1" "$(install_ui_color reset)" > /dev/tty
}

install_progress_step() {
  local title="$1" pid frame=0 status=0 log_file step_no bar="" i ui_blue ui_green ui_red ui_reset
  ui_blue="$(install_ui_color cyan)"
  ui_green="$(install_ui_color green)"
  ui_red="$(install_ui_color red)"
  ui_reset="$(install_ui_color reset)"
  shift
  log_file="${INSTALL_LOG_FILE:?installer log file not initialized}"
  step_no=$((INSTALL_PROGRESS_DONE + 1))
  for ((i = 0; i < INSTALL_PROGRESS_TOTAL; i++)); do
    if ((i < INSTALL_PROGRESS_DONE)); then bar+="█"; else bar+="░"; fi
  done
  printf '\n==> %s\n' "$title" >> "$log_file"

  if [[ "$INSTALL_VERBOSE" == true || ! -t 2 || "${TERM:-}" == dumb ]]; then
    log "$title..."
    if "$@" 2>&1 | tee -a "$log_file"; then
      INSTALL_PROGRESS_DONE=$((INSTALL_PROGRESS_DONE + 1))
      log "[$INSTALL_PROGRESS_DONE/$INSTALL_PROGRESS_TOTAL] $title 已完成"
      return 0
    else
      status=$?
      warn "$title 失败（退出码 $status）；完整日志：$log_file"
      return "$status"
    fi
  fi

  "$@" >> "$log_file" 2>&1 &
  pid=$!
  local frames=('|' '/' '-' '\')
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r\033[2K%b◆ TXBoard%b [%s] %d/%d [%s] %s' "$ui_blue" "$ui_reset" "${frames[$((frame % ${#frames[@]}))]}" "$step_no" "$INSTALL_PROGRESS_TOTAL" "$bar" "$title" > /dev/tty
    frame=$((frame + 1))
    sleep 0.15
  done
  if wait "$pid"; then
    INSTALL_PROGRESS_DONE=$((INSTALL_PROGRESS_DONE + 1))
    bar=""
    for ((i = 0; i < INSTALL_PROGRESS_TOTAL; i++)); do
      if ((i < INSTALL_PROGRESS_DONE)); then bar+="█"; else bar+="░"; fi
    done
    printf '\r\033[2K%b✓%b %d/%d [%s] %s\n' "$ui_green" "$ui_reset" "$INSTALL_PROGRESS_DONE" "$INSTALL_PROGRESS_TOTAL" "$bar" "$title" > /dev/tty
    return 0
  else
    status=$?
  fi
  printf '\r\033[2K%b✗%b %d/%d [%s] %s（失败）\n' "$ui_red" "$ui_reset" "$step_no" "$INSTALL_PROGRESS_TOTAL" "$bar" "$title" > /dev/tty
  warn "$title failed (exit $status); latest diagnostic lines:"
  tail -n 24 "$log_file" >&2 || true
  warn "完整日志：$log_file"
  return "$status"
}


normalize_http_bind() {
  python3 - "$1" <<'PY'
import ipaddress
import sys
value = sys.argv[1]
if value.startswith('[') and value.endswith(']'):
    value = value[1:-1]
try:
    if '%' in value:
        raise ValueError()
    address = ipaddress.ip_address(value)
except ValueError:
    sys.exit(1)
print('[' + address.compressed + ']' if address.version == 6 else str(address))
PY
}

report_image_acquisition_failure() {
  warn "Could not acquire requested Core image: $IMAGE"
  warn 'latest is published only by stable release tags; dev tracks main and preview tracks prereleases. No channel fallback was performed.'
  [[ "$IMAGE" != sha256:* ]] || return 0
  local repository="$IMAGE_REPO" channel available="" inspected=0
  [[ "$IMAGE" != *@sha256:* ]] || repository="${IMAGE%@sha256:*}"
  if command -v timeout >/dev/null 2>&1; then
    for channel in latest dev preview; do
      if timeout 10s docker manifest inspect "$repository:$channel" >/dev/null 2>&1; then
        available="${available:+$available, }$channel"
        inspected=1
      fi
    done
  fi
  if [[ "$inspected" -eq 1 ]]; then
    warn "Reachable channels at $repository: $available (availability does not establish freshness or release approval)"
  else
    warn 'Channel availability could not be confirmed; check registry access and the explicit image reference.'
  fi
  warn 'For native installation, select a reviewed immutable repository@sha256 digest with --native-image.'
}

usage() {
  cat <<'EOF'
TXBoard Docker 交互式安装向导

Usage:
  install.sh [options]
  install.sh --component core|node [component options]

Options:
  --dir PATH          Install directory (default: /opt/txboard)
  --tag TAG           TXBoard 镜像版本（latest / dev / 固定版本） (default: latest)
  --email EMAIL       Initial administrator email
  --mode MODE         auto-https | external-https | http
  --domain DOMAIN     Public domain for HTTPS modes
  --public-host HOST  Public host/IP for HTTP mode
  --http-bind ADDR    Explicit IPv4/IPv6 listener for HTTP mode; loopback hosts bind locally
  --http-port PORT    HTTP 端口
  --https-port PORT   HTTPS 端口 (auto-https only)
  --resource-profile NAME  auto / minimal / balanced / performance; capacity checked
  --backup-retention N
                      Number of backup archives to retain (default: 7)
  --test-mode         Enable test deployment mode; permits wildcard public hosts
  --db-mode MODE      local | host | external (default: local)
  --db-host HOST      External MySQL host
  --db-container NAME  Host MySQL/MariaDB Docker container (host mode)
  --db-socket PATH     System/local MySQL socket override (host mode)
  --db-port PORT      External MySQL port (default: 3306)
  --db-name NAME      Database name (default: txboard)
  --db-user USER      Database username (default: txboard)
  --db-password PASS  Database password (prefer environment variable)
  --install-type MODE fresh | xboard-import (default: fresh)
  --native-config DIR  Prepare/activate native runtime using private operator configuration
  --native-image REF   Native image pinned by repository@sha256 or an existing sha256 image ID
  --legacy-compat      Explicit historical compatibility install; native browser APIs unavailable
  --xboard-dump PATH Trusted XBoard single-database mysqldump .sql.gz (not a live DB)
  --xboard-env PATH  Original XBoard .env containing APP_KEY
  --xboard-auto-dump  Export .sql.gz automatically from local XBoard MySQL container
  --xboard-source-container NAME  Source 1Panel/Docker MySQL container
  --xboard-source-db NAME  Source MySQL database (default from old .env)
  --discard-legacy-audit  Opt-in: discard known legacy audit plugin tables/history in NEW target
  --yes               Non-interactive; use CLI/environment/default values
  --reset-local-db    Delete an existing managed MySQL volume before a fresh install
                      (DESTRUCTIVE: all data in that volume will be lost)
  --clean-install-dir  Remove unrelated files in target install directory (with approval)
  --archive-orphan-dir  Archive a failed deployment config if NO TXBoard containers exist
                      (preserves prior files and Docker volumes; never deletes them)
  --verbose           Show full Docker/MySQL/installer output (also saved privately)
  --render-only       Generate and validate files, do not pull/start containers
  -h, --help          Show this help

Environment variables:
  TXBOARD_IMAGE_REPO
  TXBOARD_IMAGE_TAG
  TXBOARD_INSTALL_DIR
  TXBOARD_ADMIN_EMAIL
  TXBOARD_MODE
  TXBOARD_DOMAIN
  TXBOARD_PUBLIC_HOST
  TXBOARD_HTTP_BIND
  TXBOARD_HTTP_PORT
  TXBOARD_HTTPS_PORT
  TXBOARD_BACKUP_RETENTION
  TXBOARD_RESOURCE_PROFILE
  TXBOARD_TEST_MODE
  TXBOARD_AUTO_INSTALL_DOCKER
  TXBOARD_DB_MODE
  TXBOARD_DB_HOST
  TXBOARD_DB_PORT
  TXBOARD_DB_DATABASE
  TXBOARD_DB_USERNAME
  TXBOARD_DB_PASSWORD
  TXBOARD_DB_ROOT_PASSWORD
  TXBOARD_DB_ADMIN_PASSWORD
  TXBOARD_DB_SYSTEM_SOCKET
  TXBOARD_DB_CONTAINER
  TXBOARD_DB_LINK_NETWORK
  TXBOARD_DB_PROXY_PORT
  TXBOARD_INSTALL_TYPE
  TXBOARD_LEGACY_COMPAT
  TXBOARD_XBOARD_DUMP
  TXBOARD_XBOARD_ENV_FILE
  TXBOARD_XBOARD_AUTO_DUMP
  TXBOARD_XBOARD_SOURCE_CONTAINER
  TXBOARD_XBOARD_SOURCE_DATABASE
  TXBOARD_XBOARD_DB_ADMIN_PASSWORD
  TXBOARD_DISCARD_LEGACY_AUDIT
  TXBOARD_CLEAN_INSTALL_DIR
  TXBOARD_ARCHIVE_ORPHAN_DIR
  TXBOARD_INSTALL_VERBOSE
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) INSTALL_DIR="${2:?missing value for --dir}"; shift 2 ;;
    --tag) IMAGE_TAG="${2:?missing value for --tag}"; shift 2 ;;
    --email) ADMIN_EMAIL="${2:?missing value for --email}"; shift 2 ;;
    --mode) MODE="${2:?missing value for --mode}"; shift 2 ;;
    --domain) DOMAIN="${2:?missing value for --domain}"; shift 2 ;;
    --public-host) PUBLIC_HOST="${2:?missing value for --public-host}"; shift 2 ;;
    --http-bind) REQUESTED_HTTP_BIND="${2:?missing value for --http-bind}"; shift 2 ;;
    --http-port) HTTP_PORT="${2:?missing value for --http-port}"; shift 2 ;;
    --https-port) HTTPS_PORT="${2:?missing value for --https-port}"; shift 2 ;;
    --resource-profile) DEPLOY_PROFILE="${2:?missing value for --resource-profile}"; shift 2 ;;
    --backup-retention) BACKUP_RETENTION="${2:?missing value for --backup-retention}"; shift 2 ;;
    --test-mode) TEST_MODE=true; shift ;;
    --enable-mcp|--disable-mcp) die "MCP has been retired; remove the MCP option" ;;
    --db-mode) DB_MODE="${2:?missing value for --db-mode}"; shift 2 ;;
    --db-host) DB_HOST="${2:?missing value for --db-host}"; shift 2 ;;
    --db-container) DB_CONTAINER="${2:?missing value for --db-container}"; shift 2 ;;
    --db-socket) DB_SYSTEM_SOCKET="${2:?missing value for --db-socket}"; shift 2 ;;
    --db-port) DB_PORT="${2:?missing value for --db-port}"; shift 2 ;;
    --db-name) DB_DATABASE="${2:?missing value for --db-name}"; shift 2 ;;
    --db-user) DB_USERNAME="${2:?missing value for --db-user}"; shift 2 ;;
    --db-password) DB_PASSWORD="${2:?missing value for --db-password}"; shift 2 ;;
    --install-type) INSTALL_TYPE="${2:?missing value for --install-type}"; shift 2 ;;
    --native-config) NATIVE_CONFIG_DIR="${2:?missing value for --native-config}"; shift 2 ;;
    --native-image) NATIVE_IMAGE="${2:?missing value for --native-image}"; shift 2 ;;
    --legacy-compat) LEGACY_COMPAT=true; shift ;;
    --xboard-dump) XBOARD_DUMP="${2:?missing value for --xboard-dump}"; INSTALL_TYPE=xboard-import; shift 2 ;;
    --xboard-env) XBOARD_ENV_FILE="${2:?missing value for --xboard-env}"; shift 2 ;;
    --xboard-auto-dump) XBOARD_AUTO_DUMP=true; INSTALL_TYPE=xboard-import; shift ;;
    --xboard-source-container) XBOARD_SOURCE_CONTAINER="${2:?missing value for --xboard-source-container}"; XBOARD_AUTO_DUMP=true; INSTALL_TYPE=xboard-import; shift 2 ;;
    --xboard-source-db) XBOARD_SOURCE_DATABASE="${2:?missing value for --xboard-source-db}"; XBOARD_AUTO_DUMP=true; INSTALL_TYPE=xboard-import; shift 2 ;;
    --discard-legacy-audit) DISCARD_LEGACY_AUDIT=true; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --reset-local-db) RESET_LOCAL_DB=1; shift ;;
    --clean-install-dir) CLEAN_INSTALL_DIR=true; shift ;;
    --archive-orphan-dir) ARCHIVE_ORPHAN_DIR=true; shift ;;
    --verbose) INSTALL_VERBOSE=true; shift ;;
    --render-only) RENDER_ONLY=1; ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$LEGACY_COMPAT" in true|false) ;; *) die 'TXBOARD_LEGACY_COMPAT must be true or false' ;; esac
[[ "$LEGACY_COMPAT" != true || -z "$NATIVE_CONFIG_DIR" ]] || die '--legacy-compat cannot be combined with --native-config'
if [[ "$ASSUME_YES" -eq 1 && "$RENDER_ONLY" -eq 0 && "$INSTALL_TYPE" == fresh && -z "$NATIVE_CONFIG_DIR" && "$LEGACY_COMPAT" != true ]]; then
  die 'fresh unattended installation requires --native-config and --native-image; --legacy-compat explicitly selects historical installation without native browser APIs'
fi
if [[ -n "$REQUESTED_HTTP_BIND" ]]; then
  REQUESTED_HTTP_BIND="$(normalize_http_bind "$REQUESTED_HTTP_BIND")" || die '--http-bind requires an IPv4 or IPv6 address'
fi

case "$(uname -m)" in
  x86_64|amd64|aarch64|arm64) ;;
  *) die "unsupported architecture: $(uname -m). TXBoard images target amd64 and arm64." ;;
esac

if [[ "$ASSUME_YES" -eq 0 && ! -r /dev/tty ]]; then
  die "interactive installation requires a TTY. Use --yes with explicit values for unattended mode."
fi

prompt() {
  local label="$1" default="${2-}" value=""
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    printf '%s' "$default"
    return
  fi
  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$label" "$default" > /dev/tty
  else
    printf '%s: ' "$label" > /dev/tty
  fi
  IFS= read -r value < /dev/tty || true
  printf '%s' "${value:-$default}"
}

prompt_secret() {
  local label="$1" default="${2-}" value=""
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    printf '%s' "$default"
    return
  fi
  printf '%s: ' "$label" > /dev/tty
  IFS= read -r -s value < /dev/tty || true
  printf '\n' > /dev/tty
  printf '%s' "${value:-$default}"
}

dotenv_quote() {
  local value="$1"
  [[ "$value" != *"'"* && "$value" != *$'\n'* && "$value" != *$'\r'* ]] ||
    die "database password cannot contain a single quote or newline"
  printf "'%s'" "$value"
}

choose() {
  local label="$1" default="$2" max="$3" value=""
  while true; do
    value="$(prompt "$label" "$default")"
    case "$value" in
      ''|*[!0-9]*) ;;
      *) if (( value >= 1 && value <= max )); then printf '%s' "$value"; return; fi ;;
    esac
    warn "please choose a number from 1 to $max"
  done
}

confirm() {
  local label="$1" default="${2:-Y}" value=""
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    [[ "$default" =~ ^[Yy]$ ]]
    return
  fi
  value="$(prompt "$label" "$default")"
  [[ "$value" =~ ^[Yy]([Ee][Ss])?$ ]]
}


install_dir_has_content() {
  [[ -e "$INSTALL_DIR" ]] || return 1
  [[ ! -d "$INSTALL_DIR" ]] && return 0
  [[ -n "$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}

validate_install_cleanup_target() {
  [[ "$INSTALL_DIR" == /* ]] || die "installation directory must be an absolute path"
  [[ ! -L "$INSTALL_DIR" ]] || die "refusing to clean a symlink installation directory: $INSTALL_DIR"

  case "$INSTALL_DIR" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      die "refusing to clean dangerous installation directory: $INSTALL_DIR"
      ;;
  esac
}

# Preserve the complete abandoned deployment directory, including secrets and
# generated app/storage files, instead of deleting/overwriting unknown content.
# Called ONLY after final confirmation; every call rechecks Docker ownership.
archive_orphan_install_dir() {
  local archive_root
  [[ "$ARCHIVE_ORPHAN_DIR" == true ]] || die "orphan archive was not approved"
  validate_install_cleanup_target
  [[ -d "$INSTALL_DIR" && ! -L "$INSTALL_DIR" ]] ||
    die "orphan deployment path is not a real directory"
  [[ -f "$INSTALL_DIR/compose.yaml" || -f "$INSTALL_DIR/api.env" || -f "$INSTALL_DIR/.env" ]] ||
    die "orphaned deployment config disappeared; refusing to move unexpected files"
  txboard_guard_install "$INSTALL_DIR" true ||
    die "TXBoard container appeared; cannot archive current deployment"
  archive_root="$(mktemp -d "${INSTALL_DIR}.orphan-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")" ||
    die "could not reserve safe orphan archive directory"
  chmod 700 "$archive_root"
  # mv is same-filesystem and does not dereference symlinks inside the tree.
  if ! mv -T -- "$INSTALL_DIR" "$archive_root/deployment"; then
    rmdir -- "$archive_root" 2>/dev/null || true
    die "failed to preserve orphan deployment directory; installation blocked"
  fi
  log "previous TXBoard configuration archived intact at: $archive_root/deployment"
}

clean_existing_install_dir() {
  validate_install_cleanup_target

  warn "安装目录已有文件：$INSTALL_DIR"
  if [[ "$ASSUME_YES" -eq 0 ]]; then
    printf '\n安装目录已有文件（最多显示 12 项）：\n' > /dev/tty
    if [[ -d "$INSTALL_DIR" ]]; then
      find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -printf '  - %f\n' 2>/dev/null | head -n 12 > /dev/tty || true
    else
      printf '  - %s (non-directory path)\n' "$(basename "$INSTALL_DIR")" > /dev/tty
    fi
    printf '\n' > /dev/tty
    confirm "确定清理 $INSTALL_DIR 内所有文件并继续吗？Docker 数据卷会保留。" "N" ||
      die "installation stopped to preserve existing files in $INSTALL_DIR"
  else
    case "${CLEAN_INSTALL_DIR,,}" in
      1|true|yes|y|on) ;;
      *)
        die "existing files found in $INSTALL_DIR. Re-run interactively to confirm cleanup, or use --clean-install-dir / TXBOARD_CLEAN_INSTALL_DIR=true."
        ;;
    esac
  fi

  # Existing Compose configuration and all TXBoard containers were already
  # excluded by the service guard. Never issue "compose down" during cleanup
  # of unrelated residual files; it could stop a different workload.

  # Avoid a race between the initial install preflight and the cleanup prompt.
  if [[ "$RENDER_ONLY" -eq 0 ]]; then
    txboard_guard_install "$INSTALL_DIR" ||
      die "TXBoard appeared during cleanup confirmation; refusing deletion"
  else
    [[ ! -f "$INSTALL_DIR/compose.yaml" && ! -f "$INSTALL_DIR/.env" && ! -f "$INSTALL_DIR/api.env" ]] ||
      die "render-only cannot clear deployment configuration"
  fi
  log "removing old TXBoard files from $INSTALL_DIR..."
  rm -rf -- "$INSTALL_DIR"
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    if [[ "$RENDER_ONLY" -eq 0 ]]; then
      docker info >/dev/null 2>&1 || die "Docker is installed but the daemon is not reachable."
    fi
    return
  fi

  local auto="${AUTO_INSTALL_DOCKER,,}"
  if [[ "$ASSUME_YES" -eq 0 ]]; then
    confirm "未发现 Docker + Compose v2，是否自动安装？" "Y" ||
      die "Docker Engine + Compose v2 are required."
  elif [[ "$auto" != "1" && "$auto" != "true" && "$auto" != "yes" && "$auto" != "y" ]]; then
    die "Docker + Compose v2 are required. For unattended automatic installation set TXBOARD_AUTO_INSTALL_DOCKER=true."
  fi

  [[ "${EUID:-$(id -u)}" -eq 0 ]] ||
    die "automatic Docker installation requires root; rerun with sudo."

  local tmp="/tmp/txboard-get-docker.sh"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com -o "$tmp"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" https://get.docker.com
  else
    die "curl or wget is required to install Docker automatically"
  fi
  sh "$tmp"
  rm -f "$tmp"
  command -v systemctl >/dev/null 2>&1 && systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || die "Docker installed, but Compose v2 is unavailable."
  [[ "$RENDER_ONLY" -eq 1 ]] || docker info >/dev/null 2>&1 || die "Docker daemon is not reachable after installation."
}

ensure_docker

valid_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

valid_domain() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_nonnegative_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

random_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-48
  fi
}

load_resource_helper() {
  command -v python3 >/dev/null 2>&1 || die "capacity preflight requires Python 3.10+"
  python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' || die "capacity preflight requires Python 3.10+"
  RESOURCE_HELPER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/scripts/deployment-profile.py"
  if [[ ! -f "$RESOURCE_HELPER" || -L "$RESOURCE_HELPER" ]]; then
    RESOURCE_HELPER_TEMP="$(mktemp /tmp/txboard-profile.XXXXXXXX.py)"
    RESOURCE_HELPER="$RESOURCE_HELPER_TEMP"
    trap '[[ -z "$RESOURCE_HELPER_TEMP" ]] || rm -f -- "$RESOURCE_HELPER_TEMP"; [[ -z "$NATIVE_HELPER_TEMP" ]] || rm -f -- "$NATIVE_HELPER_TEMP"' EXIT
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$DEPLOY_RAW_BASE/scripts/deployment-profile.py" -o "$RESOURCE_HELPER" || die "cannot obtain capacity planner"
    else
      wget -qO "$RESOURCE_HELPER" "$DEPLOY_RAW_BASE/scripts/deployment-profile.py" || die "cannot obtain capacity planner"
    fi
  fi
  python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$RESOURCE_HELPER" || die "capacity planner syntax invalid"
}

resource_field() {
  python3 -c 'import json,sys; value=json.loads(sys.argv[1]);
for key in sys.argv[2].split("."): value=value[key]
print(value)' "$RESOURCE_PLAN" "$1"
}

load_native_helper() {
  NATIVE_HELPER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/scripts/native-runtime.py"
  if [[ ! -f "$NATIVE_HELPER" || -L "$NATIVE_HELPER" ]]; then
    NATIVE_HELPER_TEMP="$(mktemp /tmp/txboard-native.XXXXXXXX.py)"
    NATIVE_HELPER="$NATIVE_HELPER_TEMP"
    trap '[[ -z "$RESOURCE_HELPER_TEMP" ]] || rm -f -- "$RESOURCE_HELPER_TEMP"; [[ -z "$NATIVE_HELPER_TEMP" ]] || rm -f -- "$NATIVE_HELPER_TEMP"' EXIT
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$DEPLOY_RAW_BASE/scripts/native-runtime.py" -o "$NATIVE_HELPER" || die "cannot obtain native deployment runner"
    else
      wget -qO "$NATIVE_HELPER" "$DEPLOY_RAW_BASE/scripts/native-runtime.py" || die "cannot obtain native deployment runner"
    fi
  fi
}

configure_resources() {
  load_resource_helper
  install_ui_section "资源预算与容量预检"
  DEPLOY_PROFILE="$(prompt "资源 profile（auto / minimal / balanced / performance）" "$DEPLOY_PROFILE")"
  case "$DEPLOY_PROFILE" in auto|minimal|balanced|performance) ;; *) die "invalid resource profile" ;; esac
  if ! RESOURCE_PLAN="$(python3 "$RESOURCE_HELPER" --dir "$INSTALL_DIR" --profile "$DEPLOY_PROFILE" --db-mode "$DB_MODE" --retention "$BACKUP_RETENTION")"; then
    printf '%s\n' "$RESOURCE_PLAN" >&2
    die "capacity preflight failed; free capacity or choose a smaller profile"
  fi
  DEPLOY_PROFILE="$(resource_field profile)"
  log "资源 profile=$DEPLOY_PROFILE，预算=$(resource_field required_memory_mib) MiB，CPU=$(resource_field capacity.cpus)，可用磁盘=$(resource_field capacity.disk_free_mib) MiB"
  log "此预检是安装预算估算；仍需监控数据库、备份增长并进行后期负载验收。"
}

load_install_database_module() {
  local tmp script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
  if [[ -n "$script_dir" && -f "$script_dir/lib/install-database.sh" ]]; then
    # shellcheck source=/dev/null
    source "$script_dir/lib/install-database.sh"
    return
  fi
  tmp="$(mktemp)"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$DEPLOY_RAW_BASE/lib/install-database.sh" -o "$tmp" || { rm -f "$tmp"; die "failed to download database installer module"; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$DEPLOY_RAW_BASE/lib/install-database.sh" || { rm -f "$tmp"; die "failed to download database installer module"; }
  else
    rm -f "$tmp"
    die "curl or wget is required to load the database installer module"
  fi
  # shellcheck source=/dev/null
  source "$tmp"
  rm -f "$tmp"
}

load_service_detect_module() {
  local src_dir tmp
  src_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
  if [[ -n "$src_dir" && -f "$src_dir/lib/detect.sh" ]]; then
    # shellcheck source=/dev/null
    source "$src_dir/lib/detect.sh"
    return
  fi
  tmp="$(mktemp)"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$DEPLOY_RAW_BASE/lib/detect.sh" -o "$tmp" ||
      { rm -f "$tmp"; die "could not load Docker service discovery module"; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$DEPLOY_RAW_BASE/lib/detect.sh" ||
      { rm -f "$tmp"; die "could not load Docker service discovery module"; }
  else
    rm -f "$tmp"
    die "curl or wget is required for Docker service discovery"
  fi
  bash -n "$tmp" || { rm -f "$tmp"; die "service discovery module failed syntax check"; }
  # shellcheck source=/dev/null
  source "$tmp"
  rm -f "$tmp"
}
load_service_detect_module

detect_host() {
  local host=""
  host="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  printf '%s' "${host:-127.0.0.1}"
}

install_deploy_tools() {
  local module file stage toolkit_source target command_dir
  toolkit_source="$INSTALLER_SOURCE_DIR"
  stage="$(mktemp -d "$INSTALL_DIR/.manager-stage.XXXXXXXX")" || return 1
  mkdir -p "$stage/lib" "$stage/scripts"

  download_file() {
    local url="$1" dest="$2"
    local relative="${url#"$DEPLOY_RAW_BASE/"}"
    if [[ "$relative" != "$url" && -f "$toolkit_source/$relative" && ! -L "$toolkit_source/$relative" ]]; then
      cp -- "$toolkit_source/$relative" "$dest"
      return
    fi
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$dest" "$url"
    else
      return 1
    fi
  }

  for file in txboard.sh update.sh; do
    if ! download_file "$DEPLOY_RAW_BASE/$file" "$stage/$file" || ! bash -n "$stage/$file"; then
      rm -rf -- "$stage"
      warn "failed to download/validate TXBoard management tool: $file"
      return 1
    fi
  done

  for module in common service backup config diagnose uninstall detect xboard-import maintenance components; do
    if ! download_file "$DEPLOY_RAW_BASE/lib/$module.sh" "$stage/lib/$module.sh" || ! bash -n "$stage/lib/$module.sh"; then
      rm -rf -- "$stage"
      warn "failed to download/validate TXBoard manager module: $module"
      return 1
    fi
  done
  if ! download_file "$DEPLOY_RAW_BASE/scripts/core-diagnostics.py" "$stage/scripts/core-diagnostics.py" ||
     ! python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$stage/scripts/core-diagnostics.py"; then
    rm -rf -- "$stage"
    warn "failed to download/validate Core diagnostic helper"
    return 1
  fi
  if [[ -n "$NATIVE_CONFIG_DIR" ]]; then
    [[ -f "$INSTALL_DIR/scripts/native-runtime.py" && ! -L "$INSTALL_DIR/scripts/native-runtime.py" ]] ||
      die "native runner was not preserved in the installed toolkit"
  fi
  mkdir -p "$INSTALL_DIR/lib" "$INSTALL_DIR/scripts"
  for module in common service backup config diagnose uninstall detect xboard-import maintenance components; do
    mv -- "$stage/lib/$module.sh" "$INSTALL_DIR/lib/$module.sh"
  done
  for file in txboard.sh update.sh; do mv -- "$stage/$file" "$INSTALL_DIR/$file"; done
  mv -- "$stage/scripts/core-diagnostics.py" "$INSTALL_DIR/scripts/core-diagnostics.py"
  chmod 700 "$INSTALL_DIR/scripts/core-diagnostics.py"
  rm -rf -- "$stage"
  chmod 755 "$INSTALL_DIR/txboard.sh" "$INSTALL_DIR/update.sh" "$INSTALL_DIR"/lib/*.sh

  command_dir="${TXBOARD_COMMAND_DIR:-/usr/local/bin}"
  if [[ "${EUID:-$(id -u)}" -eq 0 && -d "$command_dir" ]]; then
    target="$command_dir/txboard"
    if [[ ! -e "$target" && ! -L "$target" ]] ||
       { [[ -L "$target" ]] && [[ "$(readlink -- "$target")" == "$INSTALL_DIR/txboard.sh" ]]; }; then
      ln -sfn "$INSTALL_DIR/txboard.sh" "$target"
    else
      warn "existing $target is unrelated; use $INSTALL_DIR/txboard.sh"
    fi
  fi
}

# Detect pre-existing deployments before asking how a NEW installation should
# expose HTTP/HTTPS, choose an administrator or create database credentials.
# --dir/env is authoritative; interactive users can select a different target.
if [[ "$RENDER_ONLY" -eq 0 ]]; then
  txboard_detect_scan "$INSTALL_DIR" || die "Docker service discovery failed"
  if (( TXBOARD_DETECT_TOTAL > 0 )); then
    txboard_detect_print
  fi
fi

install_ui_banner
install_ui_section "安装位置"
INSTALL_DIR="$(prompt "安装目录" "$INSTALL_DIR")"
[[ -n "$INSTALL_DIR" && "$INSTALL_DIR" == /* ]] || die "installation directory must be an absolute path"
[[ ! -L "$INSTALL_DIR" ]] || die "refusing to use a symlink installation directory: $INSTALL_DIR"
if command -v realpath >/dev/null 2>&1; then
  INSTALL_DIR="$(realpath -m -- "$INSTALL_DIR")"
elif command -v readlink >/dev/null 2>&1; then
  INSTALL_DIR="$(readlink -m -- "$INSTALL_DIR")"
else
  [[ "$INSTALL_DIR" != *"/../"* && "$INSTALL_DIR" != */.. && "$INSTALL_DIR" != *"/./"* && "$INSTALL_DIR" != */. ]] ||
    die "installation directory contains unresolved path traversal components"
fi

if [[ "${EUID:-$(id -u)}" -ne 0 && "$INSTALL_DIR" == /opt/* ]]; then
  die "installation under /opt requires root. Re-run with sudo or choose another --dir."
fi

case "${CLEAN_INSTALL_DIR,,}" in
  1|true|yes|y|on) CLEAN_INSTALL_DIR=true ;;
  0|false|no|n|off|"") CLEAN_INSTALL_DIR=false ;;
  *) die "invalid TXBOARD_CLEAN_INSTALL_DIR value: $CLEAN_INSTALL_DIR (use true/false)" ;;
esac
case "${ARCHIVE_ORPHAN_DIR,,}" in
  1|true|yes|y|on) ARCHIVE_ORPHAN_DIR=true ;;
  0|false|no|n|off|"") ARCHIVE_ORPHAN_DIR=false ;;
  *) die "invalid TXBOARD_ARCHIVE_ORPHAN_DIR value: $ARCHIVE_ORPHAN_DIR" ;;
esac
case "${INSTALL_VERBOSE,,}" in
  1|true|yes|y|on) INSTALL_VERBOSE=true ;;
  0|false|no|n|off|"") INSTALL_VERBOSE=false ;;
  *) die "invalid TXBOARD_INSTALL_VERBOSE value: $INSTALL_VERBOSE" ;;
esac

# 已有健康 TXBoard 应升级而不是重复安装或清理。
# Interactive callers can hand off to the safe updater instead of guessing.
if [[ "$RENDER_ONLY" -eq 0 && "$ASSUME_YES" -eq 0 ]]; then
  txboard_detect_scan "$INSTALL_DIR" ||
    die "cannot safely discover existing TXBoard containers"
  if (( TXBOARD_DETECT_TOTAL > 0 && TXBOARD_DETECT_TARGET_COUNT == 1 && TXBOARD_DETECT_FOREIGN_COUNT == 0 )); then
    txboard_detect_print
    if [[ "$TXBOARD_DETECT_TARGET_STATE" == running &&
          ( "$TXBOARD_DETECT_TARGET_HEALTH" == healthy || "$TXBOARD_DETECT_TARGET_HEALTH" == none ) &&
          -f "$INSTALL_DIR/compose.yaml" && -f "$INSTALL_DIR/api.env" && -f "$INSTALL_DIR/.env" ]]; then
      printf '\n检测到当前目录已安装并运行 TXBoard。\n  1) 升级现有 TXBoard（自动检测数据库并执行安全备份）\n  0) 退出，不修改任何内容\n请选择 [0]：' > /dev/tty
      IFS= read -r existing_choice < /dev/tty || true
      case "${existing_choice:-0}" in
        0) log "已退出，现有 TXBoard 未修改"; exit 0 ;;
        1)
          updated_script="$(mktemp /tmp/txboard-verified-update.XXXXXXXX)"
          if command -v curl >/dev/null 2>&1; then
            curl -fsSL "$DEPLOY_RAW_BASE/update.sh" -o "$updated_script" ||
              { rm -f "$updated_script"; die "failed to obtain safe existing-instance updater"; }
          elif command -v wget >/dev/null 2>&1; then
            wget -qO "$updated_script" "$DEPLOY_RAW_BASE/update.sh" ||
              { rm -f "$updated_script"; die "failed to obtain safe existing-instance updater"; }
          else
            rm -f "$updated_script"
            die "curl or wget is required for existing-instance upgrade"
          fi
          bash -n "$updated_script" || { rm -f "$updated_script"; die "unsafe updater: syntax invalid"; }
          chmod 700 "$updated_script"
          upgrade_status=0
          bash "$updated_script" --dir "$INSTALL_DIR" || upgrade_status=$?
          rm -f "$updated_script"
          exit "$upgrade_status"
          ;;
        *) die "选项无效，现有 TXBoard 未修改" ;;
      esac
    fi
    warn "TXBoard is not healthy/running or deployment config is incomplete; use txboard status/diagnose/start."
  fi
fi

# A previous failed setup can leave Compose credentials without a container.
# Only offer non-destructive archival, never silent deletion. Archive takes
# place AFTER the complete installation summary has been confirmed.
if [[ "$RENDER_ONLY" -eq 0 &&
      ( -f "$INSTALL_DIR/compose.yaml" || -f "$INSTALL_DIR/api.env" || -f "$INSTALL_DIR/.env" ) &&
      "$ARCHIVE_ORPHAN_DIR" != true && "$ASSUME_YES" -eq 0 ]]; then
  txboard_detect_scan "$INSTALL_DIR" ||
    die "cannot safely inspect orphan configuration owner"
  if (( TXBOARD_DETECT_TOTAL == 0 )); then
    warn "发现上次安装留下的部署配置：$INSTALL_DIR"
    confirm "未检测到实际 TXBoard 容器，是否在最终确认后归档旧目录并重新安装？原文件完整保留。" "N" ||
      die "existing deployment files preserved; archive declined"
    ARCHIVE_ORPHAN_DIR=true
  fi
fi

# Probe all Docker containers (including stopped ones) before ANY cleanup.
# Render-only does not mutate host Docker; it still protects deployment config.
if [[ "$RENDER_ONLY" -eq 0 ]]; then
  txboard_guard_install "$INSTALL_DIR" "$ARCHIVE_ORPHAN_DIR" ||
    die "existing/ambiguous TXBoard detected; installation did not modify this deployment"
elif [[ -f "$INSTALL_DIR/compose.yaml" || -f "$INSTALL_DIR/api.env" || -f "$INSTALL_DIR/.env" ]]; then
  die "render-only cannot replace an existing TXBoard deployment configuration; use a clean staging directory"
fi

# Delay database-plugin provisioning until an existing-install short circuit has
# succeeded, so discovery does not require or alter database credentials.
load_install_database_module

if [[ -z "$MODE" ]]; then
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    MODE="http"
  else
    install_ui_section "访问模式"
    printf '  %b1%b  域名访问（自动 HTTPS）\n' "$(install_ui_color yellow)" "$(install_ui_color reset)" > /dev/tty
    printf '  %b2%b  反向代理 / CDN HTTPS\n' "$(install_ui_color yellow)" "$(install_ui_color reset)" > /dev/tty
    printf '  %b3%b  纯 HTTP\n\n' "$(install_ui_color yellow)" "$(install_ui_color reset)" > /dev/tty
    mode_choice="$(choose "访问方式" "1" "3")"
    case "$mode_choice" in
      1) MODE="auto-https" ;;
      2) MODE="external-https" ;;
      3) MODE="http" ;;
    esac
  fi
fi

case "$MODE" in
  auto-https|external-https|http) ;;
  *) die "invalid mode: $MODE" ;;
esac
[[ -z "$REQUESTED_HTTP_BIND" || "$MODE" == http ]] || die '--http-bind is supported only with --mode http'

install_ui_section "应用配置"
if [[ "$INSTALL_TYPE" == fresh && "$ASSUME_YES" -eq 0 && -z "$NATIVE_CONFIG_DIR" && "$LEGACY_COMPAT" != true ]]; then
  install_ui_section "运行时配置"
  printf "  1) Native（需要私有配置目录和固定镜像摘要）
  2) 兼容安装流程
" > /dev/tty
  if [[ "$(choose "运行时" "1" "2")" == 1 ]]; then
    NATIVE_CONFIG_DIR="$(prompt "私有 Native 配置目录（安装目录之外）" "")"
    [[ -n "$NATIVE_CONFIG_DIR" ]] || die "native configuration directory is required"
    NATIVE_IMAGE="$(prompt "Native 镜像（repository@sha256 或本地 sha256 ID）" "")"
  else
    LEGACY_COMPAT=true
  fi
fi
if [[ "$INSTALL_TYPE" == fresh && -z "$NATIVE_CONFIG_DIR" && "$RENDER_ONLY" -eq 0 ]]; then
  [[ "$LEGACY_COMPAT" == true ]] || die 'fresh installation requires --native-config and --native-image'
  warn 'Explicit historical compatibility mode: native browser administration APIs are unavailable.'
fi
IMAGE_TAG="$(prompt "TXBoard 镜像版本（latest / dev / 固定版本）" "$IMAGE_TAG")"
[[ "$IMAGE_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "invalid image tag: $IMAGE_TAG"
IMAGE="$IMAGE_REPO:$IMAGE_TAG"

if [[ -n "$NATIVE_CONFIG_DIR" ]]; then
  [[ "$NATIVE_IMAGE" =~ ^sha256:[0-9a-f]{64}$ || "$NATIVE_IMAGE" =~ ^[a-z0-9][a-z0-9./:_-]{0,220}@sha256:[0-9a-f]{64}$ ]] ||
    die "native installation requires --native-image with an immutable image reference"
  IMAGE="$NATIVE_IMAGE"
  command -v python3 >/dev/null 2>&1 || die "native installation requires Python 3.10+"
  [[ "$INSTALL_TYPE" == fresh && "$NATIVE_CONFIG_DIR" == /* && -d "$NATIVE_CONFIG_DIR" && ! -L "$NATIVE_CONFIG_DIR" ]] ||
    die "--native-config requires a fresh installation and an absolute private configuration directory"
  [[ "$NATIVE_CONFIG_DIR" != "$INSTALL_DIR" && "$NATIVE_CONFIG_DIR" != "$INSTALL_DIR/"* ]] ||
    die "private native source configuration must be outside the target installation directory"
  native_email="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["identity"]["email"])' "$NATIVE_CONFIG_DIR/prepare.json")" ||
    die "cannot read native administrator configuration"
  [[ -z "$ADMIN_EMAIL" || "$ADMIN_EMAIL" == "$native_email" ]] || die "administrator email differs from native preparation"
  ADMIN_EMAIL="$native_email"
elif [[ -n "$NATIVE_IMAGE" ]]; then
  die "--native-image requires --native-config"
fi
if [[ "$ASSUME_YES" -eq 1 && -z "$ADMIN_EMAIL" ]]; then
  die "--yes requires --email or TXBOARD_ADMIN_EMAIL"
fi
if [[ -z "$NATIVE_CONFIG_DIR" ]]; then
  ADMIN_EMAIL="$(prompt "管理员邮箱" "${ADMIN_EMAIL:-admin@example.com}")"
fi
valid_email "$ADMIN_EMAIL" || die "invalid administrator email: $ADMIN_EMAIL"

case "${TEST_MODE,,}" in
  1|true|yes|y|on) TEST_MODE=true ;;
  0|false|no|n|off|"") TEST_MODE=false ;;
  *) die "invalid TXBOARD_TEST_MODE value: $TEST_MODE (use true/false)" ;;
esac

if [[ "$ASSUME_YES" -eq 0 ]]; then
  test_default="N"
  [[ "$TEST_MODE" == "true" ]] && test_default="Y"
  if confirm "启用测试模式？（允许使用通配地址）" "$test_default"; then
    TEST_MODE=true
  else
    TEST_MODE=false
  fi

fi

if [[ "$ASSUME_YES" -eq 0 && "$INSTALL_TYPE" == fresh && -z "$XBOARD_DUMP" && -z "$NATIVE_CONFIG_DIR" ]]; then
  install_ui_section "安装方式"
  printf '  %b1%b  全新安装        %b创建新的空数据库%b\n' "$(install_ui_color yellow)" "$(install_ui_color reset)" "$(install_ui_color muted)" "$(install_ui_color reset)" > /dev/tty
  printf '  %b2%b  从 XBoard 迁入  %b可自动备份原 MySQL%b\n' "$(install_ui_color yellow)" "$(install_ui_color reset)" "$(install_ui_color muted)" "$(install_ui_color reset)" > /dev/tty
  install_choice="$(prompt "安装类型（1 / 2）" "1")"
  case "$install_choice" in
    1) INSTALL_TYPE=fresh ;;
    2) INSTALL_TYPE=xboard-import ;;
    *) die "invalid installation type" ;;
  esac
fi
case "${XBOARD_AUTO_DUMP,,}" in
  1|true|yes|y|on) XBOARD_AUTO_DUMP=true ;;
  0|false|no|n|off|"") XBOARD_AUTO_DUMP=false ;;
  *) die "invalid TXBOARD_XBOARD_AUTO_DUMP value: $XBOARD_AUTO_DUMP" ;;
esac
case "${DISCARD_LEGACY_AUDIT,,}" in
  1|true|yes|y|on) DISCARD_LEGACY_AUDIT=true ;;
  0|false|no|n|off|"") DISCARD_LEGACY_AUDIT=false ;;
  *) die "invalid TXBOARD_DISCARD_LEGACY_AUDIT value: $DISCARD_LEGACY_AUDIT" ;;
esac
case "$INSTALL_TYPE" in
  fresh)
    [[ "$XBOARD_AUTO_DUMP" == false && -z "$XBOARD_SOURCE_CONTAINER" && -z "$XBOARD_SOURCE_DATABASE" ]] ||
      die "automatic XBoard backup requires XBoard import mode"
    [[ "$DISCARD_LEGACY_AUDIT" == false ]] ||
      die "--discard-legacy-audit requires XBoard import mode"
    [[ -z "$XBOARD_DUMP" && -z "$XBOARD_ENV_FILE" ]] ||
      die "XBoard import requires --install-type xboard-import and both source paths" ;;
  xboard-import)
    if [[ "$ASSUME_YES" -eq 0 ]]; then
      if [[ -z "$XBOARD_DUMP" && "$XBOARD_AUTO_DUMP" == false ]]; then
        install_ui_section "XBoard 数据来源"
        printf '  %b1%b  自动导出本机 MySQL     %b推荐 · 自动生成 SQL.gz%b\n' "$(install_ui_color yellow)" "$(install_ui_color reset)" "$(install_ui_color muted)" "$(install_ui_color reset)" > /dev/tty
        printf '  %b2%b  使用已有 SQL.gz 文件\n' "$(install_ui_color yellow)" "$(install_ui_color reset)" > /dev/tty
        source_choice="$(choose "数据来源" "1" "2")"
        if [[ "$source_choice" == 1 ]]; then
          XBOARD_AUTO_DUMP=true
        fi
      fi
      if [[ "$XBOARD_AUTO_DUMP" == false ]]; then
        XBOARD_DUMP="$(prompt "XBoard 数据库 SQL.gz 备份的绝对路径" "$XBOARD_DUMP")"
      fi
      xboard_default_env=""
      [[ -f /opt/xboard/.env ]] && xboard_default_env=/opt/xboard/.env
      XBOARD_ENV_FILE="$(prompt "原 XBoard .env 的绝对路径（用于保留 APP_KEY）" "${XBOARD_ENV_FILE:-$xboard_default_env}")"
      if [[ "$DISCARD_LEGACY_AUDIT" == false ]] &&
          confirm "只在新目标库丢弃旧审计插件的 6 张表及 5 条迁移记录？（源备份保留）" "N"; then
        DISCARD_LEGACY_AUDIT=true
      fi
    fi
    [[ "$XBOARD_ENV_FILE" == /* && -f "$XBOARD_ENV_FILE" && ! -L "$XBOARD_ENV_FILE" ]] ||
      die "XBoard .env file must be an absolute file path"
    [[ "$XBOARD_ENV_FILE" != "$INSTALL_DIR/"* ]] ||
      die "XBoard .env must not be inside the TXBoard install directory"
    if [[ "$XBOARD_AUTO_DUMP" == true ]]; then
      [[ -z "$XBOARD_DUMP" ]] || die "--xboard-auto-dump cannot combine with --xboard-dump"
      [[ "$RENDER_ONLY" -eq 0 ]] || die "--xboard-auto-dump cannot combine with --render-only"
      XBOARD_SOURCE_CONTAINER="${XBOARD_SOURCE_CONTAINER:-$(xboard_source_env_value "$XBOARD_ENV_FILE" DB_HOST)}"
      XBOARD_SOURCE_DATABASE="${XBOARD_SOURCE_DATABASE:-$(xboard_source_env_value "$XBOARD_ENV_FILE" DB_DATABASE)}"
      if ! docker inspect --type container "$XBOARD_SOURCE_CONTAINER" >/dev/null 2>&1; then
        [[ "$ASSUME_YES" -eq 0 ]] ||
          die "source MySQL container '$XBOARD_SOURCE_CONTAINER' missing; use --xboard-source-container"
        warn "XBoard .env DB_HOST is not a Docker container; select from detected MySQL containers"
        mapfile -t source_mysql_candidates < <(list_mysql_containers)
        (( ${#source_mysql_candidates[@]} > 0 )) || die "no MySQL Docker container found; use SQL.gz manually"
        printf '\nMySQL containers:\n' > /dev/tty
        for i in "${!source_mysql_candidates[@]}"; do
          printf '  %d) %s\n' "$((i+1))" "${source_mysql_candidates[$i]}" > /dev/tty
        done
        source_pick="$(choose "XBoard MySQL 源容器" "1" "${#source_mysql_candidates[@]}")"
        IFS=$'\t' read -r _ XBOARD_SOURCE_CONTAINER _ <<< "${source_mysql_candidates[$((source_pick-1))]}"
      fi
      if [[ "$ASSUME_YES" -eq 0 ]]; then
        XBOARD_SOURCE_DATABASE="$(prompt "原 XBoard 数据库名（只备份）" "${XBOARD_SOURCE_DATABASE:-xboard}")"
      fi
      [[ "$XBOARD_SOURCE_DATABASE" =~ ^[A-Za-z0-9_]+$ ]] ||
        die "invalid XBoard source database name"
      log "XBoard source: $XBOARD_SOURCE_CONTAINER/$XBOARD_SOURCE_DATABASE"
    else
      [[ -z "$XBOARD_SOURCE_CONTAINER" && -z "$XBOARD_SOURCE_DATABASE" ]] ||
        die "manual SQL.gz and automatic MySQL source settings cannot mix"
      [[ "$XBOARD_DUMP" == /* && -f "$XBOARD_DUMP" && ! -L "$XBOARD_DUMP" && -s "$XBOARD_DUMP" ]] ||
        die "XBoard dump must be a nonempty absolute file path"
      [[ "$XBOARD_DUMP" != "$INSTALL_DIR/"* ]] ||
        die "XBoard dump must not reside inside the TXBoard installation directory"
    fi
    [[ "$RESET_LOCAL_DB" -eq 0 ]] ||
      die "XBoard import must never use --reset-local-db"
    command -v python3 >/dev/null || die "python3 is required for XBoard import" ;;
  *) die "invalid installation type: $INSTALL_TYPE" ;;
esac

install_ui_section "数据库配置"
select_database_mode
BACKUP_RETENTION="$(prompt "保留备份份数（0 表示全部保留）" "$BACKUP_RETENTION")"
valid_nonnegative_int "$BACKUP_RETENTION" || die "backup retention must be a non-negative integer"
# Capacity must be accepted before host database provisioning can create users,
# databases or Docker networks.
configure_resources
if [[ -n "$NATIVE_CONFIG_DIR" ]]; then
  load_native_helper
  python3 "$NATIVE_HELPER" validate-config --dir "$INSTALL_DIR" --source "$NATIVE_CONFIG_DIR" ||
    die "native configuration rejected before database provisioning"
fi
configure_database

# Fail closed even for external/host connection aliases. Different source and
# destination database NAMES are required for automatic imports.
if [[ "$INSTALL_TYPE" == xboard-import && "$XBOARD_AUTO_DUMP" == true &&
      "$XBOARD_SOURCE_DATABASE" == "$DB_DATABASE" ]]; then
  die "automatic XBoard import requires a distinct target database name (source: $XBOARD_SOURCE_DATABASE)"
fi

# Source and destination database names were already required to differ above.


DB_PASSWORD_ENV="$(dotenv_quote "$DB_PASSWORD")"

APP_URL=""
SITE_ADDRESS=":80"
HTTP_BIND="0.0.0.0"
HTTPS_BIND="0.0.0.0"
SESSION_SECURE_COOKIE=false
PUBLISH_HTTPS=0

case "$MODE" in
  auto-https)
    DOMAIN="$(prompt "面板域名" "$DOMAIN")"
    valid_domain "$DOMAIN" || die "invalid domain: $DOMAIN"
    HTTP_PORT="$(prompt "HTTP 端口" "${HTTP_PORT:-80}")"
    HTTPS_PORT="$(prompt "HTTPS 端口" "${HTTPS_PORT:-443}")"
    valid_port "$HTTP_PORT" || die "invalid HTTP port: $HTTP_PORT"
    valid_port "$HTTPS_PORT" || die "invalid HTTPS port: $HTTPS_PORT"
    SITE_ADDRESS="$DOMAIN"
    APP_URL="https://$DOMAIN"
    SESSION_SECURE_COOKIE=true
    PUBLISH_HTTPS=1
    ;;
  external-https)
    DOMAIN="$(prompt "对外访问域名" "$DOMAIN")"
    valid_domain "$DOMAIN" || die "invalid domain: $DOMAIN"
    HTTP_BIND="127.0.0.1"
    HTTP_PORT="$(prompt "反向代理使用的本地 HTTP 端口" "${HTTP_PORT:-8080}")"
    valid_port "$HTTP_PORT" || die "invalid HTTP port: $HTTP_PORT"
    APP_URL="https://$DOMAIN"
    SESSION_SECURE_COOKIE=true
    ;;
  http)
    PUBLIC_HOST="$(prompt "公网域名或服务器 IP" "${PUBLIC_HOST:-$(detect_host)}")"
    [[ -n "$PUBLIC_HOST" && ! "$PUBLIC_HOST" =~ [[:space:]] ]] || die "invalid public host"
    if [[ "$PUBLIC_HOST" == "0.0.0.0" || "$PUBLIC_HOST" == "::" ]]; then
      if [[ "$TEST_MODE" == "true" ]]; then
        warn "test deployment mode: accepting wildcard Public host $PUBLIC_HOST; APP_URL is intended for testing only"
      else
        die "public host cannot be $PUBLIC_HOST in standard deployment mode. Use the server IP/hostname, or explicitly enable test deployment mode with --test-mode."
      fi
    fi
    HTTP_PORT="$(prompt "HTTP 端口" "${HTTP_PORT:-80}")"
    valid_port "$HTTP_PORT" || die "invalid HTTP port: $HTTP_PORT"
    if [[ -n "$REQUESTED_HTTP_BIND" ]]; then
      HTTP_BIND="$REQUESTED_HTTP_BIND"
    elif [[ "${PUBLIC_HOST,,}" == localhost ]]; then
      HTTP_BIND=127.0.0.1
    elif [[ "$PUBLIC_HOST" == ::1 || "$PUBLIC_HOST" == '[::1]' || "$PUBLIC_HOST" =~ ^127\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      HTTP_BIND="$(normalize_http_bind "$PUBLIC_HOST")" || die 'invalid loopback host'
    fi
    if [[ "$PUBLIC_HOST" == *:* && "$PUBLIC_HOST" != \[*\] ]]; then PUBLIC_HOST="[$PUBLIC_HOST]"; fi
    if [[ "$HTTP_PORT" == "80" ]]; then
      APP_URL="http://$PUBLIC_HOST"
    else
      APP_URL="http://$PUBLIC_HOST:$HTTP_PORT"
    fi
    log "HTTP listener: $HTTP_BIND:$HTTP_PORT; public origin: $APP_URL"
    ;;
esac

if [[ "$ASSUME_YES" -eq 0 ]]; then
  install_ui_section "TXBoard 安装信息确认"
  cat > /dev/tty <<EOF

------------------------------------------------------------
TXBoard 安装信息确认

Image:          $IMAGE
Mode:           $MODE
Public URL:     $APP_URL
Admin email:    $ADMIN_EMAIL
Install dir:    $INSTALL_DIR
Test mode:      $TEST_MODE
HTTP mapping:   $HTTP_BIND:$HTTP_PORT -> container:80
Backup retain:  $BACKUP_RETENTION
Resource profile: $DEPLOY_PROFILE
Required RAM:    $(resource_field required_memory_mib) MiB (including host reserve)
Available RAM:   $(resource_field capacity.available_mib) MiB
Free disk:       $(resource_field capacity.disk_free_mib) MiB
Native runtime:  $(if [[ -n "$NATIVE_CONFIG_DIR" ]]; then printf "private configuration + immutable image"; else printf "legacy compatibility"; fi)
Install type:    $INSTALL_TYPE
XBoard dump:     $(if [[ "$XBOARD_AUTO_DUMP" == true ]]; then printf 'automatically generated'; else printf '%s' "${XBOARD_DUMP:-none}"; fi)
XBoard source:   $(if [[ "$XBOARD_AUTO_DUMP" == true ]]; then printf '%s/%s' "$XBOARD_SOURCE_CONTAINER" "$XBOARD_SOURCE_DATABASE"; else printf 'offline backup'; fi)
Discard old audit: $DISCARD_LEGACY_AUDIT (isolated target only)
Archive orphan dir: $ARCHIVE_ORPHAN_DIR (keep all prior files)
Database mode:   $DB_MODE
Database:        $DB_HOST:$DB_PORT/$DB_DATABASE
EOF
  if [[ "$PUBLISH_HTTPS" -eq 1 ]]; then
    printf 'HTTPS mapping:  %s:%s -> container:443\n' "$HTTPS_BIND" "$HTTPS_PORT" > /dev/tty
  fi
  cat > /dev/tty <<'EOF'
------------------------------------------------------------

EOF
  confirm "确认以上配置并开始安装？" "Y" || { log "已取消"; exit 0; }
fi

# Existing unrelated files must not be removed before the operator reviews the
# complete installation summary; a 已取消 wizard leaves everything intact.
# Repeat the non-destructive ownership guard after the final confirmation.
# Docker/container identity could have changed during the interactive wizard.
if [[ "$RENDER_ONLY" -eq 0 ]]; then
  txboard_guard_install "$INSTALL_DIR" "$ARCHIVE_ORPHAN_DIR" ||
    die "TXBoard appeared before installation; existing data is untouched"
fi

# Produce and validate source SQL.gz before touching installation files or
# importing anything into the disposable target database.
if [[ "$INSTALL_TYPE" == xboard-import && "$XBOARD_AUTO_DUMP" == true && "$RENDER_ONLY" -eq 0 ]]; then
  txboard_auto_backup_xboard_source "$XBOARD_SOURCE_CONTAINER" "$XBOARD_SOURCE_DATABASE"
fi

if [[ "$ARCHIVE_ORPHAN_DIR" == true &&
      ( -f "$INSTALL_DIR/compose.yaml" || -f "$INSTALL_DIR/api.env" || -f "$INSTALL_DIR/.env" ) ]]; then
  archive_orphan_install_dir
fi
if install_dir_has_content; then
  clean_existing_install_dir
fi

# Even --reset-local-db never deletes the managed volume before the final
# confirmation, and it refuses to remove volumes used by live containers.
if (( LOCAL_DB_RESET_PENDING == 1 )); then
  [[ "$RENDER_ONLY" -eq 0 && "$DB_MODE" == local ]] ||
    die "unexpected managed database reset state; refusing destructive operation"
  txboard_guard_install "$INSTALL_DIR" ||
    die "another TXBoard appeared; managed MySQL volume will not be removed"
  log "removing explicitly approved managed MySQL volume: $LOCAL_DB_VOLUME"
  docker volume rm "$LOCAL_DB_VOLUME" >/dev/null ||
    die "could not remove $LOCAL_DB_VOLUME (it may be attached); installation stopped"
fi

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
umask 077

mkdir -p data/storage/app data/plugins backups scripts
cp -- "$RESOURCE_HELPER" scripts/deployment-profile.py
chmod 700 scripts/deployment-profile.py
printf "%s\n" "$RESOURCE_PLAN" > resource-plan.json
chmod 600 resource-plan.json
mkdir -p -m 700 backups/installer
chmod 700 backups/installer
INSTALL_LOG_FILE="$INSTALL_DIR/backups/installer/install.log"
touch "$INSTALL_LOG_FILE"
chmod 600 "$INSTALL_LOG_FILE"

cat > .env <<EOF
TXBOARD_IMAGE=$IMAGE
TXBOARD_ADMIN_EMAIL=$ADMIN_EMAIL
TXBOARD_TEST_MODE=$TEST_MODE
TXBOARD_MODE=$MODE
TXBOARD_DOMAIN=$DOMAIN
TXBOARD_PUBLIC_HOST=$PUBLIC_HOST
TXBOARD_DB_MODE=$DB_MODE
TXBOARD_DB_HOST=$DB_HOST
TXBOARD_DB_PORT=$DB_PORT
TXBOARD_DB_DATABASE=$DB_DATABASE
TXBOARD_DB_USERNAME=$DB_USERNAME
TXBOARD_DB_PASSWORD=$DB_PASSWORD_ENV
TXBOARD_DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD
TXBOARD_DB_HOST_KIND=$DB_HOST_KIND
TXBOARD_DB_CONTAINER=$DB_CONTAINER
TXBOARD_DB_LINK_NETWORK=$DB_LINK_NETWORK
TXBOARD_DB_PROXY_REQUIRED=$DB_PROXY_REQUIRED
TXBOARD_DB_PROXY_BIND=$DB_PROXY_BIND
TXBOARD_DB_PROXY_PORT=$DB_PROXY_PORT
TXBOARD_DB_SOURCE_PORT=$DB_SOURCE_PORT
TXBOARD_HTTP_BIND=$HTTP_BIND
TXBOARD_HTTP_PORT=$HTTP_PORT
TXBOARD_HTTPS_BIND=$HTTPS_BIND
TXBOARD_HTTPS_PORT=${HTTPS_PORT:-443}
TXBOARD_SITE_ADDRESS=$SITE_ADDRESS
TXBOARD_TLS_DIRECTIVE=
TXBOARD_BACKUP_INTERVAL=86400
TXBOARD_BACKUP_RETENTION=$BACKUP_RETENTION
TXBOARD_RESOURCE_PROFILE=$DEPLOY_PROFILE
TXBOARD_CORE_MEMORY_MIB=$(resource_field limits.core_mib)
TXBOARD_CORE_CPUS=$(resource_field limits.core_cpus)
TXBOARD_DATABASE_MEMORY_MIB=$(resource_field limits.database_mib)
TXBOARD_DATABASE_CPUS=$(resource_field limits.database_cpus)
TXBOARD_BACKUP_MEMORY_MIB=$(resource_field limits.backup_mib)
TXBOARD_BACKUP_CPUS=$(resource_field limits.backup_cpus)
TXBOARD_OCTANE_WORKERS=$(resource_field limits.octane)
TXBOARD_HORIZON_PIPELINE=$(resource_field limits.pipeline)
TXBOARD_HORIZON_BUSINESS=$(resource_field limits.business)
TXBOARD_HORIZON_NOTIFICATION=$(resource_field limits.notification)
TXBOARD_WORKER_MEMORY_MIB=$(resource_field limits.worker_mib)
TXBOARD_REDIS_MEMORY_MIB=$(resource_field limits.redis_mib)
TXBOARD_SUBSCRIBE_PATH=s
EOF

cat > api.env <<EOF
APP_NAME=TXBoard
APP_ENV=production
APP_KEY=
APP_DEBUG=false
APP_URL=$APP_URL
LOG_CHANNEL=stack
LOG_LEVEL=warning
DB_CONNECTION=mysql
DB_HOST=$DB_HOST
DB_PORT=$DB_PORT
DB_DATABASE=$DB_DATABASE
DB_USERNAME=$DB_USERNAME
DB_PASSWORD=$DB_PASSWORD_ENV
REDIS_HOST=/data/redis.sock
REDIS_PASSWORD=null
REDIS_PORT=0
BROADCAST_DRIVER=log
CACHE_DRIVER=redis
QUEUE_CONNECTION=redis
SESSION_SECURE_COOKIE=$SESSION_SECURE_COOKIE
CORS_ALLOWED_ORIGINS=
CORS_ALLOWED_ORIGINS_PATTERNS=
MAIL_MAILER=smtp
MAIL_HOST=smtp.mailtrap.io
MAIL_PORT=2525
MAIL_USERNAME=null
MAIL_PASSWORD=null
MAIL_ENCRYPTION=null
MAIL_FROM_ADDRESS=noreply@example.com
MAIL_FROM_NAME=TXBoard
MAILGUN_DOMAIN=
MAILGUN_SECRET=
INSTALLED=false
EOF

NATIVE_BACKUP_VOLUME_BLOCK=""
NATIVE_BACKUP_MODE=0
NATIVE_VOLUME_BLOCK=""
PLUGIN_VOLUME_BLOCK="      - ./data/plugins:/www/plugins"
if [[ -n "$NATIVE_CONFIG_DIR" ]]; then
  mkdir -p "$INSTALL_DIR/scripts"
  cp -- "$NATIVE_HELPER" "$INSTALL_DIR/scripts/native-runtime.py"
  chmod 700 "$INSTALL_DIR/scripts/native-runtime.py"
  python3 "$INSTALL_DIR/scripts/native-runtime.py" stage-config --dir "$INSTALL_DIR" --source "$NATIVE_CONFIG_DIR" || die "native configuration rejected"
  PLUGIN_VOLUME_BLOCK=""
  NATIVE_BACKUP_MODE=1
  NATIVE_BACKUP_VOLUME_BLOCK="      - ./:/backup-deployment:ro"
  NATIVE_VOLUME_BLOCK="      - ./native:/run/txboard-native:ro"
fi

cat > backup.sh <<'BACKUP'
#!/bin/sh
#
# Back up everything needed to rebuild this instance.
#
# Runs both as the compose `backup` service (periodic) and as a one-shot host
# command (`TXBOARD_BACKUP_INTERVAL` unset/0).
#
# What is captured, and why:
#   db.sql.gz           the whole schema and data
#   env                 APP_KEY lives here. The encrypted columns in the dump are
#                       unreadable without it, so a database-only backup is not
#                       a backup.
#   storage-app.tar.gz  uploads and anything else under storage/app
#   storage-theme.tar.gz  installed user themes under storage/theme (if present)
#   plugins.tar.gz        installed plugins under plugins (if present)
#   CHECKSUMS.sha256      integrity for all present backed-up payloads
#   MANIFEST            what the archive is, so a restore needs no guesswork
#
# Environment:
#   DB_HOST, DB_PORT, DB_DATABASE, DB_USERNAME, DB_PASSWORD   connection
#   BACKUP_DIR        where archives are written          (default /backups)
#   BACKUP_RETENTION  archives to keep, 0 = keep all      (default 7)
#   BACKUP_INTERVAL   seconds between runs, 0 = run once  (default 0)
#   BACKUP_SOURCE_DIR the api checkout holding .env       (default /backup-source/api)
#
set -eu
umask 077

DB_HOST="${DB_HOST:-database}"
DB_PORT="${DB_PORT:-3306}"
DB_DATABASE="${DB_DATABASE:?DB_DATABASE is required}"
DB_USERNAME="${DB_USERNAME:?DB_USERNAME is required}"
DB_PASSWORD="${DB_PASSWORD:-}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
BACKUP_RETENTION="${BACKUP_RETENTION:-7}"
BACKUP_INTERVAL="${BACKUP_INTERVAL:-0}"
BACKUP_SOURCE_DIR="${BACKUP_SOURCE_DIR:-/backup-source/api}"

log() { echo "[backup] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }

prune() {
    case "$BACKUP_RETENTION" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$BACKUP_RETENTION" -gt 0 ] || return 0

    total=$(ls -1 "$BACKUP_DIR" 2>/dev/null | grep -cE '^[0-9]{8}T[0-9]{6}Z$' || true)
    [ "$total" -gt "$BACKUP_RETENTION" ] || return 0

    remove=$((total - BACKUP_RETENTION))
    log "pruning $remove archive(s), keeping $BACKUP_RETENTION"
    ls -1 "$BACKUP_DIR" | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort | head -n "$remove" |
        while read -r old; do
            [ -n "$old" ] || continue
            rm -rf "$BACKUP_DIR/$old"
        done
}

native_source_snapshot() (
    cd "$deployment" || return 1
    for item in .env api.env compose.yaml native/prepare.json native/runtime.env native/node-recipients.json native/signer.seed native/provider-ca.pem native/provider-client.pem native/provider-client.key; do
        [ -f "$item" ] && [ -s "$item" ] && [ ! -L "$item" ] || return 1
    done
    [ -d native ] && [ ! -L native ] || return 1
    [ ! -L .native-deploy ] || return 1
    # Check regular materials and the durable intent at both ends of an online
    # dump, including an upgrade that starts and finishes during the dump.
    find native ! -type f ! -type d -print > "$dest/.native-special" || return 1
    [ ! -s "$dest/.native-special" ] || return 1
    sha256sum .env api.env compose.yaml > "$dest/.native-sources" || return 1
    find native -type f -exec sha256sum {} + >> "$dest/.native-sources" || return 1
    for item in data/plugins data/storage/theme; do
        if [ -e "$item" ] || [ -L "$item" ]; then
            [ -d "$item" ] && [ ! -L "$item" ] || return 1
            find "$item" ! -type f ! -type d -print > "$dest/.native-special" || return 1
            [ ! -s "$dest/.native-special" ] || return 1
            find "$item" -type f -exec sha256sum {} + >> "$dest/.native-sources" || return 1
        fi
    done
    if [ -e .native-deploy/intent.json ]; then
        [ -f .native-deploy/intent.json ] && [ ! -L .native-deploy/intent.json ] || return 1
        sha256sum .native-deploy/intent.json >> "$dest/.native-sources" || return 1
    fi
    sort "$dest/.native-sources" > "$dest/.native-sorted" || return 1
    sha256sum "$dest/.native-sorted"
)

run_backup() (
    stamp=$(date -u '+%Y%m%dT%H%M%SZ')
    dest="$BACKUP_DIR/$stamp"
    mkdir -p "$BACKUP_DIR"
    # Refuse same-second parallel backups: a failed copy must never delete
    # an existing complete snapshot sharing the timestamp.
    if ! mkdir "$dest"; then
        log "ERROR: archive timestamp collision; existing snapshot untouched"
        return 1
    fi
    trap 'rm -rf "$dest"' EXIT
    trap 'exit 1' HUP INT TERM

    if [ "${BACKUP_NATIVE_MODE:-0}" = 1 ]; then
        deployment=${BACKUP_DEPLOYMENT_DIR:-/backup-deployment}
        if [ -e "$deployment/.upgrade-in-progress" ] && [ "${BACKUP_NATIVE_FROZEN:-0}" != 1 ]; then
            log "ERROR: native operation active; periodic backup deferred"; return 1
        fi
        native_before=$(native_source_snapshot) || { log "ERROR: native materials unavailable"; return 1; }
    fi

    log "dumping $DB_DATABASE@$DB_HOST:$DB_PORT -> $dest/db.sql.gz"
    # --single-transaction keeps InnoDB consistent without locking the panel.
    # --set-gtid-purged=OFF stops mysqldump emitting GTID statements that a
    # restore into a server without GTID enabled would reject.
    # POSIX sh reports only the last command's status in a pipeline.
    # Export first and check mysqldump before compressing the archive.
    dump_file="$dest/db.sql"
    if ! MYSQL_PWD="$DB_PASSWORD" mysqldump \
            --host="$DB_HOST" \
            --port="$DB_PORT" \
            --user="$DB_USERNAME" \
            --single-transaction \
            --quick \
            --routines \
            --events \
            --triggers \
            --set-gtid-purged=OFF \
            --default-character-set=utf8mb4 \
            "$DB_DATABASE" > "$dump_file" 2>/dev/null; then
        log "ERROR: mysqldump failed; discarding the partial archive"
        rm -rf "$dest"
        return 1
    fi
    if [ ! -s "$dump_file" ] || ! gzip -9 "$dump_file"; then
        log "ERROR: database dump is empty or compression failed"
        rm -rf "$dest"
        return 1
    fi
    if [ ! -s "$dest/db.sql.gz" ] || ! gzip -t "$dest/db.sql.gz" 2>/dev/null; then
        log "ERROR: db.sql.gz is empty or corrupt; discarding the archive"
        rm -rf "$dest"
        return 1
    fi

    log "  db.sql.gz: $(wc -c < "$dest/db.sql.gz" | tr -d ' ') bytes"

    # APP_KEY is indispensable when restoring encrypted settings.
    if [ ! -s "$BACKUP_SOURCE_DIR/.env" ] ||
       ! grep -Eq '^APP_KEY=.+$' "$BACKUP_SOURCE_DIR/.env"; then
        log "ERROR: missing .env or APP_KEY; refusing incomplete backup"
        return 1
    fi
    cp "$BACKUP_SOURCE_DIR/.env" "$dest/env"
    chmod 600 "$dest/env"
    log "  captured .env (contains APP_KEY)"

    if [ -d "$BACKUP_SOURCE_DIR/storage/app" ]; then
        if ! tar -czf "$dest/storage-app.tar.gz" -C "$BACKUP_SOURCE_DIR/storage/app" . 2>/dev/null ||
           ! gzip -t "$dest/storage-app.tar.gz"; then
            log "ERROR: storage/app archive failed; refusing incomplete backup"
            return 1
        fi
        log "  captured storage/app"
    else
        log "  no storage/app yet (no uploads to capture)"
    fi

    # User-installed theme and plugin source lives outside storage/app.
    for entry in "storage/theme:storage-theme.tar.gz" "plugins:plugins.tar.gz"; do
        source_dir=${entry%%:*}
        archive_name=${entry#*:}
        if [ -d "$BACKUP_SOURCE_DIR/$source_dir" ]; then
            if ! tar -czf "$dest/$archive_name" -C "$BACKUP_SOURCE_DIR/$source_dir" . 2>/dev/null ||
               ! gzip -t "$dest/$archive_name"; then
                log "ERROR: cannot preserve $source_dir; refusing incomplete backup"
                return 1
            fi
            log "  captured $source_dir"
        fi
    done

    if [ "${BACKUP_NATIVE_MODE:-0}" = 1 ]; then
        deployment=${BACKUP_DEPLOYMENT_DIR:-/backup-deployment}
        [ -d "$deployment/native" ] && [ ! -L "$deployment/native" ] || { log "ERROR: native materials unavailable"; return 1; }
        if [ -e "$deployment/.upgrade-in-progress" ] && [ "${BACKUP_NATIVE_FROZEN:-0}" != 1 ]; then
            log "ERROR: native operation active; periodic backup deferred"; return 1
        fi
        set -- .env api.env compose.yaml native
        for item in resource-plan.json .native-deploy data/plugins data/storage/theme; do
            if [ -e "$deployment/$item" ]; then
                [ ! -L "$deployment/$item" ] || return 1
                if [ -d "$deployment/$item" ] && find "$deployment/$item" -type l -print | grep -q .; then return 1; fi
                set -- "$@" "$item"
            fi
        done
        tar -czf "$dest/native-deployment.tar.gz" -C "$deployment" "$@" && gzip -t "$dest/native-deployment.tar.gz" || return 1
        if [ -e "$deployment/.upgrade-in-progress" ] && [ "${BACKUP_NATIVE_FROZEN:-0}" != 1 ]; then
            log "ERROR: native operation started during backup; snapshot discarded"; return 1
        fi
        native_after=$(native_source_snapshot) || return 1
        [ "$native_before" = "$native_after" ] || { log "ERROR: native configuration or intent changed during backup"; return 1; }
        rm -f "$dest/.native-special" "$dest/.native-sources" "$dest/.native-sorted"
    fi

    contents="db.sql.gz env"
    for entry in storage-app.tar.gz storage-theme.tar.gz plugins.tar.gz native-deployment.tar.gz; do
        [ ! -f "$dest/$entry" ] || contents="$contents $entry"
    done
    {
        echo "created_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "database=$DB_DATABASE"
        echo "db_host=$DB_HOST"
        echo "contents=$contents"
        echo "native=${BACKUP_NATIVE_MODE:-0}"
        echo "consistency=$(if [ "${BACKUP_NATIVE_FROZEN:-0}" = 1 ]; then echo native-frozen; else echo online-snapshot; fi)"
    } > "$dest/MANIFEST"

    (
        cd "$dest" || exit 1
        set -- db.sql.gz env
        for item in storage-app.tar.gz storage-theme.tar.gz plugins.tar.gz native-deployment.tar.gz; do
            [ ! -f "$item" ] || set -- "$@" "$item"
        done
        sha256sum "$@" MANIFEST > CHECKSUMS.sha256
        sha256sum -c CHECKSUMS.sha256 >/dev/null
    ) || {
        log "ERROR: backup integrity checksum failed"
        return 1
    }
    log "wrote $dest"
    trap - EXIT HUP INT TERM
    prune
)

if [ "$BACKUP_INTERVAL" -gt 0 ] 2>/dev/null; then
    log "periodic mode: every ${BACKUP_INTERVAL}s, retention ${BACKUP_RETENTION}"
    while true; do
        run_backup || log "backup failed; will retry at the next interval"
        sleep "$BACKUP_INTERVAL"
    done
else
    run_backup
fi
BACKUP
chmod 700 backup.sh

if [[ "$PUBLISH_HTTPS" -eq 1 ]]; then
  PORTS_BLOCK='      - "${TXBOARD_HTTP_BIND:-0.0.0.0}:${TXBOARD_HTTP_PORT:-80}:80"
      - "${TXBOARD_HTTPS_BIND:-0.0.0.0}:${TXBOARD_HTTPS_PORT:-443}:443"'
else
  PORTS_BLOCK='      - "${TXBOARD_HTTP_BIND:-0.0.0.0}:${TXBOARD_HTTP_PORT:-80}:80"'
fi

DATABASE_SERVICE_BLOCK=""
DB_PROXY_SERVICE_BLOCK=""
TXBOARD_DB_DEPENDS_BLOCK=""
BACKUP_DB_DEPENDS_BLOCK=""
DATABASE_VOLUME_BLOCK=""
DB_EXTRA_HOSTS_BLOCK=""
DB_NETWORKS_BLOCK=""
DB_NETWORK_DECL_BLOCK=""

prepare_database_compose_blocks

cat > compose.yaml <<EOF
name: $COMPOSE_PROJECT_NAME

x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

services:
$DATABASE_SERVICE_BLOCK
$DB_PROXY_SERVICE_BLOCK
  txboard:
    image: \${TXBOARD_IMAGE:?missing TXBOARD_IMAGE}
    restart: unless-stopped
    logging: *default-logging
    mem_limit: \${TXBOARD_CORE_MEMORY_MIB:?missing resource budget}m
    memswap_limit: \${TXBOARD_CORE_MEMORY_MIB:?missing resource budget}m
    cpus: "\${TXBOARD_CORE_CPUS:?missing resource budget}"
    pids_limit: 512
    stop_grace_period: 30s
$TXBOARD_DB_DEPENDS_BLOCK
$DB_EXTRA_HOSTS_BLOCK
$DB_NETWORKS_BLOCK
    volumes:
      - ./data/storage:/www/storage
$PLUGIN_VOLUME_BLOCK
$NATIVE_VOLUME_BLOCK
      - ./api.env:/www/.env
      - api-redis:/data
      - caddy-data:/caddy-data
      - caddy-config:/caddy-config
    environment:
      RESOURCE_PROFILE: \${TXBOARD_RESOURCE_PROFILE:?missing resource profile}
      OCTANE_WORKERS: \${TXBOARD_OCTANE_WORKERS:?}
      OCTANE_TASK_WORKERS: 1
      HORIZON_DATA_PIPELINE_MAX: \${TXBOARD_HORIZON_PIPELINE:?}
      HORIZON_BUSINESS_MAX: \${TXBOARD_HORIZON_BUSINESS:?}
      HORIZON_NOTIFICATION_MAX: \${TXBOARD_HORIZON_NOTIFICATION:?}
      HORIZON_WORKER_MEMORY_MB: \${TXBOARD_WORKER_MEMORY_MIB:?}
      REDIS_MAXMEMORY_MIB: \${TXBOARD_REDIS_MEMORY_MIB:?}
      HORIZON_WORKER_MAX_TIME: 3600
      HORIZON_WORKER_MAX_JOBS: 1000
      docker: "true"
      ADMIN_ACCOUNT: \${TXBOARD_ADMIN_EMAIL:?missing TXBOARD_ADMIN_EMAIL}
      DB_CONNECTION: mysql
      DB_HOST: \${TXBOARD_DB_HOST:-database}
      DB_PORT: \${TXBOARD_DB_PORT:-3306}
      DB_DATABASE: \${TXBOARD_DB_DATABASE:-txboard}
      DB_USERNAME: \${TXBOARD_DB_USERNAME:-txboard}
      DB_PASSWORD: \${TXBOARD_DB_PASSWORD:?missing TXBOARD_DB_PASSWORD}
      REDIS_HOST: /data/redis.sock
      REDIS_PORT: 0
      REDIS_PASSWORD: "null"
      SUBSCRIBE_PATH: \${TXBOARD_SUBSCRIBE_PATH:-s}
      TXBOARD_SITE_ADDRESS: \${TXBOARD_SITE_ADDRESS:-:80}
      TXBOARD_TLS_DIRECTIVE: \${TXBOARD_TLS_DIRECTIVE:-}
      ENABLE_CADDY: "true"
      ENABLE_HORIZON: "true"
      ENABLE_REDIS: "true"
      ENABLE_WS_SERVER: "true"
    ports:
$PORTS_BLOCK
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -s /data/redis.sock ping | grep -q PONG && php /opt/txboard/healthcheck.php"]
      interval: 5s
      timeout: 5s
      retries: 24
      start_period: 10s

  backup:
    mem_limit: "\${TXBOARD_BACKUP_MEMORY_MIB:?missing backup memory}m"
    memswap_limit: "\${TXBOARD_BACKUP_MEMORY_MIB:?missing backup memory}m"
    cpus: "\${TXBOARD_BACKUP_CPUS:?missing backup cpu}"
    pids_limit: 64
    image: mysql:8.4.11
    restart: unless-stopped
    logging: *default-logging
$BACKUP_DB_DEPENDS_BLOCK
$DB_EXTRA_HOSTS_BLOCK
$DB_NETWORKS_BLOCK
    entrypoint: ["/bin/sh", "/usr/local/bin/txboard-backup.sh"]
    environment:
      DB_HOST: \${TXBOARD_DB_HOST:-database}
      DB_PORT: \${TXBOARD_DB_PORT:-3306}
      DB_DATABASE: \${TXBOARD_DB_DATABASE:-txboard}
      DB_USERNAME: \${TXBOARD_DB_USERNAME:-txboard}
      DB_PASSWORD: \${TXBOARD_DB_PASSWORD:?missing TXBOARD_DB_PASSWORD}
      BACKUP_NATIVE_MODE: "$NATIVE_BACKUP_MODE"
      BACKUP_DEPLOYMENT_DIR: /backup-deployment
      BACKUP_DIR: /backups
      BACKUP_SOURCE_DIR: /backup-source/api
      BACKUP_INTERVAL: \${TXBOARD_BACKUP_INTERVAL:-86400}
      BACKUP_RETENTION: \${TXBOARD_BACKUP_RETENTION:-7}
    volumes:
      - ./backup.sh:/usr/local/bin/txboard-backup.sh:ro
      - ./backups:/backups
$NATIVE_BACKUP_VOLUME_BLOCK
      - ./api.env:/backup-source/api/.env:ro
      - ./data/storage/app:/backup-source/api/storage/app:ro

volumes:
$DATABASE_VOLUME_BLOCK
  api-redis:
  caddy-data:
  caddy-config:
$DB_NETWORK_DECL_BLOCK
EOF

chmod 600 .env api.env
chmod 644 compose.yaml
docker compose config >/dev/null

if [[ "$RENDER_ONLY" -eq 1 ]]; then
  log "deployment files rendered and validated in $INSTALL_DIR"
  exit 0
fi

# Recovery commands must already exist if image acquisition or activation fails.
log "正在安装 TXBoard 管理与诊断命令……"
install_deploy_tools || die "management toolkit unavailable; installation stopped before image activation"

INSTALL_PROGRESS_TOTAL=5
[[ "$INSTALL_TYPE" == xboard-import ]] && INSTALL_PROGRESS_TOTAL=7
INSTALL_PROGRESS_DONE=0
pull_install_images() {
  if [[ "$IMAGE" != sha256:* ]]; then
    docker pull "$IMAGE" || { report_image_acquisition_failure; return 1; }
  fi
  docker image inspect "$IMAGE" >/dev/null || return
  local service
  while IFS= read -r service; do
    [[ "$service" == txboard ]] || docker compose pull "$service" || return
  done < <(docker compose config --services)
}
install_progress_step "拉取 TXBoard 与依赖镜像" pull_install_images ||
  die "unable to pull TXBoard images"

verify_database_connectivity
verify_database_empty_for_install

# The separate import path operates only on the just-verified empty target.
# Never bypass preflight and never run txboard:install against v2_* source data.
load_xboard_import_module() {
  local script_dir tmp
  script_dir="$INSTALLER_SOURCE_DIR"
  if [[ -n "$script_dir" && -f "$script_dir/lib/xboard-import.sh" ]]; then
    source "$script_dir/lib/xboard-import.sh"
    return
  fi
  tmp="$(mktemp "$INSTALL_DIR/.xboard-import.XXXXXXXX")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$DEPLOY_RAW_BASE/lib/xboard-import.sh" -o "$tmp" ||
      { rm -f "$tmp"; die "failed to download XBoard import module"; }
  else
    wget -qO "$tmp" "$DEPLOY_RAW_BASE/lib/xboard-import.sh" ||
      { rm -f "$tmp"; die "failed to download XBoard import module"; }
  fi
  bash -n "$tmp" || { rm -f "$tmp"; die "invalid XBoard import module"; }
  source "$tmp"
  rm -f "$tmp"
}
if [[ "$INSTALL_TYPE" == xboard-import ]]; then
  load_xboard_import_module
  install_progress_step "导入 XBoard 数据并校验用户与订单" txboard_import_xboard "$XBOARD_DUMP" "$XBOARD_ENV_FILE" ||
    die "XBoard import failed; see $INSTALL_LOG_FILE"
  install_progress_step "完成迁移后的 TXBoard 初始化" docker compose run -T --rm --no-deps --entrypoint php txboard /www/artisan txboard:install --no-interaction ||
    die "TXBoard imported installation finalization failed"
fi

if [[ -n "$NATIVE_CONFIG_DIR" ]]; then
  native_install() {
    local image_id
    image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')" || return 1
    python3 "$INSTALL_DIR/scripts/native-runtime.py" install --dir "$INSTALL_DIR" --image "$image_id" --progress
  }
  install_progress_step "准备、探测并激活原生运行时" native_install ||
    die "native deployment incomplete; preserve $INSTALL_DIR and private inputs. Inspect $INSTALL_LOG_FILE; run $INSTALL_DIR/txboard.sh core-diagnose and $INSTALL_DIR/txboard.sh native status, then resume with native recover"
else
# Start the real application container before installation, but do not wait for
# its health check yet. txboard:install relies on the normal container runtime.
install_progress_step "启动 TXBoard 应用容器" docker compose up -d --remove-orphans txboard ||
  die "failed to start TXBoard"

if [[ "$INSTALL_TYPE" == fresh && -z "$NATIVE_CONFIG_DIR" ]]; then
  # Fresh installs may emit a one-time password; keep that output visible.
  log "初始化管理员（请保存输出的一次性密码）..."
  docker compose exec -T txboard php artisan txboard:install </dev/null
fi

install_progress_step "重新加载 TXBoard 正式配置" docker compose restart txboard ||
  die "TXBoard restart failed"
install_progress_step "等待 TXBoard 服务健康检查" docker compose up -d --wait txboard ||
  die "TXBoard readiness check failed"

if ! docker compose exec -T txboard php artisan txboard:install-status --no-interaction </dev/null >/dev/null; then
  die "TXBoard installation state is incomplete. Inspect: cd $INSTALL_DIR && docker compose logs txboard"
fi
fi

install_progress_step "启动定时备份" docker compose up -d backup ||
  die "failed to start backup service"

cat <<EOF

TXBoard 安装成功。

安装日志：$INSTALL_LOG_FILE
Site:        $APP_URL
Admin entry: sudo txboard core-diagnose --show-admin-path
Install dir: $INSTALL_DIR
Image:       $IMAGE

$([[ -n "$NATIVE_CONFIG_DIR" ]] && printf '%s' 'Native runtime activated at epoch 2; administrator credentials come from your private preparation file.' || { [[ "$INSTALL_TYPE" == fresh ]] && printf '%s' 'Fresh install: save the administrator password printed above.' || printf '%s' 'Imported users and administrators keep their original accounts and password hashes.'; })
$([[ "$LEGACY_COMPAT" == true ]] && printf '%s' 'Historical compatibility installation: native browser administration APIs are unavailable; this is not a native activation.' || true)

Management:
  sudo txboard
  $INSTALL_DIR/txboard.sh

Quick commands:
  sudo txboard
  sudo txboard status
  sudo txboard update
  sudo txboard restart
  sudo txboard logs txboard
  sudo txboard backup
  sudo txboard config
  sudo txboard diagnose
  sudo txboard admin-reset-password
  sudo txboard repair-command
  sudo txboard refresh-manager
  sudo txboard help
EOF
