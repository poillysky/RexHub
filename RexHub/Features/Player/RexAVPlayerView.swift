import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// AVPlayer 自建播放层：`AVPlayerLayer` 负责画面，手势与控制条由 SwiftUI 提供。
/// 系统 `VideoPlayer` 无法接管手势，AV 内核改走这里，手势绑定来自「手势」设置页。
struct RexAVPlayerView: View {
    let player: AVPlayer
    let title: String
    let onClose: () -> Void

    @State private var controlsVisible = true
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var scrubTarget: Double = 0
    @State private var hud: HUD?
    @State private var isBoosting = false
    @State private var drag = DragState()
    @State private var hideTask: Task<Void, Never>?
    @State private var timeToken: Any?
    @State private var endToken: NSObjectProtocol?
    @State private var showsSubtitlePanel = false

    @Bindable private var settings = PlayerSettingsStore.shared
    private let gestures = GestureSettingsStore.shared

    private struct HUD: Equatable {
        var icon: String
        var text: String
        var progress: Double?
    }

    private struct DragState {
        var mode: DragMode = .none
        var startValue: Double = 0
    }

    private enum DragMode {
        case none
        case seek
        case brightness
        case volume
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RexAVPlayerLayer(player: player)

                gestureLayer(size: proxy.size)

                if let hud {
                    hudView(hud)
                }

                controls
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.black)
        .ignoresSafeArea()
        .onAppear(perform: restoreAndObserve)
        .onDisappear(perform: persistAndTeardown)
    }

    // MARK: - 手势

    private func gestureLayer(size: CGSize) -> some View {
        let doubleTap = SpatialTapGesture(count: 2)
            .onEnded { value in
                handleDoubleTap(at: value.location, size: size)
            }

        let singleTap = SpatialTapGesture(count: 1)
            .onEnded { _ in handleSingleTap() }

        return Color.clear
            .contentShape(Rectangle())
            .gesture(doubleTap.exclusively(before: singleTap))
            .onLongPressGesture(
                minimumDuration: 0.5,
                maximumDistance: 20,
                perform: {},
                onPressingChanged: handleLongPress
            )
            .simultaneousGesture(dragGesture(size: size))
    }

    private func handleSingleTap() {
        // 控制条隐藏时优先唤出，避免单手势改成其他动作后无法再打开菜单。
        guard controlsVisible else {
            showControls()
            return
        }
        perform(gestures.singleTap)
    }

    private func handleDoubleTap(at location: CGPoint, size: CGSize) {
        let action: GestureAction
        if location.x < size.width * 0.25 {
            action = gestures.doubleTapLeft
        } else if location.x > size.width * 0.75 {
            action = gestures.doubleTapRight
        } else {
            action = gestures.doubleTapCenter
        }
        perform(action)
    }

    /// 点击类动作；亮度、音量与拖动查找需要连续手势，绑到点击上不执行。
    private func perform(_ action: GestureAction) {
        switch action {
        case .none, .brightness, .volume, .seek:
            break
        case .toggleControls:
            toggleControls()
        case .playPause:
            togglePlay()
        case .rewind:
            seek(by: -10)
        case .forward:
            seek(by: 10)
        case .speedUp:
            toggleBoost()
        }
    }

    private func handleLongPress(_ pressing: Bool) {
        guard gestures.longPress == .speedUp else { return }

        if pressing {
            guard !isBoosting, drag.mode == .none, player.rate > 0 else { return }
            isBoosting = true
            player.rate = 2
            hud = HUD(icon: "forward.fill", text: "2x 倍速", progress: nil)
        } else if isBoosting {
            isBoosting = false
            player.rate = Float(settings.playbackRate)
            hud = nil
            scheduleAutoHide()
        }
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isBoosting else { return }

                if drag.mode == .none {
                    if abs(value.translation.width) > abs(value.translation.height) {
                        drag.mode = dragMode(for: gestures.horizontalDrag)
                        drag.startValue = currentTime
                        if drag.mode == .seek {
                            isScrubbing = true
                            scrubTarget = currentTime
                            cancelAutoHide()
                        }
                    } else if value.startLocation.x < size.width / 2 {
                        drag.mode = dragMode(for: gestures.leftVerticalDrag)
                        drag.startValue = Double(UIScreen.main.brightness)
                    } else {
                        drag.mode = dragMode(for: gestures.rightVerticalDrag)
                        drag.startValue = Double(SystemVolume.current)
                    }
                }

                switch drag.mode {
                case .none:
                    break
                case .seek:
                    let span = duration > 0 ? min(duration, 180) : 120
                    let delta = Double(value.translation.width) / Double(max(size.width, 1)) * span
                    scrubTarget = clamp(drag.startValue + delta, upper: duration)
                    hud = HUD(
                        icon: delta >= 0 ? "goforward" : "gobackward",
                        text: "\(timeText(scrubTarget)) / \(timeText(duration))",
                        progress: duration > 0 ? scrubTarget / duration : nil
                    )
                case .brightness:
                    let next = clamp(
                        drag.startValue - Double(value.translation.height) / Double(max(size.height, 1)) * 1.6,
                        upper: 1
                    )
                    UIScreen.main.brightness = CGFloat(next)
                    hud = HUD(icon: "sun.max.fill", text: "亮度 \(Int(next * 100))%", progress: next)
                case .volume:
                    let next = clamp(
                        drag.startValue - Double(value.translation.height) / Double(max(size.height, 1)) * 1.6,
                        upper: 1
                    )
                    SystemVolume.set(Float(next))
                    hud = HUD(icon: "speaker.wave.2.fill", text: "音量 \(Int(next * 100))%", progress: next)
                }

                if drag.mode != .none {
                    cancelAutoHide()
                }
            }
            .onEnded { _ in
                if drag.mode == .seek {
                    player.seek(to: CMTime(seconds: scrubTarget, preferredTimescale: 600))
                    currentTime = scrubTarget
                    isScrubbing = false
                }
                drag = DragState()
                hud = nil
                scheduleAutoHide()
            }
    }

    private func dragMode(for action: GestureAction) -> DragMode {
        switch action {
        case .seek: .seek
        case .brightness: .brightness
        case .volume: .volume
        default: .none
        }
    }

    // MARK: - 播放控制

    private func togglePlay() {
        if player.rate > 0 {
            player.pause()
            isPlaying = false
            showControls()
        } else {
            player.playImmediately(atRate: Float(settings.playbackRate))
            isPlaying = true
            scheduleAutoHide()
        }
    }

    /// 点击类「倍速」：在 1x 与 2x 之间切换，与长按的临时倍速区分。
    private func toggleBoost() {
        guard player.rate > 0 else { return }
        let target: Float = player.rate > 1.01 ? Float(settings.playbackRate) : 2
        player.rate = target
        hud = HUD(icon: "forward.fill", text: target > 1 ? "2x 倍速" : "恢复倍速", progress: nil)
        scheduleAutoHide()
    }

    private func seek(by delta: Double) {
        let target = clamp(currentTime + delta, upper: duration)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        currentTime = target
        hud = HUD(
            icon: delta >= 0 ? "goforward" : "gobackward",
            text: "\(delta >= 0 ? "+" : "-")\(Int(abs(delta))) 秒",
            progress: duration > 0 ? target / duration : nil
        )
        scheduleAutoHide()
    }

    private func toggleControls() {
        if controlsVisible {
            hideControls()
        } else {
            showControls()
        }
    }

    private func showControls() {
        controlsVisible = true
        scheduleAutoHide()
    }

    private func hideControls() {
        hideTask?.cancel()
        showsSubtitlePanel = false
        controlsVisible = false
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard isPlaying, !isScrubbing, !showsSubtitlePanel else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, !isScrubbing else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                controlsVisible = false
            }
        }
    }

    private func cancelAutoHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    // MARK: - 控制条

    private var controls: some View {
        VStack(spacing: 0) {
            topControls
            Spacer(minLength: 0)

            if showsSubtitlePanel {
                subtitlePanel
                    .padding(.horizontal, RexSpacing.lg)
                    .padding(.bottom, RexSpacing.md)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            bottomControls
        }
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
        .animation(.easeOut(duration: 0.2), value: controlsVisible)
    }

    private var topControls: some View {
        HStack(spacing: RexSpacing.md) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RexColor.onMedia)
                    .frame(width: 36, height: 36)
                    .background(RexColor.mediaBackground.opacity(0.45), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .frame(width: 44, height: 44)
            .accessibilityLabel("关闭播放")

            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(RexColor.onMedia)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            Button(action: toggleSubtitlePanel) {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RexColor.onMedia)
                    .frame(width: 36, height: 36)
                    .background(
                        RexColor.mediaBackground.opacity(showsSubtitlePanel ? 0.85 : 0.45),
                        in: Circle()
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .frame(width: 44, height: 44)
            .accessibilityLabel("字幕设置")
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.top, RexSpacing.sm)
        .padding(.bottom, RexSpacing.xl)
        .background {
            LinearGradient(
                colors: [.black.opacity(0.55), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        }
    }

    private var bottomControls: some View {
        HStack(spacing: RexSpacing.sm) {
            Button(action: togglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(RexColor.onMedia)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "暂停" : "播放")

            Text(timeText(isScrubbing ? scrubTarget : currentTime))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(RexColor.onMedia.opacity(0.85))

            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubTarget : currentTime },
                    set: { scrubTarget = $0 }
                ),
                in: 0...max(duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        isScrubbing = true
                        scrubTarget = currentTime
                        cancelAutoHide()
                    } else {
                        isScrubbing = false
                        player.seek(to: CMTime(seconds: scrubTarget, preferredTimescale: 600))
                        currentTime = scrubTarget
                        scheduleAutoHide()
                    }
                }
            )
            .tint(RexColor.onMedia)

            Text(timeText(duration))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(RexColor.onMedia.opacity(0.85))
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.top, RexSpacing.xl)
        .padding(.bottom, RexSpacing.sm)
        .background {
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        }
    }

    /// 字幕调节面板：字号、延迟、背景只在这里临时调整，设置页只保留偏好项。
    private var subtitlePanel: some View {
        VStack(alignment: .leading, spacing: RexSpacing.md) {
            HStack {
                Text("字幕调节")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RexColor.onMedia)

                Spacer(minLength: 0)

                Button("完成", action: closeSubtitlePanel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(RexColor.onMedia.opacity(0.8))
            }

            HStack(spacing: RexSpacing.sm) {
                Text("字号")
                    .font(.system(size: 13))
                    .foregroundStyle(RexColor.onMedia.opacity(0.75))
                    .frame(width: 40, alignment: .leading)

                ForEach(SubtitleSize.allCases) { size in
                    Button {
                        settings.subtitleSize = size
                    } label: {
                        Text(size.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(
                                settings.subtitleSize == size
                                    ? RexColor.mediaBackground
                                    : RexColor.onMedia
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(
                                settings.subtitleSize == size
                                    ? RexColor.onMedia
                                    : Color.white.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: RexSpacing.sm) {
                Text("延迟")
                    .font(.system(size: 13))
                    .foregroundStyle(RexColor.onMedia.opacity(0.75))
                    .frame(width: 40, alignment: .leading)

                Spacer(minLength: 0)

                Button {
                    adjustSubtitleDelay(-0.5)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(RexColor.onMedia)
                        .frame(width: 36, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("字幕提前")

                Text(PlayerSettingsStore.delayText(settings.subtitleDelay))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(RexColor.onMedia)
                    .frame(minWidth: 62)

                Button {
                    adjustSubtitleDelay(0.5)
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(RexColor.onMedia)
                        .frame(width: 36, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("字幕延后")
            }

            Toggle(isOn: $settings.subtitleBackground) {
                Text("字幕背景")
                    .font(.system(size: 13))
                    .foregroundStyle(RexColor.onMedia.opacity(0.85))
            }
            .tint(RexColor.brandBlue)
        }
        .padding(RexSpacing.lg)
        .background(
            .black.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func toggleSubtitlePanel() {
        withAnimation(.easeOut(duration: 0.2)) {
            showsSubtitlePanel.toggle()
        }
        if showsSubtitlePanel {
            cancelAutoHide()
        } else {
            scheduleAutoHide()
        }
    }

    private func closeSubtitlePanel() {
        withAnimation(.easeOut(duration: 0.2)) {
            showsSubtitlePanel = false
        }
        scheduleAutoHide()
    }

    /// 与设置页档位一致，限制在 ±3 秒内，步进 0.5 秒。
    private func adjustSubtitleDelay(_ delta: Double) {
        let next = min(max(settings.subtitleDelay + delta, -3), 3)
        settings.subtitleDelay = (next * 10).rounded() / 10
    }

    private func hudView(_ hud: HUD) -> some View {
        VStack(spacing: RexSpacing.sm) {
            Image(systemName: hud.icon)
                .font(.system(size: 22, weight: .semibold))

            Text(hud.text)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()

            if let progress = hud.progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.25))

                        Capsule()
                            .fill(.white)
                            .frame(width: max(2, proxy.size.width * progress))
                    }
                }
                .frame(width: 120, height: 4)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .allowsHitTesting(false)
    }

    // MARK: - 观测与记忆

    private func restoreAndObserve() {
        if settings.rememberBrightness {
            UIScreen.main.brightness = CGFloat(settings.lastBrightness)
        }
        if settings.rememberVolume {
            SystemVolume.set(Float(settings.lastVolume))
        }

        isPlaying = player.rate > 0
        let itemDuration = player.currentItem?.duration.seconds ?? 0
        if itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }

        timeToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            let seconds = time.seconds
            if seconds.isFinite, !isScrubbing {
                currentTime = seconds
            }
            let total = player.currentItem?.duration.seconds ?? 0
            if total.isFinite, total > 0 {
                duration = total
            }
            isPlaying = player.rate > 0
        }

        endToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            isPlaying = false
            controlsVisible = true
        }

        scheduleAutoHide()
    }

    private func persistAndTeardown() {
        hideTask?.cancel()
        hideTask = nil

        if let timeToken {
            player.removeTimeObserver(timeToken)
        }
        timeToken = nil

        if let endToken {
            NotificationCenter.default.removeObserver(endToken)
        }
        endToken = nil

        if settings.rememberBrightness {
            settings.lastBrightness = Double(UIScreen.main.brightness)
        }
        if settings.rememberVolume {
            settings.lastVolume = Double(SystemVolume.current)
        }
    }

    // MARK: - 工具

    private func clamp(_ value: Double, upper: Double) -> Double {
        min(max(value, 0), max(upper, 0))
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

// MARK: - AVPlayerLayer 容器

private struct RexAVPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer {
            // layerClass 已固定为 AVPlayerLayer，这里不可能失败。
            layer as! AVPlayerLayer
        }
    }
}

// MARK: - 系统音量

/// 通过隐藏的 `MPVolumeView` 调节系统输出音量，App 不额外保存音量值。
@MainActor
private enum SystemVolume {
    private static var slider: UISlider?

    static var current: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    static func set(_ value: Float) {
        guard let slider = resolveSlider() else { return }
        slider.value = min(max(value, 0), 1)
        slider.sendActions(for: .touchUpInside)
    }

    private static func resolveSlider() -> UISlider? {
        if let slider {
            return slider
        }

        let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else { return nil }

        window.addSubview(view)
        let found = view.subviews.compactMap { $0 as? UISlider }.first
        slider = found
        return found
    }
}
