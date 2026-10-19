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
if [ "${MOCK_MUTATE_FILE:-}" != '' ]; then
  printf 'changed during dump\n' >> "$MOCK_MUTATE_FILE"
fi
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
# Native snapshots must retain installed themes and plugin-owned assets too.
deployment="$work/deployment"
mkdir -p "$deployment/native" "$deployment/data/storage/theme/custom" "$deployment/data/plugins/example"
cp "$work/source/.env" "$deployment/api.env"
printf 'TXBOARD_IMAGE=sha256:fixture\n' > "$deployment/.env"
printf 'name: fixture\n' > "$deployment/compose.yaml"
for item in prepare.json runtime.env node-recipients.json signer.seed provider-ca.pem provider-client.pem provider-client.key; do
  printf 'fixture\n' > "$deployment/native/$item"
done
printf 'theme entry\n' > "$deployment/data/storage/theme/custom/index.html"
printf 'plugin state\n' > "$deployment/data/plugins/example/state.json"
export BACKUP_NATIVE_MODE=1 BACKUP_DEPLOYMENT_DIR="$deployment"
sh "$script" > "$work/native.log"
native_archive="$(find "$work/backups" -name native-deployment.tar.gz -print -quit)"
test -n "$native_archive"
tar -tzf "$native_archive" > "$work/members"
grep -Fxq 'data/storage/theme/custom/index.html' "$work/members"
grep -Fxq 'data/plugins/example/state.json' "$work/members"
rm -rf "$work/backups"/*

for item in data/storage/theme/custom/index.html data/plugins/example/state.json; do
  if MOCK_MUTATE_FILE="$deployment/$item" sh "$script" > "$work/native-mutation.log" 2>&1; then
    echo 'native backup incorrectly retained files changed during dump' >&2; exit 1
  fi
  test -z "$(find "$work/backups" -mindepth 1 -print -quit)"
done
for item in data/storage/theme/custom/link data/plugins/example/link; do
  ln -s "$work/source/.env" "$deployment/$item"
  if sh "$script" > "$work/native-symlink.log" 2>&1; then
    echo 'native backup incorrectly followed an asset symlink' >&2; exit 1
  fi
  test -z "$(find "$work/backups" -mindepth 1 -print -quit)"
  rm "$deployment/$item"
done
echo 'backup regression checks passed'
