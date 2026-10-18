#!/usr/bin/env bash
# Verify ANSI opt-outs and safe TTY loading without Docker or real deployments.
set -Eeuo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
source "$repo/lib/common.sh"

[[ -z "$(TERM=dumb ui_color cyan)" ]]
[[ -z "$(NO_COLOR=1 TERM=xterm ui_color red)" ]]
bash "$repo/txboard.sh" help > "$tmp/help"
grep -Fq 'Quick commands:' "$tmp/help"
if grep -q $'\033' "$tmp/help"; then echo 'ANSI leaked into non-TTY help' >&2; exit 1; fi
[[ "$(ui_run 'noninteractive' bash -c 'printf unchanged')" == unchanged ]]
if ui_run 'failing' bash -c 'exit 37' > /dev/null 2>&1; then
  echo 'failed process was swallowed' >&2; exit 1
else
  [[ "$?" == 37 ]]
fi

cat > "$tmp/interactive.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$UI_REPO/lib/common.sh"
source "$UI_REPO/lib/service.sh"
TXBOARD_INSTALL_DIR="$UI_TEST_DIR/instance"
mkdir -p "$TXBOARD_INSTALL_DIR"
ui_screen
ui_header 'TXBoard test center' 'Color and terminal output'
ui_section 'Main functions'
ui_item 1 'Start service' 'safe'
ui_item 0 'Return'
ui_footer
original_umask="$(umask)"
ui_run 'synthetic success' bash -c 'sleep 0.3; echo operation-complete'
[[ "$(umask)" == "$original_umask" ]]
if ui_run 'synthetic failure' bash -c 'echo operation-failed; exit 23'; then
  exit 91
else
  [[ "$?" == 23 ]]
fi
compose() {
  printf '%s\n' "$*" >> "$UI_TEST_DIR/compose-calls"
  [[ "$1" != restart ]] || return 37
}
: > "$UI_TEST_DIR/compose-calls"
if ui_run 'restart rejected' service_restart_locked; then
  exit 92
else
  [[ "$?" == 37 ]]
fi
! grep -q '^up ' "$UI_TEST_DIR/compose-calls"
printf 'untouched\n' > "$UI_TEST_DIR/protected-log"
chmod 644 "$UI_TEST_DIR/protected-log"
TXBOARD_INSTALL_DIR="$UI_TEST_DIR/unsafe-instance"
mkdir -p "$TXBOARD_INSTALL_DIR/backups/manager"
ln -sf "$UI_TEST_DIR/protected-log" "$TXBOARD_INSTALL_DIR/backups/manager/operations.log"
if ui_run 'unsafe log' bash -c 'echo should-not-run'; then exit 93; fi
[[ "$(cat "$UI_TEST_DIR/protected-log")" == untouched ]]
[[ "$(stat -c '%a' "$UI_TEST_DIR/protected-log")" == 644 ]]
SH
chmod 700 "$tmp/interactive.sh"
export UI_REPO="$repo" UI_TEST_DIR="$tmp"
env -u NO_COLOR TERM=xterm-256color script -q -e -c "bash '$tmp/interactive.sh'" "$tmp/colors" > /dev/null
grep -Fq 'TXBoard test center' "$tmp/colors"
grep -Fq 'synthetic success' "$tmp/colors"
grep -Fq 'synthetic failure' "$tmp/colors"
grep -q $'\033' "$tmp/colors"
log_file="$tmp/instance/backups/manager/operations.log"
[[ -f "$log_file" ]]
[[ "$(stat -c '%a' "$log_file")" == 600 ]]
[[ "$(stat -c '%a' "$(dirname "$log_file")")" == 700 ]]
grep -Fq 'operation-complete' "$log_file"
grep -Fq 'operation-failed' "$log_file"

env NO_COLOR=1 TERM=xterm-256color script -q -e -c "bash '$tmp/interactive.sh'" "$tmp/no-color" > /dev/null
if grep -Eq $'\033\[[0-9;]*m' "$tmp/no-color"; then
  echo 'NO_COLOR was ignored' >&2; exit 1
fi
echo 'colorful TTY menus, log capture, failure propagation and NO_COLOR: passed'
