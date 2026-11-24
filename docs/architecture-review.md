# RexHub 项目梳理与架构评审（后端 / PWA / iOS）

> 范围：`server/api`（后端）、`server/web`（管理 PWA）、`ios`（iOS 客户端）。
> 依据：当前仓库源码静态阅读，未启动服务、未运行测试、未做真机验证。
> 结论分两档：**确定问题**（代码路径可直接证明）与**待验证风险**（取决于部署、数据或运行时行为）。
>
> 2026-11-17 更新：插件框架已整体删除；服务管理不再提供「短剧源」录入，短剧服务改为后续直接接入；§6 中已修复项标注 ✅ / 🟡，随插件删除而失效的项标注「已消除」。

---

## 1. 项目全貌

RexHub 是「一套自托管后端 + 两个客户端」的媒体/资源聚合系统：

```
┌──────────────────────────────┐      ┌──────────────────────────────┐
│ iOS App (SwiftUI, KSPlayer)  │      │ PWA (Next.js 16, React 19)   │
│ 首页/海报墙/资源库/115        │      │ 单页五 Tab + 手写 SW          │
└──────────────┬───────────────┘      └──────────────┬───────────────┘
               │  /api/* (Bearer)                    │  /api/* (Cookie, Next rewrite)
               └───────────────┬─────────────────────┘
                               ▼
                 ┌───────────────────────────────┐
                 │ FastAPI 8020                  │
                 │ 认证/搜索/影视/片商/短剧/115/AI │
                 │ 服务管理 / 出站调度 / 流代理   │
                 └───────┬───────────────┬───────┘
                         │               │
              SQLite meta.db       PostgreSQL（资源库 / Bitmagnet）
              会话/用户/设置        大表检索
                         │
              JSON 文件状态（服务、115、进度、外观…）
                         │
              外部服务（NAS / 短剧服务 / MoviePilot / MorePlay…）
```

> 演进说明：原「插件框架」（`plugin_framework` / `plugin_api` / `widget_runtime`）已整体删除，
> 短剧服务后续直接接入，当前 PWA 服务管理不再提供短剧源录入；
> 后端仍保留 `source_kind` / `api_base` / `endpoints` 的读取能力，供接入时复用。

仓库目录职责：

| 目录 | 职责 | 现状 |
|---|---|---|
| `server/api` | 唯一后端 | FastAPI，统一 `/api` 前缀 |
| `server/web` | 管理 PWA | Next.js standalone，`/api` 反代 8020 |
| `ios` | 原生客户端 | SwiftUI 单 target，KSPlayer |
| `server/maps`、`server/config` | 映射与配置 | 构建时同步进 web |
| `refs/ios-modular` | 模块化参考工程 | 非当前实现 |
| `plugins`、`services` | 历史示例插件与中继 | **插件已删除**；服务管理只保留 NAS 服务卡片 |

---

## 2. 后端（FastAPI）

### 2.1 技术栈与运行形态

- FastAPI + Pydantic v2 + Uvicorn；同步/异步路由、SSE、NDJSON 混用。
- 依赖：`psycopg`、`httpx[socks]`、`curl_cffi`、`bcrypt`、`p115client`、`py7zr/rarfile`、`quickjs/esprima`、`jieba`。
- 开发：`dev_server.py` 以 watchfiles 硬重启，监听 `0.0.0.0:8020`。
- 生产：Docker 内 Supervisor 同时拉起 Next.js 与绑定 `127.0.0.1:8020` 的 Uvicorn。

关键文件：[main.py](file:///Volumes/vol1T/project/RexHub/server/api/app/main.py#L57-L80)、[dev_server.py](file:///Volumes/vol1T/project/RexHub/server/api/dev_server.py#L19-L30)、[Dockerfile](file:///Volumes/vol1T/project/RexHub/server/Dockerfile#L37-L67)。

### 2.2 部署拓扑（重要）

`docker-compose.yml` 里实际有**两个 API 实例**：

| 容器 | 角色 | 端口 | 说明 |
|---|---|---|---|
| `app` | UI | 3020 | Supervisor 跑 Next + Uvicorn(127.0.0.1:8020) |
| `scrape-worker` | Worker | 8020 内网 | 同样跑 `app.main:app` |
| `postgres` | pgvector | 5439 | 资源库与 Bitmagnet 数据库 |

两者挂载同一个 `/app/data`，使用同一个 `app.main:app` 与同一个 lifespan。`APP_ROLE` 只选择 Supervisor 配置，Python 启动逻辑不分角色。

证据：[docker-compose.yml](file:///Volumes/vol1T/project/RexHub/server/docker-compose.yml#L83-L155)、[main.py](file:///Volumes/vol1T/project/RexHub/server/api/app/main.py#L57-L80)。

**这是本项目最重要的架构前提，也是多数缺陷的根源。**

### 2.3 启动生命周期

`lifespan` 依次执行：初始化 SQLite 元库 → 从配置 seed 设置 → 初始化邀请码 → 清理过期会话 → 启动 FlareSolverr monitor；关闭时停止 monitor 与数据库资源。**不再有插件 autostart / stop_all**。

无管理员时会把管理员邀请码打印到启动日志（首次部署便利，但会进入容器日志）。

### 2.4 业务能力

| 域 | 能力 | 主要实现 |
|---|---|---|
| 认证 | 登录/注册/登出、改密、管理员重置、邀请码 | [auth/routes.py](file:///Volumes/vol1T/project/RexHub/server/api/app/auth/routes.py#L56-L185) |
| 资源检索 | PG 资源浏览/搜索/详情、番号前缀、封面、分页 | [search/resource_routes.py](file:///Volumes/vol1T/project/RexHub/server/api/app/search/resource_routes.py) |
| 磁力 | Bitmagnet 搜索/详情/文件预览、CloudSaver、AVDB | [search/magnet_routes.py](file:///Volumes/vol1T/project/RexHub/server/api/app/search/magnet_routes.py) |
| 聚合搜索 | 影视/片商两套 scope，多源并行 + 预算控制 | [scope_routes.py](file:///Volumes/vol1T/project/RexHub/server/api/app/search/scope_routes.py#L469-L523) |
| 影视 | TMDB 类货架/详情/影人、MoviePilot、MorePlay 多线路解析 | [moviepilot_routes.py](file:///Volumes/vol1T/project/RexHub/server/api/app/core/moviepilot_routes.py)、[moreplay_routes.py](file:///Volumes/vol1T/project/RexHub/server/api/app/core/moreplay_routes.py#L433-L562) |
| 片商 | AVDB 榜单/演员/实体/评论/种子 | [makers/router.py](file:///Volumes/vol1T/project/RexHub/server/api/app/makers/router.py) |
| 短剧 | 站点/目录/榜单/搜索/播放、流代理（站点来源待短剧服务接入） | [shortdrama.py](file:///Volumes/vol1T/project/RexHub/server/api/app/rexhub/routers/shortdrama.py#L773-L899) |
| 115 | 目录、上传、转存、删除/移动/复制、播放直链、云端与本地解压、观看进度 | [pan.py](file:///Volumes/vol1T/project/RexHub/server/api/app/rexhub/routers/pan.py#L219-L726) |
| AI | OpenAI 兼容对话、SSE、AI 搜索、预设、向量编码 | [assistant_routes.py](file:///Volumes/vol1T/project/RexHub/server/api/app/ai/assistant_routes.py#L573-L621) |
| 服务管理 | NAS 服务卡片、连通性探测（NAS 走 socket） | [services_store.py](file:///Volumes/vol1T/project/RexHub/server/api/app/rexhub/services_store.py)、[admin.py](file:///Volumes/vol1T/project/RexHub/server/api/app/rexhub/routers/admin.py) |
| 设置 | 资源库/Bitmagnet DSN、代理、FlareSolverr | [settings.py](file:///Volumes/vol1T/project/RexHub/server/api/app/rexhub/routers/settings.py) |
| 流代理 | 逐跳 SSRF 校验、Range 转发、Content-Type 白名单 | [stream_proxy.py](file:///Volumes/vol1T/project/RexHub/server/api/app/core/stream_proxy.py#L29-L183) |

### 2.5 认证与存储

- **会话不是 JWT**：`secrets.token_urlsafe(32)` 不透明 token，DB 只存 SHA-256，30 天有效，支持撤销/过期清理。
- Cookie 为 HttpOnly + SameSite=Lax，Secure 按协议/环境决定；同时响应体返回 token 供 iOS 使用。
- token 读取优先级：显式 query token > Cookie > Bearer。
- 角色：管理员 / 普通用户。DB 配置、服务管理、115 写操作、解压接口均为管理员。
- 元数据 SQLite：`app_settings / users / sessions / torrent_file_cache`，WAL + 外键 + 30s busy timeout。
- 资源库/Bitmagnet：独立 `DbPool`，最大 14 / 8 连接，DSN 变更重建池。
- 缓存均为进程内 TTL 缓存（设置 3s、资源搜索 30s、前缀、代理地址等），无跨副本失效。

证据：[auth/store.py](file:///Volumes/vol1T/project/RexHub/server/api/app/auth/store.py#L17-L140)、[core/db.py](file:///Volumes/vol1T/project/RexHub/server/api/app/core/db.py#L73-L83)、[core/pg_pool.py](file:///Volumes/vol1T/project/RexHub/server/api/app/core/pg_pool.py#L74-L158)。

### 2.6 服务管理与出站

- 插件框架已删除。服务管理（`services.json`）当前只承载 NAS 服务卡片：`host/port` + `section`（general / movie / girl）。
- PWA 服务管理提供固定面板：Bitmagnet、CloudSaver、色花堂、AVDB、MoviePilot、MorePlay；**不再提供「短剧源」录入**。
- 后端仍保留 `source_kind` / `api_base` / `endpoints{}` / `ui{}` 字段与 `list_sources("shortdrama")` 读取链路，供短剧服务后续直接接入；当前无条目时短剧站点为空。
- 短剧路由按 `source_kind` 读取记录，端点缺省时用 `DEFAULT_ENDPOINTS` + `CAPABILITY_ALIASES`（如 `shortdrama.ranks` 回退 `video.ranks`/`ranks`）兜底。
- 探测按有无 `host+port` 分流：NAS 服务走 socket，内容源走 HTTP HEAD。
- 出站调度统一管理全局/每 host 并发、请求间距、429/503 退避、取消令牌。
- 拉页阶梯：`curl_cffi` → `httpx` → FlareSolverr；流代理逐跳解析 DNS 并拒绝内网/回环地址。

### 2.7 后端测试与可观测性

- **未发现项目自有测试**：`app/` 下没有 `test_*.py` / `conftest.py`，`package.json` 无测试脚本。
- `/health` 只返回进程、版本、SQLite 路径；不检查 PG、FlareSolverr 或后台任务。
- 无 Prometheus / OpenTelemetry / Sentry 接入；日志主要靠标准 logging + Supervisor。

---

## 3. 管理 PWA（Next.js）

### 3.1 技术栈与构建

- Next 16.1.6 App Router、React 19、TypeScript 5 strict、TanStack Query 5、Tailwind 4 + shadcn、hls.js。
- `output: 'standalone'`；`/api/:path*` rewrite 到 `API_INTERNAL_BASE`（默认 `127.0.0.1:8020`），代理超时 3600s；`/sw.js` 禁止 HTTP 缓存。
- 构建前执行 `sync-maps` 复制共享映射 JSON，源文件缺失会直接构建失败。

证据：[package.json](file:///Volumes/vol1T/project/RexHub/server/web/package.json#L5-L37)、[next.config.ts](file:///Volumes/vol1T/project/RexHub/server/web/next.config.ts#L5-L74)。

### 3.2 页面与导航

- 真正的主应用只有一个路由 `/`：认证门内挂载搜索、影视、片商、短剧、更多五个 `TabPane`。
- `/settings`、`/boards` 重定向到 `/#settings`、`/#boards`；`/detail/[hash]` 转回 `/?detail=hash`。
- 五个 Pane 常驻不卸载，靠横向轨道位移切换；底栏是普通 flex 子元素而非 fixed。
- 自定义导航内核：`pushState/replaceState/back` + 自定义 `NAV_EVENT` + `history.state.__navDepth` 判断返回方向；首页用 query（`?keyword=...`），其余 Tab 用 hash（`#media/detail?...`）。

证据：[page.tsx](file:///Volumes/vol1T/project/RexHub/server/web/src/app/page.tsx#L14-L42)、[AppShell.tsx](file:///Volumes/vol1T/project/RexHub/server/web/src/shell/AppShell.tsx#L29-L129)、[urlNav.ts](file:///Volumes/vol1T/project/RexHub/server/web/src/shell/nav/urlNav.ts#L95-L186)。

### 3.3 业务功能

| Tab | 能力 |
|---|---|
| 搜索 | 影视（Bitmagnet/CloudSaver）与片商（AVDB/Bitmagnet/色花堂）双范围、筛选、无限分页、详情、115 转存、AI 对话、板块 |
| 影视 | 货架/榜单/探索、MoviePilot 搜索与下载、影人、PT 搜索、MorePlay 流式片源 |
| 片商 | AVDB 榜单、标签、演员、实体、片单、评论、种子与播放源 |
| 短剧 | 短剧站点、目录、榜单、搜索、详情、选集、播放（服务未接入时为空态） |
| 更多 | 用户/管理员、外观、115、Bitmagnet、CloudSaver、色花堂、AVDB、MoviePilot、MorePlay、网络、AI |

普通用户隐藏 AI 管理入口，管理项按 `isAdmin` 显示。

### 3.4 认证与缓存

- 四态认证：`loading | anonymous | authenticated | offline`；挂载时 `authMe()` 恢复 Cookie 会话；网络/服务端异常进入 `offline` 并提示重试，不再把已登录用户误踢回登录页；任意请求 401 才派发 `rexhub:unauthorized` 回匿名。
- QueryClient 是浏览器长期单例，全局 `staleTime` 30s、focus 刷新；各业务域自定义 2–30 分钟。
- 短剧另有两份模块级 `Map`（TTL 5 分钟），115 面板另有模块级快照（TTL 120 秒）。

证据：[AuthProvider.tsx](file:///Volumes/vol1T/project/RexHub/server/web/src/providers/AuthProvider.tsx#L20-L101)、[providers.tsx](file:///Volumes/vol1T/project/RexHub/server/web/src/app/providers.tsx#L10-L27)。

### 3.5 PWA 与离线

- 手写 Service Worker + 静态 manifest，无 `next-pwa`。
- install 预缓存离线外壳（`/`、manifest、图标）后 `skipWaiting()`；activate 删除全部非 `app-v5` 缓存并 `clients.claim()`。
- `/api/` 与 `cover-proxy` 完全绕过缓存；导航 network-first → 缓存 → `/`；静态资源 stale-while-revalidate。
- `cachePut` 异步写入并 `trimCache()` 按插入顺序淘汰到 120 条上限；仍无后台同步/Web Push。

证据：[sw.js](file:///Volumes/vol1T/project/RexHub/server/web/public/sw.js#L1-L70)、[sw-register.ts](file:///Volumes/vol1T/project/RexHub/server/web/src/lib/pwa/sw-register.ts#L12-L47)、[manifest.json](file:///Volumes/vol1T/project/RexHub/server/web/public/manifest.json#L1-L15)。

### 3.6 PWA 测试与可观测性

- 只有 TypeScript strict + ESLint + 构建检查。
- 无单测/组件/E2E，无 `test` 脚本，无 CI 配置；lockfile 里的 Playwright 只是 Next 的 optional peer。
- 无 Sentry/Web Vitals/analytics/ErrorBoundary，SW 注册与缓存错误大量静默。

---

## 4. iOS 客户端

### 4.1 技术栈与配置

- SwiftUI + UIKit/AVKit/AVFoundation 混用；`@Observable` + `@MainActor` 管全局状态。
- 最低 **iOS 17.0**、Swift 6、iPhone + iPad、`com.poilly.RexHub`。
- 唯一显式 SPM 依赖 KSPlayer（锁定 revision），间接 FFmpegKit 6.1.4；音乐仍用 AVPlayer。
- ATS 仅显式允许本地网络；后台模式仅 `audio`。

证据：[project.pbxproj](file:///Volumes/vol1T/project/RexHub/ios/RexHub.xcodeproj/project.pbxproj#L265-L374)、[Info.plist](file:///Volumes/vol1T/project/RexHub/ios/Config/Info.plist#L23-L40)。

> 注意：根 README 写「最低 iOS 18」「模块化 RexCore/RexNetworking/...」，但当前实际工程是 iOS 17 单 target；模块化工程位于 `refs/ios-modular`，不是当前实现。README 还引用了 `docs/backend`、`docs/ios`，这两个目录当前不存在。

### 4.2 启动与导航

- `AppState` 四阶段：`launching → connecting → unauthenticated/authenticated`。
- 启动至少 0.7s 品牌页；恢复服务地址/Keychain token/用户快照；有本地会话则 `/api/auth/me` 真实校验；401/403 清会话；网络错误停留连接失败页；校验 8s 超时兜底。
- `NWPathMonitor` 网络恢复后自动重校验。
- iPhone `TabView` 四 Tab：首页、海报墙、资源库、115；iPad regular 用自定义侧栏，已访问模块保持挂载。

证据：[AppState.swift](file:///Volumes/vol1T/project/RexHub/ios/RexHub/App/AppState.swift#L5-L227)、[RootView.swift](file:///Volumes/vol1T/project/RexHub/ios/RexHub/App/RootView.swift#L7-L63)、[HomeView.swift](file:///Volumes/vol1T/project/RexHub/ios/RexHub/Features/Home/HomeView.swift#L24-L409)。

### 4.3 网络与安全

- `HTTPTransport` 两个共享 Session：`api`（15s 请求/3600s 资源/每 host 8 连接）与 `transfer`（30s/3600s/6 连接）。
- `APIClient` 为 `Sendable` 值类型，普通请求 10s、最多 2 次重试、指数退避 + jitter、读 `Retry-After`、每次请求 `X-Request-ID`、统一状态码映射、snake_case 解码、兼容 envelope 与裸模型。
- SSE 用 `URLSession.bytes` + `AsyncThrowingStream`；115 上传用 1 MiB 分块 multipart 临时文件，不整体读入内存。
- Token 存 Keychain（`AfterFirstUnlockThisDeviceOnly`），用户快照/过期时间存 UserDefaults；登录密码历史最多 10 条，每条独立 Keychain。

证据：[HTTPTransport.swift](file:///Volumes/vol1T/project/RexHub/ios/RexHub/Core/Networking/HTTPTransport.swift#L5-L56)、[APIClient.swift](file:///Volumes/vol1T/project/RexHub/ios/RexHub/Core/Networking/APIClient.swift#L1916-L2056)、[Keychain.swift](file:///Volumes/vol1T/project/RexHub/ios/RexHub/Core/Security/Keychain.swift#L83-L131)。

### 4.4 功能与播放器

- 首页服务器摘要/自定义宫格/115 存储卡；聚合搜索；MoviePilot + Makers 合并海报墙；短剧（源取自服务管理）；AI 助手；115 浏览/上传/预览；云下载/离线任务；板块；完整设置。
- 视频统一 KSPlayer 内核：`KSAVPlayer` 优先、MKV/AVI 走 FFmpeg、软解失败自动重开；`RexPlaybackEngine` 抽象播放/暂停/seek/倍速/音轨/字幕/PiP/截图。
- 续播：本地 <5s 或距结尾 <3s 清除；服务端进度只覆盖更旧记录；后台/退出/切集/结束保存并尝试同步。
- 临时预览（文档/图片/ZIP）下载到 tmp，页面消失即清理，不是持久化离线下载。

### 4.5 iOS 测试

3 个 XCTestCase、15 个方法，覆盖 APIClient 状态码/重试/envelope、AuthUser 解码、ServerConfig 解析；全部通过 `StubURLProtocol`，不访问真实网络。

未覆盖：AppState 状态机、Keychain/Session/Credential、SSE/NDJSON、multipart、取消语义、Emby、播放器生命周期、导航与业务交互。

---

## 5. 跨端视角

| 维度 | 后端 | PWA | iOS |
|---|---|---|---|
| 接口协议 | FastAPI，部分 `Envelope`、部分裸 JSON | 按域拆分客户端，混用两种解析 | 兼容 envelope 与裸模型 |
| 认证 | Cookie + Bearer + query token | Cookie（`credentials: include`） | Bearer |
| 数据缓存 | 进程内 TTL | React Query + 模块级 Map | 内存 NSCache + URLCache |
| 导航/状态 | — | 自建 URL/history 内核 | 各模块独立 NavigationStack |
| 测试 | 无 | 无 | 15 个单测 |
| 错误上报 | 无统一 | 无 | 无 |

**三份手写模型**（Pydantic / TS / Swift）没有代码生成或契约校验，后端改字段只能靠人工同步。

---

## 6. 架构缺陷与风险

### P0：会直接造成数据或安全问题的结构性问题

#### 1. 双 API 实例 vs 单进程设计

部署上确实有两个 API 容器，但以下机制仍按单进程假设实现：

| 机制 | 单进程假设 | 位置 |
|---|---|---|
| 插件 autostart / watchdog / PID 文件 | 两个实例都启动全部插件；`stop_all()` 会遍历所有 PID 文件并停止非本实例进程 | ✅ 插件框架已删除，机制随之消失 |
| 动态端口分配 | 先临时 bind 取端口再关闭，存在竞争窗口 | ✅ 随插件框架删除，已无动态端口 |
| JSON 状态（服务/115/进度/外观/网络） | 进程内无锁、写临时文件后 `replace`，多实例读改写仍可能互相覆盖 | [services_store.py](file:///Volumes/vol1T/project/RexHub/server/api/app/rexhub/services_store.py#L48-L67) |
| 设置缓存/限流 | 进程内 TTL 与滑动窗口，多副本可绕过 | [rate_limit.py](file:///Volumes/vol1T/project/RexHub/server/api/app/core/rate_limit.py#L1-L43) |
| 备份/恢复 | `_OP_LOCK` 曾是纯进程内；导出多表各自连接，无统一快照；恢复 `TRUNCATE CASCADE` | 🟡 已补 `fcntl` 跨进程文件锁；多表快照与恢复方式未改 |
| FlareSolverr | 每个实例只认自己的 session，monitor 会把对方的 session 当 orphan | [monitor.py](file:///Volumes/vol1T/project/RexHub/server/api/app/core/outbound_http/monitor.py#L18-L109) |

**判断**：插件生命周期带来的双实例冲突已随插件删除消失，但双 API 实例的结构问题仍在。要么明确「只有一个 API 实例负责写状态/后台任务」，要么把限流、缓存失效、任务状态、锁外移到 Redis/PG，并给 JSON 状态加跨进程文件锁或迁库。仅靠 `APP_ROLE` 选择 Supervisor 配置不够，因为 Python 启动逻辑没有角色分支。

#### 2. 插件宿主没有统一鉴权（✅ 已消除）

插件框架（`shared_host.mjs` / `widget_runtime/host.mjs` / `plugin_api.py`）已整体删除，不再有宿主进程监听 `0.0.0.0`、不再有插件端口直连 URL，本条不再适用。

#### 3. 原始会话 token 进入 URL

短剧播放解析仍把 token 放进 `/stream` URL；认证层也显式允许 query token 覆盖 Cookie/Bearer。

证据：[shortdrama.py](file:///Volumes/vol1T/project/RexHub/server/api/app/rexhub/routers/shortdrama.py#L773-L859)、[auth_guard.py](file:///Volumes/vol1T/project/RexHub/server/api/app/rexhub/auth_guard.py#L14-L26)。

风险：token 可能进入 Uvicorn/反代访问日志、浏览器历史、剪贴板分享链接与第三方 Referer。

### P1：功能正确性与权限边界

#### 4. iOS Emby 已保存 token 未用于业务请求（✅ 已修复）

`EmbyClient.send` 的请求头已改为 `authorizationHeader(token: token ?? self.token)`，未显式传 token 时会回落到已保存的登录 token。

证据：[EmbyClient.swift](file:///Volumes/vol1T/project/RexHub/ios/RexHub/Features/Library/EmbyClient.swift#L82-L134)、[EmbyClient.swift](file:///Volumes/vol1T/project/RexHub/ios/RexHub/Features/Library/EmbyClient.swift#L171-L195)。

#### 5. iOS AI 设置的客户端管理员门禁写死为 true（✅ 已修复）

`HomeView` 已改为 `AISettingsView(isAdmin: session.user.isAdmin)`，与相邻的服务、网络设置一致。

证据：[HomeView.swift](file:///Volumes/vol1T/project/RexHub/ios/RexHub/Features/Home/HomeView.swift#L72-L88)、[AISettingsView.swift](file:///Volumes/vol1T/project/RexHub/ios/RexHub/Features/Settings/AISettingsView.swift#L858-L902)。

#### 6. PWA 账号切换没有缓存隔离

登录/登出/401 只改用户状态，不清 React Query、短剧 Map、115 快照；「最近浏览」等 query key 不含用户；115 快照是模块级单例。

证据：[providers.tsx](file:///Volumes/vol1T/project/RexHub/server/web/src/app/providers.tsx#L21-L30)、[AuthProvider.tsx](file:///Volumes/vol1T/project/RexHub/server/web/src/providers/AuthProvider.tsx#L64-L99)、[p115PanelCache.ts](file:///Volumes/vol1T/project/RexHub/server/web/src/features/settings/p115PanelCache.ts#L12-L46)。

风险：同一浏览器切换账号后可能看到上一账号的列表、浏览记录、115 配额/任务。

#### 7. PWA 注销失败处理不一致

`authLogout()` 不检查 `res.ok`；AuthProvider 必须等请求成功才清本地状态；设置页 `void onLogout()` 无 catch。网络失败会停在已登录 UI 并产生未处理 rejection；服务端报错时又可能本地退出而 Cookie 未清。

证据：[auth.ts](file:///Volumes/vol1T/project/RexHub/server/web/src/lib/api/auth.ts#L39-L41)、[AuthProvider.tsx](file:///Volumes/vol1T/project/RexHub/server/web/src/providers/AuthProvider.tsx#L95-L99)。

#### 8. iOS 短剧刷新会把相同结果全部过滤掉（✅ 已修复）

`load(reset:)` 已拆成两条路径：reset 时用本次结果自建去重集合后**直接覆盖** `cards`；非 reset 才基于旧 `cards` 追加去重。

证据：[DramaSiteView.swift](file:///Volumes/vol1T/project/RexHub/ios/RexHub/Features/Drama/DramaSiteView.swift#L112-L141)。

#### 9. 115 解压密码进入日志、任务消息与持久化状态

候选密码被拼进任务 message；状态快照 `config` 直接返回明文密码；持久化 JSON 里的任务 message 同样可能含密码；延迟改名还会把密码标记追加到文件名。

证据：[extract_worker.py](file:///Volumes/vol1T/project/RexHub/server/api/app/p115/extract_worker.py#L158-L166)、[extract_worker.py](file:///Volumes/vol1T/project/RexHub/server/api/app/p115/extract_worker.py#L1037-L1082)、[extract_store.py](file:///Volumes/vol1T/project/RexHub/server/api/app/p115/extract_store.py#L126-L200)。

边界：这些接口是管理员限定，暴露面主要是管理员、日志/文件访问者与网盘目录查看者。

#### 10. 普通登录用户可读取完整插件 runtime（✅ 已消除）

插件 API 与 manifest/runtime 结构已随插件框架删除，本条不再适用。

#### 11. 拉页链路存在 TLS 校验降级成功路径（✅ 已修复）

尝试顺序已改为「先校验后降级」：`proxy+verify` → `proxy+noverify` → `direct+verify` → `direct+noverify`，并在降级成功时打 `tls-verify-off` 警告。

证据：[client.py](file:///Volumes/vol1T/project/RexHub/server/api/app/core/outbound_http/client.py#L377-L415)。

#### 12. 插件安装无强制完整性校验（✅ 已消除）

插件安装器已随插件框架删除，仓库不再接受第三方包执行。

### P2：一致性、性能与可维护性

#### 13. PWA 导航内核分裂

- 首页板块用 `{ boardsLayer: true }` / `{ boardsEntry: true }` 直接替换 history state，绕过 `__navDepth` 与 `NAV_EVENT`。
- 首页 `popstate` 只恢复 boards 和 detail，不恢复 keyword/排序/匹配/时间/大小/地区/scope。
- `searchSource` 参与请求与 query key，但不进 URL，刷新/分享会丢。
- 设置子页是纯 `useState<Panel>`，不能深链、刷新回 Hub、系统返回不逐层回退。

证据：[useHomeScreen.ts](file:///Volumes/vol1T/project/RexHub/server/web/src/features/home/useHomeScreen.ts#L205-L309)、[BoardsScreen.tsx](file:///Volumes/vol1T/project/RexHub/server/web/src/features/boards/BoardsScreen.tsx#L104-L129)、[SettingsScreen.tsx](file:///Volumes/vol1T/project/RexHub/server/web/src/features/settings/SettingsScreen.tsx#L210-L330)。

#### 14. PWA 离线能力名不副实（✅ 已修复）

install 阶段已预缓存 `/`、manifest 与图标；`cachePut` 改为异步并 `trimCache()` 淘汰到 120 条上限；缓存版本升到 `app-v5`。仍保留的缺口：导航返回 500 时不会 fallback、`skipWaiting` 无更新提示、无后台同步/Web Push。

证据：[sw.js](file:///Volumes/vol1T/project/RexHub/server/web/public/sw.js#L1-L70)、[sw-register.ts](file:///Volumes/vol1T/project/RexHub/server/web/src/lib/pwa/sw-register.ts#L12-L47)。

#### 15. PWA 五套大型页面常驻

`page.tsx` 静态导入五个 Screen，TabPane 只控制可见性不卸载。首屏 JS、hydration、常驻 DOM 与内存成本需要实测；好处是状态保留。

证据：[page.tsx](file:///Volumes/vol1T/project/RexHub/server/web/src/app/page.tsx#L3-L42)、[TabPane.tsx](file:///Volumes/vol1T/project/RexHub/server/web/src/shell/TabPane.tsx#L34-L59)。

#### 16. 短剧模块级缓存无容量上限

两个 Map 按站点/榜单/任意搜索词持续写入，只在读到同一 key 时删除过期项；无 LRU、无条目上限、无登出清理。

证据：[useDramaScreen.ts](file:///Volumes/vol1T/project/RexHub/server/web/src/features/drama/useDramaScreen.ts#L192-L219)。

#### 17. iOS 关闭「记住密码」不会清历史密码（✅ 已修复）

`forget()` 现在逐条删除 `history` 中每个记录的 Keychain 密码，再清当前 account 与全局密码；历史里的服务端/账号仍保留用于下次回填用户名。

证据：[CredentialStore.swift](file:///Volumes/vol1T/project/RexHub/ios/RexHub/Core/Security/CredentialStore.swift#L50-L87)。

#### 18. iOS 取消语义与共享 Session 不一致

`cancelAllInflight()` 取消共享 `HTTPTransport.api` 上的全部任务，而非「本 client 创建的请求」。退出场景通常符合预期，但并行 client / SSE / 上传时可能误伤。

证据：[APIClient.swift](file:///Volumes/vol1T/project/RexHub/ios/RexHub/Core/Networking/APIClient.swift#L180-L187)、[HTTPTransport.swift](file:///Volumes/vol1T/project/RexHub/ios/RexHub/Core/Networking/HTTPTransport.swift#L5-L13)。

#### 19. iOS AI 配置保存非原子（🟡 已缓解）

两次 PUT 仍非事务，但已用 `AgentSaveError.partial` 区分失败步骤：第二步失败时明确提示「联网搜索配置已保存，但助手配置保存失败」，不再笼统报整体失败。

证据：[AISettingsView.swift](file:///Volumes/vol1T/project/RexHub/ios/RexHub/Features/Settings/AISettingsView.swift#L858-L924)。

#### 20. 核心文件职责过宽

- `APIClient` 同时承担认证、AI SSE、片源 NDJSON、MoviePilot、115、上传、重试、解码与依赖注入。
- `RexPlayerChrome` 同时处理工具栏、设置、手势、系统音量/亮度、截图与播放控制。
- 后端 `p115`、`search`、`makers` 同样存在超大模块。

配合低测试覆盖，后续修改容易跨模块回归。

### 待运行时验证的风险

| 风险 | 说明 |
|---|---|
| JSON 状态丢更新 | 取决于两实例写入频率与共享卷语义 |
| 备份表间不一致 | 在线写入期间导出可能出现跨表时间点不一致（跨进程锁只保证同类操作串行） |
| FlareSolverr session 互回收 | 取决于两实例是否共用同一 FlareSolverr |
| 流代理 DNS rebinding | 已逐跳校验 DNS，但 httpx 会再次解析，未固定到已校验 IP |
| 解压/备份/图标资源压力 | 解压无总量/文件数配额；备份无累计解压上限；图标资源整体读入内存 |
| `to_thread` 取消 | 异步任务已取消，但线程池中的阻塞 IO 不一定立即停止 |
| iOS 后台音频与锁屏 | 未发现 `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`；音频会话无显式释放 |
| iOS 播放进度乱序 | 每次保存独立 Task 回写，无序列号，旧进度可能后到覆盖新进度 |
| iOS 清 tmp 与上传/预览冲突 | 缓存管理可删 tmp 全部内容，上传与 QuickLook 也使用 tmp |
| iOS 大量预览图并发 | `withTaskGroup` 为全部 URL 一次性建子任务，无并发上限 |
| 非局域网 HTTP + ATS | 公网 IP/域名 HTTP 是否被 ATS 阻断需按部署验证 |

---

## 7. 建议的处理顺序

**第一步：把部署模型说清楚（不改代码也要先定）**

1. 明确 API 实例角色：`ui` 只读/转发，`worker` 独占后台任务与写状态；或收敛为单 API 实例。
2. 在 Python 侧真正按 `APP_ROLE` 分支，禁止非 owner 实例执行备份恢复等写操作。
3. 若必须多副本：把限流、缓存失效、任务状态、锁迁到 Redis/PG，并给 JSON 状态加跨进程文件锁或迁库。

**第二步：收口安全边界**

1. ✅ 插件宿主已随插件框架删除，不再有独立宿主监听。
2. 播放/图片不再把原始会话 token 放 URL，改为短期签名或服务端代理。
3. ✅ 插件详情 runtime 与安装校验问题已随插件删除消失。
4. ✅ 拉页链路已改为「先校验后降级」。
5. 115 解压密码脱敏，不再进日志/消息/状态。

**第三步：修确定的功能 Bug（4 项已修，剩 PWA 缓存隔离）**

1. ✅ iOS Emby token 传递。
2. ✅ iOS AI 设置 `isAdmin` 使用真实用户。
3. ✅ iOS 短剧刷新去重顺序。
4. iOS 记住密码关闭时清理历史凭据（✅ 已完成）。
5. 待办：PWA 账号切换清缓存 + 登出失败处理（本轮新增了 `offline` 态，但缓存隔离未做）。

**第四步：补最小可用的质量网**

1. 后端：认证/权限、115 写操作、备份恢复的关键路径测试。
2. PWA：认证恢复、账号切换、导航深链/返回、SW 缓存的测试。
3. iOS：AppState 状态机、Keychain、SSE、Emby、播放器续播测试。
4. 统一 `/health` 深检查 + 最小错误上报（PWA/iOS 至少上报未捕获异常与 SW 状态）。

**第五步：降低跨端重复成本**

1. 用 OpenAPI 生成 TS/Swift 模型，或至少加契约测试。
2. 统一响应 envelope 规则，消除「一部分包一层、一部分裸 JSON」。
3. 把 PWA 的首页、板块、设置收敛到同一套 URL/历史内核。

---

## 8. 附：本次梳理发现的「文档与实现漂移」

| 位置 | 描述 | 实际 |
|---|---|---|
| 根 README | 「最低 iOS 18」「模块化 RexCore/RexNetworking/RexData/RexUI/RexPlayer/RexFeatures」 | 当前 iOS 17 单 target；模块化版本在 `refs/ios-modular` |
| 根 README | 引用 `docs/backend`、`docs/ios` | 这两个目录当前为空 |
| `bootstrap.py` docstring | 称「Postgres meta」 | 实际是 SQLite |
| `outbound_http/slots.py` 注释 | 描述旧的 20–90 秒预算 | 实现已 clamp 到 12–30 秒 |
| 本文档 §2.6 / §6 旧版 | 描述插件框架、插件宿主与安装校验 | 插件已整体删除，相关缺陷已标注消除；§2.6 改为「服务管理与出站」 |
| 本文档 §1 目录表旧版 | `plugins`、`services` 为「示例插件与中继」 | 插件已删除，服务管理只保留 NAS 服务卡片 |

建议把 README 的 iOS 章节改成「当前实现」与「模块化迁移目标」两段，避免后续按错误基线做判断。
