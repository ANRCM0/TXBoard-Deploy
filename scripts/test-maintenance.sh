#!/usr/bin/env bash
set -euo pipefail
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/install" "$tmp/commands"
printf 'TXBOARD_ADMIN_EMAIL=admin@example.com\n' > "$tmp/install/.env"
printf 'APP_URL=https://panel.example.com\n' > "$tmp/install/api.env"
printf 'services:\n  txboard: {}\n' > "$tmp/install/compose.yaml"
cp "$repo/txboard.sh" "$tmp/install/txboard.sh"
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$MOCK_DOCKER_LOG"
case " $* " in
  *" compose version "*|*" info "*) exit 0 ;;
  *" compose ps --status running -q txboard "*) echo fake-container ;;
  *" compose exec -T txboard php artisan reset:password admin@example.com --no-interaction "*) printf '新密码为：mock-password\n' ;;
  *" compose exec -T txboard php artisan txboard:install-status --no-interaction "*|
  *" compose exec -T txboard php artisan config:clear --no-interaction "*|
  *" compose exec -T txboard php artisan route:clear --no-interaction "*|
  *" compose exec -T txboard php artisan view:clear --no-interaction "*|
  *" compose exec -T txboard php artisan horizon:terminate --no-interaction "*) exit 0 ;;
  *) echo "unexpected docker call: $*" >&2; exit 99 ;;
esac
MOCK
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH" MOCK_DOCKER_LOG="$tmp/docker.log"
: > "$MOCK_DOCKER_LOG"

bash "$repo/txboard.sh" --dir "$tmp/install" help | grep -Fq 'admin-reset-password'
bash "$repo/txboard.sh" --dir "$tmp/install" help | grep -Fq 'repair-command'
bash "$repo/txboard.sh" --dir "$tmp/install" install-status
bash "$repo/txboard.sh" --dir "$tmp/install" clear-runtime-cache
bash "$repo/txboard.sh" --dir "$tmp/install" restart-horizon
grep -Fq 'compose exec -T txboard php artisan horizon:terminate --no-interaction' "$MOCK_DOCKER_LOG"
! grep -Eq 'cache:clear|optimize:clear|down -v|volume rm' "$MOCK_DOCKER_LOG"

if bash "$repo/txboard.sh" --dir "$tmp/install" admin-reset-password > "$tmp/no-tty" 2>&1; then
  echo 'password reset accepted non-interactive execution' >&2; exit 1
fi
! grep -Fq 'reset:password' "$MOCK_DOCKER_LOG"

if command -v script >/dev/null 2>&1; then
  printf 'Y\n' | script -qec "bash '$repo/txboard.sh' --dir '$tmp/install' admin-reset-password" /dev/null > "$tmp/tty.log"
  grep -Fq '新密码为：mock-password' "$tmp/tty.log"
  grep -Fq 'compose exec -T txboard php artisan reset:password admin@example.com --no-interaction' "$MOCK_DOCKER_LOG"
  n="$(grep -c 'reset:password' "$MOCK_DOCKER_LOG")"
  printf 'N\n' | script -qec "bash '$repo/txboard.sh' --dir '$tmp/install' admin-reset-password" /dev/null > "$tmp/cancel.log"
  test "$(grep -c 'reset:password' "$MOCK_DOCKER_LOG")" = "$n"
  if printf 'Y\n' | script -qec "bash '$repo/txboard.sh' --dir '$tmp/install' admin-reset-password invalid" /dev/null > "$tmp/invalid.log" 2>&1; then
    echo 'invalid email accepted' >&2; exit 1
  fi
  test "$(grep -c 'reset:password' "$MOCK_DOCKER_LOG")" = "$n"
fi

TXBOARD_COMMAND_DIR="$tmp/commands" bash "$repo/txboard.sh" --dir "$tmp/install" repair-command
test "$(readlink "$tmp/commands/txboard")" = "$tmp/install/txboard.sh"
rm "$tmp/commands/txboard"
printf 'other\n' > "$tmp/commands/txboard"
if TXBOARD_COMMAND_DIR="$tmp/commands" bash "$repo/txboard.sh" --dir "$tmp/install" repair-command 2>"$tmp/refuse.log"; then
  echo 'repair-command overwrote regular file' >&2; exit 1
fi
grep -Fq 'refusing to overwrite a non-symlink' "$tmp/refuse.log"
cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
url="" dest=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) dest="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
[[ "$url" == mock://deploy/* && -n "$dest" ]] || exit 99
cp "$TEST_REPO/${url#mock://deploy/}" "$dest"
MOCK
chmod +x "$tmp/bin/curl"
export TEST_REPO="$repo"
TXBOARD_DEPLOY_RAW_BASE=mock://deploy bash "$repo/update.sh" --dir "$tmp/install" --tools-only
bash "$tmp/install/txboard.sh" --dir "$tmp/install" help | grep -Fq 'refresh-manager'
! grep -Eq 'compose (stop|up|down|run)| volume rm | pull ' "$MOCK_DOCKER_LOG"
echo 'Administrator recovery and maintenance commands: passed'
