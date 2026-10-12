#!/usr/bin/env bash
# Actual Gateway image/Compose lifecycle. The upstream is deliberately an
# unavailable container-local loopback origin; health does not probe Core.
# One local scratch image injects startup failure for actual image-ID rollback.
set -Eeuo pipefail
umask 077
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
image="${TXBOARD_GATEWAY_TEST_IMAGE:?explicit fixed published Gateway image is required}"
[[ "$image" =~ ^ghcr\.io/anrcm0/txboard-gateway:dev-sha-[a-f0-9]{12,40}$ ||
   "$image" =~ ^ghcr\.io/anrcm0/txboard-gateway@sha256:[a-f0-9]{64}$ ]] ||
  { printf 'Use an explicit immutable release identity, not latest/dev\n' >&2; exit 1; }
real_docker="$(command -v docker)"
[[ -x "$real_docker" ]] || exit 1
"$real_docker" compose version >/dev/null
"$real_docker" info >/dev/null
command -v python3 >/dev/null
command -v curl >/dev/null
tmp="$(mktemp -d /tmp/txboard-gateway-docker.XXXXXXXX)"
dir="$tmp/install"
project="txboard-gateway-fixture-$$"
bad="${image%%[@:]*}:unhealthy-fixture-$$"
bad_id=''
cleanup() {
  local result=$?
  trap - EXIT
  if [[ -f "$dir/.gateway-installation" ]]; then
    if ! bash "$repo/gateway/deploy.sh" remove --dir "$dir" --yes >/dev/null 2>&1; then
      printf 'Fixture cleanup blocked; inspect private directory %s\n' "$tmp" >&2
      exit 1
    fi
  fi
  if [[ -n "$bad_id" && "$("$real_docker" image inspect --format '{{.Id}}' "$bad" 2>/dev/null || true)" == "$bad_id" ]]; then
    "$real_docker" image rm "$bad" >/dev/null 2>&1 || true
  fi
  if ((result != 0)); then
    printf 'Failure evidence retained in private fixture directory %s\n' "$tmp" >&2
    exit "$result"
  fi
  # Only this mktemp-owned fixture directory is ever recursively removed.
  [[ "$tmp" == /tmp/txboard-gateway-docker.* && -d "$tmp" && ! -L "$tmp" ]] || exit 1
  rm -rf -- "$tmp"
  exit "$result"
}
trap cleanup EXIT
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
printf '%s\n' "GATEWAY_METRICS_TOKEN='fixture-token-\$literal'" > "$tmp/operator.env"
bash "$repo/install.sh" --component gateway --dir "$dir" --project "$project" \
  --port "$port" --image "$image" --upstream http://localhost:9 --allow-private-http \
  --origins "http://127.0.0.1:$port" --operator-env "$tmp/operator.env"
for file in .env gateway.env compose.yaml diagnostic.log; do [[ "$(stat -c %a "$dir/$file")" == 600 ]]; done
grep -Fxq 'TXGATEWAY_BIND=127.0.0.1' "$dir/.env"
curl -fsS --max-time 5 "http://127.0.0.1:$port/healthz" > "$tmp/health.json"
python3 - "$tmp/health.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))['status']=='ok'
PY
dc() { "$real_docker" compose --project-directory "$dir" -p "$project" --env-file "$dir/.env" -f "$dir/compose.yaml" "$@"; }
id="$(dc ps -a -q gateway)"
old_id="$("$real_docker" inspect --format '{{.Image}}' "$id")"
"$real_docker" inspect --format '{{json .Config.Env}}' "$id" | python3 -c '
import json,sys
env=dict(x.split("=",1) for x in json.load(sys.stdin) if "=" in x)
assert env["TXBOARD_UPSTREAM_URL"]=="http://localhost:9"
assert env["GATEWAY_METRICS_TOKEN"]=="fixture-token-$literal"
assert env["GATEWAY_HPKE_MODE"]=="disabled"
for key in ["GATEWAY_INTERNAL_USER_ENABLED","GATEWAY_INTERNAL_PUBLIC_READ_ENABLED","GATEWAY_INTERNAL_LOGIN_ENABLED","GATEWAY_INTERNAL_EMAIL_CODE_ENABLED","GATEWAY_ACCOUNT_WORKFLOWS_ENABLED","GATEWAY_ORDER_WRITE_ENABLED"]:assert env[key]=="false"
'
bash "$dir/gateway.sh" stop --dir "$dir"
[[ "$("$real_docker" inspect --format '{{.State.Status}}' "$id")" != running ]]
bash "$dir/gateway.sh" start --dir "$dir"
curl -fsS --max-time 5 "http://127.0.0.1:$port/healthz" >/dev/null
sha256sum "$dir/gateway.env" > "$tmp/env.sha256"

# A deterministic local failure image avoids publishing a deliberately broken
# official tag. Only its pull step is replaced with local image verification;
# Compose creates a real failed container and restores the real original ID.
mkdir "$tmp/bad-build" "$tmp/bin"
printf 'FROM scratch\nENTRYPOINT ["/fixture-command-does-not-exist"]\n' > "$tmp/bad-build/Dockerfile"
"$real_docker" build --network none -t "$bad" "$tmp/bad-build" > "$tmp/build.log" 2>&1
bad_id="$("$real_docker" image inspect --format '{{.Id}}' "$bad")"
export TXGATEWAY_FIXTURE_REAL_DOCKER="$real_docker" TXGATEWAY_FIXTURE_BAD_IMAGE="$bad" TXGATEWAY_FIXTURE_BAD_ID="$bad_id"
cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
args=("$@"); env_file=''; index=0
while ((index < ${#args[@]})); do
  if [[ "${args[index]}" == --env-file ]]; then env_file="${args[index+1]}"; fi
  index=$((index + 1))
done
if [[ "${1:-}" == compose && " $* " == *' pull gateway '* && -f "$env_file" ]]; then
  image="$(sed -n 's/^TXGATEWAY_IMAGE=//p' "$env_file")"
  if [[ "$image" == "$TXGATEWAY_FIXTURE_BAD_IMAGE" ]]; then
    [[ "$("$TXGATEWAY_FIXTURE_REAL_DOCKER" image inspect --format '{{.Id}}' "$image")" == "$TXGATEWAY_FIXTURE_BAD_ID" ]]
    exit
  fi
fi
exec "$TXGATEWAY_FIXTURE_REAL_DOCKER" "$@"
EOF
chmod 700 "$tmp/bin/docker"
if PATH="$tmp/bin:$PATH" bash "$dir/gateway.sh" upgrade --dir "$dir" --tag "${bad##*:}" > "$tmp/rollback.log" 2>&1; then
  printf 'A broken target was accepted\n' >&2; exit 1
fi
grep -q 'previous image restored' "$tmp/rollback.log"
[[ ! -e "$dir/.gateway-update" ]]
grep -Fxq "TXGATEWAY_IMAGE=$old_id" "$dir/.env"
grep -Fxq "TXGATEWAY_IMAGE_REF=$image" "$dir/.env"
id="$(dc ps -a -q gateway)"
[[ "$("$real_docker" inspect --format '{{.Image}}' "$id")" == "$old_id" ]]
curl -fsS --max-time 5 "http://127.0.0.1:$port/healthz" >/dev/null
sha256sum -c "$tmp/env.sha256" >/dev/null
bash "$dir/gateway.sh" remove --dir "$dir" --yes
[[ -z "$(dc ps -a -q gateway)" ]]
[[ -f "$dir/.env" && -f "$dir/gateway.env" && -f "$dir/gateway.sh" ]]
printf 'Actual fixed Gateway image: environment/health/stop/start/failure rollback/remove passed\n'
printf 'Upstream deliberately unavailable; no Core business, Node, TLS or production acceptance claim\n'
