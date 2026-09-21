#!/usr/bin/env bash

config_show() {
  tx_require_install
  cat <<EOF
Install dir:       $TXBOARD_INSTALL_DIR
Image:             $(tx_env_get TXBOARD_IMAGE)
HTTP bind:         $(tx_env_get TXBOARD_HTTP_BIND)
HTTP port:         $(tx_env_get TXBOARD_HTTP_PORT)
HTTPS bind:        $(tx_env_get TXBOARD_HTTPS_BIND)
HTTPS port:        $(tx_env_get TXBOARD_HTTPS_PORT)
Site address:      $(tx_env_get TXBOARD_SITE_ADDRESS)
Backup retention:  $(tx_env_get TXBOARD_BACKUP_RETENTION)
APP_URL:           $(tx_env_get APP_URL "$TXBOARD_INSTALL_DIR/api.env")
EOF
}

config_set_backup_retention() {
  tx_require_install
  printf 'Backup retention (0 = keep all): ' > /dev/tty
  local value
  IFS= read -r value < /dev/tty || return 1
  [[ "$value" =~ ^[0-9]+$ ]] || { tx_warn "invalid number"; return 1; }
  tx_env_set TXBOARD_BACKUP_RETENTION "$value"
  tx_log "backup retention updated"
}

config_set_image() {
  tx_require_install
  printf 'Full image reference: ' > /dev/tty
  local value
  IFS= read -r value < /dev/tty || return 1
  [[ "$value" =~ ^[^[:space:]]+:[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || {
    tx_warn "invalid image reference"; return 1;
  }
  tx_env_set TXBOARD_IMAGE "$value"
  tx_log "image reference updated; run Update to apply it"
}

config_menu() {
  while true; do
    clear 2>/dev/null || true
    cat <<'EOF'
TXBoard Configuration

1. Show current configuration
2. Change image reference
3. Change backup retention
0. Back

Network mode/domain/port changes are intentionally not rewritten in-place yet.
Re-running the installer against an existing deployment is blocked to protect data.
EOF
    printf 'Select [0-3]: ' > /dev/tty
    IFS= read -r choice < /dev/tty || return 0
    case "$choice" in
      1) config_show; tx_pause ;;
      2) config_set_image; tx_pause ;;
      3) config_set_backup_retention; tx_pause ;;
      0) return 0 ;;
      *) tx_warn "invalid choice"; sleep 1 ;;
    esac
  done
}
