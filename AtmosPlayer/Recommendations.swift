import SwiftUI
import Combine

// MARK: - Recommendations
//
// A transparent, weighted ranking (no machine learning): what you watched, finished, saved
// and gave up on becomes a taste profile (genres, people, languages, decades, movies vs series);
// TMDB's recommendations, similar titles and discover lists are the candidates; each candidate
// is scored against the profile and its own quality, and titles you've seen are left out.
// It all runs on the phone from the stores the app already keeps. Needs a TMDB token for the
// candidates; without one, Home keeps its genre-based "Because You Watched" row.

// MARK: Viewing log

/// A history of what happened, derived from the existing stores (it never records playback
/// itself): started, past 25/50/75 %, finished, episode finished, added to or removed from My List.
struct ViewingEvent: Codable, Equatable {
    enum Kind: String, Codable { case started, progressed, completed, episodeCompleted, listAdded, listRemoved }
    let kind: Kind
    let metaId: String
    let videoId: String?
    let type: String
    let at: Date
    var progress: Double? = nil
}

@MainActor
final class ViewingLog: ObservableObject {
    static let shared = ViewingLog()

    @Published private(set) var events: [ViewingEvent] = []
    private var watchedSeen: [String: Set<String>] = [:]
    private var progressSeen: [String: Double] = [:]
    private var listSeen: Set<String> = []
    private var subscriptions: Set<AnyCancellable> = []
    private var observing = false
    private var pendingSave: Task<Void, Never>?
    private let limit = 3000

    private static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("viewing-log-v1.json")
    }()

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf: Self.url), let saved = try? decoder.decode([ViewingEvent].self, from: data) {
            events = saved
        }
    }

    /// Starts following the stores (once). The first time ever, what's already watched becomes
    /// history at the dates the stores have for it.
    func observe(watch: WatchStore, favorites: FavoritesStore) {
        guard !observing else { return }
        observing = true
        let records = WatchedStore.shared.records
        if events.isEmpty {
            for (metaId, record) in records {
                let date = record.changed == .distantPast ? Date() : record.changed
                for video in record.videos { append(Self.finished(metaId: metaId, videoId: video, at: date)) }
            }
        }
        watchedSeen = records.mapValues(\.videos)
        progressSeen = Dictionary(watch.entries.map { ($0.id, $0.progress) }, uniquingKeysWith: max)
        listSeen = Set(favorites.items.map(\.id))

        // The stores change on the main thread; delivered there too.
        WatchedStore.shared.$records.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] records in MainActor.assumeIsolated { self?.watchedChanged(records) } }
            .store(in: &subscriptions)
        watch.$entries.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] entries in MainActor.assumeIsolated { self?.progressChanged(entries) } }
            .store(in: &subscriptions)
        favorites.$items.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] items in MainActor.assumeIsolated { self?.listChanged(items) } }
            .store(in: &subscriptions)
    }

    private static func finished(metaId: String, videoId: String, at: Date) -> ViewingEvent {
        let episode = videoId != metaId && videoId.contains(":")
        return ViewingEvent(kind: episode ? .episodeCompleted : .completed, metaId: metaId, videoId: videoId,
                            type: episode ? "series" : "movie", at: at, progress: 1)
    }

    private func watchedChanged(_ records: [String: WatchedStore.Record]) {
        for (metaId, record) in records {
            let new = record.videos.subtracting(watchedSeen[metaId] ?? [])
            for video in new { append(Self.finished(metaId: metaId, videoId: video, at: Date())) }
        }
        watchedSeen = records.mapValues(\.videos)
    }

    private func progressChanged(_ entries: [WatchStore.Entry]) {
        for entry in entries {
            let old = progressSeen[entry.id]
            let ref = entry.ref
            if old == nil, entry.position > 0 {
                append(ViewingEvent(kind: .started, metaId: ref.metaId, videoId: ref.videoId, type: ref.type,
                                    at: entry.updated, progress: entry.progress))
            } else if let old {
                for mark in [0.25, 0.5, 0.75] where old < mark && entry.progress >= mark {
                    append(ViewingEvent(kind: .progressed, metaId: ref.metaId, videoId: ref.videoId, type: ref.type,
                                        at: entry.updated, progress: mark))
                }
            }
            progressSeen[entry.id] = entry.progress
        }
    }

    private func listChanged(_ items: [MetaRef]) {
        let now = Set(items.map(\.id))
        for item in items where !listSeen.contains(item.id) {
            append(ViewingEvent(kind: .listAdded, metaId: item.id, videoId: nil, type: item.type, at: Date()))
        }
        for id in listSeen.subtracting(now) {
            append(ViewingEvent(kind: .listRemoved, metaId: id, videoId: nil, type: "", at: Date()))
        }
        listSeen = now
    }

    private func append(_ event: ViewingEvent) {
        events.append(event)
        if events.count > limit { events.removeFirst(events.count - limit) }
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            let snapshot = events
            let url = Self.url
            await Task.detached(priority: .utility) {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                if let data = try? encoder.encode(snapshot) { try? data.write(to: url, options: .atomic) }
            }.value
        }
    }

    /// Titles started weeks ago and left near the start.
    func abandoned(_ entries: [WatchStore.Entry], now: Date = Date()) -> Set<String> {
        Set(entries.filter { $0.progress < 0.2 && now.timeIntervalSince($0.updated) > 21 * 86400 }.map(\.ref.metaId))
    }
}

// MARK: Taste

/// How much one title says about your taste, and when.
struct TasteSignal: Equatable {
    let metaId: String
    let type: String
    let name: String
    let weight: Double
    let at: Date
}

enum TasteSignals {
    /// One signal per title from the stores: finished (strongest), watching, abandoned
    /// (negative), My List, Stremio library. Older signals count less (half every 120 days).
    static func collect(records: [String: WatchedStore.Record], watching: [WatchStore.Entry],
                        list: [MetaRef], library: [MetaRef], abandoned: Set<String>,
                        now: Date = Date()) -> [TasteSignal] {
        struct Sum { var type: String; var name: String; var weight: Double; var at: Date }
        var sums: [String: Sum] = [:]
        func add(_ id: String, _ type: String, _ name: String, _ weight: Double, _ at: Date) {
            var sum = sums[id] ?? Sum(type: type, name: name, weight: 0, at: .distantPast)
            sum.weight += weight
            sum.at = max(sum.at, at)
            if sum.name.isEmpty { sum.name = name }
            if type == "series" { sum.type = "series" }
            sums[id] = sum
        }
        for (metaId, record) in records where !record.videos.isEmpty {
            // An episode id is the title's id plus more ("kitsu:N" alone is an anime film).
            let series = record.videos.contains { $0 != metaId && $0.contains(":") }
            let at = record.changed == .distantPast ? now.addingTimeInterval(-180 * 86400) : record.changed
            add(metaId, series ? "series" : "movie", "", series ? 2 + Double(min(record.videos.count, 10)) * 0.2 : 3, at)
        }
        for entry in watching {
            let ref = entry.ref
            let weight = abandoned.contains(ref.metaId) ? -1 : 1 + entry.progress
            add(ref.metaId, ref.type, ref.name, weight, entry.updated)
        }
        for ref in list { add(ref.id, ref.type, ref.name, 1.2, now.addingTimeInterval(-30 * 86400)) }
        for ref in library { add(ref.id, ref.type, ref.name, 0.8, now.addingTimeInterval(-60 * 86400)) }
        return sums.map { id, sum in
            let days = max(now.timeIntervalSince(sum.at), 0) / 86400
            return TasteSignal(metaId: id, type: sum.type, name: sum.name,
                               weight: sum.weight * pow(0.5, days / 120), at: sum.at)
        }
        .sorted { $0.weight > $1.weight }
    }
}

/// What you like, each value from -1 (avoid) to 1 (favourite).
struct TasteProfile: Equatable {
    var genres: [String: Double] = [:]
    var people: [String: Double] = [:]
    /// ISO 639-1 codes ("en", "ko"), from TMDB.
    var languages: [String: Double] = [:]
    var decades: [Int: Double] = [:]
    /// 0 = only movies, 1 = only series.
    var seriesShare: Double = 0.5

    var isEmpty: Bool { genres.isEmpty }

    /// Each title's weight is shared out among its genres, people…, so one title with many
    /// genres doesn't outweigh several focused ones; then every scale is set so its top is 1.
    static func build(_ signals: [TasteSignal], metas: [String: StremioMeta], extras: [String: MetaExtras]) -> TasteProfile {
        var profile = TasteProfile()
        var series = 0.0, total = 0.0
        for signal in signals {
            let w = signal.weight
            if w > 0 {
                total += w
                if signal.type == "series" { series += w }
            }
            guard let meta = metas[signal.metaId] else { continue }
            if !meta.genres.isEmpty {
                for genre in meta.genres { profile.genres[genre, default: 0] += w / Double(meta.genres.count) }
            }
            let people = Array(meta.cast.prefix(5)) + meta.directors.prefix(2)
            for person in people { profile.people[person, default: 0] += w * 0.5 / Double(max(people.count, 1)) }
            if let language = extras[signal.metaId]?.originalLanguage { profile.languages[language, default: 0] += w }
            if let year = meta.releaseInfo.flatMap({ Int($0.prefix(4)) }) { profile.decades[year / 10 * 10, default: 0] += w }
        }
        if total > 0 { profile.seriesShare = series / total }
        func normalised<K: Hashable>(_ values: [K: Double]) -> [K: Double] {
            let top = values.values.map(abs).max() ?? 0
            guard top > 0 else { return [:] }
            return values.mapValues { $0 / top }
        }
        profile.genres = normalised(profile.genres)
        profile.people = normalised(profile.people)
        profile.languages = normalised(profile.languages)
        profile.decades = normalised(profile.decades)
        return profile
    }

    /// Favourite genres, best first.
    func topGenres(_ count: Int) -> [String] {
        genres.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(count).map(\.key)
    }

    /// 0…1: how well a title's genres match (the average of its genres' scores, floored at 0).
    func genreAffinity(_ titleGenres: [String]) -> Double {
        guard !titleGenres.isEmpty, !genres.isEmpty else { return 0 }
        let sum = titleGenres.reduce(0) { $0 + (genres[$1] ?? 0) }
        return max(min(sum / Double(titleGenres.count), 1), 0)
    }
}

// MARK: Ranking

/// A title that might be recommended, with what TMDB says about it.
struct Candidate {
    var preview: MetaPreview
    var voteAverage: Double = 0
    var voteCount: Int = 0
    var popularity: Double = 0
    var language: String? = nil
    /// The titles of yours that led to it (TMDB recommended it for them).
    var seeds: Set<String> = []
}

enum RecommendationRanker {
    struct Weights {
        var genre = 0.35
        var seeds = 0.2
        var rating = 0.2
        var popularity = 0.1
        var language = 0.1
        var recency = 0.05
    }

    static var weights = Weights()

    /// 0…1. Rating is pulled toward 6/10 when few have voted, so a 9.0 from twelve votes
    /// doesn't beat a 8.2 from twenty thousand.
    static func score(_ c: Candidate, profile: TasteProfile, now: Date = Date()) -> Double {
        let w = weights
        let rating = (Double(c.voteCount) * c.voteAverage / 10 + 200 * 0.6) / (Double(c.voteCount) + 200)
        let popularity = min(log10(c.popularity + 1) / 3, 1)
        let year = c.preview.releaseInfo.flatMap { Int($0.prefix(4)) }
        let thisYear = Calendar.current.component(.year, from: now)
        let recency = year.map { 1 - min(Double(max(thisYear - $0, 0)) / 30, 1) } ?? 0.5
        let language = c.language.flatMap { profile.languages[$0] }.map { max($0, 0) } ?? 0
        return w.genre * profile.genreAffinity(c.preview.genres)
            + w.seeds * min(Double(c.seeds.count) / 2, 1)
            + w.rating * rating
            + w.popularity * popularity
            + w.language * language
            + w.recency * recency
    }

    /// Best first, each title once, nothing in `excluding`.
    static func rank(_ candidates: [Candidate], profile: TasteProfile, excluding: Set<String>, limit: Int) -> [MetaPreview] {
        var merged: [String: Candidate] = [:]
        for c in candidates where !excluding.contains(c.preview.id) {
            if var existing = merged[c.preview.id] {
                existing.seeds.formUnion(c.seeds)
                merged[c.preview.id] = existing
            } else {
                merged[c.preview.id] = c
            }
        }
        return merged.values
            .map { ($0, score($0, profile: profile)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.preview.id < $1.0.preview.id }
            .prefix(limit)
            .map(\.0.preview)
    }
}

// MARK: Recommender

/// Builds the personal rows for Home and "More Like This". Rows are saved, so they show on the
/// next launch's first frame, and rebuilt at most every few hours or when your history changes.
@MainActor
final class Recommender: ObservableObject {
    static let shared = Recommender()

    @Published private(set) var rows: [HomeSection] = []
    @Published private(set) var profile = TasteProfile()
    private var lastKey: String?
    private var lastBuild: Date?
    private var building = false

    private struct SavedRow: Codable {
        let id: String
        let title: String
        let style: HomeSection.Style
        let items: [MetaPreview]
    }

    private static let url: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("recommendations-v1.json")

    private init() {
        guard TMDB.isConfigured, let data = try? Data(contentsOf: Self.url),
              let saved = try? JSONDecoder().decode([SavedRow].self, from: data) else { return }
        rows = saved.map { HomeSection(id: $0.id, title: $0.title, style: $0.style, items: $0.items) }
    }

    func row(_ id: String) -> HomeSection? { rows.first { $0.id == id } }
    var becauseRows: [HomeSection] { rows.filter { $0.id.hasPrefix("because-") } }

    func refresh(watch: WatchStore, favorites: FavoritesStore, library: [MetaRef], force: Bool = false) async {
        guard TMDB.isConfigured, !building else { return }
        let abandoned = ViewingLog.shared.abandoned(watch.entries)
        let signals = TasteSignals.collect(records: WatchedStore.shared.records, watching: watch.entries,
                                           list: favorites.items, library: library, abandoned: abandoned)
        let key = signals.prefix(30).map(\.metaId).joined(separator: ",")
        if !force, key == lastKey, let lastBuild, Date().timeIntervalSince(lastBuild) < 6 * 3600 { return }
        guard !signals.isEmpty else {
            rows = []
            return
        }
        building = true
        defer { building = false }

        // Details for the titles that say most about you (saved after the first time).
        let known = Array(signals.filter { $0.weight > 0 }.prefix(20))
        var metas: [String: StremioMeta] = [:]
        var extras: [String: MetaExtras] = [:]
        await withTaskGroup(of: (String, StremioMeta?, MetaExtras?).self) { group in
            for signal in known {
                group.addTask { @MainActor in
                    let ref = MetaRef(id: signal.metaId, type: signal.type, name: signal.name, poster: nil)
                    let meta = await MetaResolver.resolve(ref, addons: [])
                    let more = await MetaResolver.extras(for: ref)
                    return (signal.metaId, meta, more)
                }
            }
            for await (id, meta, more) in group {
                metas[id] = meta
                extras[id] = more
            }
        }
        let profile = TasteProfile.build(signals, metas: metas, extras: extras)
        self.profile = profile

        // Already seen or under way: never recommended.
        var exclude = Set(WatchedStore.shared.records.filter { !$0.value.videos.isEmpty }.keys)
        exclude.formUnion(watch.entries.map(\.ref.metaId))

        // Candidates.
        let seeds = Array(known.filter { $0.weight >= 1 }.prefix(3))
        var bySeed: [String: [Candidate]] = [:]
        for seed in seeds {
            bySeed[seed.metaId] = await Self.related(seed.metaId, "recommendations")
        }
        var fromFavorites: [Candidate] = []
        for ref in favorites.items.prefix(3) where MetaResolver.mappable(ref.id) {
            fromFavorites += await Self.related(ref.id, "similar")
        }
        let top = profile.topGenres(2)
        let kind = profile.seriesShare > 0.6 ? "tv" : "movie"
        let genreIds = TMDBGenres.ids(top, tv: kind == "tv")
        var popular: [Candidate] = []
        var gems: [Candidate] = []
        if !genreIds.isEmpty {
            popular = await TMDBCatalog.candidates("/discover/\(kind)", [
                "with_genres": genreIds, "sort_by": "popularity.desc", "vote_count.gte": "300",
            ], page: 1, kind: kind)
            gems = await TMDBCatalog.candidates("/discover/\(kind)", [
                "with_genres": genreIds, "sort_by": "vote_average.desc", "vote_average.gte": "7",
                "vote_count.gte": "100", "vote_count.lte": "1500",
            ], page: 1, kind: kind)
        }
        // Something new: well-loved titles in genres you rarely watch.
        let liked = Set(profile.topGenres(5))
        let fresh = TMDBGenres.movie.compactMap { $0.value.first }.filter { !liked.contains($0) && (profile.genres[$0] ?? 0) >= 0 }
        let freshIds = TMDBGenres.ids(Array(fresh.sorted().prefix(4)), tv: false)
        let newToYou = freshIds.isEmpty ? [] : await TMDBCatalog.candidates("/discover/movie", [
            "with_genres": freshIds, "sort_by": "vote_average.desc", "vote_count.gte": "2000",
        ], page: 1, kind: "movie")

        // Trakt's own picks for you, when connected.
        let traktPicks = await Self.traktCandidates()

        // Rows, each title in one row only where possible.
        var shown = Set<String>()
        var built: [HomeSection] = []
        func add(_ id: String, _ title: String, _ style: HomeSection.Style, _ pool: [Candidate], limit: Int = 20) {
            var items = RecommendationRanker.rank(pool, profile: profile, excluding: exclude.union(shown), limit: limit)
            if items.count < 6 {
                items = RecommendationRanker.rank(pool, profile: profile, excluding: exclude, limit: limit)
            }
            guard items.count >= 6 else { return }
            shown.formUnion(items.prefix(10).map(\.id))
            built.append(HomeSection(id: id, title: title, style: style, items: items))
        }
        let allSeeded = bySeed.values.flatMap { $0 }
        add("recommended", "Recommended For You", .wide, allSeeded + traktPicks + fromFavorites + popular + gems, limit: 16)
        // In Trakt's order, not re-ranked: it's their list.
        let traktItems = traktPicks.map(\.preview).filter { !exclude.contains($0.id) && !shown.contains($0.id) }
        if traktItems.count >= 6 {
            built.append(HomeSection(id: "trakt-picks", title: "Recommended on Trakt", style: .poster, items: Array(traktItems.prefix(20))))
            shown.formUnion(traktItems.prefix(10).map(\.id))
        }
        if let seed = seeds.first, let pool = bySeed[seed.metaId] {
            let name = metas[seed.metaId]?.name ?? seed.name
            if !name.isEmpty { add("because-\(seed.metaId)", "Because You Watched \(name)", .poster, pool) }
        }
        add("like-favorites", "More Like Your Favorites", .poster, fromFavorites)
        add("gems-for-you", "Hidden Gems For You", .poster, gems)
        if !top.isEmpty {
            add("popular-genres", "Popular in \(top.joined(separator: " & "))", .poster, popular)
        }
        add("discover-new", "Discover Something New", .poster, newToYou)

        lastKey = key
        lastBuild = Date()
        withAnimation(.easeOut(duration: 0.25)) { rows = built }
        let saved = built.map { SavedRow(id: $0.id, title: $0.title, style: $0.style, items: $0.items) }
        let url = Self.url
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Trakt's recommendations for you, with TMDB's details (one cached call each).
    private static func traktCandidates() async -> [Candidate] {
        let picks = Array(TraktAccount.shared.recommended.prefix(24))
        guard !picks.isEmpty else { return [] }
        let found = await withTaskGroup(of: (Int, Candidate?).self) { group in
            for (index, pick) in picks.enumerated() {
                group.addTask { @MainActor in
                    guard let details = await TMDB.details(pick.tmdb) else { return (index, nil) }
                    let meta = details.stremioMeta(imdb: pick.imdb, type: pick.tmdb.kind == .tv ? "series" : "movie")
                    guard meta.poster != nil else { return (index, nil) }
                    let preview = MetaPreview(id: pick.imdb, type: meta.type, name: meta.name, poster: meta.poster,
                                              background: meta.background, logo: ArtworkURL.logo(forMetaId: pick.imdb),
                                              description: meta.description, releaseInfo: meta.releaseInfo,
                                              imdbRating: nil, genres: meta.genres, runtime: meta.runtime,
                                              trailerId: meta.trailerId)
                    return (index, Candidate(preview: preview, voteAverage: details.vote_average ?? 0,
                                             voteCount: details.vote_count ?? 0, popularity: 0,
                                             language: details.original_language, seeds: ["trakt"]))
                }
            }
            var out: [Int: Candidate] = [:]
            for await (index, candidate) in group { if let candidate { out[index] = candidate } }
            return out
        }
        return found.keys.sorted().compactMap { found[$0] }
    }

    /// TMDB's "recommendations" or "similar" for one of your titles (IMDb or Kitsu id), tagged with it.
    private static func related(_ imdb: String, _ list: String) async -> [Candidate] {
        guard let ref = await MetaResolver.tmdbRef(for: imdb) else { return [] }
        let kind = ref.kind.rawValue
        return await TMDBCatalog.candidates("/\(kind)/\(ref.id)/\(list)", [:], page: 1, kind: kind)
            .map { var c = $0; c.seeds = [imdb]; return c }
    }

    /// "More Like This" on a title page: TMDB's recommendations and similar titles, ranked for
    /// you, leaving out what you've seen. Empty without TMDB (the page then uses Cinemeta's).
    func similar(to meta: StremioMeta) async -> [MetaPreview] {
        guard TMDB.isConfigured, MetaResolver.mappable(meta.id) else { return [] }
        async let recommended = Self.related(meta.id, "recommendations")
        async let similar = Self.related(meta.id, "similar")
        let pool = await recommended + similar
        var exclude = Set(WatchedStore.shared.records.filter { !$0.value.videos.isEmpty }.keys)
        exclude.insert(meta.id)
        return RecommendationRanker.rank(pool, profile: profile, excluding: exclude, limit: 20)
    }
}
