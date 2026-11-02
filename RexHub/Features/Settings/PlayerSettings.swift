import CoreGraphics
import Foundation
import Observation

/// 播放内核：AVPlayer 用系统硬解，KSPlayer 支持 MKV 等容器与内嵌字幕。
enum PlayerKernel: String, CaseIterable, Identifiable {
    case auto
    case avPlayer
    case ksPlayer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "自动"
        case .avPlayer: "AVPlayer"
        case .ksPlayer: "KSPlayer"
        }
    }

    /// 只用于设置页说明，不参与播放决策。
    var summary: String {
        switch self {
        case .auto: "MP4 / MOV / HLS 用 AVPlayer，其余容器走 KSPlayer"
        case .avPlayer: "系统硬解，功耗低，仅支持 MP4 / MOV / HLS"
        case .ksPlayer: "FFmpeg 系，支持 MKV / AVI / RMVB 与内嵌字幕"
        }
    }
}

/// 解码路径偏好：系统内核由 AVFoundation 自动决定，偏好留给后续自定义内核使用。
enum PlayerDecodeMode: String, CaseIterable, Identifiable {
    case automatic
    case hardware
    case software

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "自动"
        case .hardware: "优先硬件"
        case .software: "优先软件"
        }
    }
}

/// 起播缓冲策略，换算成 `AVPlayerItem.preferredForwardBufferDuration`。
enum PlayerBufferPolicy: String, CaseIterable, Identifiable {
    case automatic
    case fastStart
    case smooth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "自动"
        case .fastStart: "快速起播"
        case .smooth: "流畅优先"
        }
    }

    /// 0 表示交给系统决定。
    var forwardBufferDuration: TimeInterval {
        switch self {
        case .automatic: 0
        case .fastStart: 5
        case .smooth: 30
        }
    }
}

/// 起播清晰度上限，交给 `AVPlayerItem.preferredMaximumResolution`。
enum PlayerResolution: String, CaseIterable, Identifiable {
    case automatic
    case p1080
    case p720
    case p480

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "自动"
        case .p1080: "1080P"
        case .p720: "720P"
        case .p480: "480P"
        }
    }

    /// `nil` 表示不限制，由系统按网络情况决定。
    var maxSize: CGSize? {
        switch self {
        case .automatic: nil
        case .p1080: CGSize(width: 1920, height: 1080)
        case .p720: CGSize(width: 1280, height: 720)
        case .p480: CGSize(width: 854, height: 480)
        }
    }
}

/// 字幕字号档位，直接决定播放页字幕的字体大小。
enum SubtitleSize: String, CaseIterable, Identifiable {
    case small
    case standard
    case large
    case huge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "小"
        case .standard: "标准"
        case .large: "大"
        case .huge: "特大"
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .small: 14
        case .standard: 18
        case .large: 22
        case .huge: 26
        }
    }
}

/// 默认字幕语言：自动表示不挑语言，按字幕源顺序取第一个可用的。
enum SubtitleLanguage: String, CaseIterable, Identifiable {
    case automatic
    case chinese
    case english
    case japanese
    case korean

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "自动"
        case .chinese: "中文"
        case .english: "英文"
        case .japanese: "日文"
        case .korean: "韩文"
        }
    }

    /// 替换字幕源里的 `{lang}` 占位符，`nil` 表示自动。
    var code: String? {
        switch self {
        case .automatic: nil
        case .chinese: "zh"
        case .english: "en"
        case .japanese: "ja"
        case .korean: "ko"
        }
    }
}

/// 播放器自身的参数，独立于文件列表设置，改动即时落盘。
@Observable
final class PlayerSettingsStore {
    static let shared = PlayerSettingsStore()

    /// 可选倍速档位。
    static let playbackRates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    private enum Key {
        static let kernel = "rex.player.kernel"
        static let decodeMode = "rex.player.decodeMode"
        static let autoPlay = "rex.player.autoPlay"
        static let playbackRate = "rex.player.playbackRate"
        static let loopPlayback = "rex.player.loopPlayback"
        static let startMuted = "rex.player.startMuted"
        static let bufferPolicy = "rex.player.bufferPolicy"
        static let keepScreenAwake = "rex.player.keepScreenAwake"
        static let preferredResolution = "rex.player.preferredResolution"
        static let waitMinimizeStalling = "rex.player.waitMinimizeStalling"
        static let keepPitch = "rex.player.keepPitch"
        static let resumePlayback = "rex.player.resumePlayback"
        static let autoCloseOnFinish = "rex.player.autoCloseOnFinish"
        static let autoPlayNext = "rex.player.autoPlayNext"
        static let backgroundAudio = "rex.player.backgroundAudio"
        static let rememberVolume = "rex.player.rememberVolume"
        static let rememberBrightness = "rex.player.rememberBrightness"
        static let lastVolume = "rex.player.lastVolume"
        static let lastBrightness = "rex.player.lastBrightness"
        static let skipIntro = "rex.player.skipIntro"
        static let introSeconds = "rex.player.introSeconds"
        static let skipOutro = "rex.player.skipOutro"
        static let outroSeconds = "rex.player.outroSeconds"
        static let positions = "rex.player.positions"
        static let subtitlesEnabled = "rex.player.subtitlesEnabled"
        static let subtitleSources = "rex.player.subtitleSources"
        static let subtitleLanguage = "rex.player.subtitleLanguage"
        static let subtitleSize = "rex.player.subtitleSize"
        static let subtitleBackground = "rex.player.subtitleBackground"
        static let subtitleDelay = "rex.player.subtitleDelay"
    }

    /// 播放内核，下一次起播时生效。
    var kernel: PlayerKernel {
        didSet { defaults.set(kernel.rawValue, forKey: Key.kernel) }
    }

    var decodeMode: PlayerDecodeMode {
        didSet { defaults.set(decodeMode.rawValue, forKey: Key.decodeMode) }
    }

    /// 解析出直链后是否立即起播。
    var autoPlay: Bool {
        didSet { defaults.set(autoPlay, forKey: Key.autoPlay) }
    }

    var playbackRate: Double {
        didSet { defaults.set(playbackRate, forKey: Key.playbackRate) }
    }

    var loopPlayback: Bool {
        didSet { defaults.set(loopPlayback, forKey: Key.loopPlayback) }
    }

    /// 起播时默认静音，交给播放器控制条恢复。
    var startMuted: Bool {
        didSet { defaults.set(startMuted, forKey: Key.startMuted) }
    }

    var bufferPolicy: PlayerBufferPolicy {
        didSet { defaults.set(bufferPolicy.rawValue, forKey: Key.bufferPolicy) }
    }

    /// 播放期间禁止系统自动锁屏。
    var keepScreenAwake: Bool {
        didSet { defaults.set(keepScreenAwake, forKey: Key.keepScreenAwake) }
    }

    /// 起播清晰度上限。
    var preferredResolution: PlayerResolution {
        didSet { defaults.set(preferredResolution.rawValue, forKey: Key.preferredResolution) }
    }

    /// 缓冲不足时先等待而非强行播放。
    var waitMinimizeStalling: Bool {
        didSet { defaults.set(waitMinimizeStalling, forKey: Key.waitMinimizeStalling) }
    }

    /// 变速播放时保持原音调。
    var keepPitch: Bool {
        didSet { defaults.set(keepPitch, forKey: Key.keepPitch) }
    }

    /// 记住每个文件的播放进度，下次续播。
    var resumePlayback: Bool {
        didSet { defaults.set(resumePlayback, forKey: Key.resumePlayback) }
    }

    /// 播放到结尾后自动关闭播放页；开着循环播放时以循环为准。
    var autoCloseOnFinish: Bool {
        didSet { defaults.set(autoCloseOnFinish, forKey: Key.autoCloseOnFinish) }
    }

    /// 当前目录还有下一个视频时，结束后直接播放下一个。
    var autoPlayNext: Bool {
        didSet { defaults.set(autoPlayNext, forKey: Key.autoPlayNext) }
    }

    /// 退到后台后继续播放声音，依赖 Info.plist 的 audio 后台模式。
    var backgroundAudio: Bool {
        didSet { defaults.set(backgroundAudio, forKey: Key.backgroundAudio) }
    }

    /// 起播时恢复上次调节的音量，手势调节后自动记录。
    var rememberVolume: Bool {
        didSet { defaults.set(rememberVolume, forKey: Key.rememberVolume) }
    }

    /// 起播时恢复上次调节的屏幕亮度，手势调节后自动记录。
    var rememberBrightness: Bool {
        didSet { defaults.set(rememberBrightness, forKey: Key.rememberBrightness) }
    }

    var lastVolume: Double {
        didSet { defaults.set(lastVolume, forKey: Key.lastVolume) }
    }

    var lastBrightness: Double {
        didSet { defaults.set(lastBrightness, forKey: Key.lastBrightness) }
    }

    /// 起播时跳过片头，续播进度有效时以进度为准。
    var skipIntro: Bool {
        didSet { defaults.set(skipIntro, forKey: Key.skipIntro) }
    }

    var introSeconds: Int {
        didSet { defaults.set(introSeconds, forKey: Key.introSeconds) }
    }

    /// 剩余时间不足设定秒数时直接结束，配合「播放结束自动关闭」使用。
    var skipOutro: Bool {
        didSet { defaults.set(skipOutro, forKey: Key.skipOutro) }
    }

    var outroSeconds: Int {
        didSet { defaults.set(outroSeconds, forKey: Key.outroSeconds) }
    }

    /// 播放时自动加载字幕。
    var subtitlesEnabled: Bool {
        didSet { defaults.set(subtitlesEnabled, forKey: Key.subtitlesEnabled) }
    }

    /// HTTP 字幕源模板，`{name}` 会替换成视频文件名（不含扩展名）。
    var subtitleSources: [String] {
        didSet { defaults.set(subtitleSources, forKey: Key.subtitleSources) }
    }

    /// 默认字幕语言，含 `{lang}` 的字幕源会排在前面优先尝试。
    var subtitleLanguage: SubtitleLanguage {
        didSet { defaults.set(subtitleLanguage.rawValue, forKey: Key.subtitleLanguage) }
    }

    var subtitleSize: SubtitleSize {
        didSet { defaults.set(subtitleSize.rawValue, forKey: Key.subtitleSize) }
    }

    /// 字幕条以下方半透明底衬托，避免浅色画面看不清。
    var subtitleBackground: Bool {
        didSet { defaults.set(subtitleBackground, forKey: Key.subtitleBackground) }
    }

    /// 正值表示字幕延后出现，负值提前。
    var subtitleDelay: Double {
        didSet { defaults.set(subtitleDelay, forKey: Key.subtitleDelay) }
    }

    private let defaults = UserDefaults.standard

    private init() {
        let defaults = UserDefaults.standard

        kernel = PlayerKernel(
            rawValue: defaults.string(forKey: Key.kernel) ?? ""
        ) ?? .auto
        decodeMode = PlayerDecodeMode(
            rawValue: defaults.string(forKey: Key.decodeMode) ?? ""
        ) ?? .automatic
        autoPlay = Self.bool(defaults, Key.autoPlay, default: true)

        let storedRate = defaults.object(forKey: Key.playbackRate) as? Double ?? 1
        playbackRate = Self.playbackRates.contains(storedRate) ? storedRate : 1

        loopPlayback = Self.bool(defaults, Key.loopPlayback, default: false)
        startMuted = Self.bool(defaults, Key.startMuted, default: false)
        bufferPolicy = PlayerBufferPolicy(
            rawValue: defaults.string(forKey: Key.bufferPolicy) ?? ""
        ) ?? .automatic
        keepScreenAwake = Self.bool(defaults, Key.keepScreenAwake, default: true)
        preferredResolution = PlayerResolution(
            rawValue: defaults.string(forKey: Key.preferredResolution) ?? ""
        ) ?? .automatic
        waitMinimizeStalling = Self.bool(defaults, Key.waitMinimizeStalling, default: true)
        keepPitch = Self.bool(defaults, Key.keepPitch, default: true)
        resumePlayback = Self.bool(defaults, Key.resumePlayback, default: true)
        autoCloseOnFinish = Self.bool(defaults, Key.autoCloseOnFinish, default: true)
        autoPlayNext = Self.bool(defaults, Key.autoPlayNext, default: false)
        backgroundAudio = Self.bool(defaults, Key.backgroundAudio, default: false)
        rememberVolume = Self.bool(defaults, Key.rememberVolume, default: true)
        rememberBrightness = Self.bool(defaults, Key.rememberBrightness, default: true)
        lastVolume = defaults.object(forKey: Key.lastVolume) as? Double ?? 0.7
        lastBrightness = defaults.object(forKey: Key.lastBrightness) as? Double ?? 0.5
        skipIntro = Self.bool(defaults, Key.skipIntro, default: false)
        introSeconds = Self.clampedInt(defaults, Key.introSeconds, default: 90)
        skipOutro = Self.bool(defaults, Key.skipOutro, default: false)
        outroSeconds = Self.clampedInt(defaults, Key.outroSeconds, default: 90)
        subtitlesEnabled = Self.bool(defaults, Key.subtitlesEnabled, default: true)
        subtitleSources = defaults.stringArray(forKey: Key.subtitleSources) ?? []
        subtitleLanguage = SubtitleLanguage(
            rawValue: defaults.string(forKey: Key.subtitleLanguage) ?? ""
        ) ?? .automatic
        subtitleSize = SubtitleSize(
            rawValue: defaults.string(forKey: Key.subtitleSize) ?? ""
        ) ?? .standard
        subtitleBackground = Self.bool(defaults, Key.subtitleBackground, default: true)
        subtitleDelay = defaults.object(forKey: Key.subtitleDelay) as? Double ?? 0
    }

    private static func bool(_ defaults: UserDefaults, _ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    /// 秒数统一夹在 5…600，避免历史脏数据把起播位置顶到片尾。
    private static func clampedInt(_ defaults: UserDefaults, _ key: String, default value: Int) -> Int {
        guard defaults.object(forKey: key) != nil else { return value }
        return min(max(defaults.integer(forKey: key), 5), 600)
    }

    /// 倍速文案，如 `0.5×`、`1.0×`、`1.25×`。
    static func rateText(_ rate: Double) -> String {
        let text = String(format: "%.2f", rate)
        return (text.hasSuffix("0") ? String(text.dropLast()) : text) + "×"
    }

    /// 延迟文案，如 `+1.0 秒`、`-0.5 秒`、`0 秒`。
    static func delayText(_ delay: Double) -> String {
        delay == 0 ? "0 秒" : String(format: "%+.1f 秒", delay)
    }

    func addSubtitleSource(_ template: String) {
        let value = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !subtitleSources.contains(value) else { return }
        subtitleSources.append(value)
    }

    func removeSubtitleSource(_ template: String) {
        subtitleSources.removeAll { $0 == template }
    }

    // MARK: - 播放进度

    /// 已记录的进度，单位秒；无记录返回 0。
    func savedPosition(for key: String) -> Double {
        guard !key.isEmpty else { return 0 }
        return positions()[key] ?? 0
    }

    /// 进度小于 5 秒视为从头播放，直接清除记录。
    func savePosition(_ seconds: Double, for key: String) {
        guard !key.isEmpty, seconds.isFinite else { return }
        var map = positions()
        if seconds < 5 {
            map.removeValue(forKey: key)
        } else {
            map[key] = seconds
        }
        defaults.set(map, forKey: Key.positions)
    }

    private func positions() -> [String: Double] {
        defaults.dictionary(forKey: Key.positions) as? [String: Double] ?? [:]
    }
}
