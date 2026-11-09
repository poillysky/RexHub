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
    @State private var alert: RexAlertInfo?
    @State private var serverError: String?
    @State private var accountError: String?
    @State private var passwordError: String?
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
        .overlay {
            if isSubmitting {
                connectionOverlay
            }
        }
        .animation(RexMotion.quick, value: isSubmitting)
        .rexAlert($alert)
        .onChange(of: useHTTPS) { _, value in
            ServerConfig.httpsEnabled = value
        }
        .onChange(of: rememberPassword) { _, value in
            guard !value else { return }
            CredentialStore.forget()
        }
        .onChange(of: account) { _, _ in
            if accountError != nil { accountError = nil }
        }
        .onChange(of: password) { _, _ in
            if passwordError != nil { passwordError = nil }
        }
        .onChange(of: serverAddress) { _, text in
            if serverError != nil { serverError = nil }
            guard let explicit = ServerConfig.explicitHTTPS(in: text), explicit != useHTTPS else { return }
            useHTTPS = explicit
        }
        .onAppear {
            restoreCredentials()
            // 启动时连不上服务端会回到这里，把原因展示一次。
            if alert == nil, let startupNotice = appState.loginNotice {
                alert = RexAlertInfo(title: "无法连接服务器", message: startupNotice)
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

    /// 连接中的透明遮罩：挡住整页交互，避免重复提交，并明确告诉用户正在做什么。
    private var connectionOverlay: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}

            VStack(spacing: RexSpacing.md) {
                ProgressView()
                    .controlSize(.large)
                    .tint(RexColor.brandBlue)

                Text("正在连接服务器…")
                    .font(RexFont.footnote)
                    .foregroundStyle(RexColor.primaryText)
            }
            .padding(.horizontal, RexSpacing.xxl)
            .padding(.vertical, RexSpacing.xl)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                    .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("正在连接服务器")
        }
        .transition(.opacity)
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
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
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
                fieldBorder(
                    isFocused: focusedField == .server,
                    isInvalid: serverErrorText != nil
                )
            }

            if let serverErrorText {
                RexNote(text: serverErrorText, tone: .error)
                    .transition(.opacity)
            }
        }
        .animation(RexMotion.quick, value: serverErrorText)
    }

    /// 地址错误：提交时的必填/格式错误，或边输入边校验的格式错误。
    private var serverErrorText: String? {
        if let serverError { return serverError }
        guard !serverAddress.isEmpty, !isServerValid else { return nil }
        return "地址无效，请输入 IP、域名或完整 URL"
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
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
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
                fieldBorder(
                    isFocused: focusedField == .account,
                    isInvalid: accountError != nil
                )
            }

            if let accountError {
                RexNote(text: accountError, tone: .error)
                    .transition(.opacity)
            }
        }
        .animation(RexMotion.quick, value: accountError)
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
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
                fieldBorder(
                    isFocused: focusedField == .password,
                    isInvalid: passwordError != nil
                )
            }

            if let passwordError {
                RexNote(text: passwordError, tone: .error)
                    .transition(.opacity)
            }
        }
        .animation(RexMotion.quick, value: passwordError)
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
        // 不因为字段为空就禁用：空提交时由字段级提示告诉用户缺什么，比"按钮点不动"更可发现。
        .disabled(isSubmitting)
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
        guard !isSubmitting else { return }
        focusedField = nil

        alert = nil
        withAnimation(RexMotion.quick) {
            serverError = nil
            accountError = nil
            passwordError = nil
        }

        let trimmedServer = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        var firstInvalid: Field?
        var hints: [String] = []

        if trimmedServer.isEmpty {
            serverError = "请输入服务器地址"
            firstInvalid = .server
            hints.append("服务器地址不能为空")
        } else if !isServerValid {
            serverError = "地址无效，请输入 IP、域名或完整 URL"
            firstInvalid = .server
            hints.append("服务器地址格式不正确")
        }

        if trimmedAccount.isEmpty {
            accountError = "请输入账号"
            if firstInvalid == nil { firstInvalid = .account }
            hints.append("账号不能为空")
        }

        if password.isEmpty {
            passwordError = "请输入密码"
            if firstInvalid == nil { firstInvalid = .password }
            hints.append("密码不能为空")
        }

        if let firstInvalid {
            RexHaptics.error()
            focusedField = firstInvalid
            announce(hints.joined(separator: "，"))
            return
        }

        isSubmitting = true

        Task {
            do {
                try await appState.signIn(
                    serverText: trimmedServer,
                    useHTTPS: useHTTPS,
                    username: trimmedAccount,
                    password: password
                )
                if rememberPassword {
                    CredentialStore.remember(account: trimmedAccount, password: password)
                } else {
                    CredentialStore.forget()
                }
                isSubmitting = false
                RexHaptics.success()
            } catch {
                isSubmitting = false
                RexHaptics.error()
                let failure = loginAlert(for: error)
                alert = failure
                announce("\(failure.title)。\(failure.message ?? "")")
            }
        }
    }

    /// 把底层错误翻译成"发生了什么 + 该怎么办"的两段式提示。
    /// 原始状态码只在需要用户配合排查时（服务端/接口异常）保留。
    private func loginAlert(for error: Error) -> RexAlertInfo {
        guard let apiError = error as? APIError else {
            return RexAlertInfo(title: "无法登录", message: error.localizedDescription)
        }

        switch apiError {
        case .unauthorized:
            return RexAlertInfo(title: "账号或密码错误", message: "请检查账号与密码后重新输入。")
        case .forbidden:
            return RexAlertInfo(title: "无访问权限", message: "该账号被禁止登录，请联系服务器管理员。")
        case .offline:
            return RexAlertInfo(title: "网络未连接", message: "请检查 Wi-Fi 或蜂窝网络后重试。")
        case .unreachable, .timeout:
            return RexAlertInfo(
                title: "无法连接服务器",
                message: "请确认地址可以访问，且手机与服务器处于同一网络。"
            )
        case .rateLimited:
            return RexAlertInfo(title: "尝试过于频繁", message: "请稍等片刻再重试。")
        case .server(let status):
            return RexAlertInfo(
                title: "服务器暂时不可用",
                message: "服务端返回 \(status)，请稍后重试。"
            )
        case .decoding:
            return RexAlertInfo(
                title: "服务器响应异常",
                message: "请确认地址指向 RexHub 服务端，且客户端与服务端版本匹配。"
            )
        case .notFound:
            return RexAlertInfo(
                title: "接口不存在",
                message: "服务端版本可能过旧，请升级后重试。"
            )
        case .badRequest(let detail):
            return RexAlertInfo(title: "无法登录", message: detail ?? "请检查输入内容后重试。")
        case .conflict(let detail):
            return RexAlertInfo(title: "登录状态冲突", message: detail ?? "请稍后重试。")
        case .cancelled:
            return RexAlertInfo(title: "已取消登录", message: "可以重新点击登录。")
        }
    }

    /// VoiceOver 只读页面时看不到弹窗，需要主动播报一次。
    private func announce(_ text: String) {
        guard !text.isEmpty else { return }
        AccessibilityNotification.Announcement(text).post()
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
