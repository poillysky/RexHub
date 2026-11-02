import AVKit
import KSPlayer
import KSPlayerUI
import SwiftUI
import UIKit

/// 网盘播放器：先向服务端换取临时直链，再让播放内核直连 115 CDN。
/// 服务端只返回 URL 与请求头，不代理视频字节流。
/// 传入 `playlist` 后，开启「自动连播下一集」时会在播完后切到目录里的下一个视频。
struct RexPlayerView: View {
    let item: PanItem
    var playlist: [PanItem] = []

    @Environment(\.dismiss) private var dismiss
    @Environment(\.apiClient) private var apiClient
    @Environment(\.scenePhase) private var scenePhase

    @State private var activeItem: PanItem
    @State private var player: AVPlayer?
    @State private var phase: Phase = .loading
    @State private var endToken: NSObjectProtocol?
    @State private var didReachOutro = false
    @State private var settings = PlayerSettingsStore.shared
    @State private var subtitleCues: [SubtitleCue] = []
    @State private var subtitleText = ""
    @State private var timeToken: Any?
    @State private var timeObserverPlayer: AVPlayer?
    @State private var ksPlayback: KSPlayback?

    private enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    /// KSPlayer 内核所需的全部输入，和 AVPlayer 分支互斥。
    fileprivate struct KSPlayback {
        let url: URL
        let options: KSOptions
        let subtitleURLs: [URL]
        let isMuted: Bool
    }

    init(item: PanItem, playlist: [PanItem] = []) {
        self.item = item
        self.playlist = playlist
        _activeItem = State(initialValue: item)
    }

    var body: some View {
        ZStack {
            RexColor.mediaBackground.ignoresSafeArea()

            switch phase {
            case .loading:
                VStack(spacing: RexSpacing.md) {
                    ProgressView()
                        .tint(RexColor.onMedia)

                    Text("正在解析播放地址…")
                        .font(.system(size: 14))
                        .foregroundStyle(RexColor.onMedia.opacity(0.75))
                }
            case .ready:
                if let ksPlayback {
                    KSPlayerScreen(
                        title: activeItem.name,
                        pickcode: activeItem.pickcode,
                        playback: ksPlayback,
                        loopPlayback: settings.loopPlayback,
                        outroSeconds: settings.skipOutro ? settings.outroSeconds : nil,
                        backgroundAudio: settings.backgroundAudio,
                        onPlaybackEnded: handlePlaybackEnded,
                        onSaveProgress: saveKSPlaybackPosition
                    )
                    .id(activeItem.pickcode)
                } else if let player {
                    // AV 内核用自建层，才能接管单击/双击/长按/拖动这些单指手势。
                    RexAVPlayerView(
                        player: player,
                        title: activeItem.name,
                        onClose: { dismiss() }
                    )
                    .id(ObjectIdentifier(player))
                }
            case .failed(let message):
                failureView(message)
            }
        }
        .overlay {
            if ksPlayback == nil {
                subtitleOverlay
            }
        }
        .task {
            await resolve()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // 关掉后台播放后，退到后台立即暂停；KSPlayer 在自己的画面里处理。
            guard newPhase == .background, !settings.backgroundAudio, ksPlayback == nil else { return }
            player?.pause()
        }
        .onDisappear {
            removeEndObserver()
            removeTimeObserver()
            savePlaybackPosition()
            UIApplication.shared.isIdleTimerDisabled = false
            player?.pause()
            player = nil
        }
    }

    /// 字幕贴在画面底部、系统播放控件上方，不拦截点击。
    @ViewBuilder
    private var subtitleOverlay: some View {
        if !subtitleText.isEmpty {
            Text(subtitleText)
                .font(.system(size: settings.subtitleSize.fontSize, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
                .padding(.horizontal, settings.subtitleBackground ? 8 : 0)
                .padding(.vertical, settings.subtitleBackground ? 4 : 0)
                .background {
                    if settings.subtitleBackground {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.black.opacity(0.45))
                    }
                }
                .padding(.horizontal, RexSpacing.xxl)
                .padding(.bottom, 96)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.12), value: subtitleText)
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

    // MARK: - 解析与播放

    private func resolve() async {
        phase = .loading
        removeEndObserver()
        removeTimeObserver()
        didReachOutro = false
        subtitleCues = []
        subtitleText = ""
        ksPlayback = nil
        player?.pause()
        player = nil

        guard let client = apiClient else {
            phase = .failed("登录状态已失效，请重新登录")
            return
        }
        guard !activeItem.pickcode.isEmpty else {
            phase = .failed("该文件缺少播放标识，无法播放")
            return
        }

        do {
            let info = try await client.panPlay(pickcode: activeItem.pickcode)
            let settings = PlayerSettingsStore.shared
            PlayerFacade.activateAudioSession()
            UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake

            // KSPlayer 自己负责渲染画面、控件与字幕，这里只把直链和配置交给它。
            if PlayerFacade.resolvedKernel(for: info) == .ksPlayer {
                let start = startPosition(for: settings)
                let videoName = (activeItem.name as NSString).deletingPathExtension
                let subtitleURLs = settings.subtitlesEnabled
                    ? SubtitleLoader.urls(
                        sources: settings.subtitleSources,
                        videoName: videoName,
                        language: settings.subtitleLanguage
                    )
                    : []
                ksPlayback = KSPlayback(
                    url: info.url,
                    options: PlayerFacade.makeKSOptions(for: info, startTime: start),
                    subtitleURLs: subtitleURLs,
                    isMuted: settings.startMuted
                )
                phase = .ready
                return
            }

            let newPlayer = PlayerFacade.makePlayer(for: info)
            player = newPlayer
            phase = .ready
            installEndObserver(for: newPlayer, settings: settings)
            let start = startPosition(for: settings)
            if start >= 5 {
                await newPlayer.seek(to: CMTime(seconds: start, preferredTimescale: 600))
            }
            if settings.autoPlay {
                newPlayer.playImmediately(atRate: Float(settings.playbackRate))
            }
            startTimeObserver(for: newPlayer)
            await loadSubtitles()
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

    /// 结尾处理：循环优先；否则按设置自动连播下一集或关闭播放页。
    private func installEndObserver(for player: AVPlayer, settings: PlayerSettingsStore) {
        removeEndObserver()
        guard let currentItem = player.currentItem else { return }

        endToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: currentItem,
            queue: .main
        ) { _ in
            if settings.loopPlayback {
                didReachOutro = false
                player.seek(to: .zero)
                player.playImmediately(atRate: Float(settings.playbackRate))
            } else {
                handlePlaybackEnded()
            }
        }
    }

    private func removeEndObserver() {
        guard let endToken else { return }
        NotificationCenter.default.removeObserver(endToken)
        self.endToken = nil
    }

    /// 跳过片尾：剩余时间进入设定区间时直接收尾，循环播放优先。
    private func finishIfOutroReached(for player: AVPlayer, at time: TimeInterval) {
        let settings = PlayerSettingsStore.shared
        guard settings.skipOutro, !settings.loopPlayback, !didReachOutro else { return }
        guard let duration = player.currentItem?.duration.seconds,
              duration.isFinite, duration > 0 else { return }
        guard duration - time <= Double(settings.outroSeconds) else { return }

        didReachOutro = true
        player.pause()
        handlePlaybackEnded()
    }

    /// 一集真正结束：记进度、切下一集或关闭；循环播放由调用方提前处理。
    private func handlePlaybackEnded() {
        let settings = PlayerSettingsStore.shared
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
        removeEndObserver()
        removeTimeObserver()
        player?.pause()
        player = nil
        ksPlayback = nil
        subtitleCues = []
        subtitleText = ""
        didReachOutro = false
        activeItem = next
        Task { await resolve() }
    }

    // MARK: - 字幕

    private func startTimeObserver(for player: AVPlayer) {
        removeTimeObserver()
        timeObserverPlayer = player
        timeToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { time in
            updateSubtitle(at: time.seconds)
            finishIfOutroReached(for: player, at: time.seconds)
        }
    }

    private func removeTimeObserver() {
        if let timeObserverPlayer, let timeToken {
            timeObserverPlayer.removeTimeObserver(timeToken)
        }
        timeToken = nil
        timeObserverPlayer = nil
    }

    private func updateSubtitle(at time: TimeInterval) {
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
        guard settings.subtitlesEnabled, !settings.subtitleSources.isEmpty else { return }
        let videoName = (activeItem.name as NSString).deletingPathExtension
        let cues = await SubtitleLoader.load(
            sources: settings.subtitleSources,
            videoName: videoName,
            language: settings.subtitleLanguage
        )
        guard settings.subtitlesEnabled else { return }
        subtitleCues = cues
        if let current = player?.currentTime().seconds {
            updateSubtitle(at: current)
        }
    }

    /// 关闭页面时记录进度；已播到结尾或已跳过片尾则清除，下次从头开始。
    private func savePlaybackPosition() {
        let settings = PlayerSettingsStore.shared
        guard settings.resumePlayback,
              let player,
              let current = player.currentItem else { return }

        if didReachOutro {
            settings.savePosition(0, for: activeItem.pickcode)
            return
        }

        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }

        let duration = current.duration.seconds
        if duration.isFinite, duration > 0, seconds >= duration - 3 {
            settings.savePosition(0, for: activeItem.pickcode)
        } else {
            settings.savePosition(seconds, for: activeItem.pickcode)
        }
    }

    /// KSPlayer 关闭页面时同样记录进度，结尾 3 秒内视为看完。
    /// `pickcode` 由子视图在创建时固定，避免切换下一集时写到错误条目。
    private func saveKSPlaybackPosition(for pickcode: String, current: Double, total: Double) {
        let settings = PlayerSettingsStore.shared
        guard settings.resumePlayback, current.isFinite else { return }

        if total.isFinite, total > 0, current >= total - 3 {
            settings.savePosition(0, for: pickcode)
        } else {
            settings.savePosition(current, for: pickcode)
        }
    }
}

// MARK: - KSPlayer 内核

/// 只包一层 `KSVideoPlayerView`：画面、控件、手势与字幕渲染都由 KSPlayer 提供。
@MainActor
private struct KSPlayerScreen: View {
    let title: String
    let pickcode: String
    let playback: RexPlayerView.KSPlayback
    let loopPlayback: Bool
    /// 需要跳过片尾时传入剩余秒数，`nil` 表示不跳过。
    let outroSeconds: Int?
    let backgroundAudio: Bool
    let onPlaybackEnded: () -> Void
    let onSaveProgress: (String, Double, Double) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: KSVideoPlayerModel
    @State private var didReachOutro = false

    init(
        title: String,
        pickcode: String,
        playback: RexPlayerView.KSPlayback,
        loopPlayback: Bool,
        outroSeconds: Int?,
        backgroundAudio: Bool,
        onPlaybackEnded: @escaping () -> Void,
        onSaveProgress: @escaping (String, Double, Double) -> Void
    ) {
        self.title = title
        self.pickcode = pickcode
        self.playback = playback
        self.loopPlayback = loopPlayback
        self.outroSeconds = outroSeconds
        self.backgroundAudio = backgroundAudio
        self.onPlaybackEnded = onPlaybackEnded
        self.onSaveProgress = onSaveProgress
        _model = StateObject(wrappedValue: KSVideoPlayerModel(
            title: title,
            config: nil,
            options: playback.options,
            url: playback.url,
            subtitleURLs: playback.subtitleURLs.map { URLSubtitleInfo(url: $0) }
        ))
    }

    var body: some View {
        KSVideoPlayerView(model: _model)
            .ignoresSafeArea()
            .onAppear {
                model.config.isMuted = playback.isMuted
                model.config.onPlay = { current, total in
                    finishIfOutroReached(current: current, total: total)
                }
                model.config.onFinish = { layer, error in
                    guard error == nil, !loopPlayback else { return }
                    let total = layer.player.totalTime
                    let current = layer.player.currentTime
                    guard total <= 0 || current >= total - 1 else { return }
                    onPlaybackEnded()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .background, !backgroundAudio else { return }
                model.config.playerLayer?.pause()
            }
            .onDisappear {
                model.config.onPlay = nil
                model.config.onFinish = nil
                guard let layer = model.config.playerLayer else { return }
                // 跳过片尾视为看完，交给上层清除进度记录。
                let total = layer.player.totalTime
                if didReachOutro {
                    onSaveProgress(pickcode, total, total)
                } else {
                    onSaveProgress(pickcode, layer.player.currentTime, total)
                }
            }
    }

    /// 剩余时间不足设定秒数时直接收尾，循环播放优先。
    private func finishIfOutroReached(current: TimeInterval, total: TimeInterval) {
        guard let outroSeconds, !loopPlayback, !didReachOutro else { return }
        guard total > 0, total.isFinite, total - current <= Double(outroSeconds) else { return }

        didReachOutro = true
        model.config.playerLayer?.pause()
        onPlaybackEnded()
    }
}
