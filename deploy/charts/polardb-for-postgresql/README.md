# polardb-for-postgresql

This chart installs a single-node PolarDB for PostgreSQL backend. FerretDB is
disabled by default.

```bash
helm upgrade -i polardb-for-postgresql ./deploy/charts/polardb-for-postgresql \
  -n polardb --create-namespace
```

The chart generates a random PostgreSQL password by default and stores it in a
Secret. Set `auth.password` when a deterministic password is required.

The default PVC size is `3G`. PVCs created by the StatefulSet are deleted when
the release is deleted, and retained when the StatefulSet is scaled down. Set
`polardb.persistence.persistentVolumeClaimRetentionPolicy.enabled=false` to use
the cluster's default StatefulSet PVC retention behavior instead.

Enable FerretDB with:

```bash
helm upgrade -i polardb-for-postgresql ./deploy/charts/polardb-for-postgresql \
  -n polardb --create-namespace \
  --set ferretdb.enabled=true
```

When `ferretdb.enabled` is turned on for an existing PVC, the PolarDB entrypoint
reconciles the DocumentDB PostgreSQL configuration and runs
`CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;` on the next pod startup.

The default PolarDB image repository is:

```text
ghcr.io/labring-sigs/polardb-for-postgresql:latest
```

Docker image references are lower-case, while the source repository is
`labring-sigs/PolarDB-for-PostgreSQL`.
