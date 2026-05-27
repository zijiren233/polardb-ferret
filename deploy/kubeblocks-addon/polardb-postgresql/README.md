# PolarDB PostgreSQL KubeBlocks Addon

This addon registers a KubeBlocks `ComponentDefinition` and `ComponentVersion`
for the PolarDB PostgreSQL 17 image built by this repository.

It intentionally does not reuse the upstream KubeBlocks PostgreSQL addon runtime:
that addon is based on Spilo and Patroni, while this image uses the PolarDB local
instance layout and `polar_basebackup --polardata`.

## Install

```bash
helm upgrade -i polardb-postgresql-addon ./deploy/kubeblocks-addon/polardb-postgresql -n kb-system
```

## Create a Cluster

```bash
kubectl create namespace demo
kubectl apply -f deploy/kubeblocks-addon/polardb-postgresql/examples/cluster.yaml
```

The component exposes two role-aware services through KubeBlocks:

- `primary`: selects the Pod whose KubeBlocks role is `primary`
- `replicas`: selects Pods whose KubeBlocks role is `standby`

## Current HA Model

The first version keeps the existing script-based HA manager:

- Kubernetes `Lease` elects the writable primary.
- The primary records WAL LSN and timeline in Lease annotations.
- Failover candidates check replay lag and timeline before promotion.
- PostgreSQL synchronous replication is enabled by default with
  `synchronous_commit=on` and `synchronous_standby_names='FIRST 1 (*)'`.
- Failover candidates must replay to the last WAL LSN recorded in the Lease by
  default (`ha.maximumLagOnFailoverBytes=0`).
- A demoted old primary preserves its PVC and stops by default. Full basebackup
  rebuild is opt-in with `ha.rejoin.rebuildDemoted=true`.
- `polardb-ha-manager.py` exposes `/v1.0/getrole` on port `5001`.
- KubeBlocks `roleProbe` consumes that endpoint and owns role labels.
- The primary Service uses `roleSelector: primary`.

Manual KubeBlocks `switchover` is deliberately stubbed out for now. It needs
old-primary fencing and rejoin handling before it should be enabled as a normal
OpsRequest path.
