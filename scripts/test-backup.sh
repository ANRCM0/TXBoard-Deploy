#!/usr/bin/env bash
# Regression: an unsuccessful mysqldump must never produce a retained archive.
set -euo pipefail

script="${1:?usage: test-backup.sh path/to/backup.sh}"
test -f "$script"
script="$(realpath "$script")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/backups" "$work/source/storage/app"
printf 'APP_KEY=base64:regression-test-key\n' > "$work/source/.env"
printf 'upload\n' > "$work/source/storage/app/example.txt"

cat > "$work/bin/mysqldump" <<'SH'
#!/bin/sh
printf '%s\n' 'CREATE TABLE backup_regression (id int);'
if [ "${MOCK_DUMP_FAIL:-0}" = 1 ]; then
  printf '%s\n' 'simulated mysqldump failure after partial output' >&2
  exit 27
fi
SH
chmod +x "$work/bin/mysqldump"

export PATH="$work/bin:$PATH"
export DB_HOST=database DB_PORT=3306 DB_DATABASE=txboard DB_USERNAME=test DB_PASSWORD=dummy
export BACKUP_DIR="$work/backups" BACKUP_SOURCE_DIR="$work/source"
export BACKUP_INTERVAL=0 BACKUP_RETENTION=7

# A good dump produces a gzip archive containing the database and key.
sh "$script" > "$work/success.log"
archive="$(find "$work/backups" -name db.sql.gz -print -quit)"
test -n "$archive"
gzip -cd "$archive" | grep -Fq 'CREATE TABLE backup_regression'
test -f "$(dirname "$archive")/env"
test -f "$(dirname "$archive")/storage-app.tar.gz"
test ! -e "$(dirname "$archive")/db.sql"

# A broken mysqldump may have emitted partial SQL: do not call that a backup.
rm -rf "$work/backups"/*
if MOCK_DUMP_FAIL=1 sh "$script" > "$work/failure.log" 2>&1; then
  echo 'backup incorrectly succeeded after mysqldump failed' >&2
  exit 1
fi
if find "$work/backups" -mindepth 1 -print -quit | grep -q .; then
  echo 'partial backup was incorrectly retained' >&2
  exit 1
fi
echo 'backup regression checks passed'
