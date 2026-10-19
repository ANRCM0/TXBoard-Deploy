#!/usr/bin/env bash
set -Eeuo pipefail
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
export TMP_COMPONENT_TEST="$tmp"
mkdir -p "$tmp/source/lib" "$tmp/source/node" "$tmp/bin"
cp "$repo/install.sh" "$repo/txboard.sh" "$tmp/source/"
cp "$repo/lib/components.sh" "$tmp/source/lib/"
for role in node; do
  cat > "$tmp/source/$role/deploy.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${INSTALL_DIR:-unset}" > "$TMP_COMPONENT_TEST/install-dir"
printf '%s\n' "$@" > "$TMP_COMPONENT_TEST/arguments"
exit "${FAKE_COMPONENT_EXIT:-0}"
EOF
done

bash "$tmp/source/install.sh" --component node --dir "$tmp/node" --mode machine --token 'literal $() `token` space'
printf '%s\n' install --mode machine --token 'literal $() `token` space' > "$tmp/expected"
cmp "$tmp/expected" "$tmp/arguments"
[[ "$(cat "$tmp/install-dir")" == "$tmp/node" ]]
bash "$tmp/source/install.sh" --component node --dir "$tmp/auth-node" \
  --mode machine --provider txboard --panel-url https://core.example.test --machine-id 12 \
  --token synthetic-machine-token --authorization-core-instance-id core-example-01 \
  --authorization-key-id core-key-1 --authorization-key-epoch 1 \
  --authorization-public-key AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
cat > "$tmp/expected" <<'EOF'
install
--mode
machine
--provider
txboard
--panel-url
https://core.example.test
--machine-id
12
--token
synthetic-machine-token
--authorization-core-instance-id
core-example-01
--authorization-key-id
core-key-1
--authorization-key-epoch
1
--authorization-public-key
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
EOF
cmp "$tmp/expected" "$tmp/arguments"
[[ "$(cat "$tmp/install-dir")" == "$tmp/auth-node" ]]
bash "$tmp/source/txboard.sh" --dir "$tmp/node" node status
[[ "$(cat "$tmp/arguments")" == status && "$(cat "$tmp/install-dir")" == "$tmp/node" ]]
for entry in install.sh txboard.sh; do
  if bash "$tmp/source/$entry" --component gateway --help > "$tmp/reject.log" 2>&1; then exit 1; fi
  grep -q 'Gateway is retired' "$tmp/reject.log"
done
if FAKE_COMPONENT_EXIT=37 bash "$tmp/source/install.sh" --component node --token dummy; then exit 1; else [[ "$?" == 37 ]]; fi
if bash "$tmp/source/install.sh" --component other > "$tmp/reject.log" 2>&1; then exit 1; fi
if bash "$tmp/source/install.sh" --component core --component node > "$tmp/reject.log" 2>&1; then exit 1; fi
if bash "$tmp/source/install.sh" --component > "$tmp/reject.log" 2>&1; then exit 1; fi

# Downloaded installer and delegated script both run from real private files.
# This fake curl uses local reviewed fixtures; no network/Docker is involved.
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
url='' out=''
while (($#)); do
  case "$1" in -o) out="$2"; shift 2 ;; --connect-timeout|--max-time) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
case "$url" in
  */install.sh) cp "$TMP_COMPONENT_TEST/source/install.sh" "$out" ;;
  */lib/components.sh) cp "$TMP_COMPONENT_TEST/source/lib/components.sh" "$out" ;;
  */node/deploy.sh) cp "$TMP_COMPONENT_TEST/source/node/deploy.sh" "$out" ;;
  *) exit 42 ;;
esac
EOF
chmod 700 "$tmp/bin/curl"
PATH="$tmp/bin:$PATH" bash -s -- --component node --token 'piped token' < "$tmp/source/install.sh"
printf '%s\n' install --token 'piped token' > "$tmp/expected"
cmp "$tmp/expected" "$tmp/arguments"
mkdir -p "$tmp/downloaded"
cp "$tmp/source/install.sh" "$tmp/downloaded/install.sh"
PATH="$tmp/bin:$PATH" bash "$tmp/downloaded/install.sh" --component node --help
printf '%s\n' install --help > "$tmp/expected"
cmp "$tmp/expected" "$tmp/arguments"

# The canonical Node self-refresh changed, while explicit old overrides survive.
url="$(bash -c 'source "$1"; printf "%s" "$SCRIPT_RAW_URL"' _ "$repo/node/deploy.sh")"
[[ "$url" == https://raw.githubusercontent.com/ANRCM0/TXBoard-Deploy/main/node/deploy.sh ]]
url="$(TXNODE_INSTALLER_REPO=ANRCM0/TX-Node-Installer bash -c 'source "$1"; printf "%s" "$SCRIPT_RAW_URL"' _ "$repo/node/deploy.sh")"
[[ "$url" == https://raw.githubusercontent.com/ANRCM0/TX-Node-Installer/main/deploy.sh ]]
url="$(TXBOARD_DEPLOY_RAW_BASE=https://example.com/reviewed bash -c 'source "$1"; printf "%s" "$SCRIPT_RAW_URL"' _ "$repo/node/deploy.sh")"
[[ "$url" == https://example.com/reviewed/node/deploy.sh ]]
bash "$repo/install.sh" --component core --help > "$tmp/core-help"
grep -q -- '--email' "$tmp/core-help"
bash "$repo/txboard.sh" core help > "$tmp/core-help"
grep -q 'backup' "$tmp/core-help"
echo 'component literal delegation, materialization and legacy Core/Node compatibility: passed'
