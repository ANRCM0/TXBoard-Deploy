#!/usr/bin/env bash

diagnose_run() {
  tx_require_docker
  tx_require_install
  local failed=0

  printf '\n== Docker ==\n'
  docker version --format 'Engine: {{.Server.Version}}' || failed=1
  docker compose version || failed=1

  printf '\n== Compose config ==\n'
  (cd "$TXBOARD_INSTALL_DIR" && docker compose config >/dev/null) &&
    echo "compose.yaml: OK" || { echo "compose.yaml: FAILED"; failed=1; }

  printf '\n== Containers ==\n'
  tx_compose ps || failed=1

  printf '\n== TXBoard health ==\n'
  if tx_compose ps --status running -q txboard | grep -q .; then
    tx_compose exec -T txboard php artisan xboard:install-status --no-interaction &&
      echo "install-status: OK" || { echo "install-status: FAILED"; failed=1; }
    tx_compose exec -T txboard sh -lc 'redis-cli -s /data/redis.sock ping' 2>/dev/null |
      grep -q PONG && echo "redis: OK" || { echo "redis: FAILED"; failed=1; }
  else
    echo "txboard container is not running"
    failed=1
  fi

  printf '\n== Database ==\n'
  if tx_compose ps --status running -q database | grep -q .; then
    echo "database container: running"
  else
    echo "database container: not running"
    failed=1
  fi

  printf '\n== Disk ==\n'
  df -h "$TXBOARD_INSTALL_DIR" || true

  printf '\n== Recent TXBoard logs ==\n'
  tx_compose logs --tail=80 txboard || true

  if [[ "$failed" -eq 0 ]]; then
    tx_log "diagnostics passed"
  else
    tx_warn "diagnostics found one or more problems"
    return 1
  fi
}
