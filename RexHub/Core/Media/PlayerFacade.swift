import AVFoundation
import KSPlayer

/// 播放内核隔离层：业务层只通过这里创建与配置播放器，不直接依赖 AVFoundation 细节。
/// AVPlayer 与 KSPlayer 两套配置都在本文件生成，播放页只负责选择内核。
enum PlayerFacade {
    /// 115 直链会校验 UA，必须把服务端给出的请求头一并交给播放内核。
    /// 缓冲策略与静音起播来自播放器设置，只影响本次新建的播放项。
    static func makePlayer(for info: PanPlayInfo) -> AVPlayer {
        let asset = AVURLAsset(
            url: info.url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": info.headers]
        )
        let item = AVPlayerItem(asset: asset)

        let settings = PlayerSettingsStore.shared
        let buffer = settings.bufferPolicy.forwardBufferDuration
        if buffer > 0 {
            item.preferredForwardBufferDuration = buffer
        }

        if let maxSize = settings.preferredResolution.maxSize {
            item.preferredMaximumResolution = maxSize
        }

        item.audioTimePitchAlgorithm = settings.keepPitch ? .spectral : .varispeed

        let player = AVPlayer(playerItem: item)
        player.isMuted = settings.startMuted
        player.automaticallyWaitsToMinimizeStalling = settings.waitMinimizeStalling
        return player
    }

    /// KSPlayer 内核的配置：请求头、起播进度、倍速与字幕开关一次性写进 `KSOptions`。
    /// 115 直链同样需要带请求头，否则会被 CDN 拒绝。
    static func makeKSOptions(for info: PanPlayInfo, startTime: Double) -> KSOptions {
        let settings = PlayerSettingsStore.shared
        let options = KSOptions()
        options.appendHeader(info.headers)
        options.userAgent = header(info.headers, "user-agent")
        options.referer = header(info.headers, "referer")
        options.isAutoPlay = settings.autoPlay
        options.startPlayRate = Float(settings.playbackRate)
        options.isLoopPlay = settings.loopPlayback
        options.startPlayTime = max(0, startTime)
        options.preferredForwardBufferDuration = settings.bufferPolicy.forwardBufferDuration
        options.subtitleDisable = !settings.subtitlesEnabled
        KSOptions.subtitleFontSize = Double(settings.subtitleSize.fontSize)

        switch settings.decodeMode {
        case .automatic:
            break
        case .hardware:
            options.videoDecodeType = .videotoolbox
        case .software:
            options.videoDecodeType = .software
        }

        // AVPlayer 解不了的容器直接交给 FFmpeg，省掉一次失败重试。
        let ext = info.url.pathExtension.lowercased()
        if !systemPlayableExtensions.contains(ext) {
            options.playerTypes = [KSMEPlayer.self]
        }
        return options
    }

    /// 实际生效的内核：自动模式按容器决定，手动选择则照办。
    /// 系统原生容器用 AVPlayer，硬解功耗低、支持画中画与 AirPlay；
    /// 其余容器交给 KSPlayer，由 FFmpeg 软解并渲染内嵌字幕。
    static func resolvedKernel(for info: PanPlayInfo) -> PlayerKernel {
        let selected = PlayerSettingsStore.shared.kernel
        guard selected == .auto else { return selected }
        return systemPlayableExtensions.contains(info.url.pathExtension.lowercased())
            ? .avPlayer
            : .ksPlayer
    }

    /// 系统 AVPlayer 能直接播放的容器；其余交给 FFmpeg。
    private static let systemPlayableExtensions: Set<String> = [
        "mp4", "m4v", "mov", "m3u8", "ts"
    ]

    private static func header(_ headers: [String: String], _ name: String) -> String? {
        headers.first { $0.key.lowercased() == name }?.value
    }

    /// 视频播放走 `.playback`，静音开关不影响声音。
    static func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }
}
