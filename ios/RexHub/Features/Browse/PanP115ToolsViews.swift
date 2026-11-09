import SwiftUI

// MARK: - 文件转存

/// 按来源设置 115 的转存目录：搜索、影视、片商。
struct PanTransferConfigView: View {
    var isAdmin: Bool = false

    @Environment(\.apiClient) private var apiClient

    @State private var targets: [String: P115TargetFolder] = [:]
    @State private var isLoading = true
    @State private var savingKey: String?
    @State private var alert: RexAlertInfo?
    @State private var picking: TransferSource?

    private struct TransferSource: Identifiable {
        let key: String
        let title: String

        var id: String { key }
    }

    private let sources: [TransferSource] = [
        TransferSource(key: "search", title: "搜索转存"),
        TransferSource(key: "media", title: "影视转存"),
        TransferSource(key: "maker", title: "片商转存")
    ]

    var body: some View {
        SettingsPage(title: "文件转存") {
            if isLoading {
                RexSkeleton(width: .infinity, height: 180, cornerRadius: RexRadius.panel)
            } else {
                SettingsCard {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                        if index > 0 { SettingsDivider() }

                        Button {
                            picking = source
                        } label: {
                            row(source)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .disabled(!isAdmin || savingKey != nil)
                    }
                }

                if !isAdmin {
                    RexNote(text: "当前账号不是管理员，只能查看转存目录。")
                }
            }
        }
        .task { await load() }
        .rexAlert($alert)
        .rexBottomDrawer(item: $picking) { source in
            PanFolderPickerView(
                mode: .select,
                isAdmin: isAdmin,
                onPickNamed: { cid, name in
                    Task { await save(source, cid: cid, name: name) }
                },
                onPick: { _ in }
            )
        }
    }

    // MARK: - 行

    private func row(_ source: TransferSource) -> some View {
        HStack(spacing: RexSpacing.md) {
            Text(source.title)
                .font(RexFont.row)
                .foregroundStyle(RexColor.primaryText)

            Spacer(minLength: RexSpacing.sm)

            Text(folderName(source))
                .font(RexFont.rowValue)
                .foregroundStyle(targets[source.key]?.folderCid == nil ? RexColor.tertiaryText : RexColor.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            if savingKey == source.key {
                ProgressView()
                    .controlSize(.small)
            } else if isAdmin {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(RexColor.tertiaryText)
            }
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(minHeight: RexLayout.rowHeight)
        .contentShape(Rectangle())
    }

    private func folderName(_ source: TransferSource) -> String {
        guard let target = targets[source.key] else { return "未设置" }
        if let name = target.folderName, !name.isEmpty { return name }
        return target.folderCid == "0" ? "根目录" : "已选择"
    }

    // MARK: - 数据

    private func load() async {
        guard let apiClient else {
            alert = .failure("登录状态已失效，请重新登录")
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let settings = try await apiClient.fetchSettings("api/settings/p115", as: P115Settings.self)
            targets = settings.targets ?? [:]
        } catch {
            alert = .failure(message(for: error))
        }
    }

    private func save(_ source: TransferSource, cid: String, name: String) async {
        guard let apiClient else { return }
        savingKey = source.key
        defer { savingKey = nil }
        do {
            let payload = P115TargetsSaveBody(
                targets: [source.key: .init(folderCid: cid, folderName: name)]
            )
            let body = try JSONEncoder().encode(payload)
            let settings = try await apiClient.putSettings(
                "api/settings/p115",
                json: body,
                as: P115Settings.self
            )
            targets = settings.targets ?? targets
            targets[source.key] = P115TargetFolder(folderCid: cid, folderName: name)
            alert = .success("\(source.title)目录已更新", title: "已保存")
            RexHaptics.success()
        } catch {
            alert = .failure(message(for: error))
        }
    }

    private func message(for error: Error) -> String {
        (error as? APIError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - 文件解压

/// 扫描指定 115 目录里的压缩包并解压，进度来自服务端任务快照。
struct PanExtractView: View {
    var isAdmin: Bool = false

    @Environment(\.apiClient) private var apiClient

    @State private var config: P115ExtractConfig?
    @State private var status: P115ExtractStatus?
    @State private var previewItems: [P115ExtractItem] = []
    @State private var counts: P115ExtractCounts?

    @State private var isLoading = true
    @State private var isBusy = false
    @State private var isPreviewing = false
    @State private var hasScanned = false
    @State private var isShowingFolderPicker = false
    @State private var isEditingPassword = false
    @State private var passwordDraft = ""
    @State private var errorText: String?
    @State private var alert: RexAlertInfo?

    private let displayLimit = 60

    private var isRunning: Bool { status?.running == true }
    private var isScanningNow: Bool { status?.scanning == true }

    var body: some View {
        SettingsPage(title: "文件解压") {
            if !isAdmin {
                RexNote(text: "只有管理员可以配置目录与解压任务。")
            } else if isLoading {
                RexSkeleton(width: .infinity, height: 160, cornerRadius: RexRadius.panel)
            } else if config == nil {
                RexStateCard(
                    symbol: "wifi.exclamationmark",
                    title: "配置加载失败",
                    message: errorText ?? "请检查网络后重试。",
                    tone: .warning,
                    actionTitle: "重试"
                ) {
                    RexHaptics.tap()
                    Task { await load() }
                }
            } else {
                configCard
                actionButtons
                progressSection
            }
        }
        .task { await load() }
        .task {
            guard isAdmin else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                // 空闲时不再空转请求，只在扫描或解压进行中同步服务端状态。
                guard isRunning || isScanningNow || isPreviewing else { continue }
                await refreshStatus()
            }
        }
        .rexBottomDrawer(isPresented: $isShowingFolderPicker) {
            PanFolderPickerView(
                mode: .select,
                isAdmin: isAdmin,
                onPickNamed: { cid, name in
                    Task { await saveConfig(cid: cid, folderName: name) }
                },
                onPick: { _ in }
            )
        }
        .alert("解压密码", isPresented: $isEditingPassword) {
            SecureField("留空表示无密码", text: $passwordDraft)
            Button("取消", role: .cancel) {}
            Button("保存") {
                Task { await saveConfig(password: passwordDraft) }
            }
        } message: {
            Text("多个候选密码可以用逗号或换行分隔。")
        }
        .rexAlert($alert)
    }

    // MARK: - 配置

    private var configCard: some View {
        SettingsCard {
            Button {
                isShowingFolderPicker = true
            } label: {
                configRow(
                    title: "解压目录",
                    value: folderNameText
                )
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isBusy)

            SettingsDivider()

            Button {
                passwordDraft = config?.password ?? ""
                isEditingPassword = true
            } label: {
                configRow(
                    title: "解压密码",
                    value: passwordText
                )
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isBusy)

            SettingsDivider()

            NavigationLink {
                PanExtractFlowView()
            } label: {
                configRow(title: "解压流程", value: "查看处理步骤")
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    private func configRow(title: String, value: String) -> some View {
        HStack(spacing: RexSpacing.md) {
            Text(title)
                .font(RexFont.row)
                .foregroundStyle(RexColor.primaryText)

            Spacer(minLength: RexSpacing.sm)

            Text(value)
                .font(RexFont.rowValue)
                .foregroundStyle(RexColor.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            Image(systemName: "chevron.right")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(RexColor.tertiaryText)
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(minHeight: RexLayout.rowHeight)
        .contentShape(Rectangle())
    }

    // MARK: - 操作按钮

    private var actionButtons: some View {
        HStack(spacing: RexSpacing.md) {
            if isRunning {
                Button {
                    Task { await stop() }
                } label: {
                    HStack(spacing: RexSpacing.sm) {
                        if isBusy {
                            ProgressView()
                                .controlSize(.small)
                                .tint(RexColor.error)
                        } else {
                            Image(systemName: "stop.fill")
                        }
                        Text("停止解压")
                    }
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(RexColor.error)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(
                        RexColor.error.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                    )
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(isBusy)
            } else {
                Button {
                    Task { await scan() }
                } label: {
                    HStack(spacing: RexSpacing.sm) {
                        if isBusy {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                        Text("扫描压缩包")
                    }
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(RexColor.primaryText)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(
                        RexColor.surface,
                        in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                            .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(isBusy)

                Button {
                    Task { await start() }
                } label: {
                    HStack(spacing: RexSpacing.sm) {
                        Image(systemName: "play.fill")
                        Text("开始解压")
                    }
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(RexColor.onBrand)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(
                        RexColor.brandGradient,
                        in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                    )
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(isBusy || !hasScanned)
                .opacity(hasScanned ? 1 : 0.5)
            }
        }
    }

    // MARK: - 进度

    private var progressSection: some View {
        SettingsSection(title: "解压进度") {
            summary.padding(RexSpacing.lg)

            if showsSkeleton {
                skeletonRows
            } else if displayItems.isEmpty {
                SettingsDivider()
                emptyState.padding(RexSpacing.lg)
            } else {
                ForEach(displayItems.prefix(displayLimit)) { item in
                    SettingsDivider()
                    itemRow(item)
                }
            }
        }
    }

    /// 当前状态：任务名、阶段、体积、实时百分比，与 PWA「当前状态」一致。
    private var summary: some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: RexSpacing.sm) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(liveTitle)
                        .font(.system(.headline, weight: .semibold))
                        .foregroundStyle(RexColor.primaryText)
                        .lineLimit(1)

                    Text(liveSubtitle)
                        .font(RexFont.caption)
                        .foregroundStyle(RexColor.secondaryText)
                        .lineLimit(2)
                }

                Spacer(minLength: RexSpacing.sm)

                Text("\(Int(displayPercent))%")
                    .font(RexFont.metric)
                    .foregroundStyle(RexColor.brandBlue)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            ProgressView(value: displayPercent, total: 100)
                .tint(RexColor.brandBlue)

            Text(countsText)
                .font(RexFont.caption2)
                .foregroundStyle(RexColor.tertiaryText)
                .monospacedDigit()
                .lineLimit(2)

            if isRunning {
                Text("云端 / 本地各跑一个任务，其余排队或等待复查")
                    .font(RexFont.caption2)
                    .foregroundStyle(RexColor.tertiaryText)
            }
        }
    }

    private var skeletonRows: some View {
        let names: [CGFloat] = [188, 142, 166]
        let details: [CGFloat] = [128, 104, 116]

        return VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { index in
                SettingsDivider()

                HStack(spacing: RexSpacing.md) {
                    RexSkeleton(width: 20, height: 20, cornerRadius: 6)

                    VStack(alignment: .leading, spacing: 6) {
                        RexSkeleton(width: names[index], height: 13)
                        RexSkeleton(width: details[index], height: 9)
                    }

                    Spacer(minLength: 0)

                    RexSkeleton(width: 46, height: 18, cornerRadius: 9)
                }
                .padding(.horizontal, RexSpacing.lg)
                .frame(minHeight: 60)
            }

            if !isPreviewing {
                Text("扫描后显示文件列表")
                    .font(RexFont.caption2)
                    .foregroundStyle(RexColor.tertiaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RexSpacing.md)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: RexSpacing.sm) {
            Image(systemName: hasScanned ? "tray" : "clock")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(RexColor.tertiaryText)

            Text(hasScanned ? "目录下没有可解压的压缩包" : "暂无解压任务")
                .font(RexFont.row)
                .foregroundStyle(RexColor.secondaryText)

            Text(
                hasScanned
                    ? "只扫描该目录下一层的 zip / rar / 7z，分卷压缩包自动跳过。"
                    : "点「扫描压缩包」列出该目录的压缩包，确认后点「开始解压」按顺序处理。"
            )
            .font(RexFont.caption2)
            .foregroundStyle(RexColor.tertiaryText)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func itemRow(_ item: P115ExtractItem) -> some View {
        HStack(alignment: .top, spacing: RexSpacing.md) {
            Image(systemName: itemSymbol(item))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(itemTint(item))
                .frame(width: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(RexFont.row)
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)

                Text(itemDetail(item))
                    .font(RexFont.caption2)
                    .foregroundStyle(RexColor.tertiaryText)
                    .lineLimit(2)

                if item.state == "running" || (item.percent ?? 0) > 0 {
                    itemProgressBar(item)
                }

                if let message = item.message, !message.isEmpty {
                    Text(message)
                        .font(RexFont.caption2)
                        .foregroundStyle(RexColor.secondaryText)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: RexSpacing.sm)

            Text(itemChipText(item))
                .font(RexFont.badge)
                .foregroundStyle(itemTint(item))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(itemTint(item).opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.vertical, RexSpacing.md)
    }

    @ViewBuilder
    private func itemProgressBar(_ item: P115ExtractItem) -> some View {
        let percent = max(0, min(100, item.percent ?? 0))

        if percent > 0 {
            ProgressView(value: percent, total: 100)
                .progressViewStyle(.linear)
                .tint(itemTint(item))
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(itemTint(item))
        }
    }

    private func itemSymbol(_ item: P115ExtractItem) -> String {
        switch item.state {
        case "done": "checkmark.circle.fill"
        case "failed": "exclamationmark.triangle.fill"
        case "running": "arrow.down.doc.fill"
        case "waiting": "clock.arrow.circlepath"
        default: "clock"
        }
    }

    private func itemTint(_ item: P115ExtractItem) -> Color {
        switch item.state {
        case "done": RexColor.success
        case "failed": RexColor.error
        case "running": RexColor.brandBlue
        case "waiting": RexColor.warning
        default: RexColor.tertiaryText
        }
    }

    /// 右侧状态胶囊：只描述状态，阶段放进明细行，避免多个任务都叫「解压中」。
    private func itemChipText(_ item: P115ExtractItem) -> String {
        switch item.state {
        case "done": "已完成"
        case "failed": "失败"
        case "running": "执行中"
        case "waiting": "等待复查"
        default: "排队中"
        }
    }

    private func itemStateLine(_ item: P115ExtractItem) -> String {
        switch item.state {
        case "done": return "已完成"
        case "failed": return "已失败"
        default: break
        }

        let stage = item.stage ?? ""
        if item.state == "running" {
            return stage.isEmpty ? "正在执行" : "正在执行 · \(stage)"
        }
        if item.state == "waiting" {
            return stage.isEmpty ? "等待复查" : "等待复查 · \(stage)"
        }
        return stage.isEmpty ? "排队等待" : "排队等待 · \(stage)"
    }

    private func itemDetail(_ item: P115ExtractItem) -> String {
        var parts = [itemStateLine(item)]

        if let lane = item.lane {
            parts.append(lane == "local" ? "本地" : "云端")
        }

        if let size = item.size, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }

        if let attempts = item.attempts, attempts > 0 {
            parts.append("第 \(attempts) 次等待")
        }

        return parts.joined(separator: " · ")
    }

    // MARK: - 派生

    /// 队列结果只对当前目录有效；没跑过任务时展示扫描清单。
    private var displayItems: [P115ExtractItem] {
        guard let status else {
            return hasScanned ? previewItems : []
        }

        if let statusCid = status.folderCid,
           let configCid = config?.folderCid,
           statusCid != configCid {
            return hasScanned ? previewItems : []
        }

        if let statusItems = status.items, !statusItems.isEmpty {
            return statusItems
        }
        return hasScanned ? previewItems : []
    }

    private var showsSkeleton: Bool {
        if isPreviewing { return true }
        return displayItems.isEmpty && !hasScanned
    }

    private var liveTitle: String {
        if isRunning {
            let name = status?.current?.name ?? ""
            return name.isEmpty ? "准备中…" : name
        }
        if isScanningNow || isPreviewing { return "正在扫描压缩包" }
        return "队列未运行"
    }

    private var liveSubtitle: String {
        if isRunning {
            var parts: [String] = []
            if let stage = status?.current?.stage, !stage.isEmpty {
                parts.append(stage)
            }
            if let size = status?.current?.size, size > 0 {
                parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
            return parts.isEmpty ? "处理中" : parts.joined(separator: " · ")
        }
        if isScanningNow || isPreviewing { return "正在读取目录…" }
        return "点「开始解压」才会调度任务"
    }

    private var displayPercent: Double {
        if isRunning {
            return max(0, min(100, status?.current?.percent ?? 0))
        }
        return min(100, overall * 100)
    }

    private var countsText: String {
        if totalCount > 0 {
            return "共 \(totalCount) · 完成 \(doneCount) · 失败 \(failedCount) · 等待复查 \(waitingCount) · 执行/排队 \(queuedCount)"
        }
        if isPreviewing { return "扫描中…" }
        if hasScanned {
            let pending = previewItems.filter { $0.state == "queued" }.count
            let skipped = previewItems.filter { $0.state == "failed" }.count
            var text = "扫描完成 · 待解压 \(pending)"
            if skipped > 0 { text += " · 跳过 \(skipped)" }
            return text
        }
        return "未扫描"
    }

    private var totalCount: Int { counts?.total ?? displayItems.count }
    private var doneCount: Int { counts?.done ?? displayItems.filter { $0.state == "done" }.count }
    private var failedCount: Int { counts?.failed ?? displayItems.filter { $0.state == "failed" }.count }
    private var waitingCount: Int { counts?.waiting ?? displayItems.filter { $0.state == "waiting" }.count }
    private var queuedCount: Int {
        if let queued = counts?.queued { return queued }
        return displayItems.filter { $0.state == "running" || $0.state == "queued" }.count
    }

    private var overall: Double {
        guard totalCount > 0 else { return 0 }
        return min(1, Double(doneCount + failedCount) / Double(totalCount))
    }

    private var folderNameText: String {
        guard let name = config?.folderName, !name.isEmpty else {
            return (config?.folderCid ?? "0") == "0" ? "根目录" : "已选择目录"
        }
        return name
    }

    private var passwordText: String {
        guard let password = config?.password, !password.isEmpty else { return "未设置" }
        return String(repeating: "•", count: min(8, password.count))
    }

    // MARK: - 数据

    private func load() async {
        guard isAdmin else {
            isLoading = false
            return
        }
        guard let apiClient else {
            errorText = "登录状态已失效，请重新登录"
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            config = try await apiClient.panExtractConfig()
            apply(try await apiClient.panExtractStatus())
        } catch {
            errorText = message(for: error)
        }
    }

    private func scan() async {
        guard let apiClient else { return }
        isBusy = true
        isPreviewing = true
        defer {
            isBusy = false
            isPreviewing = false
        }
        do {
            let result = try await apiClient.panExtractPreview(cid: config?.folderCid ?? "0")
            previewItems = result.items ?? []
            hasScanned = true
            await refreshStatus()
        } catch {
            alert = .failure(message(for: error))
        }
    }

    private func start() async {
        guard let apiClient else { return }
        guard hasScanned else {
            alert = .failure("请先扫描压缩包")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            apply(try await apiClient.panExtractStart())
        } catch {
            alert = .failure(message(for: error))
        }
    }

    private func stop() async {
        guard let apiClient else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            apply(try await apiClient.panExtractStop())
        } catch {
            alert = .failure(message(for: error))
        }
    }

    private func refreshStatus() async {
        guard let apiClient else { return }
        guard let snapshot = try? await apiClient.panExtractStatus() else { return }
        apply(snapshot)
    }

    private func apply(_ snapshot: P115ExtractStatus) {
        status = snapshot
        counts = snapshot.counts
        if let newConfig = snapshot.config { config = newConfig }

        if let preview = snapshot.preview,
           let previewCid = snapshot.previewCid,
           previewCid == (config?.folderCid ?? "0") {
            previewItems = preview
            hasScanned = true
        }
    }

    private func saveConfig(cid: String? = nil, folderName: String? = nil, password: String? = nil) async {
        guard let apiClient else { return }
        guard let current = config else {
            alert = .failure("配置未加载，请先重试加载")
            return
        }
        isBusy = true
        defer { isBusy = false }
        let previousCid = current.folderCid
        do {
            let saved = try await apiClient.savePanExtractConfig(
                folderCid: cid ?? current.folderCid ?? "0",
                folderName: folderName ?? current.folderName ?? "",
                password: password ?? current.password ?? ""
            )
            config = saved
            if previousCid != saved.folderCid {
                previewItems = []
                hasScanned = false
                counts = nil
            }
            alert = .success("解压配置已保存")
            RexHaptics.success()
            await refreshStatus()
        } catch {
            alert = .failure(message(for: error))
        }
    }

    private func message(for error: Error) -> String {
        (error as? APIError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - 解压流程

/// 解压任务的完整处理链路，从配置页单独进入。
struct PanExtractFlowView: View {
    private static let flowScan = Color(hex: 0x5E5CE6)
    private static let flowCheck = Color(hex: 0xFF9F0A)
    private static let flowCloud = Color(hex: 0x0071E3)
    private static let flowLocal = Color(hex: 0xC26A00)
    private static let flowDone = Color(hex: 0x248A3D)
    private static let flowFail = Color(hex: 0xC9342D)

    var body: some View {
        SettingsPage(title: "解压流程") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 0) {
                    flowNode(
                        tone: Self.flowScan,
                        title: "扫描解压目录",
                        sub: "只取第一层 zip / rar / 7z"
                    )

                    flowArrow()

                    flowNode(
                        tone: Self.flowCheck,
                        title: "分拣",
                        sub: "分卷跳过 · 非会员或超 20GB 走本地"
                    )

                    flowArrow(label: "双通道")

                    HStack(alignment: .top, spacing: RexSpacing.sm) {
                        flowLane(
                            tone: Self.flowCloud,
                            title: "云端解压",
                            steps: ["推送预解析", "轮询解压状态", "提交解压", "每 10 秒查进度", "实测产物"]
                        )

                        flowLane(
                            tone: Self.flowLocal,
                            title: "本地兜底",
                            steps: ["下载原压缩包", "本地解压", "上传产物", "统计产物大小"]
                        )
                    }

                    flowArrow()

                    flowNode(
                        tone: Self.flowCheck,
                        title: "产物核对",
                        sub: "实测 ≥ 原包 98% 才算成功"
                    )

                    flowArrow()

                    HStack(alignment: .top, spacing: RexSpacing.sm) {
                        flowNode(
                            tone: Self.flowFail,
                            title: "不达标",
                            sub: "30 秒后复核，转本地重解"
                        )

                        flowNode(
                            tone: Self.flowDone,
                            title: "达标",
                            sub: "删除原压缩包，任务完成"
                        )
                    }
                }
                .padding(RexSpacing.lg)
            }
        }
    }

    private func flowNode(tone: Color, title: String, sub: String) -> some View {
        HStack(alignment: .top, spacing: RexSpacing.sm) {
            Circle()
                .fill(tone)
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)

                Text(sub)
                    .font(.system(size: 11))
                    .foregroundStyle(RexColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            tone.opacity(0.05),
            in: RoundedRectangle(cornerRadius: RexRadius.small, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: RexRadius.small, style: .continuous)
                .strokeBorder(tone.opacity(0.22), lineWidth: 0.75)
        }
    }

    private func flowLane(tone: Color, title: String, steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle()
                    .fill(tone)
                    .frame(width: 7, height: 7)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)
            }

            ForEach(steps, id: \.self) { step in
                HStack(alignment: .top, spacing: 5) {
                    Circle()
                        .fill(tone.opacity(0.55))
                        .frame(width: 3, height: 3)
                        .padding(.top, 5)

                    Text(step)
                        .font(.system(size: 11))
                        .foregroundStyle(RexColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            tone.opacity(0.06),
            in: RoundedRectangle(cornerRadius: RexRadius.small, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: RexRadius.small, style: .continuous)
                .strokeBorder(tone.opacity(0.18), lineWidth: 0.75)
        }
    }

    private func flowArrow(label: String? = nil) -> some View {
        VStack(spacing: 3) {
            if let label {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(RexColor.tertiaryText)
            }

            Image(systemName: "arrow.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(RexColor.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

// MARK: - 模型

struct P115ExtractConfig: Decodable, Sendable {
    let folderCid: String?
    let folderName: String?
    let password: String?
}

struct P115ExtractConfigBody: Encodable {
    var folderCid: String
    var folderName: String
    var password: String
}

struct P115ExtractItem: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let size: Int64?
    let state: String?
    let stage: String?
    let message: String?
    let attempts: Int?
    let percent: Double?
    let lane: String?
    let phase: String?
}

struct P115ExtractCounts: Decodable, Sendable {
    let total: Int?
    let done: Int?
    let failed: Int?
    let waiting: Int?
    let queued: Int?
}

struct P115ExtractStatus: Decodable, Sendable {
    let running: Bool?
    let scanning: Bool?
    let workDir: String?
    let folderCid: String?
    let folderName: String?
    let current: P115ExtractItem?
    let items: [P115ExtractItem]?
    let counts: P115ExtractCounts?
    let preview: [P115ExtractItem]?
    let previewCid: String?
    let config: P115ExtractConfig?
}

struct P115ExtractPreview: Decodable, Sendable {
    let folderCid: String?
    let items: [P115ExtractItem]?
}
