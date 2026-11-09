import SwiftUI

/// AI 模型设置：LLM 服务地址 / 模型 / 令牌，保存后助手立即使用。
struct AISettingsView: View {
    let isAdmin: Bool

    @Environment(\.apiClient) private var apiClient

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var alert: RexAlertInfo?

    @State private var enabled = true
    @State private var baseUrl = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var timeoutSec = 60.0
    @State private var hasKey = false
    @State private var configured = false

    var body: some View {
        SettingsPage(title: "AI 模型") {
            if isLoading {
                RexSkeleton(width: .infinity, height: 120, cornerRadius: RexRadius.panel)
            } else {
                RexNote(text: "「小花」助手使用这里的模型与令牌；不填模型时使用服务端默认值。")

                SettingsCard {
                    SettingsSwitchRow(title: "启用 AI 模型", isOn: $enabled)
                        .disabled(!isAdmin)

                    SettingsDivider()

                    SettingsInputRow(
                        icon: "link",
                        title: "服务地址",
                        placeholder: "https://api.openai.com/v1",
                        text: $baseUrl,
                        keyboard: .URL
                    )
                    .disabled(!isAdmin)

                    SettingsDivider()

                    SettingsInputRow(
                        icon: "cube",
                        title: "模型",
                        placeholder: "如 gpt-4o-mini",
                        text: $model
                    )
                    .disabled(!isAdmin)

                    SettingsDivider()

                    SettingsInputRow(
                        icon: "key",
                        title: "API Key",
                        placeholder: hasKey ? "留空保持现有 Key" : "请输入 API Key",
                        text: $apiKey,
                        isSecure: true
                    )
                    .disabled(!isAdmin)

                    SettingsDivider()

                    SettingsStepperRow(
                        title: "超时",
                        value: Binding(
                            get: { Int(timeoutSec) },
                            set: { timeoutSec = Double($0) }
                        ),
                        range: 10...300,
                        step: 10
                    )
                    .disabled(!isAdmin)
                }

                SettingsCard {
                    SettingsRow(
                        icon: configured ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                        title: "配置状态",
                        value: configured ? "已配置" : "未配置",
                        iconTint: configured ? RexColor.success : RexColor.warning
                    )
                }

                if isAdmin {
                    HStack(spacing: RexSpacing.md) {
                        Button {
                            Task { await test() }
                        } label: {
                            HStack(spacing: RexSpacing.sm) {
                                if isTesting {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "bolt.horizontal")
                                }
                                Text("测试模型")
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
                        .disabled(isTesting || isSaving)

                        Button {
                            Task { await save() }
                        } label: {
                            HStack(spacing: RexSpacing.sm) {
                                if isSaving {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(RexColor.onBrand)
                                }
                                Text("保存")
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
                        .disabled(isSaving || isTesting)
                    }
                } else {
                    RexNote(text: "当前账号不是管理员，只能查看配置。")
                }
            }
        }
        .task { await load() }
        .rexAlert($alert)
    }

    private func load() async {
        guard let apiClient else {
            alert = .failure("登录状态已失效，请重新登录", title: "加载失败")
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let settings = try await apiClient.fetchSettings("api/settings/ai/llm", as: AiLlmSettings.self)
            enabled = settings.enabled ?? false
            baseUrl = settings.baseUrl ?? ""
            model = settings.model ?? ""
            timeoutSec = Double(settings.timeoutSec ?? 60)
            configured = settings.configured == true
            hasKey = !(settings.apiKeyHint ?? "").isEmpty
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            alert = .failure(error.localizedDescription, title: "加载失败")
        }
    }

    private func body(includeKey: Bool) -> AiLlmSaveBody {
        AiLlmSaveBody(
            enabled: enabled,
            baseUrl: baseUrl.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: includeKey && !apiKey.isEmpty ? apiKey : nil,
            timeoutSec: Int(timeoutSec)
        )
    }

    private func save() async {
        guard let apiClient, !isSaving else { return }
        isSaving = true
        alert = nil
        defer { isSaving = false }

        do {
            _ = try await apiClient.putSettings(
                "api/settings/ai/llm",
                json: try JSONEncoder().encode(body(includeKey: true)),
                as: AiLlmSettings.self
            )
            hasKey = hasKey || !apiKey.isEmpty
            apiKey = ""
            configured = true
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
                json: try JSONEncoder().encode(body(includeKey: true)),
                as: AiLlmTestResult.self
            )
            RexHaptics.success()
            alert = .success(result.message ?? "模型连接成功")
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription)
        }
    }
}
