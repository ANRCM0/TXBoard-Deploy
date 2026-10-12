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
  export TXBOARD_COMPONENT_DIR="$TXBOARD_INSTALL_DIR"
  shift 2
fi

LIB_DIR="${TXBOARD_MANAGER_LIB_DIR:-$SCRIPT_DIR/lib}"

# Components do not load Core modules or inherit Core's database/install dir.
if [[ "${1:-}" == --component ]]; then
  [[ $# -ge 2 ]] || { printf '[TXBoard] ERROR: missing component\n' >&2; exit 1; }
  component="$2"; shift 2
elif [[ "${1:-}" == core || "${1:-}" == gateway || "${1:-}" == node ]]; then
  component="$1"; shift
else
  component=core
fi
case "$component" in
  core) ;;
  gateway|node)
    [[ -f "$LIB_DIR/components.sh" ]] || { printf '[TXBoard] ERROR: components module missing; refresh the toolkit\n' >&2; exit 1; }
    if (($#)); then exec bash "$LIB_DIR/components.sh" "$component" "$@";
    else exec bash "$LIB_DIR/components.sh" "$component" help; fi ;;
  *) printf '[TXBoard] ERROR: unknown component\n' >&2; exit 1 ;;
esac

for module in common service backup config diagnose uninstall detect maintenance; do
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

run_refresh_manager() {
  need_install
  local tmp status=0
  tmp="$(mktemp "$TXBOARD_INSTALL_DIR/.safe-manager-update.XXXXXXXX")" || die "cannot create manager updater temporary file"
  if ! fetch "$TXBOARD_DEPLOY_RAW_BASE/update.sh" > "$tmp" || ! bash -n "$tmp"; then
    rm -f -- "$tmp"
    die "cannot fetch/validate current toolkit refresh script"
  fi
  chmod 700 "$tmp"
  bash "$tmp" --dir "$TXBOARD_INSTALL_DIR" --tools-only || status=$?
  rm -f -- "$tmp"
  return "$status"
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

run_upgrade() {
  local executable="$SCRIPT_DIR/scripts/upgrade.py"
  [[ -f "$executable" && ! -L "$executable" ]] ||
    die "signed upgrade runner missing; use a reviewed TXBoard-Deploy checkout (scripts/upgrade.py)"
  command -v python3 >/dev/null 2>&1 || die "upgrade requires Python 3.10+ and OpenSSL"
  python3 "$executable" "$@" --dir "$TXBOARD_INSTALL_DIR"
}

show_help() {
  cat <<'EOF'
TXBoard 管理工具

Usage:
  txboard
  txboard <command> [argument]
  txboard --dir /path/to/txboard <command>
  txboard core <command>                 Existing Core commands
  txboard gateway <command> [options]    Gateway install/status/logs/start/stop/restart/upgrade/recover/remove
  txboard node <command> [options]       Delegate to the persistent txnode installer

Interactive:
  menu                 Open the management menu
  service-menu         Open service management
  backup-menu          Open backup management
  config               Open configuration menu
  maintenance-menu     Open administrator and maintenance tools

Quick commands:
  status | ps          Show deployment and container status
  detect               Discover running/stopped TXBoard instances on this server
  start                Start TXBoard services
  stop                 Stop TXBoard services
  restart              Restart TXBoard
  stats                Show container resource usage
  logs [service]       Follow logs: all, txboard, database/mysql, backup
  update [tag]         Update the current image, or switch to a tag
  upgrade <command>   Signed isolated shadow plan/check/apply/status/recover/restore-check
  backup               Create a backup now
  backups              List available backups
  restore              Restore a managed-MySQL backup interactively (local mode only)
  config-show          Show current deployment configuration
  diagnose             Run diagnostics
  admin-reset-password [email]  Reset admin password interactively
  admin-reset-path            Rotate the admin panel security path interactively
  repair-command       Restore /usr/local/bin/txboard command link (root)
  install-status       Check Laravel installation state
  clear-runtime-cache  Clear config/route/view caches (preserve Redis)
  restart-horizon      Gracefully restart Horizon queue workers
  refresh-manager      Update scripts only (no image/database change)
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
  sudo txboard admin-reset-password
  sudo txboard admin-reset-path
  sudo txboard repair-command
  sudo txboard refresh-manager
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
 13) 重置管理员密码
 14) 运维工具
 15) 仅更新运维脚本
 16) 重置管理面板安全路径
  0) 退出
========================================
EOF
    case "$(choose "请选择" "1" "16")" in
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
      13) maintenance_reset_admin_password; pause ;;
      14) maintenance_menu ;;
      15) run_refresh_manager; pause ;;
      16) maintenance_reset_admin_path; pause ;;
      0) return 0 ;;
    esac
  done
}

case "$CMD" in
  menu) main_menu ;;
  install) run_install ;;
  update) run_update "$ARG" ;;
  upgrade) shift; run_upgrade "$@" ;;
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
  admin-reset-password|reset-admin-password) [[ $# -le 2 ]] || die "usage: txboard admin-reset-password [email]"; maintenance_reset_admin_password "$ARG" ;;
  admin-reset-path|reset-admin-path) [[ $# -eq 1 ]] || die "usage: txboard admin-reset-path"; maintenance_reset_admin_path ;;
  repair-command) maintenance_repair_command ;;
  install-status) maintenance_install_status ;;
  clear-runtime-cache) maintenance_clear_runtime_cache ;;
  restart-horizon) maintenance_restart_horizon ;;
  refresh-manager) run_refresh_manager ;;
  maintenance-menu) maintenance_menu ;;
  uninstall) uninstall_menu ;;
  help|-h|--help) show_help ;;
  *) die "unknown command: $CMD. Run 'txboard help' for usage." ;;
esac
