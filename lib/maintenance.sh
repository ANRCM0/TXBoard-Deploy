#!/usr/bin/env bash
# Non-destructive TXBoard administration. Artisan stdin is always closed.

maintenance_require_running_app() {
  docker_ok
  need_install
  local app_id
  app_id="$(compose ps --status running -q txboard)" ||
    die "cannot query TXBoard container state"
  [[ -n "$app_id" ]] ||
    die "TXBoard is not running; use 'txboard start' and inspect logs first"
}

maintenance_artisan() {
  maintenance_require_running_app
  compose exec -T txboard php artisan "$@" --no-interaction </dev/null
}

maintenance_reset_admin_password() {
  # Built-in reset:password generates a new password and displays it.
  # Do not put new credentials in argv, a log, a pipe, or a temporary file.
  [[ -t 0 && -t 1 && -w /dev/tty ]] || die "admin password reset requires a local interactive terminal"
  require_tty
  need_install
  local email="${1:-}" suggested
  suggested="$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_ADMIN_EMAIL)"
  [[ -n "$email" ]] || email="$(prompt "管理员邮箱" "$suggested")"
  [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] ||
    die "invalid administrator email"
  warn "确认邮箱仍属于管理员；安装时记录的邮箱可能已修改。"
  if ! confirm "为 $email 生成新密码？旧密码立即失效" "N"; then
    log "已取消密码重置"
    return 0
  fi
  maintenance_require_running_app
  if ! compose exec -T txboard php artisan reset:password "$email" --no-interaction </dev/null > /dev/tty; then
    warn "密码重置失败；请检查邮箱、容器状态和数据库连接。"
    return 1
  fi
  log "请保存新密码并尽快登录修改。"
}

maintenance_repair_command() {
  need_install
  [[ -f "$TXBOARD_INSTALL_DIR/txboard.sh" ]] ||
    die "missing manager script: $TXBOARD_INSTALL_DIR/txboard.sh"

  local command_dir="${TXBOARD_COMMAND_DIR:-/usr/local/bin}"
  if [[ "$command_dir" == "/usr/local/bin" && "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "repair-command requires root (use sudo)"
  fi
  local target="$command_dir/txboard" source="$TXBOARD_INSTALL_DIR/txboard.sh" existing
  [[ -d "$command_dir" ]] || die "command directory missing: $command_dir"
  if [[ -e "$target" && ! -L "$target" ]]; then
    die "refusing to overwrite a non-symlink: $target"
  fi
  if [[ -L "$target" ]]; then
    existing="$(readlink -- "$target")"
    [[ "$existing" == "$source" ]] ||
      die "refusing to overwrite an unrelated symlink: $target -> $existing"
  fi
  chmod 755 "$source"
  ln -sfn -- "$source" "$target"
  log "管理命令已修复: $target -> $source"
}

maintenance_install_status() {
  maintenance_artisan txboard:install-status
}

maintenance_clear_runtime_cache() {
  # cache:clear and optimize:clear may flush shared Redis runtime data.
  maintenance_artisan config:clear
  maintenance_artisan route:clear
  maintenance_artisan view:clear
  log "配置/路由/视图缓存已清理；未清空共享 Redis。"
}

maintenance_restart_horizon() {
  maintenance_artisan horizon:terminate
  log "Horizon 收到平滑重启请求，由 Supervisor 自动拉起。"
}

maintenance_menu() {
  require_tty
  local choice
  while true; do
    choice="$(choose "1 重置管理员密码  2 修复 txboard 命令  3 安装状态  4 清理配置缓存  5 重启 Horizon  0 返回" "1" "5")"
    case "$choice" in
      1) maintenance_reset_admin_password; pause ;;
      2) maintenance_repair_command; pause ;;
      3) maintenance_install_status; pause ;;
      4) maintenance_clear_runtime_cache; pause ;;
      5) maintenance_restart_horizon; pause ;;
      0) return 0 ;;
    esac
  done
}
