import SwiftUI

/// 影视探索：对齐 PWA 探索页的数据源与筛选条件，结果用三列海报墙分页浏览。
struct MpExploreView: View {
    @Environment(\.apiClient) private var apiClient

    @State private var source: Source = .tmdb

    @State private var isMovie = true
    @State private var tmdbSort = "popularity.desc"
    @State private var tmdbGenre = ""
    @State private var tmdbLang = ""
    @State private var dbSort = "U"
    @State private var dbGenre = ""
    @State private var dbZone = ""
    @State private var bgmCat = ""
    @State private var bgmSort = "rank"
    @State private var alSort = "POPULARITY_DESC"
    @State private var alGenre = ""

    @State private var page = 1
    @State private var nonce = 0
    @State private var items: [MpItem] = []
    @State private var isLoading = false
    @State private var alert: RexAlertInfo?

    private enum Source: String, CaseIterable, Identifiable {
        case tmdb
        case douban
        case bangumi
        case anilist

        var id: String { rawValue }

        var title: String {
            switch self {
            case .tmdb: "TheMovieDb"
            case .douban: "豆瓣"
            case .bangumi: "Bangumi"
            case .anilist: "AniList"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RexSpacing.lg) {
            chipsRow(Source.allCases.map(\.title), selection: source.title) { title in
                guard let next = Source.allCases.first(where: { $0.title == title }) else { return }
                source = next
                reset()
            }

            filterCard

            HStack(spacing: RexSpacing.sm) {
                Text(summary)
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.secondaryText)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            resultGrid
            pager
        }
        .padding(.horizontal, RexSpacing.lg)
        .padding(.top, RexSpacing.sm)
        .task(id: requestKey) { await load() }
        .rexAlert($alert)
    }

    // MARK: - 筛选

    private var filterCard: some View {
        VStack(alignment: .leading, spacing: RexSpacing.md) {
            switch source {
            case .tmdb:
                filterRow("类型", options: ["电影", "电视剧"], value: isMovie ? "电影" : "电视剧") { title in
                    isMovie = title == "电影"
                    tmdbGenre = ""
                    reset()
                }
                filterRow("排序", options: tmdbSorts.map(\.title), value: title(of: tmdbSort, in: tmdbSorts)) { title in
                    tmdbSort = value(of: title, in: tmdbSorts) ?? tmdbSort
                    reset()
                }
                filterRow("风格", options: ["全部"] + tmdbGenres.map(\.title), value: title(of: tmdbGenre, in: tmdbGenres, fallback: "全部")) { title in
                    tmdbGenre = value(of: title, in: tmdbGenres) ?? ""
                    reset()
                }
                filterRow("语言", options: ["全部"] + Self.tmdbLangs.map(\.title), value: title(of: tmdbLang, in: Self.tmdbLangs, fallback: "全部")) { title in
                    tmdbLang = value(of: title, in: Self.tmdbLangs) ?? ""
                    reset()
                }
            case .douban:
                filterRow("类型", options: ["电影", "电视剧"], value: isMovie ? "电影" : "电视剧") { title in
                    isMovie = title == "电影"
                    reset()
                }
                filterRow("排序", options: Self.doubanSorts.map(\.title), value: title(of: dbSort, in: Self.doubanSorts)) { title in
                    dbSort = value(of: title, in: Self.doubanSorts) ?? dbSort
                    reset()
                }
                filterRow("风格", options: ["全部"] + Self.doubanGenres, value: dbGenre.isEmpty ? "全部" : dbGenre) { title in
                    dbGenre = title == "全部" ? "" : title
                    reset()
                }
                filterRow("地区", options: ["全部"] + Self.doubanZones, value: dbZone.isEmpty ? "全部" : dbZone) { title in
                    dbZone = title == "全部" ? "" : title
                    reset()
                }
            case .bangumi:
                filterRow("类型", options: Self.bangumiCats.map(\.title), value: title(of: bgmCat, in: Self.bangumiCats)) { title in
                    bgmCat = value(of: title, in: Self.bangumiCats) ?? ""
                    reset()
                }
                filterRow("排序", options: Self.bangumiSorts.map(\.title), value: title(of: bgmSort, in: Self.bangumiSorts)) { title in
                    bgmSort = value(of: title, in: Self.bangumiSorts) ?? bgmSort
                    reset()
                }
            case .anilist:
                filterRow("排序", options: Self.anilistSorts.map(\.title), value: title(of: alSort, in: Self.anilistSorts)) { title in
                    alSort = value(of: title, in: Self.anilistSorts) ?? alSort
                    reset()
                }
                filterRow("风格", options: ["全部"] + Self.anilistGenres.map(\.title), value: title(of: alGenre, in: Self.anilistGenres, fallback: "全部")) { title in
                    alGenre = value(of: title, in: Self.anilistGenres) ?? ""
                    reset()
                }
            }
        }
        .padding(RexSpacing.lg)
        .background(RexColor.surface, in: RoundedRectangle(cornerRadius: RexRadius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: RexRadius.panel, style: .continuous)
                .strokeBorder(RexColor.cardBorder, lineWidth: 1)
        }
    }

    private func filterRow(
        _ title: String,
        options: [String],
        value: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: RexSpacing.sm) {
            Text(title)
                .font(RexFont.caption)
                .foregroundStyle(RexColor.tertiaryText)
                .frame(width: 30, alignment: .leading)
                .padding(.top, 5)

            ScrollView(.horizontal) {
                HStack(spacing: RexSpacing.sm) {
                    ForEach(options, id: \.self) { option in
                        chip(option, selected: option == value) {
                            onSelect(option)
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func chipsRow(_ options: [String], selection: String, onSelect: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: RexSpacing.sm) {
                ForEach(options, id: \.self) { option in
                    chip(option, selected: option == selection) {
                        onSelect(option)
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(RexFont.caption)
                .foregroundStyle(selected ? RexColor.onBrand : RexColor.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    selected ? AnyShapeStyle(RexColor.brandGradient) : AnyShapeStyle(RexColor.field),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 结果

    private var resultGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: RexSpacing.md), count: 3),
            spacing: RexSpacing.lg
        ) {
            if items.isEmpty && isLoading {
                ForEach(0..<6, id: \.self) { _ in
                    Color.clear
                        .aspectRatio(2 / 3, contentMode: .fit)
                        .overlay {
                            RexSkeleton(cornerRadius: 10)
                        }
                }
            } else {
                ForEach(items) { item in
                    NavigationLink(value: MpRoute.detail(item)) {
                        MpPosterCard(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var pager: some View {
        HStack(spacing: RexSpacing.lg) {
            Button("上一页") {
                page = max(1, page - 1)
            }
            .disabled(page <= 1 || isLoading)

            Text("第 \(page) 页")
                .font(RexFont.caption)
                .foregroundStyle(RexColor.secondaryText)
                .monospacedDigit()

            Button("下一页") {
                page += 1
            }
            .disabled(items.isEmpty || isLoading)
        }
        .font(.system(.caption, weight: .semibold))
        .foregroundStyle(RexColor.brandBlue)
        .frame(maxWidth: .infinity)
        .padding(.top, RexSpacing.md)
        .padding(.bottom, RexSpacing.xl)
    }

    // MARK: - 请求

    private var requestKey: String {
        [
            source.rawValue,
            isMovie ? "movies" : "tvs",
            tmdbSort, tmdbGenre, tmdbLang,
            dbSort, dbGenre, dbZone,
            bgmCat, bgmSort, alSort, alGenre,
            String(page), String(nonce)
        ].joined(separator: "|")
    }

    private var kindPath: String {
        isMovie ? "movies" : "tvs"
    }

    private var tmdbSorts: [(title: String, value: String)] {
        isMovie ? Self.tmdbMovieSorts : Self.tmdbTVSorts
    }

    private var tmdbGenres: [(title: String, value: String)] {
        isMovie ? Self.tmdbMovieGenres : Self.tmdbTVGenres
    }

    private var summary: String {
        switch source {
        case .tmdb:
            [
                isMovie ? "电影" : "电视剧",
                title(of: tmdbSort, in: tmdbSorts),
                tmdbGenre.isEmpty ? "" : "已选风格",
                tmdbLang.isEmpty ? "" : "已选语言"
            ]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        case .douban:
            [isMovie ? "电影" : "电视剧", title(of: dbSort, in: Self.doubanSorts), dbGenre, dbZone]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        case .bangumi:
            ["动漫", title(of: bgmSort, in: Self.bangumiSorts), title(of: bgmCat, in: Self.bangumiCats)]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        case .anilist:
            ["动漫", title(of: alSort, in: Self.anilistSorts), title(of: alGenre, in: Self.anilistGenres)]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
    }

    private var request: (path: String, params: [String: String]) {
        switch source {
        case .tmdb:
            var params = ["page": String(page), "sort_by": tmdbSort]
            if !tmdbGenre.isEmpty { params["with_genres"] = tmdbGenre }
            if !tmdbLang.isEmpty { params["with_original_language"] = tmdbLang }
            return ("discover/tmdb_\(kindPath)", params)
        case .douban:
            let tags = [dbGenre, dbZone].filter { !$0.isEmpty }.joined(separator: ",")
            var params = ["page": String(page), "count": "30", "sort": dbSort]
            if !tags.isEmpty { params["tags"] = tags }
            return ("discover/douban_\(kindPath)", params)
        case .bangumi:
            var params = ["page": String(page), "count": "30", "type": "2", "sort": bgmSort]
            if !bgmCat.isEmpty { params["cat"] = bgmCat }
            return ("discover/bangumi", params)
        case .anilist:
            var params = ["page": String(page), "sort": alSort]
            if !alGenre.isEmpty { params["genre"] = alGenre }
            return ("anilist/discover", params)
        }
    }

    private func load() async {
        guard let apiClient else {
            alert = .failure("登录状态已失效，请重新登录", title: "加载失败")
            isLoading = false
            return
        }
        isLoading = true
        alert = nil
        defer { isLoading = false }
        do {
            let result = try await apiClient.mpList(path: request.path, params: request.params)
            items = result.items
        } catch {
            items = []
            alert = .failure((error as? APIError)?.errorDescription ?? error.localizedDescription, title: "加载失败")
        }
    }

    private func reset() {
        page = 1
        nonce += 1
    }

    // MARK: - 文案

    private func title(of value: String, in options: [(title: String, value: String)], fallback: String = "") -> String {
        guard !value.isEmpty else { return fallback }
        return options.first { $0.value == value }?.title ?? fallback
    }

    private func value(of title: String, in options: [(title: String, value: String)]) -> String? {
        options.first { $0.title == title }?.value
    }

    // MARK: - 常量（与 PWA 探索页一致）

    private static let tmdbMovieSorts: [(title: String, value: String)] = [
        ("热度降序", "popularity.desc"),
        ("热度升序", "popularity.asc"),
        ("上映日期降序", "release_date.desc"),
        ("上映日期升序", "release_date.asc"),
        ("评分降序", "vote_average.desc"),
        ("评分升序", "vote_average.asc")
    ]
    private static let tmdbTVSorts: [(title: String, value: String)] = [
        ("热度降序", "popularity.desc"),
        ("热度升序", "popularity.asc"),
        ("首播日期降序", "first_air_date.desc"),
        ("首播日期升序", "first_air_date.asc"),
        ("评分降序", "vote_average.desc"),
        ("评分升序", "vote_average.asc")
    ]
    private static let tmdbMovieGenres: [(title: String, value: String)] = [
        ("动作", "28"), ("冒险", "12"), ("动画", "16"), ("喜剧", "35"), ("犯罪", "80"),
        ("纪录", "99"), ("剧情", "18"), ("家庭", "10751"), ("奇幻", "14"), ("历史", "36"),
        ("恐怖", "27"), ("音乐", "10402"), ("悬疑", "9648"), ("爱情", "10749"), ("科幻", "878"),
        ("电视电影", "10770"), ("惊悚", "53"), ("战争", "10752"), ("西部", "37")
    ]
    private static let tmdbTVGenres: [(title: String, value: String)] = [
        ("动作冒险", "10759"), ("动画", "16"), ("喜剧", "35"), ("犯罪", "80"), ("纪录", "99"),
        ("剧情", "18"), ("家庭", "10751"), ("儿童", "10762"), ("悬疑", "9648"), ("新闻", "10763"),
        ("真人秀", "10764"), ("科幻奇幻", "10765"), ("肥皂剧", "10766"), ("脱口秀", "10767"),
        ("战争政治", "10768"), ("西部", "37")
    ]
    private static let tmdbLangs: [(title: String, value: String)] = [
        ("中文", "zh"), ("英语", "en"), ("日语", "ja"), ("韩语", "ko"), ("法语", "fr"),
        ("德语", "de"), ("西班牙语", "es"), ("意大利语", "it"), ("俄语", "ru"),
        ("葡萄牙语", "pt"), ("阿拉伯语", "ar"), ("印地语", "hi"), ("泰语", "th")
    ]

    private static let doubanSorts: [(title: String, value: String)] = [
        ("综合排序", "U"), ("最新", "R"), ("热度", "T"), ("最高分", "S")
    ]
    private static let doubanGenres: [String] = [
        "剧情", "喜剧", "动作", "爱情", "科幻", "动画", "悬疑", "惊悚", "恐怖", "犯罪",
        "同性", "音乐", "歌舞", "传记", "历史", "战争", "西部", "奇幻", "冒险", "灾难",
        "武侠", "情色"
    ]
    private static let doubanZones: [String] = ["华语", "欧美", "韩国", "日本"]

    private static let bangumiCats: [(title: String, value: String)] = [
        ("其他", ""), ("TV", "1"), ("OVA", "2"), ("剧场版", "3"), ("Web", "5")
    ]
    private static let bangumiSorts: [(title: String, value: String)] = [
        ("按排名", "rank"), ("按日期", "date")
    ]

    private static let anilistSorts: [(title: String, value: String)] = [
        ("热度", "POPULARITY_DESC"), ("趋势", "TRENDING_DESC"),
        ("评分", "SCORE_DESC"), ("最新", "START_DATE_DESC")
    ]
    private static let anilistGenres: [(title: String, value: String)] = [
        ("动作", "Action"), ("冒险", "Adventure"), ("喜剧", "Comedy"), ("剧情", "Drama"),
        ("奇幻", "Fantasy"), ("恐怖", "Horror"), ("魔法少女", "Mahou Shoujo"), ("机甲", "Mecha"),
        ("音乐", "Music"), ("悬疑", "Mystery"), ("心理", "Psychological"), ("恋爱", "Romance"),
        ("科幻", "Sci-Fi"), ("日常", "Slice of Life"), ("运动", "Sports"),
        ("超自然", "Supernatural"), ("惊悚", "Thriller")
    ]
}
