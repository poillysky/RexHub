import SwiftUI

/// 搜索首页：对齐 PWA Landing —— 顶部品牌 + 快捷胶囊，中部 logo / 标题 / 搜索框。
struct SearchHomeView: View {
    /// 外部每次递增表示要求聚焦搜索框（例如在影视页点了顶栏搜索）。
    var focusToken: Int = 0
    /// 顶栏头像使用的名字（保留给调用方兼容，落地页不再展示头像）。
    var name: String = ""
    /// 点击顶栏头像的动作（通常是切到「更多」）。
    var onOpenMore: (() -> Void)?
    /// 转存入口只对管理员展示：服务端转存接口要求管理员权限。
    var isAdmin: Bool = false

    @Environment(\.apiClient) private var apiClient

    @State private var keyword = ""
    @State private var scope: SearchScope = ScopeSelectionStore.load()
    @State private var fieldFocusToken = 0
    @State private var handledFocusToken = 0
    @State private var scopeDestination: ScopeDestination?
    @State private var alert: RexAlertInfo?
    @State private var showsAssistant = false
    @State private var showsOffline = false
    @State private var showsBoards = false

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    private let maxHeroWidth: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            landingTop

            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        hero
                    }
                    .padding(.horizontal, RexSpacing.xl)
                    .padding(.bottom, verticalSizeClass == .compact ? RexSpacing.lg : 120)
                    .frame(maxWidth: RexLayout.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height, alignment: .center)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .background(RexPageBackground())
        .overlay(alignment: .bottomTrailing) {
            assistantFAB
                .padding(.trailing, RexSpacing.xl)
                .padding(.bottom, RexSpacing.xxl)
        }
        .navigationDestination(item: $scopeDestination) { item in
            ScopeSearchView(keyword: item.keyword, scope: item.scope)
                .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showsAssistant) {
            AssistantView()
                .rexSheetStyle(detents: [.large])
        }
        .sheet(isPresented: $showsOffline) {
            PanOfflineView(isAdmin: isAdmin)
                .rexSheetStyle(detents: [.large])
        }
        .sheet(isPresented: $showsBoards) {
            BoardsView()
                .rexSheetStyle(detents: [.large])
        }
        .onAppear {
            guard focusToken != handledFocusToken else { return }
            handledFocusToken = focusToken
            focusField()
        }
        .onChange(of: focusToken) { _, newValue in
            handledFocusToken = newValue
            focusField()
        }
        .rexAlert($alert)
    }

    // MARK: - 顶部（品牌 + 快捷胶囊）

    private var landingTop: some View {
        HStack(alignment: .center, spacing: RexSpacing.md) {
            HStack(spacing: RexSpacing.sm) {
                RexLogoMark(size: 28, hasShadow: true)

                Text("RexHub")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(RexColor.primaryText)
            }

            Spacer(minLength: 0)

            HStack(spacing: RexSpacing.sm) {
                topChip(title: "板块", symbol: "square.grid.2x2") {
                    showsBoards = true
                }

                if isAdmin {
                    topChip(title: "转存", symbol: "doc.on.clipboard") {
                        showsOffline = true
                    }
                }
            }
        }
        .padding(.horizontal, RexSpacing.xl)
        .padding(.top, RexSpacing.xs)
        .padding(.bottom, RexSpacing.sm)
    }

    /// 右下角悬浮的搜片助手入口：对应 PWA 的 chat-bot 圆形按钮。
    private var assistantFAB: some View {
        Button {
            RexHaptics.tap()
            showsAssistant = true
        } label: {
            ZStack {
                Circle()
                    .fill(RexColor.brandGradient)
                    .frame(width: 56, height: 56)
                    .shadow(color: RexColor.brandBlue.opacity(0.32), radius: 14, y: 6)

                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(0.28), lineWidth: 1)
            }
            .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("AI 搜片助手")
    }

    private func topChip(title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            RexHaptics.tap()
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RexColor.brandBlue)

                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(
                RexColor.surface.opacity(0.88),
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(RexColor.cardBorder, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: verticalSizeClass == .compact ? RexSpacing.lg : RexSpacing.xl) {
            brandBlock
            searchBar
        }
        .frame(maxWidth: maxHeroWidth)
    }

    private var logoSize: CGFloat {
        if verticalSizeClass == .compact { return 88 }
        return 104
    }

    private var brandBlock: some View {
        VStack(spacing: RexSpacing.md) {
            RexLogoMark(size: logoSize)

            VStack(spacing: 6) {
                Text("RexHub")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(RexColor.primaryText)

                Text("片名 · 番号 · 关键词 · 多源同搜")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(RexColor.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("RexHub")
    }

    private var searchBar: some View {
        SearchPillField(
            text: $keyword,
            placeholder: "搜索片名、番号或关键词",
            scope: scope,
            scopeTitle: scope.title,
            onScopeChange: { value in
                scope = value
                ScopeSelectionStore.save(value)
            },
            focusToken: fieldFocusToken,
            onSubmit: submit
        )
    }

    // MARK: - 数据

    private func submit() {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard apiClient != nil else {
            showToast("服务未连接，请稍后重试")
            return
        }
        scopeDestination = ScopeDestination(keyword: query, scope: scope)
    }

    // MARK: - 交互

    private func focusField() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            fieldFocusToken += 1
        }
    }

    private func showToast(_ text: String) {
        RexHaptics.warning()
        alert = .notice(text)
    }
}

/// 搜索页主输入胶囊：左侧内嵌范围下拉（影视 / 片商），右侧圆形搜索按钮，空关键词时为禁用态。
private struct SearchPillField: View {
    @Binding var text: String
    var placeholder: String
    var scope: SearchScope
    var scopeTitle: String
    var onScopeChange: (SearchScope) -> Void
    var focusToken: Int
    var onSubmit: () -> Void

    @FocusState private var isFocused: Bool
    @State private var showsScopeMenu = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: RexSpacing.sm) {
            scopeMenu

            Rectangle()
                .fill(RexColor.divider)
                .frame(width: 1 / displayScale, height: 24)

            TextField(placeholder, text: $text)
                .font(RexFont.body)
                .foregroundStyle(RexColor.primaryText)
                .tint(RexColor.brandBlue)
                .focused($isFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit {
                    showsScopeMenu = false
                    onSubmit()
                }
                .accessibilityLabel(placeholder)
                .padding(.leading, RexSpacing.xs)

            if !text.isEmpty {
                Button {
                    RexHaptics.tap()
                    withAnimation(RexMotion.quick) { text = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(RexColor.tertiaryText)
                        .frame(width: 28, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
                .transition(.opacity)
            }

            Button {
                RexHaptics.tap()
                onSubmit()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(canSubmit ? 1 : 0.55))
                    .frame(width: 42, height: 42)
                    .background {
                        Circle()
                            .fill(
                                canSubmit
                                    ? AnyShapeStyle(RexColor.brandGradient)
                                    : AnyShapeStyle(RexColor.brandBlue.opacity(0.16))
                            )
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Circle())
                    .shadow(
                        color: RexColor.brandBlue.opacity(canSubmit ? 0.28 : 0),
                        radius: 10,
                        y: 4
                    )
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!canSubmit)
            .accessibilityLabel("搜索")
            .padding(.trailing, 6)
        }
        .padding(.vertical, 6)
        .frame(minHeight: 54)
        .background(
            RexColor.surface,
            in: Capsule(style: .continuous)
        )
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(
                    isFocused ? RexColor.brandBlue.opacity(0.6) : RexColor.cardBorder,
                    lineWidth: isFocused ? 1.5 : 0.75
                )
        }
        .shadow(
            color: colorScheme == .light ? Color.black.opacity(isFocused ? 0.07 : 0.045) : .clear,
            radius: 14,
            y: 6
        )
        .shadow(color: RexColor.brandBlue.opacity(isFocused ? 0.10 : 0), radius: 12, y: 2)
        .animation(RexMotion.quick, value: isFocused)
        .animation(RexMotion.quick, value: canSubmit)
        .onChange(of: focusToken) { _, _ in isFocused = true }
        .onChange(of: isFocused) { _, focused in
            if focused { showsScopeMenu = false }
        }
    }

    /// 搜索范围下拉：与 PWA 的 SourceSwitch 一致，嵌在输入框左侧。
    /// 用自绘小弹层而非系统 Menu，避免系统菜单的最小宽度把弹层拉宽、留出大片空白。
    private var scopeMenu: some View {
        Button {
            RexHaptics.tap()
            withAnimation(RexMotion.quick) {
                showsScopeMenu.toggle()
            }
        } label: {
            HStack(spacing: 2) {
                Text(scopeTitle)
                    .font(.system(size: 13, weight: .semibold))

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(RexColor.primaryText)
            .padding(.leading, RexSpacing.md)
            .padding(.trailing, RexSpacing.sm)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("搜索范围：\(scopeTitle)")
        .accessibilityAddTraits(showsScopeMenu ? .isSelected : [])
        .overlay(alignment: .topLeading) {
            if showsScopeMenu {
                scopeMenuPanel
                    .offset(y: 46)
                    .zIndex(3)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
            }
        }
    }

    private var scopeMenuPanel: some View {
        VStack(spacing: 0) {
            ForEach(SearchScope.allCases) { item in
                Button {
                    showsScopeMenu = false
                    guard item != scope else { return }
                    RexHaptics.selection()
                    onScopeChange(item)
                } label: {
                    HStack(spacing: RexSpacing.sm) {
                        Text(item.title)
                            .font(.system(size: 13, weight: item == scope ? .semibold : .regular))
                            .foregroundStyle(RexColor.primaryText)

                        Spacer(minLength: 0)

                        if item == scope {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(RexColor.brandBlue)
                        }
                    }
                    .padding(.horizontal, RexSpacing.md)
                    .frame(width: 108, height: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if item != SearchScope.allCases.last {
                    Rectangle()
                        .fill(RexColor.divider)
                        .frame(height: 1 / displayScale)
                        .padding(.horizontal, RexSpacing.md)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }
}

/// 范围搜索入口参数。
private struct ScopeDestination: Identifiable, Hashable {
    let keyword: String
    let scope: SearchScope

    var id: String { scope.rawValue + "|" + keyword }
}

/// 搜索范围选择的本地记忆：下次打开搜索页沿用上次选的范围。
enum ScopeSelectionStore {
    private static let key = "rexhub.search.scope"

    static func load() -> SearchScope {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let value = SearchScope(rawValue: raw) else { return .movie }
        return value
    }

    static func save(_ scope: SearchScope) {
        UserDefaults.standard.set(scope.rawValue, forKey: key)
    }
}

#Preview {
    SearchHomeView()
}
