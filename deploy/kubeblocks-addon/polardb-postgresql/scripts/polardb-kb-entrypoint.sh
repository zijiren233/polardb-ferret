#!/usr/bin/env bash
set -Eeuo pipefail

: "${CLUSTER_COMPONENT_NAME:?CLUSTER_COMPONENT_NAME is required}"
: "${POLARDB_POD_NAME_LIST:?POLARDB_POD_NAME_LIST is required}"
: "${POLARDB_POD_FQDN_LIST:?POLARDB_POD_FQDN_LIST is required}"

export POD_NAME="${POD_NAME:-${CURRENT_POD_NAME:-$(hostname)}}"
export POLARDB_USER="${POLARDB_USER:-postgres}"
export POLARDB_PORT="${POLARDB_PORT:-5432}"
export POLARDB_DATA_DIR="${POLARDB_DATA_DIR:-/var/polardb}"

IFS=',' read -r -a pod_names <<< "${POLARDB_POD_NAME_LIST}"
IFS=',' read -r -a pod_fqdns <<< "${POLARDB_POD_FQDN_LIST}"

initial_primary_name="${pod_names[0]}"
initial_primary_fqdn="${pod_fqdns[0]}"

if [ -z "${initial_primary_name}" ] || [ -z "${initial_primary_fqdn}" ]; then
  echo "empty KubeBlocks pod name/FQDN list" >&2
  exit 1
fi

export POLARDB_HA_PRIMARY_HOST="${CLUSTER_COMPONENT_NAME}-primary"
export POLARDB_HA_BOOTSTRAP_PRIMARY_HOST="${initial_primary_fqdn}"
export POLARDB_HA_REJOIN_PRIMARY_HOST="${CLUSTER_COMPONENT_NAME}-primary"

exec /home/postgres/docker-entrypoint.sh postgres
