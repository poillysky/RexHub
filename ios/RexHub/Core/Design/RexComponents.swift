import SwiftUI
import UIKit

// MARK: - 触觉反馈

/// 统一的触觉反馈入口：所有可点击的状态变化使用同一套强度，避免页面间手感不一致。
@MainActor
enum RexHaptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

// MARK: - 页面背景

/// 全应用共用的浅色玻璃拟态背景：在品牌底色上叠三处极淡光晕。
/// 颜色强度按深浅色模式自动收敛，既保留层次又不干扰正文阅读。
struct RexPageBackground: View {
    var accent: Color?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RexColor.background

            RadialGradient(
                colors: [RexColor.brandBlue.opacity(colorScheme == .dark ? 0.14 : 0.10), .clear],
                center: UnitPoint(x: 0.06, y: 0.00),
                startRadius: 0,
                endRadius: 440
            )

            RadialGradient(
                colors: [RexColor.brandBlueSoft.opacity(colorScheme == .dark ? 0.08 : 0.07), .clear],
                center: UnitPoint(x: 0.96, y: 0.34),
                startRadius: 0,
                endRadius: 360
            )

            RadialGradient(
                colors: [(accent ?? Color(hex: 0xA855F7)).opacity(colorScheme == .dark ? 0.06 : 0.05), .clear],
                center: UnitPoint(x: 0.18, y: 0.70),
                startRadius: 0,
                endRadius: 380
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - 卡片

extension View {
    /// 统一卡片样式：表面色 + 0.75pt 描边 + 浅色模式柔和投影。
    /// 深色模式不投影，改用描边区分层级，避免黑底上的阴影变成灰雾。
    func rexCard(
        cornerRadius: CGFloat = RexRadius.card,
        hasShadow: Bool = true
    ) -> some View {
        modifier(RexCardModifier(cornerRadius: cornerRadius, hasShadow: hasShadow))
    }
}

private struct RexCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let hasShadow: Bool

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .background(RexColor.surface, in: shape)
            .overlay {
                shape.strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
            }
            .shadow(
                color: hasShadow && colorScheme == .light
                    ? Color.black.opacity(0.045)
                    : .clear,
                radius: 14,
                y: 5
            )
    }
}

// MARK: - 分区标题

struct RexSectionHeader: View {
    let title: String
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: RexSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(RexFont.section)
                    .foregroundStyle(RexColor.secondaryText)

                if let detail {
                    Text(detail)
                        .font(RexFont.caption)
                        .foregroundStyle(RexColor.tertiaryText)
                }
            }

            Spacer(minLength: 0)

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(RexColor.brandBlue)
                        .frame(minWidth: RexLayout.minTouch, minHeight: 28, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(.horizontal, RexSpacing.xs)
    }
}

// MARK: - 提示

/// 行内说明文字：用于设置项下方的一句话解释，不加底色，保持页面轻量。
struct RexNote: View {
    enum Tone {
        case neutral
        case info
        case warning
        case error

        var tint: Color {
            switch self {
            case .neutral: return RexColor.secondaryText
            case .info: return RexColor.info
            case .warning: return RexColor.warning
            case .error: return RexColor.error
            }
        }

        var symbol: String {
            switch self {
            case .neutral: return "info.circle"
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }
    }

    let text: String
    var tone: Tone = .neutral
    var symbol: String?

    var body: some View {
        HStack(alignment: .top, spacing: RexSpacing.sm) {
            Image(systemName: symbol ?? tone.symbol)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(tone.tint)
                .frame(width: 16, alignment: .leading)

            Text(text)
                .font(RexFont.footnote)
                .foregroundStyle(RexColor.secondaryText)
                .multilineTextAlignment(.leading)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, RexSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 带底色的提示卡：用于失败、授权失效等需要被看见的状态。
struct RexInlineNotice: View {
    var title: String?
    let message: String
    var tone: RexNote.Tone = .warning
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: RexSpacing.md) {
            Image(systemName: tone.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tone.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(RexColor.primaryText)
                }

                Text(message)
                    .font(RexFont.footnote)
                    .foregroundStyle(RexColor.secondaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle, let action {
                    Button(action: action) {
                        Text(actionTitle)
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(tone.tint)
                            .frame(minHeight: 32, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(RexSpacing.lg)
        .background(
            tone.tint.opacity(0.09),
            in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                .strokeBorder(tone.tint.opacity(0.18), lineWidth: 0.75)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 状态视图

/// 统一的空状态 / 失败 / 加载卡片：图标、标题、说明与主操作保持固定层级。
struct RexStateCard: View {
    enum Tone {
        case neutral
        case brand
        case warning

        var tint: Color {
            switch self {
            case .neutral: return RexColor.secondaryText
            case .brand: return RexColor.brandBlue
            case .warning: return RexColor.warning
            }
        }
    }

    var symbol: String = "sparkles"
    let title: String
    var message: String?
    var tone: Tone = .neutral
    var isLoading: Bool = false
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: RexSpacing.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: RexRadius.iconTile, style: .continuous)
                    .fill(tone.tint.opacity(0.10))
                    .frame(width: 64, height: 64)

                if isLoading {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(tone.tint)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(tone.tint)
                        .symbolRenderingMode(.hierarchical)
                }
            }

            VStack(spacing: RexSpacing.xs) {
                Text(title)
                    .font(.system(.headline, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)
                    .multilineTextAlignment(.center)

                if let message {
                    Text(message)
                        .font(RexFont.footnote)
                        .foregroundStyle(RexColor.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(RexColor.onBrand)
                        .frame(maxWidth: .infinity)
                        .frame(height: RexLayout.minTouch)
                        .background(
                            RexColor.brandGradient,
                            in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                        )
                }
                .buttonStyle(PressableButtonStyle())
                .frame(maxWidth: 240)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RexSpacing.xxxl)
        .padding(.horizontal, RexSpacing.xl)
        .rexCard()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 骨架屏

/// 加载占位块：浅色模式用白色高光扫过，深色模式降低高光强度。
struct RexSkeleton: View {
    var width: CGFloat?
    var height: CGFloat = 14
    var cornerRadius: CGFloat = 7

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(RexColor.field)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [
                                .clear,
                                (colorScheme == .dark ? Color.white : Color.white).opacity(0.42),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.5)
                        .offset(x: phase * proxy.size.width * 1.5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                phase = -1
                withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
            .accessibilityHidden(true)
    }
}

/// 搜索结果骨架卡片：保持与真实结果卡片相同的结构，减少加载完成时的跳动。
struct RexSkeletonResultCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            RexSkeleton(height: 16, cornerRadius: 6)
            RexSkeleton(width: 180, height: 10)

            Rectangle()
                .fill(RexColor.divider.opacity(0.65))
                .frame(height: 1)
                .padding(.vertical, 2)

            HStack(spacing: RexSpacing.sm) {
                RexSkeleton(width: 26, height: 26, cornerRadius: 8)
                RexSkeleton(width: 92, height: 24, cornerRadius: 12)
                Spacer(minLength: 0)
                RexSkeleton(width: 48, height: 24, cornerRadius: 12)
                RexSkeleton(width: 48, height: 24, cornerRadius: 12)
            }
        }
        .padding(RexSpacing.md)
        .rexCard(cornerRadius: RexRadius.card)
        .accessibilityHidden(true)
    }
}

// MARK: - 浮层提示

struct RexToastBanner: View {
    let message: String
    var symbol: String = "checkmark.circle.fill"

    var body: some View {
        HStack(spacing: RexSpacing.sm) {
            Image(systemName: symbol)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))

            Text(message)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(minHeight: RexLayout.minTouch)
        .background(Color.black.opacity(0.86), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

extension View {
    /// 顶部 Toast：调用方只需维护 `String?`，显隐动画与无障碍朗读统一在这里处理。
    func rexToast(_ message: String?, alignment: Alignment = .top) -> some View {
        overlay(alignment: alignment) {
            if let message {
                RexToastBanner(message: message)
                    .padding(.horizontal, RexSpacing.xl)
                    .padding(.top, RexSpacing.sm)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .animation(RexMotion.quick, value: message)
    }
}

// MARK: - 徽标与按钮

struct RexBadge: View {
    let text: String
    var symbol: String?
    var tint: Color = RexColor.brandBlue
    var filled: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
            }

            Text(text)
                .font(RexFont.badge)
                .lineLimit(1)
        }
        .foregroundStyle(filled ? RexColor.onBrand : tint)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            (filled ? tint : tint.opacity(0.10)),
            in: Capsule(style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

struct RexPrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 50

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RexFont.button)
            .foregroundStyle(RexColor.onBrand)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RexColor.brandGradient,
                in: RoundedRectangle(cornerRadius: RexRadius.control + 2, style: .continuous)
            )
            .shadow(
                color: RexColor.brandBlue.opacity(configuration.isPressed ? 0.12 : 0.24),
                radius: 14,
                y: 6
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(RexMotion.quick, value: configuration.isPressed)
    }
}

struct RexSecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 50

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RexFont.button)
            .foregroundStyle(RexColor.primaryText)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RexColor.surface,
                in: RoundedRectangle(cornerRadius: RexRadius.control + 2, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: RexRadius.control + 2, style: .continuous)
                    .strokeBorder(RexColor.cardBorder, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .brightness(configuration.isPressed ? -0.03 : 0)
            .animation(RexMotion.quick, value: configuration.isPressed)
    }
}

/// 设置行 / 快捷入口的按下反馈：铺一档选中底色，替代无反馈的 `.plain`。
struct RexRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? RexColor.selection : Color.clear)
            .animation(RexMotion.quick, value: configuration.isPressed)
    }
}

#Preview("Design system") {
    VStack(spacing: RexSpacing.xl) {
        RexSectionHeader(title: "分组标题", detail: "补充说明", actionTitle: "管理", action: {})

        RexStateCard(
            symbol: "magnifyingglass",
            title: "没有找到相关资源",
            message: "换个关键词或切换其他来源试试",
            tone: .neutral,
            actionTitle: "返回"
        ) {}

        RexSkeletonResultCard()

        RexToastBanner(message: "链接已复制")
    }
    .padding(RexSpacing.xl)
    .background(RexPageBackground())
}
