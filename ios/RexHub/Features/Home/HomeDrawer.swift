import Observation
import SwiftUI

// MARK: - 抽屉目的地

/// 抽屉里的设置入口：抽屉只负责选，压栈交给一级容器。
enum HomeDrawerPage: Hashable, Identifiable {
    case account
    case services
    case aiModels
    case appearance
    case fileList
    case network
    case cache
    case videoPlayer
    case gestures
    case subtitles
    case music

    var id: Self { self }
}

// MARK: - 面板

/// 点开顶栏头像后滑出的侧边抽屉：身份信息在最上，下面按「一组一张白卡」排入口。
///
/// 行内只放文字不放图标——抽屉条目多而语义清楚，塞图标反而把首屏切得很碎。
struct HomeDrawer: View {
    let name: String
    let isAdmin: Bool
    /// 浮层铺满整屏，安全区不再自动参与排版，得由浮层显式传进来。
    let safeInsets: EdgeInsets
    let onSelect: (HomeDrawerPage) -> Void
    let onLogout: () -> Void

    private let theme = RexThemeStore.shared

    @State private var avatars = AvatarStore.shared
    @State private var isConfirmingLogout = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: RexSpacing.md) {
                profile
                    .padding(.top, 28 + safeInsets.top)
                    .padding(.bottom, RexSpacing.xs)

                card {
                    row("个人设置") { onSelect(.account) }
                }

                card {
                    row("外观", detail: theme.appearance.title) { onSelect(.appearance) }
                    row("文件列表") { onSelect(.fileList) }
                    row("缓存管理") { onSelect(.cache) }
                }

                card {
                    row("服务管理") { onSelect(.services) }
                }

                card {
                    row("视频播放器") { onSelect(.videoPlayer) }
                    row("手势") { onSelect(.gestures) }
                    row("字幕") { onSelect(.subtitles) }
                    row("音乐播放器") { onSelect(.music) }
                }

                card {
                    row("网络管理") { onSelect(.network) }
                    if isAdmin {
                        row("AI 模型管理") { onSelect(.aiModels) }
                    }
                }

                card {
                    Button {
                        RexHaptics.tap()
                        isConfirmingLogout = true
                    } label: {
                        HStack(spacing: RexSpacing.sm) {
                            Text("退出登录")
                                .font(RexFont.body)
                                .foregroundStyle(RexColor.error)

                            Spacer(minLength: RexSpacing.sm)

                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.system(.footnote, weight: .medium))
                                .foregroundStyle(RexColor.error)
                        }
                        .padding(.horizontal, RexSpacing.lg)
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(DrawerRowStyle())
                }
            }
            .padding(.horizontal, RexSpacing.lg)
            .padding(.bottom, RexSpacing.xxl + safeInsets.bottom)
        }
        .alert("退出登录", isPresented: $isConfirmingLogout) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) { onLogout() }
        } message: {
            Text("退出后需要重新登录才能继续使用。")
        }
    }

    // MARK: 头部

    private var profile: some View {
        HStack(spacing: RexSpacing.md) {
            RexAvatar(name: name, size: 48, selection: avatars.selection)

            VStack(alignment: .leading, spacing: 3) {
                Text(name.isEmpty ? "未登录" : name)
                    .font(RexFont.title3)
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)

                Text(isAdmin ? "管理员" : "成员")
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.secondaryText)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: 组件

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .clipShape(RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                .fill(RexColor.surface)
        }
    }

    private func row(
        _ title: String,
        detail: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            RexHaptics.tap()
            action()
        } label: {
            HStack(spacing: RexSpacing.sm) {
                Text(title)
                    .font(RexFont.body)
                    .foregroundStyle(RexColor.primaryText)

                Spacer(minLength: RexSpacing.sm)

                if let detail {
                    Text(detail)
                        .font(RexFont.caption)
                        .foregroundStyle(RexColor.tertiaryText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, RexSpacing.lg)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(DrawerRowStyle())
    }
}

/// 抽屉行按压：只加一层浅底，不做缩放——整行很宽，缩放会让卡片边框抖。
private struct DrawerRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? RexColor.selection : Color.clear)
    }
}

// MARK: - 浮层

/// 抽屉的开合进度与手势位移，面板滑出与遮罩淡入淡出全部读它。
///
/// 两层共用一条曲线，观感才是「一个东西被推出来」；各动各的必然看着不连续。
@MainActor
@Observable
final class DrawerMotion {
    /// 0 = 完全关闭，1 = 完全展开。
    var progress: CGFloat = 0
    /// 手势横向拖拽叠加的位移，恒 ≤ 0。
    var drag: CGFloat = 0
}

/// 抽屉浮层：遮罩 + 左侧面板。
///
/// 必须挂在一级容器上：挂在页面里的话，标签栏由 TabView 绘制，抽屉盖不住它，
/// 底部会露出一条没遮住的 Tab。
///
/// 浮层常驻，开合用 `progress` 一个值驱动，不靠插入/移除视图做转场：
/// 这样不会有「插入当帧还没排版就开始动画」的问题，拖拽、滑出、关闭
/// 也永远走同一条曲线，中途松手不会冒出第二段动画。
struct HomeDrawerOverlay: View {
    let motion: DrawerMotion
    let name: String
    let isAdmin: Bool
    let onSelect: (HomeDrawerPage) -> Void
    let onLogout: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 收起时整层不参与命中测试，也不暴露给 VoiceOver。
    private var isOpen: Bool { motion.progress > 0.001 }

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width * 0.84, 380)

            ZStack(alignment: .topLeading) {
                Color.black
                    .opacity(scrimOpacity(width: width))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                    .accessibilityHidden(true)

                panel(width: width, safeInsets: proxy.safeAreaInsets)
                    .offset(x: panelOffset(width: width))
            }
        }
        .allowsHitTesting(isOpen)
        .accessibilityHidden(!isOpen)
        .accessibilityAddTraits(.isModal)
        // VoiceOver 双指 Z 手势（返回）：抽屉是模态层，必须能不用触摸拖拽关掉。
        .accessibilityAction(.escape) { close() }
    }

    /// 面板位置：关闭时整块在屏幕左外，展开时贴住左缘；拖拽只在这之上叠加。
    private func panelOffset(width: CGFloat) -> CGFloat {
        -(1 - motion.progress) * width + motion.drag
    }

    /// 遮罩强度跟着面板走：面板拉走多少，压暗就退多少，两层才像同一个物体。
    private func scrimOpacity(width: CGFloat) -> Double {
        guard width > 0 else { return 0.30 }
        let remaining = min(1, max(0, 1 + motion.drag / width))
        return 0.30 * Double(motion.progress * remaining)
    }

    private func panel(width: CGFloat, safeInsets: EdgeInsets) -> some View {
        HomeDrawer(
            name: name,
            isAdmin: isAdmin,
            safeInsets: safeInsets,
            onSelect: { page in
                // 面板先滑走再跳页：否则目标页会和面板同时出现，观感像被抽了背景。
                close { onSelect(page) }
            },
            onLogout: onLogout
        )
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background {
            // 抽屉自带跟首页同一套底色与顶部品牌蓝渐变，滑出时才不像另一套界面。
            ZStack {
                Rectangle().fill(RexColor.background)
                HomeBackdropGlow()
            }
            .ignoresSafeArea()
        }
        .simultaneousGesture(dragToClose(width: width))
    }

    private func dragToClose(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                // 只接横向拖动：竖向留给抽屉内的滚动，否则列表会被手势吃掉。
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                motion.drag = min(0, value.translation.width)
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    settleBack()
                    return
                }
                // 甩得够快也算关闭：只看位移距离的话，快速一甩会觉得没反应。
                let flicked = value.predictedEndTranslation.width < -width * 0.55
                let draggedFar = value.translation.width < -width * 0.22
                if flicked || draggedFar {
                    close()
                } else {
                    settleBack()
                }
            }
    }

    /// 松手回弹：比进出场快一档，手感像橡皮筋回到原位，而不是重播一遍开场动画。
    private func settleBack() {
        withAnimation(motionAnimation(RexMotion.standard)) {
            motion.drag = 0
        }
    }

    private func motionAnimation(_ base: Animation) -> Animation? {
        reduceMotion ? nil : base
    }

    /// 关闭抽屉：从当前位置（含手指拖到的位置）继续滑出，动画结束再跳页。
    private func close(then completion: (() -> Void)? = nil) {
        withAnimation(motionAnimation(RexMotion.spring)) {
            motion.progress = 0
            motion.drag = 0
        } completion: {
            completion?()
        }
    }
}
