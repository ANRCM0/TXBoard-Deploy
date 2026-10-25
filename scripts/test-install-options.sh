#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_DOCKER_LOG"
case "$1" in
  manifest) [[ "${*: -1}" == *":${TEST_AVAILABLE_CHANNEL:-none}" ]] ;;
  *) exit 91 ;;
esac
SH
chmod 700 "$tmp/bin/docker"
export TEST_DOCKER_LOG="$tmp/docker.log"
: > "$TEST_DOCKER_LOG"

for extra in '' '--test-mode'; do
  if PATH="$tmp/bin:$PATH" bash "$repo/install.sh" --yes --dir "$tmp/refused" $extra >"$tmp/refused.log" 2>&1; then
    echo 'Fresh unattended install silently selected legacy' >&2; exit 1
  fi
  grep -Fq 'fresh unattended installation requires --native-config and --native-image' "$tmp/refused.log"
  test ! -e "$tmp/refused"
  test ! -s "$TEST_DOCKER_LOG"
done

if PATH="$tmp/bin:$PATH" bash "$repo/install.sh" --yes --legacy-compat --native-config "$tmp/private" >"$tmp/ambiguous.log" 2>&1; then
  echo 'Conflicting runtime selections accepted' >&2; exit 1
fi
grep -Fq -- '--legacy-compat cannot be combined with --native-config' "$tmp/ambiguous.log"
test ! -s "$TEST_DOCKER_LOG"

source <(awk '/^normalize_http_bind\(\) \{/{readfn=1} readfn{print} readfn && /^\}$/ {exit}' "$repo/install.sh")
[[ "$(normalize_http_bind 127.0.0.1)" == 127.0.0.1 ]]
[[ "$(normalize_http_bind ::1)" == '[::1]' ]]
[[ "$(normalize_http_bind '[2001:db8::1]')" == '[2001:db8::1]' ]]
for invalid in 'localhost' '127.0.0.999' '::1%eth0' '127.0.0.1:80' $'127.0.0.1\n' '--help'; do
  if normalize_http_bind "$invalid" >/dev/null 2>&1; then echo 'Invalid listener accepted' >&2; exit 1; fi
done

warn() { printf '%s\n' "$*" >&2; }
source <(awk '/^report_image_acquisition_failure\(\) \{/{readfn=1} readfn{print} readfn && /^\}$/ {exit}' "$repo/install.sh")
source <(awk '/^pull_install_images\(\) \{/{readfn=1} readfn{print} readfn && /^\}$/ {exit}' "$repo/install.sh")
(
  export PATH="$tmp/bin:$PATH" TEST_AVAILABLE_CHANNEL=dev
  IMAGE_REPO=ghcr.io/example/core
  IMAGE="$IMAGE_REPO:latest"
  NATIVE_CONFIG_DIR=''
  if pull_install_images >"$tmp/pull.log" 2>&1; then echo 'Failed pull was swallowed' >&2; exit 1; fi
  grep -Fq 'Reachable channels at ghcr.io/example/core: dev' "$tmp/pull.log"
  grep -Fq 'No channel fallback was performed' "$tmp/pull.log"
  [[ "$(grep -c '^pull ' "$TEST_DOCKER_LOG")" == 1 ]]
  grep -Fxq 'pull ghcr.io/example/core:latest' "$TEST_DOCKER_LOG"
  ! grep -Eq '^pull .*:(dev|preview)$' "$TEST_DOCKER_LOG"
  export TEST_AVAILABLE_CHANNEL=none
  report_image_acquisition_failure >"$tmp/unavailable.log" 2>&1
  grep -Fq 'Channel availability could not be confirmed' "$tmp/unavailable.log"
)

render() {
  local name="$1" public="$2" expected="$3"
  shift 3
  env -u TXBOARD_HTTP_BIND TXBOARD_DB_PASSWORD=synthetic TXBOARD_DB_ROOT_PASSWORD=synthetic-root \
    bash "$repo/install.sh" --yes --render-only --dir "$tmp/$name" --mode http \
      --public-host "$public" --http-port 18081 --email fixture@example.test --db-mode local "$@" >"$tmp/$name.log" 2>&1
  grep -Fxq "TXBOARD_HTTP_BIND=$expected" "$tmp/$name/.env"
  test ! -e "$tmp/$name/.native-deploy/intent.json"
}
render inferred-loopback 127.0.0.1 127.0.0.1
render inferred-localhost localhost 127.0.0.1
render public-host example.test 0.0.0.0
render explicit-loopback example.test 127.0.0.1 --http-bind 127.0.0.1
render explicit-wildcard 127.0.0.1 0.0.0.0 --http-bind 0.0.0.0
render ipv6-loopback ::1 '[::1]' --http-bind ::1
grep -Fxq 'APP_URL=http://[::1]:18081' "$tmp/ipv6-loopback/api.env"
(
  cd "$tmp/ipv6-loopback"
  docker compose config --format json | python3 -c 'import json,sys; p=json.load(sys.stdin)["services"]["txboard"]["ports"]; assert p[0]["host_ip"] == "::1"'
)
TXBOARD_HTTP_BIND=127.0.0.1 TXBOARD_DB_PASSWORD=synthetic TXBOARD_DB_ROOT_PASSWORD=synthetic-root \
  bash "$repo/install.sh" --yes --render-only --dir "$tmp/env-bind" --mode http \
    --public-host example.test --http-port 18081 --email fixture@example.test --db-mode local >"$tmp/env-bind.log" 2>&1
grep -Fxq 'TXBOARD_HTTP_BIND=127.0.0.1' "$tmp/env-bind/.env"
echo 'Native prerequisites, explicit compatibility, listener intent and channel failure diagnostics passed.'
