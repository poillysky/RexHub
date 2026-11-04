# RexHub

RexHub 一体化仓库：iOS App + PWA 前端（Next.js）+ 后端 API（FastAPI）。
后端以原 `sehua-next-web` 的 `apps/api` 为底座，原独立 `RexHub/server` 的影视/插件/115 能力
已迁入 `apps/api/app/rexhub/`，仓库里只有一套后端在跑。

## 目录

```
RexHub/
├── apps/
│   ├── api/               后端（FastAPI）
│   │   ├── app/           业务域：search / media / ai / prefix …
│   │   └── app/rexhub/    RexHub 原生能力：/api/*、/plugins、/stremio、/addon
│   ├── web/               PWA 前端（Next.js，端口 3020，/api 反代到后端）
│   └── maps/              前端与后端共用的映射数据（构建时同步进 apps/web/maps）
├── ios/                   iOS 工程：RexHub.xcodeproj + RexHub/ 源码 + Config/Info.plist
├── config/                后端配置：app.json（公开默认）/ app.local.json（本机密钥，不入库）
├── data/                  运行时数据：next-web 缓存；data/rexhub/ 为原 RexHub 的 JSON 存储
├── media/                 STRM / 刮削库（体积大，不入库）
├── docker/                Dockerfile/entrypoint/supervisord 配套文件
├── docs/
│   ├── ios/               iOS 设计与需求文档
│   └── backend/           后端文档（目录约定、刮削流水线等）
├── reference/             本地参考，不入库：legacy-server（旧独立后端）、third-party、hongguo-selfhost
├── scripts/dev.sh         本地一键启动（API + Web）
└── Dockerfile / docker-compose.yml
```

## 本地启动

依赖：Python 3.12（`~/.local/bin/python3.12`）、Node 22（`~/.local/node/bin`）。
元库是本地 SQLite（默认 `data/meta.db`，可用 `SNS_META_DB` 指到别处）。

```bash
# 首次
cd apps/api  && ~/.local/bin/python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt
cd ../../apps/web && npm install

# 日常：API(8787) + Web(3020) 一起起
npm run dev          # = bash scripts/dev.sh
npm run stop         # 停掉
```

- API：<http://127.0.0.1:8787>（`/health`、`/docs`）
- 所有管理操作在 PWA 内完成（`/settings`「更多」页），不再提供 `/admin` 控制台
- PWA：<http://127.0.0.1:3020>

`apps/web` 的 `/api/:path*` 会反代到 `API_INTERNAL_BASE`（见 `apps/web/.env.local`，默认本机 8787）。

## iOS

```bash
cd ios
xcodebuild -project RexHub.xcodeproj -scheme RexHub -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

服务端地址在 App「设置 → 服务端」里填 `主机:8787`。

## 部署

`docker-compose.yml` 为 NAS 部署（Web 3020 + API 8020 + 刮削 Worker + Postgres），
细节见 `docs/backend/`。

## 迁移现状

- 旧独立后端已退役，代码保留在 `reference/legacy-server/` 仅作参考，不参与运行。
- 原 `RexHub/server` 的 `data/`（115 登录态、插件、服务配置、进度）已迁到 `data/rexhub/`。
