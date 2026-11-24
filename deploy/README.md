# RexHub NAS 部署

生产版编排模板：`deploy/nas-docker-compose.yml`（三容器：postgres + scrape-worker + app，全部拉取 Docker Hub 镜像）。

## 目标目录

```
/vol1/1000/Docker/sehua-next-web/
├── docker-compose.yml        ← 复制 deploy/nas-docker-compose.yml 过来
├── data/                     ← 运行时数据（meta.db 等，自动挂载）
├── postgres/                 ← Postgres 数据（库 nextweb）
└── config/                   ← app.json / app.local.json（可留空，不填用默认）
```

**注意**：`docker-compose.yml` 用的是相对路径 `./data`、`./postgres`、`./config`，请在目标目录下执行（不要在 `server/` 里直接起）。

## 第一次部署

```bash
mkdir -p /vol1/1000/Docker/sehua-next-web/{data,postgres,config}
cd /vol1/1000/Docker/sehua-next-web
# 把 deploy/nas-docker-compose.yml 复制/ata 成本目录的 docker-compose.yml
cp -r /path/to/repo/deploy/nas-docker-compose.yml docker-compose.yml

docker compose pull
docker compose up -d

# 等 1~2 分钟，拿管理员邀请码
docker logs sehua-next-web | grep 管理员邀请码
```

## 端口

| 服务 | 端口 | 说明 |
|---|---|---|
| PWA Web | `3020` | 浏览器访问 `http://NAS_IP:3020` |
| API | 8020（容器内） | 不对外映射，UI 内部调用 |
| Postgres | `5439` → 5432 | 库名 `nextweb`，用户/密码 `postgres/postgres` |

## 升级版本

1. 改 `image: poillysky/sehua-next-web:1.2.28` 为最新版本号。
2. `docker compose pull && docker compose up -d`（app 与 scrape-worker 会逐个重启）。

## 安全项（按需改）

- Postgres 默认 `postgres/postgres`，生产建议改掉（`POSTGRES_PASSWORD`，并同步放 config 里的 DSN）。
- `data/`、`config/` 是持久卷，备份时拷这两个目录即可。
- 需要 HTTPS 时在 3020 前挂反向代理（nginx/caddy），并透传 `X-Forwarded-Proto`。