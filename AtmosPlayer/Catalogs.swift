import Foundation

// MARK: - Catalog sources
//
// Where a row of titles comes from. Home's rows and the "See All" pages are data (a source, a
// title, a style), so a row can come from Cinemeta, an installed addon or TMDB without its own
// view code. Every source hands back MetaPreviews under IMDb ids, so tapping a title opens the
// same title page and finds streams the same way, whatever listed it.

enum CatalogSource: Codable, Hashable {
    /// Cinemeta's own catalogs ("top", "imdbRating", "year"), optionally by genre.
    case cinemeta(type: String, id: String, genre: String?)
    /// An installed addon's catalog, with a genre if the addon lists genres for it.
    case addon(addonId: String, type: String, catalog: String, genre: String?)
    /// TMDB trending: media "all", "movie" or "tv"; window "day" or "week".
    case tmdbTrending(media: String, window: String)
    /// TMDB lists: kind "movie"/"tv"; list "popular", "top_rated", "now_playing", "upcoming",
    /// "airing_today", "on_the_air".
    case tmdbList(kind: String, list: String)
    /// TMDB discover with its own query (genres, countries, languages, votes, providers…).
    case tmdbDiscover(kind: String, query: [String: String])

    var isCinemeta: Bool {
        if case .cinemeta = self { return true }
        return false
    }

    var needsTMDB: Bool {
        switch self {
        case .cinemeta, .addon: return false
        default: return true
        }
    }

    /// How long a saved first page counts as fresh. shortcut: fixed per kind of list, not
    /// user-configurable yet.
    var ttl: TimeInterval {
        switch self {
        case .tmdbTrending: return 3600
        case .tmdbList(_, let list): return list == "now_playing" || list == "airing_today" ? 3 * 3600 : 6 * 3600
        case .tmdbDiscover: return 12 * 3600
        case .cinemeta, .addon: return 30 * 60
        }
    }

    /// Stable name for its saved first page.
    var cacheKey: String {
        switch self {
        case let .cinemeta(type, id, genre): return "cinemeta/\(type)/\(id)/\(genre ?? "")"
        case let .addon(addonId, type, catalog, genre): return "addon/\(addonId)/\(type)/\(catalog)/\(genre ?? "")"
        case let .tmdbTrending(media, window): return "tmdb/trending/\(media)/\(window)"
        case let .tmdbList(kind, list): return "tmdb/list/\(kind)/\(list)"
        case let .tmdbDiscover(kind, query):
            return "tmdb/discover/\(kind)/" + query.keys.sorted().map { "\($0)=\(query[$0] ?? "")" }.joined(separator: "&")
        }
    }

    /// The saved first page, however old, for showing on the first frame.
    func cached() -> [MetaPreview]? {
        if case let .cinemeta(type, id, genre) = self { return Cinemeta.cachedCatalog(type: type, id: id, genre: genre) }
        return CatalogCache.load(cacheKey)?.items
    }

    /// The items after the first `count` (0 for the first page). Empty when there are no more,
    /// the source can't page, or it can't be reached.
    @MainActor
    func load(after count: Int = 0, addons: [InstalledAddon] = []) async -> [MetaPreview] {
        // Cinemeta's own answers go through the HTTP cache and HomeDiskCache instead.
        if count == 0, !isCinemeta,
           let saved = CatalogCache.load(cacheKey), Date().timeIntervalSince(saved.savedAt) < ttl {
            return saved.items
        }
        let items: [MetaPreview]
        switch self {
        case let .cinemeta(type, id, genre):
            return await Cinemeta.catalog(type: type, id: id, genre: genre, skip: count)
        case let .addon(addonId, type, catalogId, genre):
            guard let addon = addons.first(where: { $0.id == addonId }),
                  let catalog = addon.manifest.catalogs.first(where: { $0.type == type && $0.id == catalogId }),
                  count == 0 || catalog.supportsSkip else { return [] }
            items = (try? await StremioClient.catalog(addon, catalog, genre: genre, skip: count, timeout: 15)) ?? []
        case let .tmdbTrending(media, window):
            items = await TMDBCatalog.page("/trending/\(media)/\(window)", [:], page: count / 20 + 1, kind: nil)
        case let .tmdbList(kind, list):
            items = await TMDBCatalog.page("/\(kind)/\(list)", [:], page: count / 20 + 1, kind: kind)
        case let .tmdbDiscover(kind, query):
            items = await TMDBCatalog.page("/discover/\(kind)", query, page: count / 20 + 1, kind: kind)
        }
        if count == 0, !items.isEmpty { CatalogCache.save(cacheKey, items) }
        return items
    }
}

// MARK: - Saved first pages

/// First pages of non-Cinemeta rows, in Caches (Cinemeta's own are in `HomeDiskCache`).
enum CatalogCache {
    struct Saved: Codable {
        let items: [MetaPreview]
        let savedAt: Date
    }

    private static let folder: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("catalogs-v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static func file(_ key: String) -> URL {
        let name = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return folder.appendingPathComponent(String(name.suffix(150)) + ".json")
    }

    static func load(_ key: String) -> Saved? {
        guard let data = try? Data(contentsOf: file(key)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let saved = try? decoder.decode(Saved.self, from: data),
              // TMDB data is never kept past six months.
              Date().timeIntervalSince(saved.savedAt) < MetaCachePolicy.current.maximumAge else { return nil }
        return saved
    }

    static func save(_ key: String, _ items: [MetaPreview]) {
        let url = file(key)
        let saved = Saved(items: items, savedAt: Date())
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            if let data = try? encoder.encode(saved) { try? data.write(to: url, options: .atomic) }
        }
    }
}

// MARK: - TMDB lists

enum TMDBCatalog {
    private struct Page: Decodable {
        let results: [LossyElement<Item>]
    }

    private struct Item: Decodable {
        let id: Int
        let title: String?
        let name: String?
        let media_type: String?
        let poster_path: String?
        let backdrop_path: String?
        let overview: String?
        let release_date: String?
        let first_air_date: String?
        let genre_ids: [Int]?
        let vote_average: Double?
        let vote_count: Int?
        let popularity: Double?
        let original_language: String?
    }

    /// One page of a TMDB list as MetaPreviews under IMDb ids. Titles TMDB has no IMDb id
    /// for are left out: addons find streams by IMDb id.
    @MainActor
    static func page(_ path: String, _ query: [String: String], page: Int, kind: String?) async -> [MetaPreview] {
        await candidates(path, query, page: page, kind: kind).map(\.preview)
    }

    /// The same, with TMDB's votes, popularity and language kept for ranking.
    @MainActor
    static func candidates(_ path: String, _ query: [String: String], page: Int, kind: String?) async -> [Candidate] {
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "language", value: TMDB.language))
        items.append(URLQueryItem(name: "page", value: String(page)))
        guard let data = await TMDB.get(path, items),
              let decoded = try? JSONDecoder().decode(Page.self, from: data) else { return [] }
        let list: [(Item, IDMap.TMDBRef)] = decoded.results.compactMap(\.value).compactMap { item in
            let media = kind ?? item.media_type
            guard media == "movie" || media == "tv" else { return nil }   // trending/all also lists people
            return (item, IDMap.TMDBRef(kind: media == "tv" ? .tv : .movie, id: item.id))
        }
        let imdb = await imdbIds(list.map(\.1))
        return list.compactMap { item, ref -> Candidate? in
            guard let id = imdb[ref], let name = item.title ?? item.name, item.poster_path != nil else { return nil }
            let date = item.release_date ?? item.first_air_date ?? ""
            let preview = MetaPreview(
                id: id, type: ref.kind == .tv ? "series" : "movie", name: name,
                poster: TMDB.Details.image(item.poster_path, size: "w500"),
                background: TMDB.Details.image(item.backdrop_path, size: "w1280"),
                logo: ArtworkURL.logo(forMetaId: id),
                description: item.overview.flatMap { $0.isEmpty ? nil : $0 },
                releaseInfo: date.count >= 4 ? String(date.prefix(4)) : nil,
                imdbRating: nil,
                genres: TMDBGenres.names(item.genre_ids ?? [], tv: ref.kind == .tv),
                runtime: nil, trailerId: nil)
            return Candidate(preview: preview, voteAverage: item.vote_average ?? 0, voteCount: item.vote_count ?? 0,
                             popularity: item.popularity ?? 0, language: item.original_language)
        }
    }

    /// IMDb ids for TMDB titles: the saved map first, then TMDB's external ids for the rest
    /// (a few at a time, through TMDB's gate), remembered for next time.
    @MainActor
    static func imdbIds(_ refs: [IDMap.TMDBRef]) async -> [IDMap.TMDBRef: String] {
        var out: [IDMap.TMDBRef: String] = [:]
        var missing: [IDMap.TMDBRef] = []
        for ref in refs {
            if let known = IDMap.imdb(forTMDB: ref) { out[ref] = known } else { missing.append(ref) }
        }
        guard !missing.isEmpty else { return out }
        let found = await withTaskGroup(of: (IDMap.TMDBRef, String?).self) { group in
            for ref in missing {
                group.addTask {
                    guard let data = await TMDB.get("/\(ref.kind.rawValue)/\(ref.id)/external_ids"),
                          let ids = try? JSONDecoder().decode(ExternalIDs.self, from: data) else { return (ref, nil) }
                    return (ref, ids.imdb_id)
                }
            }
            var result: [(IDMap.TMDBRef, String?)] = []
            for await answer in group { result.append(answer) }
            return result
        }
        for (ref, imdb) in found {
            guard let imdb, imdb.hasPrefix("tt") else { continue }
            IDMap.record(imdb: imdb, tmdb: ref)
            out[ref] = imdb
        }
        return out
    }

    private struct ExternalIDs: Decodable { let imdb_id: String? }
}

/// TMDB's genre ids (stable, from /genre/movie/list and /genre/tv/list), named the way
/// Cinemeta names them so genres line up across sources.
enum TMDBGenres {
    static let movie: [Int: [String]] = [
        28: ["Action"], 12: ["Adventure"], 16: ["Animation"], 35: ["Comedy"], 80: ["Crime"],
        99: ["Documentary"], 18: ["Drama"], 10751: ["Family"], 14: ["Fantasy"], 36: ["History"],
        27: ["Horror"], 10402: ["Music"], 9648: ["Mystery"], 10749: ["Romance"], 878: ["Sci-Fi"],
        10770: ["TV Movie"], 53: ["Thriller"], 10752: ["War"], 37: ["Western"],
    ]
    static let tv: [Int: [String]] = [
        10759: ["Action", "Adventure"], 16: ["Animation"], 35: ["Comedy"], 80: ["Crime"], 99: ["Documentary"],
        18: ["Drama"], 10751: ["Family"], 10762: ["Kids"], 9648: ["Mystery"], 10763: ["News"],
        10764: ["Reality-TV"], 10765: ["Sci-Fi", "Fantasy"], 10766: ["Soap"], 10767: ["Talk"],
        10768: ["War", "Politics"], 37: ["Western"],
    ]

    /// TMDB ids for genre names, joined with "|" (any of them) for discover; "" when none match.
    static func ids(_ names: [String], tv: Bool) -> String {
        let table = tv ? Self.tv : movie
        let wanted = Set(names)
        let ids = table.filter { !wanted.isDisjoint(with: $0.value) }.map(\.key).sorted()
        return ids.map(String.init).joined(separator: "|")
    }

    static func names(_ ids: [Int], tv: Bool) -> [String] {
        var seen = Set<String>()
        return ids.flatMap { (tv ? Self.tv : movie)[$0] ?? [] }.filter { seen.insert($0).inserted }
    }
}

// MARK: - MetaPreview in code and on disk

extension MetaPreview {
    init(id: String, type: String, name: String, poster: String?, background: String?, logo: String?,
         description: String?, releaseInfo: String?, imdbRating: String?, genres: [String],
         runtime: String?, trailerId: String?) {
        self.id = id
        self.type = type
        self.name = name
        self.poster = poster
        self.background = background
        self.logo = logo
        self.description = description
        self.releaseInfo = releaseInfo
        self.imdbRating = imdbRating
        self.genres = genres
        self.runtime = runtime
        self.trailerId = trailerId
    }
}

// Written with Stremio's keys, so a saved row reads back through the same decoder.
extension MetaPreview: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(type, forKey: AnyKey("type"))
        try c.encode(name, forKey: AnyKey("name"))
        try c.encodeIfPresent(poster, forKey: AnyKey("poster"))
        try c.encodeIfPresent(background, forKey: AnyKey("background"))
        try c.encodeIfPresent(logo, forKey: AnyKey("logo"))
        try c.encodeIfPresent(description, forKey: AnyKey("description"))
        try c.encodeIfPresent(releaseInfo, forKey: AnyKey("releaseInfo"))
        try c.encodeIfPresent(imdbRating, forKey: AnyKey("imdbRating"))
        try c.encode(genres, forKey: AnyKey("genres"))
        try c.encodeIfPresent(runtime, forKey: AnyKey("runtime"))
        if let trailerId { try c.encode([["ytId": trailerId]], forKey: AnyKey("trailerStreams")) }
    }
}
