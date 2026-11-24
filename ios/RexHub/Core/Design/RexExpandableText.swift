import SwiftUI

/// 长文本默认折叠若干行，超出时提供「展开 / 收起」。
/// 影视详情、片商影片详情共用同一套排版，保证两处正文视觉一致。
struct RexExpandableText: View {
    let text: String
    /// 折叠时显示的行数。
    var collapsedLines: Int = 5

    @State private var isExpanded = false
    @State private var isTruncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(RexColor.primaryText.opacity(0.84))
                .lineSpacing(4)
                .lineLimit(isExpanded ? nil : collapsedLines)
                .fixedSize(horizontal: false, vertical: true)
                .background(alignment: .topLeading) {
                    // 用不限行数的完整高度对比折叠后的高度，判断是否被截断。
                    Text(text)
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .background(heightProbe(id: "full"))
                }
                .background(heightProbe(id: "visible"))
                .onPreferenceChange(RexOverviewHeightKey.self) { heights in
                    guard !isExpanded,
                          let full = heights["full"],
                          let visible = heights["visible"] else { return }
                    if full > visible + 1 { isTruncated = true }
                }

            if isTruncated {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "收起" : "展开")

                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RexColor.brandBlue)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func heightProbe(id: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: RexOverviewHeightKey.self,
                value: [id: proxy.size.height]
            )
        }
    }
}

private struct RexOverviewHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}
