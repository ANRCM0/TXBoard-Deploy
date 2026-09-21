#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${TXBOARD_INSTALL_DIR:-/opt/txboard}"
IMAGE_TAG=""
SKIP_BACKUP=0
ASSUME_YES=0
DEPLOY_RAW_BASE="${TXBOARD_DEPLOY_RAW_BASE:-https://raw.githubusercontent.com/PaiMonCai/TXBoard-Deploy/main}"

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
  --tag TAG        Switch ghcr.io/paimoncai/txboard to a different tag
  --skip-backup    Do not create a one-shot backup before update
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

if [[ -n "$IMAGE_TAG" ]]; then
  [[ "$IMAGE_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "invalid image tag: $IMAGE_TAG"
  image_repo="${current_image%:*}"
  new_image="$image_repo:$IMAGE_TAG"
else
  new_image="$current_image"
fi

container_id="$(docker compose ps -q txboard 2>/dev/null || true)"
old_image_id=""
if [[ -n "$container_id" ]]; then
  old_image_id="$(docker inspect "$container_id" --format '{{.Image}}' 2>/dev/null || true)"
fi
if [[ -z "$old_image_id" ]]; then
  old_image_id="$(docker image inspect "$current_image" --format '{{.Id}}' 2>/dev/null || true)"
fi

if [[ "$ASSUME_YES" -eq 0 ]]; then
  [[ -r /dev/tty ]] || die "confirmation requires a TTY; use --yes for unattended update"
  printf 'Current image: %s\nTarget image:  %s\nContinue? [Y/n]: ' "$current_image" "$new_image" > /dev/tty
  IFS= read -r answer < /dev/tty || true
  answer="${answer:-Y}"
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] || { log "cancelled"; exit 0; }
fi

if [[ "$SKIP_BACKUP" -eq 0 ]]; then
  log "creating one-shot backup before update..."
  docker compose run --rm -e BACKUP_INTERVAL=0 backup
fi

log "pulling $new_image ..."
docker pull "$new_image"

if [[ "$new_image" != "$current_image" ]]; then
  set_image "$new_image"
fi

rollback() {
  warn "update validation failed; attempting automatic rollback to $current_image"
  set_image "$current_image"

  if [[ -n "$old_image_id" ]] && docker image inspect "$old_image_id" >/dev/null 2>&1; then
    if docker tag "$old_image_id" "$current_image"; then
      log "restored previous image tag from $old_image_id"
    else
      warn "could not re-tag the previous image; rollback will use the currently available tag"
    fi
  else
    warn "previous image id is unavailable; tag-level rollback only"
  fi

  if docker compose up -d --force-recreate --remove-orphans --wait txboard &&
     docker compose exec -T txboard php artisan txboard:install-status --no-interaction >/dev/null; then
    log "rollback completed successfully"
    return 0
  fi

  warn "automatic rollback failed; inspect: cd $INSTALL_DIR && docker compose logs txboard"
  return 1
}

log "recreating TXBoard..."
if ! docker compose up -d --force-recreate --remove-orphans --wait txboard; then
  rollback || true
  die "update failed while starting the new container"
fi

if ! docker compose exec -T txboard php artisan txboard:install-status --no-interaction >/dev/null; then
  rollback || true
  die "updated container failed installation-state validation"
fi

log "update completed: $new_image"
refresh_tools
docker compose ps txboard
