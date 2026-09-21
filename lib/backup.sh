#!/usr/bin/env bash

backup_create() {
  tx_require_docker
  tx_require_install
  tx_log "creating one-shot backup..."
  tx_compose run --rm -e BACKUP_INTERVAL=0 backup
}

backup_list() {
  tx_require_install
  local dir="$TXBOARD_INSTALL_DIR/backups"
  [[ -d "$dir" ]] || { tx_warn "backup directory does not exist"; return 0; }
  printf '%-20s %-12s %-12s\n' "BACKUP" "DB" "STORAGE"
  local item
  for item in "$dir"/20*T*Z; do
    [[ -d "$item" ]] || continue
    printf '%-20s %-12s %-12s\n' "$(basename "$item")"       "$([[ -s "$item/db.sql.gz" ]] && echo yes || echo no)"       "$([[ -s "$item/storage-app.tar.gz" ]] && echo yes || echo no)"
  done
}

backup_restore() {
  tx_require_docker
  tx_require_install
  backup_list
  printf '\nBackup name: ' > /dev/tty
  local name dir
  IFS= read -r name < /dev/tty || return 1
  [[ "$name" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || tx_die "invalid backup name"
  dir="$TXBOARD_INSTALL_DIR/backups/$name"
  [[ -s "$dir/db.sql.gz" ]] || tx_die "database dump not found: $dir/db.sql.gz"

  tx_confirm "Restore $name? Current database and storage may be overwritten." "N" || return 0

  tx_log "stopping TXBoard application..."
  tx_compose stop txboard

  tx_log "restoring database..."
  local db user pass
  db="$(tx_env_get TXBOARD_DB_DATABASE)"; db="${db:-txboard}"
  user="$(tx_env_get TXBOARD_DB_USERNAME)"; user="${user:-txboard}"
  pass="$(tx_env_get TXBOARD_DB_PASSWORD)"
  gzip -dc "$dir/db.sql.gz" | tx_compose exec -T -e MYSQL_PWD="$pass" database     mysql --user="$user" "$db"

  if [[ -s "$dir/storage-app.tar.gz" ]]; then
    tx_log "restoring storage/app..."
    mkdir -p "$TXBOARD_INSTALL_DIR/data/storage/app"
    rm -rf "$TXBOARD_INSTALL_DIR/data/storage/app"/*
    tar -xzf "$dir/storage-app.tar.gz" -C "$TXBOARD_INSTALL_DIR/data/storage/app"
  fi

  if [[ -s "$dir/env" ]]; then
    tx_log "restoring api.env..."
    cp "$dir/env" "$TXBOARD_INSTALL_DIR/api.env"
    chmod 600 "$TXBOARD_INSTALL_DIR/api.env"
  fi

  tx_log "starting TXBoard..."
  tx_compose up -d --wait txboard
  tx_compose exec -T txboard php artisan xboard:install-status --no-interaction
  tx_log "restore completed: $name"
}

backup_delete() {
  tx_require_install
  backup_list
  printf '\nBackup name to delete: ' > /dev/tty
  local name dir
  IFS= read -r name < /dev/tty || return 1
  [[ "$name" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || tx_die "invalid backup name"
  dir="$TXBOARD_INSTALL_DIR/backups/$name"
  [[ -d "$dir" ]] || tx_die "backup not found: $name"
  tx_confirm "Delete backup $name?" "N" || return 0
  rm -rf "$dir"
  tx_log "deleted: $name"
}

backup_menu() {
  while true; do
    clear 2>/dev/null || true
    cat <<'EOF'
TXBoard Backup Management

1. Create backup now
2. List backups
3. Restore backup
4. Delete backup
0. Back
EOF
    printf 'Select [0-4]: ' > /dev/tty
    IFS= read -r choice < /dev/tty || return 0
    case "$choice" in
      1) backup_create; tx_pause ;;
      2) backup_list; tx_pause ;;
      3) backup_restore; tx_pause ;;
      4) backup_delete; tx_pause ;;
      0) return 0 ;;
      *) tx_warn "invalid choice"; sleep 1 ;;
    esac
  done
}
