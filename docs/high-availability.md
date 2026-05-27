# PolarDB PostgreSQL 高可用与运维文档

本文说明当前镜像和 Helm chart 内置的脚本版高可用能力。它同时适用于直接
Helm/StatefulSet 部署模式的日常操作、故障处理和维护判断。

## 适用范围

当前 HA 实现是一个轻量脚本方案：

- 每个 PolarDB Pod 使用独立 RWO PVC。
- `pod-0` 首次初始化为 primary。
- 其它 Pod 通过 `polar_basebackup --polardata` 从 primary 克隆为 standby。
- 每个 Pod 内运行 `ha-manager` sidecar。
- `ha-manager` 使用 Kubernetes `Lease` 记录当前 primary。
- 主库 Service 通过 `polardb-role=primary` 选择当前 primary。
- 只读 Service 通过 `polardb-role=standby` 选择 standby。

这不是完整 operator，也不是 Patroni 级别的生产 HA。它的目标是先提供一个可部署、
可故障切换、可人工恢复的主从高可用闭环。

## 当前实现状态

已实现：

- Kubernetes `Lease` 选主和续约。
- primary 续约时在 Lease annotation 中记录 WAL LSN、timeline 和观察时间。
- primary Service 自动指向 `polardb-role=primary` Pod。
- replica Service 自动指向 `polardb-role=standby` Pod。
- standby 通过 `polar_basebackup --polardata` 初始化。
- 默认开启 PostgreSQL 同步复制：`synchronous_commit=on`，
  `synchronous_standby_names='FIRST 1 (*)'`。
- Lease 过期后，健康 standby 只有在 timeline 检查通过且 replay lag 不超过阈值时，
  才能抢占 Lease 并执行 `pg_ctl promote`。
- 本地 PostgreSQL 是 primary 但 Pod 不持有 Lease 时，sidecar 会停止本地数据库。
- 被 fencing 的旧 primary 会写入 `/var/polardb/ha-demoted`，避免重启后直接双主。
- 新 primary 设置角色前会清理其它 Pod 残留的 `polardb-role=primary` label。
- `ha-manager` 暴露 HTTP 接口：
  - `GET /healthz`
  - `GET /v1.0/getrole`

未实现或仍需增强：

- 多 standby 之间按 LSN 选择最优候选。
- 复制槽自动创建、迁移和重建。
- 安全的计划内 switchover。
- 旧 primary 自动安全 rejoin 或 `pg_rewind`。
- Kubernetes API 分区场景下的强 fencing。
- 完整 e2e 故障演练测试矩阵。

因此，生产环境使用前必须结合业务 RPO/RTO、存储、网络和运维流程做压测和故障演练。

## 启用 HA

```bash
helm upgrade -i polardb-for-postgresql ./deploy/charts/polardb-for-postgresql \
  -n polardb --create-namespace \
  --set auth.password=change-me \
  --set ha.enabled=true \
  --set ha.replicaCount=3
```

主库入口：

```text
polardb-for-postgresql-polardb:5432
```

只读入口：

```text
polardb-for-postgresql-polardb-replica:5432
```

## 关键参数

```yaml
ha:
  enabled: true
  replicaCount: 3
  podManagementPolicy: Parallel
  leaseDurationSeconds: 30
  retryPeriodSeconds: 5
  primaryWaitSeconds: 600
  failover:
    enabled: true
    promoteTimeoutSeconds: 60
    maximumLagOnFailoverBytes: 1048576
    checkTimeline: true
  replication:
    walKeepSize: 1024MB
    maxWalSenders: 10
    maxReplicationSlots: 10
    synchronous:
      enabled: true
      commit: "on"
      standbyNames: "FIRST 1 (*)"
```

参数含义：

- `ha.replicaCount`: HA 模式下 StatefulSet 副本数。
- `ha.podManagementPolicy`: HA 模式下 StatefulSet 的 Pod 管理策略，默认 `Parallel`。
  这样多个 standby 可以同时进入等待 primary、basebackup 和 recovery 流程。非 HA 模式默认
  使用 `polardb.podManagementPolicy=OrderedReady`。
- `ha.leaseDurationSeconds`: Lease 超过该时间未续约后，standby 才能尝试接管。
- `ha.retryPeriodSeconds`: HA sidecar 主循环周期。
- `ha.primaryWaitSeconds`: standby 首次 clone 时等待初始 primary 的最长时间。
- `ha.failover.enabled`: 是否允许自动故障切换。
- `ha.failover.promoteTimeoutSeconds`: `pg_ctl promote` 等待超时时间。
- `ha.failover.maximumLagOnFailoverBytes`: standby replay LSN 落后 Lease 中最后 primary LSN 的最大允许字节数。
  默认 `1048576`，参考 Patroni 常用的 `maximum_lag_on_failover` 默认量级。
- `ha.failover.checkTimeline`: promote 前检查本地 timeline 不落后于 Lease 中记录的 primary timeline。
- `ha.replication.walKeepSize`: primary 保留 WAL 的大小。当前没有复制槽自动管理，生产环境需要谨慎设置。
- `ha.replication.synchronous.enabled`: 是否写入同步复制参数。默认开启。
- `ha.replication.synchronous.commit`: 写入 `synchronous_commit`，默认 `on`。
- `ha.replication.synchronous.standbyNames`: 写入 `synchronous_standby_names`，默认 `FIRST 1 (*)`。

默认同步复制是偏数据安全的取舍：有健康 standby 时，primary 的提交需要等待至少一个同步
standby 确认 WAL；如果所有 standby 不可用，写入可能等待或超时，直到 standby 恢复或运维临时关闭同步复制。

如果业务优先可用性、能接受异步复制下的 RPO 风险，可以显式关闭：

```bash
helm upgrade -i polardb-for-postgresql ./deploy/charts/polardb-for-postgresql \
  -n polardb \
  --set ha.enabled=true \
  --set ha.replication.synchronous.enabled=false
```

## 启动流程

1. StatefulSet 创建多个 Pod。直接 Helm HA 部署默认使用 `Parallel`，避免 standby 初始化被
   严格串行化。
2. `pod-0` 首次启动时执行 `initdb`、`polar-initdb.sh`，初始化为 primary。
3. 其它 Pod 等待 `pod-0` 可连接。
4. standby 执行：

```bash
polar_basebackup \
  -D /var/polardb/primary_datadir \
  --polardata=/var/polardb/shared_datadir
```

5. standby 写入 `standby.signal` 和 `primary_conninfo`。
6. HA 节点写入复制参数。默认包含 `synchronous_commit=on` 和
   `synchronous_standby_names='FIRST 1 (*)'`。
7. 每个 Pod 的 `ha-manager` 开始运行。
8. primary 创建或续约 Lease，并把当前 WAL LSN、timeline 写入 Lease annotation。
9. `ha-manager` 根据本地数据库状态和 Lease 状态更新 Pod role label。
10. primary Service 指向当前 `polardb-role=primary` Pod。

## 日常检查

查看 Pod 角色：

```bash
kubectl get pod -n polardb \
  -l app.kubernetes.io/component=polardb \
  --show-labels
```

查看 Lease：

```bash
kubectl get lease -n polardb
kubectl describe lease -n polardb polardb-for-postgresql-polardb-primary
```

Lease 中会包含类似下面的 annotation：

```text
polardb-pg.labring-sigs.io/last-wal-lsn
polardb-pg.labring-sigs.io/timeline-id
polardb-pg.labring-sigs.io/observed-at
```

查看 HA manager 日志：

```bash
kubectl logs -n polardb statefulset/polardb-for-postgresql-polardb -c ha-manager
```

查看某个 Pod 的真实数据库角色：

```bash
kubectl exec -n polardb polardb-for-postgresql-polardb-0 -c polardb -- \
  psql -U postgres -d postgres -At -c "select pg_is_in_recovery();"
```

返回 `f` 表示 primary，返回 `t` 表示 standby。

查看 HA role probe：

```bash
kubectl exec -n polardb polardb-for-postgresql-polardb-0 -c ha-manager -- \
  curl -s http://127.0.0.1:5001/v1.0/getrole
```

查看同步复制状态：

```bash
kubectl exec -n polardb <primary-pod> -c polardb -- \
  psql -U postgres -d postgres -x -c \
  "show synchronous_commit; show synchronous_standby_names; select application_name,sync_state,state,replay_lsn from pg_stat_replication;"
```

## 故障切换流程

当当前 primary Pod 宕机、PostgreSQL 不可用，或者 `ha-manager` 无法续约 Lease：

1. Lease 超过 `ha.leaseDurationSeconds` 后被视为过期。
2. 某个健康 standby 观察到 Lease 过期。
3. standby 重新读取 Lease，确认仍然过期。
4. standby 读取 Lease 中最后一次 primary WAL LSN 和 timeline。
5. standby 比较本地 replay LSN。如果落后超过 `maximumLagOnFailoverBytes`，拒绝接管。
6. 如果开启 `checkTimeline`，standby 的 timeline 不能落后于 Lease 中记录的 timeline。
7. 检查通过后，standby 更新 Lease，将 `holderIdentity` 改为自己。
8. standby 执行 `pg_ctl promote`。如果 promote 失败，会释放刚抢到的 Lease。
9. promote 成功后，该 Pod 标记为 `polardb-role=primary`。
10. 新 primary 会清理其它 Pod 上残留的 `polardb-role=primary` label。
11. primary Service 自动切到新 primary。
12. 其它 standby 会改写 `primary_conninfo`，开始跟随新的 Lease holder。

## 旧 primary fencing

如果某个 Pod 本地 PostgreSQL 是 primary，但它不是 Lease holder，`ha-manager` 会：

1. 将自己的 role 标为 `unknown`。
2. 写入 `/var/polardb/ha-demoted`。
3. 执行：

```bash
pg_ctl -D /var/polardb/primary_datadir -m fast -w stop
```

之后该 Pod 重启时会因为存在 `ha-demoted` 标记而退出，不会自动以旧数据重新加入。
这是为了避免旧 primary 回来后形成双主。

## 旧 primary 重新加入

当前默认不自动 rejoin。建议按下面流程人工处理：

1. 确认集群已有健康 primary：

```bash
kubectl get pod -n polardb \
  -l app.kubernetes.io/component=polardb,polardb-role=primary
```

2. 确认 primary 可写：

```bash
kubectl exec -n polardb <primary-pod> -c polardb -- \
  psql -U postgres -d postgres -c "create table if not exists ha_rejoin_check(id int);"
```

3. 找到需要重建的旧 primary Pod 和 PVC。

4. 临时给该 Pod 注入 `POLARDB_HA_REJOIN=1` 不是当前 chart 的一键操作。推荐的安全做法是：

- 删除该旧 Pod 对应的数据 PVC。
- 让 StatefulSet 重新创建 Pod。
- 新 Pod 会按 standby 初始化流程从当前 primary 重新 clone。

如果必须保留 PVC 对象并在容器内重建，需要先确认没有任何进程使用旧数据目录，再由运维脚本设置
`POLARDB_HA_REJOIN=1` 或 `POLARDB_HA_REBUILD_DEMOTED=1` 并重启该 Pod。
这会清理旧 primary 的本地数据并从当前 primary 重新 clone。如果同步复制曾被关闭，或者旧 primary
上存在没有同步到新 primary 的已提交事务，这些事务会丢失，因此不要在无法确认新 primary 健康和可接受
RPO 时执行该操作。

## 暂停自动故障切换

维护期间可以关闭自动 failover：

```bash
helm upgrade -i polardb-for-postgresql ./deploy/charts/polardb-for-postgresql \
  -n polardb \
  --set ha.enabled=true \
  --set ha.failover.enabled=false
```

关闭后：

- 当前 primary 仍会续约 Lease。
- standby 不会在 Lease 过期后自动 promote。
- 如果 primary 故障，业务可能不可写，需要人工恢复。

维护完成后重新开启：

```bash
helm upgrade -i polardb-for-postgresql ./deploy/charts/polardb-for-postgresql \
  -n polardb \
  --set ha.enabled=true \
  --set ha.failover.enabled=true
```

## 不建议的操作

不要在未确认新 primary 健康时删除旧 primary PVC。

不要手工给多个 Pod 打 `polardb-role=primary` label。

不要绕过 Lease 直接在 standby 上执行 `pg_ctl promote`，除非你已经停止所有可能的旧 primary，
并准备手工修正 Lease 和 Pod label。

不要把同一组 PVC 同时交给直接 Helm HA 和 KubeBlocks 管理。

## 当前风险

当前脚本版 HA 仍有这些风险：

- Lease 只代表 Kubernetes API 视角，不等同于强一致仲裁系统。
- 网络分区时，如果旧 primary 仍能服务业务但不能访问 Kubernetes API，需要依赖本地
  `ha-manager` fencing；如果 sidecar 自身卡死，则仍有风险。
- 当前只检查抢占者自己的 replay lag；还没有全局比较所有 standby 后选择最新节点。
- 没有复制槽管理，standby 长时间落后后可能无法继续追 WAL。
- 没有安全 switchover，滚动维护时仍需要谨慎。
- 默认同步复制降低数据丢失风险，但不能替代强 fencing；它也会在 standby 不可用时牺牲写入可用性。

## 后续优化清单

优先级从高到低：

1. standby 周期性上报 replay LSN，由最新 standby 才能接管。
2. 实现安全 switchover 命令。
3. 增加 replication slot 管理。
4. 增加 `pg_rewind`/自动 rejoin，但默认关闭。
5. 增加 kind/minikube e2e 故障演练脚本。
