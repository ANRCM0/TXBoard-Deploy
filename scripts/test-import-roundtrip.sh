#!/usr/bin/env bash
# Complete Docker/MySQL import smoke using a disposable XBoard-shaped fixture
# derived from a newly installed native TXBoard database.
set -Eeuo pipefail
repo="$PWD"
dir="/tmp/txboard-deploy-smoke"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
[[ -f "$dir/compose.yaml" ]] || { echo 'fresh smoke must run first' >&2; exit 1; }
cd "$dir"
docker compose exec -T database sh -ec \
  'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump --single-transaction --quick --set-gtid-purged=OFF --no-tablespaces -uroot "$MYSQL_DATABASE"' \
  > "$scratch/native.sql"
cp api.env "$scratch/xboard.env"
chmod 600 "$scratch/xboard.env"
python3 - "$scratch/native.sql" "$scratch/xboard.sql.gz" <<'PY'
import gzip, sys
raw = open(sys.argv[1], 'rb').read().replace(b'tx_', b'v2_')
with gzip.open(sys.argv[2], 'wb') as output:
    output.write(raw)
PY
python3 "$repo/scripts/xboard-plan.py" --check-dump "$scratch/xboard.sql.gz"
docker compose down -v --remove-orphans
cd "$repo"
rm -rf "$dir"
bash "$repo/install.sh" --yes --dir "$dir" \
  --tag "$TXBOARD_IMPORT_TEST_TAG" \
  --email smoke@example.com --mode http --public-host 127.0.0.1 --http-port 18081 \
  --install-type xboard-import --xboard-dump "$scratch/xboard.sql.gz" \
  --xboard-env "$scratch/xboard.env"
cd "$dir"
docker compose exec -T txboard php artisan txboard:install-status --no-interaction
docker compose exec -T database sh -ec \
  'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot "$MYSQL_DATABASE" -NBe "SELECT COUNT(*) FROM tx_user WHERE is_admin=1"' \
  | grep -qx '1'
find backups/xboard-import -name STATUS -exec grep -lx verified '{}' ';' | grep -q .
echo 'Full isolated XBoard-style backup import smoke passed'
