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
                    .font(.system(.title, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(RexColor.primaryText)

                Text("连接你的数字生活")
                    .font(.system(.footnote, weight: .regular))
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

// MARK: - 连接页

/// 第 2 页：拿本地会话连一次服务器。连上之前一直停在这里；
/// 凭证失效由 `AppState` 直接切回登录页，连不上则停在本页给出重试与退出登录。
struct ConnectingView: View {
    let isFailed: Bool
    var onRetry: () -> Void
    var onSignOut: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        ZStack {
            background
            WaveField(intensity: 1.1)

            VStack(spacing: RexSpacing.xl) {
                RexLogoMark(size: verticalSizeClass == .compact ? 76 : 100)

                VStack(spacing: RexSpacing.md) {
                    Text("RexHub")
                        .font(.system(.title, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(RexColor.primaryText)

                    LoadingHint(text: isFailed ? "连接失败" : "正在连接...", isAnimating: !isFailed)
                }

                if isFailed {
                    retryButton
                        .padding(.top, RexSpacing.md)
                        .transition(.opacity)
                }
            }
            .offset(y: -RexSpacing.xl)

            VStack {
                Spacer()
                signOutButton
                    .padding(.bottom, RexSpacing.huge)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: isFailed)
    }

    private var retryButton: some View {
        Button {
            RexHaptics.tap()
            onRetry()
        } label: {
            Text("重试")
                .font(RexFont.button)
                .foregroundStyle(RexColor.onBrand)
                .frame(width: 132)
                .frame(minHeight: 48)
                .background(
                    RexColor.brandGradient,
                    in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                )
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var signOutButton: some View {
        Button {
            RexHaptics.tap()
            onSignOut()
        } label: {
            Text("退出登录")
                .font(RexFont.body)
                .foregroundStyle(RexColor.secondaryText)
                .rexTapTarget(minWidth: 120)
        }
        .buttonStyle(PressableButtonStyle())
    }

    /// 与品牌页完全同色，两页切换时只有加载态在变，背景不跳。
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

/// 加载态：六点水波 + 一行状态文案。
private struct LoadingHint: View {
    let text: String
    var isAnimating: Bool = true

    var body: some View {
        VStack(spacing: RexSpacing.md) {
            WaveLoadingDots(isAnimating: isAnimating)

            Text(text)
                .font(RexFont.footnote)
                .foregroundStyle(RexColor.tertiaryText)
                .tracking(0.6)
                .contentTransition(.opacity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// 六个点沿正弦波依次起伏：波峰从左向右推进，同时带轻微放大与提亮。
/// 开启「减弱动态效果」时静止成一条水平点列。
private struct WaveLoadingDots: View {
    var isAnimating: Bool = true
    var dotCount: Int = 6
    var dotSize: CGFloat = 6.5
    var color: Color = RexColor.brandBlue
    /// 相邻点的相位差（弧度）：越大波形越陡，推进感越强。
    var phaseStep: Double = 0.68
    /// 一个完整波形扫过的时间（秒）。
    var period: Double = 1.05

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isMoving: Bool { isAnimating && !reduceMotion }

    var body: some View {
        Group {
            if isMoving {
                // 用时间轴驱动，相位连续推进，避免 repeatForever 在两点之间来回弹跳的顿感。
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
                    dots(phase: phase(at: context.date), animated: true)
                }
            } else {
                dots(phase: 0, animated: false)
            }
        }
        .frame(height: dotSize * 3.4)
        .accessibilityHidden(true)
    }

    private func phase(at date: Date) -> Double {
        let elapsed = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        return elapsed / period * 2 * .pi
    }

    private func dots(phase: Double, animated: Bool) -> some View {
        HStack(spacing: dotSize * 1.15) {
            ForEach(0..<dotCount, id: \.self) { index in
                dot(index: index, phase: phase, animated: animated)
            }
        }
    }

    private func dot(index: Int, phase: Double, animated: Bool) -> some View {
        let wave = animated ? sin(phase - Double(index) * phaseStep) : 0
        let level = (wave + 1) / 2

        return Circle()
            .fill(color.opacity(0.26 + 0.64 * level))
            .frame(width: dotSize, height: dotSize)
            .scaleEffect(CGFloat(0.76 + 0.36 * level))
            .offset(y: -CGFloat(wave) * dotSize * 1.05)
            .shadow(color: color.opacity(0.30 * level), radius: dotSize * 0.55)
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
