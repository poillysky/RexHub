import SwiftUI

/// 片商（AVDB）内的导航栈：列表、影片详情、搜索。
enum MakerRoute: Hashable {
    case search
    /// 带初始关键词的搜索（影片详情「搜索」）。
    case searchKey(String)
    /// 影片详情「资源搜索」：直接进服务端资源搜索结果列表（不走 AVDB 站内搜索）。
    case resourceSearch(String)
    case list(MakerListQuery)
    case movie(MakerMovie)
    case movieID(String)
    /// 影片全部评论。
    case movieReviews(id: String, title: String)
    case actors(MakerCategory)
    /// 分类入口：标签筛选 + 作品墙。
    case tags(MakerCategory)
    /// 演员详情：资料 + 作品墙。
    case actorDetail(id: String, name: String)
    /// 片商 / 导演 / 系列详情：实体头 + 作品墙。
    case entity(kind: MakerEntityKind, id: String, name: String)
}

/// 列表页的取数口径。
enum MakerListQuery: Hashable {
    case rank(MakerCategory, MakerPeriod)
    case latest(MakerCategory)
    case top(MakerCategory)
    case playback(MakerPeriod)
    case tag(MakerCategory, group: String, tagId: String, name: String)
    case actor(MakerCategory, actorID: String, name: String)
    /// 站内搜索命中的片单，直接看作品墙。
    case collection(id: String, name: String)

    var title: String {
        switch self {
        case .rank(let category, let period):
            "\(period.title)·\(category.title)"
        case .latest(let category):
            "最新·\(category.title)"
        case .top(let category):
            "TOP250·\(category.title)"
        case .playback(let period):
            "热播·\(period.playbackTitle)"
        case .tag(_, _, _, let name):
            name
        case .actor(_, _, let name):
            "演员 · \(name)"
        case .collection(_, let name):
            "片单 · \(name)"
        }
    }
}
