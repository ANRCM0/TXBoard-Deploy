#!/usr/bin/env bash

uninstall_run() {
  tx_require_docker
  tx_require_install

  cat <<EOF
This will stop and remove TXBoard containers.

Install directory: $TXBOARD_INSTALL_DIR

By default, named volumes and files are preserved.
EOF
  tx_confirm "Continue uninstall?" "N" || return 0

  tx_compose down --remove-orphans
  tx_log "containers removed; data and named volumes were preserved"

  if tx_confirm "Also remove named Docker volumes? THIS DELETES MYSQL DATA." "N"; then
    tx_compose down -v --remove-orphans || true
    tx_warn "named volumes removed"
  fi

  if tx_confirm "Also delete $TXBOARD_INSTALL_DIR files?" "N"; then
    rm -rf "$TXBOARD_INSTALL_DIR"
    tx_warn "installation directory removed"
  fi
}
