import SwiftUI

struct LoginView: View {
    @Environment(AppState.self) private var appState

    @State private var serverAddress = ServerConfig.savedText
    @State private var useHTTPS = ServerConfig.httpsEnabled
    @State private var account = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var rememberPassword = true
    @State private var appeared = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Field: Hashable {
        case server
        case account
        case password
    }

    private var isServerValid: Bool {
        ServerConfig.resolve(serverAddress, useHTTPS: useHTTPS) != nil
    }

    private var canSubmit: Bool {
        isServerValid && !account.isEmpty && !password.isEmpty
    }

    var body: some View {
        ScrollView {
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = nil }

                VStack(spacing: 0) {
                    brandHeader
                        .padding(.top, 64)
                        .padding(.bottom, 48)

                    VStack(spacing: RexSpacing.md) {
                        serverField
                            .id(Field.server)

                        accountField
                            .id(Field.account)

                        passwordField
                            .id(Field.password)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(RexColor.error)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, RexSpacing.md)
                            .padding(.horizontal, RexSpacing.xs)
                            .transition(.opacity)
                    }

                    optionsRow
                        .padding(.top, RexSpacing.lg)
                        .padding(.horizontal, RexSpacing.xs)

                    httpsToggle
                        .padding(.top, RexSpacing.xxl)
                        .padding(.horizontal, RexSpacing.xs)

                    submitButton
                        .padding(.top, RexSpacing.xl)

                    footer
                        .padding(.top, RexSpacing.xxl)
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.bottom, RexSpacing.huge)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .modifier(HiddenTopScrollEdge())
        .background(background)
        .onChange(of: useHTTPS) { _, value in
            ServerConfig.httpsEnabled = value
        }
        .onChange(of: rememberPassword) { _, value in
            guard !value else { return }
            CredentialStore.forget()
        }
        .onChange(of: serverAddress) { _, text in
            guard let explicit = ServerConfig.explicitHTTPS(in: text), explicit != useHTTPS else { return }
            useHTTPS = explicit
        }
        .onAppear {
            restoreCredentials()
            // 启动时连不上服务端会回到这里，把原因展示一次。
            if errorMessage == nil, let notice = appState.loginNotice {
                errorMessage = notice
            }
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.easeOut(duration: 0.45)) {
                    appeared = true
                }
            }
        }
    }

    private var background: some View {
        ZStack(alignment: .bottom) {
            RexColor.surface
            LinearGradient(
                colors: [
                    RexColor.lightBlue.opacity(colorScheme == .dark ? 0.12 : 0.7),
                    RexColor.background.opacity(colorScheme == .dark ? 0.5 : 0.35),
                    RexColor.surface
                ],
                startPoint: .top,
                endPoint: .center
            )

            WaveField(intensity: 0.5, heightScale: 0.45)
        }
        .ignoresSafeArea()
    }

    private var brandHeader: some View {
        VStack(spacing: RexSpacing.lg) {
            RexLogoMark(size: 96)

            Text("RexHub")
                .font(RexFont.title1)
                .foregroundStyle(RexColor.primaryText)
        }
    }

    private var serverField: some View {
        let isInvalid = !serverAddress.isEmpty && !isServerValid

        return VStack(alignment: .leading, spacing: RexSpacing.sm) {
            HStack(spacing: RexSpacing.md) {
                Image(systemName: "server.rack")
                    .font(.system(size: 16))
                    .foregroundStyle(RexColor.secondaryText)
                    .frame(width: 22)

                TextField("服务器地址，如 192.168.1.10:8080", text: $serverAddress)
                    .font(RexFont.body)
                    .foregroundStyle(RexColor.primaryText)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($focusedField, equals: .server)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .account }
            }
            .fieldStyle()
            .overlay {
                fieldBorder(isFocused: focusedField == .server, isInvalid: isInvalid)
            }

            if isInvalid {
                Text("地址无效，请输入 IP、域名或完整 URL")
                    .font(.system(size: 12))
                    .foregroundStyle(RexColor.error)
                    .padding(.horizontal, RexSpacing.xs)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isInvalid)
    }

    private var httpsToggle: some View {
        HStack(spacing: RexSpacing.sm) {
            Text("HTTPS 加密访问")
                .font(RexFont.caption)
                .foregroundStyle(RexColor.primaryText)

            Spacer()

            Toggle("HTTPS 加密访问", isOn: $useHTTPS)
                .labelsHidden()
                .tint(RexColor.brandBlue)
                .scaleEffect(0.9)
        }
        .padding(.horizontal, RexSpacing.xs)
    }

    private var accountField: some View {
        HStack(spacing: RexSpacing.md) {
            Image(systemName: "person")
                .font(.system(size: 16))
                .foregroundStyle(RexColor.secondaryText)
                .frame(width: 22)

            TextField("请输入账号", text: $account)
                .font(RexFont.body)
                .foregroundStyle(RexColor.primaryText)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .focused($focusedField, equals: .account)
                .submitLabel(.next)
                .onSubmit { focusedField = .password }
        }
        .fieldStyle()
        .overlay {
            fieldBorder(isFocused: focusedField == .account)
        }
    }

    private var passwordField: some View {
        HStack(spacing: RexSpacing.md) {
            Image(systemName: "lock")
                .font(.system(size: 16))
                .foregroundStyle(RexColor.secondaryText)
                .frame(width: 22)

            Group {
                if isPasswordVisible {
                    TextField("请输入密码", text: $password)
                } else {
                    SecureField("请输入密码", text: $password)
                }
            }
            .font(RexFont.body)
            .foregroundStyle(RexColor.primaryText)
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focusedField, equals: .password)
            .submitLabel(.go)
            .onSubmit { submit() }

            Button {
                isPasswordVisible.toggle()
            } label: {
                Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                    .font(.system(size: 16))
                    .foregroundStyle(RexColor.secondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPasswordVisible ? "隐藏密码" : "显示密码")
        }
        .fieldStyle()
        .overlay {
            fieldBorder(isFocused: focusedField == .password)
        }
    }

    private func fieldBorder(isFocused: Bool, isInvalid: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
            .stroke(
                isInvalid
                    ? RexColor.error.opacity(0.65)
                    : (isFocused ? RexColor.brandBlue.opacity(0.6) : .clear),
                lineWidth: 1.5
            )
    }

    private var optionsRow: some View {
        HStack {
            Button {
                rememberPassword.toggle()
            } label: {
                HStack(spacing: RexSpacing.sm) {
                    Image(systemName: rememberPassword ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(rememberPassword ? RexColor.brandBlue : RexColor.secondaryText)

                    Text("记住密码")
                        .font(RexFont.caption)
                        .foregroundStyle(RexColor.primaryText)
                }
                .padding(.vertical, RexSpacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("记住密码")
            .accessibilityValue(rememberPassword ? "已开启" : "已关闭")

            Spacer()

            Button("忘记密码?") {}
                .font(RexFont.caption)
                .foregroundStyle(RexColor.brandBlue)
                .buttonStyle(.plain)
                .padding(.vertical, RexSpacing.sm)
        }
    }

    private var submitButton: some View {
        Button(action: submit) {
            Group {
                if isSubmitting {
                    ProgressView()
                        .tint(RexColor.onBrand)
                } else {
                    Text("登录")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(canSubmit ? RexColor.onBrand : RexColor.secondaryText)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background {
                if canSubmit {
                    RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                        .fill(RexColor.brandGradient)
                } else {
                    RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                        .fill(RexColor.field)
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!canSubmit || isSubmitting)
        .shadow(color: canSubmit ? RexColor.brandBlue.opacity(0.3) : .clear, radius: 16, y: 8)
        .animation(.easeInOut(duration: 0.2), value: canSubmit)
    }

    private func restoreCredentials() {
        guard let saved = CredentialStore.password, !saved.isEmpty else { return }
        if let savedAccount = CredentialStore.account {
            account = savedAccount
        }
        password = saved
        rememberPassword = true
    }

    private func submit() {
        focusedField = nil
        guard canSubmit, !isSubmitting else { return }
        errorMessage = nil
        isSubmitting = true

        Task {
            do {
                try await appState.signIn(
                    serverText: serverAddress,
                    useHTTPS: useHTTPS,
                    username: account,
                    password: password
                )
                if rememberPassword {
                    CredentialStore.remember(account: account, password: password)
                } else {
                    CredentialStore.forget()
                }
                isSubmitting = false
            } catch {
                isSubmitting = false
                withAnimation(.easeOut(duration: 0.2)) {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private var footer: some View {
        Button {
            focusedField = nil
        } label: {
            HStack(spacing: RexSpacing.sm) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .medium))

                Text("发现局域网设备")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(RexColor.brandBlue)
            .padding(.vertical, RexSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func fieldStyle() -> some View {
        padding(.horizontal, RexSpacing.lg)
            .frame(height: 56)
            .background(
                RexColor.field,
                in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
            )
    }
}

/// 关闭 iOS 26 起状态栏下方自动出现的滚动边缘分割线。
private struct HiddenTopScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

#Preview {
    LoginView()
        .environment(AppState())
}
