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
    ui_screen
    ui_header "服务管理" "启动、停止和查看应用容器状态"
    ui_section "服务操作"
    ui_item 1 "运行状态"
    ui_item 2 "启动全部服务"
    ui_item 3 "停止服务"
    ui_item 4 "重启 TXBoard"
    ui_item 5 "查看资源占用"
    ui_footer
    ui_item 0 "返回主菜单"
    choice="$(choose "请选择" "1" "5")"
    case "$choice" in
      1) service_status; pause ;;
      2) ui_run "启动全部服务" service_start || warn "启动失败"; pause ;;
      3) ui_run "停止服务" service_stop || warn "停止失败"; pause ;;
      4) ui_run "重启 TXBoard" service_restart || warn "重启失败"; pause ;;
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

  ui_screen
  ui_header "日志查看" "实时日志按 Ctrl+C 返回终端"
  ui_section "选择要跟踪的容器"
  if [[ "$(database_mode)" != "local" ]]; then
    ui_item 1 "TXBoard 应用日志"
    ui_item 2 "自动备份服务"
    ui_item 3 "全部服务"
    ui_footer
    ui_item 0 "返回"
    choice="$(choose "请选择" "1" "3")"
    case "$choice" in
      1) service=txboard ;;
      2) service=backup ;;
      3) service=all ;;
      0) return 0 ;;
    esac
  else
    ui_item 1 "TXBoard 应用日志"
    ui_item 2 "MySQL 数据库"
    ui_item 3 "自动备份服务"
    ui_item 4 "全部服务"
    ui_footer
    ui_item 0 "返回"
    choice="$(choose "请选择" "1" "4")"
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
