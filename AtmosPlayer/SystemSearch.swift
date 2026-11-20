import SwiftUI
import AppIntents
import CoreSpotlight
import UniformTypeIdentifiers

// MARK: - Routing from outside the app

/// Requests from Siri, Shortcuts, Spotlight and links: open a title, resume, or search.
/// The root view and the tabs carry them out (the app may still be starting when one arrives).
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    enum Request: Equatable {
        case title(MetaRef)
        case resumeLatest
        case search(String)
    }

    /// Bumped with every request, so the same one twice still runs.
    @Published private(set) var revision = 0
    private(set) var pending: Request?

    func open(_ ref: MetaRef) { send(.title(ref)) }
    func resume() { send(.resumeLatest) }
    func search(_ text: String) { send(.search(text)) }

    private func send(_ request: Request) {
        pending = request
        revision += 1
    }

    /// The request, once: whoever handles it takes it.
    func take() -> Request? {
        defer { pending = nil }
        return pending
    }
}

// MARK: - Spotlight

/// Your titles (My List, Continue Watching, your Stremio library) in iPhone search: tap one to
/// open its page here.
enum SpotlightIndex {
    private static let domain = "titles"

    @MainActor
    static func update(_ titles: [MetaRef]) {
        var seen = Set<String>()
        let unique = titles.filter { seen.insert($0.id).inserted }.prefix(400)
        let items = unique.enumerated().map { index, ref -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .movie)
            attributes.title = ref.name
            attributes.contentDescription = ref.type == "series" ? "Series" : "Movie"
            // A poster already in memory, for the first ones (encoding them all would be slow).
            if index < 60, let poster = ref.poster, let url = ArtworkURL.best(poster, maxPixel: 720),
               let image = ImagePipeline.shared.cached(url, maxPixel: 720) {
                attributes.thumbnailData = image.jpegData(compressionQuality: 0.7)
            }
            return CSSearchableItem(uniqueIdentifier: identifier(ref), domainIdentifier: domain, attributeSet: attributes)
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items) { error in
                if let error { LogStore.shared.append("Spotlight: \(error.localizedDescription)") }
            }
        }
    }

    /// "series|tt0903747|Breaking Bad".
    static func identifier(_ ref: MetaRef) -> String { "\(ref.type)|\(ref.id)|\(ref.name)" }

    static func ref(_ identifier: String) -> MetaRef? {
        let parts = identifier.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[1].isEmpty else { return nil }
        return MetaRef(id: parts[1], type: parts[0], name: parts[2], poster: nil)
    }
}

// MARK: - Siri and Shortcuts

struct ContinueWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Watching"
    static let description = IntentDescription("Resumes what you were last watching in Atmos Player.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.resume()
        return .result()
    }
}

struct SearchTitlesIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Movies and Series"
    static let description = IntentDescription("Opens Atmos Player's search with what you ask for.")
    static let openAppWhenRun = true

    @Parameter(title: "Title")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.search(query)
        return .result()
    }
}

struct AtmosShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ContinueWatchingIntent(),
                    phrases: ["Continue watching in \(.applicationName)", "Resume \(.applicationName)"],
                    shortTitle: "Continue Watching", systemImageName: "play.fill")
        AppShortcut(intent: SearchTitlesIntent(),
                    phrases: ["Search \(.applicationName)", "Find something in \(.applicationName)"],
                    shortTitle: "Search", systemImageName: "magnifyingglass")
    }
}
