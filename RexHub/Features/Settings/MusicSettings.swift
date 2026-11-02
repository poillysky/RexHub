import Foundation
import Observation

/// 音乐播放列表范围：单曲只播当前文件，目录从选中歌曲开始顺序播放同目录歌曲。
enum MusicPlaylistMode: String, CaseIterable, Identifiable {
    case single
    case folder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .single: "单曲播放"
        case .folder: "目录"
        }
    }

    var summary: String {
        switch self {
        case .single: "只播放当前选中的歌曲。"
        case .folder: "播放当前目录下的所有歌曲，从选中的歌曲开始。"
        }
    }
}

/// 音乐播放器偏好，独立于视频设置，改动即时落盘。
@Observable
final class MusicSettingsStore {
    static let shared = MusicSettingsStore()

    static let playbackRates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    private enum Key {
        static let playlistMode = "rex.music.playlistMode"
        static let blurCover = "rex.music.blurCover"
        static let rewindSeconds = "rex.music.rewindSeconds"
        static let forwardSeconds = "rex.music.forwardSeconds"
        static let playbackRate = "rex.music.playbackRate"
    }

    var playlistMode: MusicPlaylistMode {
        didSet { defaults.set(playlistMode.rawValue, forKey: Key.playlistMode) }
    }

    /// 有封面图时铺满背景并模糊处理。
    var blurCover: Bool {
        didSet { defaults.set(blurCover, forKey: Key.blurCover) }
    }

    var rewindSeconds: Int {
        didSet { defaults.set(rewindSeconds, forKey: Key.rewindSeconds) }
    }

    var forwardSeconds: Int {
        didSet { defaults.set(forwardSeconds, forKey: Key.forwardSeconds) }
    }

    var playbackRate: Double {
        didSet { defaults.set(playbackRate, forKey: Key.playbackRate) }
    }

    private let defaults = UserDefaults.standard

    private init() {
        let defaults = UserDefaults.standard

        playlistMode = MusicPlaylistMode(
            rawValue: defaults.string(forKey: Key.playlistMode) ?? ""
        ) ?? .folder
        blurCover = defaults.object(forKey: Key.blurCover) == nil
            ? true
            : defaults.bool(forKey: Key.blurCover)
        rewindSeconds = Self.seconds(defaults, Key.rewindSeconds)
        forwardSeconds = Self.seconds(defaults, Key.forwardSeconds)

        let storedRate = defaults.object(forKey: Key.playbackRate) as? Double ?? 1
        playbackRate = Self.playbackRates.contains(storedRate) ? storedRate : 1
    }

    /// 跳跃秒数统一夹在 5…60，避免历史脏数据。
    private static func seconds(_ defaults: UserDefaults, _ key: String) -> Int {
        guard defaults.object(forKey: key) != nil else { return 10 }
        return min(max(defaults.integer(forKey: key), 5), 60)
    }
}
