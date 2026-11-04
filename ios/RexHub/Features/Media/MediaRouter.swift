import SwiftUI

/// 影视页路由：海报墙、栏目网格、详情、搜索共用同一条 path。
///
/// 详情页里会从「相关推荐」再 push 详情，如果继续用各视图各自的
/// `navigationDestination(item:)`，同类型目的地在同一栈里重复声明会被系统
/// 忽略（后声明的绑定不生效），所以统一由首页这一处声明目的地。
@MainActor
@Observable
final class MediaRouter {
    var path: [MediaRoute] = []

    func push(_ route: MediaRoute) {
        path.append(route)
    }
}

enum MediaRoute: Hashable {
    case detail(MediaItem)
    case grid(MediaCatalog)
    case search(MediaSearchTarget)
}

/// 跳转搜索页的目标：带着影片标题和可搜索的来源。
struct MediaSearchTarget: Hashable {
    let keyword: String
    let sources: [SearchSource]
}
