# PolarDB 17 + DocumentDB + FerretDB

这个目录构建一个 PolarDB 17 镜像，并在其中安装 FerretDB 需要的 DocumentDB 扩展链。`docker-compose.yml` 会启动两个容器：

- `polardb`: PolarDB 17 + DocumentDB 后端，只在 Compose 内部网络开放 PostgreSQL 端口。
- `ferretdb`: FerretDB MongoDB 协议入口，只向宿主机暴露 `127.0.0.1:27017`。

## 构建依赖

本机需要：

- Docker Engine
- Docker Compose v2
- 可访问 GitHub、Docker Hub、OSGeo 下载站点

镜像构建过程中会下载并编译：

- PolarDB `POLARDB_17_STABLE`
- DocumentDB `v0.107.0-ferretdb-2.7.0`，来自 FerretDB 官方 DocumentDB fork
- pgvector `v0.8.0`
- PostGIS `3.5.2`
- RUM `1.3.14`
- GEOS `3.12.2`

GEOS 使用源码构建，因为 Anolis/EPEL 8 中的 GEOS 版本太旧，不能满足 PostGIS 3.5.2 的要求。

## 已安装扩展

`CREATE EXTENSION documentdb CASCADE` 会安装 DocumentDB 及其依赖：

- `documentdb`
- `documentdb_core`
- `pg_cron`
- `tsm_system_rows`
- `vector`
- `postgis`
- `rum`

其中 `pg_cron` 和 `tsm_system_rows` 来自 PolarDB 17 RPM；`vector`、`postgis`、`rum` 由 Dockerfile 编译安装。

## 构建流程

Dockerfile 是三阶段构建：

1. `polardb-rpm-builder`: 从 PolarDB `POLARDB_17_STABLE` 构建 RPM。
2. `documentdb-builder`: 安装 PolarDB RPM，编译 GEOS、pgvector、PostGIS、RUM 和 DocumentDB。
3. Runtime 镜像: 复制 PolarDB 17、DocumentDB 扩展和 GEOS runtime，使用 `docker-entrypoint.sh` 生成 `/home/postgres/docker-entrypoint.sh` 初始化数据库。

初始化时会写入 FerretDB/DocumentDB 所需配置：

```conf
shared_preload_libraries = '$libdir/polar_vfs,$libdir/polar_io_stat,$libdir/polar_monitor_preload,$libdir/polar_worker,pg_cron,pg_documentdb_core,pg_documentdb'
cron.database_name = 'postgres'
polar_datadir = 'file-dio:///var/polardb/shared_datadir'
huge_pages = off
full_page_writes = on
password_encryption = 'scram-sha-256'
documentdb.enableIndexOrderbyPushdown = true
```

`password_encryption = 'scram-sha-256'` 很重要。FerretDB v2 使用 MongoDB SCRAM 认证，如果 PostgreSQL 角色密码仍是 md5 存储，`mongosh` 会认证失败。

## 直接构建镜像

```bash
docker build -t polardb17-documentdb-ferretdb:latest .
```

Dockerfile 使用 BuildKit cache mount 缓存 `dnf` 包下载和 GEOS/PostGIS 源码压缩包。GitHub Actions workflow 也开启了远端构建缓存。PolarDB、DocumentDB 和 PGXS 扩展的编译输出没有单独做目录级缓存，避免 PostgreSQL/PolarDB ABI、头文件或扩展版本变化时复用到不匹配的对象文件。

构建实践：

- 基础镜像使用 tag + digest 固定，避免同一个 tag 后续移动导致构建结果变化。
- PolarDB 源码固定到 `POLARDB_COMMIT`，默认跟随已验证的 `POLARDB_17_STABLE` 提交。
- `.dockerignore` 只放行构建需要的文件，减少上传到 BuildKit 的上下文。
- 多行包列表按名称排序，便于 review 依赖变化。
- Runtime 镜像只安装运行期包，并只从 builder 复制需要的 PolarDB/DocumentDB 文件和 GEOS 动态库。
- Runtime 约定尽量贴近 `polardb/polardb_pg_local_instance:17.9.1.0.248cd221`: `USER postgres`、`WORKDIR /home/postgres`、`ENTRYPOINT ["./docker-entrypoint.sh"]`、`CMD ["postgres"]`、`POLARDB_USER`、`POLARDB_PASSWORD`、`POLARDB_PORT`、`POLARDB_DATA_DIR=/var/polardb`、`PGHOST=127.0.0.1`。
- `POLARDB_ENABLE_DOCUMENTDB=1` 是本镜像提供的开关；镜像/Compose 默认启用 DocumentDB 配置和扩展初始化，Helm chart 默认关闭 FerretDB 时会把该值设为 `0`。已有数据目录后续开启该值时，entrypoint 会在下次启动时补齐 DocumentDB 配置并执行幂等的 `CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;`。
- 镜像内置 `HEALTHCHECK`，Compose 也基于 PostgreSQL 探活等待 FerretDB 启动。

## 使用 Docker Compose

启动：

```bash
docker compose up -d --build
```

查看状态：

```bash
docker compose ps
```

默认 MongoDB 连接地址：

```text
mongodb://postgres:ferretpass@localhost:27017/ferretdb_test?authSource=ferretdb_test&directConnection=true
```

连接：

```bash
mongosh 'mongodb://postgres:ferretpass@localhost:27017/ferretdb_test?authSource=ferretdb_test&directConnection=true'
```

停止：

```bash
docker compose down
```

删除数据卷并重新初始化：

```bash
docker compose down -v
```

如果修改了 `POLARDB_PASSWORD`，已有数据卷不会自动重置 PostgreSQL 角色密码；需要手动修改数据库角色密码，或使用 `docker compose down -v` 重新初始化。

如果直接使用宿主机目录挂载 `/var/polardb`，该目录需要能被容器内 `postgres`
用户写入。镜像默认以 `uid=1000,gid=1000` 运行，可以在启动前准备目录：

```bash
mkdir -p ./polardb-data
sudo chown 1000:1000 ./polardb-data
docker run -d \
  --name polardb \
  -v "$PWD/polardb-data:/var/polardb" \
  -e POLARDB_PASSWORD=ferretpass \
  polardb17-documentdb-ferretdb:latest
```

## 使用 Helm

默认 chart 会部署单副本 PolarDB StatefulSet、PostgreSQL ClusterIP Service、Secret 和 PVC，不开启 FerretDB：

```bash
helm upgrade -i polardb-for-postgresql ./deploy/charts/polardb-for-postgresql \
  -n polardb --create-namespace
```

Helm 默认随机生成数据库密码并写入 Secret；如果需要固定密码，可以设置 `--set auth.password=...`。

默认 PVC 大小为 `3G`。Chart 会设置 StatefulSet 的 PVC retention policy：
删除 release 时删除 PVC，缩容时保留 PVC。如果希望使用集群默认行为，可以设置
`--set polardb.persistence.persistentVolumeClaimRetentionPolicy.enabled=false`。

默认 PolarDB 镜像为：

```text
ghcr.io/labring-sigs/polardb-for-postgresql:latest
```

如果要从本机访问 MongoDB 协议入口：

```bash
helm upgrade -i polardb-for-postgresql ./deploy/charts/polardb-for-postgresql \
  -n polardb --create-namespace \
  --set ferretdb.enabled=true

kubectl port-forward svc/polardb-for-postgresql-ferretdb -n polardb 27017:27017
POLARDB_PASSWORD="$(kubectl get secret polardb-for-postgresql-auth -n polardb -o jsonpath='{.data.polardb-password}' | base64 -d)"
mongosh "mongodb://postgres:${POLARDB_PASSWORD}@localhost:27017/ferretdb_test?authSource=ferretdb_test&directConnection=true"
```

已有 PVC 后续从默认 PostgreSQL 模式升级到 `ferretdb.enabled=true` 时，PolarDB Pod 重启会自动补齐 DocumentDB 配置并创建扩展。

### Kubernetes HA 模式

这个仓库内置了一个轻量级 HA 组件，默认关闭。它不是完整 operator，而是部署在
StatefulSet 里的 sidecar 脚本，目标是先提供类似 PostgreSQL/MySQL/Redis 常见
主从高可用的最小可用闭环：

- 每个 PolarDB Pod 使用独立 RWO PVC。
- `polardb-0` 首次初始化为 primary，其它 Pod 通过 `polar_basebackup --polardata`
  从 primary 克隆成本地 standby。
- HA sidecar 使用 Kubernetes `Lease` 做主节点仲裁，借鉴 Patroni/Stolon 这类
  PostgreSQL HA 项目的 DCS 思路。
- 主库 Service 只选择带 `polardb-role=primary` 的 Pod；可选 replica Service
  只选择 `polardb-role=standby` 的 Pod。
- Lease 过期且本地 standby 健康时，sidecar 执行 `pg_ctl promote` 并接管主库
  Service。
- 如果某个 Pod 本地 PostgreSQL 是 primary 但它不持有 Lease，sidecar 会停止本地
  PostgreSQL，并写入 `/var/polardb/ha-demoted`，避免旧主库重启后形成双主。
- 新 primary 设置角色前会清理其它 Pod 残留的 `polardb-role=primary` label。

完整 HA 设计、部署、故障切换、旧主恢复和维护流程见
[`docs/high-availability.md`](docs/high-availability.md)。

启用示例：

```bash
helm upgrade -i polardb-for-postgresql ./deploy/charts/polardb-for-postgresql \
  -n polardb --create-namespace \
  --set auth.password=change-me \
  --set ha.enabled=true \
  --set ha.replicaCount=3
```

主库连接入口仍然是：

```text
polardb-for-postgresql-polardb:5432
```

只读 standby 入口默认是：

```text
polardb-for-postgresql-polardb-replica:5432
```

常用观察命令：

```bash
kubectl get pod -n polardb -l app.kubernetes.io/component=polardb --show-labels
kubectl get lease -n polardb
kubectl logs -n polardb statefulset/polardb-for-postgresql-polardb -c ha-manager
```

旧主库被 fencing 后不会自动清空 PVC 重新加入。确认集群已有新 primary 后，可以临时设置
`POLARDB_HA_REJOIN=1` 让该 Pod 删除本地数据并重新从当前主库克隆；生产环境建议把这个动作
封装成受控运维流程，而不是完全自动执行。

边界说明：

- 这是脚本版 HA，不是生产级 operator；还需要补充分区、节点宕机、长时间复制延迟、PVC
  损坏、Kubernetes API 抖动、旧主库回归等场景的系统测试。
- 当前实现走 standby 流复制模式，不要求 RWX/PFS 共享盘。PolarDB 源码里的 RO/replica
  共享存储模式和这里的独立 PVC standby 模式不是同一种部署模型。
- 复制槽默认未绑定到 standby，主要依赖 `wal_keep_size` 降低 failover 后新主库缺少旧 slot
  的复杂度；如果要做生产级数据保护，需要继续实现 slot 同步/重建、复制延迟阈值和更严格的
  promotion 前检查。
- 设计原则参考了 Patroni/Stolon 的 DCS/keeper 模型、Redis Sentinel 的故障仲裁和
  MySQL Orchestrator 的拓扑恢复思路，但这里为了贴合当前镜像和 Helm chart，先落为
  Kubernetes Lease + sidecar 的最小实现。

## 使用 Sealos Cluster Image

发布 workflow 会基于 `deploy/Kubefile` 构建多架构 cluster image，并在镜像名后追加 `-cluster`。例如仓库为 `labring-sigs/PolarDB-for-PostgreSQL` 时，默认 GHCR cluster image 为：

```text
ghcr.io/labring-sigs/polardb-for-postgresql-cluster:<tag>
```

安装时可通过环境变量覆盖 release、namespace 或 Helm 参数：

```bash
sealos run ghcr.io/labring-sigs/polardb-for-postgresql-cluster:<tag>

NAMESPACE=polardb HELM_OPTS='--set auth.password=change-me --set ferretdb.enabled=true' \
  sealos run ghcr.io/labring-sigs/polardb-for-postgresql-cluster:<tag>
```

## 测试

可以用 `mongo:8` 镜像中的 `mongosh` 做真实 MongoDB 协议读写测试。下面的命令适用于 Docker Desktop；如果是在 Linux 上，也可以直接用本机安装的 `mongosh` 连接 `localhost:27017`。

```bash
docker run --rm mongo:8 mongosh \
  'mongodb://postgres:ferretpass@host.docker.internal:27017/ferretdb_test?authSource=ferretdb_test&directConnection=true' \
  --quiet \
  --eval '
db.items.drop();
db.items.insertMany([
  { _id: 1, name: "alpha", qty: 2, tags: ["polar", "docdb"] },
  { _id: 2, name: "beta", qty: 5, tags: ["ferret", "mongo"] },
  { _id: 3, name: "gamma", qty: 8, tags: ["polar", "ferret"] }
]);
db.items.updateOne({ _id: 2 }, { $inc: { qty: 3 }, $set: { checked: true } });
printjson({ ping: db.runCommand({ ping: 1 }) });
printjson({ countGte5: db.items.countDocuments({ qty: { $gte: 5 } }) });
printjson({ polarDocs: db.items.find({ tags: "polar" }).sort({ _id: 1 }).toArray() });
printjson({ aggregate: db.items.aggregate([{ $group: { _id: null, totalQty: { $sum: "$qty" }, maxQty: { $max: "$qty" } } }]).toArray() });
'
```

预期结果应包含：

```text
ping.ok = 1
countGte5 = 2
aggregate.totalQty = 18
aggregate.maxQty = 8
```

也可以检查 PolarDB 内部扩展：

```bash
docker compose exec polardb psql -U postgres -p 5432 -d postgres -Atc \
  "show password_encryption; show shared_preload_libraries; select extname || ':' || extversion from pg_extension order by extname;"
```

应看到 `documentdb`、`documentdb_core`、`pg_cron`、`postgis`、`rum`、`tsm_system_rows`、`vector` 等扩展。

## 关键文件

- `Dockerfile`: 构建 PolarDB 17 + DocumentDB 运行镜像。
- `docker-entrypoint.sh`: 以 PolarDB 官方 local instance 入口为基准做单 primary 适配，初始化 PolarDB 数据目录、写入 DocumentDB 配置、创建扩展、设置 SCRAM 密码。
- `docker-compose.yml`: 启动 PolarDB 和 FerretDB 两个容器，只暴露 MongoDB 连接端口。
