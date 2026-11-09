import SwiftUI
import UIKit

/// AI 助手「小花」：流式对话，支持建议词、检索状态与资源卡片。
struct AssistantView: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var meta: AssistantMeta?
    @State private var messages: [AssistantMessage] = []
    @State private var input = ""
    @State private var isStreaming = false
    @State private var statusText = ""
    @State private var streamTask: Task<Void, Never>?
    @State private var alert: RexAlertInfo?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: "AI 助手",
                leading: .back(action: { dismiss() }),
                isScrolled: true
            )

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: RexSpacing.xl) {
                        if messages.isEmpty {
                            welcome
                        }

                        ForEach(messages) { message in
                            AssistantBubble(message: message, onOpenURL: { url in openURL(url) })
                                .id(message.id)
                        }

                        if isStreaming {
                            HStack(spacing: RexSpacing.sm) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(statusText.isEmpty ? "小花正在检索…" : statusText)
                                    .font(RexFont.footnote)
                                    .foregroundStyle(RexColor.secondaryText)
                            }
                            .padding(.horizontal, RexSpacing.xs)
                            .id("assistant-status")
                        }
                    }
                    .padding(.horizontal, RexSpacing.xl)
                    .padding(.top, RexSpacing.md)
                    .padding(.bottom, RexSpacing.xxl)
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
        .task { await loadMeta() }
        .onDisappear { streamTask?.cancel() }
        .rexAlert($alert)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: RexSpacing.lg) {
            VStack(alignment: .leading, spacing: RexSpacing.sm) {
                Text("你好，我是小花")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(RexColor.primaryText)

                Text("可以帮你找片、查资料、找磁力与网盘资源，需要时会直接给出可操作的结果。")
                    .font(RexFont.body)
                    .foregroundStyle(RexColor.secondaryText)
                    .lineSpacing(3)
            }

            if let chips = meta?.suggestChips, !chips.isEmpty {
                VStack(alignment: .leading, spacing: RexSpacing.sm) {
                    Text("试试这样问")
                        .font(RexFont.section)
                        .foregroundStyle(RexColor.secondaryText)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 120), spacing: RexSpacing.sm, alignment: .leading)],
                        alignment: .leading,
                        spacing: RexSpacing.sm
                    ) {
                        ForEach(chips, id: \.self) { chip in
                            Button {
                                input = chip
                                send()
                            } label: {
                                Text(chip)
                                    .font(.system(.footnote, weight: .medium))
                                    .foregroundStyle(RexColor.primaryText)
                                    .lineLimit(1)
                                    .padding(.horizontal, RexSpacing.md)
                                    .frame(height: 34)
                                    .background(RexColor.surface, in: Capsule(style: .continuous))
                                    .overlay {
                                        Capsule(style: .continuous)
                                            .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
                                    }
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                    }
                }
            }
        }
        .padding(.top, RexSpacing.lg)
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(RexColor.divider)
                .frame(height: 0.5)

            HStack(spacing: RexSpacing.sm) {
                TextField("问小花找片、问资料…", text: $input, axis: .vertical)
                    .font(RexFont.body)
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1...4)
                    .focused($isFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, RexSpacing.md)
                    .padding(.vertical, 10)
                    .frame(minHeight: 42)
                    .background(RexColor.field, in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous))

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
                        .frame(width: 42, height: 42)
                        .background(
                            canSend
                                ? AnyShapeStyle(RexColor.brandGradient)
                                : AnyShapeStyle(RexColor.tertiaryText.opacity(0.35)),
                            in: Circle()
                        )
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(!canSend && !isStreaming)
                .accessibilityLabel(isStreaming ? "停止生成" : "发送")
            }
            .padding(.horizontal, RexSpacing.xl)
            .padding(.vertical, RexSpacing.sm)
        }
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming
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
        case .done(let final):
            updateMessage(id: id) { message in
                message.text = final.reply
                message.cards = final.cards
                message.steps = final.steps
                message.isLoading = false
            }
            isStreaming = false
            statusText = ""
            if final.reply.isEmpty {
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

    private func updateMessage(id: String, _ change: (inout AssistantMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    private func loadMeta() async {
        guard let apiClient else { return }
        meta = try? await apiClient.assistantMeta()
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(RexMotion.standard) {
                if isStreaming {
                    proxy.scrollTo("assistant-status", anchor: .bottom)
                } else if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func showToast(_ text: String) {
        alert = .notice(text)
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
}

// MARK: - 气泡

private struct AssistantBubble: View {
    let message: AssistantMessage
    var onOpenURL: (URL) -> Void

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)

                Text(message.text)
                    .font(RexFont.body)
                    .foregroundStyle(RexColor.onBrand)
                    .lineSpacing(3)
                    .padding(.horizontal, RexSpacing.lg)
                    .padding(.vertical, RexSpacing.md)
                    .background(
                        RexColor.brandGradient,
                        in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                    )
            }
        } else {
            VStack(alignment: .leading, spacing: RexSpacing.md) {
                if message.isLoading, message.text.isEmpty {
                    HStack(spacing: RexSpacing.sm) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在整理答案…")
                            .font(RexFont.footnote)
                            .foregroundStyle(RexColor.secondaryText)
                    }
                } else if !message.text.isEmpty {
                    Text(message.text)
                        .font(RexFont.body)
                        .foregroundStyle(RexColor.primaryText)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !message.cards.isEmpty {
                    VStack(spacing: RexSpacing.sm) {
                        ForEach(message.cards) { card in
                            cardRow(card)
                        }
                    }
                }
            }
            .padding(RexSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .rexCard()
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
                                .font(.system(size: 18, weight: .medium))
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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(RexColor.tertiaryText)
                }
            }
            .padding(.vertical, RexSpacing.xs)
            .contentShape(Rectangle())
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
