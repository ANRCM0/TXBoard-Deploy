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
  gateway) printf '[TXBoard] ERROR: Gateway is retired; browser ingress is included in Core\n' >&2; exit 1 ;;
  core) ;;
  node)
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
  if [[ "$(env_get "$TXBOARD_INSTALL_DIR/api.env" CORE_INSTALLATION_MODE)" == native ]]; then
    [[ -z "${1:-}" ]] || die "native updates use: txboard native update --image DIGEST [--configuration DIR]"
    require_tty
    local target configuration
    target="$(prompt "Native 目标镜像（repository@sha256 或本地 sha256 ID）" "")"
    [[ -n "$target" ]] || die "immutable native image is required"
    configuration="$(prompt "目标私有配置目录（留空沿用当前配置）" "")"
    local -a native_args=(update --image "$target")
    [[ -z "$configuration" ]] || native_args+=(--configuration "$configuration")
    run_native "${native_args[@]}"
    return
  fi

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

run_native() {
  local executable="$SCRIPT_DIR/scripts/native-runtime.py"
  [[ -f "$executable" && ! -L "$executable" ]] || die "native deployment runner missing from the reviewed toolkit"
  command -v python3 >/dev/null 2>&1 || die "native deployment requires Python 3.10+"
  local -a progress_args=()
  case "${1:-}" in install|update|recover) progress_args+=(--progress) ;; esac
  python3 "$executable" "$@" --dir "$TXBOARD_INSTALL_DIR" "${progress_args[@]}"
}

show_help() {
  cat <<'EOF'
TXBoard 管理工具

Usage:
  txboard
  txboard <command> [argument]
  txboard --dir /path/to/txboard <command>
  txboard core <command>                 Existing Core commands
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
  native <command>    Native update --image DIGEST / status / recover / diagnose / backup-check
  backup               Create a backup now
  backups              List available backups
  restore              Restore a managed-MySQL backup interactively (local mode only)
  config-show          Show current deployment configuration
  resources            Check host capacity against the installed resource profile
  diagnose             Run diagnostics
  core-diagnose [--show-admin-path]  Read the redacted Core runtime report
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
    ui_screen
    ui_header "首次安装" "未检测到部署，可以开始安装向导"
    ui_section "快速开始"
    ui_item 1 "安装 TXBoard" "环境检测 · 数据库 · 启动"
    ui_footer
    ui_item 0 "退出"
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
    ui_screen
    ui_header "运维管理中心" "${TXBOARD_INSTALL_DIR}  ·  $(detect_mode)"
    ui_section "服务与运行"
    ui_item 1 "查看运行状态" "容器和服务"
    ui_item 2 "安全升级" "镜像与数据库迁移"
    ui_item 3 "启动服务"
    ui_item 4 "停止服务"
    ui_item 5 "重启 TXBoard"
    ui_item 6 "查看运行日志"
    ui_item 11 "资源占用"
    ui_section "备份与配置"
    ui_item 7 "立即备份"
    ui_item 8 "备份管理" "列表 / 恢复 / 保留策略"
    ui_item 9 "配置管理" "端口 / HTTPS / 镜像"
    ui_section "维护与安全"
    ui_item 10 "故障诊断"
    ui_item 13 "重置管理员密码"
    ui_item 16 "重置后台安全路径"
    ui_item 14 "运维工具"
    ui_item 15 "更新运维脚本" "不修改业务数据"
    ui_danger_item 12 "卸载" "高风险 · 二次确认"
    ui_footer
    ui_item 0 "退出"
    case "$(choose "请选择" "1" "16")" in
      1) service_status; pause ;;
      2) run_update; pause ;;
      3) ui_run "启动 TXBoard 服务" service_start || warn "启动失败"; pause ;;
      4) ui_run "停止 TXBoard 服务" service_stop || warn "停止失败"; pause ;;
      5) ui_run "重启 TXBoard 服务" service_restart || warn "重启失败"; pause ;;
      6) logs_menu ;;
      7) ui_run "创建完整备份" backup_create || warn "备份失败"; pause ;;
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
  native) shift; run_native "$@" ;;
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
  resources) deployment_resource_check ;;
  diagnose) diagnose_run ;;
  core-diagnose) shift; core_diagnose "$@" ;;
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
