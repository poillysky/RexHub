import SwiftUI

// MARK: - 文案与时间

/// 详情页格式化：与 PWA `format.ts` 保持同一输出（两位小数 / `YYYY-MM-DD HH:mm`）。
enum ScopeDetailText {
    static func byteSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        let value = Double(bytes)
        let group = min(Int(floor(log(value) / log(1024))), units.count - 1)
        let scaled = value / pow(1024, Double(group))
        return String(format: "%.2f %@", scaled, units[group])
    }

    static func date(_ timestamp: Int64) -> String {
        guard timestamp > 0 else { return "—" }
        let seconds = timestamp < 1_000_000_000_000 ? Double(timestamp) : Double(timestamp) / 1000
        return dateFormatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    /// 对齐 PWA `shortSourceLabel`：`host · 帖子 <tid>` 或 `host + path`。
    static func shortSourceLabel(_ raw: String) -> String {
        guard let url = URL(string: raw), let host = url.host, !host.isEmpty else {
            return raw.count > 42 ? String(raw.prefix(40)) + "…" : raw
        }
        if let tid = threadId(in: raw) {
            return "\(host) · 帖子 \(tid)"
        }
        return host + (url.path == "/" ? "" : url.path)
    }

    private static func threadId(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "thread-(\\d+)") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let found = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[found])
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

// MARK: - 描述解析

struct ScopeDescriptionLine: Identifiable, Hashable {
    let label: String
    let value: String

    var id: String { label }
}

/// 对齐 PWA `formatDescriptionLines`：解析 `【标签】值`，已知标签按固定顺序前置。
enum ScopeDescription {
    private static let preferredOrder = [
        "资源名称", "影片名称", "资源大小", "出演女优",
        "资源类型", "是否有码", "有无水印", "资源数量", "解压密码",
    ]

    private static let aliases: [String: String] = [
        "有无第三方水印": "有无水印",
        "影片容量": "资源大小",
        "影片大小": "资源大小",
        "文件大小": "资源大小",
        "提取密码": "解压密码",
        "资源密码": "解压密码",
        "资源解压密码": "解压密码",
        "影片名稱": "影片名称",
        "資源名稱": "资源名称",
        "女优名称": "出演女优",
        "女优": "出演女优",
        "演员": "出演女优",
        "主演": "出演女优",
    ]

    static func lines(_ description: String) -> [ScopeDescriptionLine] {
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let regex = try? NSRegularExpression(pattern: "^【([^】]+)】(.*)$") else {
            return []
        }

        var seen = Set<String>()
        var known: [ScopeDescriptionLine] = []
        var rest: [ScopeDescriptionLine] = []

        for rawLine in description.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  match.numberOfRanges > 2,
                  let labelRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line) else { continue }

            let rawLabel = String(line[labelRange]).trimmingCharacters(in: .whitespaces)
            guard !rawLabel.isEmpty else { continue }
            let label = aliases[rawLabel] ?? rawLabel
            guard !seen.contains(label) else { continue }

            var value = String(line[valueRange]).trimmingCharacters(in: .whitespaces)
            while let first = value.first, first == ":" || first == "：" {
                value.removeFirst()
            }
            value = value.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            seen.insert(label)
            let row = ScopeDescriptionLine(label: label, value: value)
            if preferredOrder.contains(label) {
                known.append(row)
            } else {
                rest.append(row)
            }
        }

        known.sort { lhs, rhs in
            (preferredOrder.firstIndex(of: lhs.label) ?? 0)
                < (preferredOrder.firstIndex(of: rhs.label) ?? 0)
        }
        return known + rest
    }
}

/// 对齐 PWA `formatDescriptionLinesForItem`：描述名称与文件名不一致时用真实文件名替换。
func scopeDescriptionLines(for detail: ResourceDetail) -> [ScopeDescriptionLine] {
    let name = detail.name.trimmingCharacters(in: .whitespaces)
    let lines = ScopeDescription.lines(detail.description)
    guard !name.isEmpty else { return lines }

    let descName = lines.first { $0.label == "资源名称" || $0.label == "影片名称" }?.value ?? ""
    if !descName.isEmpty, scopeNamesAlign(descName, name) { return lines }

    var next = lines.map { row -> ScopeDescriptionLine in
        if row.label == "资源名称" || row.label == "影片名称" {
            return ScopeDescriptionLine(label: row.label, value: name)
        }
        if (row.label == "资源大小" || row.label == "文件大小"), detail.size > 0 {
            return ScopeDescriptionLine(label: row.label, value: ScopeDetailText.byteSize(detail.size))
        }
        return row
    }
    if !next.contains(where: { $0.label == "资源名称" || $0.label == "影片名称" }) {
        next.insert(ScopeDescriptionLine(label: "资源名称", value: name), at: 0)
    }
    return next
}

/// 对齐 PWA `resourceNamesAlign`：先比番号，再比小写全名 / 前 24 字符互含。
func scopeNamesAlign(_ lhs: String, _ rhs: String) -> Bool {
    if let a = scopeMakerCode(lhs), let b = scopeMakerCode(rhs) { return a == b }
    let a = lhs.trimmingCharacters(in: .whitespaces).lowercased()
    let b = rhs.trimmingCharacters(in: .whitespaces).lowercased()
    guard !a.isEmpty, !b.isEmpty else { return false }
    if a == b { return true }
    return a.contains(String(b.prefix(24))) || b.contains(String(a.prefix(24)))
}

private func scopeMakerCode(_ text: String) -> String? {
    let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return nil }
    let compact = raw.replacingOccurrences(
        of: "[\\s_-]+", with: "", options: .regularExpression
    )
    if compact.range(of: "^[A-Za-z]{2,15}\\d{2,8}$", options: .regularExpression) != nil {
        return compact.uppercased()
    }
    guard let regex = try? NSRegularExpression(
        pattern: "(?:^|[^A-Za-z0-9])([A-Za-z]{2,15}[-_\\s]?\\d{2,8}|FC2[-_\\s]?PPV[-_\\s]?\\d{5,10})(?![0-9])"
    ) else { return nil }
    let range = NSRange(raw.startIndex..., in: raw)
    guard let match = regex.firstMatch(in: raw, range: range),
          match.numberOfRanges > 1,
          let found = Range(match.range(at: 1), in: raw) else { return nil }
    return String(raw[found])
        .replacingOccurrences(of: "[\\s_-]+", with: "", options: .regularExpression)
        .uppercased()
}

/// 对齐 PWA `getExtractPassword`：列 → 描述里的 解压密码 / 访问码 / 分享码。
func scopeExtractPassword(from item: ResourceDetail, lines: [ScopeDescriptionLine]) -> String {
    let column = item.extractPassword.trimmingCharacters(in: .whitespaces)
    if !column.isEmpty { return column }
    for label in ["解压密码", "访问码", "分享码"] {
        if let value = lines.first(where: { $0.label == label })?.value, !value.isEmpty {
            return value
        }
    }
    return ""
}

// MARK: - 链接类型

enum ScopeLinkKind: String {
    case magnet, ed2k, stub, share115, other

    static func normalize(_ raw: String?) -> ScopeLinkKind {
        switch (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "magnet": return .magnet
        case "ed2k": return .ed2k
        case "stub", "unavailable": return .stub
        case "share115", "115share": return .share115
        default: return .other
        }
    }

    static func of(_ link: String?) -> ScopeLinkKind {
        let lower = (link ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if lower.hasPrefix("magnet:") { return .magnet }
        if lower.hasPrefix("ed2k://") { return .ed2k }
        if lower.hasPrefix("unavailable://") { return .stub }
        if lower.contains("115cdn.com/s/") || lower.contains("115.com/s/") { return .share115 }
        return .other
    }

    var sectionTitle: String {
        switch self {
        case .share115: "115 分享"
        case .magnet: "磁力链接"
        default: "下载链接"
        }
    }
}

/// 对齐 PWA `copyAllLabel`：多链接优先显示数量。
func scopeCopyAllLabel(links: [String], kind: ScopeLinkKind) -> String {
    if links.count > 1 { return "复制全部 (\(links.count))" }
    switch kind {
    case .magnet: return "复制磁力"
    case .share115: return "复制分享"
    default: return "复制链接"
    }
}

// MARK: - 文件树

/// 对齐 PWA `TorrentFileList`：padding / 无后缀沉底，按 index 保序。
enum ScopeFileTree {
    static func build(
        _ files: [TorrentFile],
        maxDepth: Int = 3,
        hintText: String = ""
    ) -> [ScopeFileNode] {
        let sorted = files.sorted { lhs, rhs in
            let lhsPad = isPadding(lhs.path) ? 1 : 0
            let rhsPad = isPadding(rhs.path) ? 1 : 0
            if lhsPad != rhsPad { return lhsPad < rhsPad }

            let lhsExt = inferExtension(path: lhs.path, raw: lhs.fileExtension, hintText: hintText)
            let rhsExt = inferExtension(path: rhs.path, raw: rhs.fileExtension, hintText: hintText)
            if (lhsExt.isEmpty ? 1 : 0) != (rhsExt.isEmpty ? 1 : 0) {
                return !lhsExt.isEmpty
            }
            return lhs.index < rhs.index
        }

        let root = ScopeFileNode(id: "root", isFolder: true, name: "", path: "", size: 0, fileExtension: "")
        for file in sorted {
            let parts = file.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            guard !parts.isEmpty else { continue }
            let ext = inferExtension(path: file.path, raw: file.fileExtension, hintText: hintText)

            if parts.count == 1 {
                root.children.append(
                    ScopeFileNode(
                        id: "f-\(file.index)-\(file.path)",
                        isFolder: false,
                        name: displayName(path: file.path, extension: ext),
                        path: file.path,
                        size: file.size,
                        fileExtension: ext
                    )
                )
                continue
            }

            var current = root
            for (depth, part) in parts.enumerated() {
                if depth == parts.count - 1 {
                    current.children.append(
                        ScopeFileNode(
                            id: "f-\(file.index)-\(file.path)",
                            isFolder: false,
                            name: displayName(path: part, extension: ext),
                            path: file.path,
                            size: file.size,
                            fileExtension: ext
                        )
                    )
                } else if depth == maxDepth {
                    current.children.append(
                        ScopeFileNode(
                            id: "f-\(file.index)-\(file.path)",
                            isFolder: false,
                            name: parts[depth...].joined(separator: "/"),
                            path: file.path,
                            size: file.size,
                            fileExtension: ext
                        )
                    )
                    break
                } else {
                    let folderId = "d-\(parts[0...depth].joined(separator: "/"))"
                    let folder: ScopeFileNode
                    if let existing = current.children.first(where: { $0.id == folderId }) {
                        folder = existing
                    } else {
                        folder = ScopeFileNode(
                            id: folderId,
                            isFolder: true,
                            name: part,
                            path: part,
                            size: 0,
                            fileExtension: "folder"
                        )
                        current.children.append(folder)
                    }
                    current = folder
                }
            }
        }
        return root.children
    }

    static func baseName(_ path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        return normalized.split(separator: "/").last.map(String.init) ?? normalized
    }

    static func inferExtension(path: String, raw: String, hintText: String = "") -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let cleaned = trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed
        if !cleaned.isEmpty,
           cleaned.count <= 8,
           !cleaned.contains(" "),
           cleaned.range(of: "^[a-z0-9]+$", options: .regularExpression) != nil {
            return cleaned
        }

        let normalized = path
            .replacingOccurrences(of: "\u{FF0E}", with: ".")
            .replacingOccurrences(of: "\u{3002}", with: ".")
        let base = baseName(normalized)
        if let range = base.range(of: #"\.([a-z0-9]{2,5})\s*$"#, options: [.regularExpression, .caseInsensitive]) {
            let ext = base[range]
                .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                .lowercased()
            if !ext.isEmpty { return ext }
        }

        // 对齐 PWA：路径 → 标题提示里的格式（如 `[avi/1.01GB]`）。
        for candidate in [base, normalized, hintText] {
            if let hint = hintFromText(candidate) { return hint }
        }
        return ""
    }

    /// 从文本中提取视频 / 压缩包后缀提示。
    private static func hintFromText(_ text: String) -> String? {
        let blob = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !blob.isEmpty else { return nil }
        let range = NSRange(blob.startIndex..., in: blob)
        for regex in [videoHintRegex, archiveHintRegex] {
            guard let match = regex.firstMatch(in: blob, range: range),
                  match.numberOfRanges > 1,
                  let found = Range(match.range(at: 1), in: blob) else { continue }
            return String(blob[found]).lowercased()
        }
        return nil
    }

    /// 对齐 PWA `displayFileName`：已有真实后缀或用视频/压缩包提示则不重复补。
    static func displayName(path: String, extension ext: String) -> String {
        let name = baseName(path)
        guard !ext.isEmpty else { return name }
        if name.lowercased().hasSuffix("." + ext.lowercased()) { return name }
        if videoHintRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
            return name
        }
        if archiveHintRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
            return name
        }
        return name + "." + ext
    }

    private static func isPadding(_ path: String) -> Bool {
        let lowered = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        let base = baseName(lowered)
        return base.hasPrefix("_____padding_file_")
            || base.hasPrefix("____padding_file_")
            || lowered.hasPrefix(".pad/")
            || lowered.contains("/.pad/")
    }

    private static let videoHintRegex = try! NSRegularExpression(
        pattern: #"(?:^|[.\s\[\(（_/|=-])(mp4|mkv|avi|wmv|rmvb|m2ts|ts|mov|flv|mpeg|mpg|m4v|webm|rm)(?:$|[.\s\]\)）_/|=-])"#,
        options: [.caseInsensitive]
    )

    private static let archiveHintRegex = try! NSRegularExpression(
        pattern: #"(?:^|[.\s\[\(（_/|=-])(zip|rar|7z|iso)(?:$|[.\s\]\)）_/|=-])"#,
        options: [.caseInsensitive]
    )
}

final class ScopeFileNode: Identifiable {
    let id: String
    let isFolder: Bool
    let name: String
    let path: String
    let size: Int64
    let fileExtension: String
    var children: [ScopeFileNode] = []

    init(id: String, isFolder: Bool, name: String, path: String, size: Int64, fileExtension: String) {
        self.id = id
        self.isFolder = isFolder
        self.name = name
        self.path = path
        self.size = size
        self.fileExtension = fileExtension
    }
}

/// 对齐 PWA `sizeTone`：五档大小色标。
enum ScopeSizeTone {
    case xs, sm, md, lg, xl

    static func of(_ size: Int64) -> ScopeSizeTone {
        let mb: Int64 = 1024 * 1024
        if size < mb * 2 { return .xs }
        if size < mb * 50 { return .sm }
        if size < mb * 200 { return .md }
        if size < 1024 * mb { return .lg }
        return .xl
    }

    var color: Color {
        switch self {
        case .xs: Color(red: 156 / 255, green: 163 / 255, blue: 175 / 255)
        case .sm: Color(red: 75 / 255, green: 85 / 255, blue: 99 / 255)
        case .md: Color(red: 22 / 255, green: 163 / 255, blue: 74 / 255)
        case .lg: Color(red: 21 / 255, green: 128 / 255, blue: 61 / 255)
        case .xl: Color(red: 220 / 255, green: 38 / 255, blue: 38 / 255)
        }
    }

    var background: Color {
        switch self {
        case .xs: Color(red: 156 / 255, green: 163 / 255, blue: 175 / 255).opacity(0.16)
        case .sm: Color(red: 156 / 255, green: 163 / 255, blue: 175 / 255).opacity(0.18)
        case .md: Color(red: 34 / 255, green: 197 / 255, blue: 94 / 255).opacity(0.14)
        case .lg: Color(red: 34 / 255, green: 197 / 255, blue: 94 / 255).opacity(0.18)
        case .xl: Color(red: 239 / 255, green: 68 / 255, blue: 68 / 255).opacity(0.14)
        }
    }
}

// MARK: - 详情卡通用组件（三套正文共用）

extension View {
    /// 详情卡外观：surface + 0.5pt 描边 + 双层阴影（对齐 PWA `.bm-card`）。
    func scopeDetailCard() -> some View {
        background(RexColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(RexColor.cardBorder.opacity(0.65), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.03), radius: 1, x: 0, y: 1)
            .shadow(color: .black.opacity(0.05), radius: 13, x: 0, y: 10)
    }
}

/// 卡片标题行（对齐 PWA `.bm-card__head--static`）。
struct ScopeCardHead: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(RexColor.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
    }
}

/// 详情标题（对齐 PWA `.bm-detail__title`）。
struct ScopeDetailTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold))
            .tracking(-0.34)
            .foregroundStyle(RexColor.primaryText)
            .lineSpacing(2.5)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .padding(.top, 2)
    }
}

struct ScopeKVRow: Identifiable {
    let key: String
    let value: String
    var mono: Bool = false
    /// 用蓝色 code 胶囊展示，点击复制。
    var copyable: Bool = false
    var copyToast: String = "已复制"
    /// 可点击外链（如色花堂来源帖）。
    var link: URL? = nil

    var id: String { key }
}

/// 详情信息卡：`bm-kv` 键值行（键 4.5em 固定宽 + 值自适应）。
struct ScopeInfoCard: View {
    let rows: [ScopeKVRow]
    var onCopy: (String, String) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScopeCardHead(title: "详情")

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: 8) {
                        Text(row.key)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(RexColor.tertiaryText)
                            .frame(width: 56, alignment: .leading)
                            .padding(.top, row.copyable ? 4 : 0)

                        valueView(row)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                    .frame(minHeight: 28)
                    .overlay(alignment: .bottom) {
                        if index != rows.count - 1 {
                            Rectangle()
                                .fill(RexColor.cardBorder.opacity(0.8))
                                .frame(height: 0.5)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .scopeDetailCard()
    }

    @ViewBuilder
    private func valueView(_ row: ScopeKVRow) -> some View {
        if row.copyable {
            Button {
                RexHaptics.tap()
                onCopy(row.value, row.copyToast)
            } label: {
                Text(row.value)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(RexColor.brandBlue)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RexColor.brandBlue.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("复制 \(row.value)")
        } else if let link = row.link {
            Link(destination: link) {
                Text(row.value)
                    .font(.system(size: 13))
                    .foregroundStyle(RexColor.brandBlue)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(row.value)
                .font(.system(size: row.mono ? 12 : 13, design: row.mono ? .monospaced : .default))
                .foregroundStyle(row.mono ? RexColor.secondaryText : RexColor.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 卡头动作按钮：复制（蓝底浅色胶囊）。
struct ScopeCopyActionButton: View {
    var label: String = "复制"
    var action: () -> Void

    var body: some View {
        Button {
            RexHaptics.tap()
            action()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))

                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(RexColor.brandBlue)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(RexColor.brandBlue.opacity(0.09), in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .fixedSize()
        .accessibilityLabel(label)
    }
}

/// 卡头动作按钮：转存 115（品牌渐变胶囊）。
struct ScopeSaveActionButton: View {
    var isSaving: Bool
    var action: () -> Void

    var body: some View {
        Button {
            RexHaptics.tap()
            action()
        } label: {
            Group {
                if isSaving {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(RexColor.onBrand)
                } else {
                    Text("转存")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(RexColor.onBrand)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(RexColor.brandGradient, in: Capsule(style: .continuous))
            .shadow(color: RexColor.brandBlue.opacity(0.28), radius: 5, x: 0, y: 3)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isSaving)
        .fixedSize()
        .accessibilityLabel("转存 115")
    }
}

/// 逐字符换行文本：对齐 PWA `word-break: break-all`，
/// SwiftUI `Text` 会在 `|`、`?`、`:` 等位置提前断行，必须用 UILabel 接管。
struct ScopeBreakAllText: UIViewRepresentable {
    let text: String
    var fontSize: CGFloat = 12
    var color: Color = RexColor.secondaryText
    var lineSpacing: CGFloat = 2

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byCharWrapping
        label.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize),
                .foregroundColor: UIColor(color),
                .paragraphStyle: paragraph
            ]
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UILabel,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? uiView.intrinsicContentSize.width
        guard width.isFinite, width > 0 else { return nil }
        let fitting = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: ceil(fitting.height))
    }
}

/// 链接行列表：序号圆 + 完整 URL + 复制按钮（对齐 PWA `.detail-link-row`）。
/// 巨型合集（单行上千条）默认折叠前 50 条，避免一次性渲染卡死。
struct ScopeLinkRowList: View {
    let links: [String]
    var onCopy: (String) -> Void

    @State private var expanded = false

    private static let collapsedLimit = 50

    private var isCollapsible: Bool { links.count > Self.collapsedLimit }

    private var visibleLinks: [String] {
        guard isCollapsible, !expanded else { return links }
        return Array(links.prefix(Self.collapsedLimit))
    }

    private var showIndex: Bool { links.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            LazyVStack(spacing: 0) {
                ForEach(Array(visibleLinks.enumerated()), id: \.offset) { index, url in
                    HStack(alignment: .center, spacing: 8) {
                        // 只有一条链接时不加序号，多条才用 1./2. 区分。
                        if showIndex {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(RexColor.brandBlue)
                                .frame(width: 22, height: 22)
                                .background(RexColor.brandBlue.opacity(0.1), in: Circle())
                        }

                        ScopeBreakAllText(text: url, color: RexColor.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            RexHaptics.tap()
                            onCopy(url)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(RexColor.brandBlue)
                                .frame(width: 30, height: 30)
                                .background(
                                    RexColor.brandBlue.opacity(0.09),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityLabel(showIndex ? "复制链接 \(index + 1)" : "复制链接")
                    }
                    .padding(.vertical, 6)
                    .frame(minHeight: 36)
                    .overlay(alignment: .bottom) {
                        if index != visibleLinks.count - 1 {
                            Rectangle()
                                .fill(RexColor.cardBorder.opacity(0.8))
                                .frame(height: 0.5)
                        }
                    }
                }
            }

            if isCollapsible {
                Button {
                    RexHaptics.tap()
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Text(expanded ? "收起" : "展开全部（共 \(links.count) 条）")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(RexColor.brandBlue)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}

/// 远程详情加载态（对齐 PWA `.app-loading`）。
struct ScopeDetailLoading: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            Text("加载中…")
                .font(.system(size: 15))
                .foregroundStyle(RexColor.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

/// 远程详情错误态（对齐 PWA `.app-error`）。
struct ScopeDetailError: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(RexColor.error)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RexColor.error.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(RexColor.error.opacity(0.22), lineWidth: 0.5)
            }
    }
}

// MARK: - 预览网格

/// 色花堂预览：宽度分 4 份，竖图占 1 份（3:4）、横图占 2 份（3:2），行内等高
/// （对齐 PWA `.detail-preview-grid`）。按份数手工分行 + 自定义 Layout 定位；
/// 不用 LazyVGrid，因为它不支持 `gridCellColumns` 跨列。
/// 每行 4 份的组合：4竖(4张) / 1横+2竖(3张) / 2横(2张) / 1横+1竖(2张，余 1 份空)。
struct ScopePhotoPreviewGrid: View {
    let images: [String]

    @Environment(\.apiClient) private var apiClient
    @State private var loaded: [Int: UIImage] = [:]
    @State private var failed: Set<Int> = []

    private let spacing: CGFloat = 4
    private let sharesPerRow = 4

    private var urls: [URL] {
        images.compactMap { apiClient?.mediaCoverURL(raw: $0) }
    }

    /// 加载失败的图直接跳过，不留空格。
    private var visibleIndices: [Int] {
        urls.indices.filter { !failed.contains($0) }
    }

    /// 竖图占 1 份、横图占 2 份；未加载完先按竖图占位，图片到达后自动重排。
    private func share(at index: Int) -> Int {
        guard let image = loaded[index] else { return 1 }
        return image.size.width > image.size.height ? 2 : 1
    }

    /// 按 4 份宽贪心分行：横图塞不进当前行剩余份数就换行（与 PWA 4 列网格一致，不回填空洞）。
    private var rows: [[Int]] {
        var result: [[Int]] = []
        var current: [Int] = []
        var used = 0
        for index in visibleIndices {
            let need = share(at: index)
            if used + need > sharesPerRow {
                result.append(current)
                current = []
                used = 0
            }
            current.append(index)
            used += need
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ScopeCardHead(title: "内容预览")

                    VStack(spacing: spacing) {
                        ForEach(rows.indices, id: \.self) { rowIndex in
                            ScopePreviewRowLayout(spacing: spacing) {
                                ForEach(rows[rowIndex], id: \.self) { index in
                                    previewSlot(image: loaded[index])
                                        .scopePreviewShare(share(at: index))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }
                .scopeDetailCard()
            }
        }
        .task { await load() }
    }

    private func previewSlot(image: UIImage?) -> some View {
        ZStack {
            Rectangle()
                .fill(RexColor.field)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(RexColor.cardBorder.opacity(0.8), lineWidth: 0.5)
        }
    }

    private func load() async {
        // token 为空也照常请求，交给服务端返回 401，避免静默卡在占位。
        let token = apiClient?.token
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    (index, await MakerImageStore.shared.image(for: url, bearerToken: token))
                }
            }
            for await (index, image) in group {
                if let image {
                    loaded[index] = image
                } else {
                    failed.insert(index)
                }
            }
        }
    }
}

/// 预览行布局：按份数分配宽度（横图 2 份、竖图 1 份），行内统一高度 = 1 份宽 × 4/3，
/// 竖图刚好 3:4、横图刚好 3:2，且同一行等高。
private struct ScopePreviewRowLayout: Layout {
    let spacing: CGFloat

    private func metrics(subviews: Subviews, width: CGFloat) -> (share: CGFloat, height: CGFloat) {
        let total = max(1, subviews.reduce(0) { $0 + $1[ScopePreviewShareKey.self] })
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        let share = max(0, (width - gaps) / CGFloat(total))
        return (share, share * 4 / 3)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        return CGSize(width: width, height: metrics(subviews: subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let metrics = metrics(subviews: subviews, width: bounds.width)
        var x = bounds.minX
        for subview in subviews {
            let width = metrics.share * CGFloat(subview[ScopePreviewShareKey.self])
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: metrics.height)
            )
            x += width + spacing
        }
    }
}

private struct ScopePreviewShareKey: LayoutValueKey {
    static let defaultValue = 1
}

private extension View {
    func scopePreviewShare(_ share: Int) -> some View {
        layoutValue(key: ScopePreviewShareKey.self, value: share)
    }
}

/// 磁力截图预览：2 列 16:9，先铺占位框再逐张填充，避免图片陆续到达撑高页面。
/// 失败隐藏单张，全部失败隐藏整卡。
struct ScopeVideoPreviewGrid: View {
    let images: [String]
    /// 预览接口还没返回时先铺几格骨架，卡片先占住高度。
    var skeletonCount = 0

    @Environment(\.apiClient) private var apiClient
    @State private var loaded: [Int: UIImage] = [:]
    @State private var failed: Set<Int> = []

    private var urls: [URL] {
        images.compactMap { apiClient?.mediaCoverURL(raw: $0) }
    }

    /// 有图按真实索引走；无图时按骨架格数占位。
    private var slotIndices: [Int] {
        if urls.isEmpty { return Array(0..<skeletonCount) }
        return urls.indices.filter { !failed.contains($0) }
    }

    var body: some View {
        Group {
            if !slotIndices.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ScopeCardHead(title: "内容预览")

                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(slotIndices, id: \.self) { index in
                            previewSlot(image: loaded[index])
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }
                .scopeDetailCard()
            }
        }
        .task(id: images) { await load() }
    }

    private func previewSlot(image: UIImage?) -> some View {
        ZStack {
            Rectangle()
                .fill(RexColor.field.opacity(0.7))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(RexColor.cardBorder.opacity(0.8), lineWidth: 0.5)
        }
    }

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 4),
            GridItem(.flexible(), spacing: 4)
        ]
    }

    private func load() async {
        // token 为空也照常请求，交给服务端返回 401，避免静默卡在加载态。
        let token = apiClient?.token
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    (index, await MakerImageStore.shared.image(for: url, bearerToken: token))
                }
            }
            for await (index, image) in group {
                if let image {
                    loaded[index] = image
                } else {
                    failed.insert(index)
                }
            }
        }
    }
}
