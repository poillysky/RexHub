import SwiftUI
import UIKit

/// 115 云下载：任务列表（正在下载 / 下载失败 / 完成记录）与添加链接入口。
/// 与 115 网页端的云下载一致，任务操作全部由 NAS 服务端转发。
struct PanCloudDownloadView: View {
    /// 非管理员只读：添加/重试/删除都由服务端校验管理员权限。
    var isAdmin: Bool = false

    @Environment(\.apiClient) private var apiClient

    @State private var tab: CloudTab = .downloading
    @State private var quota = PanCloudQuota(remaining: 0, total: 0)
    @State private var allTasks: [PanCloudTask] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var isAdding = false
    @State private var pendingDelete: PanCloudTask?
    @State private var alert: RexAlertInfo?
    @State private var loadVersion = 0

    private enum CloudTab: Int, CaseIterable, Identifiable {
        case downloading
        case failed
        case finished

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .downloading: return "正在下载"
            case .failed: return "下载失败"
            case .finished: return "完成记录"
            }
        }

        var emptyText: String {
            switch self {
            case .downloading: return "没有正在下载的任务"
            case .failed: return "没有失败的任务"
            case .finished: return "还没有完成记录"
            }
        }

        /// 和 PWA 一致按任务实际状态归类：完成 = 进度 100%，失败 = 状态含「失败」，其余算进行中。
        /// 115 的 stat 分组（10、1-8）与服务端计数口径不同，不能直接按 stat 过滤。
        func matches(_ task: PanCloudTask) -> Bool {
            let isFailed = task.status == "failed" || task.statusText.contains("失败")

            switch self {
            case .failed:
                return isFailed
            case .finished:
                return !isFailed && task.percent >= 100
            case .downloading:
                return !isFailed && task.percent < 100
            }
        }

        func count(in tasks: [PanCloudTask]) -> Int {
            tasks.filter(matches).count
        }
    }

    var body: some View {
        SettingsPage(
            title: "云下载",
            actions: [
                RexNavAction(
                    systemImage: "arrow.clockwise",
                    label: "刷新",
                    isEnabled: !isLoading,
                    action: { Task { await load(silent: !allTasks.isEmpty) } }
                )
            ]
        ) {
            header

            if tasks.isEmpty {
                if isLoading {
                    loadingCard
                } else if let errorText {
                    failureCard(errorText)
                } else {
                    emptyCard
                }
            } else {
                taskSection
            }
        }
        .task {
            guard allTasks.isEmpty else { return }
            await load()
        }
        .task(id: tab) {
            // 下载中每 5 秒静默刷新一次，和 PWA 云下载页保持一致。
            guard tab == .downloading else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await load(silent: true)
            }
        }
        .sheet(isPresented: $isAdding) {
            PanCloudAddSheet(quota: quota) { count in
                tab = .downloading
                Task {
                    await load()
                    try? await Task.sleep(for: .milliseconds(350))
                    showSuccess("已添加 \(count) 个任务")
                }
            }
            .rexSheetStyle()
        }
        .confirmationDialog(
            "删除这个任务？",
            isPresented: deleteBinding,
            presenting: pendingDelete
        ) { task in
            Button("删除", role: .destructive) {
                Task { await remove(task) }
            }
            Button("取消", role: .cancel) {}
        } message: { task in
            Text("「\(task.name)」将从云下载列表移除，已保存到网盘的文件不受影响。")
        }
        .rexAlert($alert)
    }

    // MARK: - 顶部

    private var header: some View {
        SettingsCard {
            VStack(spacing: 0) {
                HStack(spacing: RexSpacing.sm) {
                    Image("Brand115")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .frame(width: 32, height: 32)
                        .background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(RexColor.divider, lineWidth: 1)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("云下载")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(RexColor.primaryText)

                        Text("本月配额 · 剩 \(quota.remaining)/\(quota.total) 个")
                            .font(RexFont.caption)
                            .foregroundStyle(RexColor.secondaryText)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }

                    Spacer(minLength: RexSpacing.xs)

                    if isAdmin {
                        Button {
                            RexHaptics.tap()
                            isAdding = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .bold))

                                Text("添加云下载")
                                    .font(.system(.caption, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            }
                            .foregroundStyle(RexColor.onBrand)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(RexColor.brandGradient, in: Capsule(style: .continuous))
                            .frame(minHeight: RexLayout.minTouch)
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
                .padding(.horizontal, RexSpacing.md)
                .padding(.vertical, 10)

                SettingsDivider()

                HStack(spacing: 4) {
                    ForEach(CloudTab.allCases) { item in
                        tabButton(item)
                    }
                }
                .padding(.horizontal, RexSpacing.sm)
                .padding(.vertical, 4)
            }
        }
    }

    private func tabButton(_ item: CloudTab) -> some View {
        let isSelected = tab == item

        return Button {
            RexHaptics.selection()
            select(item)
        } label: {
            HStack(spacing: 4) {
                Text(item.title)
                    .font(.system(.caption, weight: isSelected ? .semibold : .regular))

                Text("\(item.count(in: allTasks))")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 4)
                    .frame(height: 16)
                    .background(
                        isSelected ? Color.white.opacity(0.24) : RexColor.field,
                        in: Capsule()
                    )
            }
            .foregroundStyle(isSelected ? RexColor.onBrand : RexColor.secondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background {
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(RexColor.brandGradient)
                        : AnyShapeStyle(Color.clear)
                )
            }
            .shadow(
                color: isSelected ? RexColor.brandBlue.opacity(0.3) : .clear,
                radius: 6,
                y: 3
            )
            .frame(minHeight: RexLayout.minTouch)
        }
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: - 任务列表

    private var taskSection: some View {
        SettingsCard {
            VStack(spacing: 0) {
                ForEach(tasks) { task in
                    taskRow(task)

                    if task.id != tasks.last?.id {
                        SettingsDivider()
                    }
                }
            }
        }
    }

    /// 当前 Tab 的任务：由完整任务列表按状态归类得到，和 PWA 行为一致。
    private var tasks: [PanCloudTask] {
        allTasks.filter(tab.matches)
    }

    private func taskRow(_ task: PanCloudTask) -> some View {
        HStack(alignment: .top, spacing: RexSpacing.sm) {
            taskIcon(task)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.name)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)

                Text(subtitle(task))
                    .font(RexFont.caption2)
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)

                if tab == .downloading {
                    progressBar(task)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: RexSpacing.xs)

            VStack(alignment: .trailing, spacing: 0) {
                Text(statusText(task))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(statusColor(task))
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(statusColor(task).opacity(0.12), in: Capsule(style: .continuous))

                Menu {
                    menuItems(task)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RexColor.secondaryText)
                        .frame(width: 44, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("任务操作")
            }
        }
        .padding(.horizontal, RexSpacing.md)
        .padding(.vertical, 8)
        .frame(minHeight: 54)
    }

    private func taskIcon(_ task: PanCloudTask) -> some View {
        let isFile = task.name.contains(".")
        let color = isFile ? RexColor.brandBlue : Color(hex: 0xF5B54A)

        return Image(systemName: isFile ? "doc.fill" : "folder.fill")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 30, height: 30)
            .background(
                color.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
    }

    private func progressBar(_ task: PanCloudTask) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(RexColor.field)

                Capsule()
                    .fill(RexColor.brandGradient)
                    .frame(width: max(6, proxy.size.width * fraction(task)))
            }
        }
        .frame(height: 4)
    }

    @ViewBuilder
    private func menuItems(_ task: PanCloudTask) -> some View {
        if isAdmin {
            if isFailed(task) {
                Button {
                    Task { await retry(task) }
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
            }

            Button(role: .destructive) {
                pendingDelete = task
            } label: {
                Label("删除", systemImage: "trash")
            }
        }

        if !task.url.isEmpty {
            Button {
                copyLink(task)
            } label: {
                Label("复制链接", systemImage: "doc.on.doc")
            }
        }
    }

    // MARK: - 状态卡

    private var loadingCard: some View {
        RexStateCard(
            symbol: "arrow.down.circle",
            title: "正在读取云下载任务",
            message: "任务状态由 NAS 服务端同步。",
            tone: .brand,
            isLoading: true
        )
    }

    private var emptyCard: some View {
        let canAdd = isAdmin && tab != .finished

        return RexStateCard(
            symbol: "arrow.down.circle",
            title: tab.emptyText,
            message: tab == .finished
                ? "完成的任务会记录在这里，方便日后查看。"
                : "粘贴磁力或 HTTP 链接，即可交给 115 离线下载。",
            tone: .neutral,
            actionTitle: canAdd ? "添加云下载" : nil,
            action: canAdd ? {
                RexHaptics.tap()
                isAdding = true
            } : nil
        )
    }

    private func failureCard(_ message: String) -> some View {
        RexStateCard(
            symbol: "wifi.exclamationmark",
            title: "任务列表加载失败",
            message: message,
            tone: .warning,
            actionTitle: "重试"
        ) {
            RexHaptics.tap()
            Task { await load() }
        }
    }

    // MARK: - 展示辅助

    private func subtitle(_ task: PanCloudTask) -> String {
        let size = task.size > 0
            ? ByteCountFormatter.string(fromByteCount: task.size, countStyle: .file)
            : "--"
        return "\(size) · \(Self.dateText(task.addTime))"
    }

    private func statusText(_ task: PanCloudTask) -> String {
        if isFailed(task) {
            return task.statusText.isEmpty ? "下载失败" : task.statusText
        }
        if task.percent >= 100 {
            return task.statusText.isEmpty ? "已完成" : task.statusText
        }
        return "\(Int(task.percent.rounded()))%"
    }

    private func statusColor(_ task: PanCloudTask) -> Color {
        if isFailed(task) { return RexColor.error }
        if task.percent >= 100 { return RexColor.success }
        return RexColor.brandBlue
    }

    private func fraction(_ task: PanCloudTask) -> CGFloat {
        min(1, max(0, CGFloat(task.percent) / 100))
    }

    private func isFailed(_ task: PanCloudTask) -> Bool {
        task.status == "failed" || task.statusText.contains("失败")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd EEE HH:mm"
        return formatter
    }()

    private static func dateText(_ timestamp: Int64) -> String {
        guard timestamp > 0 else { return "--" }
        return dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    // MARK: - 数据

    private func select(_ item: CloudTab) {
        guard tab != item else { return }

        tab = item
        errorText = nil

        if allTasks.isEmpty {
            Task { await load(silent: true) }
        }
    }

    /// 拉取全部云下载任务（最多 5 页，和 PWA 一致），再按状态归类到各 Tab。
    /// `silent` 为 true 时保留当前列表做后台刷新，不显示加载态。
    private func load(silent: Bool = false) async {
        guard let client = apiClient else {
            errorText = "登录状态已失效，请重新登录"
            return
        }

        loadVersion += 1
        let version = loadVersion

        isLoading = true
        if !silent {
            errorText = nil
        }
        defer {
            if version == loadVersion {
                isLoading = false
            }
        }

        do {
            let firstPage = try await client.panCloudTasks(stat: 0, page: 1)
            var collected = firstPage.tasks
            let lastPage = min(max(firstPage.pageCount, 1), 5)

            if lastPage > 1, !firstPage.tasks.isEmpty {
                for page in 2...lastPage {
                    let nextPage = try await client.panCloudTasks(stat: 0, page: page)
                    guard version == loadVersion else { return }
                    collected.append(contentsOf: nextPage.tasks)
                    if nextPage.tasks.isEmpty { break }
                }
            }

            guard version == loadVersion else { return }

            var seen = Set<String>()
            allTasks = collected.filter { seen.insert($0.id).inserted }
            quota = firstPage.quota
        } catch let error as APIError {
            guard version == loadVersion, error != .cancelled else { return }
            if !silent || allTasks.isEmpty {
                errorText = message(for: error)
            }
        } catch {
            guard version == loadVersion else { return }
            if !silent || allTasks.isEmpty {
                errorText = "读取云下载任务失败，请重试"
            }
        }
    }

    private func retry(_ task: PanCloudTask) async {
        guard let client = apiClient else { return }

        do {
            try await client.panCloudRetry(infoHash: task.infoHash)
            showSuccess("已重新开始下载")
            await load(silent: true)
        } catch let error as APIError {
            guard error != .cancelled else { return }
            alert = .failure(message(for: error))
        } catch {
            alert = .failure("重试失败，请稍后再试")
        }
    }

    private func remove(_ task: PanCloudTask) async {
        guard let client = apiClient else { return }

        do {
            try await client.panCloudDelete(infoHash: task.infoHash)
            allTasks.removeAll { $0.id == task.id }
            showSuccess("已删除任务")
            await load(silent: true)
        } catch let error as APIError {
            guard error != .cancelled else { return }
            alert = .failure(message(for: error))
        } catch {
            alert = .failure("删除失败，请稍后再试")
        }
    }

    private func copyLink(_ task: PanCloudTask) {
        UIPasteboard.general.string = task.url
        showSuccess("链接已复制")
    }

    private func showSuccess(_ text: String) {
        RexHaptics.success()
        alert = .success(text)
    }

    private func message(for error: APIError) -> String {
        if case .conflict(let detail) = error, let detail, !detail.isEmpty {
            return detail
        }
        return error.errorDescription ?? "读取云下载任务失败，请重试"
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }
}

// MARK: - 添加云下载

private struct PanCloudAddSheet: View {
    let quota: PanCloudQuota
    var onAdded: (Int) -> Void

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var target = PanFolder(cid: "0", name: "根目录")
    @State private var isPickingFolder = false
    @State private var isSubmitting = false
    @State private var alert: RexAlertInfo?
    @FocusState private var isEditing: Bool

    private var links: [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var canSubmit: Bool {
        !links.isEmpty && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RexSpacing.xl) {
                    noticeCard

                    VStack(alignment: .leading, spacing: RexSpacing.sm) {
                        fieldLabel("下载链接")
                        editorCard

                        if !links.isEmpty {
                            RexBadge(
                                text: "已识别 \(links.count) 条链接",
                                symbol: "checkmark.circle.fill",
                                tint: RexColor.brandBlue
                            )
                        }
                    }

                    VStack(alignment: .leading, spacing: RexSpacing.sm) {
                        fieldLabel("保存位置")
                        folderRow
                    }
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.top, RexSpacing.md)
                .padding(.bottom, RexSpacing.xl)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(RexPageBackground())
            .navigationTitle("添加云下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        RexHaptics.tap()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(RexColor.secondaryText)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                footer
            }
            .sheet(isPresented: $isPickingFolder) {
                PanFolderPicker(selected: $target)
                    .rexSheetStyle()
            }
            .task {
                try? await Task.sleep(for: .milliseconds(300))
                isEditing = true
            }
            .rexAlert($alert)
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(RexFont.section)
            .foregroundStyle(RexColor.secondaryText)
            .padding(.leading, RexSpacing.xs)
    }

    private var noticeCard: some View {
        RexInlineNotice(
            title: "使用须知",
            message: "请遵守《115 生活用户服务协议》，仅添加你有权下载的内容，严禁下载违法违规或侵权资源。",
            tone: .warning
        )
    }

    private var editorCard: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("支持 HTTP、HTTPS、FTP、磁力链和电驴链接，换行可添加多个")
                    .font(RexFont.subheadline)
                    .foregroundStyle(RexColor.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .font(RexFont.body)
                .foregroundStyle(RexColor.primaryText)
                .scrollContentBackground(.hidden)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .focused($isEditing)
        }
        .frame(minHeight: 180)
        .background(
            RexColor.field,
            in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                .strokeBorder(
                    isEditing ? RexColor.brandBlue.opacity(0.65) : RexColor.fieldBorder,
                    lineWidth: isEditing ? 1.5 : 1
                )
        }
    }

    private var folderRow: some View {
        Button {
            RexHaptics.tap()
            isEditing = false
            isPickingFolder = true
        } label: {
            HStack(spacing: RexSpacing.md) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xF5B54A))
                    .frame(width: 32, height: 32)
                    .background(
                        Color(hex: 0xF5B54A).opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )

                Text("保存到")
                    .font(RexFont.row)
                    .foregroundStyle(RexColor.primaryText)

                Spacer(minLength: RexSpacing.sm)

                Text(target.name)
                    .font(RexFont.rowValue)
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(RexColor.tertiaryText)
            }
            .padding(.horizontal, RexSpacing.lg)
            .frame(minHeight: RexLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RexRowButtonStyle())
        .rexCard()
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: RexSpacing.md) {
                Text("本月配额：剩 \(quota.remaining)/总 \(quota.total) 个")
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .monospacedDigit()

                Spacer(minLength: RexSpacing.sm)

                Button {
                    RexHaptics.tap()
                    Task { await submit() }
                } label: {
                    ZStack {
                        if isSubmitting {
                            ProgressView()
                                .tint(RexColor.onBrand)
                        } else {
                            Text("开始下载")
                                .font(RexFont.button)
                        }
                    }
                    .foregroundStyle(RexColor.onBrand)
                    .padding(.horizontal, 24)
                    .frame(height: RexLayout.minTouch)
                    .background(
                        RexColor.brandGradient,
                        in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                    )
                    .opacity(canSubmit ? 1 : 0.45)
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(!canSubmit)
            }
            .padding(.horizontal, RexSpacing.xl)
            .padding(.vertical, RexSpacing.md)
            .background(.ultraThinMaterial)
        }
    }

    private func submit() async {
        guard canSubmit, let client = apiClient else { return }

        isEditing = false
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let count = try await client.panCloudAdd(urls: links, cid: target.cid)
            RexHaptics.success()
            onAdded(count)
            dismiss()
        } catch let error as APIError {
            guard error != .cancelled else { return }
            alert = .failure(message(for: error))
        } catch {
            alert = .failure("添加失败，请稍后再试")
        }
    }

    private func message(for error: APIError) -> String {
        if case .conflict(let detail) = error, let detail, !detail.isEmpty {
            return detail
        }
        return error.errorDescription ?? "添加失败，请稍后再试"
    }
}

#Preview {
    NavigationStack {
        PanCloudDownloadView()
            .toolbar(.hidden, for: .navigationBar)
    }
}
