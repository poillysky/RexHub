import CoreFoundation
import Foundation

/// 一条字幕：起止时间与文本，时间为相对视频开头的秒数。
struct SubtitleCue: Identifiable, Equatable, Sendable {
    let id: Int
    let start: TimeInterval
    let end: TimeInterval
    let text: String

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

// MARK: - 解析

enum SubtitleParser {
    /// 自动识别编码与格式，解析失败返回空数组。
    static func parse(data: Data) -> [SubtitleCue] {
        guard let text = decode(data) else { return [] }
        return parse(text: text)
    }

    static func parse(text: String) -> [SubtitleCue] {
        if text.contains("[Events]"), text.contains("Dialogue:") {
            return parseASS(text)
        }
        return parseSRTOrVTT(text)
    }

    /// 字幕文件常见 UTF-8 / UTF-16 / GB18030，按顺序尝试。
    private static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }

        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        return String(data: data, encoding: gb18030)
    }

    private static func parseSRTOrVTT(_ text: String) -> [SubtitleCue] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var cues: [SubtitleCue] = []
        let blocks = normalized.components(separatedBy: "\n\n")

        for block in blocks {
            let lines = block
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }

            let times = lines[timeIndex].components(separatedBy: "-->")
            guard times.count == 2,
                  let start = parseTime(times[0]),
                  let end = parseTime(times[1]) else { continue }

            let body = lines[(timeIndex + 1)...]
                .joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }

            cues.append(SubtitleCue(id: cues.count, start: start, end: end, text: body))
        }
        return cues
    }

    /// ASS/SSA：只取 Dialogue 行的时间与文本，样式标签直接剔除。
    private static func parseASS(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Dialogue:") else { continue }

            let payload = line.dropFirst("Dialogue:".count)
            let fields = payload.components(separatedBy: ",")
            guard fields.count >= 10,
                  let start = parseTime(fields[1]),
                  let end = parseTime(fields[2]) else { continue }

            let body = fields[9...]
                .joined(separator: ",")
                .replacingOccurrences(of: "\\[Nn]", with: "\n", options: .regularExpression)
                .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }

            cues.append(SubtitleCue(id: cues.count, start: start, end: end, text: body))
        }
        return cues
    }

    /// 兼容 `00:01:02,500`、`00:01:02.500`、`01:02.500` 与 VTT 附加参数。
    private static func parseTime(_ raw: String) -> TimeInterval? {
        let value = raw
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ")
            .first ?? ""
        let parts = value
            .replacingOccurrences(of: ",", with: ".")
            .components(separatedBy: ":")

        var seconds: Double = 0
        for part in parts {
            guard let number = Double(part) else { return nil }
            seconds = seconds * 60 + number
        }
        return parts.isEmpty ? nil : seconds
    }
}

// MARK: - 加载

enum SubtitleLoader {
    enum LoadError: LocalizedError {
        case invalidSource
        case empty

        var errorDescription: String? {
            switch self {
            case .invalidSource: "字幕地址无效"
            case .empty: "字幕内容为空"
            }
        }
    }

    /// 依次尝试字幕源模板，返回第一个成功解析的结果。
    /// 指定默认语言时，含 `{lang}` 的模板会被优先尝试。
    static func load(
        sources: [String],
        videoName: String,
        language: SubtitleLanguage = .automatic
    ) async -> [SubtitleCue] {
        for template in ordered(sources, language: language) {
            if let cues = try? await load(template: template, videoName: videoName, language: language),
               !cues.isEmpty {
                return cues
            }
        }
        return []
    }

    static func load(
        template: String,
        videoName: String,
        language: SubtitleLanguage = .automatic
    ) async throws -> [SubtitleCue] {
        guard let url = makeURL(template: template, videoName: videoName, language: language) else {
            throw LoadError.invalidSource
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("RexHub/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LoadError.empty
        }

        let cues = SubtitleParser.parse(data: data)
        guard !cues.isEmpty else { throw LoadError.empty }
        return cues
    }

    /// 把字幕源模板展开成可下载的地址，交给 KSPlayer 自行载入。
    static func urls(
        sources: [String],
        videoName: String,
        language: SubtitleLanguage = .automatic
    ) -> [URL] {
        ordered(sources, language: language).compactMap {
            makeURL(template: $0, videoName: videoName, language: language)
        }
    }

    /// 含 `{lang}` 的模板排到前面；自动模式下无法填充语言代码，直接跳过这类模板。
    private static func ordered(_ sources: [String], language: SubtitleLanguage) -> [String] {
        guard language.code != nil else {
            return sources.filter { !$0.contains("{lang}") }
        }
        return sources.filter { $0.contains("{lang}") }
            + sources.filter { !$0.contains("{lang}") }
    }

    private static func makeURL(
        template: String,
        videoName: String,
        language: SubtitleLanguage
    ) -> URL? {
        let encodedName = videoName.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? videoName
        var raw = template.replacingOccurrences(of: "{name}", with: encodedName)

        if raw.contains("{lang}") {
            guard let code = language.code else { return nil }
            raw = raw.replacingOccurrences(of: "{lang}", with: code)
        }

        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}
