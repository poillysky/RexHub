import Darwin
import Photos
import SwiftUI
import UIKit

/// 统一播放控制层：横竖两套布局共用同一份控件，AVPlayer 与 KSPlayer 都走这里。
/// 顶部是标题与工具行，底部依次为「参数 + 圆形工具」「时间 + 进度 + 时间」「锁定 + 传输控制 + 列表」。
struct RexPlayerChrome: View {
    let title: String
    /// AV 内核加载的外部字幕；KS 内嵌字幕由内核自己渲染。
    let subtitleText: String
    /// 当前文件夹的视频列表，播放列表弹窗按这个顺序展示。
    let playlist: [PanItem]
    /// 当前正在播放的视频 id，用于在播放列表里打勾。
    let currentItemID: String
    let onClose: () -> Void
    let onSelect: (PanItem) -> Void
    let engine: any RexPlaybackEngine

    @State private var controlsVisible = true
    @State private var showsMore = false
    /// 播放列表弹窗：展示当前文件夹里的视频并支持点选切换。
    @State private var showsPlaylist = false
    @State private var isScrubbing = false
    @State private var scrubTarget: Double = 0
    @State private var hud: HUD?
    @State private var isBoosting = false
    /// 长按倍速的方向：右半屏快进、左半屏快退。
    @State private var boostDirection: BoostDirection = .forward
    @State private var boostHUDTask: Task<Void, Never>?
    /// 实时网速（字节/秒），显示在左上角关闭按钮上方。
    @State private var networkSpeed: Double = 0
    @State private var networkSpeedTask: Task<Void, Never>?
    @State private var isLocked = false
    @State private var isCapturing = false
    @State private var sleepMinutes = 0
    /// 倍速选择使用与其他面板一致的浮层卡片。
    @State private var showsRateDialog = false
    /// 音频设置弹窗：音轨与音频相关偏好。
    @State private var showsAudioSheet = false
    /// 字幕设置弹窗：开关、内嵌字幕、外观与同步。
    @State private var showsSubtitleSheet = false
    /// 二级设置页的推进栈：弹窗首屏只留选择项，具体设置统一推进到这些页面。
    @State private var pageStack: [PlayerPage] = []
    /// 各弹窗卡片的实测高度：横屏据此把卡片底边对齐按钮底边。
    @State private var popoverHeights: [PopoverPanel: CGFloat] = [:]
    @State private var drag = DragState()
    @State private var hideTask: Task<Void, Never>?
    @State private var hudTask: Task<Void, Never>?
    @State private var sleepTask: Task<Void, Never>?
    /// 双击判定用的上一次点击时间与位置。
    @State private var lastTapAt: Date?
    @State private var lastTapPoint: CGPoint = .zero
    /// 单击延迟派发，避免与双击抢同一次触摸。
    @State private var pendingSingleTap: Task<Void, Never>?
    /// 长按计时的临时倍速任务。
    @State private var boostTask: Task<Void, Never>?

    @Environment(\.verticalSizeClass) private var verticalSizeClass

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

    private enum BoostDirection {
        case forward
        case rewind
    }

    /// 二级设置页：每个页面只负责一件事，避免在弹窗里继续叠菜单。
    private enum PlayerPage: Hashable {
        case audioSettings
        case subtitleStyle
        case subtitleSize
        case playbackEngine
        case kernel
        case decodeMode
        case resolution
        case playOrder
        case introOutro
        case playbackControl
        case sleepTimer
        case aspectMode
        case screenAndBackground

        var title: String {
            switch self {
            case .audioSettings: "音频设置"
            case .subtitleStyle: "字幕样式"
            case .subtitleSize: "字幕字号"
            case .playbackEngine: "解码与画质"
            case .kernel: "播放内核"
            case .decodeMode: "解码方式"
            case .resolution: "起播清晰度"
            case .playOrder: "播放顺序"
            case .introOutro: "片头片尾"
            case .playbackControl: "播放控制"
            case .sleepTimer: "定时关闭"
            case .aspectMode: "画面模式"
            case .screenAndBackground: "屏幕与后台"
            }
        }
    }

    /// 左侧展开的弹窗：各自记住卡片高度，定位时互不影响。
    private enum PopoverPanel: Hashable {
        case audio
        case subtitle
        case more
        case playlist
    }

    private var state: RexPlayerEngineState { engine.state }

    private var displayTime: Double {
        isScrubbing ? scrubTarget : state.currentTime
    }

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width > proxy.size.height

            ZStack {
                gestureLayer(size: proxy.size)

                if !subtitleText.isEmpty {
                    subtitleView(landscape: landscape)
                }

                controls(landscape: landscape)

                if !isLocked, state.isBuffering {
                    bufferingIndicator
                }

                if let hud {
                    hudView(hud)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: prepare)
        .onDisappear(perform: persist)
        .onChange(of: settings.subtitleDelay) { _, value in
            engine.setSubtitleDelay(value)
        }
        .onChange(of: state.isPlaying) { _, playing in
            // 长按快退会临时暂停，这段暂停不该把控制条弹出来。
            guard !isBoosting else { return }
            // 起播后重新开始倒计时；暂停或播完时保持控制条可见。
            if playing {
                scheduleAutoHide()
            } else {
                cancelAutoHide()
                if !state.isBuffering {
                    withAnimation(.easeOut(duration: 0.2)) {
                        controlsVisible = true
                    }
                }
            }
        }
        .onChange(of: showsAudioSheet) { _, shown in
            if !shown { pageStack.removeAll(); scheduleAutoHide() }
        }
        .onChange(of: showsSubtitleSheet) { _, shown in
            if !shown { pageStack.removeAll(); scheduleAutoHide() }
        }
        .onChange(of: showsMore) { _, shown in
            if !shown { pageStack.removeAll(); scheduleAutoHide() }
        }
        .onChange(of: showsPlaylist) { _, shown in
            if !shown { scheduleAutoHide() }
        }
        .onChange(of: showsRateDialog) { _, shown in
            // 倍速浮层关掉后再开始控制条的隐藏倒计时。
            if !shown { scheduleAutoHide() }
        }
    }

    // MARK: - 弹窗卡片

    /// 播放页统一弹窗：系统 popover 承载的白色圆角浮层卡片，行式布局贴合参考图。
    private struct RexPopoverCard<Content: View>: View {
        let maxHeight: CGFloat
        /// 回传卡片最终高度：横屏据此把卡片底边对准按钮底边。
        var onHeightChange: (CGFloat) -> Void = { _ in }
        @ViewBuilder var content: Content

        @State private var height: CGFloat = 0

        private var resolvedHeight: CGFloat {
            min(max(height, 44), maxHeight)
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.vertical, 10)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: PopoverHeightKey.self, value: proxy.size.height)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: 306)
            .frame(height: resolvedHeight)
            .background(.white)
            .environment(\.colorScheme, .light)
            .presentationCompactAdaptation(.popover)
            .presentationBackground(.white)
            .presentationCornerRadius(14)
            .onPreferenceChange(PopoverHeightKey.self) { newHeight in
                height = newHeight
                onHeightChange(resolvedHeight)
            }
        }
    }

    private struct PopoverHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// 分组小标题：卡片内用浅灰小字区分区块，不用导航栏。
    private func popoverSection<Content: View>(
        _ title: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(RexColor.secondaryText)
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
            }
            content()
        }
    }

    private func popoverDivider() -> some View {
        Rectangle()
            .fill(RexColor.divider)
            .frame(height: 0.5)
            .padding(.horizontal, 18)
    }

    private func popoverInfoRow(_ text: String) -> some View {
        Text(text)
            .font(RexFont.footnote)
            .foregroundStyle(RexColor.secondaryText)
            .padding(.horizontal, 18)
            .frame(minHeight: RexLayout.minTouch)
    }

    private func popoverActionRow(
        _ title: String,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            RexHaptics.selection()
            action()
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(RexColor.brandBlue)
                }
            }
            .padding(.horizontal, 18)
            .frame(minHeight: RexLayout.minTouch)
            .contentShape(Rectangle())
        }
        .buttonStyle(RexRowButtonStyle())
    }

    /// 弹窗里的入口行：只负责进入下一页，不在弹窗里展开具体设置。
    private func popoverNavRow(
        _ title: String,
        detail: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            RexHaptics.tap()
            action()
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let detail {
                    Text(detail)
                        .font(RexFont.caption)
                        .foregroundStyle(RexColor.secondaryText)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RexColor.tertiaryText)
            }
            .padding(.horizontal, 18)
            .frame(minHeight: RexLayout.minTouch)
            .contentShape(Rectangle())
        }
        .buttonStyle(RexRowButtonStyle())
    }

    private func popoverToggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(RexColor.primaryText)
        }
        .tint(RexColor.brandBlue)
        .padding(.horizontal, 18)
        .frame(minHeight: RexLayout.minTouch)
    }

    /// 竖屏空间充足；横屏按屏幕短边算可用高度，避免卡片超出屏幕被裁切。
    private var popoverMaxHeight: CGFloat {
        guard verticalSizeClass == .compact else { return 520 }
        let screen = UIScreen.main.bounds
        return max(240, min(screen.width, screen.height) - 96)
    }

    /// 横屏从按钮左侧展开，竖屏在按钮上方展开。
    private var popoverArrowEdge: Edge {
        verticalSizeClass == .compact ? .trailing : .bottom
    }

    /// 当前展开的是哪一个左侧弹窗。
    private var activePopoverPanel: PopoverPanel? {
        if showsAudioSheet { return .audio }
        if showsSubtitleSheet { return .subtitle }
        if showsMore { return .more }
        if showsPlaylist { return .playlist }
        return nil
    }

    /// 横屏卡片在按钮左侧，且底边与按钮底边对齐。
    /// 系统会把卡片垂直居中在锚点上，所以锚点要上移「卡片高度一半 - 按钮高度一半」。
    private var popoverAnchor: PopoverAttachmentAnchor {
        guard verticalSizeClass == .compact else { return .rect(.bounds) }

        let buttonHeight: CGFloat = 38
        let cardHeight = activePopoverPanel.flatMap { popoverHeights[$0] } ?? 0
        let rise = max(0, cardHeight / 2 - buttonHeight / 2)
        return .point(UnitPoint(x: 0.5, y: 0.5 - rise / buttonHeight))
    }

    /// 弹窗内一级内容与二级页面共用同一张卡片，直接切换内容。
    @ViewBuilder
    private func popoverPages<Root: View>(@ViewBuilder root: () -> Root) -> some View {
        if let page = pageStack.last {
            popoverPage(page)
        } else {
            root()
        }
    }

    // MARK: - 音频设置

    /// 一级只放音轨选择，音频偏好在同一张卡片里推进到「音频设置」。
    private var audioPopover: some View {
        RexPopoverCard(
            maxHeight: popoverMaxHeight,
            onHeightChange: { popoverHeights[.audio] = $0 }
        ) {
            popoverPages {
                popoverSection("音轨") {
                    if state.audioTracks.isEmpty {
                        popoverInfoRow("当前视频只有一条音轨")
                    } else {
                        ForEach(state.audioTracks) { track in
                            popoverActionRow(
                                track.title,
                                selected: state.selectedAudioID == track.id
                            ) {
                                engine.selectAudio(track.id)
                            }
                        }
                    }
                }

                popoverDivider()

                popoverSection {
                    popoverNavRow("音频设置") {
                        pushPage(.audioSettings)
                    }
                }
            }
        }
    }

    // MARK: - 字幕设置

    /// 一级只放字幕开关与轨道选择，字号、底色与同步在同一张卡片里推进。
    private var subtitlePopover: some View {
        RexPopoverCard(
            maxHeight: popoverMaxHeight,
            onHeightChange: { popoverHeights[.subtitle] = $0 }
        ) {
            popoverPages {
                popoverSection {
                    popoverToggleRow("显示字幕", isOn: subtitlesBinding)
                }

                popoverDivider()

                popoverSection("内嵌字幕") {
                    if state.subtitleTracks.isEmpty {
                        popoverInfoRow("当前视频没有内嵌字幕")
                    } else {
                        ForEach(state.subtitleTracks) { track in
                            popoverActionRow(
                                track.title,
                                selected: state.selectedSubtitleID == track.id
                            ) {
                                if !settings.subtitlesEnabled {
                                    settings.subtitlesEnabled = true
                                    engine.setSubtitleEnabled(true)
                                }
                                engine.selectSubtitle(track.id)
                            }
                        }
                    }
                }

                popoverDivider()

                popoverSection {
                    popoverNavRow("字幕样式") {
                        pushPage(.subtitleStyle)
                    }
                }
            }
        }
    }

    private var subtitlesBinding: Binding<Bool> {
        Binding(
            get: { settings.subtitlesEnabled },
            set: { enabled in
                settings.subtitlesEnabled = enabled
                engine.setSubtitleEnabled(enabled)
            }
        )
    }

    /// 播放倍速：与其他播放器面板共用同一套浮层卡片，不再弹系统操作表。
    private var ratePopover: some View {
        RexPopoverCard(maxHeight: popoverMaxHeight) {
            popoverSection("播放倍速") {
                ForEach(PlayerSettingsStore.playbackRates, id: \.self) { rate in
                    popoverActionRow(
                        PlayerSettingsStore.rateText(rate),
                        selected: abs(rate - settings.playbackRate) < 0.01
                    ) {
                        setRate(rate)
                        showsRateDialog = false
                    }
                }
            }
        }
    }

    // MARK: - 控制层

    private func controls(landscape: Bool) -> some View {
        VStack(spacing: 0) {
            if !isLocked {
                topBar(landscape: landscape)
            }
            Spacer(minLength: 0)
            bottomArea(landscape: landscape)
        }
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
        .animation(.easeOut(duration: 0.22), value: controlsVisible)
    }

    /// 顶栏：居中文件名，下一行是扁平图标工具条。
    private func topBar(landscape: Bool) -> some View {
        VStack(spacing: landscape ? 0 : 4) {
            ZStack(alignment: .leading) {
                Text(title)
                    .font(.system(size: landscape ? 12 : 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 56)
                    .allowsHitTesting(false)

                networkSpeedLabel
            }

            HStack(spacing: landscape ? 4 : 6) {
                flatButton("xmark", size: landscape ? 21 : 22, label: "关闭播放", action: onClose)

                if engine.canAirPlay {
                    RexAirPlayView()
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("隔空播放")
                }
                flatButton(
                    state.isAspectFill
                        ? "arrow.down.right.and.arrow.up.left.circle"
                        : "arrow.up.left.and.arrow.down.right.circle",
                    size: landscape ? 20 : 21,
                    active: state.isAspectFill,
                    label: state.isAspectFill ? "适应屏幕" : "填充铺满"
                ) {
                    toggleAspect()
                }
                flatButton(
                    landscape ? "rectangle.landscape.rotate" : "rectangle.portrait.rotate",
                    size: landscape ? 19 : 20,
                    label: landscape ? "切换竖屏" : "切换横屏"
                ) {
                    toggleOrientation()
                }

                Spacer(minLength: 8)

                if engine.canPiP {
                    flatButton(
                        state.isPipActive ? "pip.exit" : "pip.enter",
                        size: landscape ? 21 : 22,
                        label: "画中画"
                    ) {
                        engine.togglePiP()
                    }
                }
                flatButton("camera", size: landscape ? 21 : 22, label: "截图") {
                    capture()
                }
                flatButton("speedometer", size: landscape ? 21 : 22, label: "播放倍速") {
                    cancelAutoHide()
                    showsRateDialog = true
                }
                .popover(
                    isPresented: $showsRateDialog,
                    attachmentAnchor: .rect(.bounds),
                    // 顶部工具条从按钮下方展开，避免卡片顶到屏幕外。
                    arrowEdge: .top
                ) {
                    ratePopover
                }
            }
        }
        .padding(.horizontal, horizontalPadding(landscape))
        .padding(.top, landscape ? 2 : 0)
        .padding(.bottom, landscape ? 10 : 14)
    }

    /// 左上角实时网速：贴着关闭按钮上方，只在控制层显示时出现。
    private var networkSpeedLabel: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.down")
                .font(.system(size: 8, weight: .bold))

            Text(networkSpeedText)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
        }
        .foregroundStyle(.white.opacity(0.62))
        .allowsHitTesting(false)
        .accessibilityLabel("实时网速 \(networkSpeedText)")
    }

    /// 底部：参数与圆形工具、时间进度行、传输控制行。
    private func bottomArea(landscape: Bool) -> some View {
        VStack(spacing: landscape ? 6 : 8) {
            HStack(spacing: 4) {
                statsLabel(landscape: landscape)
                Spacer(minLength: 8)

                circleButton(
                    "waveform",
                    active: state.isMuted,
                    label: "音频设置"
                ) {
                    cancelAutoHide()
                    showsAudioSheet = true
                }
                .popover(
                    isPresented: $showsAudioSheet,
                    attachmentAnchor: popoverAnchor,
                    arrowEdge: popoverArrowEdge
                ) {
                    audioPopover
                }

                circleButton(
                    "line.3.horizontal.decrease",
                    active: settings.subtitlesEnabled,
                    label: "字幕设置"
                ) {
                    cancelAutoHide()
                    showsSubtitleSheet = true
                }
                .popover(
                    isPresented: $showsSubtitleSheet,
                    attachmentAnchor: popoverAnchor,
                    arrowEdge: popoverArrowEdge
                ) {
                    subtitlePopover
                }

                danmakuButton
                circleButton("ellipsis", label: "更多设置") {
                    openMore()
                }
                .popover(
                    isPresented: $showsMore,
                    attachmentAnchor: popoverAnchor,
                    arrowEdge: popoverArrowEdge
                ) {
                    morePopover
                }
            }
            .frame(height: landscape ? 32 : 30)
            .opacity(isLocked ? 0 : 1)
            .allowsHitTesting(!isLocked)

            HStack(spacing: landscape ? 12 : 10) {
                Text(timeText(displayTime))
                    .frame(width: 56, alignment: .leading)

                progressBar

                Text(state.duration > 0 ? timeText(state.duration) : "--:--")
                    .frame(width: 60, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.9))
            .opacity(isLocked ? 0 : 1)
            .allowsHitTesting(!isLocked)

            ZStack {
                HStack(spacing: 0) {
                    // 锁定前后位置不变，只切换开 / 关两种锁图标。
                    flatButton(
                        isLocked ? "lock.fill" : "lock",
                        size: landscape ? 18 : 19,
                        label: isLocked ? "解锁控制" : "锁定控制"
                    ) {
                        if isLocked {
                            unlockControls()
                        } else {
                            lockControls()
                        }
                    }
                    Spacer(minLength: 0)
                    flatButton("list.bullet", size: landscape ? 19 : 20, label: "播放列表") {
                        cancelAutoHide()
                        showsPlaylist = true
                    }
                    .popover(
                        isPresented: $showsPlaylist,
                        attachmentAnchor: popoverAnchor,
                        arrowEdge: popoverArrowEdge
                    ) {
                        playlistPopover
                    }
                    .opacity(isLocked ? 0 : 1)
                    .allowsHitTesting(!isLocked)
                }

                HStack(spacing: landscape ? 40 : 38) {
                    flatButton("gobackward.10", size: landscape ? 19 : 20, label: "快退 10 秒") {
                        seek(by: -10)
                    }
                    playPauseButton(landscape: landscape)
                    flatButton("goforward.10", size: landscape ? 19 : 20, label: "快进 10 秒") {
                        seek(by: 10)
                    }
                }
                .opacity(isLocked ? 0 : 1)
                .allowsHitTesting(!isLocked)
            }
            .frame(height: landscape ? 42 : 44)
        }
        .padding(.horizontal, horizontalPadding(landscape))
        .padding(.top, landscape ? 8 : 14)
        .padding(.bottom, landscape ? 4 : 6)
    }

    @ViewBuilder
    private func statsLabel(landscape: Bool) -> some View {
        let items = statsItems(landscape: landscape)
        if !items.isEmpty {
            Text(items.joined(separator: " · "))
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// 底部左侧参数：横屏展示容器 · 编码 · 分辨率 · 帧率 · 码率，竖屏画面窄只留分辨率，缺项自动省略。
    private func statsItems(landscape: Bool) -> [String] {
        guard landscape else { return resolutionText.map { [$0] } ?? [] }

        var items: [String] = []
        if let format = state.containerFormat {
            items.append(format)
        }
        if let codec = state.videoCodec {
            items.append(codec)
        }
        if let resolution = resolutionText {
            items.append(resolution)
        }
        if state.frameRate > 0 {
            items.append("\(Int(state.frameRate.rounded()))FPS")
        }
        if state.bitrateKbps > 0 {
            items.append("\(state.bitrateKbps)Kbps")
        }
        return items
    }

    /// 分辨率按短边归档，竖屏视频同样显示成 1080P。
    private var resolutionText: String? {
        let size = state.videoSize
        guard size.width >= 1, size.height >= 1 else { return nil }
        let shortSide = Int(min(size.width, size.height).rounded())
        switch shortSide {
        case 2160...: return "4K"
        case 1440...: return "1440P"
        case 1080...: return "1080P"
        case 720...: return "720P"
        case 480...: return "480P"
        case 360...: return "360P"
        default: return "\(shortSide)P"
        }
    }

    private var bufferingIndicator: some View {
        ProgressView()
            .controlSize(.large)
            .tint(.white)
            .allowsHitTesting(false)
    }

    private func playPauseButton(landscape: Bool) -> some View {
        Button(action: togglePlay) {
            Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(state.isPlaying ? "暂停" : "播放")
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let total = max(state.duration, 0.001)
            // 时长未知时不能按 0.001 算比例，否则进播放页会先满格再跳回续播位置。
            let played = state.duration > 0 ? min(max(displayTime / total, 0), 1) : 0
            let loaded = state.duration > 0 ? min(max(state.buffered / total, 0), 1) : 0
            let knob: CGFloat = isScrubbing ? 14 : 9

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(height: 3)

                // 缓冲进度：比轨道亮一档、比已播暗一档，三段落一眼能分开。
                Capsule()
                    .fill(.white.opacity(0.55))
                    .frame(width: width * loaded, height: 3)

                Capsule()
                    .fill(.white)
                    .frame(width: width * played, height: 3)

                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: min(max(width * played - knob / 2, 0), width - knob))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard state.duration > 0 else { return }
                        if !isScrubbing {
                            isScrubbing = true
                            cancelAutoHide()
                        }
                        scrubTarget = min(
                            max(Double(value.location.x / width) * state.duration, 0),
                            state.duration
                        )
                    }
                    .onEnded { _ in
                        guard isScrubbing else { return }
                        engine.seek(to: scrubTarget)
                        isScrubbing = false
                        scheduleAutoHide()
                    }
            )
        }
        .frame(height: 22)
    }

    // MARK: - 更多设置

    /// 一级只做入口索引，具体开关与选择推进到同一张卡片里的下一页。
    private var morePopover: some View {
        RexPopoverCard(
            maxHeight: popoverMaxHeight,
            onHeightChange: { popoverHeights[.more] = $0 }
        ) {
            popoverPages {
                popoverSection("播放") {
                    popoverNavRow("解码与画质", detail: settings.kernel.title) {
                        pushPage(.playbackEngine)
                    }
                    popoverDivider()
                    popoverNavRow("播放顺序", detail: orderSummary) {
                        pushPage(.playOrder)
                    }
                    popoverDivider()
                    popoverNavRow("片头片尾", detail: introOutroSummary) {
                        pushPage(.introOutro)
                    }
                    popoverDivider()
                    popoverNavRow("播放控制", detail: controlSummary) {
                        pushPage(.playbackControl)
                    }
                }

                popoverDivider()

                popoverSection("运行") {
                    popoverNavRow("屏幕与后台", detail: screenSummary) {
                        pushPage(.screenAndBackground)
                    }
                }
            }
        }
    }

    private var orderSummary: String {
        var parts: [String] = []
        if settings.loopPlayback { parts.append("循环") }
        if settings.autoPlayNext { parts.append("连播") }
        if settings.autoCloseOnFinish { parts.append("播完关闭") }
        return parts.isEmpty ? "未启用" : parts.joined(separator: " · ")
    }

    private var introOutroSummary: String {
        switch (settings.skipIntro, settings.skipOutro) {
        case (true, true): "片头片尾"
        case (true, false): "跳过片头"
        case (false, true): "跳过片尾"
        case (false, false): "未启用"
        }
    }

    private var controlSummary: String {
        var parts = [state.isAspectFill ? "铺满" : "适应"]
        if sleepMinutes > 0 { parts.append("\(sleepMinutes) 分钟") }
        return parts.joined(separator: " · ")
    }

    private var screenSummary: String {
        var parts: [String] = []
        if settings.keepScreenAwake { parts.append("常亮") }
        if settings.backgroundAudio { parts.append("后台音频") }
        if settings.autoLandscape { parts.append("自动横屏") }
        return parts.isEmpty ? "默认" : parts.joined(separator: " · ")
    }

    private var screenAwakeBinding: Binding<Bool> {
        Binding(
            get: { settings.keepScreenAwake },
            set: { enabled in
                settings.keepScreenAwake = enabled
                UIApplication.shared.isIdleTimerDisabled = enabled
            }
        )
    }

    // MARK: - 弹窗内的二级页

    /// 二级内容仍留在同一张弹窗卡片里：顶部一条「返回 + 标题」，下面是具体设置。
    @ViewBuilder
    private func popoverPage(_ page: PlayerPage) -> some View {
        Button(action: popPage) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RexColor.brandBlue)

                Text(page.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        popoverDivider()

        pageContent(page)
    }

    private func popoverStepperRow(
        _ title: String,
        value: Binding<Int>,
        in range: ClosedRange<Int>,
        step: Int,
        valueText: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(valueText)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(RexColor.secondaryText)
                .lineLimit(1)

            popoverStepperButtons(
                canDecrease: value.wrappedValue > range.lowerBound,
                canIncrease: value.wrappedValue < range.upperBound,
                decrease: {
                    value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
                },
                increase: {
                    value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
                }
            )
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 40)
    }

    private func popoverStepperRow(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(valueText)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(RexColor.secondaryText)
                .lineLimit(1)

            popoverStepperButtons(
                canDecrease: value.wrappedValue > range.lowerBound,
                canIncrease: value.wrappedValue < range.upperBound,
                decrease: {
                    value.wrappedValue = stepped(value.wrappedValue, by: -step, in: range)
                },
                increase: {
                    value.wrappedValue = stepped(value.wrappedValue, by: step, in: range)
                }
            )
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 40)
    }

    /// 小数步进保留一位，避免 0.1 累加出浮点尾巴。
    private func stepped(
        _ value: Double,
        by delta: Double,
        in range: ClosedRange<Double>
    ) -> Double {
        let next = ((value + delta) * 10).rounded() / 10
        return min(max(next, range.lowerBound), range.upperBound)
    }

    private func popoverStepperButtons(
        canDecrease: Bool,
        canIncrease: Bool,
        decrease: @escaping () -> Void,
        increase: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            popoverStepperButton("minus", enabled: canDecrease, action: decrease)
            popoverStepperButton("plus", enabled: canIncrease, action: increase)
        }
    }

    private func popoverStepperButton(
        _ icon: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(
                    enabled ? RexColor.primaryText : RexColor.secondaryText.opacity(0.4)
                )
                .frame(width: 24, height: 24)
                .background(
                    RexColor.field,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    @ViewBuilder
    private func pageContent(_ page: PlayerPage) -> some View {
        switch page {
        case .audioSettings:
            popoverToggleRow("变速保持音调", isOn: $settings.keepPitch)
            popoverDivider()
            popoverToggleRow("静音起播", isOn: $settings.startMuted)

        case .subtitleStyle:
            popoverNavRow("字幕字号", detail: settings.subtitleSize.title) {
                pushPage(.subtitleSize)
            }
            popoverDivider()
            popoverToggleRow("半透明底色", isOn: $settings.subtitleBackground)
            popoverDivider()
            popoverStepperRow(
                "字幕延迟",
                value: $settings.subtitleDelay,
                in: -3...3,
                step: 0.1,
                valueText: PlayerSettingsStore.delayText(settings.subtitleDelay)
            )

        case .subtitleSize:
            ForEach(SubtitleSize.allCases) { size in
                if size != SubtitleSize.allCases.first { popoverDivider() }
                popoverActionRow(size.title, selected: settings.subtitleSize == size) {
                    settings.subtitleSize = size
                    popPage()
                }
            }

        case .playbackEngine:
            popoverNavRow("播放内核", detail: settings.kernel.title) {
                pushPage(.kernel)
            }
            popoverDivider()
            popoverNavRow("解码方式", detail: settings.decodeMode.title) {
                pushPage(.decodeMode)
            }
            popoverDivider()
            popoverNavRow("起播清晰度", detail: settings.preferredResolution.title) {
                pushPage(.resolution)
            }

        case .kernel:
            ForEach(PlayerKernel.allCases) { kernel in
                if kernel != PlayerKernel.allCases.first { popoverDivider() }
                popoverActionRow(kernel.title, selected: settings.kernel == kernel) {
                    settings.kernel = kernel
                    popPage()
                }
            }

        case .decodeMode:
            ForEach(PlayerDecodeMode.allCases) { mode in
                if mode != PlayerDecodeMode.allCases.first { popoverDivider() }
                popoverActionRow(mode.title, selected: settings.decodeMode == mode) {
                    settings.decodeMode = mode
                    popPage()
                }
            }

        case .resolution:
            ForEach(PlayerResolution.allCases) { resolution in
                if resolution != PlayerResolution.allCases.first { popoverDivider() }
                popoverActionRow(
                    resolution.title,
                    selected: settings.preferredResolution == resolution
                ) {
                    settings.preferredResolution = resolution
                    popPage()
                }
            }

        case .playOrder:
            popoverToggleRow("自动连播下一集", isOn: $settings.autoPlayNext)
            popoverDivider()
            popoverToggleRow("循环播放", isOn: $settings.loopPlayback)
            popoverDivider()
            popoverToggleRow("播放结束自动关闭", isOn: $settings.autoCloseOnFinish)

        case .introOutro:
            popoverToggleRow("跳过片头", isOn: $settings.skipIntro)
            if settings.skipIntro {
                popoverDivider()
                popoverStepperRow(
                    "片头时长",
                    value: $settings.introSeconds,
                    in: 5...600,
                    step: 5,
                    valueText: "\(settings.introSeconds) 秒"
                )
            }
            popoverDivider()
            popoverToggleRow("跳过片尾", isOn: $settings.skipOutro)
            if settings.skipOutro {
                popoverDivider()
                popoverStepperRow(
                    "片尾时长",
                    value: $settings.outroSeconds,
                    in: 5...600,
                    step: 5,
                    valueText: "\(settings.outroSeconds) 秒"
                )
            }

        case .playbackControl:
            popoverNavRow("定时关闭", detail: sleepSummary) {
                pushPage(.sleepTimer)
            }
            popoverDivider()
            popoverNavRow("画面模式", detail: state.isAspectFill ? "填充铺满" : "适应屏幕") {
                pushPage(.aspectMode)
            }

        case .sleepTimer:
            ForEach(sleepOptions, id: \.self) { minutes in
                if minutes != sleepOptions.first { popoverDivider() }
                popoverActionRow(
                    minutes == 0 ? "关闭" : "\(minutes) 分钟",
                    selected: sleepMinutes == minutes
                ) {
                    setSleepTimer(minutes)
                    popPage()
                }
            }

        case .aspectMode:
            popoverActionRow("适应屏幕", selected: !state.isAspectFill) {
                engine.setAspectFill(false)
                popPage()
            }
            popoverDivider()
            popoverActionRow("填充铺满", selected: state.isAspectFill) {
                engine.setAspectFill(true)
                popPage()
            }

        case .screenAndBackground:
            popoverToggleRow("屏幕常亮", isOn: screenAwakeBinding)
            popoverDivider()
            popoverToggleRow("自动横屏", isOn: $settings.autoLandscape)
            popoverDivider()
            popoverToggleRow("后台播放音频", isOn: $settings.backgroundAudio)
            popoverDivider()
            popoverToggleRow("记忆音量", isOn: $settings.rememberVolume)
            popoverDivider()
            popoverToggleRow("记忆亮度", isOn: $settings.rememberBrightness)
        }
    }

    private var sleepOptions: [Int] { [0, 30, 60, 90] }

    private var sleepSummary: String {
        sleepMinutes == 0 ? "关闭" : "\(sleepMinutes) 分钟"
    }

    private func pushPage(_ page: PlayerPage) {
        cancelAutoHide()
        pageStack.append(page)
    }

    private func popPage() {
        _ = pageStack.popLast()
    }

    // MARK: - 播放列表

    /// 当前文件夹的视频列表，点选后原页切换播放。
    private var playlistPopover: some View {
        RexPopoverCard(
            maxHeight: min(popoverMaxHeight, 460),
            onHeightChange: { popoverHeights[.playlist] = $0 }
        ) {
            popoverSection("播放列表") {
                if playlist.isEmpty {
                    popoverInfoRow("当前文件夹没有可播放的视频")
                } else {
                    ScrollViewReader { proxy in
                        VStack(spacing: 0) {
                            ForEach(Array(playlist.enumerated()), id: \.element.id) { index, item in
                                Button {
                                    guard item.id != currentItemID else {
                                        showsPlaylist = false
                                        return
                                    }
                                    showsPlaylist = false
                                    onSelect(item)
                                } label: {
                                    playlistRow(index: index, item: item)
                                }
                                .buttonStyle(.plain)
                                .id(item.id)
                            }
                        }
                        .onAppear {
                            proxy.scrollTo(currentItemID, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func playlistRow(index: Int, item: PanItem) -> some View {
        let isCurrent = item.id == currentItemID

        return HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(RexColor.secondaryText)
                .frame(width: 22, alignment: .trailing)

            Text(item.name)
                .font(.system(size: 14, weight: isCurrent ? .semibold : .medium))
                .foregroundStyle(isCurrent ? RexColor.brandBlue : RexColor.primaryText)
                .lineLimit(1)

            Spacer(minLength: 8)

            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RexColor.brandBlue)
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    /// 顶部工具条按钮：纯白色扁平图标，无底。
    private func flatButton(
        _ icon: String,
        size: CGFloat,
        active: Bool = false,
        enabled: Bool = true,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            RexHaptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(.white.opacity(enabled ? (active ? 1 : 0.92) : 0.28))
                .frame(width: RexLayout.minTouch, height: RexLayout.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    /// 进度条上方的细描边圆形按钮。
    private func circleButton(
        _ icon: String,
        active: Bool = false,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            RexHaptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(active ? 1 : 0.9))
                .frame(width: 29, height: 29)
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(active ? 0.95 : 0.55), lineWidth: 1.2)
                }
                .frame(width: RexLayout.minTouch, height: RexLayout.minTouch)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    /// 弹幕入口：与参考图保持同一套圆形样式，弹幕能力尚未接入。
    private var danmakuButton: some View {
        Button {
            RexHaptics.tap()
            showHUD(icon: "text.bubble", text: "弹幕暂未开放")
        } label: {
            Text("D")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 29, height: 29)
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(0.55), lineWidth: 1.2)
                }
                .frame(width: RexLayout.minTouch, height: RexLayout.minTouch)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("弹幕")
    }

    // MARK: - 字幕

    private func subtitleView(landscape: Bool) -> some View {
        Text(subtitleText)
            .font(.system(size: settings.subtitleSize.fontSize, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
            .padding(.horizontal, settings.subtitleBackground ? 8 : 0)
            .padding(.vertical, settings.subtitleBackground ? 4 : 0)
            .background {
                if settings.subtitleBackground {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.black.opacity(0.45))
                }
            }
            .padding(.horizontal, RexSpacing.xxl)
            .padding(.bottom, landscape ? 128 : 148)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.12), value: subtitleText)
    }

    // MARK: - 手势

    private func gestureLayer(size: CGSize) -> some View {
        Color.clear
            .ignoresSafeArea()
            .contentShape(Rectangle())
            // 单击、双击、长按、拖动全部由同一个拖动识别器派发，
            // 不再叠加第二个手势，避免互相抢占导致「隐藏后点屏幕唤不出控制条」。
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in handleTouchChanged(value, size: size) }
                    .onEnded { value in handleTouchEnded(value, size: size) }
            )
    }

    private func handleTouchChanged(_ value: DragGesture.Value, size: CGSize) {
        guard !isLocked, !isBoosting else { return }

        let distance = hypot(value.translation.width, value.translation.height)

        // 手指还没明显移动：先按长按计时，0.5 秒后按左右半屏进入快进/快退。
        if drag.mode == .none, distance <= 12 {
            scheduleBoost(at: value.startLocation, size: size)
            return
        }

        cancelBoostSchedule()

        if drag.mode == .none {
            hudTask?.cancel()
            if abs(value.translation.width) > abs(value.translation.height) {
                let mode = dragMode(for: gestures.horizontalDrag)
                // 时长还没读到时拖动查找会把进度拽回开头，直接忽略这次横划。
                if mode == .seek, state.duration <= 0 { return }
                drag.mode = mode
                drag.startValue = displayTime
                if mode == .seek {
                    isScrubbing = true
                    scrubTarget = displayTime
                    cancelAutoHide()
                }
            } else if value.startLocation.x < size.width / 2 {
                drag.mode = dragMode(for: gestures.leftVerticalDrag)
                drag.startValue = Double(UIScreen.main.brightness)
            } else {
                drag.mode = dragMode(for: gestures.rightVerticalDrag)
                drag.startValue = Double(RexSystemVolume.current)
            }
        }

        switch drag.mode {
        case .none:
            break
        case .seek:
            let span = state.duration > 0 ? min(state.duration, 180) : 120
            let delta = Double(value.translation.width) / Double(max(size.width, 1)) * span
            scrubTarget = clamp(drag.startValue + delta, upper: state.duration)
            hud = HUD(
                icon: delta >= 0 ? "goforward" : "gobackward",
                text: "\(timeText(scrubTarget)) / \(timeText(state.duration))",
                progress: state.duration > 0 ? scrubTarget / state.duration : nil
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
            RexSystemVolume.set(Float(next))
            hud = HUD(icon: "speaker.wave.2.fill", text: "音量 \(Int(next * 100))%", progress: next)
        }

        if drag.mode != .none {
            cancelAutoHide()
        }
    }

    private func handleTouchEnded(_ value: DragGesture.Value, size: CGSize) {
        cancelBoostSchedule()
        let wasBoosting = isBoosting
        endBoost()

        guard !isLocked else {
            drag = DragState()
            return
        }

        let wasDragging = drag.mode != .none
        // 手势被用户关掉时 `drag.mode` 会一直是 none，但手指已经划过屏幕；
        // 抬手不能当成单击，否则会误切播放/暂停或控制条。
        let moved = hypot(value.translation.width, value.translation.height) > 12
        if drag.mode == .seek {
            engine.seek(to: scrubTarget)
            isScrubbing = false
        }
        drag = DragState()

        if wasDragging {
            hud = nil
            scheduleAutoHide()
        } else if wasBoosting || moved {
            // 长按倍速和无效拖动都算一次操作，抬手时不再派发单击动作。
            scheduleAutoHide()
        } else {
            handleTap(at: value.location, size: size)
        }
    }

    /// 双击在 0.3 秒内、位置接近时成立；控制条隐藏时单击立即唤出，不等待双击判定。
    private func handleTap(at location: CGPoint, size: CGSize) {
        let now = Date()
        if let last = lastTapAt,
           now.timeIntervalSince(last) < 0.3,
           hypot(location.x - lastTapPoint.x, location.y - lastTapPoint.y) < 44 {
            lastTapAt = nil
            pendingSingleTap?.cancel()
            handleDoubleTap(at: location, size: size)
            return
        }

        lastTapAt = now
        lastTapPoint = location

        guard controlsVisible else {
            // 隐藏时单击立即唤出控制条，但保留这次点击的记录：
            // 紧接着的第二下仍然算双击，不会因为刚唤出控制条就没法快进/快退。
            showControls()
            return
        }

        pendingSingleTap?.cancel()
        pendingSingleTap = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            perform(gestures.singleTap)
        }
    }

    /// 长按 0.5 秒进入临时倍速：右半屏 2x 快进，左半屏 2x 快退，松手后恢复。
    private func startBoost(_ direction: BoostDirection) {
        guard gestures.longPress == .speedUp, !isBoosting, !isLocked,
              drag.mode == .none, state.isPlaying else { return }
        isBoosting = true
        boostDirection = direction
        // 长按期间不自动隐藏，否则按到一半控制层就消失了。
        cancelAutoHide()

        switch direction {
        case .forward:
            engine.setRate(2)
            hud = HUD(
                icon: "forward.fill",
                text: "2x 快进 \(timeText(state.currentTime))",
                progress: state.duration > 0 ? state.currentTime / state.duration : nil
            )
            // 与长按快退保持一致：HUD 上持续刷新当前时间。
            boostHUDTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard !Task.isCancelled else { return }
                    hud = HUD(
                        icon: "forward.fill",
                        text: "2x 快进 \(timeText(state.currentTime))",
                        progress: state.duration > 0 ? state.currentTime / state.duration : nil
                    )
                    if state.duration > 0, state.currentTime >= state.duration - 0.2 { return }
                }
            }
        case .rewind:
            // 内核不支持负速率倒放，改为暂停后按 2x 的频率循环回退。
            engine.pause()
            hud = HUD(
                icon: "backward.fill",
                text: "2x 快退",
                progress: state.duration > 0 ? state.currentTime / state.duration : nil
            )
            boostHUDTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled else { return }
                    let target = max(state.currentTime - 0.2, 0)
                    engine.seek(to: target)
                    hud = HUD(
                        icon: "backward.fill",
                        text: "2x 快退 \(timeText(target))",
                        progress: state.duration > 0 ? target / state.duration : nil
                    )
                    if target <= 0 { return }
                }
            }
        }
    }

    private func endBoost() {
        guard isBoosting else { return }
        isBoosting = false
        boostHUDTask?.cancel()
        boostHUDTask = nil

        switch boostDirection {
        case .forward:
            engine.setRate(settings.playbackRate)
        case .rewind:
            engine.play()
            engine.setRate(settings.playbackRate)
        }
        hud = nil
    }

    private func scheduleBoost(at location: CGPoint, size: CGSize) {
        guard gestures.longPress == .speedUp, boostTask == nil, !isBoosting,
              state.isPlaying, !isLocked, size.width > 0 else { return }
        let direction: BoostDirection = location.x < size.width / 2 ? .rewind : .forward
        boostTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            startBoost(direction)
        }
    }

    private func cancelBoostSchedule() {
        boostTask?.cancel()
        boostTask = nil
    }

    private func handleDoubleTap(at location: CGPoint, size: CGSize) {
        guard !isLocked else { return }
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
            cycleRate()
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
        if state.isPlaying {
            engine.pause()
            cancelAutoHide()
            controlsVisible = true
        } else {
            // 播完后再点播放，从头开始。
            if state.duration > 0, state.currentTime >= state.duration - 0.5 {
                engine.seek(to: 0)
            }
            engine.play()
            scheduleAutoHide()
        }
    }

    /// 从倍速菜单选定档位，与长按的临时倍速区分。
    private func setRate(_ rate: Double) {
        settings.playbackRate = rate
        engine.setRate(rate)
        showHUD(icon: "speedometer", text: "\(PlayerSettingsStore.rateText(rate)) 倍速")
    }

    /// 双击切档：在预设档位之间循环。
    private func cycleRate() {
        let rates = PlayerSettingsStore.playbackRates
        let index = rates.firstIndex { abs($0 - settings.playbackRate) < 0.01 } ?? 2
        setRate(rates[(index + 1) % rates.count])
    }

    /// 适应屏幕 / 填充铺满切换，图标跟随状态变化。
    private func toggleAspect() {
        engine.setAspectFill(!state.isAspectFill)
        showHUD(
            icon: state.isAspectFill
                ? "arrow.down.right.and.arrow.up.left.circle"
                : "arrow.up.left.and.arrow.down.right.circle",
            text: state.isAspectFill ? "填充铺满" : "适应屏幕"
        )
        scheduleAutoHide()
    }

    /// 截图：交给内核取当前帧，存入系统相册。
    private func capture() {
        guard !isCapturing else { return }
        isCapturing = true
        showHUD(icon: "camera", text: "正在截图…")
        Task {
            let image = await engine.snapshot()
            isCapturing = false
            guard let image else {
                showHUD(icon: "exclamationmark.triangle", text: "截图失败，请重试")
                return
            }
            saveToPhotoLibrary(image)
        }
    }

    private func saveToPhotoLibrary(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    showHUD(icon: "exclamationmark.triangle", text: "没有相册权限")
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                Task { @MainActor in
                    showHUD(
                        icon: success ? "checkmark.circle" : "exclamationmark.triangle",
                        text: success ? "截图已保存" : "截图保存失败"
                    )
                }
            }
        }
    }

    /// 定时关闭：关闭 / 30 / 60 / 90 分钟，到点自动暂停。
    private func setSleepTimer(_ minutes: Int) {
        sleepTask?.cancel()
        sleepTask = nil
        sleepMinutes = minutes
        guard minutes > 0 else { return }

        sleepTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            sleepMinutes = 0
            engine.pause()
            cancelAutoHide()
            withAnimation(.easeOut(duration: 0.2)) {
                controlsVisible = true
            }
            showHUD(icon: "clock", text: "定时结束，已暂停")
        }
    }

    /// 横竖屏切换：调用系统几何更新让整页旋转。
    private func toggleOrientation() {
        RexOrientation.request(RexOrientation.isLandscape ? .portrait : .landscapeRight)
        scheduleAutoHide()
    }

    private func seek(by delta: Double) {
        guard state.duration > 0 else {
            // 刚进播放页、时长还没读到时给出提示，避免连点快进却毫无反应。
            showHUD(icon: "clock", text: "时长读取中，请稍候")
            return
        }
        let target = clamp(displayTime + delta, upper: state.duration)
        engine.seek(to: target)
        showHUD(
            icon: delta >= 0 ? "goforward" : "gobackward",
            text: "\(delta >= 0 ? "+" : "-")\(Int(abs(delta))) 秒 · \(timeText(target))",
            progress: target / state.duration
        )
        scheduleAutoHide()
    }

    private func lockControls() {
        hideTask?.cancel()
        hudTask?.cancel()
        showsMore = false
        withAnimation(.easeOut(duration: 0.2)) {
            isLocked = true
            controlsVisible = true
        }
    }

    private func unlockControls() {
        withAnimation(.easeOut(duration: 0.2)) {
            isLocked = false
        }
        showControls()
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
        showsMore = false
        controlsVisible = false
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        // 暂停时不自动隐藏，与系统播放器保持一致。
        guard state.isPlaying, !isScrubbing, !showsMore, !showsPlaylist,
              !showsAudioSheet, !showsSubtitleSheet, !showsRateDialog, !isLocked,
              pageStack.isEmpty else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
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

    private func openMore() {
        cancelAutoHide()
        controlsVisible = true
        // 内嵌与外挂字幕通常起播后才解析出来，打开面板时再拉一次轨道。
        engine.refreshTracks()
        showsMore = true
    }

    // MARK: - HUD

    /// 离散操作的提示统一 1.8 秒后自动消失。
    private func showHUD(icon: String, text: String, progress: Double? = nil) {
        hudTask?.cancel()
        hud = HUD(icon: icon, text: text, progress: progress)
        hudTask = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                hud = nil
            }
        }
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

    // MARK: - 实时网速

    private var networkSpeedText: String {
        if networkSpeed >= 1024 * 1024 {
            return String(format: "%.1f MB/s", networkSpeed / 1024 / 1024)
        }
        if networkSpeed >= 1024 {
            return String(format: "%.0f KB/s", networkSpeed / 1024)
        }
        return "0 KB/s"
    }

    /// 每秒采样一次网卡接收字节数，换算成实时下载速度。
    private func startNetworkSpeedSampling() {
        networkSpeedTask?.cancel()
        networkSpeedTask = Task { @MainActor in
            var previous = Self.receivedBytes()
            var previousDate = Date()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }

                let now = Date()
                let current = Self.receivedBytes()
                let elapsed = now.timeIntervalSince(previousDate)
                if current >= previous, elapsed > 0 {
                    networkSpeed = Double(current - previous) / elapsed
                }
                previous = current
                previousDate = now
            }
        }
    }

    /// 累计接收字节数：只统计 Wi-Fi / 蜂窝这类实际出口网卡，跳过回环与虚拟接口。
    private static func receivedBytes() -> UInt64 {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return 0 }
        defer { freeifaddrs(addresses) }

        var total: UInt64 = 0
        var pointer = addresses
        while let entry = pointer {
            pointer = entry.pointee.ifa_next

            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let data = entry.pointee.ifa_data else { continue }

            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }

            total += UInt64(data.assumingMemoryBound(to: if_data.self).pointee.ifi_ibytes)
        }
        return total
    }

    // MARK: - 生命周期

    private func prepare() {
        if settings.rememberBrightness {
            UIScreen.main.brightness = CGFloat(settings.lastBrightness)
        }
        if settings.rememberVolume {
            RexSystemVolume.set(Float(settings.lastVolume))
        }
        engine.setRate(settings.playbackRate)
        engine.setSubtitleDelay(settings.subtitleDelay)
        engine.setMuted(engine.state.isMuted)
        engine.refreshTracks()
        startNetworkSpeedSampling()
        scheduleAutoHide()
    }

    private func persist() {
        hideTask?.cancel()
        hideTask = nil
        hudTask?.cancel()
        hudTask = nil
        sleepTask?.cancel()
        sleepTask = nil
        networkSpeedTask?.cancel()
        networkSpeedTask = nil

        if settings.rememberBrightness {
            settings.lastBrightness = Double(UIScreen.main.brightness)
        }
        if settings.rememberVolume {
            settings.lastVolume = Double(RexSystemVolume.current)
        }
    }

    // MARK: - 工具

    private func horizontalPadding(_ landscape: Bool) -> CGFloat {
        landscape ? RexSpacing.xxl : RexSpacing.lg
    }

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
