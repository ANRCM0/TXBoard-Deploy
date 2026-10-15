#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export INSTALL_DIR="$TMP/good" APP_NAME=tx-node-tools-test
source "$ROOT/deploy.sh"
# Never fetch dependencies or runtime helpers during this synthetic regression.
curl() { return 91; }
ensure_runtime_tools
for name in runtime_backup.py runtime_manager.py; do
  cmp "$ROOT/$name" "$INSTALL_DIR/.runtime-tools/$name"
  [ "$(stat -c %a "$INSTALL_DIR/.runtime-tools/$name")" = 600 ]
done
# A stale installed helper must be atomically repaired from the pinned source.
printf 'untrusted stale helper\n' > "$INSTALL_DIR/.runtime-tools/runtime_backup.py"
ensure_runtime_tools
cmp "$ROOT/runtime_backup.py" "$INSTALL_DIR/.runtime-tools/runtime_backup.py"
# Missing or mismatched source and unavailable download cannot be executed.
mkdir -p "$TMP/untrusted-source"
printf 'print("unreviewed")\n' > "$TMP/untrusted-source/runtime_backup.py"
SELF_PATH="$TMP/untrusted-source/deploy.sh"
INSTALL_DIR="$TMP/refused"
if ensure_runtime_tools >"$TMP/refused.log" 2>&1; then
  echo 'mismatched helper was accepted' >&2; exit 1
fi
[ ! -f "$INSTALL_DIR/.runtime-tools/runtime_backup.py" ]
# Refuse symlink targets before making any directory in their destination.
mkdir "$TMP/destination"
ln -s "$TMP/destination" "$TMP/symlink-target"
INSTALL_DIR="$TMP/symlink-target"
if ensure_runtime_tools >"$TMP/symlink.log" 2>&1; then
  echo 'symlink deployment was accepted' >&2; exit 1
fi
[ ! -e "$TMP/destination/.runtime-tools" ]
# A malformed guard still blocks all writes, even with no current data directory.
INSTALL_DIR="$TMP/guarded"
printf 'not valid json\n' > "$TMP/.guarded.runtime-restore.guard"
if require_runtime_restore_clear >"$TMP/guard.log" 2>&1; then
  echo 'malformed surviving guard was ignored' >&2; exit 1
fi
# Real flock conflict: the holder and attempted operation have different open
# descriptions, so lifecycle refuses rather than proceeding concurrently.
INSTALL_DIR="$TMP/locked"
export INSTALL_DIR
if flock "$TMP/.locked.runtime-operation.lock" bash -c 'source "$1"; require_runtime_restore_clear' _ "$ROOT/deploy.sh" >"$TMP/locked.log" 2>&1; then
  echo 'concurrent runtime operation was accepted' >&2; exit 1
fi
printf 'runtime helper integrity, symlink/guard refusal and operation locking: passed\n'
