import SwiftUI
import UIKit

// MARK: - 选项

/// 文件夹图标主题：第一组为常用主题，第二组为扩展图标。
enum FileFolderTheme: String, CaseIterable, Identifiable {
    case standard
    case windows
    case synology
    case directory
    case privateDirectory
    case shortcut
    case cloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "默认"
        case .windows: "Windows"
        case .synology: "群晖"
        case .directory: "目录"
        case .privateDirectory: "私有目录"
        case .shortcut: "快捷方式"
        case .cloud: "Cloud"
        }
    }

    /// 这套图标对应的类别，用于列表预览与网盘页渲染。
    var iconKind: FileIconKind {
        switch self {
        case .cloud: .cloud
        case .privateDirectory: .privateFolder
        case .shortcut: .shortcut
        default: .folder
        }
    }

    /// 打包图标的资源名前缀；`nil` 表示使用系统符号（扩展主题）。
    var assetPrefix: String? {
        switch self {
        case .standard: "FileIcon115"
        case .windows: "FileIconWin"
        case .synology: "FileIconSyn"
        default: nil
        }
    }

    /// 该主题下某类图标的 `Asset` 名称，缺失时返回 `nil` 走系统符号。
    func assetName(for kind: FileIconKind) -> String? {
        // 各主题的原生图标集都没有「私有目录 / 快捷方式」，用同风格自绘替代。
        guard let prefix = assetPrefix else { return nil }
        let suffix = switch kind {
        case .privateFolder: "PrivateFolder"
        case .shortcut: "Shortcut"
        default: kind.assetSuffix
        }
        let name = prefix + suffix
        return UIImage(named: name) == nil ? nil : name
    }

    /// 自绘资源已经把角标画进图标，渲染时不再叠加系统角标。
    func bakesBadge(for kind: FileIconKind) -> Bool {
        assetPrefix != nil
            && (kind == .privateFolder || kind == .shortcut || kind == .cloud)
    }

    static let primaryThemes: [FileFolderTheme] = [.standard, .windows, .synology]
    static let extraThemes: [FileFolderTheme] = [.directory, .privateDirectory, .shortcut, .cloud]
}

enum FileSortField: String, CaseIterable, Identifiable {
    case name
    case size
    case date
    case type

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "名称"
        case .size: "大小"
        case .date: "修改时间"
        case .type: "类型"
        }
    }
}

enum FileSortOrder: String, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ascending: "升序"
        case .descending: "降序"
        }
    }
}

/// 列表密度：同时决定行高、名称字号、副标题字号与上下留白。
enum FileListDensity: String, CaseIterable, Identifiable {
    case compact
    case standard
    case relaxed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "紧凑"
        case .standard: "标准"
        case .relaxed: "宽松"
        }
    }

    var rowHeight: CGFloat {
        switch self {
        case .compact: 48
        case .standard: 60
        case .relaxed: 72
        }
    }

    var titleSize: CGFloat {
        switch self {
        case .compact: 14
        case .standard: 15
        case .relaxed: 16
        }
    }

    var subtitleSize: CGFloat {
        switch self {
        case .compact: 11
        case .standard: 12
        case .relaxed: 13
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .compact: 6
        case .standard: 12
        case .relaxed: 16
        }
    }
}

/// 列表容器样式：卡片为圆角白底，通栏贴边铺满。
enum FileListStyle: String, CaseIterable, Identifiable {
    case card
    case plain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .card: "卡片"
        case .plain: "通栏"
        }
    }
}

/// 文件浏览方式：逐行列表或网格图标。
enum FileListViewMode: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: "列表"
        case .grid: "网格"
        }
    }
}

/// 网格列数：自动按宽度铺排，或固定列数。
enum FileGridColumns: String, CaseIterable, Identifiable {
    case auto
    case two
    case three
    case four

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "自动"
        case .two: "2 列"
        case .three: "3 列"
        case .four: "4 列"
        }
    }

    func layout(spacing: CGFloat) -> [GridItem] {
        switch self {
        case .auto:
            [GridItem(.adaptive(minimum: 96, maximum: 160), spacing: spacing)]
        case .two:
            Array(repeating: GridItem(.flexible(), spacing: spacing), count: 2)
        case .three:
            Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3)
        case .four:
            Array(repeating: GridItem(.flexible(), spacing: spacing), count: 4)
        }
    }
}

// MARK: - 偏好

/// 文件列表偏好：只包含网盘文件夹与列表真正用得到的项，全部落在 `UserDefaults`。
@MainActor
@Observable
final class FileListSettingsStore {
    static let shared = FileListSettingsStore()

    /// 列表图标尺寸档位，每次按钮切换 ±4。
    static let iconSizes = [28, 32, 36, 40, 44, 48, 52]
    /// 网格图标尺寸档位：格子更宽，档位整体更大。
    static let gridIconSizes = [40, 48, 56, 64, 72, 80, 88]

    private enum Key {
        static let folderTheme = "rex.fileList.folderTheme"
        static let iconSize = "rex.fileList.iconSize"
        static let gridIconSize = "rex.fileList.gridIconSize"
        static let sortField = "rex.fileList.sortField"
        static let sortOrder = "rex.fileList.sortOrder"
        static let keepFoldersOnTop = "rex.fileList.keepFoldersOnTop"
        static let showFileExtension = "rex.fileList.showFileExtension"
        static let showFileSize = "rex.fileList.showFileSize"
        static let showFullTime = "rex.fileList.showFullTime"
        static let showItemCount = "rex.fileList.showItemCount"
        static let showFolderTime = "rex.fileList.showFolderTime"
        static let showFileType = "rex.fileList.showFileType"
        static let showThumbnails = "rex.fileList.showThumbnails"
        static let density = "rex.fileList.density"
        static let nameLines = "rex.fileList.nameLines"
        static let listStyle = "rex.fileList.listStyle"
        static let showDividers = "rex.fileList.showDividers"
        static let viewMode = "rex.fileList.viewMode"
        static let gridColumns = "rex.fileList.gridColumns"
    }

    var folderTheme: FileFolderTheme {
        didSet { defaults.set(folderTheme.rawValue, forKey: Key.folderTheme) }
    }

    var iconSize: Int {
        didSet { defaults.set(iconSize, forKey: Key.iconSize) }
    }

    /// 网格模式下的图标大小，与列表互相独立。
    var gridIconSize: Int {
        didSet { defaults.set(gridIconSize, forKey: Key.gridIconSize) }
    }

    var sortField: FileSortField {
        didSet { defaults.set(sortField.rawValue, forKey: Key.sortField) }
    }

    var sortOrder: FileSortOrder {
        didSet { defaults.set(sortOrder.rawValue, forKey: Key.sortOrder) }
    }

    var keepFoldersOnTop: Bool {
        didSet { defaults.set(keepFoldersOnTop, forKey: Key.keepFoldersOnTop) }
    }

    // MARK: 显示

    var showFileExtension: Bool {
        didSet { defaults.set(showFileExtension, forKey: Key.showFileExtension) }
    }

    var showFileSize: Bool {
        didSet { defaults.set(showFileSize, forKey: Key.showFileSize) }
    }

    var showFullTime: Bool {
        didSet { defaults.set(showFullTime, forKey: Key.showFullTime) }
    }

    var showItemCount: Bool {
        didSet { defaults.set(showItemCount, forKey: Key.showItemCount) }
    }

    var showFolderTime: Bool {
        didSet { defaults.set(showFolderTime, forKey: Key.showFolderTime) }
    }

    /// 副标题追加文件类型（扩展名大写）。
    var showFileType: Bool {
        didSet { defaults.set(showFileType, forKey: Key.showFileType) }
    }

    /// 图片文件用 115 缩略图替代表头图标。
    var showThumbnails: Bool {
        didSet { defaults.set(showThumbnails, forKey: Key.showThumbnails) }
    }

    // MARK: 外观

    var density: FileListDensity {
        didSet { defaults.set(density.rawValue, forKey: Key.density) }
    }

    /// 名称最多显示几行，取值 1–2。
    var nameLines: Int {
        didSet { defaults.set(nameLines, forKey: Key.nameLines) }
    }

    var listStyle: FileListStyle {
        didSet { defaults.set(listStyle.rawValue, forKey: Key.listStyle) }
    }

    var showDividers: Bool {
        didSet { defaults.set(showDividers, forKey: Key.showDividers) }
    }

    var viewMode: FileListViewMode {
        didSet { defaults.set(viewMode.rawValue, forKey: Key.viewMode) }
    }

    var gridColumns: FileGridColumns {
        didSet { defaults.set(gridColumns.rawValue, forKey: Key.gridColumns) }
    }

    private let defaults = UserDefaults.standard

    private init() {
        let defaults = UserDefaults.standard

        folderTheme = FileFolderTheme(
            rawValue: defaults.string(forKey: Key.folderTheme) ?? ""
        ) ?? .standard
        iconSize = defaults.object(forKey: Key.iconSize) as? Int ?? 36
        gridIconSize = defaults.object(forKey: Key.gridIconSize) as? Int ?? 56
        sortField = FileSortField(
            rawValue: defaults.string(forKey: Key.sortField) ?? ""
        ) ?? .name
        sortOrder = FileSortOrder(
            rawValue: defaults.string(forKey: Key.sortOrder) ?? ""
        ) ?? .descending
        keepFoldersOnTop = Self.bool(defaults, Key.keepFoldersOnTop, default: true)

        showFileExtension = Self.bool(defaults, Key.showFileExtension, default: true)
        showFileSize = Self.bool(defaults, Key.showFileSize, default: true)
        showFullTime = Self.bool(defaults, Key.showFullTime, default: false)
        showItemCount = Self.bool(defaults, Key.showItemCount, default: false)
        showFolderTime = Self.bool(defaults, Key.showFolderTime, default: false)
        showFileType = Self.bool(defaults, Key.showFileType, default: false)
        showThumbnails = Self.bool(defaults, Key.showThumbnails, default: true)

        density = FileListDensity(
            rawValue: defaults.string(forKey: Key.density) ?? ""
        ) ?? .standard
        nameLines = defaults.object(forKey: Key.nameLines) as? Int ?? 1
        listStyle = FileListStyle(
            rawValue: defaults.string(forKey: Key.listStyle) ?? ""
        ) ?? .card
        showDividers = Self.bool(defaults, Key.showDividers, default: true)
        viewMode = FileListViewMode(
            rawValue: defaults.string(forKey: Key.viewMode) ?? ""
        ) ?? .list
        gridColumns = FileGridColumns(
            rawValue: defaults.string(forKey: Key.gridColumns) ?? ""
        ) ?? .auto
    }

    /// 当前档位是否还能继续调整；`grid` 决定作用于列表还是网格。
    func canStepIconSize(_ direction: Int, grid: Bool) -> Bool {
        let sizes = grid ? Self.gridIconSizes : Self.iconSizes
        let current = grid ? gridIconSize : iconSize
        guard let index = sizes.firstIndex(of: current) else { return true }
        return direction < 0 ? index > 0 : index < sizes.count - 1
    }

    /// 按档位调整图标大小，越界时保持当前值。
    func stepIconSize(_ direction: Int, grid: Bool) {
        let sizes = grid ? Self.gridIconSizes : Self.iconSizes
        let current = grid ? gridIconSize : iconSize
        guard let index = sizes.firstIndex(of: current) else {
            if grid {
                gridIconSize = 56
            } else {
                iconSize = 36
            }
            return
        }
        let next = min(max(index + direction, 0), sizes.count - 1)
        if grid {
            gridIconSize = sizes[next]
        } else {
            iconSize = sizes[next]
        }
    }

    private static func bool(_ defaults: UserDefaults, _ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }
}
