#!/usr/bin/env bash
set -Eeuo pipefail
repo="$PWD"
tmp="$(mktemp -d)"
container="txboard-xboard-ci-$$"
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT

docker run -d --name "$container" -e MYSQL_ROOT_PASSWORD=ci-only mysql:8.4.11 >/dev/null
mysql_db() { docker exec -i -e MYSQL_PWD=ci-only "$container" mysql -uroot --batch --skip-column-names "$@"; }
for i in $(seq 1 60); do
  if docker exec -e MYSQL_PWD=ci-only "$container" mysqladmin --protocol=TCP -h127.0.0.1 -uroot ping --silent >/dev/null 2>&1; then break; fi
  sleep 2
done
docker exec -e MYSQL_PWD=ci-only "$container" mysqladmin --protocol=TCP -h127.0.0.1 -uroot ping --silent >/dev/null ||
  { echo "MySQL fixture failed to start" >&2; exit 1; }

mysql_db <<'SQL'
CREATE DATABASE txboard_import_ci CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE txboard_import_ci;
CREATE TABLE migrations (id INT PRIMARY KEY AUTO_INCREMENT, migration VARCHAR(255) NOT NULL, batch INT NOT NULL);
CREATE TABLE v2_user (id INT PRIMARY KEY, email VARCHAR(128), balance BIGINT, commission_balance BIGINT);
CREATE TABLE v2_settings (id INT PRIMARY KEY, name VARCHAR(128), value TEXT);
CREATE TABLE v2_plan (id INT PRIMARY KEY, name VARCHAR(128));
CREATE TABLE v2_order (id INT PRIMARY KEY, user_id INT, trade_no VARCHAR(100), total_amount BIGINT);
INSERT INTO v2_user VALUES (1,'user@example.com',120,9),(2,'admin@example.com',234,0);
INSERT INTO v2_plan VALUES (1,'Standard');
INSERT INTO v2_order VALUES (101,1,'trade-101',400);
INSERT INTO v2_settings VALUES (1,'site_name','Original');
INSERT INTO migrations (migration,batch) VALUES
  ('2023_03_19_000000_create_v2_tables',1),
  ('2023_08_14_221234_create_v2_settings_table',1),
  ('2025_01_04_optimize_plan_table',2);
SQL
mysql_db txboard_import_ci -e "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() ORDER BY TABLE_NAME" > "$tmp/tables"
mysql_db txboard_import_ci -e "SELECT migration FROM migrations ORDER BY id" > "$tmp/history"
printf '%s\n' 2023_03_19_000000_create_tx_tables \
  2023_08_14_221234_create_tx_settings_table \
  2025_01_04_optimize_plan_table > "$tmp/native"
python3 "$repo/scripts/xboard-plan.py" --tables "$tmp/tables" --history "$tmp/history" \
  --native "$tmp/native" --plan "$tmp/plan.json" --sql "$tmp/convert.sql"
before="$(mysql_db txboard_import_ci -e 'SELECT id,email,balance,commission_balance FROM v2_user ORDER BY id' | sha256sum | awk '{print $1}')"
mysql_db txboard_import_ci < "$tmp/convert.sql"
after="$(mysql_db txboard_import_ci -e 'SELECT id,email,balance,commission_balance FROM tx_user ORDER BY id' | sha256sum | awk '{print $1}')"
[[ "$before" == "$after" ]] || { echo "conversion changed financial rows" >&2; exit 1; }
[[ "$(mysql_db txboard_import_ci -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME LIKE 'v2\_%'")" == 0 ]] ||
  { echo "legacy tables remain" >&2; exit 1; }
[[ "$(mysql_db txboard_import_ci -e "SELECT COUNT(*) FROM migrations WHERE migration='2023_03_19_000000_create_tx_tables'")" == 1 ]] ||
  { echo "Laravel ledger not normalized" >&2; exit 1; }
[[ "$(mysql_db txboard_import_ci -e "SELECT COUNT(*) FROM tx_order WHERE trade_no='trade-101'")" == 1 ]] ||
  { echo "order lost during conversion" >&2; exit 1; }
echo 'Real MySQL table/history conversion smoke passed'
