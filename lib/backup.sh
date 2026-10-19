#!/usr/bin/env bash

backup_list() {
  need_install
  find "$TXBOARD_INSTALL_DIR/backups" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null |
    grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort -r || true
}

backup_create() { upgrade_safe_mutation backup_create_locked; }

backup_create_locked() {
  docker_ok; need_install
  compose run -T --rm -e BACKUP_INTERVAL=0 backup
}

backup_safety() { upgrade_safe_mutation backup_safety_locked; }

backup_safety_locked() {
  docker_ok; need_install
  compose run -T --rm -e BACKUP_INTERVAL=0 -e BACKUP_RETENTION=0 backup
}

backup_set_retention() { upgrade_safe_mutation backup_set_retention_locked "$@"; }

backup_set_retention_locked() {
  local value="${1:?missing backup retention}"
  [[ "$value" =~ ^[0-9]+$ ]] || die "invalid retention"
  docker_ok
  env_set "$TXBOARD_INSTALL_DIR/.env" TXBOARD_BACKUP_RETENTION "$value"
  compose up -d --force-recreate backup
}

backup_pick() {
  local -a items=()
  local i choice
  mapfile -t items < <(backup_list)
  ((${#items[@]})) || die "no backups found"
  for i in "${!items[@]}"; do
    printf '%d) %s\n' "$((i+1))" "${items[$i]}" > /dev/tty
  done
  choice="$(choose "请选择备份" "1" "${#items[@]}")"
  ((choice > 0)) || return 1
  printf '%s' "${items[$((choice-1))]}"
}

backup_restore() { upgrade_safe_mutation backup_restore_locked; }

backup_restore_locked() {
  need_install
  if [[ "$(env_get "$TXBOARD_INSTALL_DIR/api.env" CORE_INSTALLATION_MODE)" == native ]]; then
    warn "native deployment requires matching private configuration, APP_KEY, immutable image and installation authority; database-only restore is disabled"
    warn "use txboard native backup-check --archive TIMESTAMP, rehearse restoration in isolation, or resume the original txboard native recover intent"
    return 1
  fi
  require_tty; docker_ok
  if [[ "$(database_mode)" != "local" ]]; then
    warn "automatic restore is disabled for host/external databases; backups remain available, but restore them with database admin tooling"
    return 0
  fi
  local name path db user pass root app_url secure
  name="$(backup_pick)" || return 0
  path="$TXBOARD_INSTALL_DIR/backups/$name"
  gzip -t "$path/db.sql.gz" || die "corrupt database backup"

  confirm "确认恢复 $name？系统将先创建安全备份。" "N" || return 0
  backup_safety_locked

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
    ui_screen
    ui_header "备份管理" "数据安全 · 恢复前自动创建安全备份"
    ui_section "备份操作"
    ui_item 1 "创建新备份"
    ui_item 2 "查看备份列表"
    ui_item 3 "恢复数据库" "需要再次确认"
    ui_danger_item 4 "删除备份" "不可撤销"
    ui_item 5 "设置保留数量"
    ui_item 6 "核验 Native 备份材料"
    ui_footer
    ui_item 0 "返回主菜单"
    choice="$(choose "请选择" "1" "6")"
    case "$choice" in
      1) ui_run "生成 TXBoard 完整备份" backup_create || warn "备份失败"; pause ;;
      2) backup_list; pause ;;
      3) backup_restore; pause ;;
      4)
        name="$(backup_pick)" || continue
        confirm "确定删除备份 $name 吗？" "N" && upgrade_safe_mutation rm -rf "$TXBOARD_INSTALL_DIR/backups/$name"
        ;;
      5)
        value="$(prompt "保留备份数量（0 为全部保留）" "$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_BACKUP_RETENTION)")"
        [[ "$value" =~ ^[0-9]+$ ]] || { warn "invalid retention"; continue; }
        backup_set_retention "$value"
        ;;
      6)
        name="$(backup_pick)" || continue
        run_native backup-check --archive "$name" || warn "备份材料核验失败"
        pause
        ;;
      0) return 0 ;;
    esac
  done
}
