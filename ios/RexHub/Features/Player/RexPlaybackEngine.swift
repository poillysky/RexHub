import AVFoundation
import AVKit
import CoreImage
@preconcurrency import KSPlayer
import MediaPlayer
import Observation
import SwiftUI
import UIKit

/// 播放页统一引擎：把 KSPlayer 的状态与操作收敛成一组接口，
/// 控制层只认协议，不关心底层用的哪个播放器。
struct RexMediaTrack: Identifiable, Hashable {
    let id: String
    let title: String
}

/// 播放进度与轨道信息，由内核在后台刷新，SwiftUI 直接观察这里。
@MainActor
@Observable
final class RexPlayerEngineState {
    var currentTime: Double = 0
    var duration: Double = 0
    var buffered: Double = 0
    var isPlaying = false
    var isBuffering = false
    var isPipActive = false
    var rate: Double = 1
    var isMuted = false
    var isAspectFill = false
    /// 视频原始分辨率，用于控制层展示参数。
    var videoSize: CGSize = .zero
    /// 底部参数栏用的基础信息：容器格式、编码、帧率与码率。
    var containerFormat: String?
    var videoCodec: String?
    var frameRate: Double = 0
    var bitrateKbps: Int = 0
    var audioTracks: [RexMediaTrack] = []
    var subtitleTracks: [RexMediaTrack] = []
    var selectedAudioID: String?
    var selectedSubtitleID: String?
    /// 当前需要显示的字幕文本，由内核按播放进度同步。
    var subtitleText: String = ""
    /// 内核致命错误，播放页据此显示失败原因，避免资源出问题时一直停在黑屏。
    var failureMessage: String?
}

@MainActor
protocol RexPlaybackEngine: AnyObject {
    var state: RexPlayerEngineState { get }
    var canPiP: Bool { get }
    var canAirPlay: Bool { get }

    /// 每 0.2～0.25 秒回调一次，用于字幕与片尾判定。
    var onTick: ((Double, Double) -> Void)? { get set }
    /// 自然播放结束（循环由播放页统一处理，内核不自行循环）。
    var onEnded: (() -> Void)? { get set }

    func play()
    func pause()
    func seek(to seconds: Double)
    func setRate(_ rate: Double)
    func setMuted(_ muted: Bool)
    func setAspectFill(_ fill: Bool)
    func selectAudio(_ id: String?)
    func selectSubtitle(_ id: String?)
    func setSubtitleEnabled(_ enabled: Bool)
    func setSubtitleDelay(_ delay: Double)
    func refreshTracks()
    func togglePiP()
    /// 抓取当前帧，截图入口使用。
    func snapshot() async -> UIImage?
    func teardown()
}

// MARK: - KSPlayer 内核

/// 只把 KSPlayer 当渲染与解码内核：画面、内嵌字幕由它输出，其余交互全部交给统一控制层。
@MainActor
final class KSPlayerEngine: RexPlaybackEngine {
    let state = RexPlayerEngineState()
    let coordinator: KSVideoPlayer.Coordinator
    let url: URL
    let options: KSOptions
    var onTick: ((Double, Double) -> Void)?
    var onEnded: (() -> Void)?

    /// KSPlayer 的复杂图层支持系统画中画（以样例缓冲区图层作为内容源）。
    var canPiP: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    var canAirPlay: Bool { false }

    private let subtitleURLs: [URL]
    private var didAddSubtitles = false
    private var lastTickTime: Double = -1
    /// 内核应用 `startPlayTime` 之前的回调会从 0 开始，先忽略这些值，进度条才不会被拽回开头。
    private var pendingStartTime: Double = 0
    /// seek 补试任务：内核在可 seek 窗口未就绪时会静默丢弃 seek。
    private var seekRetryTask: Task<Void, Never>?
    private var disposed = false

    init(url: URL, options: KSOptions, subtitleURLs: [URL], rate: Double, isMuted: Bool) {
        self.url = url
        self.options = options
        self.subtitleURLs = subtitleURLs
        self.coordinator = KSVideoPlayer.Coordinator()
        pendingStartTime = max(0, options.startPlayTime)
        state.rate = rate
        state.isMuted = isMuted
        state.isBuffering = true
        state.containerFormat = rexContainerFormat(url: url)
        bind()
    }

    func play() {
        coordinator.playerLayer?.play()
        coordinator.playbackRate = Float(state.rate)
        state.isPlaying = true
    }

    func pause() {
        coordinator.playerLayer?.pause()
        state.isPlaying = false
    }

    func seek(to seconds: Double) {
        let target = clamp(seconds, upper: state.duration)
        state.currentTime = target
        pendingStartTime = 0
        coordinator.seek(time: target)
        // 内核在可 seek 窗口未就绪时只记下目标、不再重试，表现就是拖到未缓冲处
        // 停住不起播。这里短暂补试，直到内核接受 seek 或位置落到目标附近。
        retrySeekIfNeeded(target)
    }

    /// 补试 seek：`KSPlayerLayer.seek` 只在 `player.seekable` 为真时真正下发给 AVPlayer，
    /// 否则静默记下目标就返回，之后没有任何时机再补。拖到未缓冲区域正是这条路径。
    /// 这里按小步轮询，等可 seek 窗口覆盖目标后再下发一次。
    private func retrySeekIfNeeded(_ target: Double) {
        seekRetryTask?.cancel()
        let wasPlaying = coordinator.playerLayer?.player.isPlaying ?? state.isPlaying
        seekRetryTask = Task { [weak self] in
            for _ in 0..<16 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !self.disposed, !Task.isCancelled else { return }
                guard let layer = self.coordinator.playerLayer else { continue }
                // 已经落位就不必再补。
                if abs(layer.player.currentPlaybackTime - target) < 1.5 { return }
                guard layer.player.isReadyToPlay, layer.player.seekable else { continue }
                self.coordinator.seek(time: target)
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !self.disposed, !Task.isCancelled else { return }
                if wasPlaying, self.coordinator.playerLayer?.player.isPlaying == false {
                    self.play()
                }
                return
            }
        }
    }

    func setRate(_ rate: Double) {
        state.rate = rate
        guard state.isPlaying else { return }
        coordinator.playbackRate = Float(rate)
    }

    func setMuted(_ muted: Bool) {
        coordinator.isMuted = muted
        state.isMuted = muted
    }

    func setAspectFill(_ fill: Bool) {
        state.isAspectFill = fill
        coordinator.isScaleAspectFill = fill
    }

    func selectAudio(_ id: String?) {
        guard let layer = coordinator.playerLayer,
              let index = trackIndex(id) else { return }
        let tracks = layer.player.tracks(mediaType: .audio)
        guard tracks.indices.contains(index) else { return }
        // MediaPlayerProtocol.select(track:) 使用泛型不透明参数，无法直接传入存在类型；
        // 这里按协议语义手动切换轨道启用状态（与 KSPlayer 内部实现一致）。
        for track in tracks {
            track.isEnabled = false
        }
        tracks[index].isEnabled = true
        state.selectedAudioID = id
    }

    func selectSubtitle(_ id: String?) {
        let model = coordinator.subtitleModel
        guard let id else {
            model.selectedSubtitleInfo = nil
            state.selectedSubtitleID = nil
            return
        }
        guard let index = trackIndex(id), model.subtitleInfos.indices.contains(index) else { return }
        model.selectedSubtitleInfo = model.subtitleInfos[index]
        state.selectedSubtitleID = id
    }

    func setSubtitleEnabled(_ enabled: Bool) {
        let model = coordinator.subtitleModel
        if !enabled {
            model.selectedSubtitleInfo = nil
            state.selectedSubtitleID = nil
            return
        }
        refreshTracks()
        if state.selectedSubtitleID == nil, !model.subtitleInfos.isEmpty {
            model.selectedSubtitleInfo = model.subtitleInfos[0]
            state.selectedSubtitleID = "subtitle-0"
        }
    }

    func setSubtitleDelay(_ delay: Double) {
        coordinator.subtitleModel.subtitleDelay = delay
    }

    func refreshTracks() {
        guard let layer = coordinator.playerLayer else { return }

        let audio = layer.player.tracks(mediaType: .audio)
        state.audioTracks = audio.enumerated().map { index, track in
            let name = track.name.isEmpty ? "音轨 \(index + 1)" : track.name
            return RexMediaTrack(id: "audio-\(index)", title: name)
        }
        state.selectedAudioID = audio.firstIndex(where: { $0.isEnabled }).map { "audio-\($0)" }

        let subtitles = coordinator.subtitleModel.subtitleInfos
        state.subtitleTracks = subtitles.enumerated().map { index, info in
            let name = info.name.isEmpty ? "字幕 \(index + 1)" : info.name
            return RexMediaTrack(id: "subtitle-\(index)", title: name)
        }
        if let selected = coordinator.subtitleModel.selectedSubtitleInfo,
           let index = subtitles.firstIndex(where: { $0.subtitleID == selected.subtitleID }) {
            state.selectedSubtitleID = "subtitle-\(index)"
        } else {
            state.selectedSubtitleID = nil
        }
    }

    /// 读取内核暴露的视频参数，填充底部信息栏。
    private func loadMetadata(from player: any MediaPlayerProtocol) {
        if let track = player.tracks(mediaType: .video).first {
            state.videoCodec = rexCodecName(track.codecType)
            if track.nominalFrameRate > 0 {
                state.frameRate = Double(track.nominalFrameRate)
            }
        }
        if state.videoSize.width < 1, player.naturalSize.width > 0 {
            state.videoSize = player.naturalSize
        }
        let bitrate = player.dynamicInfo?.videoBitrate ?? 0
        if bitrate > 0 {
            state.bitrateKbps = bitrate / 1000
        }
        state.containerFormat = rexContainerFormat(url: url)
    }

    func togglePiP() {
        guard let layer = coordinator.playerLayer, layer.player.pipController != nil else { return }
        layer.isPipActive.toggle()
    }

    func snapshot() async -> UIImage? {
        guard let image = await coordinator.playerLayer?.player.thumbnailImageAtCurrentTime() else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    func teardown() {
        guard !disposed else { return }
        disposed = true
        seekRetryTask?.cancel()
        seekRetryTask = nil
        onTick = nil
        onEnded = nil
        coordinator.onStateChanged = nil
        coordinator.onPlay = nil
        coordinator.onFinish = nil
        if let layer = coordinator.playerLayer, layer.isPipActive {
            layer.isPipActive = false
        }
        coordinator.playerLayer?.pause()
        coordinator.resetPlayer()
    }

    // MARK: 绑定内核回调

    private func bind() {
        coordinator.onStateChanged = { [weak self] layer, playerState in
            guard let self, !self.disposed else { return }
            // 解码失败时把原因抛给播放页，由播放页自动换软解重开一次。
            if playerState == .error {
                self.state.failureMessage = "当前片源无法解码播放"
                return
            }
            self.applyKernelSettings(layer.player)
            self.state.isPlaying = layer.player.isPlaying
            self.state.isBuffering = playerState == .buffering || playerState == .preparing
            self.state.duration = layer.player.duration
            self.state.buffered = layer.player.playableTime

            if playerState == .readyToPlay {
                self.coordinator.isMuted = self.state.isMuted
                self.coordinator.isScaleAspectFill = self.state.isAspectFill
                if layer.player.naturalSize.width > 0 {
                    self.state.videoSize = layer.player.naturalSize
                }
                self.loadMetadata(from: layer.player)
                self.addExternalSubtitlesIfNeeded()
                self.refreshTracks()
                self.applySubtitlePreferences()
                // 旧版只有 FFmpeg 内核认 startPlayTime，AVPlayer 内核要显式跳到续播位置。
                if self.pendingStartTime > 0, layer.player is KSAVPlayer {
                    self.coordinator.seek(time: self.pendingStartTime)
                }
            }
        }

        coordinator.onPlay = { [weak self] current, total in
            guard let self, !self.disposed else { return }
            self.syncSubtitleText(at: current)
            if total.isFinite, total > 0 {
                self.state.duration = total
            }
            // 续播 seek 还没生效时内核会先回 0，这段时间保持界面停在记录位置。
            if current.isFinite, self.pendingStartTime == 0 || current >= self.pendingStartTime - 2 {
                self.state.currentTime = current
                self.pendingStartTime = 0
            }
            if let layer = self.coordinator.playerLayer {
                self.state.buffered = layer.player.playableTime
                self.state.isPlaying = layer.player.isPlaying
                self.state.isPipActive = layer.isPipActive
            }
            guard abs(current - self.lastTickTime) >= 0.2 else { return }
            self.lastTickTime = current
            self.onTick?(self.state.currentTime, self.state.duration)
        }

        coordinator.onFinish = { [weak self] layer, error in
            guard let self, !self.disposed, error == nil else { return }
            self.state.isPlaying = false
            self.state.currentTime = layer.player.currentPlaybackTime
            self.onEnded?()
        }
    }

    private func addExternalSubtitlesIfNeeded() {
        guard !didAddSubtitles, !subtitleURLs.isEmpty else { return }
        didAddSubtitles = true
        coordinator.subtitleModel.addSubtitle(dataSouce: URLSubtitleDataSouce(urls: subtitleURLs))
    }

    private func applySubtitlePreferences() {
        let model = coordinator.subtitleModel
        model.subtitleDelay = PlayerSettingsStore.shared.subtitleDelay
        if !PlayerSettingsStore.shared.subtitlesEnabled {
            model.selectedSubtitleInfo = nil
        }
    }

    /// KSPlayer 的 `KSVideoPlayer` 只往图层输出画面，字幕需要我们自己画。
    /// 这里按当前进度取一次字幕文本，交给控制层统一渲染，样式设置才能生效。
    private func syncSubtitleText(at time: TimeInterval) {
        guard PlayerSettingsStore.shared.subtitlesEnabled else {
            if !state.subtitleText.isEmpty { state.subtitleText = "" }
            return
        }
        let model = coordinator.subtitleModel
        _ = model.subtitle(currentTime: time)
        let text = model.parts.compactMap { $0.text?.string }.joined(separator: "\n")
        if text != state.subtitleText {
            state.subtitleText = text
        }
    }

    /// KSAVPlayer 内部的 AVPlayer 不读我们的设置，图层就绪后把这些偏好补写进去：
    /// 自动等待缓冲、变速保调（直链原分辨率播放，不做缩放）。
    private func applyKernelSettings(_ player: any MediaPlayerProtocol) {
        guard let avPlayer = player as? KSAVPlayer else { return }
        avPlayer.player.automaticallyWaitsToMinimizeStalling = true
        guard let item = avPlayer.player.currentItem else { return }
        item.audioTimePitchAlgorithm = PlayerSettingsStore.shared.keepPitch ? .spectral : .varispeed
    }

    private func trackIndex(_ id: String?) -> Int? {
        guard let id, let raw = id.split(separator: "-").last else { return nil }
        return Int(raw)
    }

    private func clamp(_ value: Double, upper: Double) -> Double {
        min(max(value, 0), max(upper, 0))
    }
}

// MARK: - 媒体信息

/// 从直链推断容器格式，用于底部参数栏。
private func rexContainerFormat(url: URL?) -> String? {
    guard let url else { return nil }
    switch url.pathExtension.lowercased() {
    case "": return nil
    case "m3u8": return "HLS"
    case "mpd": return "DASH"
    case "m2ts": return "M2TS"
    case let ext: return ext.uppercased()
    }
}

/// 把视频编码的 FourCC 转成常见叫法，例如 `avc1` → `H264`。
private func rexCodecName(_ code: FourCharCode) -> String? {
    switch rexFourCCString(code) {
    case "avc1", "avc3": return "H264"
    case "hvc1", "hev1": return "H265"
    case "vp09": return "VP9"
    case "av01": return "AV1"
    case "mp4v": return "MPEG-4"
    case let text where !text.isEmpty: return text
    default: return nil
    }
}

private func rexFourCCString(_ code: FourCharCode) -> String {
    let bytes: [UInt8] = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff)
    ]
    return (String(bytes: bytes, encoding: .ascii) ?? "")
        .trimmingCharacters(in: .whitespaces)
}

// MARK: - 系统能力

/// 通过隐藏的 `MPVolumeView` 调节系统输出音量，App 不额外保存音量值。
@MainActor
enum RexSystemVolume {
    private static var slider: UISlider?

    static var current: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    static func set(_ value: Float) {
        guard let slider = resolveSlider() else { return }
        slider.value = min(max(value, 0), 1)
        slider.sendActions(for: .touchUpInside)
    }

    private static func resolveSlider() -> UISlider? {
        if let slider {
            return slider
        }

        let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else { return nil }

        window.addSubview(view)
        let found = view.subviews.compactMap { $0 as? UISlider }.first
        slider = found
        return found
    }
}

/// 系统 AirPlay 路由按钮，只在 AVPlayer 内核下显示。
struct RexAirPlayView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .white
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
