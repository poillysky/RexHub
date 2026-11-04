import AVFoundation
import SwiftUI
import UIKit

/// 全屏音乐播放器：封面、进度、快退快进、上一首/下一首与倍速。
/// 播放范围由「音乐播放器」设置决定：单曲只播当前文件，目录从选中歌曲开始顺序播完同目录音频。
struct MusicPlayerView: View {
    let item: PanItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.apiClient) private var apiClient

    @State private var activeItem: PanItem
    @State private var queue: [PanItem]
    @State private var player: AVPlayer?
    @State private var phase: Phase = .loading
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var scrubTarget: Double = 0
    @State private var artwork: UIImage?
    @State private var showsPlaylist = false
    @State private var timeToken: Any?
    @State private var endToken: NSObjectProtocol?

    @Bindable private var settings = MusicSettingsStore.shared

    private enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private enum SkipDirection {
        case backward
        case forward
    }

    init(item: PanItem, playlist: [PanItem] = []) {
        self.item = item

        let isFolder = MusicSettingsStore.shared.playlistMode == .folder
        var tracks = isFolder ? playlist : []
        tracks = tracks.filter { !$0.isDir && !$0.pickcode.isEmpty }
        if !tracks.contains(where: { $0.id == item.id }) {
            tracks = [item]
        }

        _activeItem = State(initialValue: item)
        _queue = State(initialValue: tracks)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                background

                VStack(spacing: 0) {
                    topBar

                    Spacer(minLength: RexSpacing.md)

                    cover(size: coverSize(in: proxy.size))

                    Spacer(minLength: RexSpacing.xl)

                    titleBlock

                    if case .failed(let message) = phase {
                        failure(message)
                    } else {
                        progressBlock
                            .padding(.top, RexSpacing.xl)

                        controls
                            .padding(.top, RexSpacing.lg)
                    }

                    Spacer(minLength: RexSpacing.lg)

                    footer
                }
                .padding(.horizontal, RexSpacing.xxl)
                .padding(.vertical, RexSpacing.lg)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task(id: activeItem.id) {
            await resolve()
        }
        .onDisappear(perform: teardown)
        .onChange(of: settings.playbackRate) { _, rate in
            if isPlaying {
                player?.rate = Float(rate)
            }
        }
        .sheet(isPresented: $showsPlaylist) {
            playlistSheet
        }
    }

    // MARK: - 外观

    @ViewBuilder
    private var background: some View {
        ZStack {
            Color.black

            if let artwork, settings.blurCover {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(1.25)
                    .blur(radius: 48)
                    .overlay(Color.black.opacity(0.55))
            } else {
                LinearGradient(
                    colors: [RexColor.brandBlue.opacity(0.45), .black, .black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(spacing: RexSpacing.md) {
            circleButton(systemImage: "chevron.down", label: "关闭") {
                dismiss()
            }

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                Text("正在播放")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.45))

                Text(Self.displayName(for: activeItem))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            circleButton(systemImage: "list.bullet", label: "播放列表") {
                showsPlaylist = true
            }
        }
    }

    private func circleButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            RexHaptics.tap()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.12), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 0.75))
                .frame(minWidth: RexLayout.minTouch, minHeight: RexLayout.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func cover(size: CGFloat) -> some View {
        Group {
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RexColor.brandGradient

                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.3, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 18)
    }

    private func coverSize(in size: CGSize) -> CGFloat {
        max(160, min(size.width - 96, size.height * 0.34, 300))
    }

    private var titleBlock: some View {
        VStack(spacing: 6) {
            Text(Self.displayName(for: activeItem))
                .font(.system(.title2, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(Self.metaText(for: activeItem))
                .font(RexFont.footnote)
                .foregroundStyle(.white.opacity(0.58))
        }
    }

    // MARK: - 进度

    private var progressBlock: some View {
        VStack(spacing: RexSpacing.sm) {
            Slider(
                value: progressBinding,
                in: 0...max(duration, 1),
                onEditingChanged: handleScrubbing
            )
            .tint(.white)
            .disabled(phase != .ready)

            HStack {
                Text(timeText(isScrubbing ? scrubTarget : currentTime))
                Spacer()
                Text(timeText(duration))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .monospacedDigit()
        }
    }

    private var progressBinding: Binding<Double> {
        Binding(
            get: { isScrubbing ? scrubTarget : currentTime },
            set: { scrubTarget = $0 }
        )
    }

    // MARK: - 控制

    private var controls: some View {
        HStack(spacing: 0) {
            skipButton(.backward, seconds: settings.rewindSeconds) {
                skip(by: -Double(settings.rewindSeconds))
            }

            Spacer(minLength: 0)

            controlButton(
                systemImage: "backward.end.fill",
                label: "上一首",
                isEnabled: previousItem != nil
            ) {
                playPrevious()
            }

            Spacer(minLength: 0)

            playButton

            Spacer(minLength: 0)

            controlButton(
                systemImage: "forward.end.fill",
                label: "下一首",
                isEnabled: nextItem != nil
            ) {
                playNext()
            }

            Spacer(minLength: 0)

            skipButton(.forward, seconds: settings.forwardSeconds) {
                skip(by: Double(settings.forwardSeconds))
            }
        }
    }

    private var playButton: some View {
        Button(action: togglePlay) {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 68, height: 68)

                if phase == .loading {
                    ProgressView()
                        .tint(.black)
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.black)
                        .offset(x: isPlaying ? 0 : 2)
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(phase != .ready)
        .accessibilityLabel(isPlaying ? "暂停" : "播放")
    }

    private func controlButton(
        systemImage: String,
        label: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(isEnabled ? 0.85 : 0.25))
                .frame(width: 44, height: 48)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!isEnabled || phase != .ready)
        .accessibilityLabel(label)
    }

    private func skipButton(
        _ direction: SkipDirection,
        seconds: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: direction == .backward ? "gobackward" : "goforward")
                    .font(.system(size: 22, weight: .medium))

                Text("\(seconds)")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.8))
            .frame(width: 44, height: 48)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(phase != .ready)
        .accessibilityLabel(direction == .backward ? "快退 \(seconds) 秒" : "快进 \(seconds) 秒")
    }

    private var footer: some View {
        HStack(spacing: RexSpacing.md) {
            Menu {
                ForEach(MusicSettingsStore.playbackRates, id: \.self) { rate in
                    Button {
                        settings.playbackRate = rate
                    } label: {
                        if settings.playbackRate == rate {
                            Label(PlayerSettingsStore.rateText(rate), systemImage: "checkmark")
                        } else {
                            Text(PlayerSettingsStore.rateText(rate))
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 13, weight: .medium))

                    Text("倍速 \(PlayerSettingsStore.rateText(settings.playbackRate))")
                        .font(.system(.footnote, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, RexSpacing.md)
                .frame(height: 36)
                .background(.white.opacity(0.10), in: Capsule(style: .continuous))
                .frame(minHeight: RexLayout.minTouch)
            }

            Spacer(minLength: 0)

            Text("\(settings.playlistMode.title) · \(queue.count) 首")
                .font(RexFont.caption)
                .foregroundStyle(.white.opacity(0.45))
                .contentTransition(.numericText())
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: RexSpacing.md) {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            Button {
                RexHaptics.tap()
                Task { await resolve() }
            } label: {
                Text("重试")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(RexColor.onBrand)
                    .frame(width: 128, height: RexLayout.minTouch)
                    .background(
                        RexColor.brandGradient,
                        in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                    )
            }
            .buttonStyle(PressableButtonStyle())
        }
        .padding(.top, RexSpacing.xl)
    }

    // MARK: - 播放列表

    private var playlistSheet: some View {
        NavigationStack {
            List {
                ForEach(queue) { track in
                    Button {
                        RexHaptics.selection()
                        activeItem = track
                        showsPlaylist = false
                    } label: {
                        HStack(spacing: RexSpacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.displayName(for: track))
                                    .font(.system(.body, weight: track.id == activeItem.id ? .semibold : .regular))
                                    .foregroundStyle(RexColor.primaryText)
                                    .lineLimit(1)

                                Text(Self.metaText(for: track))
                                    .font(RexFont.caption)
                                    .foregroundStyle(RexColor.secondaryText)
                            }

                            Spacer(minLength: RexSpacing.sm)

                            if track.id == activeItem.id {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(RexColor.brandBlue)
                            }
                        }
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RexRowButtonStyle())
                }
            }
            .listStyle(.plain)
            .navigationTitle("播放列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showsPlaylist = false }
                }
            }
        }
        .rexSheetStyle()
    }

    // MARK: - 解析与播放

    private func resolve() async {
        phase = .loading
        artwork = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        scrubTarget = 0
        teardown()

        guard let client = apiClient else {
            phase = .failed("登录状态已失效，请重新登录")
            return
        }
        guard !activeItem.pickcode.isEmpty else {
            phase = .failed("该文件缺少播放标识，无法播放")
            return
        }

        do {
            let info = try await client.panPlay(pickcode: activeItem.pickcode)
            guard !Task.isCancelled else { return }

            PlayerFacade.activateAudioSession()

            let newPlayer = PlayerFacade.makePlayer(for: info)
            // 视频的「起播静音」不应影响音乐播放。
            newPlayer.isMuted = false
            player = newPlayer
            installEndObserver(for: newPlayer)
            startTimeObserver(for: newPlayer)
            phase = .ready
            newPlayer.playImmediately(atRate: Float(settings.playbackRate))
            isPlaying = true

            await loadDuration(for: newPlayer)
            await loadArtwork(for: newPlayer)
        } catch let error as APIError {
            guard error != .cancelled else { return }
            phase = .failed(error.errorDescription ?? "获取播放地址失败，请重试")
        } catch {
            phase = .failed("获取播放地址失败，请重试")
        }
    }

    private func loadDuration(for player: AVPlayer) async {
        guard let asset = player.currentItem?.asset,
              let value = try? await asset.load(.duration) else { return }
        let seconds = value.seconds
        guard seconds.isFinite, seconds > 0 else { return }
        duration = seconds
    }

    /// 音频内嵌封面；没有封面时保留渐变占位。
    private func loadArtwork(for player: AVPlayer) async {
        guard let asset = player.currentItem?.asset,
              let metadata = try? await asset.load(.commonMetadata) else { return }

        let artworks = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: .commonIdentifierArtwork
        )
        guard let first = artworks.first,
              let data = try? await first.load(.dataValue),
              let image = UIImage(data: data) else { return }
        guard !Task.isCancelled else { return }
        artwork = image
    }

    private func startTimeObserver(for player: AVPlayer) {
        removeTimeObserver()

        timeToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            guard !isScrubbing else { return }

            let seconds = time.seconds
            guard seconds.isFinite else { return }
            currentTime = seconds

            if let itemDuration = player.currentItem?.duration.seconds,
               itemDuration.isFinite,
               itemDuration > 0 {
                duration = itemDuration
            }

            isPlaying = player.rate > 0
        }
    }

    private func removeTimeObserver() {
        if let player, let timeToken {
            player.removeTimeObserver(timeToken)
        }
        timeToken = nil
    }

    /// 播完自动下一首；已是最后一首时回到开头并暂停。
    private func installEndObserver(for player: AVPlayer) {
        removeEndObserver()
        guard let current = player.currentItem else { return }

        endToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: current,
            queue: .main
        ) { _ in
            isPlaying = false

            if let next = nextItem {
                activeItem = next
            } else {
                player.seek(to: .zero)
                currentTime = 0
            }
        }
    }

    private func removeEndObserver() {
        guard let endToken else { return }
        NotificationCenter.default.removeObserver(endToken)
        self.endToken = nil
    }

    private func togglePlay() {
        guard let player, phase == .ready else { return }

        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }

        if duration > 0, currentTime >= duration - 0.3 {
            seek(to: 0)
        }
        player.playImmediately(atRate: Float(settings.playbackRate))
        isPlaying = true
    }

    /// 点了上一首：播放超过 3 秒先回到开头，否则真正切上一首。
    private func playPrevious() {
        if currentTime > 3 {
            seek(to: 0)
            if phase == .ready {
                player?.playImmediately(atRate: Float(settings.playbackRate))
                isPlaying = true
            }
            return
        }

        guard let previous = previousItem else { return }
        activeItem = previous
    }

    private func playNext() {
        guard let next = nextItem else { return }
        activeItem = next
    }

    private func skip(by offset: Double) {
        guard phase == .ready else { return }
        seek(to: (isScrubbing ? scrubTarget : currentTime) + offset)
    }

    private func seek(to seconds: Double) {
        guard let player else { return }

        let target = min(max(seconds, 0), max(duration, 0))
        currentTime = target
        Task {
            await player.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
    }

    private func handleScrubbing(_ editing: Bool) {
        if editing {
            scrubTarget = currentTime
            isScrubbing = true
        } else {
            isScrubbing = false
            seek(to: scrubTarget)
        }
    }

    private func teardown() {
        removeTimeObserver()
        removeEndObserver()
        player?.pause()
        player = nil
    }

    // MARK: - 数据

    private var currentIndex: Int? {
        queue.firstIndex { $0.id == activeItem.id }
    }

    private var nextItem: PanItem? {
        guard let index = currentIndex, queue.indices.contains(index + 1) else { return nil }
        return queue[index + 1]
    }

    private var previousItem: PanItem? {
        guard let index = currentIndex, index > 0 else { return nil }
        return queue[index - 1]
    }

    private static func displayName(for item: PanItem) -> String {
        let name = (item.name as NSString).deletingPathExtension
        return name.isEmpty ? item.name : name
    }

    private static func metaText(for item: PanItem) -> String {
        var parts: [String] = []

        let ext = (item.name as NSString).pathExtension
        if !ext.isEmpty {
            parts.append(ext.uppercased())
        }
        if item.size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
        }

        return parts.joined(separator: " · ")
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }

        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remainder = total % 60

        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}
