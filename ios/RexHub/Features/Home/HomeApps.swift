import Foundation
import Observation

// MARK: - 应用条目

/// 首页宫格与「全部应用」共用的应用条目。
///
/// 内置应用用品牌色方块 + SF Symbol，115 用资源包里的方形品牌图，
/// 短剧源生成的站点入口用服务端声明的远程 logo。
struct HomeAppItem: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let accent: RexBrandColor
    let action: HomeAction
    /// 资源包里的方形品牌图（如 115）。
    var brandImage: String? = nil
    /// 内容源声明的远程 logo。
    var logoURL: URL? = nil
}

extension HomeAppItem {
    /// 内置应用；只有 115 网盘，其余入口都由服务管理里的内容源生成。
    static let builtin: [HomeAppItem] = [
        HomeAppItem(
            id: "pan115",
            title: "115网盘",
            symbol: "externaldrive",
            accent: .blue,
            action: .page(.panAccount),
            brandImage: "Brand115"
        )
    ]

    /// 首页默认应用的固定部分：短剧入口在加载完成后再补齐。
    static let baseHomeIDs: [String] = builtin.map(\.id)

    /// 少数站点用本地成品图标：红果是反色渐变版，其余原始 logo 留白/尺寸不一，
    /// 统一按 115 的可见内容尺寸（56pt）重制，避免宫格里大小不一。
    static let brandIcons: [String: String] = [
        "rexhub.hongguo.video": "DramaIconHongguo",
        "rexhub.yeguo.video": "DramaIconYeguo",
        "rexhub.huangguo.video": "DramaIconHuangguo",
        "rexhub.huangdou.video": "DramaIconHuangdou"
    ]

    /// 短剧源站点转成可展示的应用入口。
    init(drama site: DramaSite, client: APIClient?) {
        let ui = site.ui?.shortdrama
        let uiTitle = ui?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        id = "drama.\(site.id)"
        title = uiTitle.isEmpty ? (site.name.isEmpty ? "短剧" : site.name) : uiTitle
        symbol = "clapperboard"
        accent = .pink
        action = .drama(site)
        brandImage = Self.brandIcons[site.id]
        logoURL = ui?.logo.flatMap { client?.remoteAssetURL($0) }
    }
}

// MARK: - 应用配置

/// 首页应用配置：哪些应用出现在宫格，与内置应用 / 短剧源入口合并成「所有应用」。
@MainActor
@Observable
final class HomeAppsStore {
    static let shared = HomeAppsStore()

    private enum Key {
        static let homeIDs = "rexhub.home.apps"
        static let version = "rexhub.home.apps.version"
        static let customized = "rexhub.home.apps.customized"
    }

    /// 配置版本：v1 的内置应用过多，v2 起首页只保留 115 与短剧入口。
    private static let currentVersion = 2

    private let defaults = UserDefaults.standard

    private(set) var dramaApps: [HomeAppItem] = []
    private(set) var homeAppIDs: [String]
    /// 用户手动增删过首页应用后，默认值不再覆盖他的选择。
    private var isCustomized: Bool

    private init() {
        if defaults.integer(forKey: Key.version) < Self.currentVersion {
            homeAppIDs = HomeAppItem.baseHomeIDs
            isCustomized = false
            defaults.set(Self.currentVersion, forKey: Key.version)
            defaults.set(false, forKey: Key.customized)
            defaults.set(homeAppIDs, forKey: Key.homeIDs)
        } else {
            homeAppIDs = defaults.stringArray(forKey: Key.homeIDs) ?? HomeAppItem.baseHomeIDs
            isCustomized = defaults.bool(forKey: Key.customized)
        }
    }

    /// 所有可展示的应用：内置在前，短剧源入口在后。
    var allApps: [HomeAppItem] {
        HomeAppItem.builtin + dramaApps
    }

    /// 首页当前展示的应用，按用户配置顺序取。
    var homeApps: [HomeAppItem] {
        let lookup = Dictionary(allApps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return homeAppIDs.compactMap { lookup[$0] }
    }

    func isOnHome(_ app: HomeAppItem) -> Bool {
        homeAppIDs.contains(app.id)
    }

    func toggle(_ app: HomeAppItem) {
        if let index = homeAppIDs.firstIndex(of: app.id) {
            homeAppIDs.remove(at: index)
        } else {
            homeAppIDs.append(app.id)
        }
        markCustomized()
        persist()
    }

    func removeFromHome(_ app: HomeAppItem) {
        guard let index = homeAppIDs.firstIndex(of: app.id) else { return }
        homeAppIDs.remove(at: index)
        markCustomized()
        persist()
    }

    /// 编辑页「保存」：用草稿整体替换首页应用，顺带去重，保证一个应用只出现一次。
    func setHomeApps(_ ids: [String]) {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        guard unique != homeAppIDs else { return }
        homeAppIDs = unique
        markCustomized()
        persist()
    }

    /// 拉取服务管理里配置的短剧源入口。
    /// 只影响「全部应用」的可用列表，是否上首页由用户自己配置。
    func reload(client: APIClient?) async {
        guard let client else { return }
        await loadDramaApps(client: client)
    }

    /// 拉取短剧源生成的入口；失败时保留内置应用，不影响首页。
    private func loadDramaApps(client: APIClient) async {
        do {
            let sites = try await client.dramaSites().filter(\.enabled)
            dramaApps = sites.map { HomeAppItem(drama: $0, client: client) }
            syncHomeApps()
        } catch {
            // 静默失败：短剧入口只是锦上添花。
        }
    }

    /// 未自定义时首页默认展示「115 + 全部短剧」；自定义过则只清掉旧版本遗留的失效 id。
    private func syncHomeApps() {
        let validIDs = Set(allApps.map(\.id))

        if isCustomized {
            let pruned = homeAppIDs.filter { validIDs.contains($0) }
            if pruned != homeAppIDs {
                homeAppIDs = pruned
                persist()
            }
        } else {
            // 短剧源入口只进「全部应用」，默认首页仍保持 115 + 短剧。
            let desired = HomeAppItem.builtin.map(\.id) + dramaApps.map(\.id)
            if desired != homeAppIDs {
                homeAppIDs = desired
                persist()
            }
        }
    }

    private func markCustomized() {
        guard !isCustomized else { return }
        isCustomized = true
        defaults.set(true, forKey: Key.customized)
    }

    private func persist() {
        defaults.set(homeAppIDs, forKey: Key.homeIDs)
    }
}
