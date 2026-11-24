import SwiftUI
import UIKit

// MARK: - 设备头

/// 参考稿的「设备头」：徽章 + 连接方式在上，设备名在下，右侧一台设备图形。
///
/// 这一段刻意不套卡片：参考稿里它直接铺在页面背景上，让设备名成为首屏视觉焦点，
/// 第一张白卡留给下面的信息区。
struct HomeServerSummary: View {
    let isAdmin: Bool
    let isOffline: Bool
    let serverText: String
    let onOpen: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 第二行设备名：只比第一行的徽章信息大一档，用相对字号跟随 Dynamic Type。
    @ScaledMetric(relativeTo: .title3) private var nameSize: CGFloat = 20

    var body: some View {
        // 左右两块的顶边对齐：设备图形比左侧文字高，按底对齐会把徽章压到设备中段。
        HStack(alignment: .top, spacing: RexSpacing.md) {
            VStack(alignment: .leading, spacing: 10) {
                metaRow
                nameButton
            }

            Spacer(minLength: 0)

            // 无障碍字号下把整行让给设备名：图形固定 100pt 会把标题挤成两三个字一行。
            if !dynamicTypeSize.isAccessibilitySize {
                HomeDeviceArt()
            }
        }
    }

    private var metaRow: some View {
        HStack(spacing: RexSpacing.sm) {
            Text(isAdmin ? "管理员" : "成员")
                // 比右侧连接状态小一档：徽章是标签，不该和正文抢字重。
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(RexColor.secondaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay {
                    // 小圆角方形外框：`cardBorder` 在浅蓝背景上几乎看不见，
                    // 这里用更深一档的弱化文字色才立得住。
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(RexColor.tertiaryText.opacity(0.55), lineWidth: 1)
                }

            HStack(spacing: 4) {
                Image(systemName: connectionSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusColor)

                Text(connectionLabel)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    private var nameButton: some View {
        Button {
            RexHaptics.tap()
            onOpen()
        } label: {
            HStack(spacing: 6) {
                // 首屏唯一的强标题：字号与字重都往上顶一档，收一点字距，粗体才不显笨。
                Text("RexHub")
                    .font(.system(size: nameSize, weight: .heavy))
                    .tracking(-0.6)
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(RexColor.tertiaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("RexHub 服务器")
        .accessibilityHint("打开服务器设置")
    }

    private var statusColor: Color {
        isOffline ? RexColor.warning : RexColor.success
    }

    private var connectionSymbol: String {
        if isOffline { return "wifi.slash" }
        return isLocalNetwork ? "wifi" : "globe"
    }

    private var connectionLabel: String {
        if isOffline { return "离线" }
        return isLocalNetwork ? "局域网连接" : "公网连接"
    }

    private var isLocalNetwork: Bool {
        HomeServerAddress.isLocal(serverText)
    }
}

// MARK: - 地址解析

/// 服务端地址的两点展示需求：取主机名当标题、判断是局域网还是公网。
enum HomeServerAddress {
    static func host(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        if let range = text.range(of: "://") {
            text = String(text[range.upperBound...])
        }
        if let slash = text.firstIndex(of: "/") {
            text = String(text[..<slash])
        }
        if let colon = text.firstIndex(of: ":") {
            text = String(text[..<colon])
        }
        return text
    }

    static func isLocal(_ raw: String) -> Bool {
        let host = host(raw).lowercased()
        guard !host.isEmpty else { return true }
        if host == "localhost" || host.hasSuffix(".local") { return true }

        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }

        if parts[0] == 10 || parts[0] == 127 { return true }
        if parts[0] == 192, parts[1] == 168 { return true }
        if parts[0] == 172, (16...31).contains(parts[1]) { return true }
        return false
    }
}

// MARK: - 设备图形

/// 用几何形状拼一台 NAS，替代 `server.rack` 符号。
/// 参考稿的右侧是一台有体积感的设备，纯线条符号撑不起这一段的分量。
private struct HomeDeviceArt: View {
    private var bodyShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
    }

    /// 设备是唯一一处「写实」图形，颜色不跟语义 token 走，按深浅色各给一套：
    /// 浅色下是灰蓝机箱，深色下压到深灰，避免黑底上出现一块过亮的白方块。
    private static let bodyTop = adaptive(light: 0xB7C4D8, dark: 0x3D4959)
    private static let bodyBottom = adaptive(light: 0x7E8FA8, dark: 0x232B37)
    private static let panel = adaptive(light: 0xEFF5FD, dark: 0x2B3442)
    private static let tray = adaptive(light: 0xE7EEF9, dark: 0x39445A)
    private static let trayBorder = adaptive(light: 0xC7D3E4, dark: 0x4A5A73)
    private static let handle = adaptive(light: 0xA6B4C8, dark: 0x6C7C94)
    private static let idleLED = adaptive(light: 0xB9C6D8, dark: 0x55647B)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Ellipse()
                .fill(Color.black.opacity(0.16))
                .frame(width: 78, height: 10)
                .blur(radius: 5)
                .offset(y: 4)

            // 机箱：上亮下暗的灰蓝，跟参考稿的实体设备一致；浅色背景上才立得住。
            bodyShape
                .fill(
                    LinearGradient(
                        colors: [Self.bodyTop, Self.bodyBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    bodyShape.strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                }
                .overlay {
                    // 前面板：比机箱低一档的浅色面，四周留出机箱边框。
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Self.panel)
                        .padding(6)
                }
                .overlay {
                    trays
                }
                .frame(width: 100, height: 82)
                .shadow(color: Color.black.opacity(0.28), radius: 10, x: 0, y: 6)
        }
        // 高度只算机箱：底下那圈投影画在框外（SwiftUI 不裁切），
        // 否则框里会多出 10pt 空白，顶对齐后左侧文字反而比设备高出一截。
        .frame(width: 100, height: 82)
        .accessibilityHidden(true)
    }

    /// 前面板：四条硬盘托架，第一格亮一颗绿灯表示「在跑」。
    private var trays: some View {
        VStack(spacing: 4) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Self.tray)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Self.trayBorder, lineWidth: 0.6)
                    }
                    .overlay(alignment: .leading) {
                        Circle()
                            .fill(index == 0 ? Color(hex: 0x30D158) : Self.idleLED)
                            .frame(width: 4, height: 4)
                            .padding(.leading, 7)
                    }
                    .overlay(alignment: .trailing) {
                        Capsule(style: .continuous)
                            .fill(Self.handle.opacity(0.6))
                            .frame(width: 18, height: 3)
                            .padding(.trailing, 7)
                    }
                    .frame(height: 11)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
}
