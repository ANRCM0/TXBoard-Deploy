#!/usr/bin/env bash
set -Eeuo pipefail

SELF="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
  RESOLVED="$(readlink -f "$SELF" 2>/dev/null || true)"
  [[ -n "$RESOLVED" ]] && SELF="$RESOLVED"
fi
SCRIPT_DIR="$(cd -- "$(dirname -- "$SELF")" && pwd)"

if [[ "${1:-}" == "--dir" ]]; then
  export TXBOARD_INSTALL_DIR="${2:?missing path for --dir}"
  shift 2
fi

LIB_DIR="${TXBOARD_MANAGER_LIB_DIR:-$SCRIPT_DIR/lib}"

for module in common service backup config diagnose uninstall detect; do
  [[ -f "$LIB_DIR/$module.sh" ]] || {
    printf '[TXBoard] ERROR: missing module: %s/%s.sh\n' "$LIB_DIR" "$module" >&2
    exit 1
  }
  # shellcheck source=/dev/null
  source "$LIB_DIR/$module.sh"
done

CMD="${1:-menu}"
ARG="${2:-}"

deployment_exists() {
  [[ -f "$TXBOARD_INSTALL_DIR/compose.yaml" &&
     -f "$TXBOARD_INSTALL_DIR/.env" &&
     -f "$TXBOARD_INSTALL_DIR/api.env" ]]
}

run_install() {
  if [[ -f "$SCRIPT_DIR/install.sh" ]]; then
    bash "$SCRIPT_DIR/install.sh" --dir "$TXBOARD_INSTALL_DIR"
  else
    fetch "$TXBOARD_DEPLOY_RAW_BASE/install.sh" | bash -s -- --dir "$TXBOARD_INSTALL_DIR"
  fi
}

run_update() {
  local -a args=(--dir "$TXBOARD_INSTALL_DIR")
  [[ -n "${1:-}" ]] && args+=(--tag "$1")
  # Always fetch the current database-aware upgrader. A stale local updater
  # could otherwise replace the image without checking schema or backups.
  local tmp
  tmp="$(mktemp "${TXBOARD_INSTALL_DIR}/.safe-update.XXXXXXXX")"
  if ! fetch "$TXBOARD_DEPLOY_RAW_BASE/update.sh" > "$tmp" || ! bash -n "$tmp"; then
    rm -f "$tmp"
    die "cannot fetch/validate safe database-aware updater; refusing to run an older local updater"
  fi
  chmod 700 "$tmp"
  local status=0
  bash "$tmp" "${args[@]}" || status=$?
  rm -f "$tmp"
  return "$status"
}

show_help() {
  cat <<'EOF'
TXBoard 管理工具

Usage:
  txboard
  txboard <command> [argument]
  txboard --dir /path/to/txboard <command>

Interactive:
  menu                 Open the management menu
  service-menu         Open service management
  backup-menu          Open backup management
  config               Open configuration menu

Quick commands:
  status | ps          Show deployment and container status
  detect               Discover running/stopped TXBoard instances on this server
  start                Start TXBoard services
  stop                 Stop TXBoard services
  restart              Restart TXBoard
  stats                Show container resource usage
  logs [service]       Follow logs: all, txboard, database/mysql, backup
  update [tag]         Update the current image, or switch to a tag
  backup               Create a backup now
  backups              List available backups
  restore              Restore a managed-MySQL backup interactively (local mode only)
  config-show          Show current deployment configuration
  diagnose             Run diagnostics
  uninstall            Open the safe uninstall flow
  install              Run the installer when no deployment exists
  help                 Show this help

Examples:
  sudo txboard
  sudo txboard status
  sudo txboard restart
  sudo txboard logs txboard
  sudo txboard update latest
  sudo txboard backup
  sudo txboard config
EOF
}

install_menu() {
  require_tty
  while true; do
    printf '\033[2J\033[H' > /dev/tty
    cat > /dev/tty <<'EOF'
========================================
            TXBoard 管理中心
========================================
未检测到现有 TXBoard 部署。

  1) 安装 TXBoard
  0) 退出
========================================
EOF
    case "$(choose "请选择" "1" "1")" in
      1) run_install; return 0 ;;
      0) return 0 ;;
    esac
  done
}

main_menu() {
  require_tty
  deployment_exists || { install_menu; return; }

  while true; do
    printf '\033[2J\033[H' > /dev/tty
    cat > /dev/tty <<'EOF'
========================================
            TXBoard 管理中心
========================================
  1) 查看运行状态
  2) 升级镜像 / 数据库
  3) 启动服务
  4) 停止服务
  5) 重启 TXBoard
  6) 查看运行日志
  7) 立即备份
  8) 备份管理
  9) 配置管理
 10) 故障诊断
 11) 资源占用
 12) 卸载
  0) 退出
========================================
EOF
    case "$(choose "请选择" "1" "12")" in
      1) service_status; pause ;;
      2) run_update; pause ;;
      3) service_start; pause ;;
      4) service_stop; pause ;;
      5) service_restart; pause ;;
      6) logs_menu ;;
      7) backup_create; pause ;;
      8) backup_menu ;;
      9) config_menu ;;
      10) diagnose_run || true; pause ;;
      11) service_stats; pause ;;
      12) uninstall_menu ;;
      0) return 0 ;;
    esac
  done
}

case "$CMD" in
  menu) main_menu ;;
  install) run_install ;;
  update) run_update "$ARG" ;;
  detect) docker_ok; txboard_detect_scan "$TXBOARD_INSTALL_DIR"; txboard_detect_print ;;
  status|ps) service_status ;;
  start) service_start ;;
  stop) service_stop ;;
  restart) service_restart ;;
  stats) service_stats ;;
  service-menu) service_menu ;;
  logs) logs_follow "$ARG" ;;
  backup) backup_create ;;
  backups|backup-list) backup_list ;;
  backup-menu) backup_menu ;;
  restore) backup_restore ;;
  config) config_menu ;;
  config-show) config_show ;;
  diagnose) diagnose_run ;;
  uninstall) uninstall_menu ;;
  help|-h|--help) show_help ;;
  *) die "unknown command: $CMD. Run 'txboard help' for usage." ;;
esac
