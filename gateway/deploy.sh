#!/usr/bin/env bash
# Image-only Native Gateway installer. This does not deploy experimental crypto.
set -Eeuo pipefail
umask 077

gw_log() { printf '[TXBoard Gateway] %s\n' "$*"; }
gw_die() { printf '[TXBoard Gateway] ERROR: %s\n' "$*" >&2; exit 1; }
gw_usage() {
  cat <<'EOF'
Usage:
  install.sh --component gateway --upstream https://core.example.com --origins https://site.example.com [options]
  gateway.sh install|status|logs|start|stop|restart|upgrade|recover|remove [options]

Installation options:
  --dir PATH          Default /opt/txboard-gateway; dedicated directory only
  --upstream ORIGIN   Required clean Core origin, without credentials/path/query
  --origins CSV       Required exact allowed browser origins (no wildcard)
  --allow-private-http  Explicitly allow a private HTTP Core origin
  --bind IPV4         Default 127.0.0.1; no TLS is configured by this installer
  --port PORT         Default 8787
  --project NAME      Default txboard-gateway; unique for each installation
  --tag TAG           Default latest; upgrade preserves the installed repository
  --image REF         Install only: image reference (official default txboard-gateway)
  --operator-env FILE Optional dotenv input copied privately; never printed
  --render-only       Write/validate configuration without pulling or starting
  --health-timeout N  Wait 1..300 seconds, default 90
  --yes               Required for remove; retains all configuration and images

Health verifies this container's /healthz only. Configure a TLS reverse proxy
separately and route /gateway/v1/*; do not expose operator endpoints publicly.
HPKE, Internal, account workflows, CAPTCHA challenge and order writes stay off.
EOF
}

gw_value() {
  local key="$1" file="${2:-$GW_DIR/.env}" count
  count="$(grep -c "^$key=" "$file" || true)"
  [[ "$count" == 1 ]] || gw_die 'missing or duplicate installation metadata'
  sed -n "s/^$key=//p" "$file"
}

gw_image_valid() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9./_-]*:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ||
     "$1" =~ ^[a-z0-9][a-z0-9./_-]*@sha256:[a-f0-9]{64}$ ]]
}

gw_origin_valid() {
  # Mirrors the current Gateway origin boundary without shell evaluation.
  # Canonical IPv4/DNS origins are supported here; IPv6 can be added separately.
  local origin="$1" authority hostname port='' part n
  [[ "$origin" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || return 1
  authority="${origin#*://}"; hostname="${authority%%:*}"
  [[ "$hostname" != *:* && "$hostname" != -* && "$hostname" != *- && "$hostname" != .* && "$hostname" != *. && "$hostname" != *..* ]] || return 1
  if [[ "$authority" == *:* ]]; then
    port="${authority##*:}"
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$port <= 65535)) || return 1
  fi
  if [[ "$origin" == http://* && "$GW_PRIVATE_HTTP" != true ]]; then return 1; fi
  if [[ "$origin" == http://* ]]; then
    case "${hostname,,}" in localhost|*.localhost|*.internal) return 0 ;; esac
    [[ "${hostname,,}" =~ ^[a-z][a-z0-9-]{0,62}$ ]] && return 0
    [[ "$hostname" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a parts <<< "$hostname"
    for part in "${parts[@]}"; do [[ "$part" == 0 || "$part" =~ ^[1-9][0-9]{0,2}$ ]] && ((10#$part <= 255)) || return 1; done
    n="${parts[0]}"
    [[ "$n" == 10 || "$n" == 127 || ( "$n" == 172 && "${parts[1]}" -ge 16 && "${parts[1]}" -le 31 ) || ( "$n" == 192 && "${parts[1]}" == 168 ) ]] || return 1
  fi
}

gw_validate_install() {
  gw_image_valid "$GW_IMAGE" || gw_die 'invalid image reference (tag or sha256 digest required)'
  gw_origin_valid "$GW_UPSTREAM" || gw_die 'invalid Core origin; HTTP requires explicit private-host opt-in'
  [[ -n "$GW_ORIGINS" && "$GW_ORIGINS" != ,* && "$GW_ORIGINS" != *, && "$GW_ORIGINS" != *,,* ]] || gw_die 'exact allowed site origins are required'
  local origin save="$GW_PRIVATE_HTTP"
  GW_PRIVATE_HTTP=true # Browser http(s) origins are exact; upstream HTTP has a separate private gate.
  IFS=, read -r -a origins <<< "$GW_ORIGINS"
  for origin in "${origins[@]}"; do
    if [[ "$origin" == http://* ]]; then
      # Syntax only for browser origins. TLS is the operator's responsibility.
      origin="https://${origin#http://}"
    fi
    gw_origin_valid "$origin" || gw_die 'invalid allowed site origin'
  done
  GW_PRIVATE_HTTP="$save"
  [[ "$GW_BIND" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || gw_die 'bind must be a canonical IPv4 address'
  local part
  IFS=. read -r -a parts <<< "$GW_BIND"
  for part in "${parts[@]}"; do [[ "$part" == 0 || "$part" =~ ^[1-9][0-9]{0,2}$ ]] && ((10#$part <= 255)) || gw_die 'invalid bind address'; done
  [[ "$GW_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$GW_PORT <= 65535)) || gw_die 'invalid host port'
  [[ "$GW_PROJECT" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]] || gw_die 'invalid Compose project name'
  if [[ -n "$GW_OPERATOR_ENV" ]]; then
    [[ -f "$GW_OPERATOR_ENV" && ! -L "$GW_OPERATOR_ENV" ]] || gw_die 'operator env must be a regular file'
    [[ "$(wc -c < "$GW_OPERATOR_ENV")" -le 65536 ]] || gw_die 'operator env exceeds 64 KiB'
    # A narrow server-owned configuration extension. It is passed as dotenv,
    # never sourced in Bash. No crypto keys, Redis, Internal paths or NODE_OPTIONS.
    local line key
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      [[ -z "$line" || "$line" == \#* ]] && continue
      key="${line%%=*}"
      [[ "$line" == *=* ]] || gw_die 'invalid operator dotenv input'
      case "$key" in
        GATEWAY_METRICS_TOKEN|GATEWAY_ALLOWED_HOSTS|GATEWAY_TRUSTED_INGRESS|GATEWAY_UPSTREAM_HOSTS|GATEWAY_UPSTREAM_TIMEOUT_MS|GATEWAY_MAX_REQUEST_BYTES|GATEWAY_MAX_RESPONSE_BYTES|GATEWAY_PUBLIC_CACHE_TTL_MS) ;;
        *) gw_die 'operator env contains a setting outside the supported Native configuration' ;;
      esac
    done < "$GW_OPERATOR_ENV"
  fi
}

gw_dc() { docker compose --project-directory "$GW_DIR" -p "$GW_PROJECT" --env-file "$GW_DIR/.env" -f "$GW_DIR/compose.yaml" "$@"; }
gw_quiet() { "$@" >> "$GW_DIR/diagnostic.log" 2>&1; }
gw_docker() {
  command -v docker >/dev/null 2>&1 || gw_die 'Docker Engine is required'
  gw_quiet docker compose version || gw_die 'Docker Compose v2 is required (see private diagnostic.log)'
  gw_quiet docker info || gw_die 'Docker daemon unavailable (see private diagnostic.log)'
}
gw_ownership() {
  local ids id identity
  ids="$(docker ps -a --filter "label=com.docker.compose.project=$GW_PROJECT" --format '{{.ID}}')" || gw_die 'cannot discover Compose ownership'
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    identity="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "io.txboard.deploy.component"}}' "$id")" || gw_die 'cannot inspect Compose ownership'
    [[ "$identity" == "$GW_DIR|gateway|gateway" ]] || gw_die 'Compose project is used by a foreign or unmanaged container'
  done <<< "$ids"
}
gw_load() {
  [[ -f "$GW_DIR/.gateway-installation" && ! -L "$GW_DIR/.gateway-installation" && "$(cat "$GW_DIR/.gateway-installation")" == 'gateway/v1' ]] || gw_die 'no managed Gateway installation found'
  local file
  for file in .env gateway.env compose.yaml gateway.sh; do
    [[ -f "$GW_DIR/$file" && ! -L "$GW_DIR/$file" ]] || gw_die 'missing or unsafe Gateway installation file'
  done
  GW_PROJECT="$(gw_value TXGATEWAY_PROJECT)"
  GW_IMAGE="$(gw_value TXGATEWAY_IMAGE)"
  GW_IMAGE_REF="$(gw_value TXGATEWAY_IMAGE_REF)"
  [[ "$GW_PROJECT" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]] || gw_die 'invalid saved project identity'
  gw_image_valid "$GW_IMAGE_REF" || gw_die 'invalid saved image reference'
  gw_image_valid "$GW_IMAGE" || [[ "$GW_IMAGE" =~ ^sha256:[a-f0-9]{64}$ ]] || gw_die 'invalid saved runtime image'
}
gw_set_image() {
  local image="$1" ref="$2" tmp
  tmp="$(mktemp "$GW_DIR/.env.XXXXXXXX")"
  awk -v image="$image" -v ref="$ref" '
    /^TXGATEWAY_IMAGE=/ { print "TXGATEWAY_IMAGE=" image; next }
    /^TXGATEWAY_IMAGE_REF=/ { print "TXGATEWAY_IMAGE_REF=" ref; next }
    { print }
  ' "$GW_DIR/.env" > "$tmp"
  chmod 600 "$tmp"; mv -f -- "$tmp" "$GW_DIR/.env"
}
gw_health() {
  local limit=$((SECONDS + GW_HEALTH_TIMEOUT)) id state
  while ((SECONDS < limit)); do
    id="$(gw_dc ps -a -q gateway 2>> "$GW_DIR/diagnostic.log")" || return 1
    [[ -n "$id" && "$id" != *$'\n'* ]] || return 1
    state="$(docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>> "$GW_DIR/diagnostic.log")" || return 1
    case "$state" in running\|healthy) return 0 ;; exited\|*|dead\|*|*\|unhealthy|*\|none) return 1 ;; esac
    sleep 1
  done
  return 1
}
gw_start() {
  [[ ! -e "$GW_DIR/.gateway-update" ]] || gw_die 'interrupted update; run recover before starting'
  if ! gw_quiet gw_dc up -d --no-build --pull never "$@" gateway || ! gw_health; then
    gw_quiet gw_dc stop gateway || true
    gw_die 'Gateway did not become healthy; stopped (see private diagnostic.log)'
  fi
  gw_log 'Gateway is healthy; this probe does not verify Core reachability or TLS'
}

gw_install() {
  gw_validate_install
  [[ ! -e "$GW_DIR/.env" && ! -e "$GW_DIR/compose.yaml" && ! -e "$GW_DIR/.gateway-installation" ]] || gw_die 'existing installation; use upgrade/start or a new dedicated directory'
  local entry
  while IFS= read -r entry; do
    case "${entry##*/}" in .gateway.lock|diagnostic.log) ;; *) gw_die 'installation directory must be empty' ;; esac
  done < <(find "$GW_DIR" -mindepth 1 -maxdepth 1)
  gw_ownership
  cat > "$GW_DIR/.env" <<EOF
TXGATEWAY_PROJECT=$GW_PROJECT
TXGATEWAY_IMAGE=$GW_IMAGE
TXGATEWAY_IMAGE_REF=$GW_IMAGE
TXGATEWAY_BIND=$GW_BIND
TXGATEWAY_PORT=$GW_PORT
EOF
  cat > "$GW_DIR/gateway.env" <<EOF
TXBOARD_UPSTREAM_URL=$GW_UPSTREAM
TXBOARD_ALLOW_PRIVATE_HTTP=$GW_PRIVATE_HTTP
GATEWAY_ALLOWED_ORIGINS=$GW_ORIGINS
EOF
  if [[ -n "$GW_OPERATOR_ENV" ]]; then cat "$GW_OPERATOR_ENV" >> "$GW_DIR/gateway.env"; printf '\n' >> "$GW_DIR/gateway.env"; fi
  cat > "$GW_DIR/compose.yaml" <<'EOF'
services:
  gateway:
    image: ${TXGATEWAY_IMAGE:?missing Gateway image}
    restart: unless-stopped
    init: true
    labels:
      io.txboard.deploy.component: gateway
    env_file:
      - ./gateway.env
    environment:
      NODE_ENV: production
      APP_ENV: production
      GATEWAY_HOST: 0.0.0.0
      GATEWAY_PORT: 8787
      GATEWAY_HPKE_MODE: disabled
      GATEWAY_REDIS_URL: ''
      GATEWAY_INTERNAL_USER_ENABLED: 'false'
      GATEWAY_INTERNAL_PUBLIC_READ_ENABLED: 'false'
      GATEWAY_INTERNAL_LOGIN_ENABLED: 'false'
      GATEWAY_INTERNAL_EMAIL_CODE_ENABLED: 'false'
      GATEWAY_ACCOUNT_WORKFLOWS_ENABLED: 'false'
      GATEWAY_CAPTCHA_CHALLENGE_ENABLED: 'false'
      GATEWAY_ORDER_WRITE_ENABLED: 'false'
      GATEWAY_PAYMENT_CATALOG_ENABLED: 'false'
    ports:
      - '${TXGATEWAY_BIND:?}:${TXGATEWAY_PORT:?}:8787'
    healthcheck:
      test: ['CMD', 'node', '-e', "fetch('http://127.0.0.1:8787/healthz').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))"]
      interval: 5s
      timeout: 4s
      retries: 5
      start_period: 5s
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    read_only: true
    tmpfs:
      - /tmp:size=16m,noexec,nosuid
    logging:
      driver: json-file
      options: {max-size: 10m, max-file: '3'}
EOF
  cp -- "${BASH_SOURCE[0]}" "$GW_DIR/gateway.sh"
  chmod 700 "$GW_DIR/gateway.sh"
  chmod 600 "$GW_DIR/.env" "$GW_DIR/gateway.env" "$GW_DIR/compose.yaml"
  printf 'gateway/v1\n' > "$GW_DIR/.gateway-installation"
  gw_quiet gw_dc config --quiet || gw_die 'invalid Compose configuration (see private diagnostic.log)'
  if ((GW_RENDER_ONLY)); then gw_log "Gateway configuration rendered in $GW_DIR; no image pulled or container started"; return; fi
  gw_quiet gw_dc pull gateway || gw_die 'image pull failed; configuration retained (see private diagnostic.log)'
  gw_start
  gw_log "Manage with: sudo bash $GW_DIR/gateway.sh status"
}

gw_restore_update() {
  local backup="$GW_DIR/.gateway-update" image ref
  [[ -d "$backup" && ! -L "$backup" && -f "$backup/env" && ! -L "$backup/env" && -f "$backup/image-id" && ! -L "$backup/image-id" ]] || gw_die 'invalid interrupted-update evidence'
  image="$(cat "$backup/image-id")"
  [[ "$image" =~ ^sha256:[a-f0-9]{64}$ ]] || gw_die 'invalid retained image identity'
  gw_quiet docker image inspect "$image" || gw_die 'retained image unavailable; recovery remains blocked'
  ref="$(gw_value TXGATEWAY_IMAGE_REF "$backup/env")"
  gw_image_valid "$ref" || gw_die 'invalid retained image reference'
  cp -- "$backup/env" "$GW_DIR/.env"; chmod 600 "$GW_DIR/.env"
  gw_set_image "$image" "$ref"
  if ! gw_quiet gw_dc up -d --force-recreate --no-build --pull never gateway || ! gw_health; then
    gw_quiet gw_dc stop gateway || true
    gw_die 'rollback failed; Gateway stopped and recovery evidence retained'
  fi
  rm -f -- "$backup/env" "$backup/image-id"; rmdir -- "$backup"
  gw_log 'Restored the retained image ID; original repository/channel retained for the next upgrade'
}
gw_upgrade() {
  [[ ! -e "$GW_DIR/.gateway-update" ]] || gw_die 'interrupted update; run recover first'
  local image="$GW_IMAGE_REF" id old_id
  if [[ -n "$GW_TAG" ]]; then
    [[ "$GW_IMAGE_REF" != *@* ]] || gw_die 'digest-pinned install requires an explicit reviewed reinstall to change its image'
    image="${GW_IMAGE_REF%:*}:$GW_TAG"
  fi
  gw_image_valid "$image" || gw_die 'invalid target image'
  id="$(gw_dc ps -a -q gateway 2>> "$GW_DIR/diagnostic.log")"
  [[ -n "$id" && "$id" != *$'\n'* ]] || gw_die 'upgrade requires the previous container; use start first'
  old_id="$(docker inspect --format '{{.Image}}' "$id")"
  [[ "$old_id" =~ ^sha256:[a-f0-9]{64}$ ]] || gw_die 'cannot retain previous image identity'
  mkdir -- "$GW_DIR/.gateway-update"
  cp -- "$GW_DIR/.env" "$GW_DIR/.gateway-update/env"
  printf '%s\n' "$old_id" > "$GW_DIR/.gateway-update/image-id"
  gw_set_image "$image" "$image"
  if ! gw_quiet gw_dc pull gateway; then
    cp -- "$GW_DIR/.gateway-update/env" "$GW_DIR/.env"
    rm -f -- "$GW_DIR/.gateway-update/env" "$GW_DIR/.gateway-update/image-id"; rmdir -- "$GW_DIR/.gateway-update"
    gw_die 'image pull failed; previous configuration/container retained'
  fi
  if gw_quiet gw_dc up -d --force-recreate --no-build --pull never gateway && gw_health; then
    rm -f -- "$GW_DIR/.gateway-update/env" "$GW_DIR/.gateway-update/image-id"; rmdir -- "$GW_DIR/.gateway-update"
    gw_log 'Gateway upgrade passed the container health check'
  else
    gw_restore_update
    gw_die 'target image failed health; previous image restored'
  fi
}

gw_main() {
  local command="${1:-help}" option
  shift || true
  GW_DIR="${TXBOARD_GATEWAY_DIR:-/opt/txboard-gateway}"
  GW_IMAGE="${TXBOARD_GATEWAY_IMAGE:-ghcr.io/anrcm0/txboard-gateway:latest}"
  GW_TAG=''; GW_UPSTREAM=''; GW_ORIGINS=''; GW_BIND=127.0.0.1; GW_PORT=8787
  GW_PROJECT=txboard-gateway; GW_PRIVATE_HTTP=false; GW_OPERATOR_ENV=''; GW_RENDER_ONLY=0; GW_YES=0; GW_HEALTH_TIMEOUT=90
  while (($#)); do
    option="$1"; shift
    case "$option" in
      --dir|--upstream|--origins|--bind|--port|--project|--tag|--image|--operator-env|--health-timeout)
        [[ $# -gt 0 && -n "$1" ]] || gw_die 'missing option value'
        case "$option" in
          --dir) GW_DIR="$1" ;; --upstream) GW_UPSTREAM="$1" ;; --origins) GW_ORIGINS="$1" ;;
          --bind) GW_BIND="$1" ;; --port) GW_PORT="$1" ;; --project) GW_PROJECT="$1" ;;
          --tag) GW_TAG="$1" ;; --image) GW_IMAGE="$1" ;; --operator-env) GW_OPERATOR_ENV="$1" ;; --health-timeout) GW_HEALTH_TIMEOUT="$1" ;;
        esac; shift ;;
      --allow-private-http) GW_PRIVATE_HTTP=true ;; --render-only) GW_RENDER_ONLY=1 ;; --yes) GW_YES=1 ;;
      --help|-h) gw_usage; return ;; *) gw_die 'unknown Gateway option' ;;
    esac
  done
  case "$command" in help|--help|-h) gw_usage; return ;; install|status|logs|start|stop|restart|upgrade|update|recover|remove|uninstall) ;; *) gw_die 'unknown Gateway command' ;; esac
  [[ "$GW_HEALTH_TIMEOUT" =~ ^[1-9][0-9]{0,2}$ ]] && ((10#$GW_HEALTH_TIMEOUT <= 300)) || gw_die 'invalid health timeout'
  [[ -z "$GW_TAG" || "$GW_TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || gw_die 'invalid image tag'
  if [[ "$command" == install && -n "$GW_TAG" ]]; then
    [[ "$GW_IMAGE" != *@* ]] || gw_die 'tag cannot replace a pinned digest'
    GW_IMAGE="${GW_IMAGE%:*}:$GW_TAG"
  fi
  [[ "$GW_DIR" =~ ^/[A-Za-z0-9_./-]+$ && "$GW_DIR" != *..* ]] || gw_die 'install directory must be an absolute simple path without ..'
  GW_DIR="$(realpath -m -- "$GW_DIR")"
  case "$GW_DIR" in /|/etc|/opt|/usr|/var|/home|/root|/tmp) gw_die 'refusing a shared system directory' ;; esac
  if [[ "$command" == install ]]; then
    gw_validate_install
    if [[ -d "$GW_DIR" ]]; then
      local existing
      while IFS= read -r existing; do
        case "${existing##*/}" in .gateway.lock|diagnostic.log) ;; *) gw_die 'installation directory must be empty' ;; esac
      done < <(find "$GW_DIR" -mindepth 1 -maxdepth 1)
    fi
    mkdir -p -- "$GW_DIR"; chmod 700 "$GW_DIR"
  else
    [[ -d "$GW_DIR" && ! -L "$GW_DIR" ]] || gw_die 'Gateway directory does not exist'
  fi
  [[ ! -L "$GW_DIR/.gateway.lock" && ! -L "$GW_DIR/diagnostic.log" ]] || gw_die 'unsafe lock/log path'
  touch "$GW_DIR/diagnostic.log"; chmod 600 "$GW_DIR/diagnostic.log"
  command -v flock >/dev/null 2>&1 || gw_die 'flock is required'
  exec 8> "$GW_DIR/.gateway.lock"
  flock -n 8 || gw_die 'another Gateway management process holds the lock'
  gw_docker
  if [[ "$command" == install ]]; then gw_install; return; fi
  gw_load; gw_ownership
  case "$command" in
    status) gw_dc ps -a ;;
    logs) gw_dc logs --tail 100 -f gateway ;;
    start) gw_start ;;
    restart) gw_start --force-recreate ;;
    stop) gw_quiet gw_dc stop gateway; gw_log 'Gateway stopped' ;;
    upgrade|update) gw_upgrade ;;
    recover) gw_restore_update ;;
    remove|uninstall)
      ((GW_YES)) || gw_die 'remove requires --yes; configuration and images will be retained'
      [[ ! -e "$GW_DIR/.gateway-update" ]] || gw_die 'interrupted update; recover before removing containers'
      gw_quiet gw_dc down; gw_log 'Gateway containers removed; configuration and images retained' ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then gw_main "$@"; fi
