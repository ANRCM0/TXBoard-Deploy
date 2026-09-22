#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE_REPO="${TXBOARD_IMAGE_REPO:-ghcr.io/paimoncai/txboard}"
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
DB_MODE="${TXBOARD_DB_MODE:-}"
DB_HOST="${TXBOARD_DB_HOST:-}"
DB_PORT="${TXBOARD_DB_PORT:-3306}"
DB_DATABASE="${TXBOARD_DB_DATABASE:-txboard}"
DB_USERNAME="${TXBOARD_DB_USERNAME:-txboard}"
DB_PASSWORD="${TXBOARD_DB_PASSWORD:-}"
DB_ROOT_PASSWORD="${TXBOARD_DB_ROOT_PASSWORD:-}"
DB_ADMIN_PASSWORD="${TXBOARD_DB_ADMIN_PASSWORD:-}"
DB_CONTAINER="${TXBOARD_DB_CONTAINER:-}"
DB_HOST_KIND=""
DB_LINK_NETWORK="${TXBOARD_DB_LINK_NETWORK:-txboard-db-link}"
DB_PROXY_REQUIRED=0
DB_PROXY_BIND=""
DB_PROXY_PORT="${TXBOARD_DB_PROXY_PORT:-13306}"
DB_SOURCE_PORT=""
DEPLOY_RAW_BASE="${TXBOARD_DEPLOY_RAW_BASE:-https://raw.githubusercontent.com/PaiMonCai/TXBoard-Deploy/main}"
ASSUME_YES=0
RENDER_ONLY=0
RESET_LOCAL_DB=0
COMPOSE_PROJECT_NAME="txboard"
LOCAL_DB_VOLUME="${COMPOSE_PROJECT_NAME}_database-data"

log() { printf '[TXBoard Deploy] %s\n' "$*"; }
warn() { printf '[TXBoard Deploy] WARNING: %s\n' "$*" >&2; }
die() { printf '[TXBoard Deploy] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
TXBoard interactive Docker installer

Usage:
  install.sh [options]

Options:
  --dir PATH          Install directory (default: /opt/txboard)
  --tag TAG           TXBoard image tag (default: latest)
  --email EMAIL       Initial administrator email
  --mode MODE         auto-https | external-https | http
  --domain DOMAIN     Public domain for HTTPS modes
  --public-host HOST  Public host/IP for HTTP mode
  --http-port PORT    Host HTTP port
  --https-port PORT   Host HTTPS port (auto-https only)
  --backup-retention N
                      Number of backup archives to retain (default: 7)
  --test-mode         Enable test deployment mode; permits wildcard public hosts
  --db-mode MODE      local | host | external (default: local)
  --db-host HOST      External MySQL host
  --db-container NAME  Host MySQL/MariaDB Docker container (host mode)
  --db-port PORT      External MySQL port (default: 3306)
  --db-name NAME      Database name (default: txboard)
  --db-user USER      Database username (default: txboard)
  --db-password PASS  Database password (prefer environment variable)
  --yes               Non-interactive; use CLI/environment/default values
  --reset-local-db    Delete an existing managed MySQL volume before a fresh install
                      (DESTRUCTIVE: all data in that volume will be lost)
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
  TXBOARD_DB_MODE
  TXBOARD_DB_HOST
  TXBOARD_DB_PORT
  TXBOARD_DB_DATABASE
  TXBOARD_DB_USERNAME
  TXBOARD_DB_PASSWORD
  TXBOARD_DB_ROOT_PASSWORD
  TXBOARD_DB_ADMIN_PASSWORD
  TXBOARD_DB_CONTAINER
  TXBOARD_DB_LINK_NETWORK
  TXBOARD_DB_PROXY_PORT
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
    --db-mode) DB_MODE="${2:?missing value for --db-mode}"; shift 2 ;;
    --db-host) DB_HOST="${2:?missing value for --db-host}"; shift 2 ;;
    --db-container) DB_CONTAINER="${2:?missing value for --db-container}"; shift 2 ;;
    --db-port) DB_PORT="${2:?missing value for --db-port}"; shift 2 ;;
    --db-name) DB_DATABASE="${2:?missing value for --db-name}"; shift 2 ;;
    --db-user) DB_USERNAME="${2:?missing value for --db-user}"; shift 2 ;;
    --db-password) DB_PASSWORD="${2:?missing value for --db-password}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --reset-local-db) RESET_LOCAL_DB=1; shift ;;
    --render-only) RENDER_ONLY=1; ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

command -v docker >/dev/null 2>&1 || die "Docker Engine is required."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."
if [[ "$RENDER_ONLY" -eq 0 ]]; then
  docker info >/dev/null 2>&1 || die "Docker daemon is not reachable."
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
  local tmp
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

load_install_database_module

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

  for module in common service backup config diagnose uninstall; do
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

if [[ -z "$MODE" ]]; then
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    MODE="http"
  else
    cat > /dev/tty <<'EOF'

Choose public access mode:
  1) Domain + Caddy automatic HTTPS
  2) HTTPS terminated by an external reverse proxy / CDN
  3) Plain HTTP

EOF
    mode_choice="$(choose "Mode" "1" "3")"
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

IMAGE_TAG="$(prompt "TXBoard image tag" "$IMAGE_TAG")"
[[ "$IMAGE_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "invalid image tag: $IMAGE_TAG"
IMAGE="$IMAGE_REPO:$IMAGE_TAG"

if [[ "$ASSUME_YES" -eq 1 && -z "$ADMIN_EMAIL" ]]; then
  die "--yes requires --email or TXBOARD_ADMIN_EMAIL"
fi
ADMIN_EMAIL="$(prompt "Administrator email" "${ADMIN_EMAIL:-admin@example.com}")"
valid_email "$ADMIN_EMAIL" || die "invalid administrator email: $ADMIN_EMAIL"

INSTALL_DIR="$(prompt "Installation directory" "$INSTALL_DIR")"
[[ -n "$INSTALL_DIR" && "$INSTALL_DIR" == /* ]] || die "installation directory must be an absolute path"

case "${TEST_MODE,,}" in
  1|true|yes|y|on) TEST_MODE=true ;;
  0|false|no|n|off|"") TEST_MODE=false ;;
  *) die "invalid TXBOARD_TEST_MODE value: $TEST_MODE (use true/false)" ;;
esac

if [[ "$ASSUME_YES" -eq 0 ]]; then
  test_default="N"
  [[ "$TEST_MODE" == "true" ]] && test_default="Y"
  if confirm "Enable test deployment mode? (allows 0.0.0.0/:: as Public host)" "$test_default"; then
    TEST_MODE=true
  else
    TEST_MODE=false
  fi
fi

if [[ "${EUID:-$(id -u)}" -ne 0 && "$INSTALL_DIR" == /opt/* ]]; then
  die "installation under /opt requires root. Re-run with sudo or choose another --dir."
fi

if [[ -e "$INSTALL_DIR/compose.yaml" || -e "$INSTALL_DIR/.env" || -e "$INSTALL_DIR/api.env" ]]; then
  die "an existing TXBoard deployment was found in $INSTALL_DIR. Use update.sh instead of reinstalling."
fi

if [[ -z "$DB_MODE" ]]; then
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    DB_MODE="local"
  else
    cat > /dev/tty <<'EOF'

Choose database mode:
  1) Managed MySQL 8.4 container
  2) External MySQL server

EOF
    db_choice="$(choose "Database" "1" "2")"
    case "$db_choice" in
      1) DB_MODE="local" ;;
      2) DB_MODE="external" ;;
    esac
  fi
fi

case "$DB_MODE" in
  local)
    DB_HOST="database"
    DB_PORT="3306"
    [[ "$DB_DATABASE" =~ ^[A-Za-z0-9_]+$ ]] || die "invalid database name: $DB_DATABASE"
    [[ -n "$DB_USERNAME" && ! "$DB_USERNAME" =~ [[:space:]] ]] || die "invalid database username"

    # MYSQL_USER/MYSQL_PASSWORD/MYSQL_ROOT_PASSWORD only initialize an empty
    # /var/lib/mysql. Reusing a stale Compose volume with freshly generated
    # credentials leaves the old MySQL users unchanged and makes TXBoard fail
    # with SQLSTATE[HY000] [1045]. Detect that state before generating secrets.
    if [[ "$RENDER_ONLY" -eq 0 ]] && docker volume inspect "$LOCAL_DB_VOLUME" >/dev/null 2>&1; then
      if [[ "$RESET_LOCAL_DB" -eq 1 ]]; then
        warn "deleting existing managed MySQL volume: $LOCAL_DB_VOLUME"
        docker volume rm "$LOCAL_DB_VOLUME" >/dev/null ||
          die "cannot remove $LOCAL_DB_VOLUME; it may still be attached to another TXBoard container"
      elif [[ "$ASSUME_YES" -eq 1 ]]; then
        die "existing managed MySQL volume $LOCAL_DB_VOLUME detected. Refusing to generate new credentials for an initialized database. Preserve it by recovering the original deployment/credentials, or rerun a disposable fresh install with --reset-local-db."
      else
        cat > /dev/tty <<EOF

Existing TXBoard managed MySQL volume detected:

  $LOCAL_DB_VOLUME

MySQL initialization passwords are only applied to an empty data directory.
Continuing with newly generated passwords would make the application fail
authentication and can hide an existing database from the new deployment.

EOF
        if confirm "Delete this database volume and continue with a completely fresh install? ALL DATABASE DATA WILL BE LOST." "N"; then
          warn "deleting existing managed MySQL volume: $LOCAL_DB_VOLUME"
          docker volume rm "$LOCAL_DB_VOLUME" >/dev/null ||
            die "cannot remove $LOCAL_DB_VOLUME; it may still be attached to another TXBoard container"
        else
          die "installation stopped to preserve the existing database volume"
        fi
      fi
    fi

    DB_PASSWORD="${DB_PASSWORD:-$(random_hex)}"
    DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-$(random_hex)}"
    ;;
  external)
    DB_HOST="$(prompt "External MySQL host" "$DB_HOST")"
    DB_PORT="$(prompt "External MySQL port" "${DB_PORT:-3306}")"
    DB_DATABASE="$(prompt "Database name" "${DB_DATABASE:-txboard}")"
    DB_USERNAME="$(prompt "Database username" "$DB_USERNAME")"
    if [[ "$ASSUME_YES" -eq 1 && -z "$DB_PASSWORD" ]]; then
      die "external database mode requires TXBOARD_DB_PASSWORD or --db-password"
    fi
    DB_PASSWORD="$(prompt_secret "Database password" "$DB_PASSWORD")"
    [[ -n "$DB_HOST" && ! "$DB_HOST" =~ [[:space:]] ]] || die "invalid external database host"
    valid_port "$DB_PORT" || die "invalid external database port: $DB_PORT"
    [[ "$DB_DATABASE" =~ ^[A-Za-z0-9_]+$ ]] || die "invalid database name: $DB_DATABASE"
    [[ -n "$DB_USERNAME" && ! "$DB_USERNAME" =~ [[:space:]] ]] || die "invalid database username"
    [[ -n "$DB_PASSWORD" ]] || die "database password cannot be empty"

    if [[ "$DB_HOST" == "127.0.0.1" || "$DB_HOST" == "localhost" ]]; then
      if [[ "$ASSUME_YES" -eq 1 ]]; then
        die "external database host '$DB_HOST' resolves inside the TXBoard container, not to the Docker host. Use host.docker.internal for MySQL running on this server."
      fi
      warn "external DB host $DB_HOST resolves inside the TXBoard container, not to the Docker host"
      if confirm "Use host.docker.internal for MySQL running on this server?" "Y"; then
        DB_HOST="host.docker.internal"
      else
        die "external database host must be reachable from the TXBoard container; 127.0.0.1/localhost cannot be used here"
      fi
    fi

    DB_ROOT_PASSWORD=""
    ;;
  *) die "invalid database mode: $DB_MODE" ;;
esac

DB_PASSWORD_ENV="$(dotenv_quote "$DB_PASSWORD")"

APP_URL=""
SITE_ADDRESS=":80"
HTTP_BIND="0.0.0.0"
HTTPS_BIND="0.0.0.0"
SESSION_SECURE_COOKIE=false
PUBLISH_HTTPS=0

case "$MODE" in
  auto-https)
    DOMAIN="$(prompt "Panel domain" "$DOMAIN")"
    valid_domain "$DOMAIN" || die "invalid domain: $DOMAIN"
    HTTP_PORT="$(prompt "Host HTTP port" "${HTTP_PORT:-80}")"
    HTTPS_PORT="$(prompt "Host HTTPS port" "${HTTPS_PORT:-443}")"
    valid_port "$HTTP_PORT" || die "invalid HTTP port: $HTTP_PORT"
    valid_port "$HTTPS_PORT" || die "invalid HTTPS port: $HTTPS_PORT"
    SITE_ADDRESS="$DOMAIN"
    APP_URL="https://$DOMAIN"
    SESSION_SECURE_COOKIE=true
    PUBLISH_HTTPS=1
    ;;
  external-https)
    DOMAIN="$(prompt "Public panel domain" "$DOMAIN")"
    valid_domain "$DOMAIN" || die "invalid domain: $DOMAIN"
    HTTP_BIND="127.0.0.1"
    HTTP_PORT="$(prompt "Local HTTP port for reverse proxy" "${HTTP_PORT:-8080}")"
    valid_port "$HTTP_PORT" || die "invalid HTTP port: $HTTP_PORT"
    APP_URL="https://$DOMAIN"
    SESSION_SECURE_COOKIE=true
    ;;
  http)
    PUBLIC_HOST="$(prompt "Public host / IP" "${PUBLIC_HOST:-$(detect_host)}")"
    [[ -n "$PUBLIC_HOST" && ! "$PUBLIC_HOST" =~ [[:space:]] ]] || die "invalid public host"
    if [[ "$PUBLIC_HOST" == "0.0.0.0" || "$PUBLIC_HOST" == "::" ]]; then
      if [[ "$TEST_MODE" == "true" ]]; then
        warn "test deployment mode: accepting wildcard Public host $PUBLIC_HOST; APP_URL is intended for testing only"
      else
        die "public host cannot be $PUBLIC_HOST in standard deployment mode. Use the server IP/hostname, or explicitly enable test deployment mode with --test-mode."
      fi
    fi
    HTTP_PORT="$(prompt "Host HTTP port" "${HTTP_PORT:-80}")"
    valid_port "$HTTP_PORT" || die "invalid HTTP port: $HTTP_PORT"
    if [[ "$HTTP_PORT" == "80" ]]; then
      APP_URL="http://$PUBLIC_HOST"
    else
      APP_URL="http://$PUBLIC_HOST:$HTTP_PORT"
    fi
    ;;
esac

BACKUP_RETENTION="$(prompt "Backup archives to retain (0 = keep all)" "$BACKUP_RETENTION")"
valid_nonnegative_int "$BACKUP_RETENTION" || die "backup retention must be a non-negative integer"

if [[ "$ASSUME_YES" -eq 0 ]]; then
  cat > /dev/tty <<EOF

------------------------------------------------------------
TXBoard deployment summary

Image:          $IMAGE
Mode:           $MODE
Public URL:     $APP_URL
Admin email:    $ADMIN_EMAIL
Install dir:    $INSTALL_DIR
Test mode:      $TEST_MODE
HTTP mapping:   $HTTP_BIND:$HTTP_PORT -> container:80
Backup retain:  $BACKUP_RETENTION
Database mode:   $DB_MODE
Database:        $DB_HOST:$DB_PORT/$DB_DATABASE
EOF
  if [[ "$PUBLISH_HTTPS" -eq 1 ]]; then
    printf 'HTTPS mapping:  %s:%s -> container:443\n' "$HTTPS_BIND" "$HTTPS_PORT" > /dev/tty
  fi
  cat > /dev/tty <<'EOF'
------------------------------------------------------------

EOF
  confirm "Continue installation?" "Y" || { log "cancelled"; exit 0; }
fi

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
umask 077

mkdir -p data/storage/app data/plugins backups

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
set -eu

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
  case "$BACKUP_RETENTION" in ''|*[!0-9]*) return 0 ;; esac
  [ "$BACKUP_RETENTION" -gt 0 ] || return 0
  total=$(ls -1 "$BACKUP_DIR" 2>/dev/null | grep -cE '^[0-9]{8}T[0-9]{6}Z$' || true)
  [ "$total" -gt "$BACKUP_RETENTION" ] || return 0
  remove=$((total - BACKUP_RETENTION))
  ls -1 "$BACKUP_DIR" | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort | head -n "$remove" |
    while read -r old; do
      [ -n "$old" ] && rm -rf "$BACKUP_DIR/$old"
    done
}

run_backup() {
  stamp=$(date -u '+%Y%m%dT%H%M%SZ')
  dest="$BACKUP_DIR/$stamp"
  mkdir -p "$dest"

  log "dumping database -> $dest/db.sql.gz"
  if ! MYSQL_PWD="$DB_PASSWORD" mysqldump \
      --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USERNAME" \
      --single-transaction --quick --routines --events --triggers \
      --set-gtid-purged=OFF --default-character-set=utf8mb4 \
      "$DB_DATABASE" 2>/dev/null | gzip -9 > "$dest/db.sql.gz"; then
    rm -rf "$dest"
    return 1
  fi

  if [ ! -s "$dest/db.sql.gz" ] || ! gzip -t "$dest/db.sql.gz" 2>/dev/null; then
    rm -rf "$dest"
    return 1
  fi

  if [ -f "$BACKUP_SOURCE_DIR/.env" ]; then
    cp "$BACKUP_SOURCE_DIR/.env" "$dest/env"
    chmod 600 "$dest/env"
  fi

  if [ -d "$BACKUP_SOURCE_DIR/storage/app" ]; then
    tar -czf "$dest/storage-app.tar.gz" -C "$BACKUP_SOURCE_DIR/storage/app" . 2>/dev/null || true
  fi

  {
    echo "created_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "database=$DB_DATABASE"
    echo "db_host=$DB_HOST"
  } > "$dest/MANIFEST"

  prune
  log "backup complete: $dest"
}

if [ "$BACKUP_INTERVAL" -gt 0 ] 2>/dev/null; then
  while true; do
    run_backup || log "backup failed; retrying next interval"
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
TXBOARD_DB_DEPENDS_BLOCK=""
BACKUP_DB_DEPENDS_BLOCK=""
DATABASE_VOLUME_BLOCK=""
DB_EXTRA_HOSTS_BLOCK=""

if [[ "$DB_MODE" == "local" ]]; then
  DATABASE_SERVICE_BLOCK="$(cat <<'YAML'
  database:
    image: mysql:8.4.11
    restart: unless-stopped
    logging: *default-logging
    environment:
      MYSQL_DATABASE: ${TXBOARD_DB_DATABASE:-txboard}
      MYSQL_USER: ${TXBOARD_DB_USERNAME:-txboard}
      MYSQL_PASSWORD: ${TXBOARD_DB_PASSWORD:?missing TXBOARD_DB_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${TXBOARD_DB_ROOT_PASSWORD:?missing TXBOARD_DB_ROOT_PASSWORD}
    volumes:
      - database-data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "--host=127.0.0.1", "--user=root", "--password=${TXBOARD_DB_ROOT_PASSWORD:?}"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 40s
YAML
)"
  TXBOARD_DB_DEPENDS_BLOCK="$(cat <<'YAML'
    depends_on:
      database:
        condition: service_healthy
YAML
)"
  BACKUP_DB_DEPENDS_BLOCK="$TXBOARD_DB_DEPENDS_BLOCK"
  DATABASE_VOLUME_BLOCK="  database-data:"
else
  DB_EXTRA_HOSTS_BLOCK="$(cat <<'YAML'
    extra_hosts:
      - "host.docker.internal:host-gateway"
YAML
)"
fi

cat > compose.yaml <<EOF
name: $COMPOSE_PROJECT_NAME

x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

services:
$DATABASE_SERVICE_BLOCK
  txboard:
    image: \${TXBOARD_IMAGE:?missing TXBOARD_IMAGE}
    restart: unless-stopped
    logging: *default-logging
    stop_grace_period: 30s
$TXBOARD_DB_DEPENDS_BLOCK
$DB_EXTRA_HOSTS_BLOCK
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

if [[ "$DB_MODE" == "local" ]]; then
  log "starting managed database..."
  docker compose up -d --remove-orphans --wait database

  log "verifying managed database credentials..."
  if ! docker compose exec -T database sh -lc \
      'MYSQL_PWD="$MYSQL_PASSWORD" mysql --protocol=TCP --host=127.0.0.1 --port=3306 --user="$MYSQL_USER" --database="$MYSQL_DATABASE" --execute="SELECT 1" >/dev/null' </dev/null; then
    die "managed MySQL rejected the configured TXBoard credentials. The database volume may have been initialized with older passwords. Preserve existing data and recover its original credentials, or remove the stale deployment and rerun a disposable fresh install with --reset-local-db."
  fi
else
  log "checking external database connectivity..."
  if ! docker compose run -T --rm --no-deps --entrypoint sh backup -lc \
      'MYSQL_PWD="$DB_PASSWORD" mysql --connect-timeout=5 --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USERNAME" --database="$DB_DATABASE" --execute="SELECT 1" >/dev/null' </dev/null; then
    die "cannot connect to external MySQL at $DB_HOST:$DB_PORT/$DB_DATABASE from the TXBoard container. If MySQL runs on this Docker host, use host.docker.internal and make sure MySQL/its container publishes or listens on a host-reachable address (not only 127.0.0.1). Also check firewall and user host permissions."
  fi
fi

# Start the real application container before installation, but do not wait for
# its health check yet. txboard:install relies on the normal container runtime.
log "starting TXBoard bootstrap container..."
docker compose up -d --remove-orphans txboard

log "initializing TXBoard..."
docker compose exec -T txboard php artisan txboard:install </dev/null

log "restarting TXBoard with the completed runtime configuration..."
docker compose restart txboard >/dev/null
docker compose up -d --wait txboard >/dev/null

if ! docker compose exec -T txboard php artisan txboard:install-status --no-interaction </dev/null >/dev/null; then
  die "TXBoard installation state is incomplete. Inspect: cd $INSTALL_DIR && docker compose logs txboard"
fi

log "starting periodic backups..."
docker compose up -d backup

log "installing TXBoard management command..."
install_deploy_tools

cat <<EOF

TXBoard installation completed.

Panel:       $APP_URL/admin/
Install dir: $INSTALL_DIR
Image:       $IMAGE

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
