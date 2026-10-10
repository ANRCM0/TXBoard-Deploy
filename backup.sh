#!/bin/sh
#
# Back up everything needed to rebuild this instance.
#
# Runs both as the compose `backup` service (periodic) and as a one-shot host
# command (`TXBOARD_BACKUP_INTERVAL` unset/0).
#
# What is captured, and why:
#   db.sql.gz           the whole schema and data
#   env                 APP_KEY lives here. The encrypted columns in the dump are
#                       unreadable without it, so a database-only backup is not
#                       a backup.
#   storage-app.tar.gz  uploads and anything else under storage/app
#   storage-theme.tar.gz  installed user themes under storage/theme (if present)
#   plugins.tar.gz        installed plugins under plugins (if present)
#   CHECKSUMS.sha256      integrity for all present backed-up payloads
#   MANIFEST            what the archive is, so a restore needs no guesswork
#
# Environment:
#   DB_HOST, DB_PORT, DB_DATABASE, DB_USERNAME, DB_PASSWORD   connection
#   BACKUP_DIR        where archives are written          (default /backups)
#   BACKUP_RETENTION  archives to keep, 0 = keep all      (default 7)
#   BACKUP_INTERVAL   seconds between runs, 0 = run once  (default 0)
#   BACKUP_SOURCE_DIR the api checkout holding .env       (default /backup-source/api)
#
set -eu
umask 077

DB_HOST="${DB_HOST:-database}"
DB_PORT="${DB_PORT:-3306}"
DB_DATABASE="${DB_DATABASE:?DB_DATABASE is required}"
DB_USERNAME="${DB_USERNAME:?DB_USERNAME is required}"
DB_PASSWORD="${DB_PASSWORD:-}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
BACKUP_RETENTION="${BACKUP_RETENTION:-7}"
BACKUP_INTERVAL="${BACKUP_INTERVAL:-0}"
BACKUP_SOURCE_DIR="${BACKUP_SOURCE_DIR:-/backup-source/api}"

log() { echo "[backup] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }

prune() {
    case "$BACKUP_RETENTION" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$BACKUP_RETENTION" -gt 0 ] || return 0

    total=$(ls -1 "$BACKUP_DIR" 2>/dev/null | grep -cE '^[0-9]{8}T[0-9]{6}Z$' || true)
    [ "$total" -gt "$BACKUP_RETENTION" ] || return 0

    remove=$((total - BACKUP_RETENTION))
    log "pruning $remove archive(s), keeping $BACKUP_RETENTION"
    ls -1 "$BACKUP_DIR" | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort | head -n "$remove" |
        while read -r old; do
            [ -n "$old" ] || continue
            rm -rf "$BACKUP_DIR/$old"
        done
}

run_backup() (
    stamp=$(date -u '+%Y%m%dT%H%M%SZ')
    dest="$BACKUP_DIR/$stamp"
    mkdir -p "$BACKUP_DIR"
    # Refuse same-second parallel backups: a failed copy must never delete
    # an existing complete snapshot sharing the timestamp.
    if ! mkdir "$dest"; then
        log "ERROR: archive timestamp collision; existing snapshot untouched"
        return 1
    fi
    trap 'rm -rf "$dest"' EXIT
    trap 'exit 1' HUP INT TERM

    log "dumping $DB_DATABASE@$DB_HOST:$DB_PORT -> $dest/db.sql.gz"
    # --single-transaction keeps InnoDB consistent without locking the panel.
    # --set-gtid-purged=OFF stops mysqldump emitting GTID statements that a
    # restore into a server without GTID enabled would reject.
    # POSIX sh reports only the last command's status in a pipeline.
    # Export first and check mysqldump before compressing the archive.
    dump_file="$dest/db.sql"
    if ! MYSQL_PWD="$DB_PASSWORD" mysqldump \
            --host="$DB_HOST" \
            --port="$DB_PORT" \
            --user="$DB_USERNAME" \
            --single-transaction \
            --quick \
            --routines \
            --events \
            --triggers \
            --set-gtid-purged=OFF \
            --default-character-set=utf8mb4 \
            "$DB_DATABASE" > "$dump_file" 2>/dev/null; then
        log "ERROR: mysqldump failed; discarding the partial archive"
        rm -rf "$dest"
        return 1
    fi
    if [ ! -s "$dump_file" ] || ! gzip -9 "$dump_file"; then
        log "ERROR: database dump is empty or compression failed"
        rm -rf "$dest"
        return 1
    fi
    if [ ! -s "$dest/db.sql.gz" ] || ! gzip -t "$dest/db.sql.gz" 2>/dev/null; then
        log "ERROR: db.sql.gz is empty or corrupt; discarding the archive"
        rm -rf "$dest"
        return 1
    fi

    log "  db.sql.gz: $(wc -c < "$dest/db.sql.gz" | tr -d ' ') bytes"

    # APP_KEY is indispensable when restoring encrypted settings.
    if [ ! -s "$BACKUP_SOURCE_DIR/.env" ] ||
       ! grep -Eq '^APP_KEY=.+$' "$BACKUP_SOURCE_DIR/.env"; then
        log "ERROR: missing .env or APP_KEY; refusing incomplete backup"
        return 1
    fi
    cp "$BACKUP_SOURCE_DIR/.env" "$dest/env"
    chmod 600 "$dest/env"
    log "  captured .env (contains APP_KEY)"

    if [ -d "$BACKUP_SOURCE_DIR/storage/app" ]; then
        if ! tar -czf "$dest/storage-app.tar.gz" -C "$BACKUP_SOURCE_DIR/storage/app" . 2>/dev/null ||
           ! gzip -t "$dest/storage-app.tar.gz"; then
            log "ERROR: storage/app archive failed; refusing incomplete backup"
            return 1
        fi
        log "  captured storage/app"
    else
        log "  no storage/app yet (no uploads to capture)"
    fi

    # User-installed theme and plugin source lives outside storage/app.
    for entry in "storage/theme:storage-theme.tar.gz" "plugins:plugins.tar.gz"; do
        source_dir=${entry%%:*}
        archive_name=${entry#*:}
        if [ -d "$BACKUP_SOURCE_DIR/$source_dir" ]; then
            if ! tar -czf "$dest/$archive_name" -C "$BACKUP_SOURCE_DIR/$source_dir" . 2>/dev/null ||
               ! gzip -t "$dest/$archive_name"; then
                log "ERROR: cannot preserve $source_dir; refusing incomplete backup"
                return 1
            fi
            log "  captured $source_dir"
        fi
    done

    contents="db.sql.gz env"
    for entry in storage-app.tar.gz storage-theme.tar.gz plugins.tar.gz; do
        [ ! -f "$dest/$entry" ] || contents="$contents $entry"
    done
    {
        echo "created_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "database=$DB_DATABASE"
        echo "db_host=$DB_HOST"
        echo "contents=$contents"
    } > "$dest/MANIFEST"

    (
        cd "$dest" || exit 1
        set -- db.sql.gz env
        for item in storage-app.tar.gz storage-theme.tar.gz plugins.tar.gz; do
            [ ! -f "$item" ] || set -- "$@" "$item"
        done
        sha256sum "$@" > CHECKSUMS.sha256
        sha256sum -c CHECKSUMS.sha256 >/dev/null
    ) || {
        log "ERROR: backup integrity checksum failed"
        return 1
    }
    log "wrote $dest"
    trap - EXIT HUP INT TERM
    prune
)

if [ "$BACKUP_INTERVAL" -gt 0 ] 2>/dev/null; then
    log "periodic mode: every ${BACKUP_INTERVAL}s, retention ${BACKUP_RETENTION}"
    while true; do
        run_backup || log "backup failed; will retry at the next interval"
        sleep "$BACKUP_INTERVAL"
    done
else
    run_backup
fi
