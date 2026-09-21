#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${TXBOARD_INSTALL_DIR:-/opt/txboard}"
IMAGE_TAG=""
SKIP_BACKUP=0
ASSUME_YES=0

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

current_image="$(grep -E '^TXBOARD_IMAGE=' .env | tail -1 | cut -d= -f2-)"
[[ -n "$current_image" ]] || die "TXBOARD_IMAGE is missing from $INSTALL_DIR/.env"

if [[ -n "$IMAGE_TAG" ]]; then
  [[ "$IMAGE_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "invalid image tag: $IMAGE_TAG"
  new_image="ghcr.io/paimoncai/txboard:$IMAGE_TAG"
else
  new_image="$current_image"
fi

if [[ "$ASSUME_YES" -eq 0 ]]; then
  [[ -r /dev/tty ]] || die "confirmation requires a TTY; use --yes for unattended update"
  printf 'Current image: %s\nTarget image:  %s\nContinue? [Y/n]: ' "$current_image" "$new_image" > /dev/tty
  IFS= read -r answer < /dev/tty || true
  answer="${answer:-Y}"
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] || { log "cancelled"; exit 0; }
fi

if [[ "$new_image" != "$current_image" ]]; then
  tmp="$(mktemp)"
  awk -v value="$new_image" '
    BEGIN { done=0 }
    /^TXBOARD_IMAGE=/ { print "TXBOARD_IMAGE=" value; done=1; next }
    { print }
    END { if (!done) print "TXBOARD_IMAGE=" value }
  ' .env > "$tmp"
  chmod --reference=.env "$tmp" 2>/dev/null || chmod 600 "$tmp"
  mv "$tmp" .env
fi

if [[ "$SKIP_BACKUP" -eq 0 ]]; then
  log "creating one-shot backup before update..."
  docker compose run --rm -e BACKUP_INTERVAL=0 backup
fi

log "pulling $new_image ..."
docker compose pull txboard

log "recreating TXBoard..."
docker compose up -d --remove-orphans --wait txboard

if ! docker compose exec -T txboard php artisan xboard:install-status --no-interaction >/dev/null; then
  die "updated container is running but installation state is incomplete"
fi

log "update completed: $new_image"
docker compose ps txboard
