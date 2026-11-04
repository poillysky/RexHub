import SwiftUI

struct RexLogoMark: View {
    var size: CGFloat = 96
    var cornerRadius: CGFloat? = nil
    var hasShadow: Bool = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.2237, style: .continuous)

        Image(RexThemeStore.shared.logoStyle.imageName)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    Color.primary.opacity(0.12),
                    lineWidth: max(0.8, size * 0.008)
                )
            )
            .shadow(
                color: hasShadow ? Color.black.opacity(0.10) : .clear,
                radius: size * 0.06,
                y: size * 0.03
            )
            .shadow(
                color: hasShadow ? RexColor.brandBlue.opacity(0.22) : .clear,
                radius: size * 0.14,
                y: size * 0.07
            )
            .accessibilityHidden(true)
    }
}

#Preview {
    VStack(spacing: 28) {
        RexLogoMark(size: 96)
        RexLogoMark(size: 56, hasShadow: false)
    }
    .padding(40)
    .background(RexColor.background)
}
