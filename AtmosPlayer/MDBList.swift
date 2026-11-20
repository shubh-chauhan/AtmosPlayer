import Foundation

// MARK: - MDBList ratings
//
// Rotten Tomatoes (critics and audience), Metacritic, Letterboxd and Trakt scores for a title,
// from MDBList (mdblist.com), which gathers them by IMDb id. Needs a free MDBList API key, from
// the MDBLIST_KEY repo secret (scrambled into Info.plist like TMDB's token). Without it the
// title page shows IMDb and TMDB only, as before.
// Free keys allow about 1000 requests a day, so answers are saved for a week.

enum MDBList {
    static let key: String? = TMDB.descramble(Bundle.main.object(forInfoDictionaryKey: "MDBListKey") as? String)
    static var isConfigured: Bool { key != nil }

    /// One score as MDBList reports it. `value` is on the source's own scale (Tomatoes and
    /// Metacritic 0…100, Letterboxd 0…5), `score` is MDBList's 0…100 version of it.
    struct Rating: Codable, Equatable, Hashable {
        let source: String
        let value: Double?
        let score: Double?
        let votes: Int?
    }

    struct Saved: Codable {
        let ratings: [Rating]
        let savedAt: Date
    }

    /// Sources shown, in this order.
    static let shown = ["tomatoes", "tomatoesaudience", "metacritic", "letterboxd", "trakt"]

    @MainActor private static var memory: [String: Saved] = [:]
    @MainActor private static var inflight: [String: Task<[Rating], Never>] = [:]

    private static let folder: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mdblist-v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// The scores for an IMDb title (empty without a key, for other ids, or when MDBList has none).
    @MainActor
    static func ratings(imdb: String, type: String) async -> [Rating] {
        guard let key, imdb.hasPrefix("tt") else { return [] }
        if let hit = memory[imdb], Date().timeIntervalSince(hit.savedAt) < 7 * 24 * 3600 { return hit.ratings }
        let file = folder.appendingPathComponent(imdb + ".json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data),
           Date().timeIntervalSince(saved.savedAt) < 7 * 24 * 3600 {
            memory[imdb] = saved
            return saved.ratings
        }
        if let running = inflight[imdb] { return await running.value }
        let task = Task<[Rating], Never> {
            let media = type == "movie" ? "movie" : "show"
            var found = await fetch("https://api.mdblist.com/imdb/\(media)/\(imdb)?apikey=\(key)")
            if found == nil {
                // The older endpoint, which takes any IMDb id without the type.
                found = await fetch("https://mdblist.com/api/?apikey=\(key)&i=\(imdb)")
            }
            return found ?? []
        }
        inflight[imdb] = task
        let result = await task.value
        inflight[imdb] = nil
        let saved = Saved(ratings: result, savedAt: Date())
        memory[imdb] = saved
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: file, options: .atomic) }
        return result
    }

    private static func fetch(_ address: String) async -> [Rating]? {
        guard let url = URL(string: address), let data = await MetaHTTP.data(url) else { return nil }
        return parse(data)
    }

    /// The "ratings" list of an MDBList answer, keeping only scores that are set.
    static func parse(_ data: Data) -> [Rating]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["ratings"] as? [[String: Any]] else { return nil }
        func number(_ any: Any?) -> Double? {
            if let n = any as? NSNumber { return n.doubleValue }
            if let s = any as? String { return Double(s) }
            return nil
        }
        return list.compactMap { item -> Rating? in
            guard let source = item["source"] as? String else { return nil }
            let value = number(item["value"]), score = number(item["score"])
            guard (value ?? 0) > 0 || (score ?? 0) > 0 else { return nil }
            return Rating(source: source, value: value, score: score, votes: number(item["votes"]).map { Int($0) })
        }
        .filter { shown.contains($0.source) }
        .sorted { (shown.firstIndex(of: $0.source) ?? 99) < (shown.firstIndex(of: $1.source) ?? 99) }
    }

    /// How a score reads on its tile: "93%", "74", "4.1".
    static func text(_ rating: Rating) -> String {
        switch rating.source {
        case "tomatoes", "tomatoesaudience":
            return String(format: "%.0f%%", rating.value ?? rating.score ?? 0)
        case "metacritic":
            return String(format: "%.0f", rating.value ?? rating.score ?? 0)
        case "letterboxd":
            if let value = rating.value, value <= 5 { return String(format: "%.1f", value) }
            return String(format: "%.1f", (rating.score ?? 0) / 20)
        default:
            return String(format: "%.0f%%", rating.score ?? rating.value ?? 0)
        }
    }

    static func label(_ source: String) -> String {
        switch source {
        case "tomatoes": return "Tomatometer"
        case "tomatoesaudience": return "Audience"
        case "metacritic": return "Metascore"
        case "letterboxd": return "Letterboxd"
        case "trakt": return "Trakt"
        default: return source.capitalized
        }
    }

    static func symbol(_ rating: Rating) -> String {
        switch rating.source {
        case "tomatoes": return (rating.value ?? rating.score ?? 0) >= 60 ? "🍅" : "🤢"
        case "tomatoesaudience": return (rating.value ?? rating.score ?? 0) >= 60 ? "🍿" : "🥫"
        default: return ""
        }
    }
}
