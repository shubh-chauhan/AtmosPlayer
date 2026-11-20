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

    static let gate = RequestGate(limit: 8)

    /// The body of a 200 answer. Network errors, 429 and 5xx are tried once more.
    static func data(_ url: URL, session: URLSession = session, attempts: Int = 2) async -> Data? {
        await data(URLRequest(url: url), session: session, attempts: attempts)
    }

    /// As above, for a request with headers. Each retry waits twice as long as the last
    /// (0.6 s, 1.2 s…), or as long as a 429's Retry-After asks (up to 10 s).
    static func data(_ request: URLRequest, session: URLSession = session, attempts: Int = 2) async -> Data? {
        // At most a handful of metadata requests in flight, so opening Home (two dozen lists)
        // never floods the connection or a service's rate limit.
        await gate.enter()
        defer { Task { await gate.leave() } }
        var wait: Double = 0.6
        for attempt in 0..<attempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                wait *= 2
            }
            if Task.isCancelled { return nil }
            guard let (data, response) = try? await session.data(for: request) else { continue }
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 200 { return data }
            if code == 429 {
                if let after = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) {
                    wait = min(max(after, wait), 10)
                }
                continue
            }
            if code >= 500 { continue }
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

// MARK: Providers

/// One source of title details. Each is asked on its own, so any can be added, removed or
/// checked alone; `MetaResolver` decides the order and merges what they find.
protocol MetadataProvider {
    /// Recorded as where a field came from ("cinemeta", "tmdb"…).
    var name: String { get }
    /// Details for `ref`, or nil when this source has none. `base` is what the sources before
    /// it found (nil on a first lookup), so a source can fetch only what is missing.
    @MainActor
    func meta(for ref: MetaRef, base: StremioMeta?, addons: [InstalledAddon], timeout: TimeInterval) async -> StremioMeta?
}

struct CinemetaProvider: MetadataProvider {
    let name = "cinemeta"

    func meta(for ref: MetaRef, base: StremioMeta?, addons: [InstalledAddon], timeout: TimeInterval) async -> StremioMeta? {
        guard ref.id.hasPrefix("tt") else { return nil }
        // Cinemeta under the listed type, then the other one (its search and its details
        // sometimes disagree on whether a title is a movie or a series).
        let types = ref.type == "movie" ? ["movie", "series"] : ref.type == "series" ? ["series", "movie"] : []
        for type in types {
            if let meta = await Cinemeta.meta(type: type, id: ref.id) { return meta }
            if Task.isCancelled { return nil }
        }
        return nil
    }
}

/// Your addons that serve details for this kind of id (Cinemeta aside), all asked at once,
/// merged in your order.
struct AddonMetaProvider: MetadataProvider {
    let name = "addons"

    func meta(for ref: MetaRef, base: StremioMeta?, addons: [InstalledAddon], timeout: TimeInterval) async -> StremioMeta? {
        let metas = await MetaResolver.addonMetas(ref, addons: addons, timeout: timeout)
        guard var merged = metas.first else { return nil }
        for other in metas.dropFirst() { merged = merged.filling(from: other) }
        return merged
    }
}

/// TMDB, by the title's IMDb id. Episode lists are fetched only for seasons that need them.
struct TMDBProvider: MetadataProvider {
    let name = "tmdb"

    func meta(for ref: MetaRef, base: StremioMeta?, addons: [InstalledAddon], timeout: TimeInterval) async -> StremioMeta? {
        guard TMDB.isConfigured, ref.id.hasPrefix("tt"), let found = await TMDB.find(imdb: ref.id) else { return nil }
        var seasons: [Int] = []
        if found.kind == .tv {
            if let base, !base.videos.isEmpty {
                // Seasons with episodes missing a still or a synopsis.
                let bare = base.videos.filter { ($0.thumbnail ?? "").isEmpty || ($0.overview ?? "").isEmpty }
                seasons = Array(Set(bare.compactMap(\.season))).filter { $0 > 0 }.sorted()
            } else if let first = await TMDB.details(found) {
                seasons = (first.seasons ?? []).compactMap(\.value?.season_number).filter { $0 > 0 }
            }
        }
        // shortcut: up to 16 seasons per title (one request), enough for nearly every show.
        guard let details = await TMDB.details(found, seasons: seasons) else { return nil }
        return details.stremioMeta(imdb: ref.id, type: found.kind == .tv ? "series" : "movie")
    }
}

struct TVMazeProvider: MetadataProvider {
    let name = "tvmaze"

    func meta(for ref: MetaRef, base: StremioMeta?, addons: [InstalledAddon], timeout: TimeInterval) async -> StremioMeta? {
        let series = base.map { $0.type == "series" } ?? (ref.type != "movie")
        guard ref.id.hasPrefix("tt"), series else { return nil }
        return await TVMaze.meta(imdb: ref.id, fallback: ref)
    }
}

/// The basics from IMDb: enough to show the page and look for streams.
struct IMDbBasicsProvider: MetadataProvider {
    let name = "imdb"

    func meta(for ref: MetaRef, base: StremioMeta?, addons: [InstalledAddon], timeout: TimeInterval) async -> StremioMeta? {
        guard ref.id.hasPrefix("tt"), let basic = await IMDbSuggest.title(ref.id) else { return nil }
        let cast = (basic.description ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let base {
            return StremioMeta(id: base.id, type: base.type, name: basic.name, poster: basic.poster,
                               releaseInfo: basic.releaseInfo, cast: cast)
        }
        return StremioMeta(id: ref.id, type: basic.type,
                           name: basic.name, poster: ref.poster ?? basic.poster,
                           background: ref.background ?? basic.poster, logo: ref.logo,
                           releaseInfo: basic.releaseInfo, cast: cast)
    }
}

// MARK: Resolver

/// Finds a title's details, trying each source until one answers. Answers are saved (see
/// `MetaCache`), and callers asking for the same title at once share one lookup.
@MainActor
enum MetaResolver {
    /// Asked in turn when a title is first looked up; the first answer is the page.
    static var lookupOrder: [any MetadataProvider] = [
        CinemetaProvider(), AddonMetaProvider(), TMDBProvider(), TVMazeProvider(), IMDbBasicsProvider(),
    ]
    /// Asked all at once to fill a thin page, merged most trusted first.
    static var enrichOrder: [any MetadataProvider] = [
        TMDBProvider(), AddonMetaProvider(), TVMazeProvider(), IMDbBasicsProvider(),
    ]

    private static var inflight: [String: Task<(StremioMeta, [String: String])?, Never>] = [:]
    private static var enriching: [String: Task<(StremioMeta, [String: String])?, Never>] = [:]
    private static var extrasInflight: [String: Task<MetaExtras?, Never>] = [:]

    private static func key(_ ref: MetaRef) -> String { "\(ref.type)/\(ref.id)" }

    /// Cinemeta is thin on some titles (no synopsis, genres, runtime or cast, no episode stills).
    /// After the page is up, this asks the other sources at once and fills only what is missing,
    /// so every title page shows the same set of details. Nil when there was nothing to add.
    static func enrichIfThin(_ meta: StremioMeta, ref: MetaRef, addons: [InstalledAddon]) async -> StremioMeta? {
        let key = key(ref)
        guard meta.isThin else { return nil }
        let saved = await MetaCache.entry(key)
        if let saved, saved.enriched, saved.isFresh() { return nil }
        let task: Task<(StremioMeta, [String: String])?, Never>
        if let running = enriching[key] {
            task = running
        } else {
            task = Task { await enrich(meta, ref: ref, addons: addons) }
            enriching[key] = task
        }
        let answer = await task.value
        enriching[key] = nil
        // Nil when no source answered (offline, say): not marked done, so the next open tries again.
        guard let answer, !Task.isCancelled else { return nil }
        let (richer, provenance) = answer
        var extras = saved?.extras ?? MetaExtras()
        extras.provenance.merge(provenance) { old, _ in old }
        MetaCache.store(key, .init(meta: richer, extras: extras, enriched: true, savedAt: saved?.savedAt ?? Date()))
        return richer
    }

    static func resolve(_ ref: MetaRef, addons: [InstalledAddon]) async -> StremioMeta? {
        let key = key(ref)
        let saved = await MetaCache.entry(key)
        if let saved, saved.isFresh() {
            if saved.extras?.tmdbId == nil || !(saved.extras?.availability?.isFresh ?? false) { loadExtras(ref) }
            return saved.meta
        }
        let task: Task<(StremioMeta, [String: String])?, Never>
        if let running = inflight[key] {
            task = running
        } else {
            task = Task { await fetch(ref, addons: addons) }
            inflight[key] = task
        }
        let answer = await task.value
        inflight[key] = nil
        // Nothing answered: yesterday's copy beats an error page.
        guard let answer else { return saved?.meta }
        let (found, provenance) = answer
        var extras = saved?.extras ?? MetaExtras()
        extras.provenance = provenance
        MetaCache.store(key, .init(meta: found, extras: extras, enriched: false, savedAt: Date()))
        loadExtras(ref)
        return found
    }

    /// What TMDB knows beyond the page's own details (photos, characters, companies, textless
    /// artwork…), saved with the title. Nil without a TMDB token or for non-IMDb titles.
    static func extras(for ref: MetaRef) async -> MetaExtras? {
        let key = key(ref)
        let saved = await MetaCache.entry(key)
        let have: MetaExtras?
        if let fromEntry = saved?.extras {
            have = fromEntry
        } else {
            have = await MetaCache.savedExtras(key)
        }
        // Streaming availability changes; everything else keeps for as long as the entry.
        if let have, have.tmdbId != nil, have.version == MetaExtras.currentVersion, have.availability?.isFresh ?? false { return have }
        guard TMDB.isConfigured, ref.id.hasPrefix("tt") else { return have }
        if let running = extrasInflight[key] { return await running.value }
        let task = Task<MetaExtras?, Never> {
            guard let found = await TMDB.find(imdb: ref.id), let details = await TMDB.details(found) else { return nil }
            return details.extras(imdb: ref.id)
        }
        extrasInflight[key] = task
        let fetched = await task.value
        extrasInflight[key] = nil
        guard var extras = fetched else { return have }
        extras.provenance = have?.provenance ?? [:]
        await MetaCache.storeExtras(key, extras)
        return extras
    }

    /// Hero pictures already decided this session, by title and frame shape.
    private static var heroMemo: [String: String] = [:]

    /// The hero picture decided for a title, if it has been: shown in the first frame.
    static func decidedHeroArt(_ ref: MetaRef, portrait: Bool) -> String? {
        heroMemo["\(key(ref))/\(portrait)"]
    }

    /// Decides a title's hero picture once and decodes it before returning, so a page shows
    /// one picture instead of a stand-in swapped a moment later. TMDB's text-free art when it's
    /// saved or arrives within `wait` seconds, else `fallback`.
    static func heroArt(for ref: MetaRef, portrait: Bool, fallback: String?, maxPixel: Int,
                        wait: Double = 2.5) async -> String? {
        let memoKey = "\(key(ref))/\(portrait)"
        if let decided = heroMemo[memoKey] { return decided }
        var art: String?
        var final = true
        if TMDB.isConfigured, ref.id.hasPrefix("tt") {
            let key = key(ref)
            let saved: MetaExtras?
            if let fromEntry = await MetaCache.entry(key)?.extras {
                saved = fromEntry
            } else {
                saved = await MetaCache.savedExtras(key)
            }
            if let saved, saved.tmdbId != nil, saved.version == MetaExtras.currentVersion {
                art = saved.heroArt(portrait: portrait)
            } else {
                // Whichever comes first: TMDB's answer or the wait running out.
                let first: (fetched: Bool, art: String?) = await withTaskGroup(of: (Bool, String?).self) { group in
                    group.addTask { @MainActor in (true, await extras(for: ref)?.heroArt(portrait: portrait)) }
                    group.addTask {
                        try? await Task.sleep(for: .seconds(wait))
                        return (false, nil)
                    }
                    let answer = await group.next() ?? (false, nil)
                    group.cancelAll()
                    return answer
                }
                art = first.art
                // Ran out of time: not remembered, so the next visit can still get TMDB's art.
                final = first.fetched
            }
        }
        var chosen = fallback
        if let art, let url = ArtworkURL.best(art, maxPixel: maxPixel),
           await ImagePipeline.shared.image(url, maxPixel: maxPixel) != nil {
            chosen = art
        } else {
            await ImagePipeline.shared.prefetch(fallback, maxPixel: maxPixel)
        }
        if final, let chosen { heroMemo[memoKey] = chosen }
        return chosen
    }

    private static func loadExtras(_ ref: MetaRef) {
        guard TMDB.isConfigured, ref.id.hasPrefix("tt") else { return }
        Task { _ = await extras(for: ref) }
    }

    /// The first source with an answer, then the usual repairs. Provenance names the source of
    /// the page ("base") and of anything a repair added.
    private static func fetch(_ ref: MetaRef, addons: [InstalledAddon]) async -> (StremioMeta, [String: String])? {
        var found: StremioMeta?
        var provenance: [String: String] = [:]
        for provider in lookupOrder {
            if let meta = await provider.meta(for: ref, base: nil, addons: addons, timeout: 12) {
                found = meta
                provenance["base"] = provider.name
                break
            }
            if Task.isCancelled { return nil }
        }
        guard var found else { return nil }

        // A series with no episodes listed: TVmaze usually has them.
        if found.type == "series", found.videos.isEmpty, ref.id.hasPrefix("tt"),
           let show = await TVMaze.show(imdb: ref.id) {
            let videos = await TVMaze.episodes(showId: show.id, imdb: ref.id)
            if !videos.isEmpty {
                found = found.replacing(videos: videos)
                provenance["episodes"] = "tvmaze"
            }
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
            provenance["poster"] = "imdb"
            provenance["background"] = "imdb"
        }
        return (found, provenance)
    }

    /// The other sources' answers for `meta`, merged under it in order of trust (see
    /// `enrichOrder`): TMDB, your meta addons, TVmaze (series), then IMDb's basics.
    private static func enrich(_ meta: StremioMeta, ref: MetaRef, addons: [InstalledAddon]) async -> (StremioMeta, [String: String])? {
        let answers = await withTaskGroup(of: (Int, StremioMeta?).self) { group in
            for (index, provider) in enrichOrder.enumerated() {
                group.addTask { @MainActor in
                    (index, await provider.meta(for: ref, base: meta, addons: addons, timeout: 8))
                }
            }
            var out: [Int: StremioMeta] = [:]
            for await (index, found) in group { if let found { out[index] = found } }
            return out
        }
        guard !answers.isEmpty else { return nil }
        var merged = meta
        var provenance: [String: String] = [:]
        for index in answers.keys.sorted() {
            guard let other = answers[index] else { continue }
            let before = merged
            merged = merged.filling(from: other)
            for field in Self.changedFields(before, merged) where provenance[field] == nil {
                provenance[field] = enrichOrder[index].name
            }
        }
        return (merged, provenance)
    }

    /// Which of the shown fields differ between two versions of a title.
    static func changedFields(_ a: StremioMeta, _ b: StremioMeta) -> [String] {
        var fields: [String] = []
        func check(_ name: String, _ same: Bool) { if !same { fields.append(name) } }
        check("poster", a.poster == b.poster)
        check("background", a.background == b.background)
        check("logo", a.logo == b.logo)
        check("description", a.description == b.description)
        check("releaseInfo", a.releaseInfo == b.releaseInfo)
        check("imdbRating", a.imdbRating == b.imdbRating)
        check("runtime", a.runtime == b.runtime)
        check("genres", a.genres == b.genres)
        check("episodes", a.videos == b.videos)
        check("cast", a.cast == b.cast)
        check("directors", a.directors == b.directors)
        check("writers", a.writers == b.writers)
        check("awards", a.awards == b.awards)
        check("country", a.country == b.country)
        check("status", a.status == b.status)
        check("released", a.released == b.released)
        check("trailer", a.trailerId == b.trailerId)
        check("language", a.language == b.language)
        return fields
    }

    /// Details from your addons that serve this kind of id (Cinemeta aside), in your order.
    static func addonMetas(_ ref: MetaRef, addons: [InstalledAddon], timeout: TimeInterval) async -> [StremioMeta] {
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
