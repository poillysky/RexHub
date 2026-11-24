import SwiftUI
import UIKit

/// 添加 Emby 服务器：直连登录，测试通过后保存到本机。
struct EmbyServerFormView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port = ""
    @State private var username = ""
    @State private var password = ""
    @State private var name = ""

    @State private var isTesting = false
    @State private var isSaving = false
    @State private var message: RexAlertInfo?

    /// 测试成功后缓存登录结果，保存时同一组输入不再重复登录。
    @State private var testedAuth: EmbyAuth?
    @State private var testedFingerprint = ""

    private let store = EmbyStore.shared

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPort: String {
        port.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 高级里的端口只在地址本身没写端口时补上。
    private var resolvedHost: String {
        guard !trimmedPort.isEmpty else { return trimmedHost }
        guard var components = URLComponents(
            string: trimmedHost.contains("://") ? trimmedHost : "http://\(trimmedHost)"
        ) else { return trimmedHost }

        if components.port == nil {
            components.port = Int(trimmedPort)
        }

        let result = components.string ?? trimmedHost
        return trimmedHost.contains("://") ? result : result.replacingOccurrences(of: "http://", with: "")
    }

    private var isBusy: Bool {
        isTesting || isSaving
    }

    private var canSubmit: Bool {
        !isBusy
            && !trimmedHost.isEmpty
            && !trimmedUsername.isEmpty
            && !password.isEmpty
    }

    private var fingerprint: String {
        "\(resolvedHost)|\(trimmedUsername)|\(password)"
    }

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: "添加服务",
                leading: .back(action: { dismiss() }),
                trailing: AnyView(connectButton)
            )

            ScrollView {
                VStack(spacing: RexSpacing.xl) {
                    basicCard

                    advancedSection

                    saveButton
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.top, RexSpacing.md)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(RexPageBackground())
        .rexPushedScreen()
        .rexAlert($message)
    }

    // MARK: 顶栏

    private var connectButton: some View {
        Button {
            Task { await test() }
        } label: {
            ZStack {
                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("连接")
                        .font(.system(.subheadline, weight: .semibold))
                }
            }
            .foregroundStyle(RexColor.primaryText)
            .padding(.horizontal, RexSpacing.lg)
            .frame(minHeight: 38)
            .background(RexColor.surface, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!canSubmit)
        .opacity(canSubmit ? 1 : 0.45)
    }

    // MARK: 表单

    private var basicCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: RexSpacing.md) {
                formLabel("协议")

                Text("Emby")
                    .font(RexFont.rowValue)
                    .foregroundStyle(RexColor.secondaryText)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, RexSpacing.lg)
            .frame(minHeight: RexLayout.rowHeight)

            formDivider

            formInput("服务器", placeholder: "192.168.1.1", text: $host, keyboard: .URL)

            formDivider

            formInput("用户名", placeholder: "必填", text: $username, contentType: .username)

            formDivider

            formInput("密码", placeholder: "password", text: $password, isSecure: true, contentType: .password)
        }
        .background(
            RexColor.surface,
            in: RoundedRectangle(cornerRadius: RexRadius.panel, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: RexRadius.panel, style: .continuous)
                .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            Text("高级")
                .font(RexFont.section)
                .foregroundStyle(RexColor.secondaryText)
                .padding(.horizontal, RexSpacing.xs)

            VStack(spacing: 0) {
                formInput("端口", placeholder: "8096", text: $port, keyboard: .numberPad)

                formDivider

                formInput("名称", placeholder: "默认用服务器名", text: $name)
            }
            .background(
                RexColor.surface,
                in: RoundedRectangle(cornerRadius: RexRadius.panel, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: RexRadius.panel, style: .continuous)
                    .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
            }
        }
    }

    private var saveButton: some View {
        Button {
            Task { await submit() }
        } label: {
            ZStack {
                if isSaving {
                    ProgressView()
                } else {
                    Text("保存")
                        .font(.system(.headline, weight: .semibold))
                }
            }
            .foregroundStyle(RexColor.primaryText)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                RexColor.surface,
                in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
            )
            .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!canSubmit)
        .opacity(canSubmit ? 1 : 0.45)
    }

    private func formLabel(_ title: String) -> some View {
        Text(title)
            .font(RexFont.row)
            .foregroundStyle(RexColor.primaryText)
            .frame(width: 72, alignment: .leading)
    }

    private func formInput(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        isSecure: Bool = false,
        keyboard: UIKeyboardType = .default,
        contentType: UITextContentType? = nil
    ) -> some View {
        HStack(spacing: RexSpacing.md) {
            formLabel(title)

            Group {
                if isSecure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .font(RexFont.rowValue)
            .foregroundStyle(RexColor.primaryText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboard)
            .textContentType(contentType)
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(minHeight: RexLayout.rowHeight)
    }

    private var formDivider: some View {
        Rectangle()
            .fill(RexColor.divider)
            .frame(height: 1 / UIScreen.main.scale)
            .padding(.horizontal, RexSpacing.lg)
    }

    // MARK: 动作

    private func test() async {
        guard let client = makeClient() else {
            message = .failure("请填写正确的服务器地址")
            RexHaptics.error()
            return
        }

        isTesting = true
        defer { isTesting = false }

        do {
            let auth = try await client.authenticate(username: trimmedUsername, password: password)
            testedAuth = auth
            testedFingerprint = fingerprint
            RexHaptics.success()

            let title = auth.serverName.isEmpty ? trimmedHost : auth.serverName
            message = .success("已连接到 \(title)")
        } catch {
            testedAuth = nil
            RexHaptics.error()
            message = .failure(errorText(error))
        }
    }

    private func submit() async {
        guard canSubmit else { return }

        isSaving = true
        defer { isSaving = false }

        do {
            let auth = try await authenticate()
            let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let server = EmbyServer(
                id: UUID().uuidString,
                name: displayName.isEmpty ? defaultName(from: auth) : displayName,
                host: EmbyClient.normalizedURL(from: resolvedHost)?.absoluteString ?? resolvedHost,
                username: trimmedUsername,
                userId: auth.userId,
                lastConnected: Date()
            )

            store.save(server, token: auth.token)
            RexHaptics.success()
            dismiss()
        } catch {
            RexHaptics.error()
            message = .failure(errorText(error))
        }
    }

    /// 输入没变就复用测试结果，避免保存时再登录一次。
    private func authenticate() async throws -> EmbyAuth {
        if let testedAuth, testedFingerprint == fingerprint {
            return testedAuth
        }
        guard let client = makeClient() else { throw EmbyError.invalidURL }
        return try await client.authenticate(username: trimmedUsername, password: password)
    }

    private func makeClient() -> EmbyClient? {
        EmbyClient(host: resolvedHost)
    }

    private func defaultName(from auth: EmbyAuth) -> String {
        if !auth.serverName.isEmpty { return auth.serverName }
        return EmbyClient.normalizedURL(from: resolvedHost)?.host ?? trimmedHost
    }

    private func errorText(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "连接失败，请检查地址与账号"
    }
}
