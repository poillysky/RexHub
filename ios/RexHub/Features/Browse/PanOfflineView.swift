import SwiftUI

/// 115 离线下载：粘贴磁力 / ED2K 链接，直存到 115 目标目录。
struct PanOfflineView: View {
    /// 非管理员只读：服务端转存接口要求管理员权限。
    var isAdmin: Bool = false

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var alert: RexAlertInfo?

    private var links: [String] {
        text
            .split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var supportedLinks: [String] {
        var seen = Set<String>()
        return links.filter { link in
            let lower = link.lowercased()
            guard lower.hasPrefix("magnet:") || lower.hasPrefix("ed2k://") else { return false }
            return seen.insert(lower).inserted
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: RexSpacing.xl) {
                        if !isAdmin {
                            RexNote(text: "只有管理员可以提交 115 转存任务。")
                        }

                        SettingsCard {
                            textEditor
                        }

                        SettingsCard {
                            SettingsInputRow(
                                icon: "lock",
                                title: "压缩包密码",
                                placeholder: "可选",
                                text: $password
                            )
                        }
                    }
                    .padding(RexSpacing.xl)
                    .frame(maxWidth: RexLayout.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)

                Button {
                    Task { await submit() }
                } label: {
                    HStack(spacing: RexSpacing.sm) {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(RexColor.onBrand)
                        }
                        Text(supportedLinks.isEmpty ? "请粘贴 magnet / ed2k 链接" : "转存 \(supportedLinks.count) 条链接")
                    }
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(RexColor.onBrand)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(
                        supportedLinks.isEmpty ? AnyShapeStyle(RexColor.tertiaryText.opacity(0.35)) : AnyShapeStyle(RexColor.brandGradient),
                        in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                    )
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(supportedLinks.isEmpty || isSubmitting || !isAdmin)
                .padding(RexSpacing.xl)
            }
            .background(RexPageBackground())
            .navigationTitle("115 离线下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isSubmitting)
        .rexAlert($alert)
    }

    private var textEditor: some View {
        TextEditor(text: $text)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(RexColor.primaryText)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 160)
            .padding(RexSpacing.md)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("magnet:?xt=urn:btih:…\ned2k://|file|…")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(RexColor.tertiaryText)
                        .padding(RexSpacing.md + 4)
                        .allowsHitTesting(false)
                }
            }
    }

    private func submit() async {
        let urls = supportedLinks
        guard let apiClient, !urls.isEmpty, !isSubmitting, isAdmin else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let result = try await apiClient.panOffline(urls: urls, password: password)
            if result.added > 0 {
                text = ""
                password = ""
                RexHaptics.success()
                let dest = result.destName.isEmpty ? "目标目录" : "「\(result.destName)」"
                var message = "已提交 \(result.added) 条，直存 \(dest)"
                if !result.failed.isEmpty {
                    message += "\n\(result.failed.count) 条失败：\(result.failed.map(\.message).joined(separator: "；"))"
                }
                if urls.count < links.count {
                    message += "\n已忽略 \(links.count - urls.count) 条不支持的链接"
                }
                alert = .success(message, title: "转存结果")
            } else {
                RexHaptics.error()
                let detail = result.failed.map(\.message).joined(separator: "；")
                alert = .failure(detail.isEmpty ? "没有成功提交任何链接" : detail, title: "转存失败")
            }
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription, title: "转存失败")
        }
    }
}
