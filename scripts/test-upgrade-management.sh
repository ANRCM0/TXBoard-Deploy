#!/usr/bin/env bash
set -euo pipefail
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/install" "$tmp/bin"
printf 'TXBOARD_IMAGE=ghcr.io/anrcm0/txboard:latest\nTXBOARD_BACKUP_RETENTION=2\n' > "$tmp/install/.env"
printf 'APP_KEY=fixture\n' > "$tmp/install/api.env"
printf 'services: {}\n' > "$tmp/install/compose.yaml"
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_EVENTS"
exit 0
MOCK
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH" MOCK_EVENTS="$tmp/events"
: > "$MOCK_EVENTS"
printf '{"checkpoint_version":1,"old_image_allowed":false}\n' > "$tmp/install/.upgrade-in-progress"
for command in start restart restore backup uninstall; do
  if bash "$repo/txboard.sh" --dir "$tmp/install" "$command" >"$tmp/$command.log" 2>&1; then
    echo "unfinished upgrade allowed $command" >&2; exit 1
  fi
  grep -q 'unfinished durable upgrade' "$tmp/$command.log"
done
retention() {
  bash -c 'export TXBOARD_INSTALL_DIR="$2"; source "$1/lib/common.sh"; source "$1/lib/backup.sh"; backup_set_retention 1' txboard-retention-test "$repo" "$tmp/install"
}
if retention >"$tmp/retention.log" 2>&1; then
  echo 'retention update bypassed durable backup guard' >&2; exit 1
fi
grep -q 'unfinished durable upgrade' "$tmp/retention.log"
grep -Fxq 'TXBOARD_BACKUP_RETENTION=2' "$tmp/install/.env"
if bash "$repo/update.sh" --dir "$tmp/install" --yes >"$tmp/update.log" 2>&1; then
  echo 'legacy updater accepted unfinished upgrade' >&2; exit 1
fi
grep -q 'unfinished durable upgrade' "$tmp/update.log"
if bash "$repo/update.sh" --dir "$tmp/install" --tools-only >"$tmp/refresh.log" 2>&1; then
  echo 'tool refresh accepted unfinished upgrade' >&2; exit 1
fi
grep -q 'unfinished durable upgrade' "$tmp/refresh.log"
! grep -Eq 'compose (up|restart|run|down)|docker pull|migrate|DROP DATABASE' "$MOCK_EVENTS"
rm -f -- "$tmp/install/.upgrade-in-progress"
(
  exec 9>"$tmp/install/.upgrade.lock"
  flock -n 9
  if bash "$repo/txboard.sh" --dir "$tmp/install" start >"$tmp/locked.log" 2>&1; then
    echo 'manager bypassed same installation flock' >&2; exit 1
  fi
  grep -q 'holds the lock' "$tmp/locked.log"
  if retention >"$tmp/retention-locked.log" 2>&1; then
    echo 'retention update bypassed installation flock' >&2; exit 1
  fi
  grep -q 'holds the lock' "$tmp/retention-locked.log"
  if bash "$repo/txboard.sh" --dir "$tmp/install" backup >"$tmp/backup-locked.log" 2>&1; then
    echo 'backup creation bypassed installation flock' >&2; exit 1
  fi
  grep -q 'holds the lock' "$tmp/backup-locked.log"
)
bash "$repo/txboard.sh" --dir "$tmp/install" start
grep -Fq 'compose up -d --remove-orphans' "$MOCK_EVENTS"
bash "$repo/txboard.sh" --dir "$tmp/install" backup
grep -Fq 'compose run -T --rm -e BACKUP_INTERVAL=0 backup' "$MOCK_EVENTS"
retention
grep -Fxq 'TXBOARD_BACKUP_RETENTION=1' "$tmp/install/.env"
echo 'Durable upgrade management interlocks passed'
