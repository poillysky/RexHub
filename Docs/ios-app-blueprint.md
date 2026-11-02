# RexHub iOS App 架构设计原则

> 配套文档：[产品需求基线](./product-requirements.md) ｜ [UI 视觉效果与质感规范](./ui-design-guidelines.md)
> 适用基线：iOS 17+ / SwiftUI / iPhone + iPad / 当前单 App Target
> 更新日期：2026-11-01

---

## 0. 一句话原则

先让 **会话、网络、启动** 三条主链路正确、可恢复、可测试，再谈页面数量。
架构的价值不在分层图好看，而在改一个地方不会牵动全身。

---

## 1. 分层与依赖规则

### 1.1 四层结构

```text
┌──────────────────────────────────────────────┐
│ App        入口 / 组合根 / 路由 / AppState      │
├──────────────────────────────────────────────┤
│ Features   Auth Home Library Player Settings  │
├──────────────────────────────────────────────┤
│ Core       Design Networking Security Storage │
│            Media Observability                │
├──────────────────────────────────────────────┤
│ Platform   URLSession Keychain AVPlayer       │
│            SwiftData NWBrowser                │
└──────────────────────────────────────────────┘
```

四条硬规则：

1. **依赖只能向下**：App → Features → Core → Platform。
2. **Feature 之间不直接 import**：跨模块协作走 Core 协议或 App 层注入。
3. **Core 不反向依赖 Feature**：Core 不知道"首页"存在。
4. **平台实现只在最底层**：`URLSession`、`SecItem`、`AVPlayer` 不出现在 View 里。

### 1.2 目标目录

```text
RexHub/
├── App/
│   ├── RexHubApp.swift        # @main，只组装
│   ├── AppState.swift         # 全局阶段与会话单一真相
│   ├── Router.swift           # 路由枚举与深链分发
│   └── Dependencies.swift     # 组合根，注入 API/缓存/播放服务
├── Features/
│   ├── Auth/                  # 启动、登录、115 授权
│   ├── Home/                  # 影视 Tab：可配置栏目海报墙（当前 HomeView 含 4 Tab 骨架）
│   ├── Detail/                # 影视作品详情、资源详情、资源多选转存
│   ├── Search/                # 全局资源搜索、多来源状态、搜索历史
│   ├── ShortDrama/            # 短剧 Tab：插件来源列表、详情、剧集
│   ├── Library/               # 网盘 Tab：文件浏览、账号与转存记录
│   ├── Player/                # 播放器与控制层、播放会话、字幕面板
│   └── Settings/              # 「更多」Tab：账号、服务端、缓存、关于
├── Core/
│   ├── Design/                # RexTheme / RexBrand / 组件
│   ├── Networking/            # Endpoint / APIClient / 错误模型
│   ├── Security/              # Keychain / 凭证生命周期 / 私密模式
│   ├── Storage/               # 缓存、播放进度、设置
│   ├── Media/                 # 播放器封装（PlayerFacade）、字幕、音轨
│   ├── Observability/         # Logger / signpost / MetricKit
│   └── Extensions/
├── Resources/                 # Assets / String Catalog / PrivacyInfo
└── Supporting/                # Info.plist / 配置文件
```

### 1.3 组合根与依赖注入

- 只在 `RexHubApp` 创建一次依赖：`APIClient`、`SessionStore`、`LibraryCache`、`PlayerService`。
- 通过 `.environment(...)` 或初始化参数向下传，**禁止**在 View 里 `APIClient(baseURL:)` 现造。
- 依赖面向协议：`AuthServicing`、`LibraryServicing`、`PlaybackServicing`，便于 Preview 与测试注入假实现。

### 1.4 什么时候拆 SPM

| 条件 | 动作 |
| --- | --- |
| 单人、页面 < 10、构建 < 30s | 保持单 Target + 目录分层 |
| 多人协作或构建 > 60s | 按 Feature 拆本地 Swift Package |
| 需要复用到 Widget / App Clip | 先拆 `RexCore` |

不要为了"架构感"提前拆包，拆包会显著增加改代码摩擦。

### 1.5 设置中心组件规范

「更多」及其二级页共用一个组件族，放在 `Core/Design`（或 `Features/Settings/Components`），**新增设置项只组合组件，不重新设计 UI**。

| 组件 | 职责 | 现有实现 |
| --- | --- | --- |
| `MoreHomePage` | 「更多」首页：服务状态卡、常用功能快捷入口、各分类分组 | `MoreView`（需按 9 组 IA 调整） |
| `SettingsCategoryPage` | 二级设置页容器：统一背景、滚动、导航栏 | `SettingsPage` |
| `SettingsGroup` | 分组容器：分组标题 + 白色圆角面板 + 行分隔 | `SettingsSection` / `SettingsCard` |
| `SettingsRow` | 标准设置行：图标、标题、说明、尾部内容 | `SettingsRow` |
| `SettingsSwitchRow` | 开关行，绑定即时生效，无「保存」按钮 | 待从 `SettingsRow` 抽取 |
| `SettingsValueRow` | 带状态或数值的行（如缓存大小、当前账号） | `SettingsRow(value:)` |
| `SettingsNavigationRow` | 跳转行，右侧箭头 + push 二级页 | `SettingsLink` |
| `SettingsDestructiveRow` | 危险操作行，红色文案 + 二次确认 | 待抽取 |
| `QuickActionGrid` | 常用功能快捷入口组（横向图标 + 文字，非设置项） | 待抽取 |

约束：

- 分组、行、间距、圆角、字号全部走设计令牌，不在页面里写魔法数字。
- 页面只声明数据（行列表、绑定值、跳转目标），不各自实现行的外观。
- 危险操作必须独立分组，并走系统 `alert` 二次确认。
- 具体视觉数值与信息架构见 [产品需求基线](./product-requirements.md) 第十一章与 [UI 视觉效果与质感规范](./ui-design-guidelines.md) 6.7。

---

## 2. 现状与差距

| 领域 | 现状（代码事实） | 风险与下一步 |
| --- | --- | --- |
| 会话恢复 | [AppState.swift](../RexHub/App/AppState.swift) 启动读 Keychain token → `/api/auth/me` 校验；401/403 清会话，网络失败保留 token 进首页离线态 | 已闭环 |
| 启动耗时 | [SplashView.swift](../RexHub/App/SplashView.swift) 只负责动画；闪屏由 `bootstrap()` 驱动，最短 300ms、校验最多 1.5s | 已闭环 |
| 网络层 | [APIClient.swift](../RexHub/Core/Networking/APIClient.swift) 统一注入 Bearer 与 `X-Request-ID`，普通请求 10s、播放解析 30s，幂等 GET 重试 2 次（指数退避 + 抖动 + Retry-After）；页面经 `\.apiClient` 环境值取用，不自行构造客户端 | 已闭环 |
| 状态管理 | `AppState`（`@Observable`）是阶段唯一真相，View 经 `.environment` 读取 | 已闭环 |
| 错误模型 | 离线 / 不可达 / 超时 / 取消 / 400（带服务端 detail）/ 401 / 403 / 404 / 409 / 429 / 5xx / 解码共 12 类，各有中文文案；目标补转存失败 / 会话过期 / 单来源失败 3 类 | 已闭环（业务错误类待补） |
| 115 接入 | Cookie / 扫码绑定（`pan115.py`）+ `GET /api/pan/list` 列目录 + `GET /api/pan/play` 解析直链；视频流量由客户端直连 115 CDN，不中转 | 已闭环 |
| 页面范围 | 底部 4 Tab：影视（固定顶栏 / 首页栏目空态 / 服务端卡；目标改为可配置栏目海报墙）、短剧（占位）、网盘（115 目录逐级浏览 + 直链播放）、更多（当前为账号卡 + 六组设置，目标为 9 组分组设置中心：服务状态 / 常用功能 / 播放与字幕 / 外观与首页 / 资源与数据 / 网盘与服务 / 插件管理 / 隐私与安全 / 应用与支持，见 1.5 与需求文档第十一章）；作品详情、资源详情、全局搜索均未实现 | Phase 1 |
| 资源搜索 | 后端无多来源调度、统一资源模型、去重与准确性过滤；iOS 无搜索页与多来源状态 | Phase 1 核心缺口 |
| 影视详情 | 无作品详情页、季/集列表、整季与单集资源入口 | Phase 1 |
| 115 转存 | 仅直链播放，无「网盘在线」转存链路、播放会话与任务状态 | Phase 1 |
| 字幕 | 无字幕子系统（来源、搜索、匹配、下载、NAS 字幕库、播放器加载） | Phase 2 |
| 短剧 | 仅有占位页，无插件来源、列表、详情、剧集 | Phase 3 |
| 私密模式 | 无 Face ID / 独立密码、无常规与私密数据隔离 | Phase 3 |
| 持久化 | token 与记住的密码进 Keychain，用户快照 / 到期时间 / 服务端地址进 UserDefaults；无业务与图片缓存 | P1 缓存缺失 |
| 隐私合规 | [PrivacyInfo.xcprivacy](../RexHub/PrivacyInfo.xcprivacy) 已声明 UserDefaults 访问（CA92.1），不做跟踪、不收集数据；ATS 本地网络已声明 | 已闭环 |
| 测试 | 无 Test Target | P1 重构无安全网 |
| 工程化 | 单 Target、无 lint、无 CI | P2 |

> 结论：会话、启动、网络三条主链路已按第 3–5 节落地。下一步按产品 Phase 1 推进：资源搜索 → 作品详情 → 资源详情 → 115 转存与播放闭环，同时补首屏缓存。

---

## 3. 会话与连接

### 3.1 关注点分离

**服务端地址**与**身份认证**是两个模型，不能混在一个状态里：

```swift
struct ServerConfig: Codable, Hashable {
    var host: String          // 例如 192.168.1.10:8080
    var useHTTPS: Bool
}

struct AuthSession: Codable {
    let token: String
    let expiresIn: Int
    let user: User
}
```

- `ServerConfig` 存 UserDefaults，可保留最近 5 个历史地址供一键回填。
- `AuthSession` 的 token 只进 Keychain，内存中由 `AppState` 持有。
- 修改地址即视为"换服务端"：清除 token、取消进行中的请求、回到未登录。

### 3.2 启动序列（目标）

```text
launch
  → 并行：读 Keychain token / 读 ServerConfig / 初始化缓存
  → 有 token：1.5s 超时内校验 /api/auth/me
        ├─ 200        → authenticated，进首页
        ├─ 401/403    → 清除 token，回登录
        └─ 超时/不可达 → 保留 token，进首页离线态，后台重试
  → 无 token：进入登录页
```

- 闪屏由真实准备完成驱动，**最短 300ms、最长 1.2s**，不用固定 sleep。
- 不允许"登录页闪一下又跳首页"。
- 校验失败要区分"网络问题"与"凭证失效"，前者不清 token。

### 3.3 登录与退出

- 登录成功：存 token → 更新 `AppState.phase` → 触发首页缓存刷新。
- 记住密码：账号存 UserDefaults，密码存 Keychain 独立 key；取消勾选即删除。
- 退出登录：删 Keychain、清内存会话、取消所有在途请求、清敏感缓存、回登录页。
- 忘记密码：服务端未提供接口前，引导文案指向管理台，不做假按钮。

### 3.4 局域网发现（后置）

- 已声明 `NSLocalNetworkUsageDescription` 与 `NSAllowsLocalNetworking`（见 [Info.plist](../Config/Info.plist)）。
- 启用 Bonjour 时用 `NWBrowser` 监听 `_rexhub._tcp`，3s 超时回退手动输入。
- 权限被拒绝时明确提示"设置 → 隐私与安全性 → 本地网络"，不假装在扫描。
- 首版优先手动输入地址，发现能力作为增强项，不阻塞主链路。

---

## 4. 状态与数据流

### 4.1 属性包装器选择

| 场景 | 用法 | 说明 |
| --- | --- | --- |
| 视图私有 UI 状态 | `@State` | 是否展开、输入内容 |
| 父 → 子双向 | `@Binding` | 表单字段 |
| 全局共享模型 | `@Environment(AppState.self)` | 会话、主题、网络状态 |
| 长生命周期引用模型 | `@State` 持有 `@Observable` 对象 | 由视图拥有生命周期 |
| 只读环境值 | `@Environment(\.colorScheme)` | 系统注入 |

iOS 17+ 统一用 `@Observable`，不再新增 `ObservableObject/@Published`。

### 4.2 AppState 是唯一阶段真相

```swift
@Observable
final class AppState {
    enum Phase {
        case launching
        case unauthenticated
        case authenticated(AuthSession)
    }
    private(set) var phase: Phase = .launching
    // bootstrap() / signIn() / signOut()
}
```

- `RootView` 只做 `switch appState.phase`，不写业务判断。
- 登录、恢复会话、退出都只改 `AppState`，页面通过环境读取。
- **不要**用多个布尔值（`isLoggedIn` + `hasSession` + `isLoading`）表达同一件事。

### 4.3 单向数据流

```text
View --用户意图--> Store/Service --异步--> 新状态 --> View 重绘
```

- View 不直接改全局状态，只调用 Store 的意图方法。
- Store 内部串行化状态变更，网络结果回主线程再写状态。
- 失败也要落到状态（`error` / `isEmpty` / `isOffline`），不能只弹一次 Toast。

### 4.4 并发约定

| 规则 | 做法 |
| --- | --- |
| UI 状态 | `@MainActor` |
| 网络/DTO | `Sendable`，值类型优先 |
| 磁盘/解码 | `actor` 或后台任务，不阻塞主线程 |
| 任务生命周期 | `.task` / `.task(id:)`，视图消失自动取消 |
| 禁止 | `Task.detached` 随意逃逸、`catch {}` 吞错、主线程解析大 JSON |

面向 Swift 6 严格并发逐步收敛：先给共享模型加 `Sendable`，再消除数据竞争警告。

### 4.5 搜索会话状态

资源搜索是"多来源并发 + 逐步返回"，状态必须按来源建模，不能用一个 `isLoading`：

```swift
struct SearchSession {
    let id: String
    var keyword: String
    var context: SearchContext      // global / mediaDetail(mediaID, season, episode)
    var providers: [ProviderState]  // waiting / searching / finished / failed / cancelled
    var results: [Resource]         // 按 resource_id 合并后的结果
    var fromCache: Bool
    var cachedAt: Date?
}
```

- 先渲染缓存（标注缓存时间）→ 再按来源增量合并 → 单来源失败只标记该来源。
- 取消全部 / 取消单来源 / 重试失败来源 / 刷新单来源是四个独立意图，取消不清空已返回结果。
- 取消与失败必须是不同状态，UI 文案不同。
- 搜索上下文（全局 / 作品详情 / 季 / 集）与私密标记参与缓存键，禁止跨上下文复用。
- 合并去重以 `resource_id` 为稳定标识，保留全部来源信息；无法确认重复时不合并。

---

## 5. 网络层

### 5.1 Endpoint 抽象

```swift
protocol Endpoint {
    var path: String { get }
    var method: HTTPMethod { get }
    var query: [URLQueryItem] { get }
    var headers: [String: String] { get }
    var body: Data? { get }
    var timeout: TimeInterval { get }
}
```

- 每个接口一个 `Endpoint` 值类型，或 `APIClient` 的具名方法。
- DTO 与领域模型分离；DTO 只负责解码，不直接进 View。
- 统一 `JSONDecoder`：`snake_case`、ISO8601 日期、可选字段容错。

### 5.2 APIClient 职责

| 职责 | 要求 |
| --- | --- |
| 鉴权 | 自动注入 `Authorization: Bearer <token>`，登录接口除外 |
| 请求标识 | 注入 `X-Request-ID`，便于服务端排查 |
| 超时 | 普通 10s；上传/解析直链 30s |
| 错误归一 | 传输、离线、超时、取消、401/403/404/409/429/5xx、解码失败分类 |
| 重试 | 仅幂等请求 + 5xx/429/网络抖动；指数退避 + 抖动，最多 2 次；尊重 `Retry-After` |
| 401 | 只刷新或登出一次，禁止无限循环 |
| 取消 | 向上传播 `CancellationError`，视图消失即取消 |
| 日志 | 只记录方法、路径、状态码、耗时；**不记录** token、密码、完整响应体 |

### 5.3 错误模型

```swift
enum APIError: LocalizedError {
    case offline            // 无网络，提示检查 Wi-Fi/蜂窝
    case unreachable        // 地址不可达，提示检查服务端
    case timeout            // 超时，提示重试
    case cancelled          // 不提示
    case unauthorized       // 401，回登录
    case forbidden          // 403，提示权限
    case notFound           // 404，内容已不存在
    case conflict(String)   // 409，服务端未初始化等
    case rateLimited        // 429，稍后重试
    case server(Int)        // 5xx，可重试
    case decoding           // 协议不匹配，上报日志
    case transferFailed(String) // 115 转存失败（空间 / 已存在 / 风控），按条展示原因
    case sessionExpired     // 播放会话过期，需重新解析，不自动循环轮询
    case sourceFailed(String)   // 单来源搜索失败，只标记该来源，不影响其他结果
}
```

原则：**每个错误都要能回答"用户下一步做什么"**，不能只有一句"操作失败"。

### 5.4 离线与弱网

- `NWPathMonitor` 驱动全局在线状态，顶部显示离线条，恢复后自动重试一次。
- 列表 cache-first：先渲染缓存 → 后台刷新 → 差异更新。
- 同一资源并发请求去重（in-flight coalescing）。
- 弱网降低图片规格，不自动播放视频。
- 局域网允许 HTTP；公网必须 HTTPS，不开 `NSAllowsArbitraryLoads`。

---

## 6. 持久化

| 数据 | 位置 | 加密/保护 | 生命周期 |
| --- | --- | --- | --- |
| 会话 token | Keychain | `kSecAttrAccessibleAfterFirstUnlock` | 退出登录删除 |
| 记住的密码 | Keychain | 同上，独立 key | 取消勾选删除 |
| 服务端地址 / HTTPS 开关 / 历史地址 | UserDefaults | 非敏感；写入前校验 | 长期 |
| 播放进度 | SwiftData 或轻量文件 | 非敏感 | 跟随媒体 |
| 媒体库缓存 | SwiftData / GRDB | 非敏感 | 可清理 |
| 图片缓存 | `NSCache` + 磁盘 LRU | 非敏感 | 自动淘汰 |
| 日志 | 本地滚动文件（可选） | 脱敏 | 7 天 |

规则：

1. **凭证只进 Keychain**，绝不写 UserDefaults、明文文件、日志。
2. 缓存必须可清空，「更多」页提供"清除缓存"并显示占用大小。
3. 缓存结构变更有版本号与迁移，禁止静默丢弃导致空白页。
4. 写盘在后台队列，主线程只读内存缓存。

---

## 7. 安全与隐私

### 7.1 凭证生命周期

- 登录成功 → 存 token 与过期时间 → 启动校验 → 过期静默刷新或回登录。
- token 载荷含 `iat` / `exp` / `scope` / `ver`：`scope` 区分 App（api）与管理台（admin），`ver` 为账号令牌版本；改密时服务端轮换版本，所有旧 token 立即失效，App 收到 401 后回登录。
- 登录接口按「来源 + 账号」做失败计数，达到阈值返回 429 并短暂锁定。
- token 只出现在请求头与 Keychain，**不打印、不埋点、不拼 URL**。
- 退出登录的清理动作见 3.3。

### 7.2 隐私清单

提交前加入 `PrivacyInfo.xcprivacy`：

- `NSPrivacyTracking = false`
- 声明 `UserDefaults` 等 Required Reason API 的用途（如 `CA92.1`）
- 声明收集的数据类型（如账号标识）与用途
- 第三方 SDK 必须自带隐私清单与签名

### 7.3 权限与日志

- 每个权限都要说明"为什么"：本地网络=连接自建服务端；相册=备份照片；通知=播放完成/备份结果。
- 使用 `os.Logger` 按 `subsystem/category` 分类，敏感字段标 `privacy: .private`。
- 埋点只记录功能使用与失败原因，不上传文件路径、账号、token。
- 崩溃与性能采集优先 `MetricKit`，减少第三方 SDK。

### 7.4 私密模式与数据隔离

- 入口隐藏、不出现「私密」字样；Face ID 优先，失败或不可用时用独立数字密码。
- App 进入后台或锁屏后自动退出私密模式，退出后相关内容立即不可见。
- **Face ID 只是本地入口，不能代替后端授权**：每个请求都携带常规 / 私密作用域，服务端校验后才返回数据。
- 客户端必须隔离：首页栏目配置、收藏、播放历史、播放进度、搜索历史、字幕库、缓存。
- 缓存键、图片缓存、字幕临时文件都要带作用域，私密数据不得进入常规缓存。
- 切换作用域时取消在途请求、清内存中的私密数据，再重载列表。

---

## 8. 播放子系统

| 主题 | 规范 |
| --- | --- |
| 播放器 | 通过 `PlayerFacade` 隔离内核；KSPlayer 作为候选待验证，业务层不依赖内核内部实现 |
| 播放模式 | 网盘在线（转存 → 解析 → 播放）、在线播放（来源直链）、磁力（后端能解析才播，否则引导转存 115） |
| 播放会话 | 后端建 `PlaybackSession` 关联用户 / 资源 / 115 账号 / 转存任务 / 解析任务 / 进度；iOS 按后端建议间隔轮询，地址就绪即停 |
| 转存解耦 | 退出播放器不取消转存；任务由 NAS 独立执行并持久化，重复请求去重 |
| 通知 | 不做 APNs；前台站内提示、后台尽力本地通知、冷启动同步后端结果；仅播放地址就绪才提示可播 |
| 格式 | HTTP/HTTPS 直链与 115 直链优先；MKV/HEVC 等依赖内核能力，NAS 不做常规转码或视频中转 |
| 缓冲 | 短视频最小 0.5s / 最大 2s；长视频最小 3s / 最大 10s，按网络调整 |
| 跳转 | `seek(to:toleranceBefore:toleranceAfter:)`，跳转前检查 `loadedTimeRanges` |
| 后台 | `AVAudioSession .playback`，支持锁屏控制与中断恢复 |
| 画中画 | 系统 `AVPictureInPictureController` / `VideoPlayer` |
| 投屏 | 第一阶段不实现 AirPlay，仅预留架构位置；不做自定义协议 |
| 字幕 | 见 8.2；支持内嵌、本地、在线插件与 HTTP URL，SRT / ASS / SSA / VTT |
| 进度 | 每 5s 或暂停/退出时持久化，续播从上次位置减 3s |

失败分类复用 5.3 的错误模型，用户可见出口见 [UI 规范](./ui-design-guidelines.md) 第 7 节；禁止无限转圈。

### 8.1 播放会话状态

```text
idle → preparing（转存 / 解析中） → ready（地址可用） → playing
                    ├─ failed（可重试，保留任务与已得结果）
                    └─ cancelled（用户取消等待，后台转存继续）
```

- 状态由 NAS 返回，iOS 只做展示与轮询，不在本地推断"已可播"。
- 轮询间隔以后端返回的建议值为准；进入后台降频，回前台立即查一次，`ready` 后停止。
- 取消等待不等于取消转存；会话可恢复，用于"稍后继续播放"。

### 8.2 字幕子系统

字幕是独立业务，不绑定播放器内核；播放器只负责渲染。

```text
SubtitleProvider（内嵌 / 本地 / 在线插件 / HTTP URL）
        ↓ 并发搜索
SubtitleSearch（标准化结果：名称 / 语言 / 格式 / 来源 / 版本 / 匹配度 / 更新时间）
        ↓ 自动匹配（作品名、别名、年份、季、集、文件名、发布版本）
        ↓ 单条下载
NAS 字幕库（电影：作品+年份；剧集：作品+季+集；动漫：作品+季度+季+集）
        ↓
播放器加载（自动切换到新字幕）
```

- 多来源并发、逐步返回、单来源失败不影响其他来源，支持单来源重试。
- 自动匹配只做推荐，用户仍可查看全部结果；不使用 AI 内容识别。
- 只支持单条下载，不做批量下载；不支持人工上传与 Web 字幕库管理。
- 常规与私密字幕库完全隔离；iPhone 只保留当前会话临时缓存，长期以 NAS 为准。
- 第一阶段能力：解析、加载、切换、样式、字号、颜色、位置、背景、时间轴偏移、编码处理；AI 翻译 / 双语 / ASR 仅预留接口。

---

## 9. 性能与观测

### 9.1 预算

| 指标 | 目标 | 测量方式 |
| --- | --- | --- |
| 冷启动到可交互 | ≤ 1.0s（iPhone 12 起） | Launch Profiler / signpost |
| 热启动 | ≤ 400ms | signpost |
| 启动后首屏内容 | 有缓存 ≤ 300ms，无缓存 ≤ 800ms | signpost |
| 滚动 | 120Hz 设备不掉帧 | Instruments / Hitches |
| 主线程卡顿 | 关键路径无 > 250ms hang | MetricKit |
| 前台内存 | < 200MB，峰值 < 350MB | Allocations |
| 图片缓存 | 内存 50MB / 磁盘 500MB 上限 | 自定义 LRU |
| 网络首屏（局域网） | ≤ 800ms | 请求耗时日志 |
| 能耗 | 无 < 30s 轮询；后台任务合并 | Energy Log |

### 9.2 性能守则

- `body` 中不做 IO、日期格式化、排序、图片解码。
- 列表用稳定 `id` + `LazyVStack/LazyVGrid`，避免整树刷新。
- 图片先降采样到目标尺寸再上屏；滚动时不触发新请求。
- `@Observable` 只让 View 读取真正需要的属性；纯计算属性用 `@ObservationIgnored` 控制。
- 启动保持精简：少用 `+load`、少链动态库、延迟初始化。

---

## 10. 可观测性

- **日志**：`os.Logger` 分 `network/auth/playback/cache`，Release 只保留 info 以上。
- **性能**：关键路径打 `os_signpost`（启动、首屏、解析直链、首帧）。
- **指标**：`MetricKit` 收集启动、卡顿、崩溃、磁盘写入，每周看趋势。
- **崩溃**：保留 dSYM，符号化后定位到函数级。
- **调试入口**：「更多」页长按版本号进入诊断页，查看服务端地址、网络状态、导出日志。

---

## 11. 测试策略

| 层级 | 覆盖内容 | 工具 |
| --- | --- | --- |
| 单元 | `ServerConfig` 解析、错误映射、DTO 解码、Store 状态机 | XCTest / Swift Testing |
| 网络 | `URLProtocol` 桩模拟 200/401/409/超时/断网 | XCTest |
| 集成 | 登录 → 存 token → 重启恢复 → 退出清理 | XCTest |
| UI 冒烟 | 启动、登录、首页、退出、播放失败态 | XCUITest |
| 快照 | 关键页面浅色/深色/超大字体 | 截图对比（可选） |
| 预览 | 每个组件至少一个 `#Preview` | Xcode Previews |

CI 门禁：编译零警告、单测通过、Core 层覆盖率 ≥ 70%、SwiftLint 无 error。

---

## 12. 工程化与发布

### 12.1 构建配置

| 配置 | 用途 | 服务端 | 签名 |
| --- | --- | --- | --- |
| Debug | 本机开发 | localhost | 自动 |
| Staging | 内测 | 测试地址 | 开发证书 |
| Release | App Store | 生产/用户自填 | 发布证书 |

- 用 `.xcconfig` 管理 Bundle ID、版本、API 默认地址，避免手改 pbxproj。
- `MARKETING_VERSION` 语义化，`CURRENT_PROJECT_VERSION` 自增。

### 12.2 质量工具与 CI

- SwiftLint：禁用强制解包、空 catch、超长函数；SwiftFormat 统一格式。
- 至少 Core 层构建警告视为错误。
- CI 流水线：`push/PR → lint → build → test → archive → TestFlight → 提审`。
- 使用 App Store Connect API Key，不把证书提交仓库；归档上传 dSYM。
- 分阶段放量，保留回滚版本；崩溃-free 阈值 ≥ 99.5%。

### 12.3 提审检查

- [ ] 隐私政策 URL 可访问，隐私标签与实际一致
- [ ] `PrivacyInfo.xcprivacy` 已加入 Target
- [ ] 所有权限文案具体
- [ ] 有账号创建则有删除入口
- [ ] 无私有 API、无隐藏功能、无诱导评分
- [ ] 截图、预览、描述与真实界面一致
- [ ] 提供审核用测试账号（如需要）
- [ ] 出口合规（加密）声明完成
- [ ] iOS 26 下导航、Tab、搜索显示正常

参考：[Preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution/)

---

## 13. 实施路线

### P0 · 主链路稳定

- [x] 新增 `AppState`，实现 Keychain 会话恢复与 `/api/auth/me` 校验（含 1.5s 超时与离线保留会话）。
- [x] 重写闪屏时序：真实准备驱动（最短 300ms），删除 1.4s 固定等待。
- [x] `APIClient` 增加鉴权注入、`X-Request-ID`、12 类错误分类、10s 超时、取消与幂等 GET 重试。
- [x] 401 / 403 与 token 过期的统一处理，退出登录清理完整；换服务端地址作废旧凭证。
- [x] 记住密码持久化：账号存 UserDefaults，密码存 Keychain 独立 account，取消勾选即删除。
- [ ] 全局离线状态（`NWPathMonitor`）与首屏缓存。

### P1 · 质量基线

1. 依赖注入与协议化，页面不再现造服务。
2. 建立 Test Target：网络桩、登录链路、`ServerConfig`。
3. 加入 `PrivacyInfo.xcprivacy` 与提审清单。
4. 图片缓存与列表降采样。
5. 115 文件浏览、直链解析与播放闭环（授权统一在 Web 管理台，iOS 不保存 115 凭证）。
6. SwiftLint + CI。

### P2 · 体验打磨

1. String Catalog 本地化。
2. iPad 分栏与横屏适配。
3. 全量无障碍审计。
4. MetricKit 与诊断页。
5. 深链、状态恢复、快捷指令。

### P3 · 产品阶段对应

工程优先级与 [产品需求基线](./product-requirements.md) 第 18 节对齐，不改变业务顺序：

| 产品阶段 | iOS 侧交付 |
| --- | --- |
| Phase 0 | 通信验证、115 授权 / 转存 / 解析验证、`PlayerFacade` 内核与 PiP 验证 |
| Phase 1 | 四 Tab、首页栏目配置、作品详情、全局搜索、多来源状态、资源详情、多磁力多选转存、页面级目录、网盘在线、HTTP 播放 |
| Phase 2 | PiP、字幕面板与字幕库、播放历史、断点续播 |
| Phase 3 | 短剧 Tab、私密模式与数据隔离、收藏、搜索历史清理、插件简化管理、设置中心补全 |
| Phase 4 | AirPlay、双语 / AI 字幕、多用户 UI、内核优化 |

P0–P2 是工程质量线，可与产品 Phase 1 并行推进；不得为赶页面跳过 P0 的主链路稳定性。

---

## 14. 验收清单

- [ ] 冷启动有 token 时直接进首页，无登录页闪烁
- [ ] 闪屏时长由真实准备驱动，≤ 1.2s
- [ ] 网络不可达时保留会话，401 才清会话
- [ ] 所有请求经过统一 `APIClient`，View 中无 `URLSession`
- [ ] 断网、超时、401、5xx 均有明确文案与下一步
- [ ] token 仅存 Keychain，日志中无敏感信息
- [ ] 播放失败有重新解析 / 换源 / 重试出口，无「转码」依赖
- [ ] 关键路径无 > 250ms 主线程卡顿
- [ ] 有 Test Target 且核心逻辑有测试
- [ ] 有 `PrivacyInfo.xcprivacy` 与提审检查记录
- [ ] 可在 CI 上完成 build + test + archive
- [ ] [UI 规范](./ui-design-guidelines.md) 第 10 节验收项全部通过

---

## 15. 参考来源

- [Managing model data in your app](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app)
- [Reducing your app's launch time](https://developer.apple.com/documentation/Xcode/reducing-your-app-s-launch-time)
- [Improving your app's performance](https://developer.apple.com/documentation/xcode/improving-your-app-s-performance)
- [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance)
- [Third-party SDK requirements（隐私清单）](https://developer.apple.com/support/third-party-SDK-requirements/)
- [Preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution/)
- [AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer)
