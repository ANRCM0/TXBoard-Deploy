#!/usr/bin/env bash
set -Eeuo pipefail

DIR="${TXBOARD_INSTALL_DIR:-/opt/txboard}"
RAW="${TXBOARD_DEPLOY_RAW_BASE:-https://raw.githubusercontent.com/PaiMonCai/TXBoard-Deploy/main}"
CMD="${1:-menu}"
[[ "$CMD" == "--dir" ]] && { DIR="${2:?missing path}"; CMD="${3:-menu}"; }

log(){ printf '[TXBoard] %s\n' "$*"; }
warn(){ printf '[TXBoard] WARNING: %s\n' "$*" >&2; }
die(){ printf '[TXBoard] ERROR: %s\n' "$*" >&2; exit 1; }
tty(){ [[ -r /dev/tty ]] || die 'interactive TTY required'; }
need(){ [[ -f "$DIR/compose.yaml" && -f "$DIR/.env" && -f "$DIR/api.env" ]] || die "no deployment in $DIR"; }
docker_ok(){ command -v docker >/dev/null && docker compose version >/dev/null && docker info >/dev/null || die 'Docker/Compose unavailable'; }
prompt(){ tty; local v; printf '%s%s: ' "$1" "${2:+ [$2]}" >/dev/tty; IFS= read -r v </dev/tty || true; printf '%s' "${v:-${2-}}"; }
confirm(){ [[ "$(prompt "$1" "${2:-N}")" =~ ^[Yy]([Ee][Ss])?$ ]]; }
choose(){ local v; while :; do v="$(prompt "$1" "$2")"; [[ "$v" =~ ^[0-9]+$ ]] && ((v>=0&&v<=$3)) && { echo "$v"; return; }; done; }
get(){ grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
setv(){ local f="$1" k="$2" v="$3" t; t="$(mktemp)"; awk -v k="$k" -v v="$v" 'BEGIN{d=0} index($0,k"=")==1{print k"="v;d=1;next}{print}END{if(!d)print k"="v}' "$f">"$t"; chmod --reference="$f" "$t" 2>/dev/null||chmod 600 "$t"; mv "$t" "$f"; }
mode(){ local m s b; m="$(get "$DIR/.env" TXBOARD_MODE)"; case "$m" in auto-https|external-https|http) echo "$m";return;; esac; s="$(get "$DIR/.env" TXBOARD_SITE_ADDRESS)"; b="$(get "$DIR/.env" TXBOARD_HTTP_BIND)"; [[ -n "$s" && "$s" != :80 ]]&&echo auto-https||{ [[ "$b" == 127.0.0.1 ]]&&echo external-https||echo http; }; }
fetch(){ if command -v curl>/dev/null;then curl -fsSL "$1";elif command -v wget>/dev/null;then wget -qO- "$1";else die 'curl/wget required';fi; }

status(){ docker_ok;need; cd "$DIR"; printf 'Directory: %s\nMode: %s\nURL: %s\nImage: %s\n\n' "$DIR" "$(mode)" "$(get api.env APP_URL)" "$(get .env TXBOARD_IMAGE)"; docker compose ps; }
update(){ docker_ok;need; if [[ -f "$DIR/update.sh" ]];then bash "$DIR/update.sh" --dir "$DIR";else fetch "$RAW/update.sh"|bash -s -- --dir "$DIR";fi; }
service(){ docker_ok;need; cd "$DIR"; local c; c="$(choose '1 status  2 start  3 stop  4 restart  5 resources  0 back' 1 5)"; case "$c" in 1)status;;2)docker compose up -d --remove-orphans;;3)docker compose stop;;4)docker compose restart txboard&&docker compose up -d --wait txboard;;5)docker stats --no-stream $(docker compose ps -q);;esac; }
logs(){ docker_ok;need; cd "$DIR"; local c s; c="$(choose '1 TXBoard  2 MySQL  3 Backup  4 All  0 back' 1 4)"; case "$c" in 1)s=txboard;;2)s=database;;3)s=backup;;4)s=;;0)return;;esac; docker compose logs -f --tail=200 ${s:+$s}; }
backup(){ docker_ok;need; cd "$DIR"; docker compose run --rm -e BACKUP_INTERVAL=0 backup; }
backups(){ find "$DIR/backups" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null|grep -E '^[0-9]{8}T[0-9]{6}Z$'|sort -r||true; }
pick_backup(){ local -a a; local i c; mapfile -t a < <(backups); ((${#a[@]}))||die 'no backups'; for i in "${!a[@]}";do printf '%d) %s\n' "$((i+1))" "${a[$i]}" >/dev/tty;done; c="$(choose Backup 1 "${#a[@]}")"; ((c>0))||die canceled; echo "${a[$((c-1))]}"; }
restore(){ tty;docker_ok;need; local n p db u pw root; n="$(pick_backup)";p="$DIR/backups/$n"; gzip -t "$p/db.sql.gz"||die 'corrupt backup'; confirm "Restore $n? A safety backup will be created" N||return; backup; cd "$DIR"; db="$(get .env TXBOARD_DB_DATABASE)";u="$(get .env TXBOARD_DB_USERNAME)";pw="$(get .env TXBOARD_DB_PASSWORD)";root="$(get .env TXBOARD_DB_ROOT_PASSWORD)"; [[ "$db" =~ ^[A-Za-z0-9_]+$ && -n "$root" ]]||die 'invalid DB config'; docker compose stop backup txboard||true; docker compose up -d --wait database; docker compose exec -T -e MYSQL_PWD="$root" database mysql -uroot -e "DROP DATABASE IF EXISTS $db; CREATE DATABASE $db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; gzip -dc "$p/db.sql.gz"|docker compose exec -T -e MYSQL_PWD="$root" database mysql -uroot "$db"; if [[ -f "$p/env" ]];then cp "$p/env" api.env; chmod 600 api.env; setv api.env DB_HOST database;setv api.env DB_DATABASE "$db";setv api.env DB_USERNAME "$u";setv api.env DB_PASSWORD "$pw";fi; if [[ -f "$p/storage-app.tar.gz" ]];then mkdir -p data/storage/app;find data/storage/app -mindepth 1 -maxdepth 1 -exec rm -rf {} +;tar -xzf "$p/storage-app.tar.gz" -C data/storage/app;fi; docker compose up -d --wait txboard;docker compose up -d backup;docker compose exec -T txboard php artisan xboard:install-status --no-interaction >/dev/null||die 'restore validation failed'; log "restored $n"; }
backup_menu(){ local c n; c="$(choose '1 create  2 list  3 restore  4 delete  5 retention  0 back' 1 5)"; case "$c" in 1)backup;;2)backups;;3)restore;;4)n="$(pick_backup)";confirm "Delete $n?" N&&rm -rf "$DIR/backups/$n";;5)n="$(prompt 'Retention (0=all)' "$(get "$DIR/.env" TXBOARD_BACKUP_RETENTION)")";[[ "$n" =~ ^[0-9]+$ ]]||die invalid;setv "$DIR/.env" TXBOARD_BACKUP_RETENTION "$n";docker_ok;cd "$DIR";docker compose up -d --force-recreate backup;;esac; }

rewrite_ports(){ local h="$1" t; t="$(mktemp)"; awk -v h="$h" 'BEGIN{x=0}$0=="    ports:"{print;print "      - \"${TXBOARD_HTTP_BIND:-0.0.0.0}:${TXBOARD_HTTP_PORT:-80}:80\"";if(h==1)print "      - \"${TXBOARD_HTTPS_BIND:-0.0.0.0}:${TXBOARD_HTTPS_PORT:-443}:443\"";x=1;next}x&&$0=="    healthcheck:"{x=0;print;next}x{next}{print}' "$DIR/compose.yaml">"$t";mv "$t" "$DIR/compose.yaml";chmod 644 "$DIR/compose.yaml"; }
config_access(){ tty;docker_ok;need; local c m d h hp sp url bind site sec https tmp; c="$(choose '1 auto-https  2 external-https  3 http  0 back' 1 3)";[[ "$c" != 0 ]]||return; d=;h=;sp="$(get "$DIR/.env" TXBOARD_HTTPS_PORT)";sp="${sp:-443}";bind=0.0.0.0;site=:80;sec=false;https=0; case "$c" in 1)m=auto-https;d="$(prompt Domain "$(get "$DIR/.env" TXBOARD_DOMAIN)")";hp="$(prompt 'HTTP port' "$(get "$DIR/.env" TXBOARD_HTTP_PORT)")";sp="$(prompt 'HTTPS port' "$sp")";url="https://$d";site="$d";sec=true;https=1;;2)m=external-https;d="$(prompt Domain "$(get "$DIR/.env" TXBOARD_DOMAIN)")";hp="$(prompt 'Local HTTP port' "$(get "$DIR/.env" TXBOARD_HTTP_PORT)")";url="https://$d";bind=127.0.0.1;sec=true;;3)m=http;h="$(prompt 'Host/IP' "$(get "$DIR/.env" TXBOARD_PUBLIC_HOST)")";hp="$(prompt 'HTTP port' "$(get "$DIR/.env" TXBOARD_HTTP_PORT)")";[[ "$hp" == 80 ]]&&url="http://$h"||url="http://$h:$hp";;esac; [[ "$hp" =~ ^[0-9]+$ ]]&&((hp>0&&hp<65536))||die 'invalid port'; [[ "$c" != 1 || ( "$sp" =~ ^[0-9]+$ && 10#$sp -gt 0 && 10#$sp -lt 65536 ) ]]||die 'invalid HTTPS port'; tmp="$(mktemp -d)";cp "$DIR/.env" "$DIR/api.env" "$DIR/compose.yaml" "$tmp/"; setv "$DIR/.env" TXBOARD_MODE "$m";setv "$DIR/.env" TXBOARD_DOMAIN "$d";setv "$DIR/.env" TXBOARD_PUBLIC_HOST "$h";setv "$DIR/.env" TXBOARD_HTTP_BIND "$bind";setv "$DIR/.env" TXBOARD_HTTP_PORT "$hp";setv "$DIR/.env" TXBOARD_HTTPS_PORT "$sp";setv "$DIR/.env" TXBOARD_SITE_ADDRESS "$site";setv "$DIR/api.env" APP_URL "$url";setv "$DIR/api.env" SESSION_SECURE_COOKIE "$sec";rewrite_ports "$https";cd "$DIR"; if ! docker compose config>/dev/null||! docker compose up -d --force-recreate --wait txboard;then cp "$tmp/.env" .env;cp "$tmp/api.env" api.env;cp "$tmp/compose.yaml" compose.yaml;docker compose up -d --force-recreate txboard||true;rm -rf "$tmp";die 'config rolled back';fi;rm -rf "$tmp";log "URL: $url"; }
config(){ need; local c; c="$(choose '1 show  2 access/domain/ports  3 update image  4 refresh tools  0 back' 1 4)"; case "$c" in 1)status;;2)config_access;;3)update;;4)mkdir -p "$DIR";fetch "$RAW/txboard.sh">"$DIR/txboard.sh";fetch "$RAW/update.sh">"$DIR/update.sh";chmod 755 "$DIR/txboard.sh" "$DIR/update.sh";[[ ${EUID:-$(id -u)} -eq 0 ]]&&ln -sfn "$DIR/txboard.sh" /usr/local/bin/txboard||true;;esac; }
diagnose(){ docker_ok;need;cd "$DIR";echo '=== compose ===';docker compose config>/dev/null&&echo OK||echo FAIL;echo '=== services ===';docker compose ps||true;echo '=== install ===';docker compose exec -T txboard php artisan xboard:install-status --no-interaction&&echo OK||echo FAIL;echo '=== disk ===';df -h "$DIR";du -sh data backups 2>/dev/null||true;echo '=== logs ===';docker compose logs --tail=50 txboard||true; }
uninstall(){ tty;docker_ok;need; local c a; c="$(choose '1 remove containers only  2 full uninstall  0 back' 0 2)";case "$c" in 1)cd "$DIR";docker compose down --remove-orphans;;2)confirm 'Full uninstall removes Docker volumes and files. Continue?' N||return;backup;a="${HOME:-/root}/txboard-uninstall-$(date -u +%Y%m%dT%H%M%SZ).tar.gz";tar -czf "$a" -C "$(dirname "$DIR")" "$(basename "$DIR")";cd "$DIR";docker compose down -v --remove-orphans;rm -f /usr/local/bin/txboard;cd /;rm -rf "$DIR";log "archive: $a";;esac; }
install(){ [[ ! -f "$DIR/compose.yaml" ]]||die 'already installed';fetch "$RAW/install.sh"|bash -s -- --dir "$DIR"; }

menu(){ tty; while :;do printf '\033[2J\033[H' >/dev/tty;cat >/dev/tty <<EOF
========================================
            TXBoard Manager
========================================
  1) Install TXBoard
  2) Update TXBoard
  3) Service management
  4) View logs
  5) Backup management
  6) Configuration
  7) Diagnostics
  8) Uninstall TXBoard
  0) Exit
EOF
case "$(choose Select 0 8)" in 1)install;;2)update;;3)service;;4)logs;;5)backup_menu;;6)config;;7)diagnose;;8)uninstall;;0)return;;esac;printf '\nPress Enter...' >/dev/tty;IFS= read -r _ </dev/tty||true;done; }

case "$CMD" in menu)menu;;install)install;;update)update;;status)status;;start)docker_ok;need;cd "$DIR";docker compose up -d;;stop)docker_ok;need;cd "$DIR";docker compose stop;;restart)docker_ok;need;cd "$DIR";docker compose restart txboard;;logs)logs;;backup)backup;;restore)restore;;diagnose)diagnose;;uninstall)uninstall;;*)echo 'usage: txboard [menu|install|update|status|start|stop|restart|logs|backup|restore|diagnose|uninstall]';exit 2;;esac
