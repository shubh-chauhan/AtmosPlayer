import Foundation

// MARK: - Stremio addon protocol
//
// An addon is a base URL serving JSON:
//   {base}/manifest.json
//   {base}/catalog/{type}/{id}.json            {base}/catalog/{type}/{id}/search={query}.json
//   {base}/meta/{type}/{id}.json
//   {base}/stream/{type}/{videoId}.json        (series episodes: "tt0903747:1:2")
// Addons are written by many people, so every model below decodes leniently: a missing or
// oddly typed field becomes nil instead of failing the whole response.

// MARK: Lenient decoding helpers

struct LossyElement<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension KeyedDecodingContainer {
    func lossyString(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(d) }
        return nil
    }

    func lossyInt(_ key: Key) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int(s) }
        return nil
    }

    func lossyBool(_ key: Key) -> Bool? {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        return nil
    }

    func lossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        guard let items = try? decodeIfPresent([LossyElement<T>].self, forKey: key) else { return [] }
        return items.compactMap { $0.value }
    }

    func stringArray(_ key: Key) -> [String]? {
        guard let items = try? decodeIfPresent([LossyElement<String>].self, forKey: key) else { return nil }
        return items.compactMap { $0.value }
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

// MARK: Manifest

struct StremioManifest: Decodable {
    let id: String
    let name: String
    let version: String?
    let description: String?
    let logo: String?
    let types: [String]
    let idPrefixes: [String]?
    let resources: [ResourceEntry]
    let catalogs: [StremioCatalog]

    struct ResourceEntry: Decodable {
        let name: String
        let types: [String]?
        let idPrefixes: [String]?

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
                self.name = name
                types = nil
                idPrefixes = nil
                return
            }
            let c = try decoder.container(keyedBy: AnyKey.self)
            guard let name = c.lossyString(AnyKey("name")) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "resource without name"))
            }
            self.name = name
            types = c.stringArray(AnyKey("types"))
            idPrefixes = c.stringArray(AnyKey("idPrefixes"))
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let id = c.lossyString(AnyKey("id")), let name = c.lossyString(AnyKey("name")) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "manifest needs id and name"))
        }
        self.id = id
        self.name = name
        version = c.lossyString(AnyKey("version"))
        description = c.lossyString(AnyKey("description"))
        logo = c.lossyString(AnyKey("logo"))
        types = c.stringArray(AnyKey("types")) ?? []
        idPrefixes = c.stringArray(AnyKey("idPrefixes"))
        resources = c.lossyArray(ResourceEntry.self, AnyKey("resources"))
        catalogs = c.lossyArray(StremioCatalog.self, AnyKey("catalogs"))
    }

    /// Whether this addon answers `resource` ("meta", "stream", …) for this type and id.
    func supports(_ resource: String, type: String, id: String) -> Bool {
        guard let entry = resources.first(where: { $0.name == resource }) else { return false }
        let entryTypes = entry.types ?? types
        if !entryTypes.isEmpty && !entryTypes.contains(type) { return false }
        let prefixes = entry.idPrefixes ?? idPrefixes ?? []
        if !prefixes.isEmpty && !prefixes.contains(where: { id.hasPrefix($0) }) { return false }
        return true
    }

    var resourceNames: [String] { resources.map(\.name) }
}

struct StremioCatalog: Decodable {
    let type: String
    let id: String
    let name: String?
    let requiredExtras: [String]
    let supportsSearch: Bool
    /// The addon pages this catalog with `skip=` and filters it with `genre=` (from these).
    let supportsSkip: Bool
    let genreOptions: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let type = c.lossyString(AnyKey("type")), let id = c.lossyString(AnyKey("id")) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "catalog needs type and id"))
        }
        self.type = type
        self.id = id
        name = c.lossyString(AnyKey("name"))

        var required: [String] = c.stringArray(AnyKey("extraRequired")) ?? []
        var supported: [String] = c.stringArray(AnyKey("extraSupported")) ?? []
        var genres: [String] = c.stringArray(AnyKey("genres")) ?? []
        for extra in c.lossyArray(Extra.self, AnyKey("extra")) {
            supported.append(extra.name)
            if extra.isRequired { required.append(extra.name) }
            if extra.name == "genre", !extra.options.isEmpty { genres = extra.options }
        }
        requiredExtras = required
        supportsSearch = supported.contains("search")
        supportsSkip = supported.contains("skip")
        genreOptions = supported.contains("genre") ? genres : []
    }

    private struct Extra: Decodable {
        let name: String
        let isRequired: Bool
        let options: [String]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            guard let name = c.lossyString(AnyKey("name")) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "extra needs name"))
            }
            self.name = name
            isRequired = c.lossyBool(AnyKey("isRequired")) ?? false
            options = c.stringArray(AnyKey("options")) ?? []
        }
    }

    /// Browsable as a plain row: nothing has to be filled in.
    var isBrowsable: Bool { requiredExtras.isEmpty }
    /// Usable for search: search is supported and it is the only thing required.
    var isSearchable: Bool { supportsSearch && requiredExtras.allSatisfy { $0 == "search" } }
}

// MARK: Catalog / meta / stream

struct MetaPreview: Decodable, Identifiable, Hashable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let logo: String?
    let description: String?
    let releaseInfo: String?
    let imdbRating: String?
    let genres: [String]
    let runtime: String?
    /// YouTube id of the first trailer (Cinemeta catalogs include them).
    let trailerId: String?

    private struct TrailerStream: Decodable { let ytId: String? }
    private struct Trailer: Decodable { let source: String?; let type: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let id = c.lossyString(AnyKey("id")), let name = c.lossyString(AnyKey("name")) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "meta needs id and name"))
        }
        self.id = id
        self.name = name
        type = c.lossyString(AnyKey("type")) ?? "movie"
        poster = c.lossyString(AnyKey("poster"))
        background = c.lossyString(AnyKey("background"))
        logo = c.lossyString(AnyKey("logo"))
        description = c.lossyString(AnyKey("description"))
        releaseInfo = c.lossyString(AnyKey("releaseInfo"))
        imdbRating = c.lossyString(AnyKey("imdbRating"))
        genres = c.stringArray(AnyKey("genres")) ?? c.stringArray(AnyKey("genre")) ?? []
        runtime = c.lossyString(AnyKey("runtime"))
        trailerId = c.lossyArray(TrailerStream.self, AnyKey("trailerStreams")).compactMap(\.ytId).first
            ?? c.lossyArray(Trailer.self, AnyKey("trailers")).first(where: { $0.type == nil || $0.type == "Trailer" })?.source
    }
}

/// A subtitle file offered by a subtitles addon (e.g. OpenSubtitles).
struct AddonSubtitle: Decodable, Identifiable, Hashable {
    let id: String
    let url: String
    let lang: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let url = c.lossyString(AnyKey("url")) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "subtitle needs url"))
        }
        self.url = url
        id = c.lossyString(AnyKey("id")) ?? url
        lang = c.lossyString(AnyKey("lang")) ?? "und"
    }

    /// "English" for "eng" / "en", the raw code when unknown.
    var languageName: String {
        let code = lang.lowercased()
        if let name = Locale.current.localizedString(forLanguageCode: code) { return name }
        let threeToTwo = ["eng": "en", "spa": "es", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de",
                          "ita": "it", "por": "pt", "pob": "pt", "hin": "hi", "jpn": "ja", "kor": "ko",
                          "chi": "zh", "zho": "zh", "ara": "ar", "rus": "ru", "dut": "nl", "nld": "nl",
                          "tur": "tr", "pol": "pl", "swe": "sv", "tam": "ta", "tel": "te", "ben": "bn"]
        if let two = threeToTwo[code], let name = Locale.current.localizedString(forLanguageCode: two) {
            return code == "pob" ? "\(name) (Brazil)" : name
        }
        return lang
    }
}

private struct SubtitlesResponse: Decodable {
    let subtitles: [AddonSubtitle]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        subtitles = c.lossyArray(AddonSubtitle.self, AnyKey("subtitles"))
    }
}

struct StremioMeta: Decodable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let logo: String?
    let description: String?
    let releaseInfo: String?
    let imdbRating: String?
    let runtime: String?
    let genres: [String]
    let videos: [Video]
    /// People and awards (Cinemeta fills these; other addons may not).
    let cast: [String]
    let directors: [String]
    let writers: [String]
    let awards: String?
    let country: String?
    /// "Ended", "Continuing" (series, Cinemeta).
    let status: String?
    /// ISO date of the (first) release.
    let released: String?
    /// YouTube id of the trailer, when the addon lists one.
    let trailerId: String?
    /// Stremio's share link (strem.io/s/…).
    let shareURL: String?
    let language: String?

    private struct TrailerStream: Decodable { let ytId: String? }
    private struct Trailer: Decodable { let source: String?; let type: String? }
    private struct Link: Decodable { let category: String?; let url: String? }

    struct Video: Decodable, Identifiable, Hashable {
        let id: String
        let title: String?
        let season: Int?
        let episode: Int?
        let released: String?
        let thumbnail: String?
        let overview: String?
        /// Episode rating out of 10 (Cinemeta).
        let rating: String?

        /// The air date, parsed.
        var releaseDate: Date? { StremioMeta.parseDate(released) }
        /// Not out yet.
        var upcoming: Bool { (releaseDate ?? .distantPast) > Date() }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            guard let id = c.lossyString(AnyKey("id")) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "video needs id"))
            }
            self.id = id
            title = c.lossyString(AnyKey("title")) ?? c.lossyString(AnyKey("name"))
            season = c.lossyInt(AnyKey("season"))
            episode = c.lossyInt(AnyKey("episode")) ?? c.lossyInt(AnyKey("number"))
            released = c.lossyString(AnyKey("released"))
            thumbnail = c.lossyString(AnyKey("thumbnail"))
            overview = c.lossyString(AnyKey("overview")) ?? c.lossyString(AnyKey("description"))
            let rawRating = c.lossyString(AnyKey("rating"))
            rating = (rawRating == nil || rawRating == "0" || rawRating == "0.0") ? nil : rawRating
        }

        /// "S1E2", or nil when the addon gives no numbers.
        var code: String? {
            guard let season, let episode else { return nil }
            return "S\(season)E\(episode)"
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let id = c.lossyString(AnyKey("id")), let name = c.lossyString(AnyKey("name")) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "meta needs id and name"))
        }
        self.id = id
        self.name = name
        type = c.lossyString(AnyKey("type")) ?? "movie"
        poster = c.lossyString(AnyKey("poster"))
        background = c.lossyString(AnyKey("background"))
        logo = c.lossyString(AnyKey("logo"))
        description = c.lossyString(AnyKey("description"))
        releaseInfo = c.lossyString(AnyKey("releaseInfo"))
        imdbRating = c.lossyString(AnyKey("imdbRating"))
        runtime = c.lossyString(AnyKey("runtime"))
        genres = c.stringArray(AnyKey("genres")) ?? c.stringArray(AnyKey("genre")) ?? []
        videos = c.lossyArray(Video.self, AnyKey("videos"))
        cast = c.stringArray(AnyKey("cast")) ?? []
        directors = c.stringArray(AnyKey("director")) ?? []
        writers = c.stringArray(AnyKey("writer")) ?? []
        awards = c.lossyString(AnyKey("awards"))
        country = c.lossyString(AnyKey("country"))
        status = c.lossyString(AnyKey("status"))
        released = c.lossyString(AnyKey("released"))
        language = c.lossyString(AnyKey("language"))
        trailerId = c.lossyArray(TrailerStream.self, AnyKey("trailerStreams")).compactMap(\.ytId).first
            ?? c.lossyArray(Trailer.self, AnyKey("trailers")).first(where: { $0.type == nil || $0.type == "Trailer" })?.source
        shareURL = c.lossyArray(Link.self, AnyKey("links")).first(where: { $0.category == "share" })?.url
    }

    private static let isoFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parseDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return isoFull.date(from: text) ?? isoPlain.date(from: text)
    }

    var releaseDate: Date? { Self.parseDate(released) }
}

struct StremioStream: Decodable, Identifiable {
    let id = UUID()
    let url: String?
    let infoHash: String?
    let externalUrl: String?
    let ytId: String?
    let name: String?
    let title: String?
    let description: String?
    let filename: String?
    /// Streams of the same release across episodes share this, which is how the next episode
    /// gets the same quality and source.
    let bingeGroup: String?
    let requestHeaders: [String: String]
    /// Torrent streams: which file in the torrent, its trackers, and name filters.
    let fileIdx: Int?
    let sources: [String]
    let fileMustInclude: [String]
    /// Quality, HDR, sound and size read from the text above, once.
    let traits: StreamTraits

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        url = c.lossyString(AnyKey("url"))
        infoHash = c.lossyString(AnyKey("infoHash"))
        fileIdx = c.lossyInt(AnyKey("fileIdx"))
        sources = c.stringArray(AnyKey("sources")) ?? []
        fileMustInclude = c.stringArray(AnyKey("fileMustInclude")) ?? []
        externalUrl = c.lossyString(AnyKey("externalUrl"))
        ytId = c.lossyString(AnyKey("ytId"))
        name = c.lossyString(AnyKey("name"))
        title = c.lossyString(AnyKey("title"))
        description = c.lossyString(AnyKey("description"))

        var filename: String?
        var binge: String?
        var headers: [String: String] = [:]
        if let hints = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("behaviorHints")) {
            filename = hints.lossyString(AnyKey("filename"))
            binge = hints.lossyString(AnyKey("bingeGroup"))
            if let proxy = try? hints.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("proxyHeaders")),
               let request = try? proxy.decodeIfPresent([String: String].self, forKey: AnyKey("request")) {
                headers = request
            }
        }
        self.filename = filename
        bingeGroup = binge
        requestHeaders = headers
        traits = StreamTraits([name, title, description, filename].compactMap { $0 }.joined(separator: " "))
    }

    /// The http(s) link this app plays: the addon's direct link, or for a torrent, the file
    /// served by your Stremio streaming server (the same URL Stremio itself builds).
    var playableURL: URL? {
        Self.makeURL(url: url, infoHash: infoHash, fileIdx: fileIdx, sources: sources,
                     fileMustInclude: fileMustInclude)
    }

    static func makeURL(url: String?, infoHash: String?, fileIdx: Int?, sources: [String],
                        fileMustInclude: [String]) -> URL? {
        if let url, let parsed = URL(string: url),
           let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return parsed
        }
        if let infoHash, let server = StreamingServer.baseURL {
            var components = URLComponents(string: server + "/" + infoHash.lowercased() + "/" + String(fileIdx ?? -1))
            var query = sources.map { URLQueryItem(name: "tr", value: $0) }
            query += fileMustInclude.map { URLQueryItem(name: "f", value: $0) }
            if !query.isEmpty { components?.queryItems = query }
            return components?.url
        }
        return nil
    }

    var isTorrent: Bool { url == nil && infoHash != nil }

    /// Why a stream without a direct link cannot play here.
    var unplayableReason: String {
        if infoHash != nil { return "Torrent: add your streaming server in the Stremio tab" }
        if externalUrl != nil { return "Opens in another app or website" }
        if ytId != nil { return "YouTube video" }
        return "No direct link"
    }

    /// Everything the addon wrote about the stream, used for the badges.
    var fullText: String {
        [name, title, description, filename].compactMap { $0 }.joined(separator: "\n")
    }

    var badges: [String] { traits.badges.map(\.badge) }
}

private struct CatalogResponse: Decodable {
    let metas: [MetaPreview]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        metas = c.lossyArray(MetaPreview.self, AnyKey("metas"))
    }
}

private struct MetaResponse: Decodable {
    let meta: StremioMeta
}

private struct StreamResponse: Decodable {
    let streams: [StremioStream]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        streams = c.lossyArray(StremioStream.self, AnyKey("streams"))
    }
}

// MARK: Installed addon + client

struct InstalledAddon: Identifiable {
    var id: String { manifest.id }
    /// The manifest URL the user installed (https, ends in /manifest.json).
    let transportURL: String
    let manifest: StremioManifest

    /// Everything before "/manifest.json".
    var base: String {
        var url = transportURL
        if let query = url.firstIndex(of: "?") { url = String(url[..<query]) }
        if let range = url.range(of: "/manifest.json", options: [.backwards, .caseInsensitive]) {
            return String(url[..<range.lowerBound])
        }
        return url.hasSuffix("/") ? String(url.dropLast()) : url
    }
}

enum StremioError: LocalizedError {
    case badURL
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: return "That isn't a valid addon link."
        case .http(let code): return "The addon answered with HTTP \(code)."
        }
    }
}

enum StremioClient {
    static let cinemetaURL = "https://v3-cinemeta.strem.io/manifest.json"

    /// Accepts what people paste: stremio:// links, links without a scheme, links without /manifest.json.
    static func normalizeManifestURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("stremio://") {
            text = "https://" + text.dropFirst("stremio://".count)
        } else if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text), components.host != nil else { return nil }
        if !components.path.lowercased().hasSuffix("manifest.json") {
            var path = components.path
            while path.hasSuffix("/") { path.removeLast() }
            components.path = path + "/manifest.json"
        }
        return components.url
    }

    static func fetchManifest(_ url: URL) async throws -> (StremioManifest, Data) {
        let data = try await get(url, gated: false)
        return (try JSONDecoder().decode(StremioManifest.self, from: data), data)
    }

    static func catalog(_ addon: InstalledAddon, _ catalog: StremioCatalog, search: String? = nil,
                        genre: String? = nil, skip: Int = 0,
                        timeout: TimeInterval = 25) async throws -> [MetaPreview] {
        // Extras only when the catalog lists them (an addon may reject ones it doesn't know).
        var parts: [String] = []
        if let search { parts.append("search=\(encode(search))") }
        if let genre, !catalog.genreOptions.isEmpty { parts.append("genre=\(encode(genre))") }
        if skip > 0, catalog.supportsSkip { parts.append("skip=\(skip)") }
        let extra = parts.isEmpty ? "" : "/" + parts.joined(separator: "&")
        let url = try resourceURL(addon, "catalog", catalog.type, catalog.id, extra: extra)
        return try JSONDecoder().decode(CatalogResponse.self, from: try await get(url, timeout: timeout)).metas
    }

    static func meta(_ addon: InstalledAddon, type: String, id: String,
                     timeout: TimeInterval = 25) async throws -> StremioMeta {
        let url = try resourceURL(addon, "meta", type, id)
        return try JSONDecoder().decode(MetaResponse.self, from: try await get(url, timeout: timeout)).meta
    }

    static func streams(_ addon: InstalledAddon, type: String, id: String) async throws -> [StremioStream] {
        let url = try resourceURL(addon, "stream", type, id)
        return try JSONDecoder().decode(StreamResponse.self, from: try await get(url, gated: false)).streams
    }

    static func subtitles(_ addon: InstalledAddon, type: String, id: String) async throws -> [AddonSubtitle] {
        let url = try resourceURL(addon, "subtitles", type, id)
        return try JSONDecoder().decode(SubtitlesResponse.self, from: try await get(url, gated: false)).subtitles
    }

    private static func resourceURL(_ addon: InstalledAddon, _ resource: String, _ type: String, _ id: String, extra: String = "") throws -> URL {
        guard let url = URL(string: "\(addon.base)/\(resource)/\(encode(type))/\(encode(id))\(extra).json") else {
            throw StremioError.badURL
        }
        return url
    }

    /// Catalog, meta and search calls: at most a dozen at once, so opening Home or searching
    /// never floods an addon. Streams, subtitles and manifests (what you're waiting on) skip it.
    private static let gate = RequestGate(limit: 12)

    /// The body of a 2xx answer. A 429 is tried once more after the wait it asks for (≤ 5 s).
    private static func get(_ url: URL, timeout: TimeInterval = 25, gated: Bool = true) async throws -> Data {
        if gated { await gate.enter() }
        defer { if gated { Task { await gate.leave() } } }
        for attempt in 0..<2 {
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 429, attempt == 0 {
                    let after = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1
                    try await Task.sleep(nanoseconds: UInt64(min(max(after, 0.5), 5) * 1_000_000_000))
                    continue
                }
                if !(200..<300).contains(http.statusCode) { throw StremioError.http(http.statusCode) }
            }
            return data
        }
        throw StremioError.http(429)
    }

    /// JavaScript's encodeURIComponent, which is what Stremio itself uses for ids and extras.
    private static let componentAllowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: componentAllowed) ?? value
    }
}

/// Your Stremio streaming server (the "Streaming server URL" in Stremio's settings). It turns
/// torrent streams into normal links this player can open.
enum StreamingServer {
    static let key = "stremio.streamingServer"

    /// The saved address without a trailing slash, or nil when none is set.
    static var baseURL: String? {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
        return normalize(raw)
    }

    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return text
    }

    /// Asks the server for its settings, the same check Stremio does. Returns nil when it answers.
    static func check(_ base: String) async -> String? {
        guard let url = URL(string: base + "/settings") else { return "That isn't a valid address." }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, (try? JSONSerialization.jsonObject(with: data)) != nil else {
                return "The server answered with HTTP \(code)."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
