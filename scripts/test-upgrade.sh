#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$MOCK_EVENTS"
line=" $* "
case "$line" in
  *" compose version "*|*" info "*) exit 0 ;;
  *" compose ps -q txboard "*) echo 'fake-container';;
  *" inspect fake-container "*) echo 'sha256:oldimage';;
  *" image inspect "*|*" tag "*|*" pull "*) ;;
  *" compose run "*"--entrypoint sh backup "*)
    if [[ "$MOCK_SCHEMA" == mixed ]]; then
      printf '25\t2\t1\t1\t1\t1\t1\t1\t1\n'
    elif [[ ( "$MOCK_SCHEMA" == native || -f "$MOCK_DIR/native-converted" ) && "$line" == *information_schema* ]]; then
      printf '0\t25\t0\t0\t0\t1\t1\t1\t1\n'
    elif [[ "$line" == *information_schema* ]]; then
      printf '25\t0\t1\t1\t1\t0\t0\t0\t1\n'
    else
      printf '5\t1000\t250\t4\t5000\n'
    fi ;;
  *" compose run "*"BACKUP_INTERVAL=0"*" backup "*)
    [[ "$MOCK_BACKUP_FAIL" != 1 ]] || exit 1
    stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    mkdir -p "$MOCK_DIR/backups/$stamp"
    cd "$MOCK_DIR/backups/$stamp"
    printf 'CREATE TABLE sample(id int);\n' | gzip -c > db.sql.gz
    printf 'APP_KEY=base64:mock-key\n' > env
    printf 'database=mock\n' > MANIFEST
    sha256sum db.sql.gz env > CHECKSUMS.sha256 ;;
  *" compose run "*"--entrypoint php txboard "*)
    if [[ "$line" == *" txboard:database-cutover "* ]]; then
      echo cutover-request >> "$MOCK_EVENTS"
      if [[ "$line" == *" --execute "* ]]; then
        touch "$MOCK_DIR/native-converted"
        echo cutover-executed >> "$MOCK_EVENTS"
      fi
    fi
    if [[ "$line" == *" migrate --force "* ]]; then
      echo 'migration-attempted' >> "$MOCK_EVENTS"
      [[ "$MOCK_MIGRATION_FAIL" != 1 ]] || exit 45
    fi
    if [[ "$line" == *" migrate:status "* ]]; then
      printf 'Migration ........ Ran\n'
    fi ;;
  *) ;;
esac
MOCK
chmod +x "$tmp/bin/docker"
cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
dest="$(printf '%s\n' "$@" | tail -1)"
if [[ "$*" == *"/backup.sh"* ]]; then
  cp "$MOCK_SAFE_BACKUP" "$dest"
else
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dest"
fi
MOCK
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH"
export MOCK_SAFE_BACKUP="$repo/backup.sh"

setup() {
  export MOCK_DIR="$tmp/$1" MOCK_EVENTS="$tmp/$1/events"
  mkdir -p "$MOCK_DIR/backups" "$MOCK_DIR/data/plugins" "$MOCK_DIR/data/storage/theme"
  printf 'TXBOARD_IMAGE=ghcr.io/anrcm0/txboard:latest\n' > "$MOCK_DIR/.env"
  printf 'APP_KEY=base64:mock-key\nTX_NATIVE_TABLES=false\n' > "$MOCK_DIR/api.env"
  printf 'services:\n  txboard:\n    image: mock\n' > "$MOCK_DIR/compose.yaml"
  printf '#!/bin/sh\n# no checksums in older deploy backup\n' > "$MOCK_DIR/backup.sh"
  printf 'plugin\n' > "$MOCK_DIR/data/plugins/p.txt"
  printf 'theme\n' > "$MOCK_DIR/data/storage/theme/t.txt"
  : > "$MOCK_EVENTS"
  export MOCK_SCHEMA=legacy MOCK_BACKUP_FAIL=0 MOCK_MIGRATION_FAIL=0
}
update() { TXBOARD_INSTALL_DIR="$MOCK_DIR" bash "$repo/update.sh" --yes --tag dev; }

setup success
update
grep -qx 'TXBOARD_IMAGE=ghcr.io/anrcm0/txboard:dev' "$MOCK_DIR/.env"
grep -Fq migration-attempted "$MOCK_EVENTS"
archive="$(find "$MOCK_DIR/backups" -mindepth 1 -maxdepth 1 -type d -print -quit)"
(cd "$archive" && sha256sum -c CHECKSUMS.sha256 >/dev/null && gzip -t plugins.tar.gz && gzip -t storage-theme.tar.gz)
test -f "$archive/deploy.env"
test -f "$archive/compose.yaml"

setup native
export MOCK_SCHEMA=native
sed -i 's/^TX_NATIVE_TABLES=false$/TX_NATIVE_TABLES=true/' "$MOCK_DIR/api.env"
update
grep -Fq migration-attempted "$MOCK_EVENTS"
grep -qx 'TX_NATIVE_TABLES=true' "$MOCK_DIR/api.env"
! grep -Fq 'txboard:database-cutover' "$MOCK_EVENTS"

setup native-cutover
plan="$MOCK_DIR/reviewed-plan.json"
printf '{"schemaVersion":1,"kind":"native-table-cutover-plan","executable":true,"requiresManualApproval":false,"blockers":[],"proposedRenames":[{"from":"v2_user","to":"tx_user"}]}\n' > "$plan"
if command -v script >/dev/null 2>&1; then
  printf "2\nREVIEWED\nRESTORED\n" | timeout 40s script -q -e -c "env TXBOARD_INSTALL_DIR=$MOCK_DIR bash $repo/update.sh --tag dev --cutover-plan $plan" /dev/null >"$tmp/cutover-success" 2>&1 || {
    tail -35 "$tmp/cutover-success" >&2; echo "mocked interactive cutover failed" >&2; exit 1;
  }
  grep -Fq cutover-executed "$MOCK_EVENTS"
  grep -qx "TX_NATIVE_TABLES=true" "$MOCK_DIR/api.env"
  grep -Fq "cutover" "$tmp/cutover-success"
fi

setup missing-cutover-plan
if command -v script >/dev/null 2>&1; then
  if printf "2\n" | timeout 20s script -q -e -c "env TXBOARD_INSTALL_DIR=$MOCK_DIR bash $repo/update.sh --tag dev --cutover-plan /nonexistent/not-approved.json" /dev/null >"$tmp/cutover-missing" 2>&1; then
    echo "missing reviewed plan was accepted" >&2; exit 1;
  fi
  ! grep -Fq "migration-attempted" "$MOCK_EVENTS"
fi

setup native-bad-flag
export MOCK_SCHEMA=native
if update >"$tmp/native-flag" 2>&1; then echo "native DB with legacy config accepted" >&2; exit 1; fi
! grep -Fq 'compose stop txboard' "$MOCK_EVENTS"

setup mixed
MOCK_SCHEMA=mixed
export MOCK_SCHEMA
if update >"$tmp/mixed" 2>&1; then echo "mixed schema accepted" >&2; exit 1; fi
! grep -Fq 'compose stop txboard' "$MOCK_EVENTS"

setup backup-fail
export MOCK_BACKUP_FAIL=1
if update >"$tmp/backup" 2>&1; then echo "missing backup accepted" >&2; exit 1; fi
! grep -Fq migration-attempted "$MOCK_EVENTS"
grep -Fq 'tag sha256:oldimage' "$MOCK_EVENTS"

setup migrate-fail
export MOCK_MIGRATION_FAIL=1
if update >"$tmp/migrate" 2>&1; then echo "migration failure accepted" >&2; exit 1; fi
grep -Fq migration-attempted "$MOCK_EVENTS"
! grep -Fq 'tag sha256:oldimage' "$MOCK_EVENTS"
! grep -Fq 'compose up -d' "$MOCK_EVENTS"

setup skip
if TXBOARD_INSTALL_DIR="$MOCK_DIR" bash "$repo/update.sh" --yes --skip-backup >"$tmp/skip" 2>&1; then
  echo "unsafe skip-backup accepted" >&2; exit 1
fi
! grep -Fq 'compose stop txboard' "$MOCK_EVENTS"
echo "TXBoard database upgrade state-machine tests passed"
