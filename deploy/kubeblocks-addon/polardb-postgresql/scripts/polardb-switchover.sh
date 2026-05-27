#!/usr/bin/env bash
set -Eeuo pipefail

cat >&2 <<'EOF'
KubeBlocks switchover is not implemented for the script-based PolarDB HA addon yet.

The current addon supports KubeBlocks-managed role probing and roleSelector
services, while actual failover is still handled by polardb-ha-manager.py with a
Kubernetes Lease. A safe switchover needs candidate lag checks, old-primary
fencing and rejoin handling before it should be exposed as an OpsRequest action.
EOF

exit 1
