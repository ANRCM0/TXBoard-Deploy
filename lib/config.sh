#!/usr/bin/env bash

rewrite_ports() {
  local publish_https="$1" tmp
  tmp="$(mktemp)"
  awk -v https="$publish_https" '
    BEGIN { in_ports=0 }
    $0=="    ports:" {
      print
      print "      - \"\${TXBOARD_HTTP_BIND:-0.0.0.0}:\${TXBOARD_HTTP_PORT:-80}:80\""
      if (https==1) print "      - \"\${TXBOARD_HTTPS_BIND:-0.0.0.0}:\${TXBOARD_HTTPS_PORT:-443}:443\""
      in_ports=1
      next
    }
    in_ports && $0=="    healthcheck:" { in_ports=0; print; next }
    in_ports { next }
    { print }
  ' "$TXBOARD_INSTALL_DIR/compose.yaml" > "$tmp"
  mv "$tmp" "$TXBOARD_INSTALL_DIR/compose.yaml"
  chmod 644 "$TXBOARD_INSTALL_DIR/compose.yaml"
}

config_show() {
  need_install
  cat <<EOF
Install dir:       $TXBOARD_INSTALL_DIR
Mode:              $(detect_mode)
Image:             $(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_IMAGE)
APP_URL:           $(env_get "$TXBOARD_INSTALL_DIR/api.env" APP_URL)
HTTP bind:         $(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_HTTP_BIND)
HTTP port:         $(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_HTTP_PORT)
HTTPS port:        $(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_HTTPS_PORT)
Backup retention:  $(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_BACKUP_RETENTION)
EOF
}

config_access() {
  require_tty; docker_ok; need_install
  local choice mode domain host http_port https_port url bind site secure publish_https tmp
  choice="$(choose "1 auto-https  2 external-https  3 http  0 back" "1" "3")"
  [[ "$choice" != "0" ]] || return 0

  domain=""; host=""; publish_https=0; bind="0.0.0.0"; site=":80"; secure=false
  https_port="$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_HTTPS_PORT)"; https_port="${https_port:-443}"

  case "$choice" in
    1)
      mode=auto-https
      domain="$(prompt "Domain" "$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_DOMAIN)")"
      valid_domain "$domain" || die "invalid domain"
      http_port="$(prompt "HTTP port" "$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_HTTP_PORT)")"
      https_port="$(prompt "HTTPS port" "$https_port")"
      valid_port "$http_port" || die "invalid HTTP port"
      valid_port "$https_port" || die "invalid HTTPS port"
      url="https://$domain"; site="$domain"; secure=true; publish_https=1
      ;;
    2)
      mode=external-https
      domain="$(prompt "Domain" "$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_DOMAIN)")"
      valid_domain "$domain" || die "invalid domain"
      http_port="$(prompt "Local HTTP port" "$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_HTTP_PORT)")"
      valid_port "$http_port" || die "invalid HTTP port"
      url="https://$domain"; bind="127.0.0.1"; secure=true
      ;;
    3)
      mode=http
      host="$(prompt "Host/IP" "$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_PUBLIC_HOST)")"
      [[ -n "$host" && ! "$host" =~ [[:space:]] ]] || die "invalid host"
      http_port="$(prompt "HTTP port" "$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_HTTP_PORT)")"
      valid_port "$http_port" || die "invalid HTTP port"
      [[ "$http_port" == "80" ]] && url="http://$host" || url="http://$host:$http_port"
      ;;
  esac

  tmp="$(mktemp -d)"
  cp "$TXBOARD_INSTALL_DIR/.env" "$TXBOARD_INSTALL_DIR/api.env" "$TXBOARD_INSTALL_DIR/compose.yaml" "$tmp/"

  env_set "$TXBOARD_INSTALL_DIR/.env" TXBOARD_MODE "$mode"
  env_set "$TXBOARD_INSTALL_DIR/.env" TXBOARD_DOMAIN "$domain"
  env_set "$TXBOARD_INSTALL_DIR/.env" TXBOARD_PUBLIC_HOST "$host"
  env_set "$TXBOARD_INSTALL_DIR/.env" TXBOARD_HTTP_BIND "$bind"
  env_set "$TXBOARD_INSTALL_DIR/.env" TXBOARD_HTTP_PORT "$http_port"
  env_set "$TXBOARD_INSTALL_DIR/.env" TXBOARD_HTTPS_PORT "$https_port"
  env_set "$TXBOARD_INSTALL_DIR/.env" TXBOARD_SITE_ADDRESS "$site"
  env_set "$TXBOARD_INSTALL_DIR/api.env" APP_URL "$url"
  env_set "$TXBOARD_INSTALL_DIR/api.env" SESSION_SECURE_COOKIE "$secure"
  rewrite_ports "$publish_https"

  if ! (cd "$TXBOARD_INSTALL_DIR" && docker compose config >/dev/null) ||
     ! compose up -d --force-recreate --wait txboard; then
    cp "$tmp/.env" "$TXBOARD_INSTALL_DIR/.env"
    cp "$tmp/api.env" "$TXBOARD_INSTALL_DIR/api.env"
    cp "$tmp/compose.yaml" "$TXBOARD_INSTALL_DIR/compose.yaml"
    compose up -d --force-recreate txboard || true
    rm -rf "$tmp"
    die "configuration failed and was rolled back"
  fi

  rm -rf "$tmp"
  log "public URL updated: $url"
}

config_menu() {
  local choice value image tag
  while true; do
    choice="$(choose "1 show  2 access/domain/ports  3 image tag  4 backup retention  0 back" "1" "4")"
    case "$choice" in
      1) config_show; pause ;;
      2) config_access; pause ;;
      3)
        image="$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_IMAGE)"
        tag="$(prompt "Image tag" "${image##*:}")"
        [[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || { warn "invalid tag"; continue; }
        if [[ -f "$TXBOARD_INSTALL_DIR/update.sh" ]]; then
          bash "$TXBOARD_INSTALL_DIR/update.sh" --dir "$TXBOARD_INSTALL_DIR" --tag "$tag"
        else
          fetch "$TXBOARD_DEPLOY_RAW_BASE/update.sh" | bash -s -- --dir "$TXBOARD_INSTALL_DIR" --tag "$tag"
        fi
        pause
        ;;
      4)
        value="$(prompt "Retention (0=keep all)" "$(env_get "$TXBOARD_INSTALL_DIR/.env" TXBOARD_BACKUP_RETENTION)")"
        [[ "$value" =~ ^[0-9]+$ ]] || { warn "invalid retention"; continue; }
        env_set "$TXBOARD_INSTALL_DIR/.env" TXBOARD_BACKUP_RETENTION "$value"
        compose up -d --force-recreate backup
        pause
        ;;
      0) return 0 ;;
    esac
  done
}
