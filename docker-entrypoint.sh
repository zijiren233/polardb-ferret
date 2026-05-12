#!/usr/bin/env bash
set -Eeuo pipefail

BASE=/u01/polardb_pg
DATA_ROOT=${POLARDB_DATA_DIR:-/var/polardb}
PRIMARY=$DATA_ROOT/primary_datadir
SHARED=$DATA_ROOT/shared_datadir
PORT=${POLARDB_PORT:-5432}
INIT_MARKER="$PRIMARY/PG_VERSION"

run_as_postgres() {
    if [ "$(id -u)" = "0" ]; then
        runuser -u postgres -- "$@"
    else
        "$@"
    fi
}

create_directories() {
    mkdir -p "$PRIMARY" "$SHARED" /docker-entrypoint-initdb.d
    chmod 700 "$PRIMARY" || :

    if [ "$(id -u)" = "0" ]; then
        find "$DATA_ROOT" \! -user postgres -exec chown postgres:postgres '{}' +
    fi
}

verify_minimum_env() {
    if [ -z "${POLARDB_PASSWORD:-}" ]; then
        cat >&2 <<-'EOF'
			Error: database is uninitialized and superuser password is not specified.
			       Set POLARDB_PASSWORD to a non-empty value.
		EOF
        exit 1
    fi
}

process_sql() {
    PGHOST= PGHOSTADDR= run_as_postgres "$BASE/bin/psql" \
        -p "$PORT" \
        -d postgres \
        -v ON_ERROR_STOP=1 \
        "$@"
}

process_init_files() {
    local file

    for file; do
        [ -e "$file" ] || continue

        case "$file" in
            *.sh)
                if [ -x "$file" ]; then
                    printf '%s: running %s\n' "$0" "$file"
                    "$file"
                else
                    printf '%s: sourcing %s\n' "$0" "$file"
                    . "$file"
                fi
                ;;
            *.sql)
                printf '%s: running %s\n' "$0" "$file"
                process_sql -f "$file"
                ;;
            *.sql.gz)
                printf '%s: running %s\n' "$0" "$file"
                gunzip -c "$file" | process_sql
                ;;
            *.sql.xz)
                printf '%s: running %s\n' "$0" "$file"
                xzcat "$file" | process_sql
                ;;
            *.sql.zst)
                printf '%s: running %s\n' "$0" "$file"
                zstd -dc "$file" | process_sql
                ;;
            *)
                printf '%s: ignoring %s\n' "$0" "$file"
                ;;
        esac
    done
}

temp_server_start() {
    local options
    printf -v options '%q ' \
        --cluster-name=primary \
        -c listen_addresses= \
        -p "$PORT"

    run_as_postgres "$BASE/bin/pg_ctl" \
        -D "$PRIMARY" \
        -o "$options" \
        -w start
}

temp_server_stop() {
    run_as_postgres "$BASE/bin/pg_ctl" \
        -D "$PRIMARY" \
        -m fast \
        -w stop
}

postgres_wants_help() {
    local arg
    for arg; do
        case "$arg" in
            -'?'|--help|--describe-config|-V|--version)
                return 0
                ;;
        esac
    done
    return 1
}

initialize_database() {
    echo "Initializing PolarDB data directories under $DATA_ROOT"

    verify_minimum_env

    run_as_postgres "$BASE/bin/initdb" \
        -D "$PRIMARY" \
        -k \
        -A trust \
        --wal-segsize=16

    cat "$BASE/share/postgresql/polardb.conf.sample" >> "$PRIMARY/postgresql.conf"

    {
        echo "port = $PORT"
        echo "listen_addresses = '*'"
        echo "polar_datadir = 'file-dio://$SHARED'"
        echo "huge_pages = off"
        echo "full_page_writes = on"
        echo "password_encryption = 'scram-sha-256'"
    } >> "$PRIMARY/postgresql.conf"

    if [ "${POLARDB_ENABLE_DOCUMENTDB:-1}" = "1" ]; then
        {
            echo "shared_preload_libraries = '\$libdir/polar_vfs,\$libdir/polar_io_stat,\$libdir/polar_monitor_preload,\$libdir/polar_worker,pg_cron,pg_documentdb_core,pg_documentdb'"
            echo "cron.database_name = 'postgres'"
            echo "documentdb.enableCompact = true"
            echo "documentdb.enableIndexOrderbyPushdown = true"
            echo "documentdb.enableLetAndCollationForQueryMatch = true"
            echo "documentdb.enableNowSystemVariable = true"
            echo "documentdb.enableSchemaValidation = true"
            echo "documentdb.enableBypassDocumentValidation = true"
            echo "documentdb.enableUserCrud = true"
            echo "documentdb.maxUserLimit = 100"
        } >> "$PRIMARY/postgresql.conf"
    fi

    {
        echo "host all all 0.0.0.0/0 md5"
        echo "host all all ::/0 md5"
    } >> "$PRIMARY/pg_hba.conf"

    run_as_postgres "$BASE/bin/polar-initdb.sh" "$PRIMARY/" "$SHARED/" primary localfs

    temp_server_start

    if [ -n "${POLARDB_PASSWORD:-}" ]; then
        if [ "${POLARDB_USER:-postgres}" = "postgres" ]; then
            echo "Setting postgres role password"
            process_sql \
                -v password="$POLARDB_PASSWORD" <<'SQL'
ALTER ROLE postgres WITH PASSWORD :'password';
SQL
        elif [ -n "${POLARDB_USER:-}" ]; then
            echo "Creating ${POLARDB_USER} role"
            process_sql \
                -v user="$POLARDB_USER" \
                -v password="$POLARDB_PASSWORD" <<'SQL'
CREATE ROLE :"user" WITH PASSWORD :'password' SUPERUSER LOGIN;
SQL
        fi
    fi
    if [ "${POLARDB_ENABLE_DOCUMENTDB:-1}" = "1" ]; then
        echo "Creating DocumentDB extension"
        process_sql -c "CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;"
    fi

    process_init_files /docker-entrypoint-initdb.d/*
    temp_server_stop

    echo "PolarDB initialization completed"
}

main() {
    if [ "$#" -eq 0 ]; then
        set -- postgres
    fi

    if [ "${1:0:1}" = "-" ]; then
        set -- postgres "$@"
    fi

    if [ "$1" = "postgres" ]; then
        if postgres_wants_help "$@"; then
            shift
            exec "$BASE/bin/postgres" "$@"
        fi

        : "${POLARDB_USER:=postgres}"
        export POLARDB_USER

        create_directories

        if [ ! -s "$INIT_MARKER" ]; then
            initialize_database
        else
            echo "PolarDB data directory already initialized, skipping init"
        fi

        set -- "$BASE/bin/postgres" -D "$PRIMARY" --cluster-name=primary
    fi

    if [ "$(id -u)" = "0" ] && [ "${1:-}" = "$BASE/bin/postgres" ]; then
        exec runuser -u postgres -- "$@"
    fi

    exec "$@"
}

main "$@"
