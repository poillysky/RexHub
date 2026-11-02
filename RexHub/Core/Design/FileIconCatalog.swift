import SwiftUI
import UIKit

/// 文件列表图标类别：文件夹类图标与按扩展名推断出的文件类型。
enum FileIconKind: String {
    case folder
    case cloud
    case privateFolder
    case shortcut
    case video
    case audio
    case image
    case text
    case document
    case pdf
    case ppt
    case excel
    case archive
    case other

    /// 图片资源名后缀，与主题的 `assetPrefix` 拼接成 `imageset` 名称。
    var assetSuffix: String {
        switch self {
        case .folder, .privateFolder, .shortcut: "Folder"
        case .cloud: "Cloud"
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Image"
        case .text: "Text"
        case .document: "Document"
        case .pdf: "Pdf"
        case .ppt: "Ppt"
        case .excel: "Excel"
        case .archive: "Archive"
        case .other: "Other"
        }
    }

    /// 默认主题使用的系统符号。
    var symbol: String {
        switch self {
        case .folder, .privateFolder, .shortcut: "folder.fill"
        case .cloud: "cloud.fill"
        case .video: "play.rectangle.fill"
        case .audio: "music.note"
        case .image: "photo.fill"
        case .text: "doc.text.fill"
        case .document: "doc.fill"
        case .pdf: "doc.richtext"
        case .ppt: "rectangle.on.rectangle"
        case .excel: "tablecells"
        case .archive: "archivebox.fill"
        case .other: "doc"
        }
    }

    var tint: Color {
        switch self {
        case .folder, .privateFolder, .shortcut, .cloud: RexColor.brandBlue
        default: RexColor.secondaryText
        }
    }

    var tileColor: Color {
        switch self {
        case .folder, .privateFolder, .shortcut, .cloud: RexColor.brandBlue.opacity(0.1)
        default: RexColor.field
        }
    }

    var badgeSymbol: String? {
        switch self {
        case .privateFolder: "lock.fill"
        case .shortcut: "arrow.up.forward"
        default: nil
        }
    }

    // MARK: - 由文件名推断

    private static let videoExtensions: Set<String> = [
        "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v", "mpg", "mpeg",
        "rmvb", "rm", "ts", "m2ts", "mts", "vob", "3gp", "ogv", "asf", "divx"
    ]
    private static let audioExtensions: Set<String> = [
        "mp3", "flac", "wav", "aac", "m4a", "ape", "ogg", "oga", "wma", "opus",
        "dts", "ac3", "aiff", "aif", "dsf", "wv"
    ]
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff",
        "svg", "raw", "cr2", "nef", "arw", "dng", "avif", "ico", "psd"
    ]
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "log", "srt", "ass", "ssa", "vtt", "json", "xml",
        "yml", "yaml", "ini", "conf", "cfg", "sh", "py", "js", "ts", "css", "html"
    ]
    private static let documentExtensions: Set<String> = [
        "doc", "docx", "pages", "rtf", "odt", "epub", "mobi", "azw3", "wps"
    ]
    private static let pdfExtensions: Set<String> = ["pdf"]
    private static let pptExtensions: Set<String> = ["ppt", "pptx", "key", "odp"]
    private static let excelExtensions: Set<String> = ["xls", "xlsx", "csv", "numbers", "ods", "tsv"]
    private static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "zst", "iso", "dmg", "tgz"
    ]

    /// 按扩展名判断文件图标，未知类型归为「其它」。
    static func fileKind(forName name: String) -> FileIconKind {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }

        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if imageExtensions.contains(ext) { return .image }
        if pdfExtensions.contains(ext) { return .pdf }
        if pptExtensions.contains(ext) { return .ppt }
        if excelExtensions.contains(ext) { return .excel }
        if documentExtensions.contains(ext) { return .document }
        if textExtensions.contains(ext) { return .text }
        if archiveExtensions.contains(ext) { return .archive }
        return .other
    }
}

/// 点击文件时进入的查看器，与图标识别共用同一套扩展名判断。
enum FileOpenStyle {
    case image
    case video
    case audio
    case document
    case archive
}

extension FileIconKind {
    /// 识别结果直接决定打开方式：图片 / 视频 / 音乐 / 文档 / 压缩包。
    var openStyle: FileOpenStyle {
        switch self {
        case .image: return .image
        case .video: return .video
        case .audio: return .audio
        case .archive: return .archive
        default: return .document
        }
    }
}

/// 主题化文件图标：有打包素材时用彩色图标，否则回退到系统符号。
struct FileIconView: View {
    let kind: FileIconKind
    var theme: FileFolderTheme = .standard
    var size: CGFloat = 36

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            artwork

            if let badge = kind.badgeSymbol, !theme.bakesBadge(for: kind) {
                Image(systemName: badge)
                    .font(.system(size: max(8, size * 0.3), weight: .bold))
                    .foregroundStyle(RexColor.primaryText)
                    .padding(size * 0.05)
                    .background(RexColor.surface, in: Circle())
                    .offset(x: size * 0.12, y: size * 0.08)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var artwork: some View {
        if let name = theme.assetName(for: kind) {
            Image(name)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: kind.symbol)
                .font(.system(size: size * 0.45, weight: .medium))
                .foregroundStyle(kind.tint)
                .frame(width: size, height: size)
                .background(
                    kind.tileColor,
                    in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                )
        }
    }
}
