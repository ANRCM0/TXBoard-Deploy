#!/usr/bin/env bash

service_status() {
  docker_ok; need_install
  printf 'Directory: %s\nMode: %s\nURL: %s\nImage: %s\n\n'     "$TXBOARD_INSTALL_DIR" "$(detect_mode)"     "$(env_get "$TXBOARD_INSTALL_DIR/api.env" APP_URL)"     "$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_IMAGE)"
  compose ps
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
    choice="$(choose "1 status  2 start  3 stop  4 restart  5 resources  0 back" "1" "5")"
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

logs_menu() {
  docker_ok; need_install
  local choice service=""
  choice="$(choose "1 TXBoard  2 MySQL  3 Backup  4 All  0 back" "1" "4")"
  case "$choice" in
    1) service=txboard ;;
    2) service=database ;;
    3) service=backup ;;
    4) service="" ;;
    0) return 0 ;;
  esac
  if [[ -n "$service" ]]; then compose logs -f --tail=200 "$service"; else compose logs -f --tail=200; fi
}
