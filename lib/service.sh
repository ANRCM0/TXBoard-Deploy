#!/usr/bin/env bash

service_status() {
  docker_ok; need_install
  local db_mode db_target
  db_mode="$(database_mode)"
  if [[ "$db_mode" == "local" ]]; then
    db_target="managed MySQL container"
  else
    db_target="$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_DB_HOST):$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_DB_PORT)/$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_DB_DATABASE)"
  fi

  printf 'Directory: %s\nMode: %s\nURL: %s\nImage: %s\nDatabase: %s (%s)\n\n' \
    "$TXBOARD_INSTALL_DIR" "$(detect_mode)" \
    "$(env_get "$TXBOARD_INSTALL_DIR/api.env" APP_URL)" \
    "$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_IMAGE)" \
    "$db_mode" "$db_target"
  compose ps
  if declare -F txboard_detect_scan >/dev/null 2>&1; then
    txboard_detect_scan "$TXBOARD_INSTALL_DIR" && txboard_detect_print ||
      warn "service discovery failed; inspect Docker access"
  fi
}

service_start() { docker_ok; need_install; compose up -d --remove-orphans; }
service_stop() { docker_ok; need_install; compose stop; }
service_restart() { docker_ok; need_install; compose restart txboard; compose up -d --wait txboard; }

service_stats() {
  docker_ok; need_install
  local ids
  ids="$(compose ps -q)"
  [[ -n "$ids" ]] || { warn "no running TXBoard containers"; return 0; }
  docker stats --no-stream $ids
}

service_menu() {
  local choice
  while true; do
    choice="$(choose "1 状态  2 启动  3 停止  4 重启  5 资源占用  0 返回" "1" "5")"
    case "$choice" in
      1) service_status; pause ;;
      2) service_start; pause ;;
      3) service_stop; pause ;;
      4) service_restart; pause ;;
      5) service_stats; pause ;;
      0) return 0 ;;
    esac
  done
}

logs_follow() {
  docker_ok; need_install
  local service="${1:-all}"

  case "$service" in
    ""|all)
      compose logs -f --tail=200
      ;;
    txboard|backup)
      compose logs -f --tail=200 "$service"
      ;;
    database|mysql)
      [[ "$(database_mode)" == "local" ]] ||
        die "database logs are available only for the managed MySQL mode"
      compose logs -f --tail=200 database
      ;;
    *)
      die "unknown log service: $service (use all, txboard, database/mysql, or backup)"
      ;;
  esac
}

logs_menu() {
  docker_ok; need_install
  local choice service="all"

  if [[ "$(database_mode)" != "local" ]]; then
    choice="$(choose "1 TXBoard  2 备份  3 全部  0 返回" "1" "3")"
    case "$choice" in
      1) service=txboard ;;
      2) service=backup ;;
      3) service=all ;;
      0) return 0 ;;
    esac
  else
    choice="$(choose "1 TXBoard  2 MySQL  3 备份  4 全部  0 返回" "1" "4")"
    case "$choice" in
      1) service=txboard ;;
      2) service=database ;;
      3) service=backup ;;
      4) service=all ;;
      0) return 0 ;;
    esac
  fi

  logs_follow "$service"
}
