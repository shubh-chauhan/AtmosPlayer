import Foundation

// MARK: - Metadata beyond Cinemeta
//
// Cinemeta is the main source, but it has gaps: some titles are listed in search under one
// type ("series") while their details only exist under the other ("movie"); some series have
// no episode list; and now and then it answers 504. These free, keyless services fill in:
//   • TVmaze: episode lists with air dates, stills and synopses, looked up by IMDb id.
//   • IMDb's suggestion service: fast, typo-tolerant search with posters and people, and the
//     basics (name, year, poster, stars) of any IMDb title.

/// Shared HTTP for the metadata services: cached, short timeouts, one retry on a server error.
enum MetaHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = URLCache(memoryCapacity: 6 << 20, diskCapacity: 48 << 20)
        config.timeoutIntervalForRequest = 12
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: config)
    }()

    /// The body of a 200 answer. Network errors, 429 and 5xx are tried once more.
    static func data(_ url: URL, session: URLSession = session, attempts: Int = 2) async -> Data? {
        for attempt in 0..<attempts {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 600_000_000) }
            if Task.isCancelled { return nil }
            guard let (data, response) = try? await session.data(from: url) else { continue }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return data }
            if code == 429 || code >= 500 { continue }
            return nil
        }
        return nil
    }

    /// Plain text from the small HTML some services put in synopses.
    static func plainText(_ html: String?) -> String? {
        guard var text = html, !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                               ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

// MARK: TVmaze

enum TVMaze {
    private static let base = "https://api.tvmaze.com"

    struct Image: Decodable { let medium: String?; let original: String? }
    struct Rating: Decodable { let average: Double? }

    struct Show: Decodable {
        let id: Int
        let name: String
        let status: String?
        let premiered: String?
        let genres: [String]?
        let summary: String?
        let image: Image?
        let runtime: Int?
        let averageRuntime: Int?
        let rating: Rating?
        let language: String?
    }

    struct Episode: Decodable {
        let season: Int?
        let number: Int?
        let name: String?
        let airstamp: String?
        let airdate: String?
        let image: Image?
        let summary: String?
        let rating: Rating?
    }

    static func show(imdb: String) async -> Show? {
        guard let url = URL(string: "\(base)/lookup/shows?imdb=\(imdb)"),
              let data = await MetaHTTP.data(url) else { return nil }
        return try? JSONDecoder().decode(Show.self, from: data)
    }

    /// Every numbered episode, as Stremio videos with Stremio's ids ("tt…:season:episode").
    static func episodes(showId: Int, imdb: String) async -> [StremioMeta.Video] {
        guard let url = URL(string: "\(base)/shows/\(showId)/episodes"),
              let data = await MetaHTTP.data(url),
              let list = try? JSONDecoder().decode([LossyElement<Episode>].self, from: data) else { return [] }
        return list.compactMap(\.value).compactMap { episode in
            guard let season = episode.season, let number = episode.number else { return nil }
            let rating = episode.rating?.average.map { String(format: "%.1f", $0) }
            return StremioMeta.Video(id: "\(imdb):\(season):\(number)", title: episode.name, season: season,
                                     episode: number, released: episode.airstamp ?? episode.airdate,
                                     thumbnail: episode.image?.original ?? episode.image?.medium,
                                     overview: MetaHTTP.plainText(episode.summary), rating: rating)
        }
    }

    /// A series page built only from TVmaze, for shows Cinemeta has nothing on.
    static func meta(imdb: String, fallback: MetaRef) async -> StremioMeta? {
        guard let show = await show(imdb: imdb) else { return nil }
        let videos = await episodes(showId: show.id, imdb: imdb)
        let status = show.status == "Running" ? "Continuing" : show.status
        return StremioMeta(id: imdb, type: "series", name: show.name,
                           poster: fallback.poster ?? show.image?.original,
                           background: fallback.background ?? show.image?.original,
                           logo: fallback.logo,
                           description: MetaHTTP.plainText(show.summary),
                           releaseInfo: show.premiered.map { String($0.prefix(4)) },
                           imdbRating: nil,
                           runtime: (show.runtime ?? show.averageRuntime).map { "\($0) min" },
                           genres: show.genres ?? [], videos: videos, status: status,
                           released: show.premiered, language: show.language)
    }
}

// MARK: IMDb suggestions

enum IMDbSuggest {
    struct Person: Identifiable, Hashable {
        let id: String
        let name: String
        let photo: String?
        let knownFor: String?
    }

    private struct Response: Decodable {
        let items: [Item]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            items = c.lossyArray(Item.self, AnyKey("d"))
        }
    }

    private struct Item: Decodable {
        let id: String
        let name: String
        let kind: String?
        let year: String?
        let years: String?
        let stars: String?
        let image: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            guard let id = c.lossyString(AnyKey("id")), let name = c.lossyString(AnyKey("l")) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no id"))
            }
            self.id = id
            self.name = name
            kind = c.lossyString(AnyKey("qid"))
            year = c.lossyString(AnyKey("y"))
            years = c.lossyString(AnyKey("yr"))
            stars = c.lossyString(AnyKey("s"))
            if let art = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("i")) {
                image = art.lossyString(AnyKey("imageUrl"))
            } else {
                image = nil
            }
        }

        /// Stremio's type for an IMDb kind; nil for games, episodes, podcasts and the like.
        var stremioType: String? {
            switch kind {
            case "movie", "tvMovie", "short", "tvShort", "video", "tvSpecial": return "movie"
            case "tvSeries", "tvMiniSeries": return "series"
            default: return nil
            }
        }

        var preview: MetaPreview? {
            guard id.hasPrefix("tt"), let type = stremioType else { return nil }
            return MetaPreview(id: id, type: type, name: name, poster: image,
                               releaseInfo: years ?? year, cast: stars)
        }
    }

    private static func url(_ query: String) -> URL? {
        let text = query.lowercased()
        let first = text.first(where: { $0.isLetter || $0.isNumber }).map { $0.isASCII ? String($0) : "x" } ?? "x"
        return URL(string: "https://v2.sg.media-imdb.com/suggestion/\(first)/\(StremioClient.encode(text)).json")
    }

    /// Best matches first, the way IMDb's own search box ranks them.
    static func search(_ query: String) async -> (titles: [MetaPreview], people: [Person]) {
        guard let url = url(query), let data = await MetaHTTP.data(url),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return ([], []) }
        let titles = response.items.compactMap(\.preview).filter { $0.poster != nil }
        let people = response.items.filter { $0.id.hasPrefix("nm") }.map {
            Person(id: $0.id, name: $0.name, photo: $0.image, knownFor: $0.stars)
        }
        return (titles, people)
    }

    /// Name, year, poster and stars of one title.
    static func title(_ id: String) async -> MetaPreview? {
        guard let url = URL(string: "https://v2.sg.media-imdb.com/suggestion/t/\(id).json"),
              let data = await MetaHTTP.data(url),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return response.items.first(where: { $0.id == id })?.preview
    }
}

// MARK: Resolver

/// Finds a title's details, trying each source until one answers.
@MainActor
enum MetaResolver {
    private static var cache: [String: StremioMeta] = [:]
    private static var enriched: Set<String> = []

    /// Cinemeta is thin on some titles (no synopsis, genres, runtime or cast, no episode stills).
    /// After the page is up, this asks the other sources at once and fills only what is missing,
    /// so every title page shows the same set of details. Nil when there was nothing to add.
    static func enrichIfThin(_ meta: StremioMeta, ref: MetaRef, addons: [InstalledAddon]) async -> StremioMeta? {
        let key = "\(ref.type)/\(ref.id)"
        guard meta.isThin, !enriched.contains(key) else { return nil }
        // Nil when no source answered (offline, say): not marked done, so the next open tries again.
        guard let richer = await enrich(meta, ref: ref, addons: addons), !Task.isCancelled else { return nil }
        enriched.insert(key)
        cache[key] = richer
        return richer
    }

    static func resolve(_ ref: MetaRef, addons: [InstalledAddon]) async -> StremioMeta? {
        let key = "\(ref.type)/\(ref.id)"
        if let hit = cache[key] { return hit }
        guard var found = await lookup(ref, addons: addons) else { return nil }

        // A series with no episodes listed: TVmaze usually has them.
        if found.type == "series", found.videos.isEmpty, ref.id.hasPrefix("tt"),
           let show = await TVMaze.show(imdb: ref.id) {
            let videos = await TVMaze.episodes(showId: show.id, imdb: ref.id)
            if !videos.isEmpty { found = found.replacing(videos: videos) }
        }
        // No artwork anywhere: IMDb's poster, so the page isn't an empty black hero.
        if found.poster == nil, found.background == nil, ref.id.hasPrefix("tt"),
           let poster = await IMDbSuggest.title(ref.id)?.poster {
            found = StremioMeta(id: found.id, type: found.type, name: found.name, poster: poster,
                                background: found.background ?? poster, logo: found.logo,
                                description: found.description, releaseInfo: found.releaseInfo,
                                imdbRating: found.imdbRating, runtime: found.runtime, genres: found.genres,
                                videos: found.videos, cast: found.cast, directors: found.directors,
                                writers: found.writers, awards: found.awards, country: found.country,
                                status: found.status, released: found.released, trailerId: found.trailerId,
                                shareURL: found.shareURL, language: found.language)
        }
        if Task.isCancelled { return found }
        if cache.count > 200 { cache.removeAll() }
        cache[key] = found
        return found
    }

    /// The other sources' answers for `meta`, merged under it in order of trust: your meta
    /// addons, TVmaze (series), then IMDb's basics.
    private static func enrich(_ meta: StremioMeta, ref: MetaRef, addons: [InstalledAddon]) async -> StremioMeta? {
        let imdb = ref.id.hasPrefix("tt")
        let series = meta.type == "series"
        async let fromAddons = addonMetas(ref, addons: addons, timeout: 8)
        async let fromTVMaze: StremioMeta? = imdb && series ? TVMaze.meta(imdb: ref.id, fallback: ref) : nil
        async let fromIMDb: MetaPreview? = imdb ? IMDbSuggest.title(ref.id) : nil
        var merged = meta
        var answered = false
        for other in await fromAddons { merged = merged.filling(from: other); answered = true }
        if let tv = await fromTVMaze { merged = merged.filling(from: tv); answered = true }
        if let basic = await fromIMDb {
            answered = true
            let cast = (basic.description ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            merged = merged.filling(from: StremioMeta(id: meta.id, type: meta.type, name: basic.name,
                                                      poster: basic.poster, releaseInfo: basic.releaseInfo,
                                                      cast: cast))
        }
        return answered ? merged : nil
    }

    /// Details from your addons that serve this kind of id (Cinemeta aside), in your order.
    private static func addonMetas(_ ref: MetaRef, addons: [InstalledAddon], timeout: TimeInterval) async -> [StremioMeta] {
        let candidates = addons.filter {
            !$0.transportURL.contains("cinemeta") && $0.manifest.supports("meta", type: ref.type, id: ref.id)
        }
        guard !candidates.isEmpty else { return [] }
        let answers = await withTaskGroup(of: (Int, StremioMeta?).self) { group in
            for (index, addon) in candidates.enumerated() {
                group.addTask {
                    (index, try? await StremioClient.meta(addon, type: ref.type, id: ref.id, timeout: timeout))
                }
            }
            var out: [Int: StremioMeta] = [:]
            for await (index, meta) in group { if let meta { out[index] = meta } }
            return out
        }
        return answers.keys.sorted().compactMap { answers[$0] }
    }

    private static func lookup(_ ref: MetaRef, addons: [InstalledAddon]) async -> StremioMeta? {
        let imdb = ref.id.hasPrefix("tt")
        if imdb {
            // Cinemeta under the listed type, then the other one (its search and its details
            // sometimes disagree on whether a title is a movie or a series).
            let types = ref.type == "movie" ? ["movie", "series"] : ref.type == "series" ? ["series", "movie"] : []
            for type in types {
                if let meta = await Cinemeta.meta(type: type, id: ref.id) { return meta }
                if Task.isCancelled { return nil }
            }
        }
        // Your addons that serve details for this kind of id, in your order, all asked at once.
        if let meta = await addonMetas(ref, addons: addons, timeout: 12).first { return meta }
        guard imdb else { return nil }
        if ref.type != "movie", let meta = await TVMaze.meta(imdb: ref.id, fallback: ref) { return meta }
        // Last resort: the basics from IMDb, enough to show the page and look for streams.
        guard let basic = await IMDbSuggest.title(ref.id) else { return nil }
        return StremioMeta(id: ref.id, type: basic.type,
                           name: basic.name, poster: ref.poster ?? basic.poster,
                           background: ref.background ?? basic.poster, logo: ref.logo,
                           releaseInfo: basic.releaseInfo,
                           cast: (basic.description ?? "").split(separator: ",")
                               .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
}

// MARK: Building models in code

extension MetaPreview {
    /// `cast` is kept in `description` (IMDb's "stars" line) until the title is opened.
    init(id: String, type: String, name: String, poster: String?, releaseInfo: String?, cast: String?) {
        self.id = id
        self.type = type
        self.name = name
        self.poster = poster
        background = nil
        logo = nil
        description = cast
        self.releaseInfo = releaseInfo
        imdbRating = nil
        genres = []
        runtime = nil
        trailerId = nil
    }
}

extension StremioMeta.Video {
    init(id: String, title: String?, season: Int?, episode: Int?, released: String?, thumbnail: String?,
         overview: String?, rating: String?) {
        self.id = id
        self.title = title
        self.season = season
        self.episode = episode
        self.released = released
        self.thumbnail = thumbnail
        self.overview = overview
        self.rating = rating
    }
}

extension StremioMeta {
    init(id: String, type: String, name: String, poster: String? = nil, background: String? = nil,
         logo: String? = nil, description: String? = nil, releaseInfo: String? = nil,
         imdbRating: String? = nil, runtime: String? = nil, genres: [String] = [], videos: [Video] = [],
         cast: [String] = [], directors: [String] = [], writers: [String] = [], awards: String? = nil,
         country: String? = nil, status: String? = nil, released: String? = nil, trailerId: String? = nil,
         shareURL: String? = nil, language: String? = nil) {
        self.id = id
        self.type = type
        self.name = name
        self.poster = poster
        self.background = background
        self.logo = logo
        self.description = description
        self.releaseInfo = releaseInfo
        self.imdbRating = imdbRating
        self.runtime = runtime
        self.genres = genres
        self.videos = videos
        self.cast = cast
        self.directors = directors
        self.writers = writers
        self.awards = awards
        self.country = country
        self.status = status
        self.released = released
        self.trailerId = trailerId
        self.shareURL = shareURL
        self.language = language
    }

    /// Missing any of the details a title page shows.
    var isThin: Bool {
        func empty(_ value: String?) -> Bool { (value ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        if empty(description) || genres.isEmpty || empty(runtime) || cast.isEmpty
            || empty(background) || empty(releaseInfo) || trailerId == nil { return true }
        if type == "series", !videos.isEmpty {
            let bare = videos.filter { empty($0.thumbnail) || empty($0.overview) }.count
            return bare * 3 > videos.count
        }
        return false
    }

    /// This meta with every empty field taken from `other`. Episodes are matched by season and
    /// number: missing stills, synopses, titles and dates are filled, and episodes `other` lists
    /// that this one doesn't are added.
    func filling(from other: StremioMeta) -> StremioMeta {
        func pick(_ mine: String?, _ theirs: String?) -> String? {
            (mine ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? (theirs ?? mine) : mine
        }
        var episodes = videos
        if !other.videos.isEmpty {
            if episodes.isEmpty {
                episodes = other.videos
            } else {
                var byCode: [String: Video] = [:]
                for video in other.videos { if let code = video.code { byCode[code] = video } }
                var seen = Set<String>()
                episodes = episodes.map { video in
                    guard let code = video.code, let match = byCode[code] else { return video }
                    seen.insert(code)
                    return Video(id: video.id, title: pick(video.title, match.title), season: video.season,
                                 episode: video.episode, released: pick(video.released, match.released),
                                 thumbnail: pick(video.thumbnail, match.thumbnail),
                                 overview: pick(video.overview, match.overview),
                                 rating: pick(video.rating, match.rating))
                }
                // Only add episodes when the ids line up with this title's ("tt…:s:e").
                if other.id == id {
                    episodes += other.videos.filter { video in
                        guard let code = video.code, (video.season ?? 0) > 0 else { return false }
                        return !seen.contains(code) && !videos.contains { $0.code == code }
                    }
                }
            }
        }
        return StremioMeta(id: id, type: type, name: name, poster: pick(poster, other.poster),
                           background: pick(background, other.background), logo: pick(logo, other.logo),
                           description: pick(description, other.description),
                           releaseInfo: pick(releaseInfo, other.releaseInfo),
                           imdbRating: pick(imdbRating, other.imdbRating), runtime: pick(runtime, other.runtime),
                           genres: genres.isEmpty ? other.genres : genres, videos: episodes,
                           cast: cast.isEmpty ? other.cast : cast,
                           directors: directors.isEmpty ? other.directors : directors,
                           writers: writers.isEmpty ? other.writers : writers,
                           awards: pick(awards, other.awards), country: pick(country, other.country),
                           status: pick(status, other.status), released: pick(released, other.released),
                           trailerId: trailerId ?? other.trailerId, shareURL: shareURL ?? other.shareURL,
                           language: pick(language, other.language))
    }

    func replacing(videos: [Video]) -> StremioMeta {
        StremioMeta(id: id, type: type, name: name, poster: poster, background: background, logo: logo,
                    description: description, releaseInfo: releaseInfo, imdbRating: imdbRating,
                    runtime: runtime, genres: genres, videos: videos, cast: cast, directors: directors,
                    writers: writers, awards: awards, country: country, status: status, released: released,
                    trailerId: trailerId, shareURL: shareURL, language: language)
    }
}
