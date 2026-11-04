import SwiftUI
import UIKit

/// 115 云下载：任务列表（正在下载 / 下载失败 / 完成记录）与添加链接入口。
/// 与 115 网页端的云下载一致，任务操作全部由 NAS 服务端转发。
struct PanCloudDownloadView: View {
    @Environment(\.apiClient) private var apiClient

    @State private var tab: CloudTab = .downloading
    @State private var counts = PanCloudCounts(total: 0, downloading: 0, failed: 0, finished: 0)
    @State private var quota = PanCloudQuota(remaining: 0, total: 0)
    @State private var tasks: [PanCloudTask] = []
    @State private var page = 1
    @State private var pageCount = 1
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var isAdding = false
    @State private var pendingDelete: PanCloudTask?
    @State private var alertText: String?
    @State private var toast: String?
    @State private var cachedTabs: [Int: TabSnapshot] = [:]
    @State private var loadVersion = 0

    /// 每个 Tab 的列表快照：切回已看过的 Tab 时先显示缓存，再静默刷新。
    private struct TabSnapshot {
        var tasks: [PanCloudTask]
        var page: Int
        var pageCount: Int
    }

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

        /// 115 的 stat：1-9 失败、10-11 已完成、12 进行中。
        var stat: Int {
            switch self {
            case .downloading: return 12
            case .failed: return 9
            case .finished: return 11
            }
        }

        var emptyText: String {
            switch self {
            case .downloading: return "没有正在下载的任务"
            case .failed: return "没有失败的任务"
            case .finished: return "还没有完成记录"
            }
        }

        func count(_ counts: PanCloudCounts) -> Int {
            switch self {
            case .downloading: return counts.downloading
            case .failed: return counts.failed
            case .finished: return counts.finished
            }
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
                    action: { Task { await load(reset: true, silent: !tasks.isEmpty) } }
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
            guard tasks.isEmpty else { return }
            await load(reset: true)
        }
        .sheet(isPresented: $isAdding) {
            PanCloudAddSheet(quota: quota) { count in
                showToast("已添加 \(count) 个任务")
                tab = .downloading
                Task { await load(reset: true) }
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
        .alert("操作失败", isPresented: alertBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alertText ?? "")
        }
        .overlay(alignment: .top) {
            if let toast {
                RexToastBanner(message: toast)
                    .padding(.horizontal, RexSpacing.xl)
                    .padding(.top, RexSpacing.sm)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(RexMotion.quick, value: toast)
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

                Text("\(item.count(counts))")
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

                if page < pageCount {
                    SettingsDivider()

                    Button {
                        Task { await load(reset: false) }
                    } label: {
                        HStack(spacing: RexSpacing.sm) {
                            if isLoading {
                                ProgressView()
                            }

                            Text(isLoading ? "正在加载…" : "加载更多")
                                .font(.system(.subheadline, weight: .medium))
                                .foregroundStyle(RexColor.brandBlue)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: RexLayout.minTouch)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(isLoading)
                }
            }
        }
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
        if isFailed(task) {
            Button {
                Task { await retry(task) }
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
            }
        }

        if !task.url.isEmpty {
            Button {
                copyLink(task)
            } label: {
                Label("复制链接", systemImage: "doc.on.doc")
            }
        }

        Button(role: .destructive) {
            pendingDelete = task
        } label: {
            Label("删除", systemImage: "trash")
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
        RexStateCard(
            symbol: "arrow.down.circle",
            title: tab.emptyText,
            message: tab == .finished
                ? "完成的任务会记录在这里，方便日后查看。"
                : "粘贴磁力或 HTTP 链接，即可交给 115 离线下载。",
            tone: .neutral,
            actionTitle: tab == .finished ? nil : "添加云下载",
            action: tab == .finished ? nil : {
                RexHaptics.tap()
                isAdding = true
            }
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
            Task { await load(reset: true) }
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
        if tab == .downloading {
            return "\(Int(task.percent.rounded()))%"
        }
        return task.statusText.isEmpty ? "已完成" : task.statusText
    }

    private func statusColor(_ task: PanCloudTask) -> Color {
        if isFailed(task) { return RexColor.error }
        if tab == .downloading { return RexColor.brandBlue }
        return RexColor.success
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

        cachedTabs[tab.rawValue] = TabSnapshot(tasks: tasks, page: page, pageCount: pageCount)

        let cached = cachedTabs[item.rawValue]
        tab = item
        tasks = cached?.tasks ?? []
        page = cached?.page ?? 1
        pageCount = cached?.pageCount ?? 1
        errorText = nil

        Task { await load(reset: true, silent: cached != nil) }
    }

    /// `silent` 为 true 时保留当前列表做后台刷新，不显示加载态。
    private func load(reset: Bool, silent: Bool = false) async {
        guard let client = apiClient else {
            errorText = "登录状态已失效，请重新登录"
            return
        }

        let requestedTab = tab
        let requestedPage = reset ? 1 : page + 1

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
            let result = try await client.panCloudTasks(
                stat: requestedTab.stat,
                page: requestedPage
            )
            guard version == loadVersion, tab == requestedTab else { return }

            counts = result.counts
            quota = result.quota
            page = result.page
            pageCount = result.pageCount
            tasks = reset ? result.tasks : tasks + result.tasks
            cachedTabs[requestedTab.rawValue] = TabSnapshot(
                tasks: tasks,
                page: page,
                pageCount: pageCount
            )
        } catch let error as APIError {
            guard version == loadVersion, error != .cancelled else { return }
            if !silent || tasks.isEmpty {
                errorText = message(for: error)
            }
        } catch {
            guard version == loadVersion else { return }
            if !silent || tasks.isEmpty {
                errorText = "读取云下载任务失败，请重试"
            }
        }
    }

    private func retry(_ task: PanCloudTask) async {
        guard let client = apiClient else { return }

        do {
            try await client.panCloudRetry(infoHash: task.infoHash)
            showToast("已重新开始下载")
            await load(reset: true)
        } catch let error as APIError {
            guard error != .cancelled else { return }
            alertText = message(for: error)
        } catch {
            alertText = "重试失败，请稍后再试"
        }
    }

    private func remove(_ task: PanCloudTask) async {
        guard let client = apiClient else { return }

        do {
            try await client.panCloudDelete(infoHash: task.infoHash)
            tasks.removeAll { $0.id == task.id }
            showToast("已删除任务")
            await load(reset: true)
        } catch let error as APIError {
            guard error != .cancelled else { return }
            alertText = message(for: error)
        } catch {
            alertText = "删除失败，请稍后再试"
        }
    }

    private func copyLink(_ task: PanCloudTask) {
        UIPasteboard.general.string = task.url
        showToast("链接已复制")
    }

    private func showToast(_ text: String) {
        RexHaptics.success()
        withAnimation(RexMotion.quick) {
            toast = text
        }

        Task {
            try? await Task.sleep(for: .seconds(2))
            guard toast == text else { return }
            withAnimation(RexMotion.quick) {
                toast = nil
            }
        }
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

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { alertText != nil },
            set: { if !$0 { alertText = nil } }
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
    @State private var errorText: String?
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

                    if let errorText {
                        errorCard(errorText)
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

    private func errorCard(_ message: String) -> some View {
        RexInlineNotice(
            title: "添加失败",
            message: message,
            tone: .error
        )
    }

    private func submit() async {
        guard canSubmit, let client = apiClient else { return }

        isEditing = false
        isSubmitting = true
        errorText = nil
        defer { isSubmitting = false }

        do {
            let count = try await client.panCloudAdd(urls: links, cid: target.cid)
            RexHaptics.success()
            onAdded(count)
            dismiss()
        } catch let error as APIError {
            guard error != .cancelled else { return }
            errorText = message(for: error)
        } catch {
            errorText = "添加失败，请稍后再试"
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
