import SwiftUI

/// AI 设置：连接配置（LLM 端点 / 密钥 / 模型）与 Agent 配置（提示词 / 工具能力 / 网络搜索）。
struct AISettingsView: View {
    let isAdmin: Bool

    @Environment(\.apiClient) private var apiClient

    private enum Tab: String, CaseIterable, Identifiable {
        case connection
        case agent

        var id: String { rawValue }

        var title: String {
            switch self {
            case .connection: return "连接配置"
            case .agent: return "Agent 配置"
            }
        }
    }

    private struct CapabilitySection: Identifiable {
        let id: String
        let label: String
        let groupIds: [String]
    }

    private static let capabilitySections: [CapabilitySection] = [
        CapabilitySection(id: "search", label: "检索", groupIds: ["media", "av"]),
        CapabilitySection(id: "resource", label: "资源", groupIds: ["warehouse", "magnet", "stream"]),
        CapabilitySection(id: "cloud", label: "网盘", groupIds: ["cloud"]),
        CapabilitySection(id: "web", label: "网络搜索", groupIds: ["web"]),
    ]

    private static let defaultBaseUrl = "https://api.openai.com/v1"
    private static let defaultModel = "gpt-4o-mini"
    private static let searxngDefaultURL = "http://192.168.2.38:8085"

    @State private var tab: Tab = .connection
    @State private var isLoading = true
    @State private var hasLoaded = false
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var isConnecting = false
    @State private var isSavingAgent = false
    @State private var alert: RexAlertInfo?

    // 连接配置
    @State private var enabled = true
    @State private var source = "custom"
    @State private var baseUrl = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var keyHint = ""
    @State private var fromEnv = false
    @State private var configured = false
    @State private var showKey = false
    @State private var models: [String] = []
    @State private var postProcess = ""
    @State private var timeoutSec = 30
    @State private var headers = ""
    @State private var showAdvanced = false
    @State private var connectHint: String?
    @State private var connectFailed = false

    // 预设
    @State private var chatSources: [AiPresetOption] = []
    @State private var postOptions: [AiPresetOption] = []
    @State private var webProviders: [AiPresetOption] = []

    // Agent 配置
    @State private var assistantModel = ""
    @State private var systemPrompt = ""
    @State private var tools: [String: Bool] = [:]
    @State private var toolMeta: [AiAssistantToolMeta] = []
    @State private var skillGroups: [AiAssistantSkillGroup] = []
    @State private var webEnabled = false
    @State private var webProvider = "searxng"
    @State private var webBaseUrl = ""
    @State private var webApiKey = ""
    @State private var webHint = ""
    @State private var webShowKey = false

    var body: some View {
        SettingsPage(title: "AI 模型", onRefresh: { await load() }) {
            Picker("视图", selection: $tab) {
                ForEach(Tab.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)

            if isLoading {
                RexSkeleton(width: .infinity, height: 240, cornerRadius: RexRadius.panel)
            } else {
                switch tab {
                case .connection:
                    connectionContent
                case .agent:
                    agentContent
                }
            }
        }
        .task { await load() }
        .rexAlert($alert)
    }

    // MARK: - 连接配置

    @ViewBuilder
    private var connectionContent: some View {
        SettingsCard {
            kvRow("当前模型", model.isEmpty ? "—" : model)
            SettingsDivider()
            kvRow("密钥", keyStatusText, color: keyStatusColor)
            SettingsDivider()
            SettingsSwitchRow(title: "启用", isOn: $enabled)
                .disabled(!isAdmin)
        }

        SettingsSection(title: "连接配置") {
            SettingsMenuRow(
                title: "来源",
                options: sourceOptions,
                label: { sourceLabel($0) },
                selection: $source
            )
            .disabled(!isAdmin || fromEnv)
            .onChange(of: source) { _, newValue in
                guard let preset = chatSources.first(where: { $0.value == newValue }),
                      let url = preset.baseUrl, !url.isEmpty else { return }
                baseUrl = url
            }

            SettingsDivider()

            SettingsInputRow(
                title: "端点",
                placeholder: Self.defaultBaseUrl,
                text: $baseUrl,
                keyboard: .URL
            )
            .disabled(!isAdmin || fromEnv)

            SettingsDivider()

            if !keyHint.isEmpty && !showKey {
                savedKeyRow(hint: keyHint) { showKey = true }
            } else {
                SettingsInputRow(
                    title: "密钥",
                    placeholder: keyHint.isEmpty ? "OpenAI 兼容 Key" : "已配置 \(keyHint)",
                    text: $apiKey,
                    isSecure: true
                )
                .disabled(!isAdmin || fromEnv)
            }

            SettingsDivider()

            SettingsInputRow(
                title: "模型",
                placeholder: Self.defaultModel,
                text: $model
            )
            .disabled(!isAdmin)

            SettingsDivider()

            SettingsMenuRow(
                title: "列表",
                options: modelOptions,
                label: { modelOptionLabel($0) },
                selection: modelSelection
            )
            .disabled(!isAdmin)

            SettingsDivider()

            SettingsMenuRow(
                title: "后处理",
                options: postProcessOptions,
                label: { postProcessLabel($0) },
                selection: $postProcess
            )
            .disabled(!isAdmin)

            SettingsDivider()

            Button {
                Task { await connect() }
            } label: {
                HStack(spacing: RexSpacing.sm) {
                    if isConnecting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("连接并拉取模型")
                        .font(.system(.subheadline, weight: .medium))
                }
                .foregroundStyle(RexColor.brandBlue)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!isAdmin || isConnecting || isSaving)
        }

        if let connectHint {
            RexNote(
                text: connectHint,
                tone: connectFailed ? .error : .neutral,
                symbol: connectFailed ? nil : "checkmark.circle.fill"
            )
        }

        SettingsCard {
            Button {
                withAnimation(RexMotion.quick) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: RexSpacing.sm) {
                    Text("高级")
                        .font(RexFont.row)
                        .foregroundStyle(RexColor.primaryText)

                    Spacer(minLength: RexSpacing.sm)

                    Text("超时 · 请求头")
                        .font(RexFont.rowValue)
                        .foregroundStyle(RexColor.secondaryText)

                    Image(systemName: "chevron.right")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(RexColor.tertiaryText)
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                }
                .padding(.horizontal, RexSpacing.lg)
                .frame(minHeight: RexLayout.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
        }

        if showAdvanced {
            SettingsCard {
                SettingsStepperRow(
                    title: "超时",
                    value: $timeoutSec,
                    range: 5...120,
                    step: 5
                )
                .disabled(!isAdmin)

                SettingsDivider()

                VStack(alignment: .leading, spacing: RexSpacing.sm) {
                    Text("请求头")
                        .font(RexFont.row)
                        .foregroundStyle(RexColor.primaryText)

                    TextEditor(text: $headers)
                        .font(.system(.footnote, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 88)
                        .padding(RexSpacing.md)
                        .background(
                            RexColor.field,
                            in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                        )
                        .overlay(alignment: .topLeading) {
                            if headers.isEmpty {
                                Text("X-Custom: value")
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(RexColor.tertiaryText)
                                    .padding(RexSpacing.md)
                                    .allowsHitTesting(false)
                            }
                        }
                        .disabled(!isAdmin)
                }
                .padding(RexSpacing.lg)
            }
        }

        if isAdmin {
            HStack(spacing: RexSpacing.md) {
                secondaryButton(title: "测试", symbol: "bolt.horizontal", isLoading: isTesting) {
                    await test()
                }
                .disabled(isTesting || isSaving || isConnecting)

                primaryButton(title: "保存", isLoading: isSaving) {
                    await save()
                }
                .disabled(isSaving || isTesting || isConnecting)
            }
        } else {
            RexNote(text: "当前账号不是管理员，只能查看配置。")
        }
    }

    // MARK: - Agent 配置

    @ViewBuilder
    private var agentContent: some View {
        SettingsCard {
            kvRow("名称", "智能搜片助手")
            SettingsDivider()
            kvRow("描述", "多源检索与整合回答")
        }

        SettingsSection(title: "模型") {
            if models.isEmpty {
                SettingsInputRow(
                    title: "绑定模型",
                    placeholder: "留空跟随模型页",
                    text: $assistantModel
                )
                .disabled(!isAdmin)
            } else {
                SettingsMenuRow(
                    title: "绑定模型",
                    options: assistantModelOptions,
                    label: { assistantModelLabel($0) },
                    selection: $assistantModel
                )
                .disabled(!isAdmin)
            }
        }

        SettingsSection(title: "指令") {
            VStack(alignment: .leading, spacing: RexSpacing.sm) {
                Text("系统提示词")
                    .font(RexFont.row)
                    .foregroundStyle(RexColor.primaryText)

                TextEditor(text: $systemPrompt)
                    .font(.system(.footnote, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160)
                    .padding(RexSpacing.md)
                    .background(
                        RexColor.field,
                        in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                    )
                    .overlay(alignment: .topLeading) {
                        if systemPrompt.isEmpty {
                            Text("留空使用内置提示词")
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(RexColor.tertiaryText)
                                .padding(RexSpacing.md)
                                .allowsHitTesting(false)
                        }
                    }
                    .disabled(!isAdmin)
            }
            .padding(RexSpacing.lg)
        }

        ForEach(Self.capabilitySections) { section in
            let groups = section.groupIds.compactMap { id in
                skillGroups.first { $0.id == id }
            }

            if !groups.isEmpty {
                SettingsSection(title: section.label) {
                    ForEach(groups) { group in
                        if group.id != groups.first?.id {
                            SettingsDivider()
                        }

                        capabilityRow(
                            title: group.label,
                            desc: group.desc,
                            isOn: skillBinding(group.id)
                        )
                        .disabled(!isAdmin)

                        ForEach(toolMeta.filter { $0.group == group.id }) { tool in
                            SettingsDivider()
                            capabilityRow(
                                title: tool.label,
                                desc: tool.desc,
                                isOn: toolBinding(tool.id)
                            )
                            .disabled(!isAdmin)
                        }
                    }
                }
            }
        }

        if isSkillOn("web") {
            SettingsSection(title: "网络搜索服务") {
                SettingsSwitchRow(
                    title: "启用服务",
                    isOn: Binding(
                        get: { webEnabled },
                        set: { on in
                            webEnabled = on
                            if on { tools["web_search"] = true }
                        }
                    )
                )
                .disabled(!isAdmin)

                SettingsDivider()

                SettingsMenuRow(
                    title: "服务商",
                    options: webProviderOptions,
                    label: { webProviderLabel($0) },
                    selection: $webProvider
                )
                .disabled(!isAdmin || !webEnabled)
                .onChange(of: webProvider) { _, newValue in
                    if newValue == "searxng" {
                        webShowKey = false
                        if webBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            webBaseUrl = Self.searxngDefaultURL
                        }
                    } else {
                        webShowKey = true
                    }
                }

                SettingsDivider()

                if isSearxng {
                    SettingsInputRow(
                        title: "服务地址",
                        placeholder: Self.searxngDefaultURL,
                        text: $webBaseUrl,
                        keyboard: .URL
                    )
                    .disabled(!isAdmin || !webEnabled)
                } else if !webHint.isEmpty && !webShowKey {
                    savedKeyRow(hint: webHint) { webShowKey = true }
                } else {
                    SettingsInputRow(
                        title: "密钥",
                        placeholder: webProvider == "brave" ? "Brave API Key" : "Serper API Key",
                        text: $webApiKey,
                        isSecure: true
                    )
                    .disabled(!isAdmin || !webEnabled)
                }
            }
        }

        if isAdmin {
            primaryButton(title: "保存", isLoading: isSavingAgent) {
                await saveAgent()
            }
            .disabled(isSavingAgent)
        } else {
            RexNote(text: "当前账号不是管理员，只能查看配置。")
        }
    }

    // MARK: - 行样式

    private func kvRow(_ title: String, _ value: String, color: Color = RexColor.secondaryText) -> some View {
        HStack(spacing: RexSpacing.sm) {
            Text(title)
                .font(RexFont.row)
                .foregroundStyle(RexColor.primaryText)

            Spacer(minLength: RexSpacing.sm)

            Text(value)
                .font(RexFont.rowValue)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(minHeight: RexLayout.rowHeight)
    }

    private func savedKeyRow(hint: String, onChange: @escaping () -> Void) -> some View {
        HStack(spacing: RexSpacing.md) {
            Text("密钥")
                .font(RexFont.row)
                .foregroundStyle(RexColor.primaryText)

            Spacer(minLength: RexSpacing.sm)

            Text(hint)
                .font(RexFont.rowValue)
                .foregroundStyle(RexColor.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            Button(action: onChange) {
                Text("更换")
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(RexColor.brandBlue)
                    .frame(minWidth: RexLayout.minTouch, minHeight: 32, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!isAdmin)
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(minHeight: RexLayout.rowHeight)
    }

    private func capabilityRow(title: String, desc: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: RexSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(RexFont.row)
                    .foregroundStyle(RexColor.primaryText)

                if !desc.isEmpty {
                    Text(desc)
                        .font(RexFont.caption)
                        .foregroundStyle(RexColor.secondaryText)
                }
            }

            Spacer(minLength: RexSpacing.sm)

            Toggle(title, isOn: isOn)
                .labelsHidden()
                .tint(RexColor.brandBlue)
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(minHeight: RexLayout.rowHeight)
        .contentShape(Rectangle())
    }

    private func primaryButton(title: String, isLoading: Bool, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: RexSpacing.sm) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(RexColor.onBrand)
                }
                Text(title)
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
    }

    private func secondaryButton(
        title: String,
        symbol: String,
        isLoading: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: RexSpacing.sm) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: symbol)
                }
                Text(title)
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
    }

    // MARK: - 计算属性

    private var keyStatusText: String {
        if !enabled { return "已关闭" }
        if fromEnv { return "环境变量" }
        return configured ? "已配置" : "未配置"
    }

    private var keyStatusColor: Color {
        if !enabled { return RexColor.tertiaryText }
        return configured || fromEnv ? RexColor.success : RexColor.warning
    }

    private var sourceOptions: [String] {
        chatSources.isEmpty ? ["custom"] : chatSources.map(\.value)
    }

    private func sourceLabel(_ value: String) -> String {
        if let hit = chatSources.first(where: { $0.value == value }) { return hit.label }
        return value == "custom" ? "自定义" : value
    }

    private var modelOptions: [String] {
        [""] + models
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { models.contains(model) ? model : "" },
            set: { newValue in
                if !newValue.isEmpty { model = newValue }
            }
        )
    }

    private func modelOptionLabel(_ value: String) -> String {
        if value.isEmpty {
            return models.isEmpty ? "先点连接" : "从列表选择…"
        }
        return value
    }

    private var postProcessOptions: [String] {
        postOptions.isEmpty ? [""] : postOptions.map(\.value)
    }

    private func postProcessLabel(_ value: String) -> String {
        postOptions.first { $0.value == value }?.label ?? "未选择（小花助手忽略）"
    }

    private var assistantModelOptions: [String] {
        var options = [""] + models
        if !assistantModel.isEmpty && !models.contains(assistantModel) {
            options.append(assistantModel)
        }
        return options
    }

    private func assistantModelLabel(_ value: String) -> String {
        if value.isEmpty { return "跟随模型页" }
        return models.contains(value) ? value : "\(value)（已保存）"
    }

    private var webProviderOptions: [String] {
        webProviders.isEmpty ? ["searxng"] : webProviders.map(\.value)
    }

    private func webProviderLabel(_ value: String) -> String {
        if let hit = webProviders.first(where: { $0.value == value }) { return hit.label }
        return value == "searxng" ? "SearXNG（自建免费）" : value
    }

    private var isSearxng: Bool {
        webProvider == "searxng"
    }

    private func toolsInGroup(_ groupId: String) -> [String] {
        toolMeta.filter { $0.group == groupId }.map(\.id)
    }

    private func isSkillOn(_ groupId: String) -> Bool {
        toolsInGroup(groupId).contains { tools[$0] != false }
    }

    private func skillBinding(_ groupId: String) -> Binding<Bool> {
        Binding(
            get: { isSkillOn(groupId) },
            set: { on in
                for id in toolsInGroup(groupId) {
                    tools[id] = on
                }
                if groupId == "web" {
                    webEnabled = on
                }
            }
        )
    }

    private func toolBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { tools[id] != false },
            set: { on in
                tools[id] = on
                if id == "web_search", on, !webEnabled {
                    webEnabled = true
                }
            }
        )
    }

    // MARK: - 数据

    private func load() async {
        guard let apiClient else {
            alert = .failure("登录状态已失效，请重新登录", title: "加载失败")
            isLoading = false
            return
        }

        if !hasLoaded { isLoading = true }
        defer { isLoading = false }

        do {
            async let llmTask = apiClient.fetchSettings("api/settings/ai/llm", as: AiLlmSettings.self)
            async let presetsTask = apiClient.fetchSettings("api/settings/ai/presets", as: AiPresets.self)
            async let webTask = apiClient.fetchSettings("api/settings/ai/web-search", as: AiWebSearchSettings.self)
            async let assistantTask = apiClient.fetchSettings("api/settings/ai/assistant", as: AiAssistantSettings.self)

            let (llm, presets, web, assistant) = try await (llmTask, presetsTask, webTask, assistantTask)

            apply(llm: llm, presets: presets)
            apply(web: web)
            apply(assistant: assistant)
            hasLoaded = true
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            alert = .failure(error.localizedDescription, title: "加载失败")
        }
    }

    private func apply(llm: AiLlmSettings, presets: AiPresets) {
        enabled = llm.enabled ?? true
        source = llm.chatCompletionSource ?? "custom"
        baseUrl = llm.baseUrl ?? Self.defaultBaseUrl
        model = llm.model ?? Self.defaultModel
        models = llm.models ?? []
        postProcess = llm.promptPostProcessing ?? ""
        headers = llm.customIncludeHeaders ?? ""
        timeoutSec = min(120, max(5, llm.timeoutSec ?? 30))
        keyHint = llm.apiKeyHint ?? ""
        configured = llm.configured == true
        fromEnv = (llm.fromEnvKey == true) || (llm.fromEnv == true)
        showKey = !configured || llm.fromEnvKey == true

        chatSources = presets.chatSources
        postOptions = presets.promptPostProcessing
        webProviders = presets.webSearchProviders
    }

    private func apply(web: AiWebSearchSettings) {
        webEnabled = web.enabled ?? false
        webProvider = web.provider ?? "searxng"
        webBaseUrl = web.baseUrl ?? ""
        webHint = web.apiKeyHint ?? ""
        webShowKey = isSearxng ? false : !(web.configured == true) || (web.fromEnv == true)
    }

    private func apply(assistant: AiAssistantSettings) {
        assistantModel = assistant.model ?? ""
        systemPrompt = assistant.systemPrompt ?? ""
        tools = assistant.tools
        toolMeta = assistant.toolMeta
        skillGroups = assistant.skillGroups
    }

    private func llmBody() -> AiLlmSaveBody {
        AiLlmSaveBody(
            enabled: enabled,
            chatCompletionSource: source,
            apiMode: "chat",
            baseUrl: baseUrl.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.isEmpty ? nil : apiKey,
            promptPostProcessing: postProcess,
            customIncludeHeaders: headers,
            timeoutSec: timeoutSec
        )
    }

    private func save() async {
        guard let apiClient, !isSaving else { return }
        isSaving = true
        alert = nil
        defer { isSaving = false }

        do {
            let saved = try await apiClient.putSettings(
                "api/settings/ai/llm",
                json: try JSONEncoder().encode(llmBody()),
                as: AiLlmSettings.self
            )
            keyHint = saved.apiKeyHint ?? keyHint
            configured = saved.configured ?? true
            if let savedModels = saved.models { models = savedModels }
            apiKey = ""
            showKey = false
            RexHaptics.success()
            alert = .success("AI 配置已保存")
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription)
        }
    }

    private func test() async {
        guard let apiClient, !isTesting else { return }
        isTesting = true
        alert = nil
        defer { isTesting = false }

        do {
            let result = try await apiClient.postSettings(
                "api/settings/ai/llm/test",
                json: try JSONEncoder().encode(llmBody()),
                as: AiLlmTestResult.self
            )
            RexHaptics.success()
            alert = .success(result.message ?? "模型连接成功")
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription)
        }
    }

    private func connect() async {
        guard let apiClient, !isConnecting else { return }
        isConnecting = true
        connectHint = nil
        connectFailed = false
        defer { isConnecting = false }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHeaders = headers.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let result = try await apiClient.postSettings(
                "api/settings/ai/llm/connect",
                json: try JSONEncoder().encode(
                    AiLlmConnectBody(
                        baseUrl: baseUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                        apiKey: trimmedKey.isEmpty ? nil : trimmedKey,
                        customIncludeHeaders: trimmedHeaders.isEmpty ? nil : trimmedHeaders
                    )
                ),
                as: AiLlmConnectResult.self
            )
            models = result.models
            connectHint = result.message ?? "已拉取 \(result.modelCount ?? result.models.count) 个模型"
            RexHaptics.success()
        } catch {
            models = []
            connectFailed = true
            connectHint = error.localizedDescription
            RexHaptics.error()
        }
    }

    private func saveAgent() async {
        guard let apiClient, !isSavingAgent else { return }
        isSavingAgent = true
        alert = nil
        defer { isSavingAgent = false }

        let provider = isSearxng ? "searxng" : webProvider
        let trimmedWebKey = webApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let webBody = AiWebSearchSaveBody(
            enabled: webEnabled && tools["web_search"] != false,
            provider: provider,
            apiKey: provider == "searxng" || trimmedWebKey.isEmpty ? nil : trimmedWebKey,
            baseUrl: webBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        do {
            do {
                let savedWeb = try await apiClient.putSettings(
                    "api/settings/ai/web-search",
                    json: try JSONEncoder().encode(webBody),
                    as: AiWebSearchSettings.self
                )
                apply(web: savedWeb)
                webApiKey = ""
            } catch {
                throw AgentSaveError.partial(step: .webSearch, underlying: error)
            }

            do {
                let savedAssistant = try await apiClient.putSettings(
                    "api/settings/ai/assistant",
                    json: try JSONEncoder().encode(
                        AiAssistantSaveBody(
                            model: assistantModel.trimmingCharacters(in: .whitespacesAndNewlines),
                            systemPrompt: systemPrompt,
                            tools: tools
                        )
                    ),
                    as: AiAssistantSettings.self
                )
                assistantModel = savedAssistant.model ?? assistantModel
                tools = savedAssistant.tools
            } catch {
                throw AgentSaveError.partial(step: .assistant, underlying: error)
            }

            RexHaptics.success()
            alert = .success("Agent 配置已保存")
        } catch {
            RexHaptics.error()
            alert = .failure(agentSaveMessage(for: error))
        }
    }

    /// 两个配置分属不同接口，第二段失败时明确告知前半段已经生效。
    private func agentSaveMessage(for error: Error) -> String {
        guard case let AgentSaveError.partial(step, underlying) = error else {
            return error.localizedDescription
        }
        let reason = underlying.localizedDescription
        switch step {
        case .webSearch:
            return "联网搜索配置保存失败：\(reason)"
        case .assistant:
            return "联网搜索配置已保存，但助手配置保存失败：\(reason)"
        }
    }

    private enum AgentSaveStep {
        case webSearch
        case assistant
    }

    private enum AgentSaveError: Error {
        case partial(step: AgentSaveStep, underlying: Error)
    }
}
