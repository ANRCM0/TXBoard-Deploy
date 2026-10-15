#!/usr/bin/env bash
# Verify every restore-sensitive entry point returns its guard failure even when
# its caller disables errexit by using the entry point as an if condition.
set -euo pipefail
ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export INSTALL_DIR="$TMP/node" APP_NAME=tx-node-restore-guard-test
mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/backups"
printf '%s\n' 'config sentinel: private synthetic fixture' > "$INSTALL_DIR/config.yml"
printf '%s\n' 'compose sentinel: private synthetic fixture' > "$INSTALL_DIR/docker-compose.yml"
printf '%s\n' 'persistent sentinel' > "$INSTALL_DIR/data/sentinel"
cp "$INSTALL_DIR/config.yml" "$TMP/config.expected"
cp "$INSTALL_DIR/docker-compose.yml" "$TMP/compose.expected"
cp "$INSTALL_DIR/data/sentinel" "$TMP/data.expected"
source "$ROOT/deploy.sh"

if ! declare -F require_runtime_restore_clear >/dev/null; then
  echo 'runtime restore guard function is missing' >&2
  exit 1
fi

# These handlers can also be reached directly from interactive menus, helper
# functions or the host-side update bridge. Checking only main() is insufficient.
# Argument parsing is immaterial: an interrupted restore blocks these mutations.
guarded_functions=(
  reset_container
  mig_write_and_start
  do_migrate_legacy
  write_config_files
  do_install
  guarded_compose_start
  do_start
  do_restart
  perform_docker_upgrade
  do_remote_upgrade_apply
  do_channel
  do_upgrade
  do_reconfigure
  audit_write
  do_backup
  do_restore
  do_runtime_backup
  do_runtime_restore
  do_backup_full_guard_test
  do_restore_full_guard_test
  restart_after_instance_change
  do_add_panel_instance
  do_install_isolated
  do_add_node
  do_remove_node
  do_machine_mode
  do_uninstall
  do_purge
)

do_backup_full_guard_test() { do_backup --full "$TMP/full.tar"; }
do_restore_full_guard_test() { do_restore --full "$TMP/full.tar"; }

for target in "${guarded_functions[@]}"; do
  if ! declare -F "$target" >/dev/null; then
    printf 'restore-sensitive function is missing: %s\n' "$target" >&2
    exit 1
  fi
  : > "$TMP/guard.calls"
  : > "$TMP/effects"
  # A separate subshell prevents the mocks or a handler-local state change from
  # affecting another case. The if deliberately suppresses implicit set -e exits.
  if (
    require_runtime_restore_clear() {
      printf 'refused\n' >> "$TMP/guard.calls"
      return 77
    }
    unexpected_effect() {
      printf '%s\n' "$1" >> "$TMP/effects"
      return 92
    }
    docker() { unexpected_effect docker; }
    dc() { unexpected_effect compose; }
    systemctl() { unexpected_effect systemctl; }
    curl() { unexpected_effect curl; }
    wget() { unexpected_effect wget; }
    rm() { unexpected_effect rm; }
    mv() { unexpected_effect mv; }
    cp() { unexpected_effect cp; }
    mkdir() { unexpected_effect mkdir; }
    chmod() { unexpected_effect chmod; }
    chown() { unexpected_effect chown; }
    ln() { unexpected_effect ln; }
    tar() { unexpected_effect tar; }
    tee() { unexpected_effect tee; }
    read() { unexpected_effect read; }
    confirm() { unexpected_effect confirm; }
    confirm_typed() { unexpected_effect confirm_typed; }
    sleep() { unexpected_effect sleep; }
    case "$target" in
      do_channel) "$target" stable ;;
      do_backup|do_restore|do_runtime_backup) "$target" ;;
      do_runtime_restore) "$target" "$TMP/full.tar" ;;
      *) "$target" 0 ;;
    esac
  ) > "$TMP/handler.log" 2>&1; then
    code=0
  else
    code=$?
  fi
  if [ "$code" -ne 77 ] || [ ! -s "$TMP/guard.calls" ] || [ -s "$TMP/effects" ]; then
    printf 'restore guard failed for %s: status=%s\n' "$target" "$code" >&2
    cat "$TMP/handler.log" >&2
    cat "$TMP/effects" >&2
    exit 1
  fi
  cmp "$TMP/config.expected" "$INSTALL_DIR/config.yml"
  cmp "$TMP/compose.expected" "$INSTALL_DIR/docker-compose.yml"
  cmp "$TMP/data.expected" "$INSTALL_DIR/data/sentinel"
done
printf 'interrupted runtime restore guard: %s direct entry points refused before effects\n' "${#guarded_functions[@]}"
