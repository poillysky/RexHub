import Foundation
import os

/// 统一日志出口：Console.app 或 `log stream --subsystem com.poilly.RexHub` 按 category 过滤。
/// 只记录元信息（路径、状态码、耗时、阶段），不记录 token 与响应体。
enum RexLog {
    private static let subsystem = "com.poilly.RexHub"

    static let network = Logger(subsystem: subsystem, category: "network")
    static let session = Logger(subsystem: subsystem, category: "session")
    static let playback = Logger(subsystem: subsystem, category: "playback")
}
