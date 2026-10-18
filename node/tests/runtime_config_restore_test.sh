#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export INSTALL_DIR="$TMP/node" APP_NAME=tx-node-config-restore-test
source "$ROOT/deploy.sh"
mkdir -p "$BACKUP_DIR" "$DATA_DIR"
printf 'panel:\n  token: isolated-synthetic-sentinel\n' > "$CONFIG_FILE"
cp "$CONFIG_FILE" "$TMP/expected.yml"
printf 'not a config\n' > "$BACKUP_DIR/runtime-20261015-000000.tar"
printf 'not a config\n' > "$BACKUP_DIR/runtime-20261015-000000.tar.gz"
mkdir "$BACKUP_DIR/legacy-source.20261015-000000"
ln -s "$CONFIG_FILE" "$BACKUP_DIR/config.yml.20261015-symlink"
# Only full archives/foreign directory/symlink exist: ordinary restore must
# return without offering to copy an uncompressed runtime archive into YAML.
confirm() { return 0; }
detect_deploy_mode() { DEPLOY_MODE=none; }
is_installed() { return 1; }
do_restore </dev/null > "$TMP/no-config.log"
cmp "$TMP/expected.yml" "$CONFIG_FILE"
[ -z "$(legacy_config_backup_names)" ]
# Even if a full bundle is renamed to a legacy archive name, its manifest/data
# entries must fail validation before any replacement of config or Compose.
mkdir "$TMP/full"
printf '{}\n' > "$TMP/full/MANIFEST.json"
cp "$CONFIG_FILE" "$TMP/full/config.yml"
tar -czf "$BACKUP_DIR/backup-20261015-000001.tar.gz" -C "$TMP/full" MANIFEST.json config.yml
if do_restore <<<1 > "$TMP/full-refused.log" 2>&1; then
  echo 'full runtime archive accepted by config-only restore' >&2; exit 1
fi
cmp "$TMP/expected.yml" "$CONFIG_FILE"
grep -Fq TXNODE_CONFIG_ARCHIVE_REFUSED "$TMP/full-refused.log"
# An enrolled backup cannot enroll a currently unenrolled deployment through
# the configuration-only path. Both raw YAML and config-only tar are refused.
for form in raw tar alias; do
  selected="config.yml.20261015-$form"
  if [ "$form" = alias ]; then
    printf 'panel: &hidden\n  token: isolated\nother: *hidden\n' > "$BACKUP_DIR/$selected"
  else
    printf 'panel:\n  token: isolated\nauthorization:\n  enabled: true\n' > "$BACKUP_DIR/$selected"
  fi
  if [ "$form" = tar ]; then
    cp "$BACKUP_DIR/$selected" "$TMP/full/config.yml"
    selected=backup-20261015-enrolled.tar.gz
    tar -czf "$BACKUP_DIR/$selected" -C "$TMP/full" config.yml
  fi
  if (
    legacy_config_backup_names() { printf '%s\n' "$selected"; }
    do_restore <<<1
  ) > "$TMP/enrolled-$form.log" 2>&1; then
    echo "enrollment/ambiguous YAML accepted by legacy restore: $form" >&2; exit 1
  fi
  cmp "$TMP/expected.yml" "$CONFIG_FILE"
  grep -Fq TXNODE_CONFIG_ARCHIVE_REFUSED "$TMP/enrolled-$form.log"
done
# Quoted YAML authorization in the current config is also blocked, even when
# the old block-style summary parser cannot recognize that representation.
printf 'panel:\n  token: isolated\n"authorization":\n  enabled: true\n' > "$CONFIG_FILE"
cp "$CONFIG_FILE" "$TMP/current-enrolled.expected"
cp "$TMP/expected.yml" "$BACKUP_DIR/config.yml.20261015-safe"
if (
  legacy_config_backup_names() { printf 'config.yml.20261015-safe\n'; }
  do_restore <<<1
) > "$TMP/current-enrolled.log" 2>&1; then
  echo 'current quoted enrollment was silently removed' >&2; exit 1
fi
cmp "$TMP/current-enrolled.expected" "$CONFIG_FILE"
printf 'configuration-only restore rejects full bundles, current/saved enrollment and ambiguous YAML: passed\n'
