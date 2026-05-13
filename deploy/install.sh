#!/bin/bash
set -euo pipefail

HELM_OPTS=${HELM_OPTS:-""}
RELEASE_NAME=${RELEASE_NAME:-polardb-for-postgresql}
NAMESPACE=${NAMESPACE:-polardb}

helm upgrade -i "${RELEASE_NAME}" \
    -n "${NAMESPACE}" --create-namespace \
    ./charts/polardb-for-postgresql \
    ${HELM_OPTS}
