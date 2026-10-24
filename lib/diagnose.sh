#!/usr/bin/env bash
core_diagnose() {
  [[ $# -eq 0 || ( $# -eq 1 && "$1" == --show-admin-path ) ]] || die "usage: txboard core-diagnose [--show-admin-path]"
  docker_ok; need_install
  local helper="$TXBOARD_INSTALL_DIR/scripts/core-diagnostics.py" status=0
  [[ -f "$helper" && ! -L "$helper" ]] || die "Core diagnostic helper missing; run txboard refresh-manager"
  command -v python3 >/dev/null 2>&1 || die "Core diagnostics require Python 3.10+"
  python3 "$helper" --dir "$TXBOARD_INSTALL_DIR" "$@" || status=$?
  if ((status != 0)); then
    warn "Core diagnostics are incomplete or report an unhealthy state. Preserve the report and original native inputs; do not reinstall."
  fi
  return "$status"
}

deployment_resource_check() {
  need_install
  local helper="$TXBOARD_INSTALL_DIR/scripts/deployment-profile.py" profile
  profile="$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_RESOURCE_PROFILE)"
  [[ -n "$profile" ]] || { warn "resource profile is not configured; review resource limits before upgrading"; return 1; }
  [[ -f "$helper" && ! -L "$helper" ]] || { warn "capacity planner missing; refresh the reviewed toolkit"; return 1; }
  command -v python3 >/dev/null 2>&1 || { warn "capacity planner requires Python 3.10+"; return 1; }
  python3 "$helper" --dir "$TXBOARD_INSTALL_DIR" --profile "$profile" --db-mode "$(database_mode)" \
    --retention "$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_BACKUP_RETENTION)" --installed
}

diagnose_run() {
  docker_ok; need_install
  local failed=0

  echo "=== compose ==="
  (cd "$TXBOARD_INSTALL_DIR" && docker compose config >/dev/null) && echo OK || { echo FAIL; failed=1; }

  echo "=== services ==="
  compose ps || failed=1

  echo "=== database ==="
  if [[ "$(database_mode)" != "local" ]]; then
    if compose run -T --rm --no-deps --entrypoint sh backup -lc \
      'MYSQL_PWD="$DB_PASSWORD" mysql --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USERNAME" --database="$DB_DATABASE" --execute="SELECT 1" >/dev/null'; then
      echo "$(database_mode) database: OK"
    else
      echo "$(database_mode) database: FAIL"
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

  echo "=== capacity budget ==="
  deployment_resource_check || failed=1
  echo "=== running container limits ==="
  local cid
  while IFS= read -r cid; do
    [[ -z "$cid" ]] || docker inspect --format '{{.Name}} memory={{.HostConfig.Memory}} nano_cpus={{.HostConfig.NanoCpus}} pids={{.HostConfig.PidsLimit}}' "$cid" || failed=1
  done < <(compose ps -q)

  echo "=== Core read-only runtime report ==="
  core_diagnose || failed=1

  if [[ "$(env_get "$TXBOARD_INSTALL_DIR/api.env" CORE_INSTALLATION_MODE)" == native ]]; then
    echo "=== native recovery and backup materials ==="
    run_native diagnose || failed=1
  fi

  echo "=== disk ==="
  df -h "$TXBOARD_INSTALL_DIR" || true
  du -sh "$TXBOARD_INSTALL_DIR/data" "$TXBOARD_INSTALL_DIR/backups" 2>/dev/null || true

  echo "=== recent logs ==="
  compose logs --tail=50 txboard || true

  ((failed == 0))
}
