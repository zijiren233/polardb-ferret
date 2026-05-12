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
3. Runtime 镜像: 复制 PolarDB 17、DocumentDB 扩展和 GEOS runtime，使用 `polardb-entrypoint.sh` 初始化数据库。

初始化时会写入 FerretDB/DocumentDB 所需配置：

```conf
shared_preload_libraries = 'pg_cron,pg_documentdb_core,pg_documentdb'
cron.database_name = 'postgres'
password_encryption = 'scram-sha-256'
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

如果修改了 `POLARDB_POSTGRES_PASSWORD`，已有数据卷不会自动重置 PostgreSQL 角色密码；需要手动修改数据库角色密码，或使用 `docker compose down -v` 重新初始化。

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
- `polardb-entrypoint.sh`: 初始化 PolarDB 数据目录、写入 DocumentDB 配置、创建扩展、设置 SCRAM 密码。
- `docker-compose.yml`: 启动 PolarDB 和 FerretDB 两个容器，只暴露 MongoDB 连接端口。
