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
可人工恢复的主从高可用闭环。默认不开启自动故障切换；需要业务明确接受自动 promote 的
RPO/RTO 取舍后再打开。

## 当前实现状态

已实现：

- Kubernetes `Lease` 选主和续约。
- primary 续约时在 Lease annotation 中记录 WAL LSN、timeline 和观察时间。
- primary Service 自动指向 `polardb-role=primary` Pod。
- replica Service 自动指向 `polardb-role=standby` Pod。
- standby 通过 `polar_basebackup --polardata` 初始化。
- 默认开启 PostgreSQL 同步复制：`synchronous_commit=on`，
  `synchronous_standby_names='FIRST 1 (*)'`。
- 默认不自动故障切换。Lease 过期后 standby 继续保持 standby，不会自动执行
  `pg_ctl promote`。
- 显式开启自动 failover 后，健康 standby 只有在 timeline 检查通过且 replay lag 不超过阈值时，
  才能抢占 Lease 并执行 `pg_ctl promote`。
- 自动 failover 开启后，默认仍要求 standby 已 replay 到 Lease 记录的最后 primary WAL LSN，
  才允许接管。
- 本地 PostgreSQL 是 primary 但 Pod 不持有 Lease 时，sidecar 会停止本地数据库。
- 被 fencing 的旧 primary 会写入 `/var/polardb/ha-demoted`，避免重启后直接双主。
- demoted 旧 primary 默认保留 PVC 并停住，等待人工 rejoin 或显式重建。
- 新 primary 设置角色前会清理其它 Pod 残留的 `polardb-role=primary` label。
- `ha-manager` 暴露 HTTP 接口：
  - `GET /healthz`
  - `GET /v1.0/getrole`

未实现或仍需增强：

- 多 standby 之间按 LSN 选择最优候选。
- 复制槽自动创建、迁移和重建。
- 安全的计划内 switchover。
- 故障 failover 后旧 primary 的自动安全 rejoin。
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
  updateStrategy:
    type: OnDelete
  leaseDurationSeconds: 30
  retryPeriodSeconds: 5
  primaryWaitSeconds: 600
  failover:
    enabled: false
    promoteTimeoutSeconds: 60
    maximumLagOnFailoverBytes: 0
    checkTimeline: true
  replication:
    walKeepSize: 1024MB
    maxWalSenders: 10
    maxReplicationSlots: 10
    synchronous:
      enabled: true
      commit: "on"
      standbyNames: "FIRST 1 (*)"
  rejoin:
    rebuildDemoted: false
```

参数含义：

- `ha.replicaCount`: HA 模式下 StatefulSet 副本数。
- `ha.podManagementPolicy`: HA 模式下 StatefulSet 的 Pod 管理策略，默认 `Parallel`。
  这样多个 standby 可以同时进入等待 primary、basebackup 和 recovery 流程。非 HA 模式默认
  使用 `polardb.podManagementPolicy=OrderedReady`。
- `ha.updateStrategy`: HA 模式下 StatefulSet 更新策略，默认 `OnDelete`。这样 Helm 升级不会自动
  滚动重启当前 primary；需要运维按 standby、primary 的顺序手动删除 Pod 推进升级。
- `ha.leaseDurationSeconds`: Lease 超过该时间未续约后，standby 才能尝试接管。
- `ha.retryPeriodSeconds`: HA sidecar 主循环周期。
- `ha.primaryWaitSeconds`: standby 首次 clone 时等待初始 primary 的最长时间。
- `ha.failover.enabled`: 是否允许自动故障切换。默认 `false`，也就是只维护复制、Lease、Service
  role 和旧主 fencing，不在 primary 故障时自动 promote standby。
- `ha.failover.promoteTimeoutSeconds`: `pg_ctl promote` 等待超时时间。
- `ha.failover.maximumLagOnFailoverBytes`: standby replay LSN 落后 Lease 中最后 primary LSN 的最大允许字节数。
  默认 `0`，表示 standby 必须 replay 到 Lease 最后一次记录的 primary WAL LSN 才允许自动接管。
  这是偏数据安全的默认值；如果业务接受 RPO，可以显式放宽。
- `ha.failover.checkTimeline`: promote 前检查本地 timeline 不落后于 Lease 中记录的 primary timeline。
- `ha.replication.walKeepSize`: primary 保留 WAL 的大小。当前没有复制槽自动管理，生产环境需要谨慎设置。
- `ha.replication.synchronous.enabled`: 是否写入同步复制参数。默认开启。
- `ha.replication.synchronous.commit`: 写入 `synchronous_commit`，默认 `on`。
- `ha.replication.synchronous.standbyNames`: 写入 `synchronous_standby_names`，默认 `FIRST 1 (*)`。
- `ha.rejoin.rebuildDemoted`: 是否允许清理 demoted 旧 primary 的本地数据并重新做
  `polar_basebackup`。默认关闭，避免 Pod 抖动导致反复全量重建。

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

## 自动故障切换流程

默认 `ha.failover.enabled=false`，因此当前 primary Pod 宕机、PostgreSQL 不可用，或者
`ha-manager` 无法续约 Lease 时，standby 不会自动 promote，业务写入会不可用，需要人工处理。

只有显式设置 `ha.failover.enabled=true` 后，下面的自动故障切换流程才会发生：

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

开启自动故障切换：

```bash
helm upgrade -i polardb-for-postgresql ./deploy/charts/polardb-for-postgresql \
  -n polardb \
  --set ha.enabled=true \
  --set ha.failover.enabled=true
```

KubeBlocks addon 也提供同名开关，默认关闭：

```yaml
ha:
  failover:
    enabled: false
```

开启自动切换前至少确认：

1. 业务能接受自动 promote 带来的旧主隔离和人工 rejoin 流程。
2. 默认同步复制满足业务写入可用性要求。
3. `ha.failover.maximumLagOnFailoverBytes=0` 没有被放宽，除非业务明确接受 RPO。
4. 已演练旧 primary 被 demote 后的保留、排查和全量重建流程。

## 旧 primary fencing

如果某个 Pod 本地 PostgreSQL 是 primary，但它不是 Lease holder，`ha-manager` 会：

1. 将自己的 role 标为 `unknown`。
2. 写入 `/var/polardb/ha-demoted`。
3. 执行：

```bash
pg_ctl -D /var/polardb/primary_datadir -m fast -w stop
```

之后该 Pod 重启时会先看到 `ha-demoted` 标记。默认行为不是清数据重建，而是保留
`/var/polardb` 并退出，等待人工确认后处理。这样 Pod 抖动不会导致旧主反复清数据、反复全量
basebackup。

## 旧 primary 重新加入

旧 primary 不能在故障 failover 后只改 `primary_conninfo` 直接当 standby。原因是故障窗口内旧
primary 可能写过新 primary 没有的 WAL，已经形成 timeline 分叉；直接跟随新主可能导致数据目录
不一致。PostgreSQL 标准做法是用 `pg_rewind` 修正旧主数据目录后再作为 standby 加入，但当前
PolarDB localfs/shared data 布局不支持我们直接使用标准 `pg_rewind`。

PolarDB 的受控切换测试里存在“旧主改成 standby”的流程，但前提是：先确认 standby replay 追平，
停止旧 primary 和其它节点，再改 recovery 配置并重启。这是 switchover 语义，不是旧 primary
失联后的自动 failover 语义。当前脚本版 HA 还没有实现这个受控 switchover 命令。

当前脚本版 HA 已删除自动增量 rejoin 模式，只保留两种行为：

- 默认：旧 primary 保留 PVC 并停住。
- `ha.rejoin.rebuildDemoted=true`: 运维显式接受全量重建后，清理该 Pod 本地数据并重新
  `polar_basebackup`。

为什么删除 `pg_rewind` 模式：当前镜像在 PolarDB localfs/shared data 布局下实测过标准
`pg_rewind` 失败，错误是 `/var/polardb/primary_datadir/global/pg_control` 不存在。PolarDB
源码中 `pg_rewind` 仍按 `global/pg_control` 读取 target；而 PolarDB postmaster 启动路径会把
shared storage 中的 `pg_control` 复制到本地，这不等于 `pg_rewind` 工具本身支持完整 PolarDB
目录布局。因此这个模式从脚本 HA 中删除，避免提供一个实际不可靠的恢复选项。

建议按下面流程手动处理：

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

3. 确认旧 primary 已被保护性停住：

```bash
kubectl logs -n polardb <old-primary-pod> -c polardb
```

日志会包含类似：

```text
This pod was demoted and requires manual rejoin or rebuild
Data is preserved at /var/polardb.
```

4. 如果需要保留旧 primary 现场进行排查，不要删除 PVC，也不要开启
   `ha.rejoin.rebuildDemoted`。可以把 PVC 快照、备份或挂载到独立环境做人工比对。

5. 只有在确认可以接受全量重建该 Pod 本地数据时，才开启：

```bash
helm upgrade -i polardb-for-postgresql ./deploy/charts/polardb-for-postgresql \
  -n polardb \
  --set ha.enabled=true \
  --set ha.rejoin.rebuildDemoted=true
```

6. 由于 HA StatefulSet 默认 `OnDelete`，删除旧 primary Pod 触发重新启动：

```bash
kubectl delete pod -n polardb <old-primary-pod>
```

全量重建会清理旧 primary 的本地数据并从当前 primary 重新 clone。如果同步复制曾被关闭，或者旧
primary 上存在没有同步到新 primary 的已提交事务，这些事务会丢失，因此不要在无法确认新 primary
健康和可接受 RPO 时执行该操作。

7. 旧 primary 成功作为 standby 回来后，建议关闭全量重建开关，避免后续误操作：

```bash
helm upgrade -i polardb-for-postgresql ./deploy/charts/polardb-for-postgresql \
  -n polardb \
  --set ha.enabled=true \
  --set ha.rejoin.rebuildDemoted=false
```

## 自动故障切换开关

默认已经关闭自动 failover：

```bash
helm upgrade -i polardb-for-postgresql ./deploy/charts/polardb-for-postgresql \
  -n polardb \
  --set ha.enabled=true \
  --set ha.failover.enabled=false
```

关闭后：

- 当前 primary 仍会续约 Lease。
- standby 仍会跟随当前 primary。
- Service role 仍会维护。
- standby 不会在 Lease 过期后自动 promote。
- 如果 primary 故障，业务可能不可写，需要人工恢复。

需要自动切换时显式开启：

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
- 旧 primary 故障后默认保留数据并停住，需要人工确认 rejoin 或显式重建。
- 没有安全 switchover，滚动维护时仍需要谨慎。
- 直接 Helm HA 默认使用 `OnDelete` 更新策略，避免自动重启 primary；升级时需要人工控制顺序。
- 默认同步复制降低数据丢失风险，但不能替代强 fencing；它也会在 standby 不可用时牺牲写入可用性。

## 后续优化清单

优先级从高到低：

1. standby 周期性上报 replay LSN，由最新 standby 才能接管。
2. 实现安全 switchover 命令。
3. 增加 replication slot 管理。
4. 研究 PolarDB localfs/shared data 场景下可靠的增量 rejoin 方式。
5. 增加 kind/minikube e2e 故障演练脚本。
