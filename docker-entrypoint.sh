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

documentdb_enabled() {
    case "${POLARDB_ENABLE_DOCUMENTDB:-1}" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

trim() {
    local value
    value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

remove_postgresql_conf_block() {
    local conf end start tmp
    conf="$1"
    start="$2"
    end="$3"
    tmp="$(mktemp)"

    awk -v start="$start" -v end="$end" '
        $0 == start { skip = 1; next }
        $0 == end { skip = 0; next }
        skip { next }
        { print }
    ' "$conf" > "$tmp"

    cat "$tmp" > "$conf"
    rm -f "$tmp"
}

remove_postgresql_conf_key() {
    local conf key tmp
    conf="$1"
    key="$2"
    tmp="$(mktemp)"

    awk -v key="$key" '
        function active_key(line) {
            sub(/^[[:space:]]+/, "", line)
            if (line ~ /^#/) {
                return ""
            }
            sub(/[[:space:]=].*$/, "", line)
            return line
        }

        active_key($0) == key { next }
        { print }
    ' "$conf" > "$tmp"

    cat "$tmp" > "$conf"
    rm -f "$tmp"
}

read_postgresql_conf_value() {
    local conf key
    conf="$1"
    key="$2"

    awk -v key="$key" '
        function active_key(line) {
            sub(/^[[:space:]]+/, "", line)
            if (line ~ /^#/) {
                return ""
            }
            sub(/[[:space:]=].*$/, "", line)
            return line
        }

        function active_value(line) {
            sub(/^[[:space:]]+/, "", line)
            sub(/^[^[:space:]=]+[[:space:]]*/, "", line)
            sub(/^=[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*$/, "", line)
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            return line
        }

        active_key($0) == key { value = active_value($0) }
        END { print value }
    ' "$conf"
}

library_list_contains() {
    local current item library
    current="$1"
    library="$2"

    IFS=',' read -ra items <<< "$current"
    for item in "${items[@]}"; do
        item="$(trim "$item")"
        if [ "$item" = "$library" ]; then
            return 0
        fi
    done

    return 1
}

merge_shared_preload_libraries() {
    local current library
    current="$1"
    current="${current%;}"
    current="${current//\"/}"
    current="${current//\'/}"
    current="$(trim "$current")"

    if [ -z "$current" ]; then
        current="$(read_postgresql_conf_value "$BASE/share/postgresql/polardb.conf.sample" "shared_preload_libraries")"
        current="${current%;}"
        current="${current//\"/}"
        current="${current//\'/}"
        current="$(trim "$current")"
    fi

    if [ -z "$current" ]; then
        current='pg_cron,pg_documentdb_core,pg_documentdb'
    fi

    for library in pg_cron pg_documentdb_core pg_documentdb; do
        if ! library_list_contains "$current" "$library"; then
            current="${current},${library}"
        fi
    done

    printf '%s' "$current"
}

configure_documentdb() {
    local conf shared_preload_libraries
    conf="$PRIMARY/postgresql.conf"

    shared_preload_libraries="$(read_postgresql_conf_value "$conf" "shared_preload_libraries")"
    shared_preload_libraries="$(merge_shared_preload_libraries "$shared_preload_libraries")"

    remove_postgresql_conf_block "$conf" "# BEGIN polardb-documentdb" "# END polardb-documentdb"
    remove_postgresql_conf_key "$conf" "shared_preload_libraries"
    remove_postgresql_conf_key "$conf" "cron.database_name"
    remove_postgresql_conf_key "$conf" "documentdb.enableCompact"
    remove_postgresql_conf_key "$conf" "documentdb.enableIndexOrderbyPushdown"
    remove_postgresql_conf_key "$conf" "documentdb.enableLetAndCollationForQueryMatch"
    remove_postgresql_conf_key "$conf" "documentdb.enableNowSystemVariable"
    remove_postgresql_conf_key "$conf" "documentdb.enableSchemaValidation"
    remove_postgresql_conf_key "$conf" "documentdb.enableBypassDocumentValidation"
    remove_postgresql_conf_key "$conf" "documentdb.enableUserCrud"
    remove_postgresql_conf_key "$conf" "documentdb.maxUserLimit"

    {
        echo "# BEGIN polardb-documentdb"
        printf "shared_preload_libraries = '%s'\n" "$shared_preload_libraries"
        cat <<'EOF'
cron.database_name = 'postgres'
documentdb.enableCompact = true
documentdb.enableIndexOrderbyPushdown = true
documentdb.enableLetAndCollationForQueryMatch = true
documentdb.enableNowSystemVariable = true
documentdb.enableSchemaValidation = true
documentdb.enableBypassDocumentValidation = true
documentdb.enableUserCrud = true
documentdb.maxUserLimit = 100
# END polardb-documentdb
EOF
    } >> "$conf"

    if [ "$(id -u)" = "0" ]; then
        chown postgres:postgres "$conf"
    fi
}

create_documentdb_extension() {
    echo "Creating DocumentDB extension if needed"
    process_sql -c "CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;"
}

reconcile_documentdb() {
    local status

    echo "Reconciling DocumentDB configuration"
    configure_documentdb

    temp_server_start

    status=0
    create_documentdb_extension || status=$?
    temp_server_stop || status=$?

    return "$status"
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

    if documentdb_enabled; then
        configure_documentdb
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
    if documentdb_enabled; then
        create_documentdb_extension
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
            if documentdb_enabled; then
                reconcile_documentdb
            fi
        fi

        set -- "$BASE/bin/postgres" -D "$PRIMARY" --cluster-name=primary
    fi

    if [ "$(id -u)" = "0" ] && [ "${1:-}" = "$BASE/bin/postgres" ]; then
        exec runuser -u postgres -- "$@"
    fi

    exec "$@"
}

main "$@"
