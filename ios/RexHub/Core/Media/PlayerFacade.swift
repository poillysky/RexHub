import AVFoundation
@preconcurrency import KSPlayer

/// 播放内核隔离层：业务层只通过这里创建与配置播放器，不直接依赖 AVFoundation 细节。
/// 音乐播放器的 AVPlayer 与视频播放器的 KSPlayer 配置都在本文件生成。
@MainActor
enum PlayerFacade {
    /// 115 直链会校验 UA，必须把服务端给出的请求头一并交给播放内核。
    /// 缓冲策略来自播放器设置，只影响本次新建的播放项。
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

        item.audioTimePitchAlgorithm = settings.keepPitch ? .spectral : .varispeed

        let player = AVPlayer(playerItem: item)
        return player
    }

    /// KSPlayer 内核的配置：请求头、起播进度、倍速与字幕开关一次性写进 `KSOptions`。
    /// 115 直链同样需要带请求头，否则会被 CDN 拒绝。
    static func makeKSOptions(
        for info: PanPlayInfo,
        startTime: Double,
        route: PlaybackRoute
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
        // 拖动进度条后必须自动续播，否则 seek 完成会停在暂停态（HLS 尤其明显）。
        options.isSeekedAutoPlay = true
        // 内嵌字幕是否自动选中；外挂字幕由播放页按开关决定要不要加载。
        options.autoSelectEmbedSubtitle = settings.subtitlesEnabled
        // 旧版内核只有静态开关，字幕字号也走全局模型。
        KSOptions.isAutoPlay = settings.autoPlay
        SubtitleModel.textFontSize = settings.subtitleSize.fontSize

        // FFmpeg 解封装后默认仍交给 VideoToolbox 硬解；
        // 关掉异步解压就等于退回 FFmpeg 纯软解，所以两个开关必须一起设。
        // 硬解建会话失败或解码出错时，KSPlayer 会自动切回 FFmpeg 软解。
        options.hardwareDecode = !route.forceSoftwareDecode
        options.asynchronousDecompression = !route.forceSoftwareDecode
        KSOptions.firstPlayerType = route.usesFFmpegPlayback ? KSMEPlayer.self : KSAVPlayer.self
        return options
    }

    /// 本次播放的路由：要不要走 FFmpeg 解封装、要不要强制纯软解。
    struct PlaybackRoute {
        /// 非系统容器或 AVFoundation 不认的编码，交给 FFmpeg 解封装。
        let usesFFmpegPlayback: Bool
        /// 连 VideoToolbox 都不用，走 FFmpeg 纯软解。
        let forceSoftwareDecode: Bool
    }

    /// 固定使用 KSPlayer 内核，这里只决定解封装与解码器：
    /// - 系统容器（mp4/m4v/mov/m3u8/ts）：`KSAVPlayer` + AVFoundation 硬解。
    /// - mkv/avi 等非系统容器：`KSMEPlayer`（FFmpeg 解封装）+ VideoToolbox 硬解。
    /// - AVFoundation 不认的编码（`hev1` 标记的 HEVC）：同样走 FFmpeg 解封装 + 硬解。
    /// - 只有模拟器没有 HEVC 硬解能力时，才直接锁定 FFmpeg 软解。
    /// 解析阶段判断不了的兼容问题，由播放页在运行期报错后自动换软解重开一次。
    static func resolveRoute(
        for info: PanPlayInfo,
        forceSoftwareDecode: Bool = false
    ) async -> PlaybackRoute {
        if forceSoftwareDecode {
            return PlaybackRoute(usesFFmpegPlayback: true, forceSoftwareDecode: true)
        }

        // 服务端已标明是 HLS：AVPlayer 原生支持 m3u8 + AES-128，不必过 FFmpeg。
        if info.kind.lowercased() == "hls" {
            return PlaybackRoute(usesFFmpegPlayback: false, forceSoftwareDecode: false)
        }

        // 服务端标明 mp4 时以声明为准（插件端口地址没有扩展名，不能靠 URL 后缀判断）。
        let declaredMP4 = info.kind.lowercased() == "mp4"
        let systemPlayable = declaredMP4
            || systemPlayableExtensions.contains(info.url.pathExtension.lowercased())
        guard systemPlayable else {
            return PlaybackRoute(usesFFmpegPlayback: true, forceSoftwareDecode: false)
        }

        guard await avPlayerCanDecode(info) else {
            return PlaybackRoute(
                usesFFmpegPlayback: !isSimulator,
                forceSoftwareDecode: isSimulator
            )
        }

        return PlaybackRoute(usesFFmpegPlayback: false, forceSoftwareDecode: false)
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
