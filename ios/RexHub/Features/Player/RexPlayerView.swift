import AVFoundation
import KSPlayer
import SwiftUI
import UIKit

/// 网盘播放器：先向服务端换取临时直链，再让播放内核直连 115 CDN。
/// 服务端只返回 URL 与请求头，不代理视频字节流。
/// 画面与交互统一交给 `RexPlayerChrome`，AVPlayer 与 KSPlayer 只负责解码与渲染。
/// 传入 `playlist` 后，开启「自动连播下一集」时会在播完后切到目录里的下一个视频。
struct RexPlayerView: View {
    let item: PanItem
    var playlist: [PanItem] = []
    /// 片商 / 插件返回的直链：有值时不再向 115 换取播放地址。
    var directSource: PanPlayInfo?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.apiClient) private var apiClient
    @Environment(\.scenePhase) private var scenePhase

    @State private var activeItem: PanItem
    @State private var engine: (any RexPlaybackEngine)?
    /// 换内核或换下一集时变化，强制重建画面层，画中画也能重新绑定新的 `AVPlayerLayer`。
    @State private var engineToken = UUID()
    @State private var phase: Phase = .loading
    @State private var didReachOutro = false
    @State private var subtitleCues: [SubtitleCue] = []
    @State private var subtitleText = ""
    /// 本次进入播放页是否由「自动横屏」转了过去，退出时据此恢复竖屏。
    @State private var didAutoRotate = false
    /// 自动横屏的判定任务，退出播放页时取消，避免转场后误转方向。
    @State private var autoRotateTask: Task<Void, Never>?

    private enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    init(item: PanItem, playlist: [PanItem] = [], directSource: PanPlayInfo? = nil) {
        self.item = item
        self.playlist = playlist
        self.directSource = directSource
        _activeItem = State(initialValue: item)
    }

    var body: some View {
        ZStack {
            RexColor.mediaBackground.ignoresSafeArea()

            switch phase {
            case .loading:
                ZStack(alignment: .topLeading) {
                    VStack(spacing: RexSpacing.md) {
                        ProgressView()
                            .tint(RexColor.onMedia)

                        Text("正在解析播放地址…")
                            .font(.system(size: 14))
                            .foregroundStyle(RexColor.onMedia.opacity(0.75))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // 解析可能因为网络问题一直转圈，这里必须留一个退出口。
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(RexColor.onMedia.opacity(0.9))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭播放")
                    .padding(.leading, RexSpacing.lg)
                    .padding(.top, RexSpacing.sm)
                }
            case .ready:
                if let engine, let message = engine.state.failureMessage {
                    failureView(message)
                } else if let engine {
                    ZStack {
                        surface(engine)

                        RexPlayerChrome(
                            title: activeItem.name,
                            subtitleText: subtitleText,
                            playlist: playlist,
                            currentItemID: activeItem.id,
                            onClose: { dismiss() },
                            onSelect: { switchTo($0) },
                            engine: engine
                        )
                    }
                    .id(engineToken)
                }
            case .failed(let message):
                failureView(message)
            }
        }
        .task {
            await resolve()
        }
        .onAppear(perform: enableAutoLandscape)
        .onChange(of: scenePhase) { _, newPhase in
            // 切后台先把进度落盘，进程被系统回收后再回来仍能续播。
            if newPhase != .active {
                savePlaybackPosition()
            }
            guard newPhase == .background else { return }
            guard !PlayerSettingsStore.shared.backgroundAudio,
                  engine?.state.isPipActive != true else { return }
            engine?.pause()
        }
        .onDisappear {
            autoRotateTask?.cancel()
            savePlaybackPosition()
            teardownEngine()
            UIApplication.shared.isIdleTimerDisabled = false
            restorePortraitIfNeeded()
        }
        .preferredColorScheme(.dark)
    }

    /// 两个内核共用同一套控制层，这里只按引擎类型挑对应的画面层。
    @ViewBuilder
    private func surface(_ engine: any RexPlaybackEngine) -> some View {
        if let av = engine as? AVPlayerEngine {
            RexAVPlayerSurface(player: av.player) { layer in
                av.attach(playerLayer: layer)
            }
            .ignoresSafeArea()
        } else if let ks = engine as? KSPlayerEngine {
            KSVideoPlayer(coordinator: ks.coordinator, url: ks.url, options: ks.options)
                .ignoresSafeArea()
        }
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: RexSpacing.lg) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(RexColor.warning)

            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(RexColor.onMedia.opacity(0.8))
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            Button {
                Task { await resolve() }
            } label: {
                Text("重试")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RexColor.onBrand)
                    .frame(width: 160, height: 44)
                    .background(
                        RexColor.brandGradient,
                        in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                    )
            }
            .buttonStyle(PressableButtonStyle())

            Button {
                dismiss()
            } label: {
                Text("返回")
                    .font(.system(size: 14))
                    .foregroundStyle(RexColor.onMedia.opacity(0.7))
                    .frame(minWidth: 88, minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, RexSpacing.xxl)
    }

    // MARK: - 屏幕方向

    /// 开启「自动横屏」时，只有横屏片源才转横屏，竖屏短剧保持竖屏观看。
    /// 视频尺寸由内核异步读出，先等模态转场结束，再等尺寸就绪后决定。
    private func enableAutoLandscape() {
        guard !didAutoRotate, PlayerSettingsStore.shared.autoLandscape else { return }
        autoRotateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }

            // 尺寸需要等内核解析元数据，最多等 2 秒。
            for _ in 0..<20 {
                if let size = engine?.state.videoSize, size.width >= 1, size.height >= 1 { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
            }

            // 尺寸未知时仍按原逻辑横屏，避免元数据来得慢就不转了。
            if let size = engine?.state.videoSize, size.width < size.height {
                return
            }
            didAutoRotate = true
            RexOrientation.request(.landscapeRight)
        }
    }

    /// 退出播放页时只还原由自动横屏转过去的方向。
    private func restorePortraitIfNeeded() {
        guard didAutoRotate else { return }
        didAutoRotate = false
        RexOrientation.request(.portrait)
    }

    // MARK: - 解析与播放

    private func resolve() async {
        phase = .loading
        teardownEngine()
        didReachOutro = false
        subtitleCues = []
        subtitleText = ""

        do {
            let info: PanPlayInfo
            if let directSource {
                info = directSource
            } else {
                guard let client = apiClient else {
                    phase = .failed("登录状态已失效，请重新登录")
                    return
                }
                guard !activeItem.pickcode.isEmpty else {
                    phase = .failed("该文件缺少播放标识，无法播放")
                    return
                }
                info = try await client.panPlay(pickcode: activeItem.pickcode)
            }

            let settings = PlayerSettingsStore.shared
            PlayerFacade.activateAudioSession()
            UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake

            let start = startPosition(for: settings)
            // 上次记录的时长一起塞给内核，进入播放页时进度条直接落在续播位置，不用等元数据再跳。
            let savedDuration = settings.savedDuration(for: activeItem.pickcode)
            let route = await PlayerFacade.resolveRoute(for: info)
            let newEngine: any RexPlaybackEngine

            if route.kernel == .ksPlayer {
                let videoName = (activeItem.name as NSString).deletingPathExtension
                let subtitleURLs = settings.subtitlesEnabled
                    ? SubtitleLoader.urls(
                        sources: settings.subtitleSources,
                        videoName: videoName,
                        language: settings.subtitleLanguage
                    )
                    : []
                let ks = KSPlayerEngine(
                    url: info.url,
                    options: PlayerFacade.makeKSOptions(
                        for: info,
                        startTime: start,
                        forceSoftwareDecode: route.forceSoftwareDecode
                    ),
                    subtitleURLs: subtitleURLs,
                    rate: settings.playbackRate,
                    isMuted: settings.startMuted
                )
                ks.state.currentTime = start
                ks.state.duration = savedDuration
                newEngine = ks
            } else {
                let av = AVPlayerEngine(
                    player: PlayerFacade.makePlayer(for: info),
                    rate: settings.playbackRate
                )
                av.state.currentTime = start
                av.state.duration = savedDuration
                if start >= 5 {
                    await av.player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
                    av.state.currentTime = start
                }
                if settings.autoPlay {
                    av.play()
                }
                newEngine = av
            }

            installCallbacks(for: newEngine)
            newEngine.refreshTracks()

            engine = newEngine
            engineToken = UUID()
            phase = .ready

            if newEngine is AVPlayerEngine {
                await loadSubtitles()
            }
        } catch let error as APIError {
            guard error != .cancelled else { return }
            phase = .failed(error.errorDescription ?? "获取播放地址失败，请重试")
        } catch {
            phase = .failed("获取播放地址失败，请重试")
        }
    }

    /// 起播位置：优先续播进度，没有进度时按「跳过片头」直接跳到设定秒数。
    private func startPosition(for settings: PlayerSettingsStore) -> Double {
        let saved = settings.resumePlayback ? settings.savedPosition(for: activeItem.pickcode) : 0
        if saved >= 5 { return saved }
        return settings.skipIntro ? Double(settings.introSeconds) : 0
    }

    /// 两个内核统一回调：进度用于 AV 外部字幕与片尾判定，结束统一走 `handlePlaybackEnded`。
    private func installCallbacks(for engine: any RexPlaybackEngine) {
        let updatesExternalSubtitles = engine is AVPlayerEngine

        engine.onTick = { current, total in
            if updatesExternalSubtitles {
                updateSubtitle(at: current)
            }
            finishIfOutroReached(current: current, total: total)
        }

        engine.onEnded = {
            handlePlaybackEnded()
        }
    }

    /// 跳过片尾：剩余时间进入设定区间时直接收尾，循环播放优先。
    private func finishIfOutroReached(current: Double, total: Double) {
        let settings = PlayerSettingsStore.shared
        guard settings.skipOutro, !settings.loopPlayback, !didReachOutro else { return }
        guard total.isFinite, total > 0, current.isFinite else { return }
        guard total - current <= Double(settings.outroSeconds) else { return }

        didReachOutro = true
        engine?.pause()
        handlePlaybackEnded()
    }

    /// 一集真正结束：循环优先，其次连播下一集，最后按设置关闭播放页。
    private func handlePlaybackEnded() {
        let settings = PlayerSettingsStore.shared

        if settings.loopPlayback {
            didReachOutro = false
            engine?.seek(to: 0)
            engine?.play()
            return
        }

        savePlaybackPosition()

        if settings.autoPlayNext, let next = nextItem {
            switchTo(next)
            return
        }
        if settings.autoCloseOnFinish {
            dismiss()
        }
    }

    /// 当前目录里的下一个视频；没有播放列表或已是最后一个时返回 `nil`。
    private var nextItem: PanItem? {
        guard !playlist.isEmpty,
              let index = playlist.firstIndex(where: { $0.id == activeItem.id }),
              playlist.indices.contains(index + 1) else { return nil }
        return playlist[index + 1]
    }

    /// 原地切换到下一个视频：清掉旧内核，重新解析直链。
    private func switchTo(_ next: PanItem) {
        savePlaybackPosition()
        teardownEngine()
        subtitleCues = []
        subtitleText = ""
        didReachOutro = false
        activeItem = next
        Task { await resolve() }
    }

    private func teardownEngine() {
        engine?.teardown()
        engine = nil
    }

    // MARK: - 字幕

    private func updateSubtitle(at time: TimeInterval) {
        let settings = PlayerSettingsStore.shared
        guard settings.subtitlesEnabled, time.isFinite else {
            if !subtitleText.isEmpty { subtitleText = "" }
            return
        }

        let adjusted = time - settings.subtitleDelay
        let text = subtitleCues.last(where: { $0.contains(adjusted) })?.text ?? ""
        if text != subtitleText {
            subtitleText = text
        }
    }

    /// 依次尝试已配置的 HTTP 字幕源，取第一个可解析的结果。
    private func loadSubtitles() async {
        let settings = PlayerSettingsStore.shared
        guard settings.subtitlesEnabled, !settings.subtitleSources.isEmpty else { return }

        let videoName = (activeItem.name as NSString).deletingPathExtension
        let cues = await SubtitleLoader.load(
            sources: settings.subtitleSources,
            videoName: videoName,
            language: settings.subtitleLanguage
        )
        guard settings.subtitlesEnabled else { return }

        subtitleCues = cues
        if let current = engine?.state.currentTime {
            updateSubtitle(at: current)
        }
    }

    /// 关闭页面或切集时记录进度；已播到结尾或已跳过片尾则清除，下次从头开始。
    private func savePlaybackPosition() {
        let settings = PlayerSettingsStore.shared
        guard settings.resumePlayback, let engine else { return }

        if didReachOutro {
            settings.savePosition(0, for: activeItem.pickcode)
        } else {
            let seconds = engine.state.currentTime
            guard seconds.isFinite else { return }
            // 片尾判定的收尾逻辑在 `savePosition` 里，这里把时长一并交给它，供列表显示进度。
            settings.savePosition(seconds, duration: engine.state.duration, for: activeItem.pickcode)
        }
        syncProgressToServer(settings)
    }

    /// 进度落盘后同步到服务端，供其它设备续播；失败不影响本机播放与续播。
    private func syncProgressToServer(_ settings: PlayerSettingsStore) {
        // 片商直链不是 115 文件，服务端没有对应进度记录。
        guard directSource == nil, let client = apiClient else { return }
        let pickcode = activeItem.pickcode
        let position = settings.savedPosition(for: pickcode)
        let duration = settings.savedDuration(for: pickcode)
        // 看完或没看时位置归零，服务端据此删除记录；位置有效但时长缺失时无法算比例，等下次再报。
        guard position <= 0 || duration > 0 else { return }

        Task {
            try? await client.panUpdateProgress(
                pickcode: pickcode,
                position: position,
                duration: duration
            )
        }
    }
}
