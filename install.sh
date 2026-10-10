#!/usr/bin/env bash
set -Eeuo pipefail

bootstrap_piped_installer() {
  # When Bash executes the installer directly from stdin (for example
  # curl ... | sudo bash), the script source and child-process stdin share the
  # same pipe. Slow network producers can expose races where Docker/Compose or
  # another child consumes bytes that Bash has not parsed yet. Re-run the
  # installer from a real file so runtime commands never share the source fd.
  [[ -z "${BASH_SOURCE[0]:-}" ]] || return 0

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

IMAGE_REPO="${TXBOARD_IMAGE_REPO:-ghcr.io/anrcm0/txboard}"
# Docker repository names must be lowercase, including operator-supplied overrides.
IMAGE_REPO="${IMAGE_REPO,,}"
IMAGE_TAG="${TXBOARD_IMAGE_TAG:-latest}"
INSTALL_DIR="${TXBOARD_INSTALL_DIR:-/opt/txboard}"
ADMIN_EMAIL="${TXBOARD_ADMIN_EMAIL:-}"
MODE="${TXBOARD_MODE:-}"
DOMAIN="${TXBOARD_DOMAIN:-}"
PUBLIC_HOST="${TXBOARD_PUBLIC_HOST:-}"
HTTP_PORT="${TXBOARD_HTTP_PORT:-}"
HTTPS_PORT="${TXBOARD_HTTPS_PORT:-}"
BACKUP_RETENTION="${TXBOARD_BACKUP_RETENTION:-7}"
TEST_MODE="${TXBOARD_TEST_MODE:-false}"
AUTO_INSTALL_DOCKER="${TXBOARD_AUTO_INSTALL_DOCKER:-false}"
MCP_ENABLED="${TXBOARD_ENABLE_MCP:-false}"
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
CLEAN_INSTALL_DIR="${TXBOARD_CLEAN_INSTALL_DIR:-false}"
COMPOSE_PROJECT_NAME="txboard"
LOCAL_DB_VOLUME="${COMPOSE_PROJECT_NAME}_database-data"

log() { printf '[TXBoard Deploy] %s\n' "$*"; }
warn() { printf '[TXBoard Deploy] WARNING: %s\n' "$*" >&2; }
die() { printf '[TXBoard Deploy] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
TXBoard Docker 交互式安装向导

Usage:
  install.sh [options]

Options:
  --dir PATH          Install directory (default: /opt/txboard)
  --tag TAG           TXBoard 镜像版本（latest / dev / 固定版本） (default: latest)
  --email EMAIL       Initial administrator email
  --mode MODE         auto-https | external-https | http
  --domain DOMAIN     Public domain for HTTPS modes
  --public-host HOST  Public host/IP for HTTP mode
  --http-port PORT    HTTP 端口
  --https-port PORT   HTTPS 端口 (auto-https only)
  --backup-retention N
                      Number of backup archives to retain (default: 7)
  --test-mode         Enable test deployment mode; permits wildcard public hosts
  --enable-mcp        Enable embedded MCP Gateway for AI Agents
  --disable-mcp       Disable embedded MCP Gateway (default)
  --db-mode MODE      local | host | external (default: local)
  --db-host HOST      External MySQL host
  --db-container NAME  Host MySQL/MariaDB Docker container (host mode)
  --db-socket PATH     System/local MySQL socket override (host mode)
  --db-port PORT      External MySQL port (default: 3306)
  --db-name NAME      Database name (default: txboard)
  --db-user USER      Database username (default: txboard)
  --db-password PASS  Database password (prefer environment variable)
  --yes               Non-interactive; use CLI/environment/default values
  --reset-local-db    Delete an existing managed MySQL volume before a fresh install
                      (DESTRUCTIVE: all data in that volume will be lost)
  --clean-install-dir  Remove existing files from the target install directory first
                      (Docker volumes are preserved; managed DB reset is separate)
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
  TXBOARD_HTTP_PORT
  TXBOARD_HTTPS_PORT
  TXBOARD_BACKUP_RETENTION
  TXBOARD_TEST_MODE
  TXBOARD_AUTO_INSTALL_DOCKER
  TXBOARD_ENABLE_MCP
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
  TXBOARD_CLEAN_INSTALL_DIR
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
    --http-port) HTTP_PORT="${2:?missing value for --http-port}"; shift 2 ;;
    --https-port) HTTPS_PORT="${2:?missing value for --https-port}"; shift 2 ;;
    --backup-retention) BACKUP_RETENTION="${2:?missing value for --backup-retention}"; shift 2 ;;
    --test-mode) TEST_MODE=true; shift ;;
    --enable-mcp) MCP_ENABLED=true; shift ;;
    --disable-mcp) MCP_ENABLED=false; shift ;;
    --db-mode) DB_MODE="${2:?missing value for --db-mode}"; shift 2 ;;
    --db-host) DB_HOST="${2:?missing value for --db-host}"; shift 2 ;;
    --db-container) DB_CONTAINER="${2:?missing value for --db-container}"; shift 2 ;;
    --db-socket) DB_SYSTEM_SOCKET="${2:?missing value for --db-socket}"; shift 2 ;;
    --db-port) DB_PORT="${2:?missing value for --db-port}"; shift 2 ;;
    --db-name) DB_DATABASE="${2:?missing value for --db-name}"; shift 2 ;;
    --db-user) DB_USERNAME="${2:?missing value for --db-user}"; shift 2 ;;
    --db-password) DB_PASSWORD="${2:?missing value for --db-password}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --reset-local-db) RESET_LOCAL_DB=1; shift ;;
    --clean-install-dir) CLEAN_INSTALL_DIR=true; shift ;;
    --render-only) RENDER_ONLY=1; ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

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
  local manager_tmp="$INSTALL_DIR/.txboard.sh.tmp"
  local updater_tmp="$INSTALL_DIR/.update.sh.tmp"
  local module tmp
  mkdir -p "$INSTALL_DIR/lib"

  download_file() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$dest" "$url"
    else
      return 1
    fi
  }

  if ! download_file "$DEPLOY_RAW_BASE/txboard.sh" "$manager_tmp" ||
     ! download_file "$DEPLOY_RAW_BASE/update.sh" "$updater_tmp"; then
    rm -f "$manager_tmp" "$updater_tmp"
    warn "failed to download TXBoard management tools"
    return 0
  fi

  for module in common service backup config diagnose uninstall detect; do
    tmp="$INSTALL_DIR/lib/.$module.sh.tmp"
    if ! download_file "$DEPLOY_RAW_BASE/lib/$module.sh" "$tmp"; then
      rm -f "$manager_tmp" "$updater_tmp" "$INSTALL_DIR/lib/."*.tmp
      warn "failed to download TXBoard manager module: $module"
      return 0
    fi
    mv "$tmp" "$INSTALL_DIR/lib/$module.sh"
  done

  mv "$manager_tmp" "$INSTALL_DIR/txboard.sh"
  mv "$updater_tmp" "$INSTALL_DIR/update.sh"
  chmod 755 "$INSTALL_DIR/txboard.sh" "$INSTALL_DIR/update.sh" "$INSTALL_DIR"/lib/*.sh

  if [[ "${EUID:-$(id -u)}" -eq 0 && -d /usr/local/bin ]]; then
    ln -sfn "$INSTALL_DIR/txboard.sh" /usr/local/bin/txboard
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

# Probe all Docker containers (including stopped ones) before ANY cleanup.
# Render-only does not mutate host Docker; it still protects deployment config.
if [[ "$RENDER_ONLY" -eq 0 ]]; then
  txboard_guard_install "$INSTALL_DIR" ||
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
    cat > /dev/tty <<'EOF'

请选择访问方式：
  1) 域名访问（Caddy 自动配置 HTTPS）
  2) 外部反向代理或 CDN 提供 HTTPS
  3) 纯 HTTP（不自动配置 HTTPS）

EOF
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

IMAGE_TAG="$(prompt "TXBoard 镜像版本（latest / dev / 固定版本）" "$IMAGE_TAG")"
[[ "$IMAGE_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "invalid image tag: $IMAGE_TAG"
IMAGE="$IMAGE_REPO:$IMAGE_TAG"

if [[ "$ASSUME_YES" -eq 1 && -z "$ADMIN_EMAIL" ]]; then
  die "--yes requires --email or TXBOARD_ADMIN_EMAIL"
fi
ADMIN_EMAIL="$(prompt "管理员邮箱" "${ADMIN_EMAIL:-admin@example.com}")"
valid_email "$ADMIN_EMAIL" || die "invalid administrator email: $ADMIN_EMAIL"

case "${TEST_MODE,,}" in
  1|true|yes|y|on) TEST_MODE=true ;;
  0|false|no|n|off|"") TEST_MODE=false ;;
  *) die "invalid TXBOARD_TEST_MODE value: $TEST_MODE (use true/false)" ;;
esac

case "${MCP_ENABLED,,}" in
  1|true|yes|y|on) MCP_ENABLED=true ;;
  0|false|no|n|off|"") MCP_ENABLED=false ;;
  *) die "invalid TXBOARD_ENABLE_MCP value: $MCP_ENABLED (use true/false)" ;;
esac

if [[ "$ASSUME_YES" -eq 0 ]]; then
  test_default="N"
  [[ "$TEST_MODE" == "true" ]] && test_default="Y"
  if confirm "启用测试模式？（允许使用通配地址）" "$test_default"; then
    TEST_MODE=true
  else
    TEST_MODE=false
  fi

  mcp_default="N"
  [[ "$MCP_ENABLED" == "true" ]] && mcp_default="Y"
  if confirm "启用 MCP 网关？" "$mcp_default"; then
    MCP_ENABLED=true
  else
    MCP_ENABLED=false
  fi
fi

configure_database

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
    if [[ "$HTTP_PORT" == "80" ]]; then
      APP_URL="http://$PUBLIC_HOST"
    else
      APP_URL="http://$PUBLIC_HOST:$HTTP_PORT"
    fi
    ;;
esac

BACKUP_RETENTION="$(prompt "保留备份份数（0 表示全部保留）" "$BACKUP_RETENTION")"
valid_nonnegative_int "$BACKUP_RETENTION" || die "backup retention must be a non-negative integer"

if [[ "$ASSUME_YES" -eq 0 ]]; then
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
MCP Gateway:    $MCP_ENABLED
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
  txboard_guard_install "$INSTALL_DIR" ||
    die "TXBoard appeared before installation; existing data is untouched"
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

mkdir -p data/storage/app data/plugins backups

cat > .env <<EOF
TXBOARD_IMAGE=$IMAGE
TXBOARD_ADMIN_EMAIL=$ADMIN_EMAIL
TXBOARD_TEST_MODE=$TEST_MODE
TXBOARD_ENABLE_MCP=$MCP_ENABLED
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

    contents="db.sql.gz env"
    for entry in storage-app.tar.gz storage-theme.tar.gz plugins.tar.gz; do
        [ ! -f "$dest/$entry" ] || contents="$contents $entry"
    done
    {
        echo "created_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "database=$DB_DATABASE"
        echo "db_host=$DB_HOST"
        echo "contents=$contents"
    } > "$dest/MANIFEST"

    (
        cd "$dest" || exit 1
        set -- db.sql.gz env
        for item in storage-app.tar.gz storage-theme.tar.gz plugins.tar.gz; do
            [ ! -f "$item" ] || set -- "$@" "$item"
        done
        sha256sum "$@" > CHECKSUMS.sha256
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
    stop_grace_period: 30s
$TXBOARD_DB_DEPENDS_BLOCK
$DB_EXTRA_HOSTS_BLOCK
$DB_NETWORKS_BLOCK
    volumes:
      - ./data/storage:/www/storage
      - ./data/plugins:/www/plugins
      - ./api.env:/www/.env
      - api-redis:/data
      - caddy-data:/caddy-data
      - caddy-config:/caddy-config
    environment:
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
      ENABLE_MCP: \${TXBOARD_ENABLE_MCP:-false}
      MCP_HOST: 127.0.0.1
      MCP_PORT: 3000
      MCP_ALLOWED_HOSTS: localhost,127.0.0.1
      MCP_ALLOWED_ORIGINS: ""
    ports:
$PORTS_BLOCK
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -s /data/redis.sock ping | grep -q PONG && php /opt/txboard/healthcheck.php"]
      interval: 5s
      timeout: 5s
      retries: 24
      start_period: 10s

  backup:
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
      BACKUP_DIR: /backups
      BACKUP_SOURCE_DIR: /backup-source/api
      BACKUP_INTERVAL: \${TXBOARD_BACKUP_INTERVAL:-86400}
      BACKUP_RETENTION: \${TXBOARD_BACKUP_RETENTION:-7}
    volumes:
      - ./backup.sh:/usr/local/bin/txboard-backup.sh:ro
      - ./backups:/backups
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

log "pulling TXBoard and infrastructure images..."
docker compose pull

if [[ "$MCP_ENABLED" == "true" ]]; then
  log "verifying TXBoard image includes the embedded MCP Gateway..."
  if ! docker compose run -T --rm --no-deps --entrypoint sh txboard -lc \
      'test -f /opt/txboard-mcp/dist/index.js' </dev/null >/dev/null; then
    die "selected TXBoard image does not include the embedded MCP Gateway; use a newer image tag or disable MCP"
  fi
fi

verify_database_connectivity
verify_database_empty_for_install

# Start the real application container before installation, but do not wait for
# its health check yet. txboard:install relies on the normal container runtime.
log "正在启动 TXBoard 初始化容器……"
docker compose up -d --remove-orphans txboard

log "正在初始化 TXBoard……"
docker compose exec -T txboard php artisan txboard:install </dev/null

log "正在重启 TXBoard 并加载正式配置……"
docker compose restart txboard >/dev/null
docker compose up -d --wait txboard >/dev/null

if ! docker compose exec -T txboard php artisan txboard:install-status --no-interaction </dev/null >/dev/null; then
  die "TXBoard installation state is incomplete. Inspect: cd $INSTALL_DIR && docker compose logs txboard"
fi

log "正在启动定时备份……"
docker compose up -d backup

log "正在安装 TXBoard 管理命令……"
install_deploy_tools

cat <<EOF

TXBoard 安装成功。

Panel:       $APP_URL/admin/
Install dir: $INSTALL_DIR
Image:       $IMAGE
MCP Gateway: $MCP_ENABLED
MCP URL:     $([[ "$MCP_ENABLED" == "true" ]] && printf '%s/mcp' "$APP_URL" || printf 'disabled')

The administrator password was printed by txboard:install above.
Store it now; the deploy script does not save that password.

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
  sudo txboard help
EOF
