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
    @Environment(\.verticalSizeClass) private var verticalSizeClass

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
                        .padding(.top, verticalSizeClass == .compact ? 28 : 56)
                        .padding(.bottom, verticalSizeClass == .compact ? 28 : 40)

                    VStack(spacing: RexSpacing.md) {
                        serverField
                            .id(Field.server)

                        accountField
                            .id(Field.account)

                        passwordField
                            .id(Field.password)
                    }

                    if let errorMessage {
                        RexInlineNotice(
                            title: "无法登录",
                            message: errorMessage,
                            tone: .error
                        )
                        .padding(.top, RexSpacing.md)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    optionsRow
                        .padding(.top, RexSpacing.md)
                        .padding(.horizontal, RexSpacing.xs)

                    httpsToggle
                        .padding(.top, RexSpacing.lg)
                        .padding(.horizontal, RexSpacing.xs)

                    submitButton
                        .padding(.top, RexSpacing.lg)
                }
                .frame(maxWidth: RexLayout.formMaxWidth)
                .frame(maxWidth: .infinity)
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
        VStack(spacing: RexSpacing.md) {
            RexLogoMark(size: verticalSizeClass == .compact ? 76 : 92)

            Text("RexHub")
                .font(RexFont.title1)
                .foregroundStyle(RexColor.primaryText)

            Text("连接你的私有媒体中心")
                .font(RexFont.footnote)
                .foregroundStyle(RexColor.secondaryText)
        }
    }

    private var serverField: some View {
        let isInvalid = !serverAddress.isEmpty && !isServerValid

        return VStack(alignment: .leading, spacing: RexSpacing.sm) {
            HStack(spacing: RexSpacing.md) {
                Image(systemName: "server.rack")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(focusedField == .server ? RexColor.brandBlue : RexColor.secondaryText)
                    .frame(width: 22)
                    .animation(RexMotion.quick, value: focusedField)

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
                RexNote(
                    text: "地址无效，请输入 IP、域名或完整 URL",
                    tone: .error
                )
                .transition(.opacity)
            }
        }
        .animation(RexMotion.quick, value: isInvalid)
    }

    private var httpsToggle: some View {
        HStack(spacing: RexSpacing.sm) {
            Text("HTTPS 加密访问")
                .font(RexFont.body)
                .foregroundStyle(RexColor.primaryText)

            Spacer()

            Toggle("HTTPS 加密访问", isOn: $useHTTPS)
                .labelsHidden()
                .tint(RexColor.brandBlue)
        }
        .padding(.horizontal, RexSpacing.xs)
        .frame(minHeight: RexLayout.minTouch)
    }

    private var accountField: some View {
        HStack(spacing: RexSpacing.md) {
            Image(systemName: "person")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(focusedField == .account ? RexColor.brandBlue : RexColor.secondaryText)
                .frame(width: 22)
                .animation(RexMotion.quick, value: focusedField)

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
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(focusedField == .password ? RexColor.brandBlue : RexColor.secondaryText)
                .frame(width: 22)
                .animation(RexMotion.quick, value: focusedField)

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
                RexHaptics.tap()
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
        RoundedRectangle(cornerRadius: RexRadius.control + 2, style: .continuous)
            .strokeBorder(
                isInvalid
                    ? RexColor.error.opacity(0.65)
                    : (isFocused ? RexColor.brandBlue.opacity(0.65) : RexColor.fieldBorder),
                lineWidth: isFocused || isInvalid ? 1.5 : 1
            )
    }

    private var optionsRow: some View {
        HStack {
            Button {
                RexHaptics.selection()
                rememberPassword.toggle()
            } label: {
                HStack(spacing: RexSpacing.sm) {
                    Image(systemName: rememberPassword ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(rememberPassword ? RexColor.brandBlue : RexColor.tertiaryText)
                        .contentTransition(.symbolEffect(.replace))

                    Text("记住密码")
                        .font(RexFont.subheadline)
                        .foregroundStyle(RexColor.primaryText)
                }
                .frame(minHeight: RexLayout.minTouch)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("记住密码")
            .accessibilityValue(rememberPassword ? "已开启" : "已关闭")

            Spacer()
        }
    }

    private var submitButton: some View {
        Button {
            RexHaptics.tap()
            submit()
        } label: {
            Group {
                if isSubmitting {
                    ProgressView()
                        .tint(RexColor.onBrand)
                } else {
                    Text("登录")
                        .font(RexFont.button)
                        .foregroundStyle(canSubmit ? RexColor.onBrand : RexColor.brandBlue.opacity(0.72))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .frame(minHeight: 54)
            .background {
                if canSubmit {
                    RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                        .fill(RexColor.brandGradient)
                } else {
                    RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                        .fill(RexColor.brandBlue.opacity(0.12))
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!canSubmit || isSubmitting)
        .shadow(color: canSubmit ? RexColor.brandBlue.opacity(0.3) : .clear, radius: 16, y: 8)
        .animation(RexMotion.standard, value: canSubmit)
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
                RexHaptics.success()
            } catch {
                isSubmitting = false
                RexHaptics.error()
                withAnimation(RexMotion.quick) {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct RexLoginFieldSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, RexSpacing.lg)
            .padding(.vertical, 4)
            .frame(minHeight: 56)
            .background(
                RexColor.surface,
                in: RoundedRectangle(cornerRadius: RexRadius.control + 2, style: .continuous)
            )
            .shadow(
                color: colorScheme == .light ? Color.black.opacity(0.035) : .clear,
                radius: 10,
                y: 4
            )
    }
}

private extension View {
    func fieldStyle() -> some View {
        modifier(RexLoginFieldSurface())
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
