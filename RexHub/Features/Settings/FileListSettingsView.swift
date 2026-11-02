import SwiftUI

/// 文件列表：文件夹主题、图标大小、排序与列表显示项，全部即时生效并落盘。
struct FileListSettingsView: View {
    @Bindable private var settings = FileListSettingsStore.shared

    var body: some View {
        SettingsPage(title: "文件列表") {
            SettingsCard {
                SettingsLink(icon: "folder", title: "文件夹主题", value: settings.folderTheme.title) {
                    FolderThemeSettingsView()
                }

                SettingsDivider()

                // 列表与网格各自独立，只显示当前浏览方式对应的图标大小。
                if settings.viewMode == .grid {
                    SettingsLink(icon: "square.grid.2x2", title: "网格图标大小", value: "\(settings.gridIconSize) pt") {
                        ListIconSizeSettingsView(grid: true)
                    }
                } else {
                    SettingsLink(icon: "textformat.size", title: "列表图标大小", value: "\(settings.iconSize) pt") {
                        ListIconSizeSettingsView(grid: false)
                    }
                }

                SettingsDivider()

                SettingsLink(
                    icon: "arrow.up.arrow.down",
                    title: "排序",
                    value: "\(settings.sortField.title) · \(settings.sortOrder.title)"
                ) {
                    FileSortSettingsView()
                }
            }

            SettingsSection(title: "显示") {
                SettingsSwitchRow(title: "显示文件扩展名", isOn: $settings.showFileExtension)

                SettingsDivider()

                SettingsSwitchRow(title: "显示文件大小", isOn: $settings.showFileSize)

                SettingsDivider()

                SettingsSwitchRow(title: "显示文件类型", isOn: $settings.showFileType)

                SettingsDivider()

                SettingsSwitchRow(title: "显示图片缩略图", isOn: $settings.showThumbnails)

                SettingsDivider()

                SettingsSwitchRow(title: "显示完整时间", isOn: $settings.showFullTime)

                SettingsDivider()

                SettingsSwitchRow(title: "标题栏显示文件数量", isOn: $settings.showItemCount)

                SettingsDivider()

                SettingsSwitchRow(title: "文件夹项目显示时间", isOn: $settings.showFolderTime)
            }

            SettingsSection(title: "列表外观") {
                SettingsMenuRow(
                    title: "浏览方式",
                    options: FileListViewMode.allCases,
                    label: \.title,
                    selection: $settings.viewMode
                )

                // 列数只对网格有效，分隔线 / 卡片只对列表有效，避免出现无效项。
                if settings.viewMode == .grid {
                    SettingsDivider()

                    SettingsMenuRow(
                        title: "网格列数",
                        options: FileGridColumns.allCases,
                        label: \.title,
                        selection: $settings.gridColumns
                    )
                }

                SettingsDivider()

                SettingsMenuRow(
                    title: "显示密度",
                    options: FileListDensity.allCases,
                    label: \.title,
                    selection: $settings.density
                )

                SettingsDivider()

                SettingsMenuRow(
                    title: "名称行数",
                    options: [1, 2],
                    label: { "\($0) 行" },
                    selection: $settings.nameLines
                )

                if settings.viewMode == .list {
                    SettingsDivider()

                    SettingsMenuRow(
                        title: "列表样式",
                        options: FileListStyle.allCases,
                        label: \.title,
                        selection: $settings.listStyle
                    )

                    SettingsDivider()

                    SettingsSwitchRow(title: "显示分隔线", isOn: $settings.showDividers)
                }
            }

            Text("仅影响网盘的文件列表显示，修改后立即保存。")
                .font(.system(size: 12))
                .foregroundStyle(RexColor.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, RexSpacing.xs)
                .lineSpacing(2)
        }
    }
}

// MARK: - 文件夹主题

private struct FolderThemeSettingsView: View {
    @Bindable private var settings = FileListSettingsStore.shared

    var body: some View {
        SettingsPage(title: "文件夹主题") {
            themeCard

            iconCard
        }
        .onAppear {
            // 旧版本可以单独选中「目录 / Cloud」等条目，新页面只保留三套主题。
            if !FileFolderTheme.primaryThemes.contains(settings.folderTheme) {
                settings.folderTheme = .standard
            }
        }
    }

    private var themeCard: some View {
        SettingsCard {
            ForEach(FileFolderTheme.primaryThemes) { theme in
                themeRow(theme)

                if theme != FileFolderTheme.primaryThemes.last {
                    SettingsDivider()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: RexRadius.panel, style: .continuous))
    }

    private func themeRow(_ theme: FileFolderTheme) -> some View {
        let isSelected = settings.folderTheme == theme

        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                settings.folderTheme = theme
            }
        } label: {
            HStack(spacing: RexSpacing.md) {
                FileIconView(kind: theme.iconKind, theme: previewTheme(for: theme), size: 34)

                Text(theme.title)
                    .font(.system(size: 16))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)

                Spacer(minLength: RexSpacing.sm)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(RexColor.brandBlue)
                }
            }
            .padding(.horizontal, RexSpacing.lg)
            .frame(height: 56)
            .background {
                // 整行铺满底色：中间行保持直角，首末行的圆角由卡片裁剪给出
                if isSelected {
                    RexColor.selection
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var iconCard: some View {
        SettingsCard {
            ForEach(IconPreviewItem.samples) { item in
                if item.id != IconPreviewItem.samples.first?.id {
                    SettingsDivider()
                }

                HStack(spacing: RexSpacing.md) {
                    FileIconView(kind: item.kind, theme: settings.folderTheme, size: 34)

                    Text(item.name)
                        .font(.system(size: 16))
                        .foregroundStyle(RexColor.primaryText)

                    Spacer(minLength: RexSpacing.sm)
                }
                .padding(.horizontal, RexSpacing.lg)
                .frame(height: 56)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// 只有三套主主题可选；历史遗留的单项主题用当前主题渲染预览。
    private func previewTheme(for theme: FileFolderTheme) -> FileFolderTheme {
        FileFolderTheme.primaryThemes.contains(theme) ? theme : settings.folderTheme
    }
}

// MARK: - 列表图标大小

private struct IconPreviewItem: Identifiable {
    let name: String
    let kind: FileIconKind

    var id: String { name }

    static let samples: [IconPreviewItem] = [
        IconPreviewItem(name: "目录", kind: .folder),
        IconPreviewItem(name: "私有目录", kind: .privateFolder),
        IconPreviewItem(name: "快捷方式", kind: .shortcut),
        IconPreviewItem(name: "Cloud", kind: .cloud),
        IconPreviewItem(name: "视频", kind: .video),
        IconPreviewItem(name: "音频", kind: .audio),
        IconPreviewItem(name: "图片", kind: .image),
        IconPreviewItem(name: "文本", kind: .text),
        IconPreviewItem(name: "文档", kind: .document),
        IconPreviewItem(name: "PDF", kind: .pdf),
        IconPreviewItem(name: "PPT", kind: .ppt),
        IconPreviewItem(name: "Excel", kind: .excel),
        IconPreviewItem(name: "压缩文件", kind: .archive),
        IconPreviewItem(name: "其它", kind: .other)
    ]
}

private struct ListIconSizeSettingsView: View {
    let grid: Bool

    @Bindable private var settings = FileListSettingsStore.shared
    @Environment(\.displayScale) private var displayScale

    private var currentSize: Int { grid ? settings.gridIconSize : settings.iconSize }

    var body: some View {
        SettingsPage(title: grid ? "网格图标大小" : "列表图标大小", actions: actions) {
            SettingsCard {
                ForEach(IconPreviewItem.samples) { item in
                    if item.id != IconPreviewItem.samples.first?.id {
                        Rectangle()
                            .fill(RexColor.divider)
                            .frame(height: 1 / displayScale)
                            .padding(.leading, RexSpacing.lg + CGFloat(currentSize) + RexSpacing.md)
                    }

                    row(item)
                }
            }

            Text("\(grid ? "网格" : "列表")图标的大小，点击右上角按钮调整。")
                .font(.system(size: 12))
                .foregroundStyle(RexColor.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, RexSpacing.xs)
        }
    }

    private var actions: [RexNavAction] {
        [
            RexNavAction(
                systemImage: "minus",
                label: "缩小图标",
                isEnabled: settings.canStepIconSize(-1, grid: grid),
                showsOutline: true
            ) {
                withAnimation(.easeOut(duration: 0.15)) {
                    settings.stepIconSize(-1, grid: grid)
                }
            },
            RexNavAction(
                systemImage: "plus",
                label: "放大图标",
                isEnabled: settings.canStepIconSize(1, grid: grid),
                showsOutline: true
            ) {
                withAnimation(.easeOut(duration: 0.15)) {
                    settings.stepIconSize(1, grid: grid)
                }
            }
        ]
    }

    private func row(_ item: IconPreviewItem) -> some View {
        let size = CGFloat(currentSize)

        return HStack(spacing: RexSpacing.md) {
            FileIconView(kind: item.kind, theme: settings.folderTheme, size: size)

            Text(item.name)
                .font(.system(size: 16))
                .foregroundStyle(RexColor.primaryText)

            Spacer(minLength: RexSpacing.sm)
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(height: max(56, size + RexSpacing.xxl))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 排序

private struct FileSortSettingsView: View {
    @Bindable private var settings = FileListSettingsStore.shared

    var body: some View {
        SettingsPage(title: "排序") {
            SettingsCard {
                SettingsMenuRow(
                    title: "排序依据",
                    options: FileSortField.allCases,
                    label: \.title,
                    selection: $settings.sortField
                )

                SettingsDivider()

                SettingsMenuRow(
                    title: "排序顺序",
                    options: FileSortOrder.allCases,
                    label: \.title,
                    selection: $settings.sortOrder
                )

                SettingsDivider()

                SettingsSwitchRow(title: "保持文件夹置顶", isOn: $settings.keepFoldersOnTop)
            }

            Text("排序只影响列表显示顺序，不会改动网盘中的文件。")
                .font(.system(size: 12))
                .foregroundStyle(RexColor.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, RexSpacing.xs)
        }
    }
}

// MARK: - 选项行

struct SettingsMenuRow<T: Hashable>: View {
    let title: String
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
        } label: {
            HStack(spacing: RexSpacing.sm) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(RexColor.primaryText)

                Spacer(minLength: RexSpacing.sm)

                Text(label(selection))
                    .font(.system(size: 14))
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RexColor.secondaryText)
            }
            .padding(.horizontal, RexSpacing.lg)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        FileListSettingsView()
            .toolbar(.hidden, for: .navigationBar)
    }
}
