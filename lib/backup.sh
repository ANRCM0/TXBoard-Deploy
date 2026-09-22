#!/usr/bin/env bash

backup_list() {
  need_install
  find "$TXBOARD_INSTALL_DIR/backups" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null |
    grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort -r || true
}

backup_create() {
  docker_ok; need_install
  compose run -T --rm -e BACKUP_INTERVAL=0 backup
}

backup_safety() {
  docker_ok; need_install
  compose run -T --rm -e BACKUP_INTERVAL=0 -e BACKUP_RETENTION=0 backup
}

backup_pick() {
  local -a items=()
  local i choice
  mapfile -t items < <(backup_list)
  ((${#items[@]})) || die "no backups found"
  for i in "${!items[@]}"; do
    printf '%d) %s\n' "$((i+1))" "${items[$i]}" > /dev/tty
  done
  choice="$(choose "Backup" "1" "${#items[@]}")"
  ((choice > 0)) || return 1
  printf '%s' "${items[$((choice-1))]}"
}

backup_restore() {
  require_tty; docker_ok; need_install
  if [[ "$(database_mode)" == "external" ]]; then
    warn "automatic restore is disabled for external databases; create backups here and restore them with your database provider/admin tooling"
    return 0
  fi
  local name path db user pass root app_url secure
  name="$(backup_pick)" || return 0
  path="$TXBOARD_INSTALL_DIR/backups/$name"
  gzip -t "$path/db.sql.gz" || die "corrupt database backup"

  confirm "Restore $name? A safety backup will be created first." "N" || return 0
  backup_safety

  db="$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_DB_DATABASE)"; db="${db:-txboard}"
  user="$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_DB_USERNAME)"; user="${user:-txboard}"
  pass="$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_DB_PASSWORD)"
  root="$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_DB_ROOT_PASSWORD)"
  app_url="$(env_get "$TXBOARD_INSTALL_DIR/api.env" APP_URL)"
  secure="$(env_get "$TXBOARD_INSTALL_DIR/api.env" SESSION_SECURE_COOKIE)"
  [[ "$db" =~ ^[A-Za-z0-9_]+$ && -n "$root" ]] || die "invalid database configuration"

  compose stop backup txboard || true
  compose up -d --wait database
  compose exec -T -e MYSQL_PWD="$root" database mysql -uroot -e     "DROP DATABASE IF EXISTS $db; CREATE DATABASE $db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  gzip -dc "$path/db.sql.gz" | compose exec -T -e MYSQL_PWD="$root" database mysql -uroot "$db"

  if [[ -f "$path/env" ]]; then
    cp "$path/env" "$TXBOARD_INSTALL_DIR/api.env"
    chmod 600 "$TXBOARD_INSTALL_DIR/api.env"
    env_set "$TXBOARD_INSTALL_DIR/api.env" DB_HOST database
    env_set "$TXBOARD_INSTALL_DIR/api.env" DB_DATABASE "$db"
    env_set "$TXBOARD_INSTALL_DIR/api.env" DB_USERNAME "$user"
    env_set "$TXBOARD_INSTALL_DIR/api.env" DB_PASSWORD "$pass"
    env_set "$TXBOARD_INSTALL_DIR/api.env" APP_URL "$app_url"
    env_set "$TXBOARD_INSTALL_DIR/api.env" SESSION_SECURE_COOKIE "$secure"
  fi

  if [[ -f "$path/storage-app.tar.gz" ]]; then
    mkdir -p "$TXBOARD_INSTALL_DIR/data/storage/app"
    find "$TXBOARD_INSTALL_DIR/data/storage/app" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    tar -xzf "$path/storage-app.tar.gz" -C "$TXBOARD_INSTALL_DIR/data/storage/app"
  fi

  compose up -d --wait txboard
  compose up -d backup
  compose exec -T txboard php artisan txboard:install-status --no-interaction >/dev/null ||
    die "restore validation failed"
  log "restored $name"
}

backup_menu() {
  local choice name value
  while true; do
    choice="$(choose "1 create  2 list  3 restore  4 delete  5 retention  0 back" "1" "5")"
    case "$choice" in
      1) backup_create; pause ;;
      2) backup_list; pause ;;
      3) backup_restore; pause ;;
      4)
        name="$(backup_pick)" || continue
        confirm "Delete $name?" "N" && rm -rf "$TXBOARD_INSTALL_DIR/backups/$name"
        ;;
      5)
        value="$(prompt "Retention (0=keep all)" "$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_BACKUP_RETENTION)")"
        [[ "$value" =~ ^[0-9]+$ ]] || { warn "invalid retention"; continue; }
        env_set "$TXBOARD_INSTALL_DIR/.env" TXBOARD_BACKUP_RETENTION "$value"
        docker_ok
        compose up -d --force-recreate backup
        ;;
      0) return 0 ;;
    esac
  done
}
