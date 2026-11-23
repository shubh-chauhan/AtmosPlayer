import Foundation

// MARK: - TMDB
//
// The Movie Database: details, credits with photos and characters, textless artwork,
// production companies, ratings and episode lists, looked up from a title's IMDb id.
// Uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB.
//
// Terms (checked 2026-11-20, themoviedb.org/api-terms-of-use): free for non-commercial use with
// the TMDB logo and the notice above shown in the app; nothing may be cached longer than six
// months; about 40 requests a second, and a 429 must be respected.
//
// The read token comes from the TMDB_TOKEN repo secret, put into Info.plist at build time
// reversed and base64'd. Without it every call here returns nil and the app works as before.

enum TMDB {
    static let imageBase = "https://image.tmdb.org/t/p/"

    /// The read access token (or a v3 key), or nil when the build has none.
    static let token: String? = descramble(Bundle.main.object(forInfoDictionaryKey: "TMDBToken") as? String)

    static var isConfigured: Bool { token != nil }

    /// Undoes CI's `rev | base64`.
    static func descramble(_ stored: String?) -> String? {
        guard let stored, !stored.isEmpty, !stored.hasPrefix("$("),
              let data = Data(base64Encoded: stored),
              let reversed = String(data: data, encoding: .utf8) else { return nil }
        let token = String(reversed.reversed()).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// The device's language ("fr", "hi"…), for TMDB's text and artwork.
    static let languageCode: String = Locale.current.language.languageCode?.identifier ?? "en"

    /// Text language for TMDB answers, as TMDB writes it ("en-US", "fr-FR"). Where TMDB has no
    /// translation the text stays empty, and the details from Cinemeta (English) are kept.
    static let language: String = {
        guard let region = Locale.current.region?.identifier else { return languageCode }
        return "\(languageCode)-\(region)"
    }()

    /// Where streaming availability is looked up: the region picked in Settings, else the
    /// device's region.
    static var region: String {
        let picked = UserDefaults.standard.string(forKey: regionKey) ?? ""
        return picked.isEmpty ? (Locale.current.region?.identifier ?? "US") : picked
    }
    static let regionKey = "tmdb.region"

    // MARK: Requests

    /// At most a few TMDB requests at once, well inside its limits.
    private static let gate = RequestGate(limit: 6)

    static func get(_ path: String, _ query: [URLQueryItem] = []) async -> Data? {
        guard let token, var components = URLComponents(string: "https://api.themoviedb.org/3" + path) else { return nil }
        var items = query
        // A v3 key is 32 hex characters and goes in the query; the v4 read token is a bearer token.
        let isV3Key = token.count == 32 && token.allSatisfy(\.isHexDigit)
        if isV3Key { items.append(URLQueryItem(name: "api_key", value: token)) }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        if !isV3Key { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        await gate.enter()
        defer { Task { await gate.leave() } }
        return await MetaHTTP.data(request, attempts: 3)
    }

    // MARK: IMDb ↔ TMDB

    /// TMDB's id for an IMDb title: from the id map, else TMDB's /find.
    @MainActor
    static func find(imdb: String) async -> IDMap.TMDBRef? {
        if let known = IDMap.tmdb(forIMDb: imdb) { return known }
        guard let data = await get("/find/\(imdb)", [URLQueryItem(name: "external_source", value: "imdb_id")]),
              let found = try? JSONDecoder().decode(FindResponse.self, from: data) else { return nil }
        let ref: IDMap.TMDBRef?
        if let movie = found.movie_results.first {
            ref = IDMap.TMDBRef(kind: .movie, id: movie.id)
        } else if let show = found.tv_results.first {
            ref = IDMap.TMDBRef(kind: .tv, id: show.id)
        } else {
            ref = nil
        }
        if let ref { IDMap.record(imdb: imdb, tmdb: ref) }
        return ref
    }

    private struct FindResponse: Decodable {
        struct Hit: Decodable { let id: Int }
        let movie_results: [Hit]
        let tv_results: [Hit]
    }

    // MARK: Details

    /// One title's details with credits, ids, artwork and trailers in a single request, and up
    /// to 16 seasons' episodes when asked. Answers are shared for a few minutes, so the title
    /// page, its enrichment and its extras cost one call.
    @MainActor
    static func details(_ ref: IDMap.TMDBRef, seasons: [Int] = []) async -> Details? {
        let wanted = Array(Set(seasons).sorted().prefix(16))
        let key = "\(ref.kind.rawValue)/\(ref.id)/\(wanted.map(String.init).joined(separator: ","))"
        if let hit = recent[key], Date().timeIntervalSince(hit.at) < 600 { return hit.details }
        if let running = inflight[key] { return await running.value }
        let task = Task<Details?, Never> {
            var append = ["credits", "external_ids", "images", "videos", "watch/providers"]
            append += wanted.map { "season/\($0)" }
            let data = await get("/\(ref.kind.rawValue)/\(ref.id)", [
                URLQueryItem(name: "language", value: language),
                URLQueryItem(name: "append_to_response", value: append.joined(separator: ",")),
                // Artwork in your language, English, or with no text at all ("null": textless backdrops).
                URLQueryItem(name: "include_image_language", value: Set([TMDB.languageCode, "en"]).sorted().joined(separator: ",") + ",null"),
            ])
            return data.flatMap { try? JSONDecoder().decode(Details.self, from: $0) }
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        if let result {
            if recent.count > 40, let oldest = recent.min(by: { $0.value.at < $1.value.at })?.key {
                recent[oldest] = nil
            }
            recent[key] = (result, Date())
        }
        return result
    }

    @MainActor private static var inflight: [String: Task<Details?, Never>] = [:]
    @MainActor private static var recent: [String: (details: Details, at: Date)] = [:]

    // MARK: Response

    struct Details: Decodable {
        struct Named: Decodable { let name: String? }
        struct Country: Decodable { let iso_3166_1: String?; let name: String? }
        struct Language: Decodable { let english_name: String?; let iso_639_1: String? }
        struct CastMember: Decodable { let name: String?; let character: String?; let profile_path: String?; let order: Int? }
        struct CrewMember: Decodable { let name: String?; let job: String?; let department: String?; let profile_path: String? }
        struct Credits: Decodable { let cast: [LossyElement<CastMember>]?; let crew: [LossyElement<CrewMember>]? }
        struct ExternalIDs: Decodable { let imdb_id: String?; let tvdb_id: Int? }
        struct Image: Decodable { let file_path: String?; let iso_639_1: String?; let vote_average: Double?; let width: Int? }
        struct Images: Decodable { let backdrops: [LossyElement<Image>]?; let logos: [LossyElement<Image>]?; let posters: [LossyElement<Image>]? }
        struct Video: Decodable { let key: String?; let site: String?; let type: String?; let official: Bool? }
        struct Videos: Decodable { let results: [LossyElement<Video>]? }
        struct Episode: Decodable {
            let season_number: Int?
            let episode_number: Int?
            let name: String?
            let overview: String?
            let still_path: String?
            let air_date: String?
            let vote_average: Double?
        }
        struct Season: Decodable { let season_number: Int?; let episodes: [LossyElement<Episode>]? }
        struct SeasonSummary: Decodable { let season_number: Int? }
        struct Provider: Decodable { let provider_id: Int?; let provider_name: String?; let logo_path: String?; let display_priority: Int? }
        struct RegionOffers: Decodable {
            let link: String?
            let flatrate: [LossyElement<Provider>]?
            let free: [LossyElement<Provider>]?
            let ads: [LossyElement<Provider>]?
            let rent: [LossyElement<Provider>]?
            let buy: [LossyElement<Provider>]?
        }
        struct WatchProviders: Decodable { let results: [String: RegionOffers]? }

        let id: Int
        // Movies use title/release_date/runtime; series name/first_air_date/episode_run_time.
        let title: String?
        let name: String?
        let original_title: String?
        let original_name: String?
        let original_language: String?
        let overview: String?
        let release_date: String?
        let first_air_date: String?
        let runtime: Int?
        let episode_run_time: [Int]?
        let status: String?
        let genres: [LossyElement<Named>]?
        let vote_average: Double?
        let vote_count: Int?
        let poster_path: String?
        let backdrop_path: String?
        let production_companies: [LossyElement<Named>]?
        let production_countries: [LossyElement<Country>]?
        let spoken_languages: [LossyElement<Language>]?
        let seasons: [LossyElement<SeasonSummary>]?
        let credits: Credits?
        let external_ids: ExternalIDs?
        let images: Images?
        let videos: Videos?
        let watchProviders: WatchProviders?
        /// "season/1", "season/2"… from append_to_response.
        let appendedSeasons: [Int: Season]

        private struct Keys: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let plain = try decoder.container(keyedBy: Keys.self)
            func value<T: Decodable>(_ key: String) -> T? {
                guard let k = Keys(stringValue: key) else { return nil }
                return try? plain.decodeIfPresent(T.self, forKey: k)
            }
            guard let id: Int = value("id") else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no id"))
            }
            self.id = id
            title = value("title")
            name = value("name")
            original_title = value("original_title")
            original_name = value("original_name")
            original_language = value("original_language")
            overview = value("overview")
            release_date = value("release_date")
            first_air_date = value("first_air_date")
            runtime = value("runtime")
            episode_run_time = value("episode_run_time")
            status = value("status")
            genres = value("genres")
            vote_average = value("vote_average")
            vote_count = value("vote_count")
            poster_path = value("poster_path")
            backdrop_path = value("backdrop_path")
            production_companies = value("production_companies")
            production_countries = value("production_countries")
            spoken_languages = value("spoken_languages")
            seasons = value("seasons")
            credits = value("credits")
            external_ids = value("external_ids")
            images = value("images")
            videos = value("videos")
            watchProviders = value("watch/providers")
            var appended: [Int: Season] = [:]
            for key in plain.allKeys where key.stringValue.hasPrefix("season/") {
                if let number = Int(key.stringValue.dropFirst("season/".count)),
                   let season = try? plain.decode(Season.self, forKey: key) {
                    appended[number] = season
                }
            }
            appendedSeasons = appended
        }
    }
}

// MARK: - Turning a TMDB answer into the app's models

extension TMDB.Details {
    static func image(_ path: String?, size: String) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return TMDB.imageBase + size + path
    }

    /// Highest-voted, widest first.
    private static func best(_ list: [LossyElement<Image>]?, where keep: (Image) -> Bool) -> Image? {
        (list ?? []).compactMap(\.value).filter { $0.file_path != nil && keep($0) }
            .max { ($0.vote_average ?? 0, $0.width ?? 0) < ($1.vote_average ?? 0, $1.width ?? 0) }
    }

    var textlessBackdrop: String? {
        Self.image(Self.best(images?.backdrops, where: { $0.iso_639_1 == nil })?.file_path, size: "w1280")
    }

    /// A poster with no text, at full size: it fills a tall phone frame the way a backdrop can't.
    var textlessPoster: String? {
        Self.image(Self.best(images?.posters, where: { $0.iso_639_1 == nil })?.file_path, size: "original")
    }

    var anyBackdrop: String? {
        Self.image(Self.best(images?.backdrops, where: { _ in true })?.file_path ?? backdrop_path, size: "w1280")
    }

    /// A logo in your language when there is one, else English.
    var logo: String? {
        let own = Self.best(images?.logos, where: { $0.iso_639_1 == TMDB.languageCode })
        return Self.image((own ?? Self.best(images?.logos, where: { $0.iso_639_1 == "en" }))?.file_path, size: "w500")
    }

    var poster: String? {
        Self.image(Self.best(images?.posters, where: { $0.iso_639_1 == "en" })?.file_path ?? poster_path, size: "w780")
    }

    /// The YouTube trailer TMDB lists, official ones first.
    var trailerId: String? {
        let list = (videos?.results ?? []).compactMap(\.value).filter { $0.site == "YouTube" && $0.key != nil }
        let trailers = list.filter { $0.type == "Trailer" }
        return (trailers.first { $0.official == true } ?? trailers.first ?? list.first { $0.type == "Teaser" })?.key
    }

    var isSeries: Bool { name != nil && title == nil }

    /// Episodes from the appended seasons, with Stremio's ids ("tt…:season:episode").
    func videos(imdb: String) -> [StremioMeta.Video] {
        appendedSeasons.keys.sorted().flatMap { number in
            (appendedSeasons[number]?.episodes ?? []).compactMap(\.value).compactMap { episode -> StremioMeta.Video? in
                guard let season = episode.season_number ?? Optional(number), let index = episode.episode_number else { return nil }
                let rating = episode.vote_average.flatMap { $0 > 0 ? String(format: "%.1f", $0) : nil }
                return StremioMeta.Video(id: "\(imdb):\(season):\(index)", title: episode.name, season: season,
                                         episode: index, released: episode.air_date,
                                         thumbnail: Self.image(episode.still_path, size: "w780"),
                                         overview: episode.overview.flatMap { $0.isEmpty ? nil : $0 },
                                         rating: rating)
            }
        }
    }

    /// TMDB's answer in the app's own shape, under the title's IMDb id so streams still match.
    /// Only what TMDB actually lists is set; the rest stays empty.
    func stremioMeta(imdb: String, type: String) -> StremioMeta {
        let crew = (credits?.crew ?? []).compactMap(\.value)
        let date = release_date ?? first_air_date
        let minutes = runtime ?? episode_run_time?.first
        let statusText: String? = {
            switch status {
            case "Returning Series", "In Production": return "Continuing"
            case "Ended", "Canceled": return "Ended"
            default: return nil
            }
        }()
        func unique(_ names: [String]) -> [String] {
            var seen = Set<String>()
            return names.filter { seen.insert($0).inserted }
        }
        return StremioMeta(
            id: imdb, type: type, name: title ?? name ?? "",
            poster: poster, background: anyBackdrop, logo: logo,
            description: overview.flatMap { $0.isEmpty ? nil : $0 },
            releaseInfo: date.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil },
            imdbRating: nil,
            runtime: minutes.flatMap { $0 > 0 ? "\($0) min" : nil },
            genres: (genres ?? []).compactMap(\.value?.name),
            videos: videos(imdb: imdb),
            cast: Array((credits?.cast ?? []).compactMap(\.value?.name).prefix(15)),
            directors: unique(crew.filter { $0.job == "Director" }.compactMap(\.name)),
            writers: unique(crew.filter { $0.department == "Writing" }.compactMap(\.name)),
            country: (production_countries ?? []).compactMap(\.value?.name).joined(separator: ", ").nilIfEmpty,
            status: statusText,
            released: date.flatMap { $0.isEmpty ? nil : $0 },
            trailerId: trailerId,
            language: (spoken_languages ?? []).compactMap(\.value?.english_name).first)
    }

    /// Where it streams, rents or sells in `region`, as TMDB lists it (data from JustWatch).
    func availability(region: String) -> MetaExtras.Availability {
        let offers = watchProviders?.results?[region]
        func list(_ providers: [LossyElement<Provider>]?, _ kind: MetaExtras.Offer.Kind) -> [MetaExtras.Offer] {
            (providers ?? []).compactMap(\.value)
                .sorted { ($0.display_priority ?? .max) < ($1.display_priority ?? .max) }
                .compactMap { p in
                    guard let id = p.provider_id, let name = p.provider_name else { return nil }
                    return MetaExtras.Offer(providerId: id, name: name, logo: Self.image(p.logo_path, size: "w92"), kind: kind)
                }
        }
        let all = list(offers?.flatrate, .subscription) + list(offers?.free, .free) + list(offers?.ads, .ads)
            + list(offers?.rent, .rent) + list(offers?.buy, .buy)
        return MetaExtras.Availability(region: region, link: offers?.link, offers: all, checkedAt: Date())
    }

    /// The details the app's model has no place for.
    func extras(imdb: String) -> MetaExtras {
        let castList = (credits?.cast ?? []).compactMap(\.value)
            .sorted { ($0.order ?? .max) < ($1.order ?? .max) }
            .prefix(30)
            .compactMap { member -> MetaExtras.Person? in
                guard let name = member.name else { return nil }
                return MetaExtras.Person(name: name, role: member.character.flatMap { $0.isEmpty ? nil : $0 },
                                         department: "Acting", photo: Self.image(member.profile_path, size: "w185"))
            }
        let keyJobs: Set<String> = ["Director", "Screenplay", "Writer", "Creator", "Novel", "Producer",
                                    "Executive Producer", "Original Music Composer", "Director of Photography"]
        let crewList = (credits?.crew ?? []).compactMap(\.value)
            .filter { $0.job.map(keyJobs.contains) ?? false }
            .compactMap { member -> MetaExtras.Person? in
                guard let name = member.name else { return nil }
                return MetaExtras.Person(name: name, role: member.job, department: member.department,
                                         photo: Self.image(member.profile_path, size: "w185"))
            }
        return MetaExtras(
            imdbId: external_ids?.imdb_id ?? imdb, tmdbId: id, tmdbKind: isSeries ? "tv" : "movie",
            tvdbId: external_ids?.tvdb_id,
            originalTitle: original_title ?? original_name, originalLanguage: original_language,
            countries: (production_countries ?? []).compactMap(\.value?.name),
            companies: (production_companies ?? []).compactMap(\.value?.name),
            cast: Array(castList), crew: crewList,
            tmdbRating: (vote_count ?? 0) > 0 ? vote_average : nil, tmdbVotes: vote_count,
            textlessBackdrop: textlessBackdrop, backdrop: anyBackdrop, logo: logo, poster: poster,
            textlessPoster: textlessPoster, version: MetaExtras.currentVersion, provenance: [:], availability: availability(region: TMDB.region))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Extra details

/// What a title page can show beyond `StremioMeta`, with where each filled-in field came from.
/// Kept beside the meta (never inside it), so everything that reads `StremioMeta` is unchanged.
struct MetaExtras: Codable, Equatable {
    struct Person: Codable, Equatable, Hashable {
        let name: String
        /// The character for cast, the job for crew.
        let role: String?
        let department: String?
        let photo: String?
    }

    var imdbId: String?
    var tmdbId: Int?
    /// "movie" or "tv".
    var tmdbKind: String?
    var tvdbId: Int?
    var originalTitle: String?
    var originalLanguage: String?
    var countries: [String] = []
    var companies: [String] = []
    var cast: [Person] = []
    var crew: [Person] = []
    var tmdbRating: Double?
    var tmdbVotes: Int?
    var textlessBackdrop: String?
    var backdrop: String?
    var logo: String?
    var poster: String?
    var textlessPoster: String?
    /// Bumped when a TMDB field is added, so details saved by an older build are fetched again.
    var version: Int?
    static let currentVersion = 2
    /// Field name → the source that filled it (only fields the first source left empty).
    var provenance: [String: String] = [:]
    /// Where the title is licensed to stream, rent or buy. This is not whether your addons
    /// have a stream for it: the two are unrelated.
    var availability: Availability?

    /// Text-free art shaped for the frame: a portrait poster for a tall one, else a backdrop.
    /// A tall frame takes the full-size titled poster before a backdrop: a 1280-wide backdrop
    /// cropped to a phone's height shows its middle third blown up about three times.
    func heroArt(portrait: Bool) -> String? {
        guard portrait else { return textlessBackdrop }
        return textlessPoster ?? poster.map { $0.replacingOccurrences(of: "/w780/", with: "/original/") } ?? textlessBackdrop
    }

    struct Availability: Codable, Equatable {
        let region: String
        /// TMDB's "where to watch" page for the title.
        let link: String?
        let offers: [Offer]
        let checkedAt: Date

        /// Older than this, it's looked up again.
        static let freshFor: TimeInterval = 12 * 3600
        var isFresh: Bool { Date().timeIntervalSince(checkedAt) < Self.freshFor && region == TMDB.region }
    }

    struct Offer: Codable, Equatable, Hashable {
        enum Kind: String, Codable { case subscription, free, ads, rent, buy }
        let providerId: Int
        let name: String
        let logo: String?
        let kind: Kind
    }
}

// MARK: - Request gate

/// Lets at most `limit` callers through at once; the rest wait their turn.
actor RequestGate {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func enter() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty {
            running = max(running - 1, 0)
        } else {
            // The slot passes straight to the next caller.
            waiting.removeFirst().resume()
        }
    }
}
