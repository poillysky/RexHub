import SwiftUI
import UniformTypeIdentifiers

/// 「全部应用」：上方是首页应用，下方是还没放到首页的应用。
///
/// 同一个应用只会出现在其中一处：加到首页后从下方消失，移出后再回到下方，
/// 宫格里不会出现两个相同的图标。
/// 点「编辑」进入编辑态（取消 / 编辑应用 / 保存），改动先落在草稿里，
/// 保存才写回首页配置，取消则原样丢弃。
struct AllAppsView: View {
    /// 点击应用后交给首页路由执行。
    let onAction: (HomeAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.apiClient) private var apiClient
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let store = HomeAppsStore.shared

    @State private var isEditing = false
    @State private var isScrolled = false
    /// 编辑草稿：保存前的首页应用顺序。
    @State private var draftIDs: [String] = []
    /// 正在拖动的应用 id，用来在拖动时虚化原位图标。
    @State private var draggingID: String?

    /// 顶部卡一行最多 5 个（图标缩小到一半）；下方卡还是 5 列大图标。
    private var homeMaxPerRow: Int {
        dynamicTypeSize.isAccessibilitySize ? 4 : 5
    }

    private var availableColumns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 4 : 5
        return Array(repeating: GridItem(.flexible(), spacing: RexSpacing.md, alignment: .top), count: count)
    }

    /// 顶部展示的应用：编辑态用草稿，平时用已保存的配置。
    private var homeApps: [HomeAppItem] {
        let ids = isEditing ? draftIDs : store.homeAppIDs
        return Self.resolve(ids, in: store.allApps)
    }

    /// 底部只列还没放到首页的应用，保证每个图标只出现一次。
    private var availableApps: [HomeAppItem] {
        let placed = Set(isEditing ? draftIDs : store.homeAppIDs)
        return store.allApps.filter { !placed.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isEditing {
                editNavBar
            } else {
                RexNavBar(
                    title: "全部应用",
                    leading: .back(action: { dismiss() }),
                    isScrolled: isScrolled
                )
            }

            ScrollView {
                VStack(spacing: RexSpacing.lg) {
                    homeAppsCard
                    if !availableApps.isEmpty {
                        availableAppsCard
                    }
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.top, RexSpacing.md)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .background(RexScrollOffsetReader(space: "allAppsScroll"))
            }
            .rexScrollTracking("allAppsScroll", isScrolled: $isScrolled)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(RexPageBackground())
        .task { await store.reload(client: apiClient) }
    }

    // MARK: 编辑态顶栏

    /// 编辑态顶栏：左「取消」、中「编辑应用」、右「保存」，与参考稿一致。
    private var editNavBar: some View {
        ZStack {
            Text("编辑应用")
                .font(.system(.headline, weight: .semibold))
                .foregroundStyle(RexColor.primaryText)

            HStack {
                Button {
                    RexHaptics.tap()
                    endEditing()
                } label: {
                    Text("取消")
                        .font(.system(.subheadline))
                        .foregroundStyle(RexColor.brandBlue)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())

                Spacer(minLength: 0)

                Button {
                    RexHaptics.tap()
                    store.setHomeApps(draftIDs)
                    endEditing()
                } label: {
                    Text("保存")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(RexColor.brandBlue)
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
            }
            .padding(.horizontal, RexSpacing.md)
        }
        .frame(height: 52)
        .frame(maxWidth: .infinity)
    }

    // MARK: 首页应用

    private var homeAppsCard: some View {
        VStack(alignment: .leading, spacing: RexSpacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                Text("首页应用")
                    .font(.system(.headline, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)

                Spacer(minLength: RexSpacing.sm)

                if isEditing {
                    Text("长按拖动排序，轻点移出")
                        .font(RexFont.caption)
                        .foregroundStyle(RexColor.tertiaryText)
                } else {
                    Button {
                        RexHaptics.tap()
                        beginEditing()
                    } label: {
                        Text("编辑")
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(RexColor.primaryText)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 30)
                            .background(Capsule(style: .continuous).fill(RexColor.field))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }

            if homeApps.isEmpty {
                Text(isEditing ? "还没有首页应用，轻点下方图标添加。" : "还没有首页应用，点「编辑」从下方添加。")
                    .font(RexFont.footnote)
                    .foregroundStyle(RexColor.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, RexSpacing.md)
            } else {
                EvenIconRowLayout(
                    maxPerRow: homeMaxPerRow,
                    itemSize: 30,
                    rowSpacing: RexSpacing.md,
                    edgeInset: RexSpacing.xs
                ) {
                    ForEach(homeApps) { app in
                        appCell(app, badge: isEditing ? .remove : nil, iconSize: 30, showsTitle: false) {
                            if isEditing {
                                withAnimation(RexMotion.standard) { removeFromDraft(app) }
                            } else {
                                launch(app)
                            }
                        }
                        .modifier(
                            HomeReorderModifier(
                                appID: app.id,
                                order: $draftIDs,
                                draggingID: $draggingID,
                                isEnabled: isEditing
                            )
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(RexSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rexCard(cornerRadius: RexRadius.panel)
        .onDrop(of: [.text], delegate: HomeDropResetDelegate(draggingID: $draggingID))
    }

    // MARK: 未添加的应用

    private var availableAppsCard: some View {
        LazyVGrid(columns: availableColumns, alignment: .leading, spacing: RexSpacing.lg) {
            ForEach(availableApps) { app in
                appCell(app, badge: isEditing ? .add : nil, iconSize: 48) {
                    if isEditing {
                        withAnimation(RexMotion.standard) { addToDraft(app) }
                    } else {
                        launch(app)
                    }
                }
            }
        }
        .padding(RexSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rexCard(cornerRadius: RexRadius.panel)
    }

    // MARK: 组件

    private enum Badge {
        case add
        case remove
    }

    private func appCell(
        _ app: HomeAppItem,
        badge: Badge?,
        iconSize: CGFloat = 60,
        showsTitle: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            RexHaptics.tap()
            action()
        } label: {
            VStack(spacing: showsTitle ? RexSpacing.sm : 0) {
                HomeAppIcon(
                    symbol: app.symbol,
                    accent: app.accent,
                    brandImage: app.brandImage,
                    logoURL: app.logoURL,
                    maxWidth: iconSize
                )
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        badgeIcon(badge, for: iconSize)
                            .offset(x: iconSize * 0.13, y: -iconSize * 0.13)
                    }
                }

                if showsTitle {
                    Text(app.title)
                        .font(.system(.caption2, weight: .medium))
                        .foregroundStyle(RexColor.secondaryText)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(app.title)
    }

    private func badgeIcon(_ badge: Badge, for iconSize: CGFloat) -> some View {
        let side: CGFloat = iconSize < 44 ? 18 : 22
        return Image(systemName: badge == .add ? "plus" : "minus")
            .font(.system(size: side * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(Circle().fill(badge == .add ? RexColor.brandBlue : Color(hex: 0x8E8E93)))
            .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
    }

    // MARK: 编辑草稿

    private func beginEditing() {
        draftIDs = store.homeAppIDs
        draggingID = nil
        withAnimation(RexMotion.standard) { isEditing = true }
    }

    private func endEditing() {
        draggingID = nil
        withAnimation(RexMotion.standard) { isEditing = false }
    }

    private func addToDraft(_ app: HomeAppItem) {
        guard !draftIDs.contains(app.id) else { return }
        draftIDs.append(app.id)
    }

    private func removeFromDraft(_ app: HomeAppItem) {
        draftIDs.removeAll { $0 == app.id }
    }

    private static func resolve(_ ids: [String], in apps: [HomeAppItem]) -> [HomeAppItem] {
        let lookup = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { lookup[$0] }
    }

    // MARK: 动作

    /// 先收起整页，再执行跳转，避免推入的页面盖在弹层下面。
    private func launch(_ app: HomeAppItem) {
        let action = app.action
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            onAction(action)
        }
    }
}

// MARK: - 长按拖动排序

/// 编辑态专用的排序手势：长按图标开始拖动，拖到另一个图标上就与它换位，松手结束。
/// 非编辑态整个原样返回，不影响单击跳转。
private struct HomeReorderModifier: ViewModifier {
    let appID: String
    @Binding var order: [String]
    @Binding var draggingID: String?
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onDrag {
                    draggingID = appID
                    return NSItemProvider(object: appID as NSString)
                }
                .opacity(draggingID == appID ? 0.35 : 1)
                .onDrop(
                    of: [.text],
                    delegate: HomeReorderDropDelegate(
                        targetID: appID,
                        order: $order,
                        draggingID: $draggingID
                    )
                )
        } else {
            content
        }
    }
}

private struct HomeReorderDropDelegate: DropDelegate {
    let targetID: String
    @Binding var order: [String]
    @Binding var draggingID: String?

    func dropEntered(info: DropInfo) {
        guard let draggingID,
              draggingID != targetID,
              let from = order.firstIndex(of: draggingID),
              let to = order.firstIndex(of: targetID) else { return }

        RexHaptics.selection()
        withAnimation(RexMotion.standard) {
            // 往后移要 +1：`move` 的 toOffset 是「移除后」的下标。
            order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

// MARK: - 等距宫格

/// 每行固定 `maxPerRow` 个等宽槽位，图标在槽内居中、从左往右依次排。
/// 槽位不随实际数量变化，所以只有 2 个图标时也不会被拉到两端。超过 `maxPerRow` 自动换行。
private struct EvenIconRowLayout: Layout {
    let maxPerRow: Int
    let itemSize: CGFloat
    let rowSpacing: CGFloat
    let edgeInset: CGFloat

    private var perRow: Int {
        max(1, maxPerRow)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let rows = (subviews.count + perRow - 1) / perRow
        let height = CGFloat(rows) * itemSize + CGFloat(rows - 1) * rowSpacing
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }

        // 固定槽宽：整行按 maxPerRow 等分，最后一行不满也沿用同样的槽位。
        let slot = (bounds.width - edgeInset * 2) / CGFloat(perRow)
        var index = 0
        var y = bounds.minY

        while index < subviews.count {
            let count = min(perRow, subviews.count - index)

            for offset in 0..<count {
                let x = bounds.minX + edgeInset + slot * CGFloat(offset) + (slot - itemSize) / 2
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: itemSize, height: itemSize)
                )
                index += 1
            }

            y += itemSize + rowSpacing
        }
    }
}

/// 松手落在卡片空白处（没落到其它图标上）时清掉拖动状态，避免原位图标一直半透明。
private struct HomeDropResetDelegate: DropDelegate {
    @Binding var draggingID: String?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        draggingID == nil ? nil : DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}
