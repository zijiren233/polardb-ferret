#!/usr/bin/env bash
set -Eeuo pipefail

BASE=/u01/polardb_pg
DATA_ROOT=${POLARDB_DATA_DIR:-/var/polardb}
PRIMARY=$DATA_ROOT/primary_datadir
SHARED=$DATA_ROOT/shared_datadir
PORT=${POLARDB_PORT:-5432}
INIT_MARKER="$PRIMARY/PG_VERSION"
HA_DEMOTED_MARKER="$DATA_ROOT/ha-demoted"

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

ha_enabled() {
    case "${POLARDB_HA_ENABLED:-0}" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

pod_ordinal() {
    local name
    name="${POD_NAME:-${HOSTNAME:-}}"
    printf '%s' "${name##*-}"
}

ha_primary_host() {
    printf '%s' "${POLARDB_HA_PRIMARY_HOST:-}"
}

ha_bootstrap_primary_host() {
    printf '%s' "${POLARDB_HA_BOOTSTRAP_PRIMARY_HOST:-${POLARDB_HA_PRIMARY_HOST:-}}"
}

ha_rejoin_primary_host() {
    printf '%s' "${POLARDB_HA_REJOIN_PRIMARY_HOST:-${POLARDB_HA_PRIMARY_HOST:-}}"
}

pgpass_escape() {
    local value
    value="$1"
    value="${value//\\/\\\\}"
    value="${value//:/\\:}"
    printf '%s' "$value"
}

write_pgpass() {
    {
        printf '%s:%s:*:%s:%s\n' \
            "*" \
            "$(pgpass_escape "$PORT")" \
            "$(pgpass_escape "${POLARDB_USER:-postgres}")" \
            "$(pgpass_escape "${POLARDB_PASSWORD:-}")"
    } > /home/postgres/.pgpass
    chmod 600 /home/postgres/.pgpass
    if [ "$(id -u)" = "0" ]; then
        chown postgres:postgres /home/postgres/.pgpass
    fi
}

wait_for_primary() {
    local host timeout started now
    host="$(ha_bootstrap_primary_host)"
    timeout="${POLARDB_HA_PRIMARY_WAIT_SECONDS:-600}"
    started="$(date +%s)"

    if [ -z "$host" ]; then
        echo "POLARDB_HA_PRIMARY_HOST is required for standby bootstrap" >&2
        exit 1
    fi

    echo "Waiting for primary at $host:$PORT"
    while true; do
        if PGPASSWORD="${POLARDB_PASSWORD:-}" "$BASE/bin/pg_isready" \
            -h "$host" \
            -p "$PORT" \
            -U "${POLARDB_USER:-postgres}" \
            -d postgres \
            -q; then
            return 0
        fi

        now="$(date +%s)"
        if [ $((now - started)) -ge "$timeout" ]; then
            echo "Timed out waiting for primary at $host:$PORT" >&2
            exit 1
        fi
        sleep 5
    done
}

primary_service_available_for_rejoin() {
    local host
    host="$(ha_rejoin_primary_host)"

    if [ -z "$host" ]; then
        return 1
    fi

    PGPASSWORD="${POLARDB_PASSWORD:-}" "$BASE/bin/pg_isready" \
        -h "$host" \
        -p "$PORT" \
        -U "${POLARDB_USER:-postgres}" \
        -d postgres \
        -q
}

append_ha_primary_config() {
    local conf
    conf="$PRIMARY/postgresql.conf"
    {
        echo "# BEGIN polardb-ha-primary"
        echo "wal_level = 'replica'"
        echo "max_wal_senders = ${POLARDB_HA_MAX_WAL_SENDERS:-10}"
        echo "max_replication_slots = ${POLARDB_HA_MAX_REPLICATION_SLOTS:-10}"
        echo "wal_keep_size = '${POLARDB_HA_WAL_KEEP_SIZE:-1024MB}'"
        echo "hot_standby = on"
        echo "# END polardb-ha-primary"
    } >> "$conf"

    {
        echo "host replication all 0.0.0.0/0 md5"
        echo "host replication all ::/0 md5"
    } >> "$PRIMARY/pg_hba.conf"
}

configure_standby_recovery() {
    local conf host app_name
    conf="$PRIMARY/postgresql.conf"
    host="$(ha_bootstrap_primary_host)"
    app_name="${POD_NAME:-${HOSTNAME:-standby}}"

    write_pgpass

    touch "$PRIMARY/standby.signal"
    {
        echo "# BEGIN polardb-ha-standby"
        printf "primary_conninfo = 'host=%s port=%s user=%s dbname=postgres application_name=%s'\n" \
            "$host" \
            "$PORT" \
            "${POLARDB_USER:-postgres}" \
            "$app_name"
        echo "recovery_target_timeline = 'latest'"
        echo "hot_standby = on"
        echo "# END polardb-ha-standby"
    } >> "$conf"
}

initialize_ha_standby() {
    local tmp_primary tmp_shared host
    host="$(ha_bootstrap_primary_host)"

    verify_minimum_env
    wait_for_primary

    echo "Bootstrapping PolarDB standby from $host:$PORT"
    rm -rf "$PRIMARY" "$SHARED"
    tmp_primary="${PRIMARY}.basebackup.$$"
    tmp_shared="${SHARED}.basebackup.$$"
    rm -rf "$tmp_primary" "$tmp_shared"
    mkdir -p "$tmp_primary" "$tmp_shared"
    if [ "$(id -u)" = "0" ]; then
        chown postgres:postgres "$tmp_primary" "$tmp_shared"
    fi
    write_pgpass

    PGPASSWORD="${POLARDB_PASSWORD:-}" run_as_postgres "$BASE/bin/polar_basebackup" \
        -D "$tmp_primary" \
        -h "$host" \
        -p "$PORT" \
        -U "${POLARDB_USER:-postgres}" \
        --polardata="$tmp_shared" \
        --no-sync \
        -v

    mv "$tmp_primary" "$PRIMARY"
    mv "$tmp_shared" "$SHARED"
    chmod 700 "$PRIMARY"
    chmod 700 "$SHARED" || :
    if [ "$(id -u)" = "0" ]; then
        chown -R postgres:postgres "$PRIMARY" "$SHARED"
    fi
    configure_standby_recovery
}

standby_data_directory() {
    [ -f "$PRIMARY/standby.signal" ] || [ -f "$PRIMARY/replica.signal" ]
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

    if ha_enabled; then
        append_ha_primary_config
    fi

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

        if ha_enabled && [ "${POLARDB_HA_REJOIN:-0}" = "1" ]; then
            echo "POLARDB_HA_REJOIN=1 set; rebuilding this pod as standby"
            rm -f "$HA_DEMOTED_MARKER"
            POLARDB_HA_BOOTSTRAP_PRIMARY_HOST="$(ha_rejoin_primary_host)" initialize_ha_standby
        fi

        if [ ! -s "$INIT_MARKER" ]; then
            if ha_enabled && primary_service_available_for_rejoin; then
                echo "Found an existing HA primary; bootstrapping this pod as standby"
                POLARDB_HA_BOOTSTRAP_PRIMARY_HOST="$(ha_rejoin_primary_host)" initialize_ha_standby
            elif ha_enabled && [ "$(pod_ordinal)" != "0" ]; then
                initialize_ha_standby
            else
                initialize_database
            fi
        else
            if ha_enabled && [ -f "$HA_DEMOTED_MARKER" ]; then
                if [ "${POLARDB_HA_REBUILD_DEMOTED:-0}" = "1" ] && primary_service_available_for_rejoin; then
                    echo "This pod was demoted; rebuilding it as standby from the current primary"
                    rm -f "$HA_DEMOTED_MARKER"
                    POLARDB_HA_BOOTSTRAP_PRIMARY_HOST="$(ha_rejoin_primary_host)" initialize_ha_standby
                else
                    echo "This pod was demoted and requires manual rejoin or rebuild" >&2
                    echo "Data is preserved at $DATA_ROOT. Set POLARDB_HA_REBUILD_DEMOTED=1 only after accepting possible data loss." >&2
                    exit 1
                fi
            fi
            echo "PolarDB data directory already initialized, skipping init"
            if documentdb_enabled && ! standby_data_directory; then
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
