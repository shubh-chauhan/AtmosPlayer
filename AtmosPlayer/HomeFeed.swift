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
        config.timeoutIntervalForRequest = 12
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
        guard let data = await MetaHTTP.data(url, session: session), let items = decode(data) else {
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
              let data = await MetaHTTP.data(url, session: session) else { return [] }
        return decode(data) ?? []
    }

    /// Full metadata (with every episode) for many series at once: Cinemeta's episode calendar.
    static func calendar(ids: [String]) async -> [StremioMeta] {
        guard !ids.isEmpty,
              let url = URL(string: "\(base)/catalog/series/calendar-videos/calendarVideosIds=\(ids.joined(separator: ",")).json"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(CinemetaCalendarResponse.self, from: data) else { return [] }
        return decoded.metas
    }

    static func cachedCatalog(type: String, id: String, genre: String? = nil) -> [MetaPreview]? {
        guard let url = catalogURL(type: type, id: id, genre: genre),
              let data = HomeDiskCache.load(for: url) else { return nil }
        return decode(data)
    }

    /// Nil when Cinemeta has no details under this type (it answers `{}`), or can't be reached
    /// after a retry.
    static func meta(type: String, id: String) async -> StremioMeta? {
        guard let url = URL(string: "\(base)/meta/\(type)/\(id).json"),
              let data = await MetaHTTP.data(url, session: session) else { return nil }
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

private struct CinemetaCalendarResponse: Decodable {
    let metas: [StremioMeta]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        metas = c.lossyArray(StremioMeta.self, AnyKey("metasDetailed"))
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
    enum Style: String, Codable, Hashable { case ranked, wide, poster }

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
    /// Any source other than Cinemeta (a TMDB list, an addon catalog); nil for Cinemeta's own.
    var source: CatalogSource? = nil
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

    /// One row of Home, as data: where its titles come from and how it looks.
    struct Spec: Codable, Hashable {
        let id: String
        let title: String
        let style: HomeSection.Style
        let source: CatalogSource
        var seeAll: Bool = true
        /// Its titles can be featured in the hero.
        var hero: Bool = false
    }

    private static var year: String { String(Calendar.current.component(.year, from: Date())) }

    /// Before My List (Top 10s and what's new) and after the genre tiles (everything else).
    /// TMDB's lists when the build has a TMDB token; Cinemeta's otherwise.
    static var topSpecs: [Spec] { TMDB.isConfigured ? tmdbTopSpecs : cinemetaTopSpecs }
    static var restSpecs: [Spec] { TMDB.isConfigured ? tmdbRestSpecs : cinemetaRestSpecs }

    static var cinemetaTopSpecs: [Spec] {
        [
            Spec(id: "top-movies", title: "Top 10 Movies Today", style: .ranked, source: .cinemeta(type: "movie", id: "top", genre: nil), hero: true),
            Spec(id: "new-movies", title: "New Releases", style: .wide, source: .cinemeta(type: "movie", id: "year", genre: Self.year), hero: true),
            Spec(id: "top-series", title: "Top 10 Series Today", style: .ranked, source: .cinemeta(type: "series", id: "top", genre: nil), hero: true),
            Spec(id: "new-series", title: "New Series", style: .wide, source: .cinemeta(type: "series", id: "year", genre: Self.year), hero: true),
        ]
    }

    static var cinemetaRestSpecs: [Spec] {
        [
            Spec(id: "g-action", title: "Action & Adventure", style: .poster, source: .cinemeta(type: "movie", id: "top", genre: "Action")),
            Spec(id: "g-comedy", title: "Comedies", style: .poster, source: .cinemeta(type: "movie", id: "top", genre: "Comedy")),
            Spec(id: "acclaimed-series", title: "Acclaimed Series", style: .wide, source: .cinemeta(type: "series", id: "imdbRating", genre: nil)),
            Spec(id: "g-scifi", title: "Sci-Fi Worlds", style: .poster, source: .cinemeta(type: "movie", id: "top", genre: "Sci-Fi")),
            Spec(id: "g-thriller", title: "Edge-of-Your-Seat Thrillers", style: .poster, source: .cinemeta(type: "movie", id: "top", genre: "Thriller")),
            Spec(id: "g-crime-series", title: "Crime Series", style: .poster, source: .cinemeta(type: "series", id: "top", genre: "Crime")),
            Spec(id: "g-animation", title: "Animated Favourites", style: .poster, source: .cinemeta(type: "movie", id: "top", genre: "Animation")),
            Spec(id: "acclaimed-movies", title: "Critically Acclaimed Films", style: .wide, source: .cinemeta(type: "movie", id: "imdbRating", genre: nil)),
            Spec(id: "g-horror", title: "Horror Nights", style: .poster, source: .cinemeta(type: "movie", id: "top", genre: "Horror")),
            Spec(id: "g-drama-series", title: "Binge-Worthy Dramas", style: .poster, source: .cinemeta(type: "series", id: "top", genre: "Drama")),
            Spec(id: "g-romance", title: "Romance", style: .poster, source: .cinemeta(type: "movie", id: "top", genre: "Romance")),
            Spec(id: "g-family", title: "Family Movie Night", style: .poster, source: .cinemeta(type: "movie", id: "top", genre: "Family")),
            Spec(id: "g-docs", title: "Documentaries", style: .poster, source: .cinemeta(type: "movie", id: "top", genre: "Documentary")),
        ]
    }

    /// TMDB discover queries share these: enough votes that a title is properly rated.
    private static func discover(_ kind: String, _ extra: [String: String]) -> CatalogSource {
        var query = ["sort_by": "popularity.desc", "vote_count.gte": "200", "include_adult": "false"]
        query.merge(extra) { _, new in new }
        return .tmdbDiscover(kind: kind, query: query)
    }

    static var tmdbTopSpecs: [Spec] {
        [
            Spec(id: "trending", title: "Trending Worldwide", style: .wide, source: .tmdbTrending(media: "all", window: "week"), hero: true),
            Spec(id: "top-movies", title: "Top 10 Movies Today", style: .ranked, source: .cinemeta(type: "movie", id: "top", genre: nil), hero: true),
            Spec(id: "top-series", title: "Top 10 Series Today", style: .ranked, source: .cinemeta(type: "series", id: "top", genre: nil), hero: true),
            Spec(id: "popular-movies", title: "Popular Movies", style: .poster, source: .tmdbList(kind: "movie", list: "popular")),
            Spec(id: "popular-series", title: "Popular Series", style: .poster, source: .tmdbList(kind: "tv", list: "popular")),
            // Hindi cinema: Cinemeta's lists are mostly Hollywood, so these come from TMDB by language.
            Spec(id: "bollywood-hits", title: "Bollywood Hits", style: .wide,
                 source: discover("movie", ["with_original_language": "hi", "vote_count.gte": "40",
                                            "primary_release_date.gte": Self.yearsAgo(4)]), hero: true),
            Spec(id: "bollywood-new", title: "New Hindi Releases", style: .poster,
                 source: discover("movie", ["with_original_language": "hi", "vote_count.gte": "3",
                                            "primary_release_date.gte": Self.monthsAgo(8),
                                            "primary_release_date.lte": Self.today])),
        ]
    }

    private static var today: String {
        ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
    }

    private static func monthsAgo(_ months: Int) -> String {
        let date = Calendar.current.date(byAdding: .month, value: -months, to: Date()) ?? Date()
        return ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate])
    }

    private static func yearsAgo(_ years: Int) -> String { monthsAgo(years * 12) }

    static var tmdbRestSpecs: [Spec] {
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        var list: [Spec] = [
            Spec(id: "acclaimed-movies", title: "Critically Acclaimed Movies", style: .wide, source: .tmdbList(kind: "movie", list: "top_rated")),
            Spec(id: "acclaimed-series", title: "Critically Acclaimed Series", style: .wide, source: .tmdbList(kind: "tv", list: "top_rated")),
            // Well rated, but seen by few: fewer votes than a hit gets.
            Spec(id: "hidden-gems", title: "Hidden Gems", style: .poster,
                 source: discover("movie", ["sort_by": "vote_average.desc", "vote_average.gte": "7.2",
                                            "vote_count.gte": "150", "vote_count.lte": "1500",
                                            "primary_release_date.gte": "1990-01-01", "without_genres": "99,10770"])),
            Spec(id: "recent", title: "Recently Released", style: .wide, source: .tmdbList(kind: "movie", list: "now_playing"), hero: true),
            Spec(id: "upcoming", title: "Coming Soon", style: .poster,
                 source: discover("movie", ["primary_release_date.gte": today, "sort_by": "popularity.desc",
                                            "vote_count.gte": "0", "with_release_type": "2|3"])),
        ]
        list += StreamingPlatform.all.prefix(4).map { platform in
            Spec(id: "originals-\(platform.id)", title: "\(platform.name) Originals", style: .poster, source: platform.originals)
        }
        list += [
            Spec(id: "g-scifi", title: "Sci-Fi & Fantasy", style: .poster, source: discover("movie", ["with_genres": "878|14"])),
            Spec(id: "g-crime", title: "Crime & Thriller", style: .poster, source: discover("movie", ["with_genres": "80|53"])),
            Spec(id: "g-action", title: "Action & Adventure", style: .poster, source: discover("movie", ["with_genres": "28|12"])),
            Spec(id: "bollywood-classics", title: "Bollywood Classics", style: .poster,
                 source: discover("movie", ["with_original_language": "hi", "sort_by": "vote_average.desc",
                                            "vote_count.gte": "300"])),
            Spec(id: "hindi-series", title: "Hindi Series", style: .poster,
                 source: discover("tv", ["with_original_language": "hi", "vote_count.gte": "15"])),
            Spec(id: "south-indian", title: "South Indian Blockbusters", style: .poster,
                 source: discover("movie", ["with_original_language": "ta|te|ml|kn", "vote_count.gte": "60",
                                            "primary_release_date.gte": Self.yearsAgo(5)])),
            Spec(id: "international", title: "International Cinema", style: .wide,
                 source: discover("movie", ["with_origin_country": "KR|JP|FR|ES|IN|IT|DE|DK|SE|MX|BR|CN|HK",
                                            "vote_count.gte": "500", "sort_by": "vote_average.desc"])),
            Spec(id: "g-comedy", title: "Comedies", style: .poster, source: .cinemeta(type: "movie", id: "top", genre: "Comedy")),
            Spec(id: "g-crime-series", title: "Crime Series", style: .poster, source: .cinemeta(type: "series", id: "top", genre: "Crime")),
            Spec(id: "g-animation", title: "Animated Favourites", style: .poster, source: .cinemeta(type: "movie", id: "top", genre: "Animation")),
            Spec(id: "g-horror", title: "Horror Nights", style: .poster, source: .cinemeta(type: "movie", id: "top", genre: "Horror")),
            Spec(id: "g-drama-series", title: "Binge-Worthy Dramas", style: .poster, source: .cinemeta(type: "series", id: "top", genre: "Drama")),
            Spec(id: "g-romance", title: "Romance", style: .poster, source: .cinemeta(type: "movie", id: "top", genre: "Romance")),
            Spec(id: "g-family", title: "Family Movie Night", style: .poster, source: .cinemeta(type: "movie", id: "top", genre: "Family")),
            Spec(id: "g-docs", title: "Documentaries", style: .poster, source: .cinemeta(type: "movie", id: "top", genre: "Documentary")),
        ]
        return list
    }

    private init() {
        // Seed from disk so the first frame already has the storefront.
        // shortcut: these small reads stay on the main thread so the first frame has rows;
        // move them off it if Home ever grows past a few dozen saved rows.
        var saved: [String: [MetaPreview]] = [:]
        for spec in Self.topSpecs + Self.restSpecs {
            if let items = spec.source.cached() { saved[spec.id] = items }
        }
        let (newTop, newRest) = Self.sections(saved)
        top = newTop
        rest = newRest
        hero = Self.heroItems(Self.heroPools { saved[$0] ?? [] })
        Task { await self.pruneHero() }
    }

    /// Titles whose backdrop would not load. They are left out of the hero, where they would
    /// show as an empty black page.
    private var artless: Set<String> = []

    private func pruneHero() async {
        let items = hero
        guard items.count > 3 else { return }
        var failed: Set<String> = []
        await withTaskGroup(of: (String, Bool).self) { group in
            for item in items {
                let id = item.id
                guard let url = ArtworkURL.best(item.background ?? item.poster, maxPixel: 320) else {
                    failed.insert(id)
                    continue
                }
                group.addTask { (id, await ImagePipeline.shared.image(url, maxPixel: 320) != nil) }
            }
            for await (id, loaded) in group where !loaded { failed.insert(id) }
        }
        // Most of them failing means the network is down, not that the artwork is missing.
        guard !failed.isEmpty, failed.count * 2 < items.count else { return }
        artless.formUnion(failed)
        let kept = hero.filter { !artless.contains($0.id) }
        if kept.count != hero.count {
            withAnimation(.easeOut(duration: 0.25)) { hero = kept }
        }
    }

    var isEmpty: Bool { hero.isEmpty && top.isEmpty && rest.isEmpty }

    /// Loads everything at once and swaps it in together, so rows never jump around.
    func load(force: Bool = false) async {
        if !force, let lastLoad, Date().timeIntervalSince(lastLoad) < 30 * 60, !isEmpty { return }
        guard !loading else { return }
        loading = true
        defer { loading = false }

        var results = await Self.fetch(Self.topSpecs + Self.restSpecs)
        // TMDB unreachable (or the token rejected): Cinemeta's rows instead, so Home isn't bare.
        if TMDB.isConfigured,
           (Self.topSpecs + Self.restSpecs).filter(\.source.needsTMDB).allSatisfy({ (results[$0.id] ?? []).isEmpty }) {
            results.merge(await Self.fetch(Self.cinemetaTopSpecs + Self.cinemetaRestSpecs.filter { results[$0.id] == nil || results[$0.id]!.isEmpty })) { old, new in old.isEmpty ? new : old }
            usingFallback = true
        } else {
            usingFallback = false
        }

        let (newTop, newRest) = Self.sections(results, fallback: usingFallback)
        guard !newTop.isEmpty || !newRest.isEmpty else {
            failed = isEmpty
            return
        }
        failed = false
        lastLoad = Date()
        let newHero = Self.heroItems(Self.heroPools { results[$0] ?? [] }).filter { !artless.contains($0.id) }
        withAnimation(.easeOut(duration: 0.25)) {
            if newHero.map(\.id) != hero.map(\.id) { hero = newHero }
            if newTop != top { top = newTop }
            if newRest != rest { rest = newRest }
        }
        await pruneHero()
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

    /// Set when TMDB answered nothing and Cinemeta's rows stand in.
    private var usingFallback = false

    /// Every row's first page at once (TMDB's through its own request gate).
    private static func fetch(_ specs: [Spec]) async -> [String: [MetaPreview]] {
        await withTaskGroup(of: (String, [MetaPreview]).self) { group in
            for spec in specs {
                group.addTask { @MainActor in (spec.id, await spec.source.load()) }
            }
            var out: [String: [MetaPreview]] = [:]
            for await (id, items) in group { out[id] = items }
            return out
        }
    }

    /// The rows in order, each title shown in at most one row: a title already in an earlier
    /// row is left out of later ones, unless that would leave a row too short (the Top 10s
    /// keep their full lists either way).
    static func sections(_ results: [String: [MetaPreview]], fallback: Bool = false) -> ([HomeSection], [HomeSection]) {
        let topSpecs = fallback ? cinemetaTopSpecs : Self.topSpecs
        let restSpecs = fallback ? cinemetaRestSpecs : Self.restSpecs
        var seen = Set<String>()
        func build(_ specs: [Spec]) -> [HomeSection] {
            specs.compactMap { spec -> HomeSection? in
                let all = results[spec.id] ?? []
                // Drop titles shown above before the row is capped, so the cap doesn't eat its fresh ones.
                let fresh = spec.style == .ranked ? nil : Self.section(spec, all.filter { !seen.contains($0.id) })
                guard let row = (fresh?.items.count ?? 0) >= 8 ? fresh : Self.section(spec, all) else { return nil }
                seen.formUnion(row.items.map(\.id))
                return row
            }
        }
        let top = build(topSpecs)
        return (top, build(restSpecs))
    }

    private static func section(_ spec: Spec, _ items: [MetaPreview]) -> HomeSection? {
        // IMDb titles without art of their own still get MetaHub's or TMDB's on the card.
        var list = items.filter { $0.poster != nil || $0.id.hasPrefix("tt") }
        switch spec.style {
        case .ranked: list = Array(list.prefix(10))
        case .wide: list = Array(list.filter { $0.background != nil || $0.id.hasPrefix("tt") }.prefix(16))
        case .poster: list = Array(list.prefix(20))
        }
        guard list.count >= 4 else { return nil }
        let seeAll: CatalogRoute?
        if spec.style == .ranked || !spec.seeAll {
            seeAll = nil
        } else if case let .cinemeta(type, id, genre) = spec.source {
            seeAll = CatalogRoute(title: spec.title, type: type, catalogId: id, genre: genre, allowsTypeSwitch: false)
        } else {
            seeAll = CatalogRoute(title: spec.title, type: "", catalogId: "", source: spec.source)
        }
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
        (topSpecs + restSpecs).filter(\.hero).map { lookup($0.id) }
    }
}
