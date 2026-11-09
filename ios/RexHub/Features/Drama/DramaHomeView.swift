import SwiftUI

/// 短剧 Hub：站点列表（对齐 PWA `/drama`），点站点进入目录。
struct DramaHomeView: View {
    @Environment(\.apiClient) private var apiClient

    @State private var sites: [DramaSite] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var path: [DramaRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                RexHubTitle(title: "短剧") {
                    EmptyView()
                }

                ScrollView {
                    VStack(spacing: RexSpacing.md) {
                        if isLoading {
                            ForEach(0..<4, id: \.self) { _ in
                                RexSkeleton(width: .infinity, height: 68, cornerRadius: RexRadius.card)
                            }
                        } else if let errorText {
                            RexStateCard(
                                symbol: "wifi.exclamationmark",
                                title: "站点加载失败",
                                message: errorText,
                                tone: .warning,
                                actionTitle: "重试"
                            ) {
                                Task { await loadSites() }
                            }
                        } else if sites.isEmpty {
                            RexStateCard(
                                symbol: "popcorn",
                                title: "暂无可用的短剧片源",
                                message: "请先在插件中心启用短剧插件。",
                                tone: .neutral
                            )
                        } else {
                            ForEach(Array(sites.enumerated()), id: \.element.id) { index, site in
                                DramaSiteCard(site: site, isHot: index == 0) {
                                    path.append(.site(site))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, RexSpacing.xl)
                    .padding(.top, RexSpacing.md)
                    .padding(.bottom, RexSpacing.huge)
                    .frame(maxWidth: RexLayout.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .refreshable { await loadSites() }
            }
            .background(RexPageBackground())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: DramaRoute.self) { route in
                switch route {
                case .site(let site):
                    DramaSiteView(site: site)
                        .toolbar(.hidden, for: .navigationBar)
                case .detail(let card):
                    DramaDetailView(card: card)
                        .toolbar(.hidden, for: .navigationBar)
                case .ranks(let site):
                    DramaRankView(site: site)
                        .toolbar(.hidden, for: .navigationBar)
                case .searchResults(let keyword, let site):
                    DramaSearchResultsView(keyword: keyword, site: site)
                        .toolbar(.hidden, for: .navigationBar)
                }
            }
        }
        .task { await loadSites() }
    }

    private func loadSites() async {
        guard let apiClient else {
            errorText = "登录状态已失效，请重新登录"
            isLoading = false
            return
        }
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            sites = try await apiClient.dramaSites().filter(\.enabled)
        } catch {
            if let apiError = error as? APIError, apiError == .cancelled { return }
            errorText = error.localizedDescription
        }
    }
}

// MARK: - 路由

enum DramaRoute: Hashable {
    case site(DramaSite)
    case detail(DramaCard)
    case ranks(String)
    case searchResults(String, String?)
}

// MARK: - 网格

struct DramaCardGrid: View {
    let cards: [DramaCard]

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var columns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 5 : 3
        return Array(repeating: GridItem(.flexible(), spacing: RexSpacing.md, alignment: .top), count: count)
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: RexSpacing.xl) {
            ForEach(cards) { card in
                NavigationLink(value: DramaRoute.detail(card)) {
                    DramaPosterCard(card: card)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityHint("查看短剧详情")
            }
        }
    }
}

/// 站点卡片：对齐 PWA `.drama-site-card`（品牌色左侧细条 / 渐变图标 / 徽标）。
struct DramaSiteCard: View {
    let site: DramaSite
    var isHot: Bool = false
    let action: () -> Void

    @Environment(\.apiClient) private var apiClient

    private var ui: DramaShortdramaUI? { site.ui?.shortdrama }
    private var hot: Bool { isHot || site.id == "rexhub.hongguo.video" }

    private var accent: Color {
        guard let hex = ui?.accent?.trimmingCharacters(in: .whitespaces), !hex.isEmpty else {
            return RexColor.brandBlue
        }
        var value = hex
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else {
            return RexColor.brandBlue
        }
        return Color(hex: number)
    }

    private var title: String {
        guard let title = ui?.title, !title.isEmpty else { return site.name }
        return title
    }

    private var subtitle: String {
        guard let subtitle = ui?.subtitle, !subtitle.isEmpty else { return "短剧片单 · 可直接播放" }
        return subtitle
    }

    var body: some View {
        Button {
            RexHaptics.tap()
            action()
        } label: {
            HStack(spacing: 14) {
                logo

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(RexColor.primaryText)
                            .lineLimit(1)

                        if let badge = ui?.badge, !badge.isEmpty {
                            Text(badge)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1)
                                .background(accent.opacity(0.13), in: Capsule())
                        }
                    }

                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(RexColor.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RexColor.tertiaryText)
                    .padding(4)
                    .background(accent.opacity(0.08), in: Circle())
            }
            .padding(.leading, 18)
            .padding(.trailing, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(RexColor.surface)
                    .overlay {
                        RadialGradient(
                            colors: [accent.opacity(0.09), .clear],
                            center: .leading,
                            startRadius: 0,
                            endRadius: 320
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(accent.opacity(0.18), lineWidth: 0.5)
            }
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent, accent.opacity(0.25)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3)
                    .padding(.vertical, 15)
            }
            .shadow(color: Color.black.opacity(0.07), radius: 13, y: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("\(title)，\(subtitle)")
        .accessibilityHint("进入短剧站点")
    }

    @ViewBuilder
    private var logo: some View {
        if let path = ui?.logo, !path.isEmpty, let url = logoURL(path) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                } else {
                    fallbackGlyph
                }
            }
            .frame(width: 44, height: 44)
        } else {
            fallbackGlyph
                .frame(width: 44, height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: hot
                                    ? [Color(hex: 0xFF5F45), Color(hex: 0xFF2D55)]
                                    : [accent, accent.opacity(0.62)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .shadow(color: accent.opacity(hot ? 0.28 : 0.18), radius: 8, y: 4)
        }
    }

    private var fallbackGlyph: some View {
        Image(systemName: "clapperboard")
            .font(.system(size: 21, weight: .regular))
            .foregroundStyle(.white)
    }

    private func logoURL(_ path: String) -> URL? {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        guard let base = apiClient?.baseURL.absoluteString else { return nil }
        return URL(string: base.hasSuffix("/") ? base + path : base + "/" + path)
    }
}

struct DramaPosterCard: View {
    let card: DramaCard
    var width: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay {
                    MakerArtwork(card.cover, width: 360)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
                }
                .overlay(alignment: .topTrailing) {
                    if card.episodeCount > 0 {
                        MakerBadge(text: "\(card.episodeCount) 集", tint: RexColor.brandBlue)
                            .padding(6)
                    }
                }
                .shadow(color: Color.black.opacity(0.16), radius: 8, y: 4)

            Text(card.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(card.title)
    }
}
