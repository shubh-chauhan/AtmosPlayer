import Foundation

/// Storage shared by the app and its widgets (an App Group). The app writes Continue Watching
/// here; the widget only reads it.
enum SharedContainer {
    static let groupID = "group.com.atmosplayer.app"

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    static var artFolder: URL? { url?.appendingPathComponent("widget-art", isDirectory: true) }
    static var feedFile: URL? { url?.appendingPathComponent("continue-watching.json") }
}

/// One Continue Watching item as the widget shows it.
struct WidgetWatchItem: Codable, Hashable, Identifiable {
    /// The movie / episode id, used to resume it.
    let id: String
    let name: String
    let subtitle: String
    let progress: Double
    /// File name of its artwork in `SharedContainer.artFolder`.
    let artFile: String?

    /// Opens the app and resumes this item.
    var link: URL {
        var components = URLComponents()
        components.scheme = "atmosplayer"
        components.host = "resume"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url ?? URL(string: "atmosplayer://")!
    }
}

enum WidgetFeed {
    static func save(_ items: [WidgetWatchItem]) {
        guard let file = SharedContainer.feedFile, let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: file, options: .atomic)
    }

    static func load() -> [WidgetWatchItem] {
        guard let file = SharedContainer.feedFile, let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([WidgetWatchItem].self, from: data)) ?? []
    }

    /// True when the App Group is reachable (it isn't if the signing dropped the entitlement).
    static var available: Bool { SharedContainer.url != nil }
}
