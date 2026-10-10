#!/usr/bin/env bash
set -euo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$MOCK_EVENTS"
case " $* " in
  *" compose version "*) exit 0 ;;
  *" ps -a --no-trunc --format "*) echo fake-container ;;
  *" inspect -f "*" fake-container "*) printf 'fake-container|/txboard-txboard-1|running|healthy|txboard|txboard|%s|%s/compose.yaml|ghcr.io/anrcm0/txboard:latest|sha256:oldimage\n' "$MOCK_DIR" "$MOCK_DIR" ;;
  *" compose ps -a -q txboard "*) echo fake-container ;;
  *" compose ps -q txboard "*) echo fake-container ;;
  *" inspect fake-container "*) echo sha256:oldimage ;;
  *" compose run "*"--entrypoint sh backup "*)
    if [[ "$*" == *information_schema* ]]; then
      case "$MOCK_SCHEMA" in
        native) printf '0\t8\t0\t0\t0\t1\t1\t1\t1\n' ;;
        legacy) printf '8\t0\t1\t1\t1\t0\t0\t0\t1\n' ;;
        mixed) printf '3\t4\t1\t1\t1\t1\t1\t1\t1\n' ;;
      esac
    else
      printf '3\t120\t9\t5\t400\n'
    fi
    ;;
  *" compose run "*"--entrypoint php txboard "*)
    if [[ "$*" == *" migrate --force "* ]]; then
      echo migration-attempted >> "$MOCK_EVENTS"
      [[ "${MOCK_MIGRATION_FAIL:-0}" != 1 ]] || exit 45
    fi
    if [[ "$*" == *" migrate:status "* ]]; then echo 'Migration ........ Ran'; fi
    ;;
  *BACKUP_INTERVAL=0*backup*)
    [[ "${MOCK_BACKUP_FAIL:-0}" != 1 ]] || exit 1
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$MOCK_DIR/backups/$stamp"
    cd "$MOCK_DIR/backups/$stamp"
    printf 'CREATE TABLE sample(id int);\n' | gzip -c > db.sql.gz
    printf 'APP_KEY=base64:mock-key\n' > env
    printf 'database=mock\n' > MANIFEST
    sha256sum db.sql.gz env > CHECKSUMS.sha256
    ;;
  *) : ;;
esac
MOCK
cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'/backup.sh'* ]]; then
  args=("$@"); cp "$MOCK_SAFE_BACKUP" "${args[${#args[@]}-1]}"
else
  exit 99
fi
MOCK
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" MOCK_SAFE_BACKUP="$repo/backup.sh"
setup() {
  export MOCK_DIR="$tmp/$1" MOCK_EVENTS="$tmp/$1/events"
  mkdir -p "$MOCK_DIR/backups" "$MOCK_DIR/data/plugins" "$MOCK_DIR/data/storage/theme"
  printf 'TXBOARD_IMAGE=ghcr.io/anrcm0/txboard:latest\n' > "$MOCK_DIR/.env"
  printf 'APP_KEY=base64:mock-key\n' > "$MOCK_DIR/api.env"
  printf 'services:\n  txboard:\n    image: mock\n' > "$MOCK_DIR/compose.yaml"
  printf '#!/bin/sh\n# old backup helper\n' > "$MOCK_DIR/backup.sh"
  printf 'plugin\n' > "$MOCK_DIR/data/plugins/p.txt"
  printf 'theme\n' > "$MOCK_DIR/data/storage/theme/t.txt"
  : > "$MOCK_EVENTS"
  export MOCK_SCHEMA=native MOCK_BACKUP_FAIL=0 MOCK_MIGRATION_FAIL=0
}
update() { TXBOARD_INSTALL_DIR="$MOCK_DIR" bash "$repo/update.sh" --yes --tag dev; }
setup native
update > "$tmp/native.log" 2>&1 || {
  tail -50 "$tmp/native.log"
  echo "Mock Docker events:" >&2
  cat "$MOCK_EVENTS" >&2
  echo "PATH=$PATH" >&2
  command -v docker >&2
  "$tmp/bin/docker" compose version || true
  exit 1
}
grep -Fxq 'TXBOARD_IMAGE=ghcr.io/anrcm0/txboard:dev' "$MOCK_DIR/.env"
grep -Fq migration-attempted "$MOCK_EVENTS"
test -s "$MOCK_DIR/api.env"
! grep -q TX_NATIVE_TABLES "$MOCK_DIR/api.env"
archive="$(find "$MOCK_DIR/backups" -mindepth 1 -maxdepth 1 -type d -print -quit)"
(cd "$archive" && sha256sum -c CHECKSUMS.sha256 >/dev/null)
setup legacy
export MOCK_SCHEMA=legacy
if update > "$tmp/legacy.log" 2>&1; then echo "legacy database accepted" >&2; exit 1; fi
grep -q 'legacy v2_\* schema detected' "$tmp/legacy.log"
! grep -q ' compose stop txboard' "$MOCK_EVENTS"
! grep -q migration-attempted "$MOCK_EVENTS"
setup mixed
export MOCK_SCHEMA=mixed
if update > "$tmp/mixed.log" 2>&1; then echo "mixed database accepted" >&2; exit 1; fi
! grep -q ' compose stop txboard' "$MOCK_EVENTS"
setup backup-failure
export MOCK_BACKUP_FAIL=1
if update > "$tmp/backup-failure.log" 2>&1; then echo "backup failure accepted" >&2; exit 1; fi
! grep -q migration-attempted "$MOCK_EVENTS"
setup migration-failure
export MOCK_MIGRATION_FAIL=1
if update > "$tmp/migration-failure.log" 2>&1; then echo "migration failure accepted" >&2; exit 1; fi
grep -q migration-attempted "$MOCK_EVENTS"
! grep -q ' compose up -d' "$MOCK_EVENTS"
setup retired-cutover
if TXBOARD_INSTALL_DIR="$MOCK_DIR" bash "$repo/update.sh" --cutover-plan /tmp/invalid >"$tmp/retired.log" 2>&1; then
  echo "retired in-place cutover accepted" >&2; exit 1
fi
! grep -q ' compose stop txboard' "$MOCK_EVENTS"
echo 'Native-only updater tests passed'
