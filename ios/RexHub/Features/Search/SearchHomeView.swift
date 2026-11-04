import SwiftUI

/// 资源搜索入口：输入关键词、选择来源，跳转到结果列表页。
struct SearchHomeView: View {
    /// 外部每次递增表示要求聚焦搜索框（例如在影视页点了顶栏搜索）。
    var focusToken: Int = 0
    /// 顶栏头像使用的名字。
    var name: String = ""
    /// 点击顶栏头像的动作（通常是切到「更多」）。
    var onOpenMore: (() -> Void)?

    @Environment(\.apiClient) private var apiClient

    @State private var isScrolled = false
    @State private var avatars = AvatarStore.shared
    @State private var keyword = ""
    @State private var fieldFocusToken = 0
    @State private var handledFocusToken = 0
    @State private var services: [SearchService] = []
    @State private var isLoadingServices = true
    @State private var servicesError: String?
    @State private var selectedIDs: Set<String> = []
    @State private var destination: SearchDestination?
    @State private var toast: String?
    @State private var showsNotifications = false

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    private let maxHeroWidth: CGFloat = 600

    var body: some View {
        VStack(spacing: 0) {
            RexTopBar(title: "搜索", isCollapsed: isScrolled) {
                leadingAvatar
            } trailing: {
                notificationButton
            }

            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        hero
                    }
                    .padding(.horizontal, RexSpacing.xl)
                    .padding(.top, verticalSizeClass == .compact ? RexSpacing.lg : RexSpacing.xxl)
                    .padding(.bottom, RexSpacing.huge)
                    .frame(maxWidth: RexLayout.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height, alignment: .center)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize)
                .rexScrollTracking("searchScroll", isScrolled: $isScrolled)
                .overlay(alignment: .top) {
                    if let toast {
                        RexToastBanner(message: toast, symbol: "exclamationmark.circle.fill")
                            .padding(.horizontal, RexSpacing.xl)
                            .padding(.top, RexSpacing.sm)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(RexMotion.quick, value: toast)
            }
        }
        .background(RexPageBackground())
        .navigationDestination(item: $destination) { item in
            SearchResultsView(keyword: item.keyword, sources: item.sources)
                .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showsNotifications) {
            NotificationCenterSheet()
        }
        .task { await loadServices() }
        .onAppear {
            guard focusToken != handledFocusToken else { return }
            handledFocusToken = focusToken
            focusField()
        }
        .onChange(of: focusToken) { _, newValue in
            handledFocusToken = newValue
            focusField()
        }
    }

    // MARK: - 顶部

    @ViewBuilder
    private var leadingAvatar: some View {
        if let onOpenMore {
            Button(action: onOpenMore) {
                RexAvatar(name: name, size: 32, selection: avatars.selection)
            }
            .buttonStyle(PressableButtonStyle())
            .frame(width: 44, height: 44)
            .accessibilityLabel("打开更多")
        }
    }

    private var notificationButton: some View {
        Button {
            RexHaptics.tap()
            showsNotifications = true
        } label: {
            Image(systemName: "bell")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(RexColor.primaryText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("通知")
    }

    private var hero: some View {
        VStack(spacing: verticalSizeClass == .compact ? RexSpacing.lg : RexSpacing.xxl) {
            brandBlock
            searchBar
            servicePicker
        }
        .frame(maxWidth: maxHeroWidth)
    }

    private var logoSize: CGFloat {
        if verticalSizeClass == .compact { return 84 }
        return dynamicTypeSize.isAccessibilitySize ? 88 : 112
    }

    private var brandBlock: some View {
        ZStack {
            // 图标后的柔光与光环
            Ellipse()
                .fill(RexColor.brandBlue.opacity(0.18))
                .frame(width: logoSize * 1.75, height: logoSize * 0.96)
                .blur(radius: 28)

            Ellipse()
                .strokeBorder(.white.opacity(0.65), lineWidth: 1)
                .frame(width: logoSize * 1.68, height: logoSize * 0.92)
                .rotationEffect(.degrees(-16))

            RexLogoMark(size: logoSize)
        }
        .frame(height: logoSize * 1.18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("RexHub")
    }

    private var searchBar: some View {
        SearchPillField(
            text: $keyword,
            placeholder: "搜索片名、番号或关键词",
            focusToken: fieldFocusToken,
            onSubmit: submit
        )
    }

    private var servicePicker: some View {
        Group {
            if services.isEmpty {
                emptyServicesCard
            } else {
                HStack(spacing: RexSpacing.sm) {
                    ForEach(services) { service in
                        serviceCard(service)
                    }
                }
                .frame(maxWidth: RexLayout.readableMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, RexSpacing.xs)
                .animation(RexMotion.spring, value: selectedIDs)
            }
        }
    }

    private var emptyServicesCard: some View {
        HStack(alignment: .center, spacing: RexSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill((servicesError == nil ? RexColor.brandBlue : RexColor.warning).opacity(0.10))
                    .frame(width: 42, height: 42)

                if isLoadingServices {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: servicesError == nil ? "square.stack.3d.up" : "wifi.exclamationmark")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(servicesError == nil ? RexColor.brandBlue : RexColor.warning)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(isLoadingServices ? "正在读取搜索服务" : (servicesError == nil ? "还没有可用来源" : "来源加载失败"))
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)

                Text(servicesError ?? (isLoadingServices ? "马上就好…" : "请先在服务管理中添加搜索服务。"))
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if !isLoadingServices {
                Button {
                    RexHaptics.tap()
                    if servicesError != nil {
                        Task { await loadServices() }
                    } else {
                        onOpenMore?()
                    }
                } label: {
                    Text(servicesError == nil ? "去添加" : "重试")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(RexColor.brandBlue)
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(servicesError == nil && onOpenMore == nil)
            }
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.vertical, RexSpacing.md)
        .rexCard()
        .animation(RexMotion.standard, value: isLoadingServices)
    }

    /// 服务图标：优先使用各服务的官方图标资源，缺失时退回语义相近的系统图标。
    private func serviceIcon(_ service: SearchService) -> (symbol: String, tint: Color, asset: String?) {
        let name = service.name.lowercased()
        if name.contains("bitmagnet") {
            return ("cylinder.split.1x2.fill", RexColor.brandBlue, "ServiceBitmagnet")
        }
        if name.contains("cloud") {
            return ("cloud.fill", Color(hex: 0x0EA5E9), "ServiceCloudSaver")
        }
        if name.contains("色花堂") {
            return ("camera.macro", Color(hex: 0xEC4899), "ServiceSehuatang")
        }
        return ("square.stack.3d.up.fill", RexColor.brandBlue, nil)
    }

    private func serviceCard(_ service: SearchService) -> some View {
        let isSelected = selectedIDs.contains(service.id)
        let icon = serviceIcon(service)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        return Button {
            RexHaptics.selection()
            withAnimation(RexMotion.spring) {
                if isSelected {
                    selectedIDs.remove(service.id)
                } else {
                    selectedIDs.insert(service.id)
                }
            }
            // 勾选状态随手记住，下次打开搜索页沿用
            SearchSelectionStore.save(selectedIDs)
        } label: {
            VStack(spacing: 5) {
                Group {
                    if let asset = icon.asset {
                        let size = iconSize(for: asset)
                        Image(asset)
                            .resizable()
                            .interpolation(.high)
                            .antialiased(true)
                            .scaledToFit()
                            .frame(width: size.width, height: size.height)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: icon.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(icon.tint)
                            .frame(width: 20, height: 20)
                            .background(icon.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                .frame(height: 24)

                Text(service.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 66)
            .background(
                isSelected ? RexColor.brandBlue.opacity(0.06) : RexColor.surface,
                in: shape
            )
            .overlay {
                shape.strokeBorder(
                    isSelected ? RexColor.brandBlue.opacity(0.26) : RexColor.cardBorder,
                    lineWidth: isSelected ? 1 : 0.75
                )
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(RexColor.onBrand)
                        .frame(width: 14, height: 14)
                        .background(RexColor.brandBlue, in: Circle())
                        .padding(6)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .shadow(
                color: (!isSelected && colorScheme == .light) ? Color.black.opacity(0.04) : .clear,
                radius: 8,
                y: 3
            )
            .contentShape(shape)
        }
        .buttonStyle(PressableButtonStyle())
        .animation(RexMotion.spring, value: isSelected)
        .accessibilityLabel(service.name)
        .accessibilityHint(isSelected ? "已选为搜索来源" : "点按加入搜索来源")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 宽幅的品牌图标需要更宽的展示区域，窄幅的直接按高度对齐，保证视觉面积相近。
    /// 三个服务图标统一 24pt 高；CloudSaver 的云形标志更宽，单独放宽到 34pt。
    private func iconSize(for asset: String?) -> CGSize {
        asset == "ServiceCloudSaver"
            ? CGSize(width: 34, height: 24)
            : CGSize(width: 24, height: 24)
    }

    // MARK: - 浮层

    // MARK: - 数据

    private func loadServices() async {
        guard let client = apiClient else {
            isLoadingServices = false
            servicesError = "尚未连接 NAS 服务，请先在更多页完成登录。"
            return
        }

        isLoadingServices = true
        servicesError = nil
        defer { isLoadingServices = false }

        do {
            let items = try await client.searchServices()
            services = items
            let ids = Set(items.map(\.id))
            // 记住上次勾选的来源；第一次打开默认全不选，服务下线后自动剔除旧 ID
            selectedIDs = SearchSelectionStore.load().intersection(ids)
            SearchSelectionStore.save(selectedIDs)
        } catch {
            servicesError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func submit() {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard apiClient != nil else {
            showToast("服务未连接，请稍后重试")
            return
        }

        let picked = services
            .filter { selectedIDs.contains($0.id) }
            .map { SearchSource(id: $0.id, name: $0.name) }

        guard !picked.isEmpty else {
            showToast("请至少选择一个搜索来源")
            return
        }

        destination = SearchDestination(keyword: query, sources: picked)
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
}

/// 搜索页主输入胶囊：右侧内嵌圆形品牌搜索按钮，空关键词时为禁用态。
private struct SearchPillField: View {
    @Binding var text: String
    var placeholder: String
    var focusToken: Int
    var onSubmit: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: RexSpacing.xs) {
            TextField(placeholder, text: $text)
                .font(RexFont.body)
                .foregroundStyle(RexColor.primaryText)
                .tint(RexColor.brandBlue)
                .focused($isFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(onSubmit)
                .accessibilityLabel(placeholder)
                .padding(.leading, RexSpacing.xl)

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
    }
}

/// 一次搜索的目标页参数：关键词 + 选中的来源。
private struct SearchDestination: Identifiable, Hashable {
    let keyword: String
    let sources: [SearchSource]

    var id: String {
        keyword + "|" + sources.map(\.id).joined(separator: ",")
    }
}

/// 系统通知入口：暂未接入通知数据源时展示统一空状态。
private struct NotificationCenterSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                RexStateCard(
                    symbol: "bell",
                    title: "暂无通知",
                    message: "系统通知会显示在这里。"
                )

                Spacer(minLength: 0)
            }
            .padding(RexSpacing.xl)
            .frame(maxWidth: RexLayout.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .background(RexPageBackground())
            .navigationTitle("通知")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(RexColor.brandBlue)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

/// 搜索来源选择的本地记忆：进入搜索页时沿用上次勾选，第一次打开默认全不选。
private enum SearchSelectionStore {
    private static let key = "rexhub.search.selectedServiceIDs"

    static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func save(_ ids: Set<String>) {
        UserDefaults.standard.set(ids.sorted(), forKey: key)
    }
}

#Preview {
    SearchHomeView()
}
