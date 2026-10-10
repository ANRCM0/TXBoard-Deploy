#!/usr/bin/env bash
uninstall_menu() {
  require_tty; docker_ok; need_install
  local choice archive
  choice="$(choose "1 仅移除容器  2 完整卸载  0 返回" "0" "2")"
  case "$choice" in
    1) compose down --remove-orphans ;;
    2)
      confirm "完整卸载会删除 Docker 数据卷和文件，确定继续吗？" "N" || return 0
      backup_create
      archive="${HOME:-/root}/txboard-uninstall-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
      tar -czf "$archive" -C "$(dirname "$TXBOARD_INSTALL_DIR")" "$(basename "$TXBOARD_INSTALL_DIR")"
      compose down -v --remove-orphans
      rm -f /usr/local/bin/txboard
      rm -rf "$TXBOARD_INSTALL_DIR"
      log "archive: $archive"
      ;;
  esac
}
