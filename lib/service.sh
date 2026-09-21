#!/usr/bin/env bash

service_status() {
  tx_require_docker
  tx_require_install
  tx_compose ps
}

service_start() {
  tx_require_docker
  tx_require_install
  tx_compose up -d --remove-orphans
}

service_stop() {
  tx_require_docker
  tx_require_install
  tx_compose stop
}

service_restart() {
  tx_require_docker
  tx_require_install
  tx_compose restart txboard
  tx_compose up -d --wait txboard
}

service_logs() {
  tx_require_docker
  tx_require_install
  tx_compose logs --tail=200 -f txboard
}

service_stats() {
  tx_require_docker
  tx_require_install
  local ids
  ids="$(tx_compose ps -q)"
  [[ -n "$ids" ]] || { tx_warn "no running TXBoard containers"; return 0; }
  docker stats --no-stream $ids
}

service_menu() {
  while true; do
    clear 2>/dev/null || true
    cat <<'EOF'
TXBoard Service Management

1. Status
2. Start
3. Stop
4. Restart TXBoard
5. Follow logs
6. Resource usage
0. Back
EOF
    printf 'Select [0-6]: ' > /dev/tty
    IFS= read -r choice < /dev/tty || return 0
    case "$choice" in
      1) service_status; tx_pause ;;
      2) service_start; tx_pause ;;
      3) service_stop; tx_pause ;;
      4) service_restart; tx_pause ;;
      5) service_logs ;;
      6) service_stats; tx_pause ;;
      0) return 0 ;;
      *) tx_warn "invalid choice"; sleep 1 ;;
    esac
  done
}
