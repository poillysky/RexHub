import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 网盘目录浏览：默认作为一级 Tab 的根页面，也可从「快捷操作 · 全部文件」推入。
/// 列表走服务端 JSON，播放只取临时直链，视频流量不经过本地服务端。
struct DriveView: View {
    var reselectToken: Int = 0
    /// 被其他页面推入时显示返回按钮，而不是作为 Tab 根页面。
    var isPushed: Bool = false
    /// 非管理员只读：服务端所有写操作都要求管理员权限。
    var isAdmin: Bool = false

    var body: some View {
        DriveFolderView(
            cid: "0",
            title: isPushed ? "全部文件" : "网盘",
            isRoot: !isPushed,
            reselectToken: reselectToken,
            isAdmin: isAdmin
        )
    }
}

private struct DriveFolderView: View {
    let cid: String
    let title: String
    /// 一级页没有返回；进入子文件夹后显示返回。
    let isRoot: Bool
    var reselectToken: Int = 0
    var isAdmin: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.apiClient) private var apiClient
    @Environment(\.colorScheme) private var colorScheme

    @State private var items: [PanItem] = []
    @State private var total = 0
    @State private var phase: Phase = .loading
    @State private var isLoadingMore = false
    @State private var playItem: PanItem?
    @State private var musicItem: PanItem?
    @State private var imageItem: PanItem?
    @State private var documentItem: PanItem?
    @State private var archiveItem: PanItem?
    @State private var showCloudDownload = false
    @State private var isScrolled = false

    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var isImporting = false
    @State private var isUploading = false
    @State private var errorMessage: String?

    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var isDeleting = false
    @State private var isConfirmingDelete = false
    @State private var transferMode: PanTransferMode?
    @State private var transferringText: String?

    /// 单条目操作：⋯ 打开完整面板，长按打开快捷菜单，两者互不重复。
    @State private var actionItem: PanItem?
    @State private var infoItem: PanItem?
    @State private var renameItem: PanItem?
    @State private var renameText = ""
    @State private var isRenamePromptShown = false
    @State private var isBatchRenamePromptShown = false
    @State private var isRenaming = false
    @State private var pendingDeleteIDs: [String] = []
    @State private var transferIDs: [String] = []

    private let settings = FileListSettingsStore.shared
    /// 视频行的观看进度来自播放器设置，保存进度后由 `@Observable` 触发行重绘。
    private let playerSettings = PlayerSettingsStore.shared

    private let pageSize = 200

    private enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content

            if isSelecting {
                selectionBar
            }
        }
        .background(RexPageBackground())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(isSelecting ? .hidden : .visible, for: .tabBar)
        .navigationDestination(isPresented: $showCloudDownload) {
            PanCloudDownloadView(isAdmin: isAdmin)
        }
        .onChange(of: showCloudDownload) { _, presented in
            // 云下载返回后刷新列表，让新落盘的文件立即出现。
            guard !presented else { return }
            Task { await load(reset: true) }
        }
        .fullScreenCover(item: $playItem) { item in
            RexPlayerView(item: item, playlist: videoItems)
        }
        .fullScreenCover(item: $musicItem) { item in
            MusicPlayerView(item: item, playlist: audioItems)
        }
        .fullScreenCover(item: $imageItem) { item in
            PanImageViewerView(items: imageItems, startID: item.id)
        }
        .fullScreenCover(item: $documentItem) { item in
            PanDocumentViewerView(item: item)
        }
        .fullScreenCover(item: $archiveItem) { item in
            PanArchiveViewerView(item: item)
        }
        .overlay {
            if isUploading {
                busyOverlay("正在上传…")
            } else if isDeleting {
                busyOverlay("正在删除…")
            } else if isRenaming {
                busyOverlay("正在重命名…")
            } else if let transferringText {
                busyOverlay(transferringText)
            }
        }
        .rexBottomDrawer(item: $transferMode) { mode in
            PanFolderPickerView(mode: mode, isAdmin: isAdmin) { cid in
                Task { await transfer(mode, to: cid, ids: transferIDs) }
            }
        }
        .rexBottomDrawer(item: $actionItem, sizing: .content(minHeight: 320)) { item in
            PanItemActionSheet(
                item: item,
                onInfo: { runAfterActionSheet { infoItem = item } },
                onRename: { startRename(item) },
                onTransfer: { mode in beginTransfer(mode, ids: [item.id]) },
                onDelete: { confirmDelete([item.id]) },
                isAdmin: isAdmin
            )
        }
        .rexBottomDrawer(item: $infoItem, sizing: .content()) { item in
            PanItemInfoSheet(item: item)
        }
        .rexBottomDrawer(isPresented: $isBatchRenamePromptShown, sizing: .content()) {
            PanBatchRenameSheet(items: selectedItems) { pairs in
                Task { await batchRename(pairs) }
            }
        }
        .alert("删除所选项目？", isPresented: $isConfirmingDelete) {
            Button("取消", role: .cancel) { pendingDeleteIDs = [] }
            Button("删除", role: .destructive) { Task { await deleteItems(pendingDeleteIDs) } }
        } message: {
            Text("共 \(pendingDeleteIDs.count) 项，删除后可在 115 回收站找回。")
        }
        .alert("重命名", isPresented: $isRenamePromptShown) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { cancelRename() }
            Button("保存") {
                guard let item = renameItem else { return }
                let name = renameText
                Task { await rename(item, to: name) }
            }
        } message: {
            Text(renameItem?.isDir == true ? "修改文件夹名称" : "修改文件名（扩展名会自动保留）")
        }
        .alert("新建文件夹", isPresented: $isCreatingFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("创建") { Task { await createFolder() } }
        } message: {
            Text("在「\(title)」中创建")
        }
        .alert("操作失败", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            Task { await upload(result) }
        }
        .task {
            if items.isEmpty {
                await load(reset: true)
            }
            await syncPlaybackProgress()
        }
    }

    // MARK: - 上传提示

    private func busyOverlay(_ text: String) -> some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()

            VStack(spacing: RexSpacing.md) {
                ProgressView()
                    .tint(.white)

                Text(text)
                    .font(.system(.footnote, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, RexSpacing.xxl)
            .padding(.vertical, RexSpacing.xl)
            .background(
                Color.black.opacity(0.82),
                in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    @MainActor
    private func createFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard let client = apiClient else {
            errorMessage = "登录状态已失效，请重新登录"
            return
        }

        do {
            try await client.panCreateFolder(cid: cid, name: name)
            newFolderName = ""
            await load(reset: true)
        } catch let error as APIError {
            guard error != .cancelled else { return }
            errorMessage = message(for: error)
        } catch {
            errorMessage = "新建文件夹失败，请重试"
        }
    }

    @MainActor
    private func upload(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        guard let client = apiClient else {
            errorMessage = "登录状态已失效，请重新登录"
            return
        }

        isUploading = true
        defer { isUploading = false }

        var failures: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            do {
                try await client.panUpload(fileName: url.lastPathComponent, fileURL: url, cid: cid)
            } catch let error as APIError {
                if error != .cancelled {
                    failures.append("\(url.lastPathComponent)：\(message(for: error))")
                }
            } catch {
                failures.append("\(url.lastPathComponent)：上传失败")
            }
        }

        await load(reset: true)

        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n")
        }
    }

    // MARK: - 多选

    private var selectionBar: some View {
        HStack(spacing: RexSpacing.md) {
            selectionButton(.copy)
            selectionButton(.move)
            renameSelectionButton
            deleteSelectionButton
        }
        .padding(.horizontal, RexSpacing.xl)
        // 白色面板一直铺到屏幕底部（含 Home 指示条安全区），
        // 顶部留白与安全区高度接近，按钮在整块面板里垂直居中。
        .padding(.top, RexSpacing.xxxl)
        .background(RexColor.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(RexColor.divider)
                .frame(height: 1 / displayScale)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func selectionButton(_ mode: PanTransferMode) -> some View {
        selectionCircleButton(
            systemImage: mode.systemImage,
            title: mode.actionTitle
        ) {
            guard !selectedIDs.isEmpty else { return }
            transferIDs = Array(selectedIDs)
            transferMode = mode
        }
    }

    private var renameSelectionButton: some View {
        selectionCircleButton(systemImage: "square.and.pencil", title: "重命名") {
            guard !selectedIDs.isEmpty else { return }
            isBatchRenamePromptShown = true
        }
    }

    private var deleteSelectionButton: some View {
        selectionCircleButton(systemImage: "trash", title: "删除") {
            guard !selectedIDs.isEmpty else { return }
            pendingDeleteIDs = Array(selectedIDs)
            isConfirmingDelete = true
        }
    }

    /// 多选底栏的圆形操作按钮：小尺寸玻璃圆 + 居中图标，和 115 的多选样式一致。
    private func selectionCircleButton(
        systemImage: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(RexColor.primaryText)
                .frame(width: 44, height: 44)
                .modifier(SelectionGlassCircle())
                .contentShape(Circle())
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(selectedIDs.isEmpty)
        .opacity(selectedIDs.isEmpty ? 0.35 : 1)
        .accessibilityLabel(title)
    }

    private var isAllSelected: Bool {
        !items.isEmpty && selectedIDs.count >= items.count
    }

    /// 选中项按当前列表顺序排列，批量重命名也按这个顺序编号。
    private var selectedItems: [PanItem] {
        orderedItems.filter { selectedIDs.contains($0.id) }
    }

    private func enterSelection() {
        selectedIDs.removeAll()
        withAnimation(.easeOut(duration: 0.18)) {
            isSelecting = true
        }
    }

    private func exitSelection() {
        selectedIDs.removeAll()
        withAnimation(.easeOut(duration: 0.18)) {
            isSelecting = false
        }
    }

    private func toggleSelection(_ item: PanItem) {
        RexHaptics.selection()
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    private func toggleSelectAll() {
        if isAllSelected {
            selectedIDs.removeAll()
        } else {
            selectedIDs = Set(items.map(\.id))
        }
    }

    @MainActor
    private func deleteItems(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        guard let client = apiClient else {
            errorMessage = "登录状态已失效，请重新登录"
            return
        }

        isDeleting = true
        defer {
            isDeleting = false
            pendingDeleteIDs = []
        }

        do {
            try await client.panDelete(ids: ids)
            if isSelecting { exitSelection() }
            await load(reset: true)
        } catch let error as APIError {
            guard error != .cancelled else { return }
            errorMessage = message(for: error)
        } catch {
            errorMessage = "删除失败，请重试"
        }
    }

    @MainActor
    private func transfer(_ mode: PanTransferMode, to cid: String, ids: [String]) async {
        guard !ids.isEmpty else { return }
        guard let client = apiClient else {
            errorMessage = "登录状态已失效，请重新登录"
            return
        }

        transferringText = mode.busyText
        defer { transferringText = nil }

        do {
            switch mode {
            case .copy:
                try await client.panCopy(ids: ids, to: cid)
            case .move:
                try await client.panMove(ids: ids, to: cid)
            case .select:
                // 选目录模式不会走到搬移逻辑，这里只做兜底。
                break
            }
            if isSelecting { exitSelection() }
            await load(reset: true)
        } catch let error as APIError {
            guard error != .cancelled else { return }
            errorMessage = message(for: error)
        } catch {
            errorMessage = "\(mode.actionTitle)失败，请重试"
        }
    }

    /// 重命名单个条目：文件缺扩展名时自动补回，避免 115 截断后缀。
    @MainActor
    private func rename(_ item: PanItem, to rawName: String) async {
        renameItem = nil

        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "名称不能为空"
            return
        }
        if !item.isDir {
            let ext = (item.name as NSString).pathExtension
            if !ext.isEmpty, (name as NSString).pathExtension.isEmpty {
                name += ".\(ext)"
            }
        }
        guard name != item.name else { return }
        guard let client = apiClient else {
            errorMessage = "登录状态已失效，请重新登录"
            return
        }

        isRenaming = true
        defer { isRenaming = false }

        do {
            try await client.panRename(id: item.id, name: name)
            await load(reset: true)
        } catch let error as APIError {
            guard error != .cancelled else { return }
            errorMessage = message(for: error)
        } catch {
            errorMessage = "重命名失败，请重试"
        }
    }

    /// 批量重命名：一次提交所有新名称，成功后退出多选。
    @MainActor
    private func batchRename(_ pairs: [PanRenamePair]) async {
        guard !pairs.isEmpty else { return }
        guard let client = apiClient else {
            errorMessage = "登录状态已失效，请重新登录"
            return
        }

        isRenaming = true
        defer { isRenaming = false }

        do {
            try await client.panRenameBatch(pairs)
            if isSelecting { exitSelection() }
            await load(reset: true)
        } catch let error as APIError {
            guard error != .cancelled else { return }
            errorMessage = message(for: error)
        } catch {
            errorMessage = "批量重命名失败，请重试"
        }
    }

    private func startRename(_ item: PanItem) {
        renameItem = item
        renameText = item.name
        runAfterActionSheet {
            isRenamePromptShown = true
        }
    }

    private func cancelRename() {
        renameItem = nil
        renameText = ""
    }

    /// 面板收起后再执行下一步，避免连续弹窗被系统丢弃。
    private func runAfterActionSheet(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            action()
        }
    }

    private func beginTransfer(_ mode: PanTransferMode, ids: [String]) {
        guard !ids.isEmpty else { return }
        transferIDs = ids
        runAfterActionSheet { transferMode = mode }
    }

    private func confirmDelete(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        pendingDeleteIDs = ids
        runAfterActionSheet { isConfirmingDelete = true }
    }

    // MARK: - 顶栏

    private var header: some View {
        RexNavBar(
            title: isSelecting ? "\(selectedIDs.count) 项" : displayTitle,
            leading: isSelecting
                ? .pill(isAllSelected ? "取消全选" : "全选", action: toggleSelectAll)
                : (isRoot ? .none : .back(action: { dismiss() })),
            actions: isSelecting
                ? [
                    RexNavAction(
                        systemImage: "checkmark.circle.fill",
                        label: "完成",
                        action: exitSelection
                    )
                ]
                : headerActions,
            groupsActions: !isSelecting,
            isScrolled: isScrolled
        )
    }

    /// 顶栏右侧操作：云下载仅管理员可用，更多菜单对所有人可见。
    private var headerActions: [RexNavAction] {
        var actions: [RexNavAction] = []
        if isAdmin {
            actions.append(
                RexNavAction(
                    systemImage: "icloud.and.arrow.down",
                    label: "云下载",
                    isEnabled: true,
                    action: { showCloudDownload = true }
                )
            )
        }
        actions.append(
            RexNavAction(
                systemImage: "ellipsis",
                label: "更多操作",
                showsCircleOutline: true,
                menu: { AnyView(moreMenu) }
            )
        )
        return actions
    }

    /// 顶栏三点菜单：选择、新建、上传、浏览方式、排序与置顶。
    @ViewBuilder
    private var moreMenu: some View {
        if isAdmin {
            Button {
                enterSelection()
            } label: {
                Label("选择", systemImage: "checkmark.circle")
            }

            Button {
                newFolderName = ""
                isCreatingFolder = true
            } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
            }

            Button {
                isImporting = true
            } label: {
                Label("上传文件", systemImage: "arrow.up.doc")
            }

            Divider()
        }

        Picker(selection: viewModeBinding) {
            Label("图标", systemImage: "square.grid.2x2").tag(FileListViewMode.grid)
            Label("列表", systemImage: "list.bullet").tag(FileListViewMode.list)
        } label: {
            Text("浏览方式")
        }

        Divider()

        Menu {
            Picker(selection: sortFieldBinding) {
                ForEach(FileSortField.allCases) { field in
                    Text(field.title).tag(field)
                }
            } label: {
                Text("排序依据")
            }

            Divider()

            Picker(selection: sortOrderBinding) {
                ForEach(FileSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            } label: {
                Text("排序方向")
            }
        } label: {
            Label("排序", systemImage: "arrow.up.arrow.down")
        }

        Divider()

        Toggle(isOn: keepFoldersBinding) {
            Label("保持文件夹置顶", systemImage: "pin")
        }
    }

    private var viewModeBinding: Binding<FileListViewMode> {
        Binding(
            get: { settings.viewMode },
            set: { settings.viewMode = $0 }
        )
    }

    private var sortFieldBinding: Binding<FileSortField> {
        Binding(
            get: { settings.sortField },
            set: { settings.sortField = $0 }
        )
    }

    private var sortOrderBinding: Binding<FileSortOrder> {
        Binding(
            get: { settings.sortOrder },
            set: { settings.sortOrder = $0 }
        )
    }

    private var keepFoldersBinding: Binding<Bool> {
        Binding(
            get: { settings.keepFoldersOnTop },
            set: { settings.keepFoldersOnTop = $0 }
        )
    }

    // MARK: - 内容

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: RexSpacing.md) {
                    switch phase {
                    case .loading where items.isEmpty:
                        loadingCard
                    case .failed(let message):
                        failureCard(message)
                    case .loading, .loaded:
                        if items.isEmpty {
                            emptyCard
                        } else if settings.viewMode == .grid {
                            gridContent
                        } else {
                            listContent
                        }
                    }
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.top, RexSpacing.md)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: RexLayout.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .background(RexScrollOffsetReader(space: "driveScroll"))
                .id("driveTop")
            }
            .rexScrollTracking("driveScroll", isScrolled: $isScrolled)
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                await load(reset: true)
            }
            .onChange(of: reselectToken) { _, _ in
                guard isRoot else { return }
                RexHaptics.tap()
                exitSelection()
                withAnimation(RexMotion.standard) {
                    proxy.scrollTo("driveTop", anchor: .top)
                }
            }
        }
    }

    private var listContent: some View {
        let ordered = orderedItems
        let isCard = settings.listStyle == .card

        return LazyVStack(spacing: 0) {
            ForEach(ordered) { item in
                if settings.showDividers, item.id != ordered.first?.id {
                    Rectangle()
                        .fill(RexColor.divider)
                        .frame(height: 1 / displayScale)
                        .padding(.leading, RexSpacing.lg + CGFloat(settings.iconSize) + RexSpacing.md)
                }

                row(item)
                    .onAppear {
                        guard item.id == ordered.last?.id,
                              items.count < total,
                              !isLoadingMore else { return }
                        Task { await loadMore() }
                    }
            }
        }
        .background {
            if isCard {
                RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                    .fill(RexColor.surface)
            }
        }
        .overlay {
            if isCard {
                RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                    .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: isCard ? RexRadius.card : 0, style: .continuous))
        .shadow(
            color: isCard && colorScheme == .light ? Color.black.opacity(0.045) : .clear,
            radius: 12,
            y: 4
        )
        .padding(.horizontal, isCard ? 0 : -RexSpacing.xl)
    }

    private var gridContent: some View {
        let ordered = orderedItems
        let columns = settings.gridColumns.layout(spacing: RexSpacing.md)

        return LazyVGrid(columns: columns, spacing: RexSpacing.md) {
            ForEach(ordered) { item in
                gridCellWithMenu(item)
                    .onAppear {
                        guard item.id == ordered.last?.id,
                              items.count < total,
                              !isLoadingMore else { return }
                        Task { await loadMore() }
                    }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: PanItem) -> some View {
        if isSelecting || !isAdmin {
            rowBody(item)
        } else {
            rowBody(item)
                .contextMenu { quickMenu(item) }
        }
    }

    /// 行主体：左侧点击区 + 观看进度圆环 + 行尾 ⋯ 完整操作入口。
    private func rowBody(_ item: PanItem) -> some View {
        HStack(spacing: 0) {
            rowContent(item)
                .frame(maxWidth: .infinity)

            if !isSelecting {
                if let progress = playerSettings.playbackProgress(for: item.pickcode) {
                    progressRing(progress.ratio)
                        .padding(.trailing, RexSpacing.sm)
                }

                itemMenuButton(item)
                    .padding(.trailing, RexSpacing.sm)
            }
        }
    }

    @ViewBuilder
    private func rowContent(_ item: PanItem) -> some View {
        if isSelecting {
            Button {
                toggleSelection(item)
            } label: {
                rowLabel(item)
            }
            .buttonStyle(DriveRowButtonStyle())
        } else if item.isDir {
            NavigationLink {
                DriveFolderView(cid: item.id, title: item.name, isRoot: false, isAdmin: isAdmin)
            } label: {
                rowLabel(item)
            }
            .buttonStyle(DriveRowButtonStyle())
        } else {
            Button {
                open(item)
            } label: {
                rowLabel(item)
            }
            .buttonStyle(DriveRowButtonStyle())
            .disabled(item.pickcode.isEmpty)
        }
    }

    /// 行尾三点：打开完整操作面板（打开 / 信息 / 重命名 / 复制 / 移动 / 删除）。
    private func itemMenuButton(_ item: PanItem) -> some View {
        Button {
            actionItem = item
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RexColor.secondaryText)
                // 竖排三点省出横向空间给文件名。
                .rotationEffect(.degrees(90))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("更多操作")
    }

    /// 长按快捷菜单：复制、移动、重命名、删除，与 ⋯ 完整面板分开。
    @ViewBuilder
    private func quickMenu(_ item: PanItem) -> some View {
        Button {
            beginTransfer(.copy, ids: [item.id])
        } label: {
            Label("复制到…", systemImage: "doc.on.doc")
        }

        Button {
            beginTransfer(.move, ids: [item.id])
        } label: {
            Label("移动到…", systemImage: "folder")
        }

        Button {
            startRename(item)
        } label: {
            Label("重命名", systemImage: "square.and.pencil")
        }

        Divider()

        Button(role: .destructive) {
            confirmDelete([item.id])
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private func rowLabel(_ item: PanItem) -> some View {
        let density = settings.density

        return HStack(spacing: RexSpacing.md) {
            if isSelecting {
                selectionMark(isSelected: selectedIDs.contains(item.id))
            }

            leadingIcon(item, size: CGFloat(settings.iconSize))

            VStack(alignment: .leading, spacing: 2) {
                Text(breakableName(displayName(for: item)))
                    .font(.system(size: density.titleSize))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(settings.nameLines)
                    .multilineTextAlignment(.leading)

                let detail = subtitle(for: item)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: density.subtitleSize))
                        .foregroundStyle(RexColor.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, RexSpacing.lg)
        // 行尾还有 ⋯ 按钮时，右侧只留一点呼吸空间，把宽度让给文件名。
        .padding(.trailing, isSelecting ? RexSpacing.lg : RexSpacing.sm)
        .padding(.vertical, density.verticalPadding)
        .frame(minHeight: density.rowHeight)
        .background(
            isSelecting && selectedIDs.contains(item.id)
                ? RexColor.brandBlue.opacity(0.10)
                : Color.clear
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(item.isDir ? "打开文件夹" : "播放")
    }

    /// 网格卡片同样支持长按快捷菜单。
    @ViewBuilder
    private func gridCellWithMenu(_ item: PanItem) -> some View {
        if isSelecting || !isAdmin {
            gridCell(item)
        } else {
            gridCell(item)
                .contextMenu { quickMenu(item) }
        }
    }

    @ViewBuilder
    private func gridCell(_ item: PanItem) -> some View {
        if isSelecting {
            Button {
                toggleSelection(item)
            } label: {
                gridLabel(item)
            }
            .buttonStyle(DriveCellButtonStyle())
        } else if item.isDir {
            NavigationLink {
                DriveFolderView(cid: item.id, title: item.name, isRoot: false, isAdmin: isAdmin)
            } label: {
                gridLabel(item)
            }
            .buttonStyle(DriveCellButtonStyle())
        } else {
            Button {
                open(item)
            } label: {
                gridLabel(item)
            }
            .buttonStyle(DriveCellButtonStyle())
            .disabled(item.pickcode.isEmpty)
        }
    }

    private func gridLabel(_ item: PanItem) -> some View {
        let density = settings.density
        let iconSize = CGFloat(settings.gridIconSize)

        return VStack(spacing: RexSpacing.sm) {
            leadingIcon(item, size: iconSize)
                .frame(height: iconSize)

            Text(breakableName(displayName(for: item)))
                .font(.system(size: density.titleSize))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(settings.nameLines)
                .multilineTextAlignment(.center)

            let detail = subtitle(for: item)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: density.subtitleSize))
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, RexSpacing.sm)
        .padding(.vertical, density.verticalPadding)
        .background(
            isSelecting && selectedIDs.contains(item.id)
                ? RexColor.brandBlue.opacity(0.10)
                : RexColor.surface,
            in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                .strokeBorder(
                    isSelecting && selectedIDs.contains(item.id)
                        ? RexColor.brandBlue.opacity(0.45)
                        : RexColor.cardBorder,
                    lineWidth: isSelecting && selectedIDs.contains(item.id) ? 1.5 : 0.75
                )
        )
        .shadow(
            color: colorScheme == .light ? Color.black.opacity(0.04) : .clear,
            radius: 8,
            y: 3
        )
        .overlay(alignment: .topTrailing) {
            if isSelecting {
                selectionMark(isSelected: selectedIDs.contains(item.id))
                    .padding(6)
            }
        }
        .overlay(alignment: .bottom) {
            if let progress = playerSettings.playbackProgress(for: item.pickcode) {
                progressBar(progress.ratio)
                    .padding(.horizontal, RexSpacing.md)
                    .padding(.bottom, 6)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(item.isDir ? "打开文件夹" : "播放")
    }

    /// 多选态的勾选圆点，列表与网格共用。
    private func selectionMark(isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 21))
            .foregroundStyle(isSelected ? RexColor.brandBlue : RexColor.secondaryText.opacity(0.45))
            .background(Circle().fill(RexColor.surface).padding(2))
            .transition(.scale.combined(with: .opacity))
    }

    /// 网格卡片底部的观看进度条。
    private func progressBar(_ ratio: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(RexColor.secondaryText.opacity(0.2))

                Capsule()
                    .fill(RexColor.brandBlue)
                    .frame(width: max(2, proxy.size.width * ratio))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }

    /// 列表行尾的观看进度圆环，替代原来的底部进度条。
    private func progressRing(_ ratio: Double) -> some View {
        ZStack {
            Circle()
                .stroke(RexColor.secondaryText.opacity(0.18), lineWidth: 2)

            Circle()
                .trim(from: 0, to: min(max(ratio, 0), 1))
                .stroke(RexColor.brandBlue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    /// 图片文件在开启缩略图时用 115 缩略图，其余仍用主题图标。
    @ViewBuilder
    private func leadingIcon(_ item: PanItem, size: CGFloat) -> some View {
        if settings.showThumbnails,
           !item.isDir,
           !item.sha1.isEmpty,
           FileIconKind.fileKind(forName: item.name) == .image {
            PanThumbnailView(item: item, theme: settings.folderTheme, size: size)
        } else {
            FileIconView(
                kind: item.isDir ? .folder : .fileKind(forName: item.name),
                theme: settings.folderTheme,
                size: size
            )
        }
    }

    private var loadingCard: some View {
        VStack(alignment: .leading, spacing: RexSpacing.md) {
            HStack(spacing: RexSpacing.sm) {
                ProgressView()
                    .controlSize(.small)

                Text("正在读取网盘…")
                    .font(RexFont.footnote)
                    .foregroundStyle(RexColor.secondaryText)
            }
            .padding(.horizontal, RexSpacing.xs)

            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { index in
                    HStack(spacing: RexSpacing.md) {
                        RexSkeleton(width: 38, height: 38, cornerRadius: 10)

                        VStack(alignment: .leading, spacing: 6) {
                            RexSkeleton(width: index.isMultiple(of: 2) ? 168 : 214, height: 13)
                            RexSkeleton(width: 92, height: 10)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, RexSpacing.lg)
                    .frame(height: 64)
                }
            }
            .rexCard()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在读取网盘")
    }

    private var emptyCard: some View {
        RexStateCard(
            symbol: "folder",
            title: "此文件夹为空",
            message: isAdmin
                ? "可以从这里上传文件，或新建文件夹开始整理。"
                : "这个文件夹里还没有内容。",
            tone: .brand,
            actionTitle: isAdmin ? "上传文件" : nil,
            action: isAdmin ? {
                RexHaptics.tap()
                isImporting = true
            } : nil
        )
    }

    private func failureCard(_ message: String) -> some View {
        RexStateCard(
            symbol: "wifi.exclamationmark",
            title: "加载失败",
            message: message,
            tone: .warning,
            actionTitle: "重试"
        ) {
            RexHaptics.tap()
            Task { await load(reset: true) }
        }
    }

    // MARK: - 数据

    /// 自动连播用：当前目录里可播放的视频，顺序与列表展示一致。
    private var videoItems: [PanItem] {
        orderedItems.filter {
            !$0.isDir
                && !$0.pickcode.isEmpty
                && FileIconKind.fileKind(forName: $0.name) == .video
        }
    }

    /// 音乐播放器用：当前目录里的音频，顺序与列表展示一致。
    private var audioItems: [PanItem] {
        orderedItems.filter {
            !$0.isDir
                && !$0.pickcode.isEmpty
                && FileIconKind.fileKind(forName: $0.name) == .audio
        }
    }

    /// 图片预览可左右翻页：当前目录里的图片，顺序与列表展示一致。
    private var imageItems: [PanItem] {
        orderedItems.filter {
            !$0.isDir
                && !$0.pickcode.isEmpty
                && FileIconKind.fileKind(forName: $0.name) == .image
        }
    }

    /// 图标识别结果直接决定查看器：图片 / 视频 / 音乐 / 文档 / 压缩包。
    private func open(_ item: PanItem) {
        switch FileIconKind.fileKind(forName: item.name).openStyle {
        case .audio:
            musicItem = item
        case .video:
            playItem = item
        case .image:
            imageItem = item
        case .document:
            documentItem = item
        case .archive:
            archiveItem = item
        }
    }

    /// 约定置顶的文件夹：无论排序方式如何都排在最前，顺序即数组顺序。
    private static let pinnedFolderNames = ["云下载", "最近接收", "最近接受"]

    /// 按设置里的排序依据 / 顺序重排，并处理「保持文件夹置顶」与固定置顶文件夹。
    private var orderedItems: [PanItem] {
        let ascending = settings.sortOrder == .ascending
        let sorted = items.sorted { lhs, rhs in
            if settings.keepFoldersOnTop, lhs.isDir != rhs.isDir {
                return lhs.isDir
            }

            let result = Self.compare(lhs, rhs, by: settings.sortField)

            if result == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }

        let pinned = sorted
            .compactMap { item in Self.pinnedRank(item).map { (item, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)

        guard !pinned.isEmpty else { return sorted }

        let pinnedIDs = Set(pinned.map(\.id))
        return pinned + sorted.filter { !pinnedIDs.contains($0.id) }
    }

    private static func pinnedRank(_ item: PanItem) -> Int? {
        guard item.isDir else { return nil }
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return pinnedFolderNames.firstIndex(of: name)
    }

    private static func compare(_ lhs: PanItem, _ rhs: PanItem, by field: FileSortField) -> ComparisonResult {
        switch field {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .size:
            return valueCompare(lhs.size, rhs.size)
        case .date:
            return valueCompare(lhs.updatedAt, rhs.updatedAt)
        case .type:
            let left = (lhs.name as NSString).pathExtension
            let right = (rhs.name as NSString).pathExtension
            if left.lowercased() == right.lowercased() {
                return lhs.name.localizedStandardCompare(rhs.name)
            }
            return left.localizedStandardCompare(right)
        }
    }

    private static func valueCompare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private func load(reset: Bool) async {
        guard let client = apiClient else {
            phase = .failed("登录状态已失效，请重新登录")
            return
        }

        if reset {
            phase = .loading
        }

        do {
            let page = try await client.panList(
                cid: cid,
                offset: reset ? 0 : items.count,
                limit: pageSize
            )
            items = reset ? page.items : items + page.items
            total = page.total
            phase = .loaded
        } catch let error as APIError {
            guard error != .cancelled else { return }
            if reset || items.isEmpty {
                phase = .failed(message(for: error))
            }
        } catch {
            if reset || items.isEmpty {
                phase = .failed("加载失败，请重试")
            }
        }
    }

    private func loadMore() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        await load(reset: false)
        isLoadingMore = false
    }

    /// 拉取服务端进度，补齐其它设备看过、本机还没记录的续播圆环。
    @MainActor
    private func syncPlaybackProgress() async {
        guard let client = apiClient else { return }
        guard let entries = try? await client.panPlaybackProgress() else { return }
        playerSettings.mergeRemoteProgress(entries)
    }

    private func message(for error: APIError) -> String {
        if case .conflict(let detail) = error, let detail, !detail.isEmpty {
            return detail
        }
        return error.errorDescription ?? "加载失败，请重试"
    }

    private var displayTitle: String {
        guard settings.showItemCount, total > 0 else { return title }
        return "\(title)（\(total)）"
    }

    /// 关闭「显示文件扩展名」时去掉后缀，文件夹不改名。
    private func displayName(for item: PanItem) -> String {
        guard !settings.showFileExtension, !item.isDir else { return item.name }
        let name = (item.name as NSString).deletingPathExtension
        return name.isEmpty ? item.name : name
    }

    /// 文件名里常有一长段没有空格的文本，系统会在空格处整段换行，导致第一行很短。
    /// 在 `.` `_` `-` 后插入零宽空格，让换行落在分隔符处。
    private func breakableName(_ name: String) -> String {
        name
            .replacingOccurrences(of: ".", with: ".\u{200B}")
            .replacingOccurrences(of: "_", with: "_\u{200B}")
            .replacingOccurrences(of: "-", with: "-\u{200B}")
    }

    private func subtitle(for item: PanItem) -> String {
        var parts: [String] = []

        if item.isDir {
            if settings.showFolderTime, let date = Self.dateText(item.updatedAt, full: settings.showFullTime) {
                parts.append(date)
            }
        } else {
            if settings.showFileSize {
                parts.append(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
            }
            if settings.showFileType, let type = Self.typeText(for: item) {
                parts.append(type)
            }
            if let date = Self.dateText(item.updatedAt, full: settings.showFullTime) {
                parts.append(date)
            }
        }

        return parts.joined(separator: " · ")
    }

    /// 文件类型：取扩展名并大写，没有扩展名时不显示。
    private static func typeText(for item: PanItem) -> String? {
        let ext = (item.name as NSString).pathExtension
        return ext.isEmpty ? nil : ext.uppercased()
    }

    private static func dateText(_ timestamp: Int64, full: Bool) -> String? {
        guard timestamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        if full {
            return fullFormatter.string(from: date)
        }
        let formatter = Calendar.current.isDateInToday(date) ? todayFormatter : dateFormatter
        return formatter.string(from: date)
    }

    private static let fullFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let todayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "今天 HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// 列表行点击反馈：按下时铺一层选中底色，替代无反馈的 .plain。
private struct DriveRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? RexColor.selection : Color.clear)
    }
}

/// 网格卡片点击反馈：轻微缩放，保留卡片圆角与阴影。
private struct DriveCellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 多选底栏按钮的玻璃圆：iOS 26 走原生液态玻璃，低版本退回超薄材质 + 细描边。
private struct SelectionGlassCircle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle().stroke(RexColor.primaryText.opacity(0.10), lineWidth: 0.5)
                )
        }
    }
}

// MARK: - 单条目操作

/// 行尾 ⋯ 打开的完整操作面板，包含信息、重命名、复制、移动与删除。
private struct PanItemActionSheet: View {
    let item: PanItem
    let onInfo: () -> Void
    let onRename: () -> Void
    let onTransfer: (PanTransferMode) -> Void
    let onDelete: () -> Void
    /// 非管理员只展示详情，写操作由服务端拒绝。
    var isAdmin: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    private var kind: FileIconKind {
        item.isDir ? .folder : .fileKind(forName: item.name)
    }

    var body: some View {
        VStack(spacing: RexSpacing.sm) {
            groupCard {
                header
                    .padding(.horizontal, RexSpacing.lg)
                    .padding(.vertical, RexSpacing.md)

                if isAdmin {
                    divider
                    actionRow("复制到", systemImage: "doc.on.doc") { onTransfer(.copy) }
                    divider
                    actionRow("移动到", systemImage: "arrow.forward.folder") { onTransfer(.move) }
                    divider
                    actionRow("重命名", systemImage: "square.and.pencil") { onRename() }
                    divider
                    actionRow("删除", systemImage: "trash", isDestructive: true) { onDelete() }
                }
            }

            // 「详情」单独一张卡片。
            groupCard {
                actionRow("详情", systemImage: "info.circle") { onInfo() }
            }
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.top, RexSpacing.xxxl)
        .padding(.bottom, RexSpacing.xxl)
        .frame(maxWidth: .infinity)
        .background(RexColor.sheetBackground.ignoresSafeArea())
    }

    private func groupCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RexColor.surface,
            in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                .stroke(RexColor.primaryText.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: RexSpacing.md) {
            FileIconView(kind: kind, size: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)

                Text(panDateText(item.updatedAt))
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private func actionRow(
        _ title: String,
        systemImage: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            dismiss()
            action()
        } label: {
            HStack(spacing: RexSpacing.sm) {
                Text(title)
                    .font(RexFont.row)
                    .foregroundStyle(isDestructive ? RexColor.error : RexColor.primaryText)

                Spacer(minLength: 0)

                Image(systemName: systemImage)
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(isDestructive ? RexColor.error : RexColor.brandBlue)

                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(RexColor.tertiaryText)
            }
            .padding(.horizontal, RexSpacing.lg)
            .frame(minHeight: RexLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var divider: some View {
        Rectangle()
            .fill(RexColor.divider)
            .frame(height: 1 / displayScale)
            .padding(.horizontal, RexSpacing.lg)
    }
}

/// 多选后的批量重命名：统一前缀 + 递增序号，文件自动保留原扩展名。
private struct PanBatchRenameSheet: View {
    let items: [PanItem]
    let onConfirm: ([PanRenamePair]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var prefix = ""
    @State private var start = 1
    @FocusState private var isPrefixFocused: Bool

    private var trimmedPrefix: String {
        prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 序号位数跟着数量走，至少两位。
    private var numberWidth: Int {
        max(2, String(start + max(items.count - 1, 0)).count)
    }

    private func newName(for item: PanItem, at index: Int) -> String {
        let number = String(format: "%0\(numberWidth)d", start + index)
        var name = trimmedPrefix.isEmpty ? number : "\(trimmedPrefix) \(number)"
        guard !item.isDir else { return name }

        let ext = (item.name as NSString).pathExtension
        if !ext.isEmpty {
            name += ".\(ext)"
        }
        return name
    }

    private var pairs: [PanRenamePair] {
        items.indices.map { index in
            PanRenamePair(id: items[index].id, name: newName(for: items[index], at: index))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RexSpacing.lg) {
            VStack(alignment: .leading, spacing: 4) {
                Text("批量重命名")
                    .font(.system(.headline, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)

                Text("共 \(items.count) 项 · 文件扩展名自动保留")
                    .font(RexFont.footnote)
                    .foregroundStyle(RexColor.secondaryText)
            }
            .padding(.horizontal, RexSpacing.lg)
            .padding(.top, RexSpacing.xl)

            Rectangle()
                .fill(RexColor.divider)
                .frame(height: 1 / displayScale)

            VStack(alignment: .leading, spacing: RexSpacing.sm) {
                Text("名称前缀")
                    .font(RexFont.footnote)
                    .foregroundStyle(RexColor.secondaryText)

                TextField("可留空，只使用序号", text: $prefix)
                    .font(RexFont.body)
                    .foregroundStyle(RexColor.primaryText)
                    .padding(.horizontal, RexSpacing.md)
                    .padding(.vertical, 4)
                    .frame(minHeight: 46)
                    .background(
                        RexColor.field,
                        in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                            .strokeBorder(
                                isPrefixFocused ? RexColor.brandBlue.opacity(0.6) : Color.clear,
                                lineWidth: 1.5
                            )
                    }
                    .focused($isPrefixFocused)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, RexSpacing.lg)

            HStack(spacing: RexSpacing.md) {
                Text("起始序号")
                    .font(RexFont.row)
                    .foregroundStyle(RexColor.primaryText)

                Spacer(minLength: 0)

                Text("\(start)")
                    .font(RexFont.rowValue)
                    .foregroundStyle(RexColor.secondaryText)
                    .monospacedDigit()

                Stepper("起始序号", value: $start, in: 1...9999)
                    .labelsHidden()
            }
            .padding(.horizontal, RexSpacing.lg)
            .frame(minHeight: 46)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.prefix(3).indices, id: \.self) { index in
                    Text(newName(for: items[index], at: index))
                        .font(RexFont.footnote)
                        .foregroundStyle(RexColor.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if items.count > 3 {
                    Text("… 共 \(items.count) 项")
                        .font(RexFont.caption)
                        .foregroundStyle(RexColor.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(RexSpacing.md)
            .background(
                RexColor.field,
                in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
            )
            .padding(.horizontal, RexSpacing.lg)

            Spacer(minLength: 0)

            HStack(spacing: RexSpacing.md) {
                Button {
                    dismiss()
                } label: {
                    Text("取消")
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(RexColor.primaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(
                            RexColor.field,
                            in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                        )
                }
                .buttonStyle(PressableButtonStyle())

                Button {
                    RexHaptics.success()
                    let result = pairs
                    dismiss()
                    onConfirm(result)
                } label: {
                    Text("开始重命名")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(RexColor.onBrand)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(
                            RexColor.brandGradient,
                            in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                        )
                        .shadow(
                            color: RexColor.brandBlue.opacity(0.24),
                            radius: 10,
                            y: 4
                        )
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(items.isEmpty)
                .opacity(items.isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, RexSpacing.lg)
        }
        .padding(.bottom, RexSpacing.xxl)
        .background(RexColor.surface)
    }
}

/// 单条目信息面板：类型、大小、修改时间与文件 ID。
private struct PanItemInfoSheet: View {
    let item: PanItem

    @Environment(\.displayScale) private var displayScale

    private var kind: FileIconKind {
        item.isDir ? .folder : .fileKind(forName: item.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: RexSpacing.md) {
                FileIconView(kind: kind, size: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(RexColor.primaryText)
                        .lineLimit(2)

                    Text(panTypeLabel(for: item))
                        .font(RexFont.caption)
                        .foregroundStyle(RexColor.secondaryText)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, RexSpacing.lg)
            .padding(.vertical, RexSpacing.lg)

            divider

            infoRow("类型", panTypeLabel(for: item))
            divider
            infoRow("大小", panSizeText(for: item))
            divider
            infoRow("修改时间", panDateText(item.updatedAt))
            divider
            infoRow("文件 ID", item.id)

            Spacer(minLength: 0)
        }
        .background(RexColor.surface)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .center, spacing: RexSpacing.md) {
            Text(title)
                .font(RexFont.footnote)
                .foregroundStyle(RexColor.secondaryText)

            Spacer(minLength: RexSpacing.sm)

            Text(value)
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(minHeight: 44)
    }

    private var divider: some View {
        Rectangle()
            .fill(RexColor.divider)
            .frame(height: 1 / displayScale)
            .padding(.leading, RexSpacing.lg)
    }
}

private func panTypeLabel(for item: PanItem) -> String {
    if item.isDir { return "文件夹" }

    let ext = (item.name as NSString).pathExtension
    switch FileIconKind.fileKind(forName: item.name) {
    case .video: return "视频"
    case .audio: return "音频"
    case .image: return "图片"
    case .pdf: return "PDF"
    case .ppt: return "演示文稿"
    case .excel: return "表格"
    case .document: return "文档"
    case .text: return "文本"
    case .archive: return "压缩包"
    default: return ext.isEmpty ? "文件" : ext.uppercased()
    }
}

private func panSizeText(for item: PanItem) -> String {
    item.isDir ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
}

private func panDateText(_ timestamp: Int64) -> String {
    guard timestamp > 0 else { return "—" }
    return Date(timeIntervalSince1970: TimeInterval(timestamp))
        .formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
}

#Preview {
    NavigationStack {
        DriveView(isAdmin: true)
            .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - 缩略图

/// 115 缩略图：先查内存缓存，加载完成前与失败时回退到图片图标。
private struct PanThumbnailView: View {
    let item: PanItem
    let theme: FileFolderTheme
    let size: CGFloat

    @Environment(\.apiClient) private var apiClient
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                FileIconView(kind: .image, theme: theme, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .task(id: item.sha1) { await load() }
    }

    private func load() async {
        let key = item.sha1
        if let cached = ThumbnailCache.shared.image(for: key) {
            image = cached
            return
        }
        guard let client = apiClient,
              let data = try? await client.panThumbnail(sha1: key),
              let decoded = UIImage(data: data) else { return }
        ThumbnailCache.shared.store(decoded, for: key)
        image = decoded
    }
}

/// `NSCache` 本身线程安全，可在任意线程读写。
private final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 400
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}
