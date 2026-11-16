import SwiftUI

// MARK: - Cinemeta, the curated source for Home

/// Home is built from Cinemeta (Stremio's own catalog, IMDb-backed) only, so it reads like a
/// storefront instead of a dump of every addon's lists.
enum Cinemeta {
    static let base = "https://v3-cinemeta.strem.io"

    static let movieGenres = ["Action", "Adventure", "Animation", "Biography", "Comedy", "Crime",
                              "Documentary", "Drama", "Family", "Fantasy", "History", "Horror",
                              "Mystery", "Romance", "Sci-Fi", "Sport", "Thriller", "War", "Western"]
    static let seriesGenres = movieGenres + ["Reality-TV"]

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 64 << 20)
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    static func catalogURL(type: String, id: String, genre: String? = nil, skip: Int = 0) -> URL? {
        var extras: [String] = []
        if let genre { extras.append("genre=\(genre.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? genre)") }
        if skip > 0 { extras.append("skip=\(skip)") }
        let tail = extras.isEmpty ? "" : "/" + extras.joined(separator: "&")
        return URL(string: "\(base)/catalog/\(type)/\(id)\(tail).json")
    }

    /// Catalog items, de-duplicated. Answers are also kept on disk so Home opens instantly.
    static func catalog(type: String, id: String, genre: String? = nil, skip: Int = 0) async -> [MetaPreview] {
        guard let url = catalogURL(type: type, id: id, genre: genre, skip: skip) else { return [] }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let items = decode(data) else {
            return []
        }
        if skip == 0 { HomeDiskCache.save(data, for: url) }
        return items
    }

    /// Title search (Cinemeta's "search" extra on its Popular catalog).
    static func search(type: String, _ text: String) async -> [MetaPreview] {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "\(base)/catalog/\(type)/top/search=\(encoded).json"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return decode(data) ?? []
    }

    static func cachedCatalog(type: String, id: String, genre: String? = nil) -> [MetaPreview]? {
        guard let url = catalogURL(type: type, id: id, genre: genre),
              let data = HomeDiskCache.load(for: url) else { return nil }
        return decode(data)
    }

    static func meta(type: String, id: String) async -> StremioMeta? {
        guard let url = URL(string: "\(base)/meta/\(type)/\(id).json"),
              let (data, _) = try? await session.data(from: url) else { return nil }
        return try? JSONDecoder().decode(CinemetaMetaResponse.self, from: data).meta
    }

    private static func decode(_ data: Data) -> [MetaPreview]? {
        guard let response = try? JSONDecoder().decode(CinemetaCatalogResponse.self, from: data) else { return nil }
        var seen = Set<String>()
        return response.metas.filter { seen.insert($0.id).inserted }
    }
}

private struct CinemetaCatalogResponse: Decodable {
    let metas: [MetaPreview]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        metas = c.lossyArray(MetaPreview.self, AnyKey("metas"))
    }
}

private struct CinemetaMetaResponse: Decodable {
    let meta: StremioMeta
}

/// Last answers for Home's catalogs, in Caches (iOS may clear it; Home then just loads).
enum HomeDiskCache {
    private static let folder: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("home-feed", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static func file(_ url: URL) -> URL {
        let name = url.absoluteString.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return folder.appendingPathComponent(String(name.suffix(120)) + ".json")
    }

    static func save(_ data: Data, for url: URL) { try? data.write(to: file(url), options: .atomic) }
    static func load(for url: URL) -> Data? { try? Data(contentsOf: file(url)) }
}

// MARK: - Feed

/// One row of Home.
struct HomeSection: Identifiable, Equatable {
    enum Style: Equatable { case ranked, wide, poster }

    let id: String
    let title: String
    let style: Style
    let items: [MetaPreview]
    /// Where "See All" goes, if anywhere.
    var seeAll: CatalogRoute? = nil
}

/// A full catalog page ("See All", a genre).
struct CatalogRoute: Hashable {
    let title: String
    let type: String
    let catalogId: String
    var genre: String? = nil
    /// Genre pages can switch between movies and series.
    var allowsTypeSwitch = false
}

/// Everything above and below Continue Watching / My List. Shared, so switching tabs never
/// reloads it, and seeded from disk, so it shows immediately on launch.
@MainActor
final class HomeFeed: ObservableObject {
    static let shared = HomeFeed()

    @Published private(set) var hero: [MetaPreview] = []
    @Published private(set) var top: [HomeSection] = []      // before My List
    @Published private(set) var rest: [HomeSection] = []     // after the genre chips
    @Published private(set) var suggestion: HomeSection?
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    private var lastLoad: Date?
    private var suggestionFor: String?

    private struct Spec {
        let id: String
        let title: String
        let style: HomeSection.Style
        let type: String
        let catalog: String
        var genre: String? = nil
        var seeAll: Bool = true
    }

    private static var year: String { String(Calendar.current.component(.year, from: Date())) }

    private static var topSpecs: [Spec] {
        [
            Spec(id: "top-movies", title: "Top 10 Movies Today", style: .ranked, type: "movie", catalog: "top"),
            Spec(id: "new-movies", title: "New Releases", style: .wide, type: "movie", catalog: "year", genre: Self.year),
            Spec(id: "top-series", title: "Top 10 Series Today", style: .ranked, type: "series", catalog: "top"),
            Spec(id: "new-series", title: "New Series", style: .wide, type: "series", catalog: "year", genre: Self.year),
        ]
    }

    private static var restSpecs: [Spec] {
        [
            Spec(id: "g-action", title: "Action & Adventure", style: .poster, type: "movie", catalog: "top", genre: "Action"),
            Spec(id: "g-comedy", title: "Comedies", style: .poster, type: "movie", catalog: "top", genre: "Comedy"),
            Spec(id: "acclaimed-series", title: "Acclaimed Series", style: .wide, type: "series", catalog: "imdbRating"),
            Spec(id: "g-scifi", title: "Sci-Fi Worlds", style: .poster, type: "movie", catalog: "top", genre: "Sci-Fi"),
            Spec(id: "g-thriller", title: "Edge-of-Your-Seat Thrillers", style: .poster, type: "movie", catalog: "top", genre: "Thriller"),
            Spec(id: "g-crime-series", title: "Crime Series", style: .poster, type: "series", catalog: "top", genre: "Crime"),
            Spec(id: "g-animation", title: "Animated Favourites", style: .poster, type: "movie", catalog: "top", genre: "Animation"),
            Spec(id: "acclaimed-movies", title: "Critically Acclaimed Films", style: .wide, type: "movie", catalog: "imdbRating"),
            Spec(id: "g-horror", title: "Horror Nights", style: .poster, type: "movie", catalog: "top", genre: "Horror"),
            Spec(id: "g-drama-series", title: "Binge-Worthy Dramas", style: .poster, type: "series", catalog: "top", genre: "Drama"),
            Spec(id: "g-romance", title: "Romance", style: .poster, type: "movie", catalog: "top", genre: "Romance"),
            Spec(id: "g-family", title: "Family Movie Night", style: .poster, type: "movie", catalog: "top", genre: "Family"),
            Spec(id: "g-docs", title: "Documentaries", style: .poster, type: "movie", catalog: "top", genre: "Documentary"),
        ]
    }

    private init() {
        // Seed from disk so the first frame already has the storefront.
        func seeded(_ specs: [Spec]) -> [HomeSection] {
            specs.compactMap { spec -> HomeSection? in
                guard let items = Cinemeta.cachedCatalog(type: spec.type, id: spec.catalog, genre: spec.genre) else {
                    return nil
                }
                return Self.section(spec, items)
            }
        }
        top = seeded(Self.topSpecs)
        rest = seeded(Self.restSpecs)
        let specs = Self.topSpecs
        hero = Self.heroItems(Self.heroPools { id in
            guard let spec = specs.first(where: { $0.id == id }) else { return [] }
            return Cinemeta.cachedCatalog(type: spec.type, id: spec.catalog, genre: spec.genre) ?? []
        })
    }

    var isEmpty: Bool { hero.isEmpty && top.isEmpty && rest.isEmpty }

    /// Loads everything at once and swaps it in together, so rows never jump around.
    func load(force: Bool = false) async {
        if !force, let lastLoad, Date().timeIntervalSince(lastLoad) < 30 * 60, !isEmpty { return }
        guard !loading else { return }
        loading = true
        defer { loading = false }

        let specs = Self.topSpecs + Self.restSpecs
        let results = await withTaskGroup(of: (String, [MetaPreview]).self) { group in
            for spec in specs {
                group.addTask {
                    (spec.id, await Cinemeta.catalog(type: spec.type, id: spec.catalog, genre: spec.genre))
                }
            }
            var out: [String: [MetaPreview]] = [:]
            for await (id, items) in group { out[id] = items }
            return out
        }

        let newTop = Self.topSpecs.compactMap { Self.section($0, results[$0.id] ?? []) }
        let newRest = Self.restSpecs.compactMap { Self.section($0, results[$0.id] ?? []) }
        guard !newTop.isEmpty || !newRest.isEmpty else {
            failed = isEmpty
            return
        }
        failed = false
        lastLoad = Date()
        let newHero = Self.heroItems(Self.heroPools { results[$0] ?? [] })
        withAnimation(.easeOut(duration: 0.25)) {
            if newHero.map(\.id) != hero.map(\.id) { hero = newHero }
            if newTop != top { top = newTop }
            if newRest != rest { rest = newRest }
        }
    }

    /// "Because You Watched …": popular titles sharing the main genre of the last thing watched.
    func loadSuggestion(from watched: WatchStore.Entry?) async {
        guard let watched, watched.ref.metaId.hasPrefix("tt") else { return }
        let ref = watched.ref
        guard suggestionFor != ref.metaId else { return }
        suggestionFor = ref.metaId
        let type = ref.type == "series" ? "series" : "movie"
        guard let meta = await Cinemeta.meta(type: type, id: ref.metaId) else { return }
        let genres = meta.genres
        guard let genre = genres.first(where: { $0 != "Drama" }) ?? genres.first else { return }
        let items = await Cinemeta.catalog(type: type, id: "top", genre: genre)
            .filter { $0.id != ref.metaId && $0.poster != nil }
        guard items.count >= 5 else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            suggestion = HomeSection(id: "because-\(ref.metaId)", title: "Because You Watched \(ref.name)",
                                     style: .poster, items: Array(items.prefix(20)),
                                     seeAll: CatalogRoute(title: genre, type: type, catalogId: "top", genre: genre,
                                                          allowsTypeSwitch: true))
        }
    }

    private static func section(_ spec: Spec, _ items: [MetaPreview]) -> HomeSection? {
        var list = items.filter { $0.poster != nil }
        switch spec.style {
        case .ranked: list = Array(list.prefix(10))
        case .wide: list = Array(list.filter { $0.background != nil }.prefix(16))
        case .poster: list = Array(list.prefix(20))
        }
        guard list.count >= 4 else { return nil }
        let seeAll: CatalogRoute? = spec.style == .ranked || !spec.seeAll ? nil
            : CatalogRoute(title: spec.title, type: spec.type, catalogId: spec.catalog, genre: spec.genre,
                           allowsTypeSwitch: false)
        return HomeSection(id: spec.id, title: spec.title, style: spec.style, items: list, seeAll: seeAll)
    }

    /// The hero: ten titles mixed from today's popular and newly released movies and series,
    /// only ones with a backdrop, a logo and a synopsis. The mix rotates every day, so the
    /// top of Home doesn't just repeat the Top 10 rows below it.
    private static func heroItems(_ pools: [[MetaPreview]]) -> [MetaPreview] {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        var seen = Set<String>()
        var lanes: [[MetaPreview]] = []
        for (index, pool) in pools.enumerated() {
            var lane: [MetaPreview] = []
            for item in pool where item.background != nil && item.logo != nil
                && !(item.description ?? "").isEmpty && lane.count < 12 {
                if seen.insert(item.id).inserted { lane.append(item) }
            }
            if lane.count > 1 {
                let shift = (day * (index + 3)) % lane.count
                lane = Array(lane[shift...] + lane[..<shift])
            }
            lanes.append(lane)
        }
        var out: [MetaPreview] = []
        var round = 0
        while out.count < 10 && lanes.contains(where: { round < $0.count }) {
            for lane in lanes where round < lane.count && out.count < 10 { out.append(lane[round]) }
            round += 1
        }
        return out
    }

    private static func heroPools(_ lookup: (String) -> [MetaPreview]) -> [[MetaPreview]] {
        [lookup("top-movies"), lookup("new-movies"), lookup("top-series"), lookup("new-series")]
    }
}
