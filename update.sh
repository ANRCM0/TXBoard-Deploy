#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${TXBOARD_INSTALL_DIR:-/opt/txboard}"
IMAGE_TAG=""
SKIP_BACKUP=0
ASSUME_YES=0
DEPLOY_RAW_BASE="${TXBOARD_DEPLOY_RAW_BASE:-https://raw.githubusercontent.com/ANRCM0/TXBoard-Deploy/main}"

log() { printf '[TXBoard Deploy] %s\n' "$*"; }
warn() { printf '[TXBoard Deploy] WARNING: %s\n' "$*" >&2; }
die() { printf '[TXBoard Deploy] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
TXBoard image updater

Usage:
  update.sh [options]

Options:
  --dir PATH       Install directory (default: /opt/txboard)
  --tag TAG        Switch ghcr.io/anrcm0/txboard to a different tag
  --skip-backup    Not permitted during schema-safe updates
  --yes            Do not ask for confirmation
  -h, --help       Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) INSTALL_DIR="${2:?missing value for --dir}"; shift 2 ;;
    --tag) IMAGE_TAG="${2:?missing value for --tag}"; shift 2 ;;
    --skip-backup) SKIP_BACKUP=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

command -v docker >/dev/null 2>&1 || die "Docker Engine is required."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."
docker info >/dev/null 2>&1 || die "Docker daemon is not reachable."

[[ -f "$INSTALL_DIR/compose.yaml" && -f "$INSTALL_DIR/.env" && -f "$INSTALL_DIR/api.env" ]] ||
  die "no TXBoard deployment found in $INSTALL_DIR"

cd "$INSTALL_DIR"

get_env() {
  grep -E "^$1=" .env | tail -1 | cut -d= -f2- || true
}

refresh_tools() {
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
    warn "could not refresh TXBoard management tools"
    return 0
  fi

  for module in common service backup config diagnose uninstall; do
    tmp="$INSTALL_DIR/lib/.$module.sh.tmp"
    if ! download_file "$DEPLOY_RAW_BASE/lib/$module.sh" "$tmp"; then
      rm -f "$manager_tmp" "$updater_tmp" "$INSTALL_DIR/lib/."*.tmp
      warn "could not refresh manager module: $module"
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
  log "management command refreshed"
}

set_image() {
  local value="$1" tmp
  tmp="$(mktemp)"
  awk -v value="$value" '
    BEGIN { done=0 }
    /^TXBOARD_IMAGE=/ { print "TXBOARD_IMAGE=" value; done=1; next }
    { print }
    END { if (!done) print "TXBOARD_IMAGE=" value }
  ' .env > "$tmp"
  chmod --reference=.env "$tmp" 2>/dev/null || chmod 600 "$tmp"
  mv "$tmp" .env
}

current_image="$(get_env TXBOARD_IMAGE)"
[[ -n "$current_image" ]] || die "TXBOARD_IMAGE is missing from $INSTALL_DIR/.env"

# Accept existing deployments whose saved image repository contains uppercase
# owner letters. Preserve the tag (Docker tags may contain uppercase letters).
image_repo="${current_image%:*}"
image_repo="${image_repo,,}"
normalized_current_image="$image_repo:${current_image##*:}"

if [[ -n "$IMAGE_TAG" ]]; then
  [[ "$IMAGE_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "invalid image tag: $IMAGE_TAG"
  new_image="$image_repo:$IMAGE_TAG"
else
  new_image="$normalized_current_image"
fi


# Only existing and COMPLETE legacy v2_* installations are auto-migrated.
# Native tx_* table cutover is NOT a routine Docker image upgrade.
[[ "$SKIP_BACKUP" -eq 0 ]] || die "--skip-backup is disabled: a full backup is required"
umask 077
command -v flock >/dev/null 2>&1 || die "flock is required for upgrade locking"
exec 9>"$INSTALL_DIR/.upgrade.lock"
flock -n 9 || die "another TXBoard upgrade is running"

# The existing backup service supplies a MySQL client on the exact same network.
# No application credentials or row data are printed.
db_sql() {
  docker compose run -T --rm --no-deps --entrypoint sh backup -ec \
    'MYSQL_PWD="$DB_PASSWORD" exec mysql --batch --skip-column-names --connect-timeout=10 --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USERNAME" --database="$DB_DATABASE" --execute="$1"' sh "$1"
}
schema_preflight() {
  local inventory v2 tx u settings orders history mode
  inventory="$(db_sql "SELECT SUM(LEFT(TABLE_NAME,3)='v2_'), SUM(LEFT(TABLE_NAME,3)='tx_'), SUM(TABLE_NAME='v2_user'), SUM(TABLE_NAME='v2_settings'), SUM(TABLE_NAME='v2_order'), SUM(TABLE_NAME='migrations') FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_TYPE='BASE TABLE'")" ||
    die "failed to inventory MySQL tables"
  read -r v2 tx u settings orders history <<< "$inventory"
  [[ "$v2" =~ ^[0-9]+$ && "$tx" =~ ^[0-9]+$ ]] || die "unknown or empty DB schema"
  (( tx == 0 )) || die "native/mixed tx_* schema detected; manual cutover runbook required"
  (( v2 > 0 && u == 1 && settings == 1 && orders == 1 && history == 1 )) ||
    die "unsupported V2 schema: core tables or migration history missing"
  mode="$(sed -n 's/^TX_NATIVE_TABLES=//p' api.env | tail -1 | tr -d "'\" ")"
  case "$mode" in ''|false|FALSE|0) ;; *) die "TX_NATIVE_TABLES is not false; automatic legacy upgrade denied" ;; esac
  log "legacy database preflight passed ($v2 v2_* tables; no tx_* tables)"
}
critical_snapshot() {
  db_sql "SELECT (SELECT COUNT(*) FROM v2_user), (SELECT COALESCE(SUM(balance),0) FROM v2_user), (SELECT COALESCE(SUM(commission_balance),0) FROM v2_user), (SELECT COUNT(*) FROM v2_order), (SELECT COALESCE(SUM(total_amount),0) FROM v2_order)"
}
target_artisan() {
  docker compose run -T --rm --no-deps \
    -e CACHE_DRIVER=array -e SETTING_CACHE_STORE=array -e QUEUE_CONNECTION=sync -e SESSION_DRIVER=array \
    --entrypoint php txboard /www/artisan "$@" --no-interaction
}

container_id="$(docker compose ps -q txboard 2>/dev/null || true)"
[[ -n "$container_id" ]] || die "TXBoard must be running before database-aware update"
old_image_id="$(docker inspect "$container_id" --format '{{.Image}}' 2>/dev/null || true)"
[[ "$old_image_id" == sha256:* ]] || die "could not pin old running image"
schema_preflight
if [[ "$ASSUME_YES" -eq 0 ]]; then
  [[ -r /dev/tty ]] || die "confirmation requires TTY (or --yes)"
  printf 'Old: %s\nNew: %s\nLegacy DB: backup, downtime and migrations required. Continue? [Y/n]: ' "$current_image" "$new_image" > /dev/tty
  IFS= read -r answer < /dev/tty || true
  [[ -n "$answer" ]] || answer=Y
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] || { log cancelled; exit 0; }
fi

log "pulling target image BEFORE stopping writers..."
docker pull "$new_image" || die "pull failed; current deployment unchanged"
phase=before_stop
attempted_migrate=0
backup_path=""
restore_image_without_db_change() {
  warn "restarting the old image; no schema migration has been attempted"
  set_image "$normalized_current_image"
  docker image inspect "$old_image_id" >/dev/null 2>&1 || return 1
  docker tag "$old_image_id" "$normalized_current_image" || return 1
  docker compose up -d --no-deps --force-recreate --wait txboard &&
    docker compose exec -T txboard php artisan txboard:install-status --no-interaction </dev/null
}
upgrade_on_exit() {
  local code="$1"
  trap - EXIT
  if (( code == 0 )); then return 0; fi
  if [[ "$phase" == before_stop || "$phase" == complete ]]; then return "$code"; fi
  if (( attempted_migrate == 0 )); then
    restore_image_without_db_change || warn "old container restart failed; manual recovery required"
  else
    warn "Schema migration may have modified the database. NEVER boot an old image against it."
    warn "TXBoard remains stopped; inspect the database and restore a verified compatible backup before downgrading."
    warn "Backup archive: $backup_path"
  fi
  return "$code"
}
trap 'upgrade_on_exit $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log "stopping TXBoard, embedded queue workers, WebSocket and scheduled writers..."
docker compose stop txboard || die "could not stop TXBoard"
phase=frozen
schema_preflight
before="$(critical_snapshot)" || die "critical snapshot query failed"
[[ -n "$before" ]] || die "empty critical snapshot"

# A separate one-shot dump with retention disabled, not the rolling backup.
old_backup="$(find "$INSTALL_DIR/backups" -mindepth 1 -maxdepth 1 -type d -name '????????T??????Z' -printf '%f\n' 2>/dev/null | sort | tail -1 || true)"
log "creating mandatory full backup (database, APP_KEY, persistent files)"
docker compose run -T --rm -e BACKUP_INTERVAL=0 -e BACKUP_RETENTION=0 backup </dev/null ||
  die "pre-migration backup failed"
new_backup="$(find "$INSTALL_DIR/backups" -mindepth 1 -maxdepth 1 -type d -name '????????T??????Z' -printf '%f\n' 2>/dev/null | sort | tail -1 || true)"
[[ -n "$new_backup" && "$new_backup" != "$old_backup" ]] || die "backup did not create a new archive"
backup_path="$INSTALL_DIR/backups/$new_backup"
(cd "$backup_path" && test -s env && test -s db.sql.gz && test -s MANIFEST && test -s CHECKSUMS.sha256 && sha256sum -c CHECKSUMS.sha256 && gzip -t db.sql.gz) ||
  die "backup archive checksum or gzip validation failed"
log "backup archive verified: $backup_path (separate restoration rehearsal is still needed)"

set_image "$new_image"
phase=migrate
attempted_migrate=1
log "running normal Laravel schema migrations using the TARGET image..."
target_artisan migrate --force || die "Laravel migrations failed; manual database recovery required"
migration_status="$(target_artisan migrate:status)" || die "cannot inspect migration status"
if grep -Eiq '(^|[[:space:]])Pending([[:space:]]|$)' <<< "$migration_status"; then
  die "migrations remain pending"
fi
after="$(critical_snapshot)" || die "post-migration snapshot failed"
[[ "$after" == "$before" ]] || die "critical user/order/balance aggregates changed during schema upgrade"
phase=post_migrate
log "schema and financial invariants checked; recreating TXBoard..."
docker compose up -d --no-deps --force-recreate --wait txboard ||
  die "new image health check failed after migration"
docker compose exec -T txboard php artisan txboard:install-status --no-interaction </dev/null ||
  die "new image install-state check failed"
phase=complete
log "upgrade passed: $new_image; retained v2_* schema; archive=$backup_path"
refresh_tools
docker compose ps txboard
