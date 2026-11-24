# RexHub

RexHub 一体化仓库：iOS App + PWA 前端（Next.js）+ 后端 API（FastAPI）。
后端以原 `sehua-next-web` 的 `server/api` 为底座，原独立 `RexHub/server` 的影视/插件/115 能力
已迁入 `server/api/app/rexhub/`，仓库里只有一套后端在跑。

## 目录

```
RexHub/
├── server/                NAS 部署单元（后端 + PWA + 配套资源，构建上下文就在这里）
│   ├── api/              后端（FastAPI，统一 8020）
│   │   ├── app/          业务域：search / media / ai / prefix …
│   │   └── app/rexhub/   RexHub 原生能力：/api/*、/plugins
│   ├── web/              PWA 前端（Next.js，端口 3020，/api 反代到后端）
│   ├── maps/             前端与后端共用的映射数据（构建时同步进 web/maps）
│   ├── config/           后端配置：app.json（公开默认）/ app.local.json（本机密钥，不入库）
│   ├── data/             运行时数据（元库 meta.db、data/rexhub/ JSON 存储）
│   ├── media/            STRM / 刮削库（体积大，不入库）
│   ├── docker/           entrypoint / supervisord / healthcheck 配套文件
│   ├── scripts/          本地一键启动（dev.sh / stop-dev.sh）
│   └── Dockerfile / docker-compose.yml / package.json
├── docs/
│   ├── backend/          后端文档（目录约定、刮削流水线等）
│   └── ios/              iOS 客户端重建设计报告
└── refs/                 本地参考，不入库：ios-legacy（旧 iOS 客户端）等
```

## 本地启动

依赖：Python 3.12（`~/.local/bin/python3.12`）、Node 22（`~/.local/node/bin`）。
元库是本地 SQLite（默认 `server/data/meta.db`，可用 `SNS_META_DB` 指到别处）。

```bash
# 首次
cd server/api && ~/.local/bin/python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt
cd ../web     && npm install

# 日常：API(8020) + Web(3020) 一起起（在 server/ 下执行）
cd ..         && npm run dev     # = bash scripts/dev.sh
npm run stop                     # 停掉
```

- API：<http://127.0.0.1:8020>（`/health`、`/docs`）
- 所有管理操作在 PWA 内完成（`/settings`「更多」页），不再提供 `/admin` 控制台
- PWA：<http://127.0.0.1:3020>

`server/web` 的 `/api/:path*` 会反代到 `API_INTERNAL_BASE`（见 `server/web/.env.local`，默认本机 8020）。

### 首次登录（首个管理员）

新库启动时还没有管理员，API 启动日志会打印一次管理员邀请码：

- 本地：`npm run dev` 的 API 输出中查找 `尚无管理员账号，管理员邀请码：…`
- 容器：`docker logs sehua-next-web | grep 管理员邀请码`

在登录页「注册账号」填入该码即注册为管理员；之后可在「更多 → 用户管理 → 邀请码」查看/轮换管理员码与普通用户码。邀请码在轮换前一直有效，轮换后旧码立即失效。

## iOS

SwiftUI 客户端（iPhone + iPad）在 `ios/`，设计基线见 `docs/ios/ios-redesign.md`。最低 iOS 18，播放内核 KSPlayer（GPL-3.0）。

```bash
cd ios
./tools/generate-project.sh     # XcodeGen 生成 RexHub.xcodeproj（真机需先设置 REXHUB_DEVELOPMENT_TEAM）
./tools/run-tests.sh            # 单测（默认 iPhone 17 模拟器）
```

模块：`RexCore`（模型 / 设计 token）、`RexNetworking`（HTTP）、`RexData`（Keychain / 会话 / 本地存储）、`RexUI`（组件）、`RexPlayer`（播放）、`RexFeatures`（页面）。当前完成 M0（登录 + 四 Tab 骨架）与 M1（搜索：范围 / 筛选 / 分页 / 最近搜索 + 资源详情）。

## 部署

`docker-compose.yml` 为 NAS 部署（Web 3020 + API 8020 + 刮削 Worker + Postgres），
细节见 `docs/backend/`。

## 迁移现状

- 旧独立后端已退役并删除；当前只有 `server/api` 一套后端在跑。
- 原 `RexHub/server` 的 `data/`（115 登录态、插件、服务配置、进度）已迁到 `data/rexhub/`。
