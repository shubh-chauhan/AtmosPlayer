import Foundation

// MARK: - Metadata on disk
//
// Title details survive relaunches, so a title opened yesterday shows at once, offline too.
// Files live in Caches (iOS may clear them; that only costs a refetch). Nothing is kept past
// six months (TMDB's limit for anything that came from it).

/// How long saved details count as fresh. Past it they're refetched; if that fails, the old
/// copy is still shown.
struct MetaCachePolicy {
    var movie: TimeInterval = 24 * 3600
    /// A running series gets new episodes, so it's checked more often.
    var runningSeries: TimeInterval = 6 * 3600
    var endedSeries: TimeInterval = 24 * 3600
    /// Hard limit for anything saved.
    var maximumAge: TimeInterval = 180 * 24 * 3600
    /// Titles kept in memory; the least recently used one goes first.
    var memoryEntries = 200
    /// Files kept on disk; the oldest go first.
    var diskEntries = 2000

    static var current = MetaCachePolicy()

    func ttl(for meta: StremioMeta) -> TimeInterval {
        guard meta.type == "series" else { return movie }
        return meta.status == "Ended" ? endedSeries : runningSeries
    }
}

@MainActor
enum MetaCache {
    struct Entry: Codable {
        var meta: StremioMeta
        var extras: MetaExtras?
        /// The gaps were already filled from the other sources.
        var enriched: Bool
        var savedAt: Date

        func isFresh(_ policy: MetaCachePolicy = .current, now: Date = Date()) -> Bool {
            now.timeIntervalSince(savedAt) < policy.ttl(for: meta)
        }
    }

    private static var memory: [String: Entry] = [:]
    /// Keys from least to most recently used.
    private static var order: [String] = []
    private static var pruned = false

    private static let folder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("meta-v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static func file(_ key: String) -> URL {
        // Base64url of "type/id": any addon id is a safe file name.
        let name = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return folder.appendingPathComponent(name + ".json")
    }

    /// The saved entry (fresh or not) from memory, else disk (read off the main thread).
    static func entry(_ key: String) async -> Entry? {
        if let hit = memory[key] {
            touch(key)
            return hit
        }
        let url = file(key)
        let decoded = await Task.detached(priority: .userInitiated) { () -> Entry? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try? decoder.decode(Entry.self, from: data)
        }.value
        guard let decoded, Date().timeIntervalSince(decoded.savedAt) < MetaCachePolicy.current.maximumAge else { return nil }
        remember(key, decoded)
        return decoded
    }

    static func store(_ key: String, _ entry: Entry) {
        remember(key, entry)
        let url = file(key)
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            if let data = try? encoder.encode(entry) { try? data.write(to: url, options: .atomic) }
        }
        if !pruned {
            pruned = true
            let folder = folder
            let policy = MetaCachePolicy.current
            Task.detached(priority: .background) { prune(folder, policy: policy) }
        }
    }

    /// Updates only the extras of an entry already saved.
    static func storeExtras(_ key: String, _ extras: MetaExtras) async {
        guard var entry = await entry(key) else { return }
        entry.extras = extras
        store(key, entry)
    }

    private static func remember(_ key: String, _ entry: Entry) {
        memory[key] = entry
        touch(key)
        // Least recently used out, one at a time (never the whole cache).
        while order.count > MetaCachePolicy.current.memoryEntries {
            memory[order.removeFirst()] = nil
        }
    }

    private static func touch(_ key: String) {
        if let index = order.lastIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }

    /// Drops files past the age limit, then the oldest beyond the count limit.
    nonisolated private static func prune(_ folder: URL, policy: MetaCachePolicy) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let dated = files.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        let now = Date()
        for (index, item) in dated.enumerated()
        where index >= policy.diskEntries || now.timeIntervalSince(item.1) > policy.maximumAge {
            try? fm.removeItem(at: item.0)
        }
    }

    /// Empties memory and disk (Settings › Storage, with the image cache).
    static func clearAll() {
        memory.removeAll()
        order.removeAll()
        let folder = folder
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: url)
            }
        }
    }
}

// MARK: - ID map

/// IMDb ↔ TMDB ids, learnt from TMDB's /find and its external ids, saved between launches.
/// TVDB ids are kept with the title's extras.
@MainActor
enum IDMap {
    struct TMDBRef: Codable, Hashable {
        enum Kind: String, Codable { case movie, tv }
        let kind: Kind
        let id: Int
    }

    private struct Saved: Codable {
        var byIMDb: [String: TMDBRef] = [:]
        var savedAt: [String: Date] = [:]
    }

    private static var saved: Saved = load()
    private static var byTMDB: [TMDBRef: String] = Dictionary(saved.byIMDb.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    private static var pendingSave: Task<Void, Never>?

    private static let url: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("idmap-v1.json")

    static func tmdb(forIMDb imdb: String) -> TMDBRef? { saved.byIMDb[imdb] }
    static func imdb(forTMDB ref: TMDBRef) -> String? { byTMDB[ref] }

    static func record(imdb: String, tmdb: TMDBRef) {
        guard imdb.hasPrefix("tt"), saved.byIMDb[imdb] != tmdb else { return }
        saved.byIMDb[imdb] = tmdb
        saved.savedAt[imdb] = Date()
        byTMDB[tmdb] = imdb
        scheduleSave()
    }

    private static func load() -> Saved {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: url), var saved = try? decoder.decode(Saved.self, from: data) else { return Saved() }
        // Nothing older than six months (TMDB's limit).
        let limit = Date().addingTimeInterval(-MetaCachePolicy.current.maximumAge)
        for (imdb, date) in saved.savedAt where date < limit {
            saved.byIMDb[imdb] = nil
            saved.savedAt[imdb] = nil
        }
        return saved
    }

    /// Batched: one write a couple of seconds after the last change.
    private static func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            let snapshot = saved
            let url = url
            await Task.detached(priority: .utility) {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                if let data = try? encoder.encode(snapshot) { try? data.write(to: url, options: .atomic) }
            }.value
        }
    }
}

// MARK: - Saving StremioMeta

// Written with the same keys the decoder reads (Stremio's own), so a saved meta reads back
// through the one decoding path every addon answer already goes through.

extension StremioMeta: Encodable {
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
        try c.encodeIfPresent(runtime, forKey: AnyKey("runtime"))
        try c.encode(genres, forKey: AnyKey("genres"))
        try c.encode(videos, forKey: AnyKey("videos"))
        try c.encode(cast, forKey: AnyKey("cast"))
        try c.encode(directors, forKey: AnyKey("director"))
        try c.encode(writers, forKey: AnyKey("writer"))
        try c.encodeIfPresent(awards, forKey: AnyKey("awards"))
        try c.encodeIfPresent(country, forKey: AnyKey("country"))
        try c.encodeIfPresent(status, forKey: AnyKey("status"))
        try c.encodeIfPresent(released, forKey: AnyKey("released"))
        try c.encodeIfPresent(language, forKey: AnyKey("language"))
        if let trailerId {
            try c.encode([["ytId": trailerId]], forKey: AnyKey("trailerStreams"))
        }
        if let shareURL {
            try c.encode([["category": "share", "url": shareURL]], forKey: AnyKey("links"))
        }
    }
}

extension StremioMeta.Video: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(id, forKey: AnyKey("id"))
        try c.encodeIfPresent(title, forKey: AnyKey("title"))
        try c.encodeIfPresent(season, forKey: AnyKey("season"))
        try c.encodeIfPresent(episode, forKey: AnyKey("episode"))
        try c.encodeIfPresent(released, forKey: AnyKey("released"))
        try c.encodeIfPresent(thumbnail, forKey: AnyKey("thumbnail"))
        try c.encodeIfPresent(overview, forKey: AnyKey("overview"))
        try c.encodeIfPresent(rating, forKey: AnyKey("rating"))
    }
}
