#!/usr/bin/env bash
# Installer regression tests: ordering and destructive-operation staging.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

python3 - "$repo/install.sh" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
def at(needle):
    assert needle in s, 'missing installer step: '+needle
    return s.index(needle)
# Always discover before new-install prompts, admin email or database setup.
assert at('txboard_detect_scan "$INSTALL_DIR" || die "Docker service discovery failed"') < at('INSTALL_DIR="$(prompt "Installation directory" "$INSTALL_DIR")"')
assert at('INSTALL_DIR="$(prompt "Installation directory" "$INSTALL_DIR")"') < at('if [[ -z "$MODE" ]]; then')
assert at('txboard_guard_install "$INSTALL_DIR"') < at('if [[ -z "$MODE" ]]; then')
assert at('if [[ -z "$MODE" ]]; then') < at('ADMIN_EMAIL="$(prompt "Administrator email"')
assert at('ADMIN_EMAIL="$(prompt "Administrator email"') < at('configure_database\n')
assert at('confirm "确认以上配置并开始安装？"') < at('if install_dir_has_content; then\n  clean_existing_install_dir\nfi')
assert at('confirm "Continue installation?"') < at('docker volume rm "$LOCAL_DB_VOLUME"')
assert at('verify_database_connectivity\nverify_database_empty_for_install') < at('docker compose up -d --remove-orphans txboard')
assert 'docker compose down --remove-orphans </dev/null' not in s
print('installer ordering and deferred destructive actions: passed')
PY

mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$MOCK_DOCKER_LOG"
case " $* " in
  *" volume inspect "*) exit 0 ;;
  *" volume rm "*) exit 0 ;;
  *" compose run "*"--entrypoint sh backup "*)
    [[ "$MOCK_TABLES" != fail ]] || exit 55
    printf '%s\n' "$MOCK_TABLES" ;;
  *) echo "unexpected docker mock call: $*" >&2; exit 99 ;;
esac
MOCK
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH" MOCK_DOCKER_LOG="$tmp/docker.log"
: > "$MOCK_DOCKER_LOG"

# DB local old-volume removal must be approved/scheduled, not immediate.
(
  set -e
  source "$repo/lib/install-database.sh"
  die() { echo "$*" >&2; exit 1; }
  warn() { :; }
  log() { :; }
  random_hex() { printf 'test-secret'; }
  DB_MODE=local
  DB_HOST="" DB_PORT=3306 DB_DATABASE=txboard DB_USERNAME=txboard
  DB_PASSWORD=existing DB_ROOT_PASSWORD=existing
  ASSUME_YES=1 RESET_LOCAL_DB=1 RENDER_ONLY=0
  LOCAL_DB_VOLUME=txboard_database-data
  LOCAL_DB_RESET_PENDING=0
  configure_database
  [[ "$LOCAL_DB_RESET_PENDING" == 1 ]]
)
if grep -Fq 'volume rm ' "$MOCK_DOCKER_LOG"; then
  echo "managed MySQL volume was removed before install confirmation" >&2
  exit 1
fi

# Explicit query returns empty, populated, and unknown (error) results.
cat > "$tmp/test-inventory.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$TEST_REPO/lib/install-database.sh"
die() { echo "$*" >&2; exit 1; }
log() { :; }
DB_DATABASE=txboard
verify_database_empty_for_install
SH
chmod +x "$tmp/test-inventory.sh"
export TEST_REPO="$repo"
MOCK_TABLES=0 "$tmp/test-inventory.sh"
if MOCK_TABLES=3 "$tmp/test-inventory.sh" >"$tmp/populated" 2>&1; then
  echo 'populated database accepted as new installation' >&2
  exit 1
fi
grep -Fq 'contains 3 existing table(s)' "$tmp/populated"
if MOCK_TABLES=fail "$tmp/test-inventory.sh" >"$tmp/error" 2>&1; then
  echo 'unknown database status accepted as empty' >&2
  exit 1
fi
echo 'installer database inventory and reset deferral: passed'
