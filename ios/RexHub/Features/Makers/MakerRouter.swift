import SwiftUI

/// 片商（AVDB）内的导航栈：列表、影片详情、搜索。
enum MakerRoute: Hashable {
    case search
    case list(MakerListQuery)
    case movie(MakerMovie)
    case movieID(String)
    case actors(MakerCategory)
}

/// 列表页的取数口径。
enum MakerListQuery: Hashable {
    case rank(MakerCategory, MakerPeriod)
    case latest(MakerCategory)
    case top(MakerCategory)
    case playback(MakerPeriod)
    case tag(MakerCategory, group: String, tagId: String, name: String)
    case actor(MakerCategory, actorID: String, name: String)

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
        }
    }
}
