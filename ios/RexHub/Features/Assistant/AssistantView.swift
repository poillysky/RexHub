import SwiftUI
import UIKit

/// AI 助手「小花」：独立聊天页。
/// 交互对齐主流助手 App 与微信聊天页：左右分栏气泡、头像、时间分隔、底部输入条。
struct AssistantView: View {
    /// 当前账号昵称，用于右侧用户头像。
    var userName: String = ""

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var messages: [AssistantMessage] = []
    @State private var input = ""
    @State private var isStreaming = false
    @State private var statusText = ""
    @State private var streamTask: Task<Void, Never>?
    @State private var scrollTask: Task<Void, Never>?
    @State private var toast: RexToastInfo?
    @State private var avatars = AvatarStore.shared
    @FocusState private var isFocused: Bool

    /// 相邻两条消息超过这个间隔才插时间分隔，避免刷屏。
    private let timeGap: TimeInterval = 5 * 60

    var body: some View {
        VStack(spacing: 0) {
            topBar

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: RexSpacing.md) {
                        if messages.isEmpty {
                            welcome
                        }

                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            if showsTime(at: index) {
                                timeSeparator(message.createdAt)
                            }

                            AssistantMessageRow(
                                message: message,
                                streaming: isStreaming,
                                statusText: statusText,
                                userName: userName,
                                avatarSelection: avatars.selection,
                                onOpenURL: { url in openURL(url) }
                            )
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal, RexSpacing.lg)
                    .padding(.top, RexSpacing.md)
                    .padding(.bottom, RexSpacing.xl)
                    .frame(maxWidth: RexLayout.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: statusText) { _, _ in
                    scrollToBottom(proxy)
                }
            }

            inputBar
        }
        .background(RexPageBackground())
        .toolbar(.hidden, for: .navigationBar)
        .onDisappear { streamTask?.cancel() }
        .rexToast($toast)
    }

    // MARK: - 顶栏

    /// 极简顶栏：左侧返回，标题居中，右侧会话操作。
    private var topBar: some View {
        ZStack {
            Text("小花")
                .font(.system(.headline, weight: .semibold))
                .foregroundStyle(RexColor.primaryText)

            HStack {
                Button {
                    RexHaptics.tap()
                    dismiss()
                } label: {
                    iconLabel("chevron.left")
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("返回")

                Spacer(minLength: 0)

                Menu {
                    Button("清空对话", systemImage: "trash", role: .destructive) {
                        clearConversation()
                    }
                    .disabled(messages.isEmpty)
                } label: {
                    iconLabel("ellipsis")
                }
                .accessibilityLabel("会话操作")
            }
        }
        .padding(.horizontal, RexSpacing.md)
        .padding(.vertical, RexSpacing.xs + 2)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RexColor.divider)
                .frame(height: 0.5)
        }
    }

    private func iconLabel(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(RexColor.primaryText)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }

    // MARK: - 欢迎语

    private var welcome: some View {
        VStack(spacing: RexSpacing.lg) {
            AssistantAvatar(size: 64)
                .shadow(color: RexColor.brandBlue.opacity(0.25), radius: 18, y: 8)

            VStack(spacing: RexSpacing.xs) {
                Text("你好，我是小花")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(RexColor.primaryText)

                Text("找片 · 查资料 · 磁力与网盘资源")
                    .font(RexFont.footnote)
                    .foregroundStyle(RexColor.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
        .padding(.bottom, RexSpacing.xl)
    }

    // MARK: - 输入条

    private var inputBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(RexColor.divider)
                .frame(height: 0.5)

            HStack(alignment: .bottom, spacing: RexSpacing.sm) {
                TextField("问小花找片、问资料…", text: $input, axis: .vertical)
                    .font(RexFont.body)
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1...5)
                    .focused($isFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, RexSpacing.md)
                    .padding(.vertical, 9)
                    .frame(minHeight: 38)
                    .background(
                        RexColor.surface,
                        in: RoundedRectangle(cornerRadius: 19, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .strokeBorder(RexColor.fieldBorder, lineWidth: 0.75)
                    }

                Button {
                    if isStreaming {
                        stop()
                    } else {
                        send()
                    }
                } label: {
                    Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(RexColor.onBrand)
                        .frame(width: 38, height: 38)
                        .background(
                            canSend || isStreaming
                                ? AnyShapeStyle(RexColor.brandGradient)
                                : AnyShapeStyle(RexColor.tertiaryText.opacity(0.3)),
                            in: Circle()
                        )
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(!canSend && !isStreaming)
                .animation(RexMotion.quick, value: canSend)
                .accessibilityLabel(isStreaming ? "停止生成" : "发送")
            }
            .padding(.horizontal, RexSpacing.md)
            .padding(.vertical, RexSpacing.sm)
        }
        .background(.regularMaterial)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming
    }

    // MARK: - 时间分隔

    private func showsTime(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = messages[index - 1].createdAt
        return messages[index].createdAt.timeIntervalSince(previous) > timeGap
    }

    private func timeSeparator(_ date: Date) -> some View {
        Text(timeText(date))
            .font(RexFont.caption2)
            .foregroundStyle(RexColor.tertiaryText)
            .padding(.vertical, RexSpacing.xs)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    private func timeText(_ date: Date) -> String {
        let clock = date.formatted(.dateTime.hour().minute())
        if Calendar.current.isDateInToday(date) {
            return clock
        }
        if Calendar.current.isDateInYesterday(date) {
            return "昨天 \(clock)"
        }
        return "\(date.formatted(.dateTime.month().day())) \(clock)"
    }

    // MARK: - 发送

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, let apiClient else { return }

        input = ""
        isFocused = false
        statusText = ""
        isStreaming = true
        RexHaptics.tap()

        let userMessage = AssistantMessage(role: .user, text: text)
        messages.append(userMessage)
        let placeholder = AssistantMessage(role: .assistant, text: "", isLoading: true)
        messages.append(placeholder)

        let history = messages
            .filter { !$0.isLoading && !$0.text.isEmpty }
            .dropLast()
            .suffix(8)
            .map { AssistantHistoryTurn(role: $0.role.rawValue, content: $0.text) }

        streamTask = Task {
            do {
                for try await event in apiClient.assistantChatStream(
                    message: text,
                    history: Array(history)
                ) {
                    guard !Task.isCancelled else { return }
                    apply(event, to: placeholder.id)
                }
                isStreaming = false
                statusText = ""
            } catch {
                guard !Task.isCancelled else { return }
                isStreaming = false
                statusText = ""
                updateMessage(id: placeholder.id) { message in
                    message.text = "请求失败：\(error.localizedDescription)"
                    message.isLoading = false
                }
                showToast("助手调用失败")
            }
        }
    }

    private func apply(_ event: AssistantStreamEvent, to id: String) {
        switch event.kind {
        case .status(let text):
            statusText = text
        case .cards(let cards):
            updateMessage(id: id) { $0.cards = cards }
        case .done(let result):
            updateMessage(id: id) { message in
                message.text = result.reply
                message.cards = result.cards
                message.steps = result.steps
                message.isLoading = false
            }
            isStreaming = false
            statusText = ""
            if result.reply.isEmpty {
                showToast("这次没有拿到答案，换个问法试试")
            }
        case .failure(let message):
            updateMessage(id: id) { item in
                item.text = message
                item.isLoading = false
            }
            isStreaming = false
            statusText = ""
            showToast(message)
        }
    }

    private func stop() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        statusText = ""
        if let last = messages.last, last.isLoading {
            updateMessage(id: last.id) { message in
                message.text = message.text.isEmpty ? "已停止生成" : message.text
                message.isLoading = false
            }
        }
    }

    private func clearConversation() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        statusText = ""
        messages.removeAll()
        RexHaptics.success()
    }

    private func updateMessage(id: String, _ change: (inout AssistantMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        // 流式输出会连续触发，先取消上一次，避免叠加多个滚动任务。
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            withAnimation(RexMotion.standard) {
                if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func showToast(_ text: String) {
        toast = .warning(text)
    }
}

// MARK: - 消息模型

struct AssistantMessage: Identifiable {
    enum Role: String {
        case user
        case assistant
    }

    let id = UUID().uuidString
    let role: Role
    var text: String
    var cards: [AssistantCard] = []
    var steps: [AssistantStep] = []
    var isLoading = false
    let createdAt = Date()
}

// MARK: - 气泡

/// 单条消息：助手在左（头像 + 白气泡 + 资源卡），用户在右（品牌色气泡 + 头像）。
private struct AssistantMessageRow: View {
    let message: AssistantMessage
    var streaming: Bool
    var statusText: String
    var userName: String
    var avatarSelection: AvatarStore.Selection
    var onOpenURL: (URL) -> Void

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: RexSpacing.sm) {
            if isUser {
                Spacer(minLength: 56)
                bubble
                RexAvatar(name: userName, size: 36, selection: avatarSelection)
            } else {
                AssistantAvatar(size: 36)

                VStack(alignment: .leading, spacing: RexSpacing.sm) {
                    bubble

                    if !message.cards.isEmpty {
                        VStack(spacing: RexSpacing.sm) {
                            ForEach(message.cards) { card in
                                cardRow(card)
                            }
                        }
                        .frame(maxWidth: 420, alignment: .leading)
                    }
                }

                Spacer(minLength: 40)
            }
        }
    }

    @ViewBuilder
    private var bubble: some View {
        if isUser {
            Text(message.text)
                .font(RexFont.body)
                .foregroundStyle(RexColor.onBrand)
                .lineSpacing(3)
                .padding(.horizontal, RexSpacing.md + 2)
                .padding(.vertical, RexSpacing.sm + 2)
                .background(ChatBubbleBackground(isUser: true))
        } else {
            VStack(alignment: .leading, spacing: RexSpacing.sm) {
                if message.isLoading, message.text.isEmpty {
                    HStack(spacing: RexSpacing.sm) {
                        TypingDots()
                        Text(statusText.isEmpty ? "正在整理答案…" : statusText)
                            .font(RexFont.footnote)
                            .foregroundStyle(RexColor.secondaryText)
                            .lineLimit(2)
                    }
                } else if !message.text.isEmpty {
                    Text(message.text)
                        .font(RexFont.body)
                        .foregroundStyle(RexColor.primaryText)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 已经出字、仍在流式输出时，补一条轻量状态，避免用户以为卡住。
                if streaming, message.isLoading, !message.text.isEmpty {
                    HStack(spacing: 6) {
                        TypingDots()
                        if !statusText.isEmpty {
                            Text(statusText)
                                .font(RexFont.caption2)
                                .foregroundStyle(RexColor.tertiaryText)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, RexSpacing.md + 2)
            .padding(.vertical, RexSpacing.sm + 2)
            .background(ChatBubbleBackground(isUser: false))
            .frame(maxWidth: 420, alignment: .leading)
        }
    }

    private func cardRow(_ card: AssistantCard) -> some View {
        let url = card.openURL.flatMap(URL.init(string:))

        return Button {
            guard let url else { return }
            onOpenURL(url)
        } label: {
            HStack(spacing: RexSpacing.md) {
                MakerArtwork(card.cover.isEmpty ? nil : card.cover, width: 200)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        if card.cover.isEmpty {
                            Image(systemName: sourceSymbol(card.source))
                                .font(.system(.headline, weight: .medium))
                                .foregroundStyle(RexColor.brandBlue)
                                .frame(width: 48, height: 48)
                        }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(RexColor.primaryText)
                        .lineLimit(2)

                    let detail = [card.subtitle, card.meta]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")

                    if !detail.isEmpty {
                        Text(detail)
                            .font(RexFont.caption2)
                            .foregroundStyle(RexColor.tertiaryText)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                if url != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(RexColor.tertiaryText)
                }
            }
            .padding(RexSpacing.sm)
            .background(RexColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(url == nil)
    }

    private func sourceSymbol(_ source: String) -> String {
        switch source {
        case "magnet": "link"
        case "media": "film"
        case "av": "person.2.crop.square.stack"
        case "cloud": "cloud"
        case "web": "globe"
        case "stream": "play.rectangle"
        default: "tray.full"
        }
    }
}

/// 助手头像：品牌渐变圆 + 星芒。
private struct AssistantAvatar: View {
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle().fill(RexColor.brandGradient)

            Image(systemName: "sparkles")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 聊天气泡：靠近头像的上角收窄，形成微信式的指向。
private struct ChatBubbleBackground: View {
    var isUser: Bool

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: isUser ? 18 : 6,
            bottomLeadingRadius: 18,
            bottomTrailingRadius: isUser ? 6 : 18,
            topTrailingRadius: 18,
            style: .continuous
        )

        shape
            .fill(isUser ? AnyShapeStyle(RexColor.brandGradient) : AnyShapeStyle(RexColor.surface))
            .overlay {
                if !isUser {
                    shape.strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
                }
            }
    }
}

/// 三个依次呼吸的圆点，表示助手正在思考。
private struct TypingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(RexColor.tertiaryText)
                    .frame(width: 6, height: 6)
                    .opacity(animating ? 1 : 0.35)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever()
                            .delay(Double(index) * 0.16),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
        .accessibilityHidden(true)
    }
}
