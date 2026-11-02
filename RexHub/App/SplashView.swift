import SwiftUI

struct SplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false

    var body: some View {
        ZStack {
            background
            WaveField(intensity: 1.25)

            brandLockup
                .offset(y: -10)
        }
        .onAppear(perform: playIntro)
    }

    private func playIntro() {
        guard !appeared else { return }
        if reduceMotion {
            appeared = true
        } else {
            withAnimation(.spring(response: 0.62, dampingFraction: 0.86).delay(0.04)) {
                appeared = true
            }
        }
    }

    private var brandLockup: some View {
        VStack(spacing: RexSpacing.xl) {
            RexLogoMark(size: 100)
                .scaleEffect(appeared ? 1 : 0.94)
                .opacity(appeared ? 1 : 0)

            VStack(spacing: RexSpacing.sm) {
                Text("RexHub")
                    .font(.system(size: 31, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(RexColor.primaryText)

                Text("连接你的数字生活")
                    .font(.system(size: 13, weight: .regular))
                    .tracking(2.2)
                    .foregroundStyle(RexColor.secondaryText)
            }
            .offset(y: appeared ? 0 : 8)
            .opacity(appeared ? 1 : 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var background: some View {
        LinearGradient(
            stops: colorScheme == .dark
                ? [
                    .init(color: RexColor.surface, location: 0),
                    .init(color: RexColor.surface, location: 0.45),
                    .init(color: RexColor.brandBlue.opacity(0.10), location: 1)
                ]
                : [
                    .init(color: RexColor.surface, location: 0),
                    .init(color: RexColor.surface, location: 0.38),
                    .init(color: RexColor.lightBlue.opacity(0.55), location: 1)
                ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

// MARK: - 波浪

private struct WaveLayerSpec {
    var height: CGFloat
    var lift: CGFloat
    var cycles: CGFloat
    var amplitude: CGFloat
    var opacity: CGFloat
    var duration: Double
    var reverse: Bool
    var rimOpacity: CGFloat
}

struct WaveField: View {
    var intensity: CGFloat = 1
    var heightScale: CGFloat = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var layers: [WaveLayerSpec] {
        let depth: CGFloat = colorScheme == .dark ? 1.15 : 1
        let rim: CGFloat = colorScheme == .dark ? 0.10 : 0.40
        return [
            WaveLayerSpec(height: 620, lift: 0.548, cycles: 0.85, amplitude: 0.050,
                          opacity: 0.05 * depth * intensity, duration: 18, reverse: false, rimOpacity: 0),
            WaveLayerSpec(height: 540, lift: 0.472, cycles: 1.25, amplitude: 0.058,
                          opacity: 0.08 * depth * intensity, duration: 13, reverse: true, rimOpacity: 0),
            WaveLayerSpec(height: 460, lift: 0.391, cycles: 1.00, amplitude: 0.064,
                          opacity: 0.12 * depth * intensity, duration: 15, reverse: false, rimOpacity: rim * 0.6),
            WaveLayerSpec(height: 390, lift: 0.295, cycles: 1.55, amplitude: 0.072,
                          opacity: 0.17 * depth * intensity, duration: 10, reverse: true, rimOpacity: rim)
        ]
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ForEach(Array(layers.enumerated()), id: \.offset) { _, spec in
                AnimatedWave(spec: spec, height: spec.height * heightScale, animate: !reduceMotion)
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct AnimatedWave: View {
    let spec: WaveLayerSpec
    let height: CGFloat
    let animate: Bool

    @State private var drift: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let period = geo.size.width / max(spec.cycles, 0.2)
            let shape = WaveShape(lift: spec.lift, cycles: spec.cycles, amplitude: spec.amplitude)

            shape
                .fill(
                    LinearGradient(
                        colors: [
                            RexColor.brandBlue.opacity(spec.opacity * 0.45),
                            RexColor.brandBlue.opacity(spec.opacity)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    shape
                        .stroke(RexColor.onBrand.opacity(spec.rimOpacity), lineWidth: 0.8)
                }
                .offset(x: drift * period * (spec.reverse ? -1 : 1))
                .onAppear {
                    guard animate else { return }
                    withAnimation(.linear(duration: spec.duration).repeatForever(autoreverses: false)) {
                        drift = 1
                    }
                }
        }
        .frame(height: height)
    }
}

struct WaveShape: Shape {
    var lift: CGFloat
    var cycles: CGFloat = 1.2
    var amplitude: CGFloat = 0.06

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }

        let period = rect.width / max(cycles, 0.2)
        let base = rect.height * (1 - lift)
        let amp = rect.height * amplitude
        let bottom = rect.maxY + 140

        func waveY(_ x: CGFloat) -> CGFloat {
            let t = Double(x / period) * 2 * Double.pi
            return base + amp * CGFloat(sin(t) * 0.7 + sin(t * 2 + 0.9) * 0.3)
        }

        var x = rect.minX - period
        path.move(to: CGPoint(x: x, y: bottom))
        path.addLine(to: CGPoint(x: x, y: waveY(x)))

        let step: CGFloat = 6
        while x < rect.maxX + period {
            x += step
            path.addLine(to: CGPoint(x: x, y: waveY(x)))
        }
        path.addLine(to: CGPoint(x: x, y: bottom))
        path.closeSubpath()
        return path
    }
}

#Preview("Splash") {
    SplashView()
}

#Preview("Splash · Dark") {
    SplashView()
        .preferredColorScheme(.dark)
}
