#!/usr/bin/env bash
diagnose_run() {
  docker_ok; need_install
  local failed=0

  echo "=== compose ==="
  (cd "$TXBOARD_INSTALL_DIR" && docker compose config >/dev/null) && echo OK || { echo FAIL; failed=1; }

  echo "=== services ==="
  compose ps || failed=1

  echo "=== database ==="
  if [[ "$(database_mode)" == "external" ]]; then
    if compose run -T --rm --no-deps --entrypoint sh backup -lc \
      'MYSQL_PWD="$DB_PASSWORD" mysql --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USERNAME" --database="$DB_DATABASE" --execute="SELECT 1" >/dev/null'; then
      echo "external database: OK"
    else
      echo "external database: FAIL"
      failed=1
    fi
  else
    if compose ps --status running -q database | grep -q .; then
      echo "managed database: running"
    else
      echo "managed database: not running"
      failed=1
    fi
  fi

  echo "=== install ==="
  if compose ps --status running -q txboard | grep -q .; then
    compose exec -T txboard php artisan txboard:install-status --no-interaction >/dev/null &&
      echo "install-status: OK" || { echo "install-status: FAIL"; failed=1; }
    compose exec -T txboard sh -lc 'redis-cli -s /data/redis.sock ping' 2>/dev/null | grep -q PONG &&
      echo "redis: OK" || { echo "redis: FAIL"; failed=1; }
  else
    echo "txboard: not running"
    failed=1
  fi

  echo "=== disk ==="
  df -h "$TXBOARD_INSTALL_DIR" || true
  du -sh "$TXBOARD_INSTALL_DIR/data" "$TXBOARD_INSTALL_DIR/backups" 2>/dev/null || true

  echo "=== recent logs ==="
  compose logs --tail=50 txboard || true

  ((failed == 0))
}
