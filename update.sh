#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${TXBOARD_INSTALL_DIR:-/opt/txboard}"
IMAGE_TAG=""
SKIP_BACKUP=0
ASSUME_YES=0
CUTOVER_PLAN=""
SCHEMA_KIND=""
UPGRADE_MODE=""
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
  --yes            Unattended: keep legacy v2_* names; native tx_* upgrades automatically
  --cutover-plan PATH  Host path to an independently reviewed/approved rename plan
  -h, --help       Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) INSTALL_DIR="${2:?missing value for --dir}"; shift 2 ;;
    --tag) IMAGE_TAG="${2:?missing value for --tag}"; shift 2 ;;
    --skip-backup) SKIP_BACKUP=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --cutover-plan) CUTOVER_PLAN="${2:?missing value for --cutover-plan}"; shift 2 ;;
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

  for module in common service backup config diagnose uninstall detect; do
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
      { rm -f "$tmp"; die "cannot obtain TXBoard service discovery module"; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$DEPLOY_RAW_BASE/lib/detect.sh" ||
      { rm -f "$tmp"; die "cannot obtain TXBoard service discovery module"; }
  else
    rm -f "$tmp"
    die "curl or wget required for safe service discovery"
  fi
  bash -n "$tmp" || { rm -f "$tmp"; die "invalid Docker service discovery module"; }
  # shellcheck source=/dev/null
  source "$tmp"
  rm -f "$tmp"
}
load_service_detect_module

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
    'MYSQL_PWD="$DB_PASSWORD" exec mysql --batch --skip-column-names --connect-timeout=10 --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USERNAME" --database="$DB_DATABASE" --execute="$1"' sh "$1" </dev/null
}
# Read database shape before any mutation. Mixed/empty/unknown databases never
# enter the automatic update path.
detect_schema() {
  local inventory v2 tx v2user v2settings v2order txuser txsettings txorder history flag
  inventory="$(db_sql "SELECT
    SUM(LEFT(TABLE_NAME,3)='v2_'), SUM(LEFT(TABLE_NAME,3)='tx_'),
    SUM(TABLE_NAME='v2_user'), SUM(TABLE_NAME='v2_settings'), SUM(TABLE_NAME='v2_order'),
    SUM(TABLE_NAME='tx_user'), SUM(TABLE_NAME='tx_settings'), SUM(TABLE_NAME='tx_order'),
    SUM(TABLE_NAME='migrations')
    FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_TYPE='BASE TABLE'")" ||
    die "failed to inventory live MySQL schema"
  read -r v2 tx v2user v2settings v2order txuser txsettings txorder history <<< "$inventory"
  [[ "$v2" =~ ^[0-9]+$ && "$tx" =~ ^[0-9]+$ && "$history" == 1 ]] ||
    die "empty/unknown database or missing Laravel migration history"
  if (( v2 > 0 && tx == 0 && v2user == 1 && v2settings == 1 && v2order == 1 )); then
    SCHEMA_KIND=legacy
  elif (( tx > 0 && v2 == 0 && txuser == 1 && txsettings == 1 && txorder == 1 )); then
    SCHEMA_KIND=native
  else
    die "mixed/incomplete database detected (v2=$v2, tx=$tx): refusing automatic upgrade"
  fi
  flag="$(sed -n 's/^TX_NATIVE_TABLES=//p' api.env | tail -1 | tr -d "'\" ")"
  case "$SCHEMA_KIND:$flag" in
    legacy:''|legacy:false|legacy:FALSE|legacy:0) ;;
    native:true|native:TRUE|native:1) ;;
    *) die "schema is $SCHEMA_KIND but TX_NATIVE_TABLES in api.env is '$flag': resolve config before upgrade" ;;
  esac
  log "detected $SCHEMA_KIND database (v2=$v2, tx=$tx); configuration matches"
}
require_schema() {
  local want="$1"
  detect_schema
  [[ "$SCHEMA_KIND" == "$want" ]] ||
    die "schema changed unexpectedly: expected $want, found $SCHEMA_KIND"
}
# A consistent snapshot captures critical financial invariants; no user data
# is printed to logs. Counts/aggregates must remain equal across the update.

critical_snapshot() {
  local prefix=v2
  [[ "$SCHEMA_KIND" == native ]] && prefix=tx
  db_sql "SELECT (SELECT COUNT(*) FROM ${prefix}_user), (SELECT COALESCE(SUM(balance),0) FROM ${prefix}_user), (SELECT COALESCE(SUM(commission_balance),0) FROM ${prefix}_user), (SELECT COUNT(*) FROM ${prefix}_order), (SELECT COALESCE(SUM(total_amount),0) FROM ${prefix}_order)"
}
target_artisan() {
  docker compose run -T --rm --no-deps \
    -e CACHE_DRIVER=array -e SETTING_CACHE_STORE=array -e QUEUE_CONNECTION=sync -e SESSION_DRIVER=array \
    --entrypoint php txboard /www/artisan "$@" --no-interaction </dev/null
}

cutover_artisan() {
  local mode="$1"; shift
  local -a approval=()
  if [[ "$mode" == execute ]]; then
    approval=(-e TXBOARD_CUTOVER_APPROVED=1 -e TXBOARD_BACKUP_VERIFIED=1)
  fi
  docker compose run -T --rm --no-deps \
    -v "$CUTOVER_PLAN:/tmp/txboard-reviewed-cutover.json:ro" \
    -e CACHE_DRIVER=array -e SETTING_CACHE_STORE=array -e QUEUE_CONNECTION=sync -e SESSION_DRIVER=array \
    "${approval[@]}" --entrypoint php txboard /www/artisan txboard:database-cutover \
    --plan=/tmp/txboard-reviewed-cutover.json --direction=up "$@" --no-interaction </dev/null
}

set_native_flag() {
  local tmp
  tmp="$(mktemp "$INSTALL_DIR/.api-env.XXXXXXXX")"
  awk '
    BEGIN { found=0 }
    /^TX_NATIVE_TABLES=/ { print "TX_NATIVE_TABLES=true"; found=1; next }
    { print }
    END { if (!found) print "TX_NATIVE_TABLES=true" }
  ' api.env > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod --reference=api.env "$tmp" 2>/dev/null || chmod 600 "$tmp"
  mv "$tmp" api.env
}

# Do not infer ownership from Compose ps alone: another directory/project may
# have claimed the same service name. Discovery includes stopped containers.
txboard_guard_update "$INSTALL_DIR" ||
  die "target TXBoard service is stopped, unhealthy or ambiguously owned; no upgrade was started"
container_id="$TXBOARD_DETECT_TARGET_ID"
old_image_id="$TXBOARD_DETECT_TARGET_IMAGE"
[[ "$old_image_id" == sha256:* ]] || die "could not pin old running image"
detect_schema
# Older TXBoard-Deploy installations had a backup.sh without CHECKSUMS and
# without a strict failure contract. Upgrade that script before any downtime.
if ! grep -Fq 'CHECKSUMS.sha256' "$INSTALL_DIR/backup.sh" 2>/dev/null; then
  log "upgrading legacy backup script before database migration..."
  safe_backup="$(mktemp "$INSTALL_DIR/.safe-backup.XXXXXXXX")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$DEPLOY_RAW_BASE/backup.sh" -o "$safe_backup" ||
      die "cannot retrieve verified upgrade-capable backup helper"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$safe_backup" "$DEPLOY_RAW_BASE/backup.sh" ||
      die "cannot retrieve verified upgrade-capable backup helper"
  else
    die "curl or wget required to upgrade old backup script"
  fi
  sh -n "$safe_backup" &&
    grep -Fq 'CHECKSUMS.sha256' "$safe_backup" &&
    grep -Fq 'APP_KEY' "$safe_backup" &&
    grep -Fq 'BACKUP_RETENTION' "$safe_backup" ||
    die "retrieved backup script failed validation"
  chmod 700 "$safe_backup"
  mv -f "$safe_backup" "$INSTALL_DIR/backup.sh"
fi
# Database migration mode is selected once from the detected LIVE schema.
# Native tx_* databases skip all legacy questions; legacy mode defaults to keeping v2_*.
UPGRADE_MODE="$SCHEMA_KIND"
if [[ "$SCHEMA_KIND" == legacy ]]; then
  if (( ASSUME_YES == 0 )); then
    [[ -r /dev/tty ]] || die "legacy database requires interactive choice (or --yes to KEEP v2_* names)"
    printf "\nLegacy v2_* database detected:\n  1) Upgrade application; KEEP v2_* table names (recommended)\n  2) Upgrade and rename ALL tables to tx_* (approved plan + verified restore required)\n  0) Cancel\nChoice [1]: " > /dev/tty
    IFS= read -r choice < /dev/tty || true
    case "${choice:-1}" in
      1) UPGRADE_MODE=legacy ;;
      2) UPGRADE_MODE=cutover ;;
      0) log "cancelled before image or database changes"; exit 0 ;;
      *) die "invalid schema upgrade choice" ;;
    esac
  fi
  if [[ "$UPGRADE_MODE" == cutover ]]; then
    if [[ -z "$CUTOVER_PLAN" ]]; then
      printf "Reviewed and approved plan absolute path on HOST: " > /dev/tty
      IFS= read -r CUTOVER_PLAN < /dev/tty || true
    fi
    [[ "$CUTOVER_PLAN" == /* && -f "$CUTOVER_PLAN" && -s "$CUTOVER_PLAN" && -r "$CUTOVER_PLAN" && ! -L "$CUTOVER_PLAN" ]] ||
      die "cutover requires an independently reviewed, readable, non-symlink JSON plan at an absolute host path"
    CUTOVER_PLAN="$(realpath "$CUTOVER_PLAN")"
    printf "\nWARNING: native cutover requires reviewed runtime/plugins, a restore-tested full backup, and a maintenance window.\nType REVIEWED to confirm independent plan/runtime review: " > /dev/tty
    IFS= read -r typed < /dev/tty || true
    [[ "$typed" == REVIEWED ]] || die "cutover not approved"
  elif [[ -n "$CUTOVER_PLAN" ]]; then
    die "--cutover-plan provided but rename option was not selected"
  fi
elif [[ -n "$CUTOVER_PLAN" ]]; then
  die "already native: --cutover-plan is not applicable"
else
  log "native tx_* database detected; no legacy prompt; continuing automatic upgrade"
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

# Re-check after pull/backup preparation: a replaced or unhealthy container
# must not be stopped or migrated under the original ID's identity.
txboard_guard_update "$INSTALL_DIR" ||
  die "TXBoard service changed after preflight; refuse to stop or migrate"
[[ "$TXBOARD_DETECT_TARGET_ID" == "$container_id" ]] ||
  die "TXBoard container changed during upgrade preflight; abort"
log "stopping TXBoard, embedded queue workers, WebSocket and scheduled writers..."
docker compose stop txboard || die "could not stop TXBoard"
phase=frozen
require_schema "$SCHEMA_KIND"
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
# The old backup Compose binds storage/app, but not all plugin/theme files.
# Preserve those host paths plus deployment configuration in this archive.
cp -p "$INSTALL_DIR/.env" "$backup_path/deploy.env" ||
  die "cannot preserve deployment settings"
cp -p "$INSTALL_DIR/compose.yaml" "$backup_path/compose.yaml" ||
  die "cannot preserve deployment compose"
for spec in 'data/plugins:plugins.tar.gz' 'data/storage/theme:storage-theme.tar.gz'; do
  subpath="$INSTALL_DIR/${spec%%:*}"
  filename="${spec##*:}"
  if [[ -d "$subpath" ]]; then
    tar -czf "$backup_path/$filename" -C "$subpath" . ||
      die "cannot back up $subpath"
  fi
done
(
  cd "$backup_path"
  sha256sum deploy.env compose.yaml > CHECKSUMS.additional
  for name in plugins.tar.gz storage-theme.tar.gz; do
    if [[ -f "$name" ]]; then
      gzip -t "$name" || exit 1
      sha256sum "$name" >> CHECKSUMS.additional
    fi
  done
  cat CHECKSUMS.additional >> CHECKSUMS.sha256
  rm -f CHECKSUMS.additional
) || die "cannot checksum complete persistent files"
if [[ "$UPGRADE_MODE" == cutover ]]; then
  # Freeze the exact reviewed plan inside the immutable upgrade archive; never
  # trust a mutable host file again after the stop/backup point.
  cp -- "$CUTOVER_PLAN" "$backup_path/reviewed-plan.json" || die "could not snapshot reviewed rename plan"
  chmod 600 "$backup_path/reviewed-plan.json"
  (cd "$backup_path" && sha256sum reviewed-plan.json >> CHECKSUMS.sha256) || die "could not checksum reviewed plan"
  CUTOVER_PLAN="$backup_path/reviewed-plan.json"
fi
(cd "$backup_path" && test -s env && test -s db.sql.gz && test -s MANIFEST && test -s CHECKSUMS.sha256 && sha256sum -c CHECKSUMS.sha256 && gzip -t db.sql.gz) ||
  die "backup archive checksum or gzip validation failed"
log "backup archive verified: $backup_path (separate restoration rehearsal is still needed)"

set_image "$new_image"
phase=migrate
attempted_migrate=1
log "running normal Laravel schema migrations using the TARGET image..."
target_artisan migrate --force || die "Laravel migrations failed; manual database recovery required"
require_schema "$SCHEMA_KIND"
if [[ "$UPGRADE_MODE" == cutover ]]; then
  log "checking exact, reviewed ALL-table mapping against post-migration v2_* schema..."
  cutover_artisan dryrun || die "reviewed cutover plan rejected; no rename attempted"
  printf "\nConfirmed full backup: %s\nProduction backup must have been RESTORED and checked on an isolated clone.\nType RESTORED to attest the recovery test succeeded: " "$backup_path" > /dev/tty
  IFS= read -r recovery < /dev/tty || true
  [[ "$recovery" == RESTORED ]] || die "restore verification not confirmed; no rename attempted"
  log "enabling Laravel maintenance mode while all writers remain frozen..."
  target_artisan down || die "could not enter Laravel maintenance mode; rename cancelled"
  log "executing ONE atomic MySQL multi-table rename with approved plan..."
  cutover_artisan execute --execute || die "native cutover command failed; inspect schema and backup before recovery"
  set_native_flag || die "cutover succeeded but api.env could not switch to TX_NATIVE_TABLES=true; keep writers stopped"
  require_schema native
  target_artisan config:clear || die "cannot clear Laravel config cache after native cutover"
fi
migration_status="$(target_artisan migrate:status)" || die "cannot inspect migration status"
if grep -Eiq '(^|[[:space:]])Pending([[:space:]]|$)' <<< "$migration_status"; then
  die "migrations remain pending"
fi
after="$(critical_snapshot)" || die "post-migration snapshot failed"
[[ "$after" == "$before" ]] || die "critical user/order/balance aggregates changed during schema upgrade"
if [[ "$UPGRADE_MODE" == cutover ]]; then
  target_artisan up || die "cannot exit Laravel maintenance mode after confirmed native cutover"
fi
phase=post_migrate
log "schema and financial invariants checked; recreating TXBoard..."
docker compose up -d --no-deps --force-recreate --wait txboard ||
  die "new image health check failed after migration"
docker compose exec -T txboard php artisan txboard:install-status --no-interaction </dev/null ||
  die "new image install-state check failed"
phase=complete
log "upgrade passed: $new_image; $SCHEMA_KIND schema; archive=$backup_path"
refresh_tools
docker compose ps txboard
