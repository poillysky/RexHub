# RexHub 部署

RexHub 是轻量单体：一个镜像里同时跑 **web(3020) + api(8020)**，元库是 **SQLite**（`data/meta.db`）。
**不需要 Postgres**；色花/Bitmagnet 资源库 DSN 是可选高级功能（网页设置里填，无外部编排依赖）。

## 二选一编排

| 文件 | 场景 |
|---|---|
| `docker-compose.rexhub.yml` | **推荐**。RexHub 单容器版：web+api 一个容器，`./data` 挂 SQLite |
| `nas-docker-compose.yml` | 旧三容器模板（含 Postgres）——**只在你确实要跑资源库扫描时才用** |

## 单容器启动（推荐）

```bash
mkdir -p rexhub-deploy/{data,config}
cd rexhub-deploy
cp /path/to/deploy/docker-compose.rexhub.yml docker-compose.yml

docker compose pull && docker compose up -d
# 首次登录拿邀请码
docker logs rexhub | grep 管理员邀请码
```

访问 `http://NAS_IP:3020`。

## 持久化

- `./data/` → `/app/data`：meta.db（账号/设置/缓存）必须保留。
- `./config/` → `/app/config`：可选，放 `app.local.json`（115 账号、AI key、资源库 DSN 等私有配置）。

备份只需 `data/` + `config/` 两个目录。

## 升级

1. 把 `docker-compose.rexhub.yml` 里 `image:` 的版本号改新。
2. `docker compose pull && docker compose up -d`。

## 安全项

- 需要 HTTPS 时在 3020 前挂反向代理，并透传 `X-Forwarded-Proto`（`SNS_COOKIE_SECURE` 会自动按协议处理）。
- 想改对外端口，改 `ports: "3020:3020"` 左侧即可。