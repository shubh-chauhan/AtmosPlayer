import Foundation
import SwiftUI

// MARK: - Trakt
//
// Optional: connect a Trakt account to send what you watch there (scrobbling), keep ✓ marks
// in step with Trakt's history, rate titles, and get Trakt's recommendations on Home.
// API: trakt.docs.apiary.io (v2). Sign-in uses Trakt's device code flow: the app shows a code,
// you enter it at trakt.tv/activate; no password ever passes through the app. Tokens are kept
// in the Keychain.
//
// The app's client id and secret come from the TRAKT_CLIENT_ID / TRAKT_CLIENT_SECRET repo
// secrets (a Trakt API app you register), scrambled into Info.plist like TMDB's token. Without
// them Trakt stays off and Settings says how to turn it on.

enum TraktConfig {
    static let clientId: String? = TMDB.descramble(Bundle.main.object(forInfoDictionaryKey: "TraktClientID") as? String)
    static let clientSecret: String? = TMDB.descramble(Bundle.main.object(forInfoDictionaryKey: "TraktClientSecret") as? String)
    static var isConfigured: Bool { clientId != nil && clientSecret != nil }
}

@MainActor
final class TraktAccount: ObservableObject {
    static let shared = TraktAccount()

    /// The code to enter at the activation page while connecting.
    struct Pairing: Equatable {
        let userCode: String
        let url: String
        let expires: Date
    }

    private struct Tokens: Codable {
        var access: String
        var refresh: String
        var expires: Date
    }

    @Published private(set) var username: String?
    @Published private(set) var pairing: Pairing?
    @Published private(set) var syncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    /// Your Trakt ratings (1…10) by IMDb id.
    @Published private(set) var ratings: [String: Int] = [:]
    /// Trakt's recommendations for you, IMDb id → TMDB ref, best first.
    @Published private(set) var recommended: [(imdb: String, tmdb: IDMap.TMDBRef)] = []

    var connected: Bool { tokens != nil }

    private var tokens: Tokens?
    private var pairingTask: Task<Void, Never>?
    private let tokenKey = "trakt.tokens"
    private let userKey = "trakt.username"
    private let ratingsKey = "trakt.ratings.v1"
    private static let base = "https://api.trakt.tv"

    private init() {
        if let raw = Keychain.read(tokenKey), let data = raw.data(using: .utf8) {
            tokens = try? JSONDecoder().decode(Tokens.self, from: data)
        }
        username = UserDefaults.standard.string(forKey: userKey)
        ratings = DiskStore.load(ratingsKey, as: [String: Int].self) ?? [:]
    }

    // MARK: Connect

    /// Starts the device code flow and waits (in the background) for you to approve it.
    func connect() {
        guard TraktConfig.isConfigured, let clientId = TraktConfig.clientId else { return }
        pairingTask?.cancel()
        lastError = nil
        pairingTask = Task {
            guard let reply = try? await send("POST", "/oauth/device/code", body: ["client_id": clientId], auth: false),
                  reply.1 == 200,
                  let json = try? JSONSerialization.jsonObject(with: reply.0) as? [String: Any],
                  let deviceCode = json["device_code"] as? String,
                  let userCode = json["user_code"] as? String else {
                lastError = "Couldn't reach Trakt. Try again."
                return
            }
            let url = json["verification_url"] as? String ?? "https://trakt.tv/activate"
            let interval = max((json["interval"] as? NSNumber)?.doubleValue ?? 5, 1)
            let lifetime = (json["expires_in"] as? NSNumber)?.doubleValue ?? 600
            pairing = Pairing(userCode: userCode, url: url, expires: Date().addingTimeInterval(lifetime))
            await poll(deviceCode: deviceCode, every: interval, until: Date().addingTimeInterval(lifetime))
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairing = nil
    }

    private func poll(deviceCode: String, every interval: Double, until deadline: Date) async {
        guard let clientId = TraktConfig.clientId, let secret = TraktConfig.clientSecret else { return }
        var wait = interval
        while Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let body = ["code": deviceCode, "client_id": clientId, "client_secret": secret]
            guard let reply = try? await send("POST", "/oauth/device/token", body: body, auth: false) else { continue }
            switch reply.1 {
            case 200:
                guard store(tokensFrom: reply.0) else { break }
                pairing = nil
                await loadUsername()
                await sync()
                return
            case 400:
                continue   // waiting for you to enter the code
            case 429:
                wait += 1  // asked to slow down
            default:
                // 404 invalid, 409 already used, 410 expired, 418 denied.
                lastError = reply.1 == 418 ? "The request was denied on Trakt." : "The code expired. Try again."
                pairing = nil
                return
            }
        }
        if !Task.isCancelled {
            lastError = "The code expired. Try again."
            pairing = nil
        }
    }

    @discardableResult
    private func store(tokensFrom data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else { return false }
        let lifetime = (json["expires_in"] as? NSNumber)?.doubleValue ?? 7 * 24 * 3600
        let created = (json["created_at"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
        let new = Tokens(access: access, refresh: refresh, expires: Date(timeIntervalSince1970: created + lifetime))
        tokens = new
        if let encoded = try? JSONEncoder().encode(new), let text = String(data: encoded, encoding: .utf8) {
            Keychain.write(tokenKey, text)
        }
        objectWillChange.send()
        return true
    }

    func disconnect() {
        if let access = tokens?.access, let clientId = TraktConfig.clientId, let secret = TraktConfig.clientSecret {
            Task { _ = try? await send("POST", "/oauth/revoke", body: ["token": access, "client_id": clientId, "client_secret": secret], auth: false) }
        }
        tokens = nil
        Keychain.delete(tokenKey)
        username = nil
        UserDefaults.standard.removeObject(forKey: userKey)
        ratings = [:]
        DiskStore.remove(ratingsKey)
        recommended = []
        lastSync = nil
        _ = PendingWrites.shared.take(stremio: false)
    }

    private func loadUsername() async {
        guard let reply = try? await send("GET", "/users/settings"), reply.1 == 200,
              let json = try? JSONSerialization.jsonObject(with: reply.0) as? [String: Any],
              let user = json["user"] as? [String: Any] else { return }
        let name = (user["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? user["username"] as? String
        username = name
        UserDefaults.standard.set(name, forKey: userKey)
    }

    // MARK: Requests

    /// One API call. Signed-in calls refresh an expired token first, and once more on a 401.
    private func send(_ method: String, _ path: String, body: Any? = nil, auth: Bool = true,
                      retried: Bool = false) async throws -> (Data, Int) {
        guard let clientId = TraktConfig.clientId, let url = URL(string: Self.base + path) else { throw URLError(.badURL) }
        if auth, let tokens, tokens.expires.timeIntervalSinceNow < 3600 { await refreshTokens() }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientId, forHTTPHeaderField: "trakt-api-key")
        if auth {
            guard let access = tokens?.access else { throw URLError(.userAuthenticationRequired) }
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, auth, !retried {
            await refreshTokens()
            return try await send(method, path, body: body, auth: auth, retried: true)
        }
        if code == 429, !retried {
            let after = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 2
            try? await Task.sleep(nanoseconds: UInt64(min(after, 10) * 1_000_000_000))
            return try await send(method, path, body: body, auth: auth, retried: true)
        }
        return (data, code)
    }

    private func refreshTokens() async {
        guard let refresh = tokens?.refresh, let clientId = TraktConfig.clientId,
              let secret = TraktConfig.clientSecret else { return }
        let body = ["refresh_token": refresh, "client_id": clientId, "client_secret": secret,
                    "redirect_uri": "urn:ietf:wg:oauth:2.0:oob", "grant_type": "refresh_token"]
        guard let reply = try? await send("POST", "/oauth/token", body: body, auth: false) else { return }
        if reply.1 == 200 {
            store(tokensFrom: reply.0)
        } else if reply.1 == 400 || reply.1 == 401 {
            // The refresh token was revoked: sign in again.
            lastError = "Your Trakt sign-in expired. Connect again."
            tokens = nil
            Keychain.delete(tokenKey)
        }
    }

    // MARK: Bodies

    /// The JSON Trakt uses for a movie, or a show's episode, by IMDb id. Nil for other ids.
    static func item(_ ref: VideoRef) -> [String: Any]? {
        guard ref.metaId.hasPrefix("tt") else { return nil }
        if ref.type == "movie" { return ["movie": ["ids": ["imdb": ref.metaId]]] }
        guard let pair = episodeNumbers(ref.videoId) else { return nil }
        return ["show": ["ids": ["imdb": ref.metaId]], "episode": ["season": pair.0, "number": pair.1]]
    }

    /// "tt123:2:5" → (2, 5).
    static func episodeNumbers(_ videoId: String) -> (Int, Int)? {
        let parts = videoId.split(separator: ":")
        guard parts.count == 3, let season = Int(parts[1]), let episode = Int(parts[2]) else { return nil }
        return (season, episode)
    }

    /// The body for /sync/history: movies by id, episodes grouped by show and season.
    static func historyBody(metaId: String, type: String, videoIds: [String], at: Date?) -> [String: Any]? {
        guard metaId.hasPrefix("tt") else { return nil }
        var stamp: [String: Any] = [:]
        if let at { stamp["watched_at"] = StremioAPI.timestamp(at) }
        if type == "movie" {
            let movie: [String: Any] = ["ids": ["imdb": metaId]]
            return ["movies": [movie.merging(stamp) { a, _ in a }]]
        }
        var bySeason: [Int: [Int]] = [:]
        for id in videoIds {
            if let pair = episodeNumbers(id) { bySeason[pair.0, default: []].append(pair.1) }
        }
        guard !bySeason.isEmpty else { return nil }
        let seasons: [[String: Any]] = bySeason.keys.sorted().map { season -> [String: Any] in
            let episodes: [[String: Any]] = (bySeason[season] ?? []).sorted().map { number -> [String: Any] in
                let episode: [String: Any] = ["number": number]
                return episode.merging(stamp) { a, _ in a }
            }
            return ["number": season, "episodes": episodes]
        }
        return ["shows": [["ids": ["imdb": metaId], "seasons": seasons]]]
    }

    // MARK: Writes

    /// When the player closes: Trakt saves the position, or marks it watched past 80 %.
    func scrobble(_ ref: VideoRef, position: Double, duration: Double, at: Date = Date()) async {
        guard connected, duration > 0, position.isFinite, var body = Self.item(ref) else { return }
        let progress = min(max(position / duration * 100, 0), 100)
        body["progress"] = progress
        let op = PendingWrites.Op.traktScrobble(ref: ref, progress: progress, at: at)
        do {
            let (_, code) = try await send("POST", "/scrobble/stop", body: body)
            // 409: Trakt already has this scrobble.
            if (200..<300).contains(code) || code == 409 {
                PendingWrites.shared.resolve(op.key)
            } else if code >= 500 {
                PendingWrites.shared.add(op)
            }
        } catch {
            PendingWrites.shared.add(op)
        }
    }

    /// ✓ marks set or cleared by hand go to Trakt's history.
    func pushHistory(metaId: String, type: String, videoIds: [String], add: Bool, at: Date = Date()) async {
        guard connected, let body = Self.historyBody(metaId: metaId, type: type, videoIds: videoIds, at: add ? at : nil) else { return }
        let op = PendingWrites.Op.traktHistory(metaId: metaId, type: type, videoIds: videoIds, add: add, at: at)
        do {
            let (_, code) = try await send("POST", add ? "/sync/history" : "/sync/history/remove", body: body)
            if (200..<300).contains(code) {
                PendingWrites.shared.resolve(op.key)
            } else if code >= 500 {
                PendingWrites.shared.add(op)
            }
        } catch {
            PendingWrites.shared.add(op)
        }
    }

    /// Rates a title 1…10 on Trakt, or clears the rating (nil).
    func rate(metaId: String, type: String, rating: Int?) async {
        guard connected, metaId.hasPrefix("tt") else { return }
        let key = type == "movie" ? "movies" : "shows"
        var entry: [String: Any] = ["ids": ["imdb": metaId]]
        if let rating { entry["rating"] = rating }
        let previous = ratings[metaId]
        ratings[metaId] = rating
        DiskStore.save(ratings, ratingsKey)
        let ok = (try? await send("POST", rating == nil ? "/sync/ratings/remove" : "/sync/ratings", body: [key: [entry]]))
            .map { (200..<300).contains($0.1) } ?? false
        if !ok {
            ratings[metaId] = previous
            DiskStore.save(ratings, ratingsKey)
            lastError = "Couldn't save the rating on Trakt."
        }
    }

    private func sendPending() async {
        for op in PendingWrites.shared.take(stremio: false) {
            switch op {
            case let .traktScrobble(ref, progress, at):
                await scrobble(ref, position: progress, duration: 100, at: at)
            case let .traktHistory(metaId, type, videoIds, add, at):
                await pushHistory(metaId: metaId, type: type, videoIds: videoIds, add: add, at: at)
            default:
                break
            }
        }
    }

    // MARK: Sync

    /// Sends what's waiting, then brings in Trakt's watched history, your ratings and
    /// Trakt's recommendations. `ifOlderThan` skips it when one ran recently.
    func sync(ifOlderThan age: TimeInterval = 0) async {
        guard connected, !syncing else { return }
        if age > 0, let lastSync, Date().timeIntervalSince(lastSync) < age { return }
        syncing = true
        defer { syncing = false }
        await sendPending()
        if username == nil { await loadUsername() }

        async let movies = fetchList("/sync/watched/movies")
        async let shows = fetchList("/sync/watched/shows")
        async let movieRatings = fetchList("/sync/ratings/movies")
        async let showRatings = fetchList("/sync/ratings/shows")
        async let recMovies = fetchList("/recommendations/movies?limit=20&ignore_collected=true")
        async let recShows = fetchList("/recommendations/shows?limit=20&ignore_collected=true")
        let (watchedMovies, watchedShows) = await (movies, shows)
        let (rated1, rated2) = await (movieRatings, showRatings)
        let (rec1, rec2) = await (recMovies, recShows)
        guard watchedMovies != nil || watchedShows != nil else {
            lastError = "Couldn't reach Trakt."
            return
        }

        for entry in watchedMovies ?? [] {
            guard let imdb = Self.imdb(entry["movie"]) else { continue }
            WatchedStore.shared.adoptTrakt(metaId: imdb, ids: [imdb])
        }
        for entry in watchedShows ?? [] {
            guard let imdb = Self.imdb(entry["show"]) else { continue }
            var ids = Set<String>()
            for season in (entry["seasons"] as? [[String: Any]]) ?? [] {
                guard let number = (season["number"] as? NSNumber)?.intValue else { continue }
                for episode in (season["episodes"] as? [[String: Any]]) ?? [] {
                    if let index = (episode["number"] as? NSNumber)?.intValue { ids.insert("\(imdb):\(number):\(index)") }
                }
            }
            if !ids.isEmpty { WatchedStore.shared.adoptTrakt(metaId: imdb, ids: ids) }
        }

        if rated1 != nil || rated2 != nil {
            var all: [String: Int] = [:]
            for entry in (rated1 ?? []) + (rated2 ?? []) {
                guard let rating = (entry["rating"] as? NSNumber)?.intValue,
                      let imdb = Self.imdb(entry["movie"] ?? entry["show"]) else { continue }
                all[imdb] = rating
            }
            ratings = all
            DiskStore.save(all, ratingsKey)
        }

        var picks: [(imdb: String, tmdb: IDMap.TMDBRef)] = []
        for (list, kind) in [(rec1 ?? [], IDMap.TMDBRef.Kind.movie), (rec2 ?? [], .tv)] {
            for entry in list {
                guard let ids = entry["ids"] as? [String: Any], let imdb = ids["imdb"] as? String, imdb.hasPrefix("tt"),
                      let tmdb = (ids["tmdb"] as? NSNumber)?.intValue else { continue }
                let ref = IDMap.TMDBRef(kind: kind, id: tmdb)
                IDMap.record(imdb: imdb, tmdb: ref)
                picks.append((imdb, ref))
            }
        }
        // Movies and shows taken in turn, so neither crowds out the other.
        let half = picks.filter { $0.tmdb.kind == .movie }, other = picks.filter { $0.tmdb.kind == .tv }
        recommended = (0..<max(half.count, other.count)).flatMap { i in
            [i < half.count ? half[i] : nil, i < other.count ? other[i] : nil].compactMap { $0 }
        }

        lastSync = Date()
        lastError = nil
    }

    private func fetchList(_ path: String) async -> [[String: Any]]? {
        guard let reply = try? await send("GET", path), reply.1 == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: reply.0)) as? [[String: Any]]
    }

    private static func imdb(_ media: Any?) -> String? {
        guard let media = media as? [String: Any], let ids = media["ids"] as? [String: Any],
              let imdb = ids["imdb"] as? String, imdb.hasPrefix("tt") else { return nil }
        return imdb
    }
}

/// Rate a title on Trakt from its page: hearts 1…10, the way Trakt rates.
struct TraktRatingMenu<Label: View>: View {
    let metaId: String
    let type: String
    /// Drawn with your current rating (nil when unrated).
    @ViewBuilder let label: (Int?) -> Label
    @ObservedObject private var trakt = TraktAccount.shared

    var body: some View {
        let current = trakt.ratings[metaId]
        Menu {
            ForEach((1...10).reversed(), id: \.self) { value in
                Button {
                    Task { await trakt.rate(metaId: metaId, type: type, rating: value) }
                } label: {
                    if current == value {
                        Label("\(value) – \(Self.word(value))", systemImage: "checkmark")
                    } else {
                        Text("\(value) – \(Self.word(value))")
                    }
                }
            }
            if current != nil {
                Divider()
                Button("Remove Rating", systemImage: "xmark", role: .destructive) {
                    Task { await trakt.rate(metaId: metaId, type: type, rating: nil) }
                }
            }
        } label: {
            label(current)
        }
        .sensoryFeedback(.success, trigger: current)
        .accessibilityLabel(current.map { "Your Trakt rating: \($0) out of 10" } ?? "Rate on Trakt")
    }

    private static func word(_ value: Int) -> String {
        ["Weak Sauce", "Terrible", "Bad", "Poor", "Meh", "Fair", "Good", "Great", "Superb", "Totally Ninja!"][value - 1]
    }
}
