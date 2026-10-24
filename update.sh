#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${TXBOARD_INSTALL_DIR:-/opt/txboard}"
IMAGE_TAG=""
NATIVE_IMAGE=""
NATIVE_CONFIGURATION=""
SKIP_BACKUP=0
ASSUME_YES=0
TOOLS_ONLY=0
SCHEMA_KIND=""
DEPLOY_RAW_BASE="${TXBOARD_DEPLOY_RAW_BASE:-https://raw.githubusercontent.com/ANRCM0/TXBoard-Deploy/main}"

log() { printf '[TXBoard Deploy] %s\n' "$*"; }
warn() { printf '[TXBoard Deploy] WARNING: %s\n' "$*" >&2; }
die() { printf '[TXBoard Deploy] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
TXBoard 镜像与数据库安全升级

Usage:
  update.sh [options]

Options:
  --dir PATH       Install directory (default: /opt/txboard)
  --tag TAG        Switch the installed Core image repository to a different tag
  --native-image REF  Immutable native Core image (sha256 ID or repository@sha256)
  --native-config DIR  Private target module configuration for a native update
  --skip-backup    Not permitted during schema-safe updates
  --yes            Unattended native TXBoard upgrade (rejects legacy v2_* schemas)
  --tools-only     Refresh management scripts only; do not update images or databases
  --cutover-plan PATH  Retired (use the isolated XBoard import workflow)
  -h, --help       Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) INSTALL_DIR="${2:?missing value for --dir}"; shift 2 ;;
    --tag) IMAGE_TAG="${2:?missing value for --tag}"; shift 2 ;;
    --native-image) NATIVE_IMAGE="${2:?missing value for --native-image}"; shift 2 ;;
    --native-config) NATIVE_CONFIGURATION="${2:?missing value for --native-config}"; shift 2 ;;
    --skip-backup) SKIP_BACKUP=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --tools-only) TOOLS_ONLY=1; shift ;;
    --cutover-plan) die "legacy in-place cutover is retired; import into a separate empty TXBoard database instead" ;;
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
  # Stage and syntax-check the entire toolkit before replacing any installed
  # manager file. Network errors must not leave a partially refreshed toolkit.
  local stage file module target
  stage="$(mktemp -d "$INSTALL_DIR/.manager-refresh.XXXXXXXX")" ||
    { warn "could not create manager staging directory"; return 1; }
  mkdir -p "$stage/lib"

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

  for file in txboard.sh update.sh; do
    if ! download_file "$DEPLOY_RAW_BASE/$file" "$stage/$file" ||
       ! bash -n "$stage/$file"; then
      warn "could not fetch/validate manager file: $file"
      rm -rf -- "$stage"
      return 1
    fi
  done
  for module in common service backup config diagnose uninstall detect xboard-import maintenance components; do
    if ! download_file "$DEPLOY_RAW_BASE/lib/$module.sh" "$stage/lib/$module.sh" ||
       ! bash -n "$stage/lib/$module.sh"; then
      warn "could not fetch/validate manager module: $module"
      rm -rf -- "$stage"
      return 1
    fi
  done

  mkdir -p "$stage/scripts"
  if ! download_file "$DEPLOY_RAW_BASE/scripts/deployment-profile.py" "$stage/scripts/deployment-profile.py" ||
     ! python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$stage/scripts/deployment-profile.py"; then
    warn "could not fetch/validate capacity planner"
    rm -rf -- "$stage"
    return 1
  fi
  if ! download_file "$DEPLOY_RAW_BASE/scripts/core-diagnostics.py" "$stage/scripts/core-diagnostics.py" ||
     ! python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$stage/scripts/core-diagnostics.py"; then
    warn "could not fetch/validate Core diagnostic helper"
    rm -rf -- "$stage"
    return 1
  fi
  if [[ -f "$INSTALL_DIR/scripts/native-runtime.py" ]]; then
    mkdir -p "$stage/scripts"
    if ! download_file "$DEPLOY_RAW_BASE/scripts/native-runtime.py" "$stage/scripts/native-runtime.py" ||
       ! python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$stage/scripts/native-runtime.py"; then
      warn "could not fetch/validate native deployment runner"
      rm -rf -- "$stage"
      return 1
    fi
  fi

  mkdir -p "$INSTALL_DIR/lib" "$INSTALL_DIR/scripts"
  mv -f -- "$stage/scripts/deployment-profile.py" "$INSTALL_DIR/scripts/deployment-profile.py"
  chmod 700 "$INSTALL_DIR/scripts/deployment-profile.py"
  mv -f -- "$stage/scripts/core-diagnostics.py" "$INSTALL_DIR/scripts/core-diagnostics.py"
  chmod 700 "$INSTALL_DIR/scripts/core-diagnostics.py"
  for module in common service backup config diagnose uninstall detect xboard-import maintenance components; do
    mv -f -- "$stage/lib/$module.sh" "$INSTALL_DIR/lib/$module.sh"
  done
  for file in txboard.sh update.sh; do
    mv -f -- "$stage/$file" "$INSTALL_DIR/$file"
  done
  if [[ -f "$stage/scripts/native-runtime.py" ]]; then
    mv -f -- "$stage/scripts/native-runtime.py" "$INSTALL_DIR/scripts/native-runtime.py"
    chmod 700 "$INSTALL_DIR/scripts/native-runtime.py"
  fi
  rm -rf -- "$stage"
  chmod 755 "$INSTALL_DIR/txboard.sh" "$INSTALL_DIR/update.sh" "$INSTALL_DIR"/lib/*.sh

  target=/usr/local/bin/txboard
  if [[ "${EUID:-$(id -u)}" -eq 0 && -d /usr/local/bin ]]; then
    if [[ ! -e "$target" && ! -L "$target" ]] ||
       { [[ -L "$target" ]] && [[ "$(readlink -- "$target")" == "$INSTALL_DIR/txboard.sh" ]]; }; then
      ln -sfn -- "$INSTALL_DIR/txboard.sh" "$target"
    else
      warn "existing $target is unrelated; refusing to overwrite it"
    fi
  fi
  log "management command refreshed"
}

if [[ "$TOOLS_ONLY" -eq 1 ]]; then
  [[ -z "$IMAGE_TAG" && -z "$NATIVE_IMAGE" && -z "$NATIVE_CONFIGURATION" && "$SKIP_BACKUP" -eq 0 ]] ||
    die "--tools-only cannot be combined with --tag or --skip-backup"
  umask 077
  command -v flock >/dev/null 2>&1 || die "flock is required for management refresh"
  exec 9>"$INSTALL_DIR/.upgrade.lock"
  flock -n 9 || die "another TXBoard management or upgrade process holds the lock"
  [[ ! -e "$INSTALL_DIR/.upgrade-in-progress" && ! -L "$INSTALL_DIR/.upgrade-in-progress" ]] ||
    die "unfinished durable upgrade; inspect upgrade status/recover before refreshing tools"
  refresh_tools || die "management tools refresh failed; current deployment was not changed"
  exit 0
fi

if grep -Fxq 'CORE_INSTALLATION_MODE=native' "$INSTALL_DIR/api.env"; then
  [[ -n "$NATIVE_IMAGE" && -z "$IMAGE_TAG" && "$SKIP_BACKUP" -eq 0 ]] ||
    die "native updates require --native-image with an immutable image; backup is mandatory"
  native_runner="$INSTALL_DIR/scripts/native-runtime.py"
  [[ -f "$native_runner" && ! -L "$native_runner" ]] || die "native runner missing; use the reviewed native deployment toolkit"
  native_args=(update --dir "$INSTALL_DIR" --image "$NATIVE_IMAGE")
  [[ -z "$NATIVE_CONFIGURATION" ]] || native_args+=(--configuration "$NATIVE_CONFIGURATION")
  exec python3 "$native_runner" "${native_args[@]}" --progress
fi
[[ -z "$NATIVE_IMAGE" && -z "$NATIVE_CONFIGURATION" ]] || die "native image/configuration requires an initialized native deployment"

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


# Native-only upgrades. A populated v2_* source MUST use the isolated XBoard importer.
[[ "$SKIP_BACKUP" -eq 0 ]] || die "--skip-backup is disabled: a full backup is required"
umask 077
command -v flock >/dev/null 2>&1 || die "flock is required for upgrade locking"
exec 9>"$INSTALL_DIR/.upgrade.lock"
flock -n 9 || die "another TXBoard upgrade is running"
[[ ! -e "$INSTALL_DIR/.upgrade-in-progress" && ! -L "$INSTALL_DIR/.upgrade-in-progress" ]] ||
  die "unfinished durable upgrade; use upgrade status/recover before changing an image"

profile="$(get_env TXBOARD_RESOURCE_PROFILE)"
if [[ -n "$profile" ]]; then
  helper="$INSTALL_DIR/scripts/deployment-profile.py"
  [[ -f "$helper" && ! -L "$helper" ]] || die "capacity planner missing; refresh the reviewed toolkit"
  python3 "$helper" --dir "$INSTALL_DIR" --installed --profile "$profile" \
    --db-mode "$(get_env TXBOARD_DB_MODE)" --retention "$(get_env TXBOARD_BACKUP_RETENTION)" ||
    die "capacity preflight failed before image or database changes"
fi

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
  if (( v2 > 0 )); then
    die "legacy v2_* schema detected; do NOT upgrade in place with a native-only TXBoard image. Use the isolated XBoard import workflow."
  fi
  if (( tx == 0 || txuser != 1 || txsettings != 1 || txorder != 1 )); then
    die "incomplete or unknown native database (v2=$v2, tx=$tx); refusing upgrade"
  fi
  SCHEMA_KIND=native
  log "Native tx_* schema verified (tables=$tx); starting guarded upgrade"

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
  db_sql "SELECT (SELECT COUNT(*) FROM tx_user), (SELECT COALESCE(SUM(balance),0) FROM tx_user), (SELECT COALESCE(SUM(commission_balance),0) FROM tx_user), (SELECT COUNT(*) FROM tx_order), (SELECT COALESCE(SUM(total_amount),0) FROM tx_order)"
}
target_artisan() {
  docker compose run -T --rm --no-deps \
    -e CACHE_DRIVER=array -e SETTING_CACHE_STORE=array -e QUEUE_CONNECTION=sync -e SESSION_DRIVER=array \
    --entrypoint php txboard /www/artisan "$@" --no-interaction </dev/null
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
  log "正在升级旧版备份组件以支持完整校验……"
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

log "正在预先拉取新镜像（当前服务仍在运行）……"
docker pull "$new_image" || die "拉取镜像失败，当前服务不受影响"
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
log "正在停止 TXBoard、队列和 WebSocket 写入……"
docker compose stop txboard || die "could not stop TXBoard"
phase=frozen
require_schema "$SCHEMA_KIND"
before="$(critical_snapshot)" || die "critical snapshot query failed"
[[ -n "$before" ]] || die "empty critical snapshot"

# A separate one-shot dump with retention disabled, not the rolling backup.
old_backup="$(find "$INSTALL_DIR/backups" -mindepth 1 -maxdepth 1 -type d -name '????????T??????Z' -printf '%f\n' 2>/dev/null | sort | tail -1 || true)"
log "正在完整备份数据库、APP_KEY 和持久化文件……"
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
(cd "$backup_path" && test -s env && test -s db.sql.gz && test -s MANIFEST && test -s CHECKSUMS.sha256 && sha256sum -c CHECKSUMS.sha256 && gzip -t db.sql.gz) ||
  die "backup archive checksum or gzip validation failed"
log "backup archive verified: $backup_path (separate restoration rehearsal is still needed)"

set_image "$new_image"
phase=migrate
attempted_migrate=1
log "正在使用新镜像执行 Laravel 数据库结构迁移……"
target_artisan migrate --force || die "Laravel migrations failed; manual database recovery required"
require_schema "$SCHEMA_KIND"
migration_status="$(target_artisan migrate:status)" || die "cannot inspect migration status"
if grep -Eiq '(^|[[:space:]])Pending([[:space:]]|$)' <<< "$migration_status"; then
  die "migrations remain pending"
fi
after="$(critical_snapshot)" || die "post-migration snapshot failed"
[[ "$after" == "$before" ]] || die "critical user/order/balance aggregates changed during schema upgrade"
phase=post_migrate
log "数据库结构和核心余额校验通过，正在启动新版 TXBoard……"
docker compose up -d --no-deps --force-recreate --wait txboard ||
  die "new image health check failed after migration"
docker compose exec -T txboard php artisan txboard:install-status --no-interaction </dev/null ||
  die "new image install-state check failed"
phase=complete
log "升级完成：镜像=$new_image，数据库=native，备份=$backup_path"
refresh_tools || warn "TXBoard was updated but the management toolkit could not be refreshed"
docker compose ps txboard
