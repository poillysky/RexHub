# KSPlayer 接入与构建备忘

记录接入 KSPlayer 双内核时踩过的坑，以及每次构建/验证要用的固定命令。

## 1. 环境

| 项 | 值 |
| --- | --- |
| Xcode | 27.2 (Build 27B52) |
| 模拟器 UDID | `978F624A-26BE-4A6A-9C84-6537ED194306` |
| DerivedData | `~/Library/Developer/Xcode/DerivedData/RexHub-guewcnvtplvfsgamxjujvezzdgqe` |
| Bundle ID | `com.poilly.RexHub` |

## 2. 代理（127.0.0.1:7897）

macOS 系统代理已开，但 **xcodebuild 内部的 git 不读系统代理**，只认环境变量。
不带环境变量时 KSPlayer 克隆会卡在 80K 不动。

所有拉包命令都要显式带上：

```bash
export HTTPS_PROXY=http://127.0.0.1:7897
export HTTP_PROXY=http://127.0.0.1:7897
export ALL_PROXY=http://127.0.0.1:7897
export https_proxy=$HTTPS_PROXY http_proxy=$HTTP_PROXY
```

校验代理是否可用：

```bash
curl -x http://127.0.0.1:7897 -I https://github.com   # 期望 200
```

## 3. 依赖

| 包 | 版本 |
| --- | --- |
| KSPlayer | `branch = main`，HEAD `7d6b4ce`（swift-tools 6.2） |
| FFmpegKit | `9.0.2` |

- 用 main 而不是 2.3.4：老 tag 是 tools 5.9 且没有 `Sources/KSPlayerUI/SwiftUI/KSVideoPlayerView.swift`。
- 工程通过 `XCRemoteSwiftPackageReference` + `PBXBuildFile(productRef:)` 接入 `KSPlayerUI`、`KSPlayer` 两个 product。
- 首次解析要拉约 1.6G，解析结果落在 `SourcePackages/`，之后不再需要网络。

解析依赖（注意 `Package.resolved` 与 SPM 指纹目录都在沙箱外）：

```bash
export HTTPS_PROXY=http://127.0.0.1:7897 HTTP_PROXY=$HTTPS_PROXY ALL_PROXY=$HTTPS_PROXY
xcodebuild -resolvePackageDependencies -project RexHub.xcodeproj -scheme RexHub \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/RexHub-guewcnvtplvfsgamxjujvezzdgqe
```

## 4. 构建命令（固定用这条）

```bash
xcodebuild -project RexHub.xcodeproj -scheme RexHub \
  -destination 'platform=iOS Simulator,id=978F624A-26BE-4A6A-9C84-6537ED194306' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/RexHub-guewcnvtplvfsgamxjujvezzdgqe \
  OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' build
```

`-disable-sandbox` 不能省：KSPlayerUI 里大量 `@State` 依赖宏插件，关闭插件沙箱前会报
`sandbox-exec: execvp() of .../swift-plugin-server failed: Operation not permitted`，
进而误报 `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`。

这条构建命令需要在非沙箱环境执行（要写 `~/Library/org.swift.swiftpm/security`、Keychain 与 DerivedData）。

## 5. 安装与验证

```bash
xcrun simctl bootstatus 978F624A-26BE-4A6A-9C84-6537ED194306 -b
xcrun simctl install 978F624A-26BE-4A6A-9C84-6537ED194306 \
  ~/Library/Developer/Xcode/DerivedData/RexHub-guewcnvtplvfsgamxjujvezzdgqe/Build/Products/Debug-iphonesimulator/RexHub.app
xcrun simctl launch 978F624A-26BE-4A6A-9C84-6537ED194306 com.poilly.RexHub
xcrun simctl io 978F624A-26BE-4A6A-9C84-6537ED194306 screenshot /tmp/rexhub.png
```

## 6. KSPlayer API 备忘

- `KSVideoPlayerModel(title:config:options:url:subtitleURLs:)` + `KSVideoPlayerView(model:)`，画面、控件、手势、字幕都由 KSPlayer 自己渲染。
- 取进度：`model.config.playerLayer?.player.currentTime / .totalTime`。
  `KSPlayerLayer` 本身**没有** `currentTime/totalTime` 属性（第一次编译就挂在这）。
- 请求头：`options.appendHeader(headers)`，再单独设 `userAgent` / `referer`（115 直链必需）。
- 容器兜底：扩展名不在 `mp4/m4v/mov/m3u8/ts` 时 `options.playerTypes = [KSMEPlayer.self]`。
- 静音：`KSVideoPlayer.Coordinator.isMuted` 有 didSet，要在 `onAppear` 里设，初始化设会被覆盖。
- 字幕：把 HTTP 模板 `{name}` 展开成 URL，交给 `URLSubtitleInfo(url:)`，ASS/SSA 由 KSPlayer 解析。

## 7. 代码索引

| 内容 | 位置 |
| --- | --- |
| 内核枚举与设置项 | `RexHub/Features/Settings/PlayerSettings.swift` |
| 播放内核菜单 | `RexHub/Features/Settings/PlayerSettingsView.swift` |
| KSOptions / AVPlayer 配置 | `RexHub/Core/Media/PlayerFacade.swift` |
| 双内核播放页 | `RexHub/Features/Player/RexPlayerView.swift` |
| 字幕解析与 URL 展开 | `RexHub/Core/Media/Subtitle.swift` |

## 8. 注意事项

- KSPlayer 默认 GPL 协议，对外发布前需确认授权。
- 构建失败时中间产物会被移入废纸篓，恢复方式：Finder 打开废纸篓 → 先看 `sboxbackup` → 拖回 DerivedData 对应目录（缓存产物，不恢复也能重新构建）。
