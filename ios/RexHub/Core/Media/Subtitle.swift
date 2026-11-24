import Foundation

/// 把配置的字幕源模板展开成可下载的地址，交给 KSPlayer 自行载入与渲染。
enum SubtitleLoader {
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
