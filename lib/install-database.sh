#!/usr/bin/env bash

# Installation-time database helpers for TXBoard Deploy.
# This file is sourced by install.sh and relies on its prompt/log/validation helpers.

DB_HOST_KIND="${DB_HOST_KIND:-}"
DB_LINK_NETWORK="${DB_LINK_NETWORK:-${TXBOARD_DB_LINK_NETWORK:-txboard-db-link}}"
DB_PROXY_REQUIRED="${DB_PROXY_REQUIRED:-0}"
DB_PROXY_BIND="${DB_PROXY_BIND:-}"
DB_PROXY_PORT="${DB_PROXY_PORT:-${TXBOARD_DB_PROXY_PORT:-13306}}"
DB_SOURCE_PORT="${DB_SOURCE_PORT:-}"
DB_CONTAINER="${DB_CONTAINER:-${TXBOARD_DB_CONTAINER:-}}"
DB_ADMIN_PASSWORD="${DB_ADMIN_PASSWORD:-${TXBOARD_DB_ADMIN_PASSWORD:-}}"

list_mysql_containers() {
  docker ps --format '{{.ID}}\t{{.Names}}\t{{.Image}}' |
    awk 'BEGIN{IGNORECASE=1} $2 ~ /(mysql|mariadb)/ || $3 ~ /(mysql|mariadb)/ {print}'
}

install_db_container_env() {
  local container="$1" key="$2"
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null |
    sed -n "s/^${key}=//p" | head -n1
}

ensure_db_link_network() {
  docker network inspect "$DB_LINK_NETWORK" >/dev/null 2>&1 ||
    docker network create "$DB_LINK_NETWORK" >/dev/null
}

connect_db_container_network() {
  local container="$1"
  ensure_db_link_network
  if ! docker inspect -f '{{json .NetworkSettings.Networks}}' "$container" | grep -q "\"$DB_LINK_NETWORK\""; then
    docker network connect "$DB_LINK_NETWORK" "$container"
  fi
}

mysql_container_exec_root() {
  local container="$1" root_password="$2" sql="$3"
  docker exec -i -e MYSQL_PWD="$root_password" "$container" sh -lc '
    client="$(command -v mysql || command -v mariadb || true)"
    [ -n "$client" ] || { echo "mysql/mariadb client not found in database container" >&2; exit 127; }
    exec "$client" --user=root --protocol=socket
  ' <<<"$sql"
}

wait_mysql_container_admin() {
  local container="$1" root_password="$2" i
  for i in $(seq 1 30); do
    if mysql_container_exec_root "$container" "$root_password" "SELECT 1;" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

mysql_system_client() {
  local candidate

  command -v mysql >/dev/null 2>&1 && { command -v mysql; return; }
  command -v mariadb >/dev/null 2>&1 && { command -v mariadb; return; }

  for candidate in \
    /www/server/mysql/bin/mysql \
    /www/server/mysql/bin/mariadb \
    /usr/local/mysql/bin/mysql \
    /usr/local/mysql/bin/mariadb \
    /usr/local/mariadb/bin/mariadb \
    /usr/local/mariadb/bin/mysql; do
    [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return; }
  done

  return 1
}

mysql_system_exec_root() {
  local client="$1" root_password="$2" sql="$3"
  MYSQL_PWD="$root_password" "$client" --user=root --protocol=socket --execute="$sql"
}

host_database_sql() {
  cat <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USERNAME'@'%' IDENTIFIED BY '$DB_PASSWORD';
ALTER USER '$DB_USERNAME'@'%' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$DB_DATABASE\`.* TO '$DB_USERNAME'@'%';
FLUSH PRIVILEGES;
SQL
}

probe_mysql_from_docker() {
  local host="$1" port="$2"
  docker run --rm --add-host host.docker.internal:host-gateway     -e MYSQL_PWD="$DB_PASSWORD" mysql:8.4.11     mysql --connect-timeout=5 --host="$host" --port="$port"       --user="$DB_USERNAME" --database="$DB_DATABASE" --execute="SELECT 1" >/dev/null 2>&1
}

pick_proxy_port() {
  local port="$DB_PROXY_PORT" i
  valid_port "$port" || port=13306
  if command -v ss >/dev/null 2>&1; then
    for i in $(seq 0 99); do
      if ! ss -ltnH | awk '{print $4}' | grep -Eq "[:.]$((port+i))$"; then
        printf '%s' "$((port+i))"
        return
      fi
    done
    die "cannot find a free Docker-host database proxy port"
  fi
  printf '%s' "$port"
}

setup_host_mysql_container() {
  local -a candidates=()
  local line pick=1 container_id container_name root_password sql
  mapfile -t candidates < <(list_mysql_containers)

  if [[ -n "$DB_CONTAINER" ]]; then
    docker inspect "$DB_CONTAINER" >/dev/null 2>&1 || die "database container not found: $DB_CONTAINER"
    container_id="$(docker inspect -f '{{.Id}}' "$DB_CONTAINER")"
    container_name="$(docker inspect -f '{{.Name}}' "$DB_CONTAINER")"
    container_name="${container_name#/}"
  else
    (("${#candidates[@]}" > 0)) || return 1
    if [[ "$ASSUME_YES" -eq 0 ]]; then
      cat > /dev/tty <<'EOF'

Detected MySQL/MariaDB Docker containers:
EOF
      local i=1
      for line in "${candidates[@]}"; do
        printf '  %d) %s\n' "$i" "$line" > /dev/tty
        ((i++))
      done
      if (("${#candidates[@]}" > 1)); then
        pick="$(choose "Database container" "1" "${#candidates[@]}")"
      fi
    elif (("${#candidates[@]}" > 1)); then
      die "multiple MySQL/MariaDB containers detected; set TXBOARD_DB_CONTAINER or --db-container"
    fi
    IFS=$'\t' read -r container_id container_name _ <<< "${candidates[$((pick-1))]}"
  fi

  DB_DATABASE="$(prompt "Database name" "${DB_DATABASE:-txboard}")"
  DB_USERNAME="$(prompt "Database username" "${DB_USERNAME:-txboard}")"
  [[ "$DB_DATABASE" =~ ^[A-Za-z0-9_]+$ ]] || die "invalid database name: $DB_DATABASE"
  [[ "$DB_USERNAME" =~ ^[A-Za-z0-9_]+$ ]] || die "host database username must contain only letters, digits, and underscore"
  DB_PASSWORD="${DB_PASSWORD:-$(random_hex)}"

  root_password="$DB_ADMIN_PASSWORD"
  if [[ -z "$root_password" ]]; then
    root_password="$(install_db_container_env "$container_id" MYSQL_ROOT_PASSWORD)"
  fi
  if [[ -z "$root_password" ]]; then
    root_password="$(install_db_container_env "$container_id" MARIADB_ROOT_PASSWORD)"
  fi
  sql="$(host_database_sql)"

  if ! wait_mysql_container_admin "$container_id" "$root_password"; then
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      die "cannot administer MySQL container $container_name after waiting for it to become ready; set TXBOARD_DB_ADMIN_PASSWORD if its root password is not exposed in the container environment"
    fi
    root_password="$(prompt_secret "MySQL root/admin password for $container_name" "")"
    wait_mysql_container_admin "$container_id" "$root_password" ||
      die "cannot authenticate as root in MySQL container $container_name"
  fi

  log "creating/updating TXBoard database in host container $container_name..."
  mysql_container_exec_root "$container_id" "$root_password" "$sql" >/dev/null
  connect_db_container_network "$container_id"

  local container_port
  container_port="$(mysql_container_exec_root "$container_id" "$root_password" "SELECT @@port;" 2>/dev/null | tail -n1 | tr -d '[:space:]')"
  valid_port "$container_port" || container_port=3306

  DB_HOST="$container_name"
  DB_PORT="$container_port"
  DB_HOST_KIND="docker-container"
  DB_CONTAINER="$container_name"
  DB_ROOT_PASSWORD=""
  DB_ADMIN_PASSWORD=""
  log "host MySQL container connected through Docker network $DB_LINK_NETWORK"
}

setup_host_system_mysql() {
  local client root_password="" sql source_port gateway probe_name
  client="$(mysql_system_client)" || return 1

  if ! "$client" --user=root --protocol=socket --execute="SELECT 1" >/dev/null 2>&1; then
    root_password="$DB_ADMIN_PASSWORD"
    if [[ -z "$root_password" && "$ASSUME_YES" -eq 0 ]]; then
      root_password="$(prompt_secret "System MySQL root/admin password" "")"
    fi
    [[ -n "$root_password" ]] ||
      die "system MySQL requires admin credentials; set TXBOARD_DB_ADMIN_PASSWORD"
    mysql_system_exec_root "$client" "$root_password" "SELECT 1;" >/dev/null 2>&1 ||
      die "cannot authenticate to system MySQL as root"
  fi

  DB_DATABASE="$(prompt "Database name" "${DB_DATABASE:-txboard}")"
  DB_USERNAME="$(prompt "Database username" "${DB_USERNAME:-txboard}")"
  [[ "$DB_DATABASE" =~ ^[A-Za-z0-9_]+$ ]] || die "invalid database name: $DB_DATABASE"
  [[ "$DB_USERNAME" =~ ^[A-Za-z0-9_]+$ ]] || die "host database username must contain only letters, digits, and underscore"
  DB_PASSWORD="${DB_PASSWORD:-$(random_hex)}"
  sql="$(host_database_sql)"
  mysql_system_exec_root "$client" "$root_password" "$sql" >/dev/null

  source_port="$(MYSQL_PWD="$root_password" "$client" --user=root --protocol=socket --batch --skip-column-names --execute='SELECT @@port;' 2>/dev/null | tail -n1)"
  valid_port "$source_port" || source_port=3306
  DB_SOURCE_PORT="$source_port"

  log "testing Docker -> host MySQL connectivity..."
  if probe_mysql_from_docker host.docker.internal "$source_port"; then
    DB_HOST="host.docker.internal"
    DB_PORT="$source_port"
    DB_HOST_KIND="system-direct"
    DB_PROXY_REQUIRED=0
    DB_ROOT_PASSWORD=""
    DB_ADMIN_PASSWORD=""
    log "system MySQL is reachable directly through host.docker.internal"
    return 0
  fi

  gateway="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)"
  gateway="${gateway:-172.17.0.1}"
  DB_PROXY_BIND="$gateway"
  DB_PROXY_PORT="$(pick_proxy_port)"
  probe_name="txboard-db-proxy-probe-$$"

  warn "system MySQL is not reachable from Docker (often bind-address=127.0.0.1); enabling a Docker-gateway-only proxy"
  docker run -d --rm --name "$probe_name" --network host alpine/socat:latest     "TCP-LISTEN:${DB_PROXY_PORT},bind=${DB_PROXY_BIND},fork,reuseaddr"     "TCP:127.0.0.1:${source_port}" >/dev/null
  sleep 1
  if ! probe_mysql_from_docker host.docker.internal "$DB_PROXY_PORT"; then
    docker rm -f "$probe_name" >/dev/null 2>&1 || true
    die "system MySQL is loopback-only and the safe Docker gateway proxy could not reach it"
  fi
  docker rm -f "$probe_name" >/dev/null 2>&1 || true

  DB_HOST="host.docker.internal"
  DB_PORT="$DB_PROXY_PORT"
  DB_HOST_KIND="system-proxy"
  DB_PROXY_REQUIRED=1
  DB_ROOT_PASSWORD=""
  DB_ADMIN_PASSWORD=""
  log "system MySQL will be exposed only on Docker gateway $DB_PROXY_BIND:$DB_PROXY_PORT"
}

setup_host_database() {
  local -a container_candidates=()
  local system_client="" line pick max_choice container_name container_image

  # Explicit Docker selection remains authoritative for unattended installs and
  # callers that already know which container should be used.
  if [[ -n "$DB_CONTAINER" ]]; then
    setup_host_mysql_container
    return
  fi

  mapfile -t container_candidates < <(list_mysql_containers)
  system_client="$(mysql_system_client 2>/dev/null || true)"

  # Interactive host mode should present all locally manageable database
  # runtimes together. Previously any Docker MySQL short-circuited discovery,
  # which made a simultaneously installed system/BT-Panel MySQL invisible.
  if [[ "$ASSUME_YES" -eq 0 && -n "$system_client" && "${#container_candidates[@]}" -gt 0 ]]; then
    cat > /dev/tty <<'EOF'

Detected MySQL/MariaDB instances on this server:
EOF
    local i=1
    for line in "${container_candidates[@]}"; do
      IFS=

configure_database() {
  if [[ -z "$DB_MODE" ]]; then
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      DB_MODE="local"
    else
      cat > /dev/tty <<'EOF'

Choose database mode:
  1) Managed MySQL 8.4 container
  2) MySQL on this server (auto-detect system / 1Panel / Docker)
  3) External MySQL server

EOF
      local db_choice
      db_choice="$(choose "Database" "1" "3")"
      case "$db_choice" in
        1) DB_MODE="local" ;;
        2) DB_MODE="host" ;;
        3) DB_MODE="external" ;;
      esac
    fi
  fi

  case "$DB_MODE" in
    local)
      DB_HOST="database"
      DB_PORT="3306"
      DB_HOST_KIND="managed"
      [[ "$DB_DATABASE" =~ ^[A-Za-z0-9_]+$ ]] || die "invalid database name: $DB_DATABASE"
      [[ -n "$DB_USERNAME" && ! "$DB_USERNAME" =~ [[:space:]] ]] || die "invalid database username"

      if [[ "$RENDER_ONLY" -eq 0 ]] && docker volume inspect "$LOCAL_DB_VOLUME" >/dev/null 2>&1; then
        if [[ "$RESET_LOCAL_DB" -eq 1 ]]; then
          warn "deleting existing managed MySQL volume: $LOCAL_DB_VOLUME"
          docker volume rm "$LOCAL_DB_VOLUME" >/dev/null ||
            die "cannot remove $LOCAL_DB_VOLUME; it may still be attached to another TXBoard container"
        elif [[ "$ASSUME_YES" -eq 1 ]]; then
          die "existing managed MySQL volume $LOCAL_DB_VOLUME detected. Refusing to generate new credentials for an initialized database. Preserve it by recovering the original deployment/credentials, or rerun a disposable fresh install with --reset-local-db."
        else
          cat > /dev/tty <<EOF

Existing TXBoard managed MySQL volume detected:

  $LOCAL_DB_VOLUME

MySQL initialization passwords are only applied to an empty data directory.
Continuing with newly generated passwords would make the application fail
authentication and can hide an existing database from the new deployment.

EOF
          if confirm "Delete this database volume and continue with a completely fresh install? ALL DATABASE DATA WILL BE LOST." "N"; then
            warn "deleting existing managed MySQL volume: $LOCAL_DB_VOLUME"
            docker volume rm "$LOCAL_DB_VOLUME" >/dev/null ||
              die "cannot remove $LOCAL_DB_VOLUME; it may still be attached to another TXBoard container"
          else
            die "installation stopped to preserve the existing database volume"
          fi
        fi
      fi

      DB_PASSWORD="${DB_PASSWORD:-$(random_hex)}"
      DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-$(random_hex)}"
      ;;
    host)
      setup_host_database
      ;;
    external)
      DB_HOST="$(prompt "External MySQL host" "$DB_HOST")"
      DB_PORT="$(prompt "External MySQL port" "${DB_PORT:-3306}")"
      DB_DATABASE="$(prompt "Database name" "${DB_DATABASE:-txboard}")"
      DB_USERNAME="$(prompt "Database username" "$DB_USERNAME")"
      if [[ "$ASSUME_YES" -eq 1 && -z "$DB_PASSWORD" ]]; then
        die "external database mode requires TXBOARD_DB_PASSWORD or --db-password"
      fi
      DB_PASSWORD="$(prompt_secret "Database password" "$DB_PASSWORD")"
      [[ -n "$DB_HOST" && ! "$DB_HOST" =~ [[:space:]] ]] || die "invalid external database host"
      valid_port "$DB_PORT" || die "invalid external database port: $DB_PORT"
      [[ "$DB_DATABASE" =~ ^[A-Za-z0-9_]+$ ]] || die "invalid database name: $DB_DATABASE"
      [[ -n "$DB_USERNAME" && ! "$DB_USERNAME" =~ [[:space:]] ]] || die "invalid database username"
      [[ -n "$DB_PASSWORD" ]] || die "database password cannot be empty"

      if [[ "$DB_HOST" == "127.0.0.1" || "$DB_HOST" == "localhost" ]]; then
        if [[ "$ASSUME_YES" -eq 1 ]]; then
          die "external database host '$DB_HOST' resolves inside the TXBoard container, not to the Docker host. Use host mode for MySQL running on this server."
        fi
        warn "external DB host $DB_HOST points to the TXBoard container itself"
        if confirm "Switch to automatic host-MySQL mode instead?" "Y"; then
          DB_MODE="host"
          DB_HOST=""
          setup_host_database
          return
        fi
        die "use host database mode for MySQL on this server, or provide a Docker-reachable external host"
      fi

      DB_ROOT_PASSWORD=""
      DB_HOST_KIND="external"
      ;;
    *)
      die "invalid database mode: $DB_MODE"
      ;;
  esac
}

prepare_database_compose_blocks() {
  DATABASE_SERVICE_BLOCK=""
  DB_PROXY_SERVICE_BLOCK=""
  TXBOARD_DB_DEPENDS_BLOCK=""
  BACKUP_DB_DEPENDS_BLOCK=""
  DATABASE_VOLUME_BLOCK=""
  DB_EXTRA_HOSTS_BLOCK=""
  DB_NETWORKS_BLOCK=""
  DB_NETWORK_DECL_BLOCK=""

  if [[ "$DB_MODE" == "local" ]]; then
    DATABASE_SERVICE_BLOCK="$(cat <<'YAML'
  database:
    image: mysql:8.4.11
    restart: unless-stopped
    logging: *default-logging
    environment:
      MYSQL_DATABASE: ${TXBOARD_DB_DATABASE:-txboard}
      MYSQL_USER: ${TXBOARD_DB_USERNAME:-txboard}
      MYSQL_PASSWORD: ${TXBOARD_DB_PASSWORD:?missing TXBOARD_DB_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${TXBOARD_DB_ROOT_PASSWORD:?missing TXBOARD_DB_ROOT_PASSWORD}
    volumes:
      - database-data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "--host=127.0.0.1", "--user=root", "--password=${TXBOARD_DB_ROOT_PASSWORD:?}"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 40s
YAML
)"
    TXBOARD_DB_DEPENDS_BLOCK="$(cat <<'YAML'
    depends_on:
      database:
        condition: service_healthy
YAML
)"
    BACKUP_DB_DEPENDS_BLOCK="$TXBOARD_DB_DEPENDS_BLOCK"
    DATABASE_VOLUME_BLOCK="  database-data:"
  elif [[ "$DB_MODE" == "host" && "$DB_HOST_KIND" == "docker-container" ]]; then
    DB_NETWORKS_BLOCK="$(cat <<'YAML'
    networks:
      - default
      - db_link
YAML
)"
    DB_NETWORK_DECL_BLOCK="$(cat <<YAML
networks:
  db_link:
    external: true
    name: $DB_LINK_NETWORK
YAML
)"
  elif [[ "$DB_MODE" == "host" && "$DB_PROXY_REQUIRED" -eq 1 ]]; then
    DB_EXTRA_HOSTS_BLOCK="$(cat <<'YAML'
    extra_hosts:
      - "host.docker.internal:host-gateway"
YAML
)"
    DB_PROXY_SERVICE_BLOCK="$(cat <<'YAML'
  db-proxy:
    image: alpine/socat:latest
    restart: unless-stopped
    logging: *default-logging
    network_mode: host
    command:
      - "TCP-LISTEN:${TXBOARD_DB_PROXY_PORT:?missing TXBOARD_DB_PROXY_PORT},bind=${TXBOARD_DB_PROXY_BIND:?missing TXBOARD_DB_PROXY_BIND},fork,reuseaddr"
      - "TCP:127.0.0.1:${TXBOARD_DB_SOURCE_PORT:?missing TXBOARD_DB_SOURCE_PORT}"
YAML
)"
    TXBOARD_DB_DEPENDS_BLOCK="$(cat <<'YAML'
    depends_on:
      db-proxy:
        condition: service_started
YAML
)"
    BACKUP_DB_DEPENDS_BLOCK="$TXBOARD_DB_DEPENDS_BLOCK"
  else
    DB_EXTRA_HOSTS_BLOCK="$(cat <<'YAML'
    extra_hosts:
      - "host.docker.internal:host-gateway"
YAML
)"
  fi
}

verify_database_connectivity() {
  if [[ "$DB_MODE" == "local" ]]; then
    log "starting managed database..."
    docker compose up -d --remove-orphans --wait database

    log "verifying managed database credentials..."
    if ! docker compose exec -T database sh -lc         'MYSQL_PWD="$MYSQL_PASSWORD" mysql --protocol=TCP --host=127.0.0.1 --port=3306 --user="$MYSQL_USER" --database="$MYSQL_DATABASE" --execute="SELECT 1" >/dev/null' </dev/null; then
      die "managed MySQL rejected the configured TXBoard credentials. The database volume may have been initialized with older passwords. Preserve existing data and recover its original credentials, or remove the stale deployment and rerun a disposable fresh install with --reset-local-db."
    fi
    return
  fi

  if [[ "$DB_MODE" == "host" && "$DB_PROXY_REQUIRED" -eq 1 ]]; then
    log "starting safe host-MySQL Docker gateway proxy..."
    docker compose up -d --remove-orphans db-proxy
  fi

  log "checking $DB_MODE database connectivity from the TXBoard Docker network..."
  if ! docker compose run -T --rm --no-deps --entrypoint sh backup -lc       'MYSQL_PWD="$DB_PASSWORD" mysql --connect-timeout=5 --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USERNAME" --database="$DB_DATABASE" --execute="SELECT 1" >/dev/null' </dev/null; then
    die "cannot connect to $DB_MODE MySQL at $DB_HOST:$DB_PORT/$DB_DATABASE from the TXBoard container. Check the selected database, Docker networking, firewall, and MySQL user host permissions."
  fi
}
\t' read -r _ container_name container_image <<< "$line"
      printf '  %d) Docker: %s (%s)\n' "$i" "$container_name" "$container_image" > /dev/tty
      ((i++))
    done
    printf '  %d) System/local: %s\n' "$i" "$system_client" > /dev/tty

    max_choice="$i"
    pick="$(choose "Host database" "1" "$max_choice")"
    if (( pick <= ${#container_candidates[@]} )); then
      IFS=

configure_database() {
  if [[ -z "$DB_MODE" ]]; then
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      DB_MODE="local"
    else
      cat > /dev/tty <<'EOF'

Choose database mode:
  1) Managed MySQL 8.4 container
  2) MySQL on this server (auto-detect system / 1Panel / Docker)
  3) External MySQL server

EOF
      local db_choice
      db_choice="$(choose "Database" "1" "3")"
      case "$db_choice" in
        1) DB_MODE="local" ;;
        2) DB_MODE="host" ;;
        3) DB_MODE="external" ;;
      esac
    fi
  fi

  case "$DB_MODE" in
    local)
      DB_HOST="database"
      DB_PORT="3306"
      DB_HOST_KIND="managed"
      [[ "$DB_DATABASE" =~ ^[A-Za-z0-9_]+$ ]] || die "invalid database name: $DB_DATABASE"
      [[ -n "$DB_USERNAME" && ! "$DB_USERNAME" =~ [[:space:]] ]] || die "invalid database username"

      if [[ "$RENDER_ONLY" -eq 0 ]] && docker volume inspect "$LOCAL_DB_VOLUME" >/dev/null 2>&1; then
        if [[ "$RESET_LOCAL_DB" -eq 1 ]]; then
          warn "deleting existing managed MySQL volume: $LOCAL_DB_VOLUME"
          docker volume rm "$LOCAL_DB_VOLUME" >/dev/null ||
            die "cannot remove $LOCAL_DB_VOLUME; it may still be attached to another TXBoard container"
        elif [[ "$ASSUME_YES" -eq 1 ]]; then
          die "existing managed MySQL volume $LOCAL_DB_VOLUME detected. Refusing to generate new credentials for an initialized database. Preserve it by recovering the original deployment/credentials, or rerun a disposable fresh install with --reset-local-db."
        else
          cat > /dev/tty <<EOF

Existing TXBoard managed MySQL volume detected:

  $LOCAL_DB_VOLUME

MySQL initialization passwords are only applied to an empty data directory.
Continuing with newly generated passwords would make the application fail
authentication and can hide an existing database from the new deployment.

EOF
          if confirm "Delete this database volume and continue with a completely fresh install? ALL DATABASE DATA WILL BE LOST." "N"; then
            warn "deleting existing managed MySQL volume: $LOCAL_DB_VOLUME"
            docker volume rm "$LOCAL_DB_VOLUME" >/dev/null ||
              die "cannot remove $LOCAL_DB_VOLUME; it may still be attached to another TXBoard container"
          else
            die "installation stopped to preserve the existing database volume"
          fi
        fi
      fi

      DB_PASSWORD="${DB_PASSWORD:-$(random_hex)}"
      DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-$(random_hex)}"
      ;;
    host)
      setup_host_database
      ;;
    external)
      DB_HOST="$(prompt "External MySQL host" "$DB_HOST")"
      DB_PORT="$(prompt "External MySQL port" "${DB_PORT:-3306}")"
      DB_DATABASE="$(prompt "Database name" "${DB_DATABASE:-txboard}")"
      DB_USERNAME="$(prompt "Database username" "$DB_USERNAME")"
      if [[ "$ASSUME_YES" -eq 1 && -z "$DB_PASSWORD" ]]; then
        die "external database mode requires TXBOARD_DB_PASSWORD or --db-password"
      fi
      DB_PASSWORD="$(prompt_secret "Database password" "$DB_PASSWORD")"
      [[ -n "$DB_HOST" && ! "$DB_HOST" =~ [[:space:]] ]] || die "invalid external database host"
      valid_port "$DB_PORT" || die "invalid external database port: $DB_PORT"
      [[ "$DB_DATABASE" =~ ^[A-Za-z0-9_]+$ ]] || die "invalid database name: $DB_DATABASE"
      [[ -n "$DB_USERNAME" && ! "$DB_USERNAME" =~ [[:space:]] ]] || die "invalid database username"
      [[ -n "$DB_PASSWORD" ]] || die "database password cannot be empty"

      if [[ "$DB_HOST" == "127.0.0.1" || "$DB_HOST" == "localhost" ]]; then
        if [[ "$ASSUME_YES" -eq 1 ]]; then
          die "external database host '$DB_HOST' resolves inside the TXBoard container, not to the Docker host. Use host mode for MySQL running on this server."
        fi
        warn "external DB host $DB_HOST points to the TXBoard container itself"
        if confirm "Switch to automatic host-MySQL mode instead?" "Y"; then
          DB_MODE="host"
          DB_HOST=""
          setup_host_database
          return
        fi
        die "use host database mode for MySQL on this server, or provide a Docker-reachable external host"
      fi

      DB_ROOT_PASSWORD=""
      DB_HOST_KIND="external"
      ;;
    *)
      die "invalid database mode: $DB_MODE"
      ;;
  esac
}

prepare_database_compose_blocks() {
  DATABASE_SERVICE_BLOCK=""
  DB_PROXY_SERVICE_BLOCK=""
  TXBOARD_DB_DEPENDS_BLOCK=""
  BACKUP_DB_DEPENDS_BLOCK=""
  DATABASE_VOLUME_BLOCK=""
  DB_EXTRA_HOSTS_BLOCK=""
  DB_NETWORKS_BLOCK=""
  DB_NETWORK_DECL_BLOCK=""

  if [[ "$DB_MODE" == "local" ]]; then
    DATABASE_SERVICE_BLOCK="$(cat <<'YAML'
  database:
    image: mysql:8.4.11
    restart: unless-stopped
    logging: *default-logging
    environment:
      MYSQL_DATABASE: ${TXBOARD_DB_DATABASE:-txboard}
      MYSQL_USER: ${TXBOARD_DB_USERNAME:-txboard}
      MYSQL_PASSWORD: ${TXBOARD_DB_PASSWORD:?missing TXBOARD_DB_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${TXBOARD_DB_ROOT_PASSWORD:?missing TXBOARD_DB_ROOT_PASSWORD}
    volumes:
      - database-data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "--host=127.0.0.1", "--user=root", "--password=${TXBOARD_DB_ROOT_PASSWORD:?}"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 40s
YAML
)"
    TXBOARD_DB_DEPENDS_BLOCK="$(cat <<'YAML'
    depends_on:
      database:
        condition: service_healthy
YAML
)"
    BACKUP_DB_DEPENDS_BLOCK="$TXBOARD_DB_DEPENDS_BLOCK"
    DATABASE_VOLUME_BLOCK="  database-data:"
  elif [[ "$DB_MODE" == "host" && "$DB_HOST_KIND" == "docker-container" ]]; then
    DB_NETWORKS_BLOCK="$(cat <<'YAML'
    networks:
      - default
      - db_link
YAML
)"
    DB_NETWORK_DECL_BLOCK="$(cat <<YAML
networks:
  db_link:
    external: true
    name: $DB_LINK_NETWORK
YAML
)"
  elif [[ "$DB_MODE" == "host" && "$DB_PROXY_REQUIRED" -eq 1 ]]; then
    DB_EXTRA_HOSTS_BLOCK="$(cat <<'YAML'
    extra_hosts:
      - "host.docker.internal:host-gateway"
YAML
)"
    DB_PROXY_SERVICE_BLOCK="$(cat <<'YAML'
  db-proxy:
    image: alpine/socat:latest
    restart: unless-stopped
    logging: *default-logging
    network_mode: host
    command:
      - "TCP-LISTEN:${TXBOARD_DB_PROXY_PORT:?missing TXBOARD_DB_PROXY_PORT},bind=${TXBOARD_DB_PROXY_BIND:?missing TXBOARD_DB_PROXY_BIND},fork,reuseaddr"
      - "TCP:127.0.0.1:${TXBOARD_DB_SOURCE_PORT:?missing TXBOARD_DB_SOURCE_PORT}"
YAML
)"
    TXBOARD_DB_DEPENDS_BLOCK="$(cat <<'YAML'
    depends_on:
      db-proxy:
        condition: service_started
YAML
)"
    BACKUP_DB_DEPENDS_BLOCK="$TXBOARD_DB_DEPENDS_BLOCK"
  else
    DB_EXTRA_HOSTS_BLOCK="$(cat <<'YAML'
    extra_hosts:
      - "host.docker.internal:host-gateway"
YAML
)"
  fi
}

verify_database_connectivity() {
  if [[ "$DB_MODE" == "local" ]]; then
    log "starting managed database..."
    docker compose up -d --remove-orphans --wait database

    log "verifying managed database credentials..."
    if ! docker compose exec -T database sh -lc         'MYSQL_PWD="$MYSQL_PASSWORD" mysql --protocol=TCP --host=127.0.0.1 --port=3306 --user="$MYSQL_USER" --database="$MYSQL_DATABASE" --execute="SELECT 1" >/dev/null' </dev/null; then
      die "managed MySQL rejected the configured TXBoard credentials. The database volume may have been initialized with older passwords. Preserve existing data and recover its original credentials, or remove the stale deployment and rerun a disposable fresh install with --reset-local-db."
    fi
    return
  fi

  if [[ "$DB_MODE" == "host" && "$DB_PROXY_REQUIRED" -eq 1 ]]; then
    log "starting safe host-MySQL Docker gateway proxy..."
    docker compose up -d --remove-orphans db-proxy
  fi

  log "checking $DB_MODE database connectivity from the TXBoard Docker network..."
  if ! docker compose run -T --rm --no-deps --entrypoint sh backup -lc       'MYSQL_PWD="$DB_PASSWORD" mysql --connect-timeout=5 --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USERNAME" --database="$DB_DATABASE" --execute="SELECT 1" >/dev/null' </dev/null; then
    die "cannot connect to $DB_MODE MySQL at $DB_HOST:$DB_PORT/$DB_DATABASE from the TXBoard container. Check the selected database, Docker networking, firewall, and MySQL user host permissions."
  fi
}
\t' read -r _ container_name _ <<< "${container_candidates[$((pick-1))]}"
      DB_CONTAINER="$container_name"
      setup_host_mysql_container
    else
      setup_host_system_mysql
    fi
    return
  fi

  # Preserve the existing unattended/default behavior when only one runtime
  # family is available: Docker first, then system/local MySQL.
  if setup_host_mysql_container; then return 0; fi
  if setup_host_system_mysql; then return 0; fi
  die "no manageable host MySQL/MariaDB found. Use external mode if the database is remote or managed separately."
}

configure_database() {
  if [[ -z "$DB_MODE" ]]; then
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      DB_MODE="local"
    else
      cat > /dev/tty <<'EOF'

Choose database mode:
  1) Managed MySQL 8.4 container
  2) MySQL on this server (auto-detect system / 1Panel / Docker)
  3) External MySQL server

EOF
      local db_choice
      db_choice="$(choose "Database" "1" "3")"
      case "$db_choice" in
        1) DB_MODE="local" ;;
        2) DB_MODE="host" ;;
        3) DB_MODE="external" ;;
      esac
    fi
  fi

  case "$DB_MODE" in
    local)
      DB_HOST="database"
      DB_PORT="3306"
      DB_HOST_KIND="managed"
      [[ "$DB_DATABASE" =~ ^[A-Za-z0-9_]+$ ]] || die "invalid database name: $DB_DATABASE"
      [[ -n "$DB_USERNAME" && ! "$DB_USERNAME" =~ [[:space:]] ]] || die "invalid database username"

      if [[ "$RENDER_ONLY" -eq 0 ]] && docker volume inspect "$LOCAL_DB_VOLUME" >/dev/null 2>&1; then
        if [[ "$RESET_LOCAL_DB" -eq 1 ]]; then
          warn "deleting existing managed MySQL volume: $LOCAL_DB_VOLUME"
          docker volume rm "$LOCAL_DB_VOLUME" >/dev/null ||
            die "cannot remove $LOCAL_DB_VOLUME; it may still be attached to another TXBoard container"
        elif [[ "$ASSUME_YES" -eq 1 ]]; then
          die "existing managed MySQL volume $LOCAL_DB_VOLUME detected. Refusing to generate new credentials for an initialized database. Preserve it by recovering the original deployment/credentials, or rerun a disposable fresh install with --reset-local-db."
        else
          cat > /dev/tty <<EOF

Existing TXBoard managed MySQL volume detected:

  $LOCAL_DB_VOLUME

MySQL initialization passwords are only applied to an empty data directory.
Continuing with newly generated passwords would make the application fail
authentication and can hide an existing database from the new deployment.

EOF
          if confirm "Delete this database volume and continue with a completely fresh install? ALL DATABASE DATA WILL BE LOST." "N"; then
            warn "deleting existing managed MySQL volume: $LOCAL_DB_VOLUME"
            docker volume rm "$LOCAL_DB_VOLUME" >/dev/null ||
              die "cannot remove $LOCAL_DB_VOLUME; it may still be attached to another TXBoard container"
          else
            die "installation stopped to preserve the existing database volume"
          fi
        fi
      fi

      DB_PASSWORD="${DB_PASSWORD:-$(random_hex)}"
      DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-$(random_hex)}"
      ;;
    host)
      setup_host_database
      ;;
    external)
      DB_HOST="$(prompt "External MySQL host" "$DB_HOST")"
      DB_PORT="$(prompt "External MySQL port" "${DB_PORT:-3306}")"
      DB_DATABASE="$(prompt "Database name" "${DB_DATABASE:-txboard}")"
      DB_USERNAME="$(prompt "Database username" "$DB_USERNAME")"
      if [[ "$ASSUME_YES" -eq 1 && -z "$DB_PASSWORD" ]]; then
        die "external database mode requires TXBOARD_DB_PASSWORD or --db-password"
      fi
      DB_PASSWORD="$(prompt_secret "Database password" "$DB_PASSWORD")"
      [[ -n "$DB_HOST" && ! "$DB_HOST" =~ [[:space:]] ]] || die "invalid external database host"
      valid_port "$DB_PORT" || die "invalid external database port: $DB_PORT"
      [[ "$DB_DATABASE" =~ ^[A-Za-z0-9_]+$ ]] || die "invalid database name: $DB_DATABASE"
      [[ -n "$DB_USERNAME" && ! "$DB_USERNAME" =~ [[:space:]] ]] || die "invalid database username"
      [[ -n "$DB_PASSWORD" ]] || die "database password cannot be empty"

      if [[ "$DB_HOST" == "127.0.0.1" || "$DB_HOST" == "localhost" ]]; then
        if [[ "$ASSUME_YES" -eq 1 ]]; then
          die "external database host '$DB_HOST' resolves inside the TXBoard container, not to the Docker host. Use host mode for MySQL running on this server."
        fi
        warn "external DB host $DB_HOST points to the TXBoard container itself"
        if confirm "Switch to automatic host-MySQL mode instead?" "Y"; then
          DB_MODE="host"
          DB_HOST=""
          setup_host_database
          return
        fi
        die "use host database mode for MySQL on this server, or provide a Docker-reachable external host"
      fi

      DB_ROOT_PASSWORD=""
      DB_HOST_KIND="external"
      ;;
    *)
      die "invalid database mode: $DB_MODE"
      ;;
  esac
}

prepare_database_compose_blocks() {
  DATABASE_SERVICE_BLOCK=""
  DB_PROXY_SERVICE_BLOCK=""
  TXBOARD_DB_DEPENDS_BLOCK=""
  BACKUP_DB_DEPENDS_BLOCK=""
  DATABASE_VOLUME_BLOCK=""
  DB_EXTRA_HOSTS_BLOCK=""
  DB_NETWORKS_BLOCK=""
  DB_NETWORK_DECL_BLOCK=""

  if [[ "$DB_MODE" == "local" ]]; then
    DATABASE_SERVICE_BLOCK="$(cat <<'YAML'
  database:
    image: mysql:8.4.11
    restart: unless-stopped
    logging: *default-logging
    environment:
      MYSQL_DATABASE: ${TXBOARD_DB_DATABASE:-txboard}
      MYSQL_USER: ${TXBOARD_DB_USERNAME:-txboard}
      MYSQL_PASSWORD: ${TXBOARD_DB_PASSWORD:?missing TXBOARD_DB_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${TXBOARD_DB_ROOT_PASSWORD:?missing TXBOARD_DB_ROOT_PASSWORD}
    volumes:
      - database-data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "--host=127.0.0.1", "--user=root", "--password=${TXBOARD_DB_ROOT_PASSWORD:?}"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 40s
YAML
)"
    TXBOARD_DB_DEPENDS_BLOCK="$(cat <<'YAML'
    depends_on:
      database:
        condition: service_healthy
YAML
)"
    BACKUP_DB_DEPENDS_BLOCK="$TXBOARD_DB_DEPENDS_BLOCK"
    DATABASE_VOLUME_BLOCK="  database-data:"
  elif [[ "$DB_MODE" == "host" && "$DB_HOST_KIND" == "docker-container" ]]; then
    DB_NETWORKS_BLOCK="$(cat <<'YAML'
    networks:
      - default
      - db_link
YAML
)"
    DB_NETWORK_DECL_BLOCK="$(cat <<YAML
networks:
  db_link:
    external: true
    name: $DB_LINK_NETWORK
YAML
)"
  elif [[ "$DB_MODE" == "host" && "$DB_PROXY_REQUIRED" -eq 1 ]]; then
    DB_EXTRA_HOSTS_BLOCK="$(cat <<'YAML'
    extra_hosts:
      - "host.docker.internal:host-gateway"
YAML
)"
    DB_PROXY_SERVICE_BLOCK="$(cat <<'YAML'
  db-proxy:
    image: alpine/socat:latest
    restart: unless-stopped
    logging: *default-logging
    network_mode: host
    command:
      - "TCP-LISTEN:${TXBOARD_DB_PROXY_PORT:?missing TXBOARD_DB_PROXY_PORT},bind=${TXBOARD_DB_PROXY_BIND:?missing TXBOARD_DB_PROXY_BIND},fork,reuseaddr"
      - "TCP:127.0.0.1:${TXBOARD_DB_SOURCE_PORT:?missing TXBOARD_DB_SOURCE_PORT}"
YAML
)"
    TXBOARD_DB_DEPENDS_BLOCK="$(cat <<'YAML'
    depends_on:
      db-proxy:
        condition: service_started
YAML
)"
    BACKUP_DB_DEPENDS_BLOCK="$TXBOARD_DB_DEPENDS_BLOCK"
  else
    DB_EXTRA_HOSTS_BLOCK="$(cat <<'YAML'
    extra_hosts:
      - "host.docker.internal:host-gateway"
YAML
)"
  fi
}

verify_database_connectivity() {
  if [[ "$DB_MODE" == "local" ]]; then
    log "starting managed database..."
    docker compose up -d --remove-orphans --wait database

    log "verifying managed database credentials..."
    if ! docker compose exec -T database sh -lc         'MYSQL_PWD="$MYSQL_PASSWORD" mysql --protocol=TCP --host=127.0.0.1 --port=3306 --user="$MYSQL_USER" --database="$MYSQL_DATABASE" --execute="SELECT 1" >/dev/null' </dev/null; then
      die "managed MySQL rejected the configured TXBoard credentials. The database volume may have been initialized with older passwords. Preserve existing data and recover its original credentials, or remove the stale deployment and rerun a disposable fresh install with --reset-local-db."
    fi
    return
  fi

  if [[ "$DB_MODE" == "host" && "$DB_PROXY_REQUIRED" -eq 1 ]]; then
    log "starting safe host-MySQL Docker gateway proxy..."
    docker compose up -d --remove-orphans db-proxy
  fi

  log "checking $DB_MODE database connectivity from the TXBoard Docker network..."
  if ! docker compose run -T --rm --no-deps --entrypoint sh backup -lc       'MYSQL_PWD="$DB_PASSWORD" mysql --connect-timeout=5 --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USERNAME" --database="$DB_DATABASE" --execute="SELECT 1" >/dev/null' </dev/null; then
    die "cannot connect to $DB_MODE MySQL at $DB_HOST:$DB_PORT/$DB_DATABASE from the TXBoard container. Check the selected database, Docker networking, firewall, and MySQL user host permissions."
  fi
}
