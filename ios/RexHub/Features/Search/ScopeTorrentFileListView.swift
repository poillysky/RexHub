import SwiftUI

/// 对齐 PWA `TorrentFileList`（详情模式）：文件树 + 类型图标 + 大小色标，
/// 文件夹始终展开、子级缩进 1.4em。
struct ScopeTorrentFileListView: View {
    let files: [TorrentFile]
    /// 标题 / 描述，用于补全无扩展名文件的格式（如 `[avi/1GB]`）。
    var hintText: String = ""

    private var nodes: [ScopeFileNode] {
        ScopeFileTree.build(files, hintText: hintText)
    }

    var body: some View {
        Group {
            if nodes.isEmpty {
                Text("暂无文件信息")
                    .font(.system(size: 13))
                    .foregroundStyle(RexColor.tertiaryText)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(nodes) { node in
                        ScopeFileRow(node: node)
                    }
                }
            }
        }
    }
}

private struct ScopeFileRow: View {
    let node: ScopeFileNode
    var depth: Int = 0

    private static let coreMinSize: Int64 = 100 * 1024 * 1024

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                ScopeFileIconView(kind: iconKind, size: 18)

                Text(node.name)
                    .font(.system(size: 13))
                    .foregroundStyle(node.isFolder ? RexColor.secondaryText : RexColor.primaryText)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if missingExtension {
                    Text("无后缀")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(RexColor.secondaryText)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(
                            Color(red: 120 / 255, green: 120 / 255, blue: 128 / 255).opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                }

                if !node.isFolder, node.size > 0 {
                    Text(ScopeDetailText.byteSize(node.size))
                        .font(.system(size: 10, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(tone.color)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(tone.background, in: Capsule(style: .continuous))
                        .fixedSize()
                }
            }
            .padding(.vertical, 4)
            .frame(minHeight: 28)

            if node.isFolder, !node.children.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(node.children) { child in
                        ScopeFileRow(node: child, depth: depth + 1)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }

    private var tone: ScopeSizeTone {
        ScopeSizeTone.of(node.size)
    }

    private var iconKind: ScopeFileIconKind {
        if node.isFolder { return .folder }
        if !node.fileExtension.isEmpty {
            return ScopeFileIconKind.of(extension: node.fileExtension)
        }
        // 大文件无后缀：仅图标按视频示意，不伪造文件名。
        return node.size >= Self.coreMinSize ? .video : .file
    }

    /// 文件名本身没有扩展名时给出「无后缀」提示。
    private var missingExtension: Bool {
        guard !node.isFolder, node.fileExtension.isEmpty else { return false }
        let base = ScopeFileTree.baseName(node.path.isEmpty ? node.name : node.path)
        return base.range(
            of: #"\.[a-z0-9]{2,5}$"#,
            options: [.regularExpression, .caseInsensitive]
        ) == nil
    }
}

// MARK: - PWA 文件类型图标

/// 对齐 PWA `TorrentFileList.getFileType` 的 11 类文件图标。
enum ScopeFileIconKind: String, CaseIterable {
    case folder
    case file
    case image
    case video
    case audio
    case book
    case web
    case archive
    case disk
    case executable
    case subtitle

    var assetName: String {
        switch self {
        case .folder: return "ScopeFileIconFolder"
        case .file: return "ScopeFileIconFile"
        case .image: return "ScopeFileIconImage"
        case .video: return "ScopeFileIconVideo"
        case .audio: return "ScopeFileIconAudio"
        case .book: return "ScopeFileIconBook"
        case .web: return "ScopeFileIconWeb"
        case .archive: return "ScopeFileIconArchive"
        case .disk: return "ScopeFileIconDisk"
        case .executable: return "ScopeFileIconExecutable"
        case .subtitle: return "ScopeFileIconSubtitle"
        }
    }

    /// 与 PWA `EXTENSION_MAP` 完全一致；未命中返回 `.file`。
    static func of(extension raw: String) -> ScopeFileIconKind {
        let ext = raw.lowercased()
        guard !ext.isEmpty else { return .file }
        if ext == "folder" { return .folder }
        return extensionMap[ext] ?? .file
    }

    private static let extensionMap: [String: ScopeFileIconKind] = {
        let table: [ScopeFileIconKind: [String]] = [
            .audio: ["mp3", "wav", "ogg", "m4a", "flac", "wma", "aac", "mid", "midi", "cue"],
            .image: [
                "jpg", "jpeg", "png", "gif", "bmp", "svg", "webp",
                "tiff", "ico", "heic", "raw", "psd", "ai"
            ],
            .video: [
                "mp4", "mkv", "webm", "avi", "mov", "flv", "wmv",
                "mpeg", "mpg", "3gp", "m4v", "rm", "rmvb", "ts", "m2ts", "pmp"
            ],
            .book: ["pdf", "epub", "fb2", "mobi", "azw", "azw3", "cbr", "cbz", "chm"],
            .web: ["torrent", "html", "htm", "php", "url", "asp", "aspx", "jsp"],
            .archive: [
                "zip", "rar", "7z", "gz", "bz2", "tar", "xpi",
                "rpm", "cab", "lzh", "dmg", "z", "lz", "xz", "tgz", "tbz2"
            ],
            .disk: ["iso", "img", "vmdk", "vdi"],
            .executable: [
                "exe", "msi", "apk", "deb", "bat", "sh",
                "bin", "dll", "so", "cmd", "com", "run", "vbs", "app"
            ],
            .subtitle: ["srt", "sub", "ssa", "ass", "vtt", "rt", "rtx", "smi"]
        ]
        var map: [String: ScopeFileIconKind] = [:]
        for (kind, exts) in table {
            for ext in exts { map[ext] = kind }
        }
        return map
    }()
}

/// PWA 那套 32×32 双色 SVG 图标。
struct ScopeFileIconView: View {
    let kind: ScopeFileIconKind
    var size: CGFloat = 18

    var body: some View {
        Image(kind.assetName)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
