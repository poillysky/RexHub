# 镜像云构建 & Docker Hub 部署

镜像由 GitHub Actions 在云端构建（`.github/workflows/docker-build.yml`），推送到 Docker Hub，NAS 侧 `docker compose pull` 直接拉取。

## 镜像

- 名称：`poillysky/rexhub`
- 当前版本：`1.0.0`
- 架构：`linux/amd64` + `linux/arm64` 多架构
- 构建上下文：`server/`（`server/Dockerfile`，单镜像含 web 3020 + api 8020，supervisord 托管）

## 一次性配置：GitHub repo secrets

仓库 → Settings → Secrets and variables → Actions → New repository secret：

| Secret | 值 |
|---|---|
| `DOCKERHUB` | Docker Hub → Account settings → Security → New Access Token（Read & Write） |

> 不要用 Docker Hub 登录密码，用 Access Token。

## 触发构建

三种方式任选：

1. **推 main**：`git push origin main` 自动构建。
2. **打 tag（推荐按版本）**：
   ```bash
   git tag v1.0.0 && git push origin v1.0.0
   ```
   生成的镜像 tag：`1.0.0` / `v1.0.0` / `latest` / `main`。
3. **手动**：Actions → Build & Push Image → Run workflow，可填额外 tag。

> 发版时记得同时把 `server/docker-compose.yml` 里的 `image: …:1.0.0` 版本号与 `DEFAULT_VERSION`（workflow 里）一起改。

## NAS 部署

目录结构（与 compose 注释一致）：

```
/vol1/1000/Docker/rexhub/
├── docker-compose.yml
├── data/        → /app/data
├── postgres/    → Postgres 数据（库 nextweb）
└── config/      app.json / app.local.json
```

```bash
mkdir -p /vol1/1000/Docker/rexhub/{data,postgres,config}
cd /vol1/1000/Docker/rexhub
# 放好 docker-compose.yml 后
docker compose pull
docker compose up -d
```

访问：`http://NAS_IP:3020`。

## 首次登录

新库没有管理员，API 启动日志打印一次管理员邀请码：

```bash
docker logs rexhub | grep 管理员邀请码
```

登录页「注册账号」填入该码即注册为管理员。

## 版本升级流程

1. 改代码 → 提交推送 main。
2. 升版本号（三处保持一致）：
   - `server/docker-compose.yml` 的 `image:` tag
   - `.github/workflows/docker-build.yml` 的 `DEFAULT_VERSION`
   - `server/Dockerfile` 顶部注释（可选）
3. 打 tag 推送：`git tag vX.Y.Z && git push origin vX.Y.Z`。
4. Actions 构建完成后，NAS 上 `docker compose pull && docker compose up -d`。
