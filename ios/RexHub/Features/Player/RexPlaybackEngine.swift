import AVFoundation
import AVKit
import CoreImage
import KSPlayer
import MediaPlayer
import Observation
import SwiftUI
import UIKit

/// 播放页统一引擎：AVPlayer 与 KSPlayer 都通过这一层暴露同一组状态与操作，
/// 控制层只认协议，不关心底层用的是哪个内核。
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

// MARK: - AVPlayer 内核

@MainActor
final class AVPlayerEngine: NSObject, RexPlaybackEngine {
    let state = RexPlayerEngineState()
    let player: AVPlayer
    var onTick: ((Double, Double) -> Void)?
    var onEnded: (() -> Void)?

    var canPiP: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    var canAirPlay: Bool { true }

    private var timeToken: Any?
    private var endToken: NSObjectProtocol?
    private var failureToken: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var pipController: AVPictureInPictureController?
    private weak var playerLayer: AVPlayerLayer?
    /// 画面层挂上之前的播放意图：`AVPlayerLayer` 还没进窗口就开始播放会丢掉首帧，
    /// 之后一直黑屏且不报错，所以真正起播推迟到 `attach(playerLayer:)` 之后。
    private var awaitingLayerToPlay = false
    private var audioGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    /// 截图用的帧输出，HLS 等流媒体无法用 `AVAssetImageGenerator` 取帧时兜底。
    /// 只在截图时临时挂到播放项上，常驻会让解码管线多一路输出，HDR 片源还会导致画面黑屏。
    private let snapshotOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    private var disposed = false

    init(player: AVPlayer, rate: Double) {
        self.player = player
        super.init()
        state.rate = rate
        state.isMuted = player.isMuted
        // 容器格式按直链扩展名展示。
        state.containerFormat = rexContainerFormat(url: (player.currentItem?.asset as? AVURLAsset)?.url)
        observe()
        Task { await loadTracks() }
    }

    /// 画面层建好后回调，画中画需要真实的 `AVPlayerLayer`。
    func attach(playerLayer: AVPlayerLayer) {
        self.playerLayer = playerLayer
        playerLayer.videoGravity = state.isAspectFill ? .resizeAspectFill : .resizeAspect
        makePipControllerIfNeeded()
        // 画面层就绪前点过的播放，到这里才真正开始，避免首帧被丢弃导致黑屏。
        guard awaitingLayerToPlay else { return }
        awaitingLayerToPlay = false
        player.playImmediately(atRate: Float(state.rate))
    }

    /// 画面层就绪后再创建画中画控制器；首次创建失败时，点击按钮还会再试一次。
    private func makePipControllerIfNeeded() {
        guard pipController == nil,
              AVPictureInPictureController.isPictureInPictureSupported(),
              let playerLayer,
              let controller = AVPictureInPictureController(playerLayer: playerLayer) else { return }
        controller.delegate = self
        pipController = controller
        state.isPipActive = controller.isPictureInPictureActive
    }

    func play() {
        // 立即进入加载态，首帧出来前不闪播放按钮；首次进度回调会校正真实状态。
        state.isBuffering = true
        state.isPlaying = true
        // 画面层还没挂上时先记下播放意图，等 attach 后再真正起播。
        guard playerLayer != nil else {
            awaitingLayerToPlay = true
            return
        }
        player.playImmediately(atRate: Float(state.rate))
    }

    func pause() {
        player.pause()
        state.isPlaying = false
    }

    func seek(to seconds: Double) {
        let target = clamp(seconds, upper: state.duration)
        state.currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func setRate(_ rate: Double) {
        state.rate = rate
        guard player.timeControlStatus == .playing else { return }
        player.rate = Float(rate)
    }

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
        state.isMuted = muted
    }

    func setAspectFill(_ fill: Bool) {
        state.isAspectFill = fill
        playerLayer?.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }

    func selectAudio(_ id: String?) {
        guard let group = audioGroup, let item = player.currentItem else { return }
        guard let index = trackIndex(id), group.options.indices.contains(index) else { return }
        item.select(group.options[index], in: group)
        state.selectedAudioID = id
    }

    func selectSubtitle(_ id: String?) {
        guard let group = legibleGroup, let item = player.currentItem else { return }
        guard let id else {
            item.select(nil, in: group)
            state.selectedSubtitleID = nil
            return
        }
        guard let index = trackIndex(id), group.options.indices.contains(index) else { return }
        item.select(group.options[index], in: group)
        state.selectedSubtitleID = id
    }

    func setSubtitleEnabled(_ enabled: Bool) {
        if !enabled {
            selectSubtitle(nil)
        } else if state.selectedSubtitleID == nil, !state.subtitleTracks.isEmpty {
            selectSubtitle(state.subtitleTracks[0].id)
        }
    }

    /// 外部字幕的延迟由播放页叠加在时间轴上，这里不需要处理。
    func setSubtitleDelay(_ delay: Double) {}

    func refreshTracks() {
        Task { await loadTracks() }
    }

    func togglePiP() {
        makePipControllerIfNeeded()
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
    }

    func snapshot() async -> UIImage? {
        // 优先取当前正在显示的帧，暂停、逐帧、流媒体都能拿到；
        // 取不到时再退回资源抽帧（对本地与直链 mp4 更稳）。
        if let image = await snapshotFromOutput() {
            return image
        }
        guard let asset = player.currentItem?.asset else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        do {
            let (image, _) = try await generator.image(at: player.currentTime())
            return UIImage(cgImage: image)
        } catch {
            return nil
        }
    }

    /// 从帧输出取当前画面，并按视频轨的旋转信息摆正。
    private func snapshotFromOutput() async -> UIImage? {
        guard let item = player.currentItem else { return nil }

        // 帧输出只在截图时挂上，取完立即摘掉，避免影响正常渲染。
        item.add(snapshotOutput)
        defer { item.remove(snapshotOutput) }
        snapshotOutput.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.1)
        // 刚挂上时还没有可用帧，等一次输出刷新再取。
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !disposed else { return nil }

        let time = player.currentTime()
        guard let buffer = snapshotOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
            return nil
        }

        var image = CIImage(cvPixelBuffer: buffer)
        if let track = try? await item.asset.loadTracks(withMediaType: .video).first,
           let transform = try? await track.load(.preferredTransform),
           transform != .identity {
            image = image.transformed(by: transform)
        }
        let extent = image.extent
        image = image.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    func teardown() {
        guard !disposed else { return }
        disposed = true
        onTick = nil
        onEnded = nil

        if let timeToken {
            player.removeTimeObserver(timeToken)
        }
        timeToken = nil

        if let endToken {
            NotificationCenter.default.removeObserver(endToken)
        }
        endToken = nil

        if let failureToken {
            NotificationCenter.default.removeObserver(failureToken)
        }
        failureToken = nil

        statusObservation?.invalidate()
        statusObservation = nil

        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
        pipController?.delegate = nil
        pipController = nil
        player.currentItem?.remove(snapshotOutput)
        player.pause()
    }

    // MARK: 观测

    private func observe() {
        timeToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.handleTick(time.seconds)
            }
        }

        endToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onEnded?()
            }
        }

        guard let item = player.currentItem else { return }
        // 资源本身解不了时 AVPlayer 只会停在黑屏，这里把原因抛给播放页。
        statusObservation = item.observe(\.status, options: [.new]) { item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "视频无法解码，可切换 KSPlayer 内核重试"
            Task { @MainActor [weak self] in
                guard let self, !self.disposed else { return }
                self.state.failureMessage = message
            }
        }

        failureToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let message = error?.localizedDescription ?? "播放中断，请重试"
            MainActor.assumeIsolated {
                guard let self, !self.disposed else { return }
                self.state.failureMessage = message
            }
        }
    }

    private func handleTick(_ seconds: Double) {
        guard !disposed else { return }

        if seconds.isFinite {
            state.currentTime = seconds
        }

        let itemDuration = player.currentItem?.duration.seconds ?? 0
        if itemDuration.isFinite, itemDuration > 0 {
            state.duration = itemDuration
        }

        state.buffered = bufferedTime()
        state.isPlaying = player.timeControlStatus == .playing
        state.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        state.isPipActive = pipController?.isPictureInPictureActive ?? false

        if let size = player.currentItem?.presentationSize, size.width > 0 {
            state.videoSize = size
        }

        // HLS 等流媒体的码率拿不到轨道信息时，从访问日志里补一次。
        if state.bitrateKbps == 0, let event = player.currentItem?.accessLog()?.events.last {
            let bitrate = event.indicatedBitrate > 0 ? event.indicatedBitrate : event.observedBitrate
            if bitrate > 0 {
                state.bitrateKbps = Int((bitrate / 1000).rounded())
            }
        }

        onTick?(state.currentTime, state.duration)
    }

    private func bufferedTime() -> Double {
        // 拖动进度后可能出现多段已缓冲区间，取最远的那段末尾，缓冲条才不会回缩。
        let ranges = player.currentItem?.loadedTimeRanges ?? []
        let end = ranges.reduce(0.0) { result, value in
            let range = value.timeRangeValue
            let rangeEnd = range.start.seconds + range.duration.seconds
            return rangeEnd.isFinite ? max(result, rangeEnd) : result
        }
        return end
    }

    // MARK: 轨道

    private func loadTracks() async {
        guard let asset = player.currentItem?.asset else { return }

        let audio = try? await asset.loadMediaSelectionGroup(for: .audible)
        let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
        let videoTrack = try? await asset.loadTracks(withMediaType: .video).first
        guard !disposed else { return }

        if let videoTrack {
            await loadVideoMetadata(from: videoTrack)
        }

        audioGroup = audio
        legibleGroup = legible

        let selection = player.currentItem?.currentMediaSelection

        state.audioTracks = (audio?.options ?? []).enumerated().map { index, option in
            RexMediaTrack(id: "audio-\(index)", title: trackTitle(option))
        }
        state.selectedAudioID = matchedTrackID(
            in: audio,
            selected: audio.flatMap { selection?.selectedMediaOption(in: $0) },
            prefix: "audio"
        )

        state.subtitleTracks = (legible?.options ?? []).enumerated().map { index, option in
            RexMediaTrack(id: "subtitle-\(index)", title: trackTitle(option))
        }
        state.selectedSubtitleID = matchedTrackID(
            in: legible,
            selected: legible.flatMap { selection?.selectedMediaOption(in: $0) },
            prefix: "subtitle"
        )
    }

    /// 读取视频轨的分辨率、帧率、码率与编码，填充底部参数栏。
    private func loadVideoMetadata(from track: AVAssetTrack) async {
        let size = try? await track.load(.naturalSize)
        let frameRate = try? await track.load(.nominalFrameRate)
        let dataRate = try? await track.load(.estimatedDataRate)
        let descriptions = try? await track.load(.formatDescriptions)
        guard !disposed else { return }

        if let size, size.width >= 1, state.videoSize.width < 1 {
            state.videoSize = size
        }
        if let frameRate, frameRate > 0 {
            state.frameRate = Double(frameRate)
        }
        if let dataRate, dataRate > 0 {
            state.bitrateKbps = Int((dataRate / 1000).rounded())
        }
        if let descriptions, let description = descriptions.first {
            state.videoCodec = rexCodecName(CMFormatDescriptionGetMediaSubType(description))
        }
    }

    private func matchedTrackID(
        in group: AVMediaSelectionGroup?,
        selected: AVMediaSelectionOption?,
        prefix: String
    ) -> String? {
        guard let group, let selected,
              let index = group.options.firstIndex(of: selected) else { return nil }
        return "\(prefix)-\(index)"
    }

    private func trackTitle(_ option: AVMediaSelectionOption) -> String {
        if let locale = option.locale,
           let name = locale.localizedString(forIdentifier: locale.identifier) {
            return name
        }
        return option.displayName
    }

    private func trackIndex(_ id: String?) -> Int? {
        guard let id, let raw = id.split(separator: "-").last else { return nil }
        return Int(raw)
    }

    private func clamp(_ value: Double, upper: Double) -> Double {
        min(max(value, 0), max(upper, 0))
    }
}

// MARK: 画中画回调

extension AVPlayerEngine: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        state.isPipActive = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        state.isPipActive = false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        state.isPipActive = false
    }

    /// 点击画中画窗口的「回到 App」时，系统需要控制器确认可以恢复播放页。
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
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
        layer.player.select(track: tracks[index])
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

// MARK: - AVPlayer 画面层

struct RexAVPlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let onLayerReady: (AVPlayerLayer) -> Void

    func makeUIView(context: Context) -> RexPlayerLayerView {
        let view = RexPlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.configure(player: player, onAttach: onLayerReady)
        return view
    }

    func updateUIView(_ uiView: RexPlayerLayerView, context: Context) {
        uiView.configure(player: player, onAttach: onLayerReady)
    }

    final class RexPlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer {
            // layerClass 已固定为 AVPlayerLayer，这里不可能失败。
            layer as! AVPlayerLayer
        }

        private var player: AVPlayer?
        private var onAttach: ((AVPlayerLayer) -> Void)?
        private var didNotify = false

        func configure(player: AVPlayer, onAttach: @escaping (AVPlayerLayer) -> Void) {
            self.player = player
            if !didNotify {
                self.onAttach = onAttach
            }
            bindIfPossible()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            bindIfPossible()
        }

        /// 必须在挂到窗口之后再绑定 player：模拟器上提前绑定会让首帧被丢弃，
        /// 之后进度照走、解码照跑，但画面一直黑屏且不报任何错。
        private func bindIfPossible() {
            guard window != nil, let player else { return }
            if playerLayer.player !== player {
                playerLayer.player = player
            }
            guard !didNotify, let onAttach else { return }
            didNotify = true
            self.onAttach = nil
            DispatchQueue.main.async {
                onAttach(self.playerLayer)
            }
        }
    }
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
