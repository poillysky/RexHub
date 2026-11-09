import SwiftUI

/// 片商影片搜索：按番号或标题检索，可按中文字幕 / 磁力 / 可播放筛选。
struct MakerSearchView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all
        case subtitle
        case magnets
        case playable

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "全部"
            case .subtitle: "中文字幕"
            case .magnets: "有磁力"
            case .playable: "可播放"
            }
        }
    }

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    @State private var keyword = ""
    @State private var submitted = ""
    @State private var filter: Filter = .all
    @State private var movies: [MakerMovie] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var errorText: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: "搜索片商",
                leading: .back(action: { dismiss() }),
                isScrolled: true
            )

            searchField
                .padding(.horizontal, RexSpacing.xl)
                .padding(.bottom, RexSpacing.md)

            filterChips

            ScrollView {
                VStack(spacing: RexSpacing.xl) {
                    if isLoading, movies.isEmpty {
                        MakerCardSkeletons(posterWidth: 108, count: 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let errorText, movies.isEmpty {
                        RexStateCard(
                            symbol: "wifi.exclamationmark",
                            title: "搜索失败",
                            message: errorText,
                            tone: .warning,
                            actionTitle: "重试"
                        ) {
                            Task { await search(reset: true) }
                        }
                    } else if movies.isEmpty, !submitted.isEmpty {
                        RexStateCard(
                            symbol: "magnifyingglass",
                            title: "没有找到相关影片",
                            message: "换个番号或关键词试试。",
                            tone: .neutral
                        )
                    } else if submitted.isEmpty {
                        RexStateCard(
                            symbol: "text.magnifyingglass",
                            title: "搜索番号或标题",
                            message: "例如 ABP-123 或影片标题的一部分。",
                            tone: .brand
                        )
                    } else {
                        MakerMovieGrid(movies: movies)

                        if hasMore {
                            Button {
                                Task { await search(reset: false) }
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
        }
        .background(RexPageBackground())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { isFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: RexSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(RexColor.secondaryText)

            TextField("番号或标题", text: $keyword)
                .font(RexFont.body)
                .foregroundStyle(RexColor.primaryText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFocused)
                .onSubmit { Task { await search(reset: true) } }

            if !keyword.isEmpty {
                Button {
                    keyword = ""
                    submitted = ""
                    movies = []
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

    private var filterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: RexSpacing.sm) {
                ForEach(Filter.allCases) { item in
                    let selected = filter == item
                    Button {
                        guard !selected else { return }
                        RexHaptics.selection()
                        filter = item
                        if !submitted.isEmpty {
                            Task { await search(reset: true) }
                        }
                    } label: {
                        Text(item.title)
                            .font(.system(.footnote, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? RexColor.onBrand : RexColor.secondaryText)
                            .padding(.horizontal, RexSpacing.md)
                            .frame(height: 30)
                            .background(
                                selected ? AnyShapeStyle(RexColor.brandGradient) : AnyShapeStyle(RexColor.surface),
                                in: Capsule(style: .continuous)
                            )
                            .overlay {
                                if !selected {
                                    Capsule(style: .continuous)
                                        .strokeBorder(RexColor.cardBorder, lineWidth: 0.75)
                                }
                            }
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, RexSpacing.xl)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, RexSpacing.sm)
    }

    // MARK: - 数据

    private func search(reset: Bool) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let apiClient, !isLoading else { return }

        if reset {
            page = 1
            hasMore = true
            errorText = nil
            submitted = trimmed
        } else {
            guard hasMore else { return }
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await apiClient.makerMovieSearch(
                keyword: trimmed,
                page: page,
                filter: filter.rawValue
            )
            var seen = Set(movies.map(\.id))
            let fresh = response.items.filter { seen.insert($0.id).inserted }

            if reset {
                movies = fresh
            } else {
                movies.append(contentsOf: fresh)
            }
            hasMore = response.hasMore
            if hasMore { page += 1 }
            errorText = nil
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            errorText = error.localizedDescription
        }
    }
}
