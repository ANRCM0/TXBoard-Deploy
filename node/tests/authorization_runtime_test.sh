#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export INSTALL_DIR="$TMP/node" APP_NAME=tx-node-proof-test
source "$ROOT/deploy.sh"

fixture_capability_json='{"protocol_version":1,"runtime":"tx-node","version":"test","commit":"synthetic","capabilities":["node_authorization_snapshot_v1"]}'
image_id="sha256:$(printf '%64s' '' | tr ' ' a)"
docker() {
  printf '%s\n' "$@" > "$TMP/arguments"
  if [ "$1" = inspect ]; then printf '%s\n' "$image_id"; return; fi
  if [ "${proof_fail:-false}" = true ]; then return 2; fi
  printf '%s\n' "$fixture_capability_json"
}

AUTHORIZATION_ENABLED=false
verify_authorization_runtime
test ! -e "$TMP/arguments"

AUTHORIZATION_ENABLED=true
verify_authorization_runtime
printf '%s\n' run --rm --network none --entrypoint /usr/local/bin/tx-node "$IMAGE" --capabilities > "$TMP/expected"
cmp "$TMP/expected" "$TMP/arguments"
! grep -Eq 'token|mount|volume' "$TMP/arguments"

verify_existing_authorization_runtime
grep -Fxq "$image_id" "$TMP/arguments"
! grep -Fxq "$IMAGE" "$TMP/arguments"

for fixture_capability_json in \
  'not-json' \
  '{"protocol_version":true,"runtime":"tx-node","capabilities":["node_authorization_snapshot_v1"]}' \
  '{"protocol_version":1,"runtime":"other","capabilities":["node_authorization_snapshot_v1"]}' \
  '{"protocol_version":1,"runtime":"tx-node","capabilities":[]}' \
  '{"protocol_version":1,"runtime":"tx-node","capabilities":"node_authorization_snapshot_v1"}'; do
  if (verify_authorization_runtime >/dev/null 2>&1); then
    echo 'unsupported or malformed runtime capability was accepted' >&2
    exit 1
  fi
done
proof_fail=true
if (verify_authorization_runtime >/dev/null 2>&1); then
  echo 'old runtime without capabilities flag was accepted' >&2
  exit 1
fi
echo 'finite authorization runtime capability and immutable existing-image checks: ok'
