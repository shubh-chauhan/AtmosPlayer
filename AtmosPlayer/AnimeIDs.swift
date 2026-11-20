import Foundation

// MARK: - Anime ids
//
// Anime addons list titles under Kitsu ids ("kitsu:1376"), which TMDB doesn't know. This finds
// the TMDB title behind a Kitsu id, so anime gets the same posters, backdrops, text-free hero
// art and episode stills as everything else: first through the TVDB id Kitsu lists for it,
// else by searching TMDB for its English title and year. Answers are saved between launches.

@MainActor
enum KitsuMap {
    private static var saved: [String: IDMap.TMDBRef] = load()
    /// Ids with no TMDB match, not asked again for a day.
    private static var misses: [String: Date] = [:]
    private static var inflight: [String: Task<IDMap.TMDBRef?, Never>] = [:]
    private static var pendingSave: Task<Void, Never>?

    private static let url: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("kitsumap-v1.json")

    /// "kitsu:1376" or "kitsu:1376:5" → "1376".
    static func kitsuNumber(_ id: String) -> String? {
        let parts = id.split(separator: ":")
        guard parts.count >= 2, parts[0] == "kitsu", Int(parts[1]) != nil else { return nil }
        return String(parts[1])
    }

    static func tmdb(for id: String) async -> IDMap.TMDBRef? {
        guard TMDB.isConfigured, let number = kitsuNumber(id) else { return nil }
        if let known = saved[number] { return known }
        if let miss = misses[number], Date().timeIntervalSince(miss) < 24 * 3600 { return nil }
        if let running = inflight[number] { return await running.value }
        let task = Task<IDMap.TMDBRef?, Never> { await lookUp(number) }
        inflight[number] = task
        let found = await task.value
        inflight[number] = nil
        if let found {
            saved[number] = found
            scheduleSave()
        } else {
            misses[number] = Date()
        }
        return found
    }

    private struct KitsuAnswer: Decodable {
        struct Titles: Decodable { let en: String?; let en_jp: String?; let en_us: String? }
        struct Attributes: Decodable {
            let canonicalTitle: String?
            let titles: Titles?
            let startDate: String?
            let subtype: String?
            let externalSite: String?
            let externalId: String?
        }
        struct Resource: Decodable { let type: String?; let attributes: Attributes? }
        let data: Resource?
        let included: [LossyElement<Resource>]?
    }

    private static func lookUp(_ number: String) async -> IDMap.TMDBRef? {
        guard let address = URL(string: "https://kitsu.io/api/edge/anime/\(number)?include=mappings") else { return nil }
        var request = URLRequest(url: address)
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        guard let data = await MetaHTTP.data(request),
              let answer = try? JSONDecoder().decode(KitsuAnswer.self, from: data),
              let anime = answer.data?.attributes else { return nil }
        let isMovie = anime.subtype?.lowercased() == "movie"

        // 1. TVDB id from Kitsu's mappings ("thetvdb/series" → "81797" or "81797/2").
        let mappings = (answer.included ?? []).compactMap(\.value).filter { $0.type == "mappings" }.compactMap(\.attributes)
        if !isMovie, let tvdb = mappings.first(where: { ($0.externalSite ?? "").hasPrefix("thetvdb") })?.externalId?
            .split(separator: "/").first.map(String.init), Int(tvdb) != nil,
           let found = await TMDB.find(externalId: tvdb, source: "tvdb_id") {
            return found
        }

        // 2. TMDB search by title and first year; animation first.
        let title = anime.titles?.en ?? anime.titles?.en_us ?? anime.canonicalTitle ?? anime.titles?.en_jp
        guard let title, !title.isEmpty else { return nil }
        let year = anime.startDate.map { String($0.prefix(4)) }
        return await TMDB.search(title: title, year: year, movie: isMovie)
    }

    private static func load() -> [String: IDMap.TMDBRef] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: IDMap.TMDBRef].self, from: data)) ?? [:]
    }

    private static func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            let snapshot = saved, url = url
            await Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
            }.value
        }
    }
}

extension TMDB {
    private struct FindAnswer: Decodable {
        struct Hit: Decodable { let id: Int }
        let movie_results: [Hit]
        let tv_results: [Hit]
    }

    private struct SearchAnswer: Decodable {
        struct Hit: Decodable { let id: Int; let genre_ids: [Int]? }
        let results: [LossyElement<Hit>]
    }

    /// TMDB's title for another service's id (`source`: "tvdb_id", "imdb_id"…).
    static func find(externalId: String, source: String) async -> IDMap.TMDBRef? {
        guard let data = await get("/find/\(externalId)", [URLQueryItem(name: "external_source", value: source)]),
              let found = try? JSONDecoder().decode(FindAnswer.self, from: data) else { return nil }
        if let show = found.tv_results.first { return IDMap.TMDBRef(kind: .tv, id: show.id) }
        if let movie = found.movie_results.first { return IDMap.TMDBRef(kind: .movie, id: movie.id) }
        return nil
    }

    /// The best TMDB match for a title (and year), animated ones first.
    static func search(title: String, year: String?, movie: Bool) async -> IDMap.TMDBRef? {
        var query = [URLQueryItem(name: "query", value: title), URLQueryItem(name: "include_adult", value: "false")]
        if let year, Int(year) != nil {
            query.append(URLQueryItem(name: movie ? "primary_release_year" : "first_air_date_year", value: year))
        }
        guard let data = await get(movie ? "/search/movie" : "/search/tv", query),
              let found = try? JSONDecoder().decode(SearchAnswer.self, from: data) else { return nil }
        let hits = found.results.compactMap(\.value)
        // 16 is Animation for both movies and TV.
        guard let pick = hits.first(where: { $0.genre_ids?.contains(16) ?? false }) ?? hits.first else { return nil }
        return IDMap.TMDBRef(kind: movie ? .movie : .tv, id: pick.id)
    }
}
