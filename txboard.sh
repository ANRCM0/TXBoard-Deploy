#!/usr/bin/env bash
set -Eeuo pipefail

SELF="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
  RESOLVED="$(readlink -f "$SELF" 2>/dev/null || true)"
  [[ -n "$RESOLVED" ]] && SELF="$RESOLVED"
fi
SCRIPT_DIR="$(cd -- "$(dirname -- "$SELF")" && pwd)"
LIB_DIR="${TXBOARD_MANAGER_LIB_DIR:-$SCRIPT_DIR/lib}"

for module in common service backup config diagnose uninstall; do
  [[ -f "$LIB_DIR/$module.sh" ]] || {
    printf '[TXBoard] ERROR: missing module: %s/%s.sh\n' "$LIB_DIR" "$module" >&2
    exit 1
  }
  # shellcheck source=/dev/null
  source "$LIB_DIR/$module.sh"
done

CMD="${1:-menu}"
ARG="${2:-}"

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
  if [[ -f "$SCRIPT_DIR/update.sh" ]]; then
    bash "$SCRIPT_DIR/update.sh" "${args[@]}"
  else
    fetch "$TXBOARD_DEPLOY_RAW_BASE/update.sh" | bash -s -- "${args[@]}"
  fi
}

main_menu() {
  require_tty
  while true; do
    printf '\033[2J\033[H' > /dev/tty
    cat > /dev/tty <<'EOF'
========================================
            TXBoard Manager
========================================
  1) Install TXBoard
  2) Update TXBoard
  3) Service management
  4) View logs
  5) Backup management
  6) Configuration
  7) Diagnostics
  8) Uninstall TXBoard
  0) Exit
========================================
EOF
    case "$(choose "Select" "0" "8")" in
      1) run_install; pause ;;
      2) run_update; pause ;;
      3) service_menu ;;
      4) logs_menu ;;
      5) backup_menu ;;
      6) config_menu ;;
      7) diagnose_run || true; pause ;;
      8) uninstall_menu ;;
      0) return 0 ;;
    esac
  done
}

case "$CMD" in
  menu) main_menu ;;
  install) run_install ;;
  update) run_update "$ARG" ;;
  status) service_status ;;
  start) service_start ;;
  stop) service_stop ;;
  restart) service_restart ;;
  logs) logs_menu ;;
  backup) backup_create ;;
  restore) backup_restore ;;
  diagnose) diagnose_run ;;
  uninstall) uninstall_menu ;;
  *) die "usage: txboard [menu|install|update [tag]|status|start|stop|restart|logs|backup|restore|diagnose|uninstall]" ;;
esac
