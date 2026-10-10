#!/usr/bin/env bash
# Convert an offline XBoard dump in a dedicated, empty TXBoard target.
# This module has no connection to the live XBoard database.
txboard_import_xboard() {
  local dump="$1" source_env="$2" helper key tmp report sql
  local before_users before_orders after_users after_orders orphaned
  [[ "$dump" == /* && -f "$dump" && -s "$dump" && -r "$dump" && ! -L "$dump" ]] ||
    die "XBoard backup must be an absolute, readable, regular .sql.gz file"
  [[ "$source_env" == /* && -f "$source_env" && -r "$source_env" && ! -L "$source_env" ]] ||
    die "XBoard .env must be an absolute, readable regular file (APP_KEY required)"
  [[ "$dump" != "$INSTALL_DIR/"* && "$source_env" != "$INSTALL_DIR/"* ]] ||
    die "XBoard inputs must reside outside the new installation directory"
  key="$(sed -n 's/^APP_KEY=//p' "$source_env" | tail -1 | tr -d '\r')"
  [[ "$key" =~ ^base64:[A-Za-z0-9+/=]+$ || "$key" =~ ^[A-Za-z0-9]{32}$ ]] ||
    die "XBoard APP_KEY missing/invalid; encrypted data cannot safely be migrated"

  report="$INSTALL_DIR/backups/xboard-import/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p -m 700 "$report"
  chmod 700 "$report"
  printf 'preparing\n' > "$report/STATUS"
  sha256sum "$dump" > "$report/SOURCE.sha256"
  helper="$report/xboard-plan.py"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$DEPLOY_RAW_BASE/scripts/xboard-plan.py" -o "$helper" ||
      die "unable to download XBoard migration planner"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$helper" "$DEPLOY_RAW_BASE/scripts/xboard-plan.py" ||
      die "unable to download XBoard migration planner"
  else
    die "curl or wget is required to load the migration planner"
  fi
  python3 "$helper" --check-dump "$dump" ||
    die "dump preflight failed; destination is still empty"

  # Copy ONLY APP_KEY, preserving encrypted settings. No old APP_URL or secrets
  # other than the necessary encryption key are imported.
  tmp="$(mktemp "$INSTALL_DIR/.xboard-api-env.XXXXXXXX")"
  awk '
    NR == FNR { if ($0 ~ /^APP_KEY=/) {key=substr($0,9); sub(/\r$/, "", key)}; next }
    /^APP_KEY=/ {if (!written++) print "APP_KEY=" key; next}
    {print}
    END {if (!written) print "APP_KEY=" key}
  ' "$source_env" "$INSTALL_DIR/api.env" > "$tmp" ||
    { rm -f "$tmp"; die "could not preserve XBoard APP_KEY"; }
  chmod 600 "$tmp"
  mv "$tmp" "$INSTALL_DIR/api.env"

  log "Restoring trusted XBoard backup to the new EMPTY target DB..."
  docker compose run -T --rm --no-deps \
    -v "$dump:/tmp/xboard-import.sql.gz:ro" --entrypoint sh backup -ec '
      gzip -t /tmp/xboard-import.sql.gz
      gzip -dc /tmp/xboard-import.sql.gz |
        MYSQL_PWD="$DB_PASSWORD" mysql --binary-mode --default-character-set=utf8mb4 \
          --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USERNAME" --database="$DB_DATABASE"
    ' </dev/null ||
    die "restore failed: target is partial; discard isolated target and retry"
  printf 'restored\n' > "$report/STATUS"

  xboard_db_sql() {
    docker compose run -T --rm --no-deps --entrypoint sh backup -ec \
      'MYSQL_PWD="$DB_PASSWORD" exec mysql --batch --raw --skip-column-names --connect-timeout=10 --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USERNAME" --database="$DB_DATABASE" --execute="$1"' sh "$1" </dev/null
  }
  xboard_db_sql "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_TYPE='BASE TABLE' ORDER BY TABLE_NAME" > "$report/tables.txt" ||
    die "cannot inspect restored XBoard tables"
  xboard_db_sql "SELECT migration FROM migrations ORDER BY id" > "$report/history.txt" ||
    die "cannot inspect XBoard migration ledger"
  docker compose run -T --rm --no-deps --entrypoint sh txboard -ec \
    'for p in /www/database/migrations/*.php; do basename "$p" .php; done' \
    > "$report/native-migrations.txt" </dev/null ||
    die "cannot inspect native image migration catalog"
  python3 "$helper" --tables "$report/tables.txt" --history "$report/history.txt" \
    --native "$report/native-migrations.txt" --plan "$report/plan.json" \
    --sql "$report/convert.sql" ||
    die "XBoard version unsupported; target data preserved for diagnosis, no table renamed"

  before_users="$(xboard_db_sql 'SELECT id,email,password,balance,commission_balance,uuid,plan_id,expired_at,u,d,transfer_enable FROM v2_user ORDER BY id' | sha256sum | awk '{print $1}')" ||
    die "failed to snapshot XBoard user rows"
  before_orders="$(xboard_db_sql 'SELECT id,user_id,plan_id,trade_no,status,total_amount,paid_at FROM v2_order ORDER BY id' | sha256sum | awk '{print $1}')" ||
    die "failed to snapshot XBoard order rows"
  [[ -n "$before_users" && -n "$before_orders" ]] ||
    die "source row digests unavailable"

  printf 'converting-isolated-target\n' > "$report/STATUS"
  sql="$report/convert.sql"
  docker compose run -T --rm --no-deps \
    -v "$sql:/tmp/xboard-convert.sql:ro" --entrypoint sh backup -ec \
    'MYSQL_PWD="$DB_PASSWORD" exec mysql --batch --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USERNAME" --database="$DB_DATABASE" < /tmp/xboard-convert.sql' \
    </dev/null ||
    die "conversion failed; discard the isolated target and review $report"
  docker compose run -T --rm --no-deps --entrypoint php txboard \
    /www/artisan txboard:assert-native-schema --no-interaction </dev/null ||
    die "native schema guard rejected copied database"
  log "Applying remaining native migrations..."
  docker compose run -T --rm --no-deps -e CACHE_DRIVER=array \
    -e SETTING_CACHE_STORE=array -e QUEUE_CONNECTION=sync -e SESSION_DRIVER=array \
    --entrypoint php txboard /www/artisan migrate --force --no-interaction </dev/null ||
    die "native migrations failed; do not boot an unverified database"

  after_users="$(xboard_db_sql 'SELECT id,email,password,balance,commission_balance,uuid,plan_id,expired_at,u,d,transfer_enable FROM tx_user ORDER BY id' | sha256sum | awk '{print $1}')" ||
    die "failed to verify imported users"
  after_orders="$(xboard_db_sql 'SELECT id,user_id,plan_id,trade_no,status,total_amount,paid_at FROM tx_order ORDER BY id' | sha256sum | awk '{print $1}')" ||
    die "failed to verify imported orders"
  [[ "$after_users" == "$before_users" && "$after_orders" == "$before_orders" ]] ||
    die "user/order/financial row digests changed; TXBoard startup is blocked"
  orphaned="$(xboard_db_sql 'SELECT COUNT(*) FROM tx_order o LEFT JOIN tx_user u ON u.id=o.user_id WHERE u.id IS NULL')" ||
    die "cannot validate order owner references"
  [[ "$orphaned" == 0 ]] || die "import contains orphan orders"
  docker compose run -T --rm --no-deps --entrypoint php txboard \
    /www/artisan txboard:install-status --no-interaction </dev/null ||
    die "import has no valid administrator"
  local migration_status
  migration_status="$(docker compose run -T --rm --no-deps --entrypoint php txboard \
    /www/artisan migrate:status --no-interaction </dev/null)" ||
    die "cannot inspect Laravel migration status"
  if grep -Eiq '(^|[[:space:]])Pending([[:space:]]|$)' <<< "$migration_status"; then
    die "pending native migrations remain after import"
  fi
  printf 'verified\n' > "$report/STATUS"
  printf 'users_sha256=%s\norders_sha256=%s\n' "$after_users" "$after_orders" > "$report/VERIFICATION"
  chmod 600 "$report/VERIFICATION"
  log "XBoard import validated; review report: $report"
  log "Original XBoard database and SQL backup were not modified"
}
