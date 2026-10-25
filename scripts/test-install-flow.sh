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
assert at('txboard_detect_scan "$INSTALL_DIR" || die "Docker service discovery failed"') < at('INSTALL_DIR="$(prompt "安装目录" "$INSTALL_DIR")"')
assert at('INSTALL_DIR="$(prompt "安装目录" "$INSTALL_DIR")"') < at('if [[ -z "$MODE" ]]; then')
assert at('txboard_guard_install "$INSTALL_DIR"') < at('if [[ -z "$MODE" ]]; then')
assert at('if [[ -z "$MODE" ]]; then') < at('ADMIN_EMAIL="$(prompt "管理员邮箱"')
assert at('ADMIN_EMAIL="$(prompt "管理员邮箱"') < at('configure_database\n')
assert at('confirm "确认以上配置并开始安装？"') < at('if install_dir_has_content; then\n  clean_existing_install_dir\nfi')
assert at('confirm "确认以上配置并开始安装？"') < at('docker volume rm "$LOCAL_DB_VOLUME"')
assert at('verify_database_connectivity\nverify_database_empty_for_install') < at('docker compose up -d --remove-orphans txboard')
assert at('confirm "确认以上配置并开始安装？"') < at('txboard_auto_backup_xboard_source "$XBOARD_SOURCE_CONTAINER" "$XBOARD_SOURCE_DATABASE"')
assert at('txboard_auto_backup_xboard_source "$XBOARD_SOURCE_CONTAINER" "$XBOARD_SOURCE_DATABASE"') < at('if install_dir_has_content; then\n  clean_existing_install_dir\nfi')
assert at('confirm "确认以上配置并开始安装？"') < at('archive_orphan_install_dir\nfi')
assert at('archive_orphan_install_dir\nfi') < at('if install_dir_has_content; then\n  clean_existing_install_dir\nfi')
assert at('txboard_guard_install "$INSTALL_DIR" "$ARCHIVE_ORPHAN_DIR"') < at('configure_database\n')
assert 'mv -T -- "$INSTALL_DIR" "$archive_root/deployment"' in s
assert 'docker compose down --remove-orphans </dev/null' not in s
assert at('\ninstall_deploy_tools || die ') < at('install_progress_step "拉取 TXBoard 与依赖镜像"')
assert '$APP_URL/admin/' not in s
assert 'Admin entry: $ADMIN_ENTRY_COMMAND' in s
print('installer ordering and deferred destructive actions: passed')
PY

# A failed toolkit download must preserve every previously installed tool.
(
  INSTALL_DIR="$tmp/toolkit"
  NATIVE_CONFIG_DIR=""
  DEPLOY_RAW_BASE=mock://deploy
  INSTALLER_SOURCE_DIR="$tmp/offline-source"
  TXBOARD_COMMAND_DIR="$tmp/commands"
  mkdir -p "$INSTALL_DIR/lib" "$tmp/tool-bin" "$TXBOARD_COMMAND_DIR" "$INSTALLER_SOURCE_DIR"
  printf 'original-manager\n' > "$INSTALL_DIR/txboard.sh"
  printf 'original-module\n' > "$INSTALL_DIR/lib/common.sh"
  printf 'unrelated-command\n' > "$TXBOARD_COMMAND_DIR/txboard"
  export TEST_TOOLKIT_REPO="$repo" TEST_TOOLKIT_FAIL=lib/diagnose.sh
  cat > "$tmp/tool-bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
url="" dest=""
while (($#)); do
  case "$1" in -o) dest="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
relative="${url#mock://deploy/}"
[[ "$relative" != "${TEST_TOOLKIT_FAIL:-}" ]] || exit 42
cp -- "$TEST_TOOLKIT_REPO/$relative" "$dest"
CURL
  chmod +x "$tmp/tool-bin/curl"
  export PATH="$tmp/tool-bin:$PATH"
  warn() { printf '%s\n' "$*" >&2; }
  die() { printf '%s\n' "$*" >&2; return 1; }
  source <(awk '/^install_deploy_tools\(\) \{/{reading=1} reading{print} reading && /^\}$/ {exit}' "$repo/install.sh")
  if install_deploy_tools; then echo 'partial toolkit was accepted' >&2; exit 1; fi
  grep -Fxq original-manager "$INSTALL_DIR/txboard.sh"
  grep -Fxq original-module "$INSTALL_DIR/lib/common.sh"
  test ! -f "$INSTALL_DIR/scripts/core-diagnostics.py"
  export TEST_TOOLKIT_FAIL=""
  install_deploy_tools
  bash -n "$INSTALL_DIR/txboard.sh"
  test -f "$INSTALL_DIR/scripts/core-diagnostics.py"
  grep -Fxq unrelated-command "$TXBOARD_COMMAND_DIR/txboard"
  # A relative invocation must continue to use its reviewed local checkout after chdir.
  INSTALLER_SOURCE_DIR="$repo"
  export TEST_TOOLKIT_FAIL=txboard.sh
  cd "$INSTALL_DIR"
  install_deploy_tools
  test -f "$INSTALL_DIR/scripts/core-diagnostics.py"
)

# Exercise the progress wrapper without starting real Docker. A failing step
# must fail closed and preserve diagnostics; completion never advances on error.
(
  export INSTALL_LOG_FILE="$tmp/progress.log" INSTALL_VERBOSE=true TERM=dumb
  INSTALL_PROGRESS_TOTAL=2
  INSTALL_PROGRESS_DONE=0
  log() { printf '%s\n' "$*"; }
  warn() { printf '%s\n' "$*" >&2; }
  # The standalone progress function now reads colors from the install wizard.
  install_ui_color() { :; }
  source <(awk '/^install_progress_step\(\) \{/{reading=1} reading{print} reading && /^\}$/ {exit}' "$repo/install.sh")
  install_progress_step "testing successful stage" bash -c 'echo safe-output' >"$tmp/progress.out" 2>&1
  [[ "$INSTALL_PROGRESS_DONE" == 1 ]]
  grep -Fq 'safe-output' "$INSTALL_LOG_FILE"
  grep -Fq '[1/2]' "$tmp/progress.out"
  if install_progress_step "testing failed stage" bash -c 'echo intentional-error >&2; exit 23' >"$tmp/progress.failed" 2>&1; then
    echo "progress wrapper masked a failed command" >&2
    exit 1
  else
    [[ "$?" == 23 ]] || { echo "progress wrapper changed failing exit status" >&2; exit 1; }
  fi
  [[ "$INSTALL_PROGRESS_DONE" == 1 ]] || { echo "failed progress stage advanced the progress bar" >&2; exit 1; }
  grep -Fq 'intentional-error' "$INSTALL_LOG_FILE"
  grep -Fq '完整日志：' "$tmp/progress.failed"
)
echo 'installer stage progress and error log preservation: passed'

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

# Retired switches fail before service discovery or installation side effects.
for retired_option in --enable-mcp --disable-mcp; do
  if bash "$repo/install.sh" "$retired_option" >"$tmp/retired-option.log" 2>&1; then
    echo "retired MCP option was accepted" >&2; exit 1
  fi
  grep -Fq 'MCP has been retired' "$tmp/retired-option.log"
  [[ ! -s "$MOCK_DOCKER_LOG" ]] || { echo 'retired option called Docker' >&2; exit 1; }
done
echo 'retired MCP switches rejected before service discovery: passed'

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

# A socket-only initialization server must never satisfy the host-container
# readiness check. Exercise the actual helper across shutdown/authentication
# failure and final restart; sleep is replaced only in this synthetic fixture.
(
  set -euo pipefail
  source "$repo/lib/install-database.sh"
  probe_log="$tmp/readiness.log"
  : > "$probe_log"
  sleep() { :; }
  mysql_container_exec_root() {
    [[ "$1" == fixture && "$2" == fixture-password ]]
    [[ "$3" == *'@@GLOBAL.skip_networking'* ]]
    printf 'probe\n' >> "$probe_log"
    case "$(wc -l < "$probe_log" | tr -d '[:space:]')" in
      1) printf 'readiness\ntxboard_mysql_bootstrap\n' ;;
      2) return 1 ;;
      3) printf 'readiness\ntxboard_mysql_ready\n' ;;
      *) echo 'unexpected extra readiness probe' >&2; return 99 ;;
    esac
  }
  wait_mysql_container_admin fixture fixture-password
  [[ "$(wc -l < "$probe_log" | tr -d '[:space:]')" == 3 ]]

  : > "$probe_log"
  mysql_container_exec_root() {
    printf 'probe\n' >> "$probe_log"
    printf 'readiness\ntxboard_mysql_bootstrap\n'
  }
  if wait_mysql_container_admin fixture fixture-password; then
    echo 'socket-only bootstrap server accepted as ready' >&2
    exit 1
  fi
  [[ "$(wc -l < "$probe_log" | tr -d '[:space:]')" == 30 ]]

  mysql_container_exec_root() { printf 'malformed-readiness\n'; }
  if wait_mysql_container_admin fixture fixture-password; then
    echo 'unknown readiness result accepted' >&2
    exit 1
  fi
)
echo 'host MySQL bootstrap/restart readiness: passed'
