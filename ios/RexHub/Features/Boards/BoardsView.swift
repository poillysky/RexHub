import SwiftUI
import UIKit

/// 色花堂板块：Hub（两大分区 · 14 板）→ 板内最新资源列表。
struct BoardsView: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var path: [BoardsRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                RexNavBar(
                    title: "板块",
                    leading: .back(action: { dismiss() }),
                    isScrolled: true
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: RexSpacing.xl) {
                        Text("色花堂")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(RexColor.primaryText)
                            .padding(.horizontal, RexSpacing.xl)

                        ForEach(ShtForumCatalog.categories) { category in
                            VStack(alignment: .leading, spacing: RexSpacing.sm) {
                                HStack(spacing: RexSpacing.sm) {
                                    Text(category.category)
                                        .font(RexFont.section)
                                        .foregroundStyle(RexColor.secondaryText)

                                    Text("\(category.boards.count)")
                                        .font(RexFont.caption2)
                                        .foregroundStyle(RexColor.tertiaryText)
                                }
                                .padding(.horizontal, RexSpacing.xl)

                                LazyVGrid(
                                    columns: [
                                        GridItem(.flexible(), spacing: RexSpacing.sm),
                                        GridItem(.flexible(), spacing: RexSpacing.sm)
                                    ],
                                    spacing: RexSpacing.sm
                                ) {
                                    ForEach(Array(category.boards.enumerated()), id: \.element.id) { index, board in
                                        BoardCard(board: board, tone: index % 3) {
                                            path.append(.board(board))
                                        }
                                    }
                                }
                                .padding(.horizontal, RexSpacing.xl)
                            }
                        }
                    }
                    .padding(.top, RexSpacing.md)
                    .padding(.bottom, RexSpacing.huge)
                    .frame(maxWidth: RexLayout.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .background(RexPageBackground())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: BoardsRoute.self) { route in
                switch route {
                case .board(let board):
                    BoardListView(board: board)
                        .toolbar(.hidden, for: .navigationBar)
                }
            }
        }
    }
}

private enum BoardsRoute: Hashable {
    case board(ShtForumBoard)
}

private struct BoardCard: View {
    let board: ShtForumBoard
    let tone: Int
    var action: () -> Void

    private var tint: Color {
        switch tone {
        case 0: RexColor.brandBlue
        case 1: Color(hex: 0x34C759)
        default: Color(hex: 0xAF52DE)
        }
    }

    var body: some View {
        Button {
            RexHaptics.tap()
            action()
        } label: {
            HStack(spacing: RexSpacing.md) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Text(String(board.name.prefix(1)))
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(tint)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(board.name)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(RexColor.primaryText)
                        .lineLimit(1)

                    Text(board.types.isEmpty ? "最新" : "\(board.types.count) 子板")
                        .font(RexFont.caption2)
                        .foregroundStyle(RexColor.tertiaryText)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, RexSpacing.md)
            .frame(minHeight: 62)
            .background(RexColor.surface, in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                    .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

// MARK: - 板内列表

private struct BoardListView: View {
    let board: ShtForumBoard

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    @State private var items: [BrowseItem] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var keyword = ""
    @State private var activeKeyword = ""
    @State private var alert: RexAlertInfo?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: board.name,
                leading: .back(action: { dismiss() }),
                isScrolled: true
            )

            searchField
                .padding(.horizontal, RexSpacing.xl)
                .padding(.bottom, RexSpacing.md)

            ScrollView {
                VStack(spacing: RexSpacing.md) {
                    if isLoading, items.isEmpty {
                        ForEach(0..<4, id: \.self) { _ in
                            RexSkeleton(width: .infinity, height: 92, cornerRadius: RexRadius.card)
                        }
                    } else if let errorText, items.isEmpty {
                        RexStateCard(
                            symbol: "wifi.exclamationmark",
                            title: "加载失败",
                            message: errorText,
                            tone: .warning,
                            actionTitle: "重试"
                        ) {
                            Task { await load(reset: true) }
                        }
                    } else if items.isEmpty {
                        RexStateCard(
                            symbol: "tray.full",
                            title: "暂无资源",
                            message: activeKeyword.isEmpty ? "这个板块还没有内容。" : "换个关键词试试。",
                            tone: .neutral
                        )
                    } else {
                        ForEach(items) { item in
                            BoardItemCard(item: item, onCopy: copy, onOffline: save)
                        }

                        if hasMore {
                            Button {
                                Task { await load(reset: false) }
                            } label: {
                                Text(isLoading ? "加载中…" : "加载更多")
                                    .font(.system(.subheadline, weight: .medium))
                                    .foregroundStyle(RexColor.brandBlue)
                                    .frame(minWidth: 120, minHeight: 44)
                            }
                            .buttonStyle(PressableButtonStyle())
                            .disabled(isLoading)
                        }
                    }
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.top, RexSpacing.sm)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: RexLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await load(reset: true) }
        }
        .background(RexPageBackground())
        .toolbar(.hidden, for: .navigationBar)
        .task { await load(reset: true) }
        .rexAlert($alert)
    }

    private var searchField: some View {
        HStack(spacing: RexSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(RexColor.secondaryText)

            TextField("在「\(board.name)」中搜索", text: $keyword)
                .font(RexFont.body)
                .foregroundStyle(RexColor.primaryText)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFocused)
                .onSubmit(commit)

            if !keyword.isEmpty {
                Button {
                    keyword = ""
                    activeKeyword = ""
                    Task { await load(reset: true) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(RexColor.tertiaryText)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空关键词")
            }
        }
        .padding(.horizontal, RexSpacing.md)
        .frame(height: 44)
        .background(RexColor.surface, in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                .strokeBorder(RexColor.fieldBorder, lineWidth: 0.75)
        }
    }

    private func commit() {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else {
            showToast("请输入至少 2 个字符", isError: false)
            return
        }
        isFocused = false
        activeKeyword = value
        Task { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard let apiClient, !isLoading else { return }
        if reset {
            page = 1
            hasMore = true
            errorText = nil
            items = []
        } else {
            guard hasMore else { return }
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await apiClient.browse(
                page: page,
                boardFid: board.fid,
                board: board.name,
                keyword: activeKeyword
            )
            if reset {
                items = result.resources
            } else {
                items.append(contentsOf: result.resources)
            }
            hasMore = result.hasMore
            if hasMore { page += 1 }
            errorText = nil
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            errorText = error.localizedDescription
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        RexHaptics.success()
        alert = .success("已复制链接")
    }

    private func save(_ link: String) async {
        guard let apiClient else { return }
        do {
            let result = try await apiClient.panTransfer(urls: [link])
            RexHaptics.success()
            if let failed = result.failed.first {
                alert = .failure(failed.message)
            } else {
                alert = .success(
                    APIClient.is115ShareLink(link) ? "已转存到网盘" : "已提交离线下载"
                )
            }
        } catch {
            RexHaptics.error()
            alert = .failure(error.localizedDescription)
        }
    }

    private func showToast(_ text: String, isError: Bool = true) {
        alert = isError ? .failure(text) : .notice(text)
    }
}

private struct BoardItemCard: View {
    let item: BrowseItem
    var onCopy: (String) -> Void
    var onOffline: (String) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            Text(item.title)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(3)

            HStack(spacing: RexSpacing.sm) {
                if !item.sizeText.isEmpty {
                    Text(item.sizeText)
                        .font(RexFont.caption2)
                        .foregroundStyle(RexColor.secondaryText)
                }
                if !item.createdAt.isEmpty {
                    Text(item.createdAt)
                        .font(RexFont.caption2)
                        .foregroundStyle(RexColor.tertiaryText)
                }
                if !item.boardName.isEmpty {
                    Text(item.boardName)
                        .font(RexFont.caption2)
                        .foregroundStyle(RexColor.tertiaryText)
                }
            }

            if !item.primaryLink.isEmpty {
                HStack(spacing: RexSpacing.sm) {
                    Button {
                        Task { await onOffline(item.primaryLink) }
                    } label: {
                        let isShare = APIClient.is115ShareLink(item.primaryLink)
                        Label(
                            isShare ? "转存" : "离线下载",
                            systemImage: isShare
                                ? "square.and.arrow.down"
                                : "arrow.down.to.line.compact"
                        )
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(RexColor.onBrand)
                        .padding(.horizontal, RexSpacing.md)
                        .frame(height: 30)
                        .background(RexColor.brandGradient, in: Capsule(style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())

                    Button {
                        onCopy(item.primaryLink)
                    } label: {
                        Text("复制")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(RexColor.primaryText)
                            .padding(.horizontal, RexSpacing.md)
                            .frame(height: 30)
                            .background(RexColor.field, in: Capsule(style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(RexSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rexCard()
    }
}
