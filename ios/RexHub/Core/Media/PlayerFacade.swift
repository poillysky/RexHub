import AVFoundation
@preconcurrency import KSPlayer

/// 播放内核隔离层：业务层只通过这里创建与配置播放器，不直接依赖 AVFoundation 细节。
/// AVPlayer 与 KSPlayer 两套配置都在本文件生成，播放页只负责选择内核。
@MainActor
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
    static func makeKSOptions(
        for info: PanPlayInfo,
        startTime: Double,
        forceSoftwareDecode: Bool = false
    ) -> KSOptions {
        let settings = PlayerSettingsStore.shared
        let options = KSOptions()
        options.appendHeader(info.headers)
        options.userAgent = header(info.headers, "user-agent")
        options.referer = header(info.headers, "referer")
        options.isLoopPlay = false
        options.startPlayTime = max(0, startTime)
        options.startPlayRate = Float(settings.playbackRate)
        options.preferredForwardBufferDuration = settings.bufferPolicy.forwardBufferDuration
        // 内嵌字幕是否自动选中；外挂字幕由播放页按开关决定要不要加载。
        options.autoSelectEmbedSubtitle = settings.subtitlesEnabled
        // 旧版内核只有静态开关，字幕字号也走全局模型。
        KSOptions.isAutoPlay = settings.autoPlay
        SubtitleModel.textFontSize = settings.subtitleSize.fontSize

        switch settings.decodeMode {
        case .automatic:
            break
        case .hardware:
            options.hardwareDecode = true
        case .software:
            options.hardwareDecode = false
        }

        // 兜底走 FFmpeg 时强制软解：这类片源本来就是硬解不出来才切过来的，
        // 再交给 VideoToolbox 只会重复失败。
        if forceSoftwareDecode {
            options.hardwareDecode = false
        }

        // AVPlayer 解不了的容器直接交给 FFmpeg，省掉一次失败重试。
        let ext = info.url.pathExtension.lowercased()
        if !systemPlayableExtensions.contains(ext) || forceSoftwareDecode {
            KSOptions.firstPlayerType = KSMEPlayer.self
        } else {
            KSOptions.firstPlayerType = KSAVPlayer.self
        }
        return options
    }

    /// 本次播放的路由：用哪个内核、要不要强制 FFmpeg 软解。
    struct PlaybackRoute {
        let kernel: PlayerKernel
        let forceSoftwareDecode: Bool
    }

    /// 实际生效的内核：自动模式按容器决定，手动选择则照办。
    /// 系统原生容器用 AVPlayer，硬解功耗低、支持画中画与 AirPlay；
    /// 其余容器交给 KSPlayer，由 FFmpeg 软解并渲染内嵌字幕。
    /// HEVC 还要再看一层：AVFoundation 只认 `hvc1` 标记的 H.265，`hev1` 标记的连封装都解不了；
    /// 而模拟器本身没有 HEVC 解码能力，`hvc1` 在模拟器上同样是「进度照走、画面永久黑」。
    /// 这些情况一律改走 FFmpeg 软解。
    static func resolveRoute(for info: PanPlayInfo) async -> PlaybackRoute {
        let selected = PlayerSettingsStore.shared.kernel
        guard selected == .auto else {
            return PlaybackRoute(kernel: selected, forceSoftwareDecode: false)
        }

        guard systemPlayableExtensions.contains(info.url.pathExtension.lowercased()) else {
            return PlaybackRoute(kernel: .ksPlayer, forceSoftwareDecode: false)
        }
        guard await avPlayerCanDecode(info) else {
            return PlaybackRoute(kernel: .ksPlayer, forceSoftwareDecode: true)
        }
        return PlaybackRoute(kernel: .avPlayer, forceSoftwareDecode: false)
    }

    /// 系统 AVPlayer 能直接播放的容器；其余交给 FFmpeg。
    private static let systemPlayableExtensions: Set<String> = [
        "mp4", "m4v", "mov", "m3u8", "ts"
    ]

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// 逐条视频轨判断 AVPlayer 能不能直接解；元数据拿不到时按能播处理，不额外增加失败路径。
    private static func avPlayerCanDecode(_ info: PanPlayInfo) async -> Bool {
        let asset = AVURLAsset(
            url: info.url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": info.headers]
        )
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let formats = try? await track.load(.formatDescriptions) else { return true }
        return formats.allSatisfy { format in
            switch CMFormatDescriptionGetMediaSubType(format) {
            case fourCC("hvc1"):
                return !isSimulator
            case fourCC("hev1"):
                return false
            default:
                return true
            }
        }
    }

    private static func fourCC(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

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
