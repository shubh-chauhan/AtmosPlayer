import Foundation
import Combine
import Security

/// Your Stremio account: sign in once and the app uses the same addons, library and
/// Continue Watching as the Stremio apps, and sends your progress back to Stremio.
///
/// Talks to api.strem.io, the same API the official apps use. The password is sent only to
/// Stremio and never stored; only the session key Stremio returns is kept, in the Keychain.
@MainActor
final class StremioAccount: ObservableObject {
    @Published private(set) var email: String?
    @Published private(set) var library: [MetaRef] = []
    @Published private(set) var syncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    /// Settings toggle (bound with @AppStorage in the Addons screen). On unless turned off.
    static let pushProgressKey = "stremio.pushProgress"
    private var pushProgressEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.pushProgressKey) as? Bool ?? true
    }

    var signedIn: Bool { authKey != nil }

    private var authKey: String?
    private let emailKey = "stremio.email"
    private let libraryKey = "stremio.library.v1"

    init() {
        authKey = Keychain.read("stremio.authKey")
        email = UserDefaults.standard.string(forKey: emailKey)
        library = DiskStore.load(libraryKey, as: [MetaRef].self) ?? []
    }

    // MARK: Sign in / out

    func signIn(email: String, password: String) async throws {
        let body: [String: Any] = ["type": "Login", "email": email, "password": password, "facebook": false]
        let result = try await StremioAPI.call("login", body)
        guard let dict = result as? [String: Any], let key = dict["authKey"] as? String else {
            throw StremioAPI.Failure.message("Stremio didn't return a session.")
        }
        authKey = key
        Keychain.write("stremio.authKey", key)
        let user = dict["user"] as? [String: Any]
        let shown = (user?["email"] as? String) ?? email
        self.email = shown
        UserDefaults.standard.set(shown, forKey: emailKey)
    }

    func signOut() {
        if let key = authKey {
            Task { _ = try? await StremioAPI.call("logout", ["type": "Logout", "authKey": key]) }
        }
        authKey = nil
        Keychain.delete("stremio.authKey")
        email = nil
        library = []
        lastSync = nil
        UserDefaults.standard.removeObject(forKey: emailKey)
        DiskStore.remove(libraryKey)
    }

    // MARK: Pull from Stremio

    /// Brings in the account's addons, library and Continue Watching.
    /// `ifOlderThan` skips the sync when one ran recently (used when the app comes to the front).
    func sync(addons: AddonStore, watch: WatchStore, ifOlderThan age: TimeInterval = 0) async {
        guard let key = authKey, !syncing else { return }
        if age > 0, let lastSync, Date().timeIntervalSince(lastSync) < age { return }
        syncing = true
        defer { syncing = false }
        // Writes that failed earlier go first, so what's read back includes them.
        await sendPending()
        do {
            async let addonResult = StremioAPI.call("addonCollectionGet",
                                                    ["type": "AddonCollectionGet", "authKey": key, "update": true])
            async let libraryResult = StremioAPI.call("datastoreGet",
                                                      ["authKey": key, "collection": "libraryItem", "ids": [String](), "all": true])
            let (addonJSON, libraryJSON) = try await (addonResult, libraryResult)
            guard authKey == key else { return }

            // Addons, in the account's order.
            var collection: [(url: String, manifest: Data)] = []
            for entry in ((addonJSON as? [String: Any])?["addons"] as? [Any]) ?? [] {
                guard let entry = entry as? [String: Any],
                      let url = entry["transportUrl"] as? String,
                      let manifest = entry["manifest"],
                      let data = try? JSONSerialization.data(withJSONObject: manifest) else { continue }
                collection.append((url, data))
            }
            addons.adoptAccountAddons(collection)

            // Library and Continue Watching.
            let items = ((libraryJSON as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.compactMap(LibraryItem.init)
            let saved = items.filter { !$0.removed && !$0.temp && ($0.type == "movie" || $0.type == "series") }
                .sorted { $0.modified > $1.modified }
                .map { MetaRef(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster) }
            library = saved
            DiskStore.save(saved, libraryKey)
            watch.mergeFromStremio(items.map(\.watchSnapshot), dropsCleared: pushProgressEnabled)
            // Watched movies and episodes (the ✓ marks).
            for item in items where item.type == "movie" || item.type == "series" {
                WatchedStore.shared.adoptRemote(metaId: item.id, type: item.type, field: item.watchedField,
                                                movieWatched: item.movieWatched, modified: item.modified)
            }

            lastSync = Date()
            lastError = nil
        } catch StremioAPI.Failure.sessionExpired {
            lastError = "Your Stremio session expired. Sign in again."
            signOut()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Push to Stremio

    /// Sends the writes saved while Stremio couldn't be reached.
    func sendPending() async {
        guard authKey != nil else { return }
        for op in PendingWrites.shared.take(stremio: true) {
            switch op {
            case let .stremioProgress(ref, position, duration, at):
                await pushProgress(ref, position: position, duration: duration, at: at)
            case let .stremioWatched(metaId, type, watched, videoIds):
                await pushWatched(metaId: metaId, type: type, watched: Set(watched), videoIds: videoIds)
            case let .stremioClear(ref):
                await clearProgress(ref)
            default:
                break
            }
        }
    }

    /// A write that failed for a reason that can pass (no signal, server error) is kept to retry.
    private func failed(_ op: PendingWrites.Op, _ error: Error, _ what: String) {
        LogStore.shared.append("Stremio \(what) failed: \(error.localizedDescription)")
        if PendingWrites.isTemporary(error) { PendingWrites.shared.add(op) }
    }

    /// Account writes run one after another, so two changes to the same library item
    /// (progress and a ✓, say) can't overwrite each other.
    private var writeChain: Task<Void, Never>?

    private func serialized(_ work: @escaping @MainActor () async -> Void) async {
        let previous = writeChain
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        writeChain = task
        await task.value
    }

    /// Sends a title's watched movies / episodes to Stremio (what its "Mark as watched" does).
    /// `videoIds` is the series' episode list in the addon's order; from the saved details, else
    /// Cinemeta, if nil. With `change`, only that change is applied to Stremio's current marks, so
    /// marks made in other Stremio apps (not yet seen here) are kept.
    func pushWatched(metaId: String, type: String, watched: Set<String>, videoIds: [String]?,
                     change: (ids: [String], on: Bool)? = nil) async {
        guard let key = authKey else { return }
        let op = PendingWrites.Op.stremioWatched(metaId: metaId, type: type, watched: Array(watched), videoIds: videoIds)
        await serialized {
            do {
                let existing = try await StremioAPI.call("datastoreGet",
                                                         ["authKey": key, "collection": "libraryItem", "ids": [metaId], "all": false])
                var item = (existing as? [Any])?.first as? [String: Any]
                var ids = videoIds
                if type == "series", ids == nil {
                    // Addon titles (anime) aren't on Cinemeta; their page's saved details list them.
                    ids = await MetaResolver.savedVideoIds(type: type, id: metaId)
                }
                if item == nil || (type == "series" && ids == nil) {
                    let meta = await Cinemeta.meta(type: type, id: metaId)
                    if ids == nil { ids = meta?.videos.map(\.id) }
                    if item == nil {
                        let now = StremioAPI.timestamp(Date())
                        item = [
                            "_id": metaId, "name": meta?.name ?? "", "type": type, "poster": meta?.poster ?? "",
                            "posterShape": "poster", "removed": true, "temp": true, "_ctime": now,
                            "behaviorHints": ["defaultVideoId": NSNull(), "featuredVideoId": NSNull(), "hasScheduledVideos": false],
                        ]
                    }
                }
                guard var item else { return }
                var state = (item["state"] as? [String: Any]) ?? [
                    "timeWatched": 0, "overallTimeWatched": 0, "timesWatched": 0, "flaggedWatched": 0,
                    "watched": "", "noNotif": false, "timeOffset": 0, "duration": 0,
                ]
                if type == "series" {
                    guard let ids else {
                        // No episode list yet: kept and sent again on a later sync.
                        PendingWrites.shared.add(op)
                        return
                    }
                    var marks = watched
                    if let change, let theirs = state["watched"] as? String, !theirs.isEmpty {
                        let remote = WatchedBitfield.decode(theirs, videoIds: ids).union(watched)
                        marks = change.on ? remote : remote.subtracting(change.ids)
                    }
                    guard let field = WatchedBitfield.encode(marks, videoIds: ids) else { return }
                    state["watched"] = field
                } else {
                    let on = watched.contains(metaId)
                    state["flaggedWatched"] = on ? 1 : 0
                    let times = (state["timesWatched"] as? NSNumber)?.intValue ?? 0
                    state["timesWatched"] = on ? max(times, 1) : 0
                    if on { state["timeOffset"] = 0 }
                }
                item["state"] = state
                item["_mtime"] = StremioAPI.timestamp(Date())
                _ = try await StremioAPI.call("datastorePut",
                                              ["authKey": key, "collection": "libraryItem", "changes": [item]])
                PendingWrites.shared.resolve(op.key)
            } catch {
                self.failed(op, error, "watched sync")
            }
        }
    }

    /// Takes a title off Stremio's Continue Watching (what Stremio's own "dismiss" does).
    func clearProgress(_ ref: VideoRef) async {
        guard let key = authKey else { return }
        let op = PendingWrites.Op.stremioClear(ref: ref)
        await serialized { do {
            let existing = try await StremioAPI.call("datastoreGet",
                                                     ["authKey": key, "collection": "libraryItem", "ids": [ref.metaId], "all": false])
            guard var item = (existing as? [Any])?.first as? [String: Any],
                  var state = item["state"] as? [String: Any] else { return }
            state["timeOffset"] = 0
            item["state"] = state
            item["_mtime"] = StremioAPI.timestamp(Date())
            _ = try await StremioAPI.call("datastorePut",
                                          ["authKey": key, "collection": "libraryItem", "changes": [item]])
            PendingWrites.shared.resolve(op.key)
        } catch {
            self.failed(op, error, "dismiss")
        } }
    }

    /// Called when the player closes, so Stremio's Continue Watching matches where you stopped.
    func pushProgress(_ ref: VideoRef, position: Double, duration: Double, at: Date = Date()) async {
        guard pushProgressEnabled, let key = authKey, position.isFinite, duration.isFinite, position >= 30 else { return }
        let finished = duration > 0 && position > duration - max(120, duration * 0.05)
        let op = PendingWrites.Op.stremioProgress(ref: ref, position: position, duration: duration, at: at)
        await serialized { do {
            let now = StremioAPI.timestamp(at)
            // Start from the latest copy on the server so nothing else in the item is lost.
            let existing = try await StremioAPI.call("datastoreGet",
                                                     ["authKey": key, "collection": "libraryItem", "ids": [ref.metaId], "all": false])
            var item = ((existing as? [Any])?.first as? [String: Any]) ?? [
                "_id": ref.metaId, "name": ref.name, "type": ref.type, "poster": ref.poster ?? "",
                "posterShape": "poster", "removed": true, "temp": true, "_ctime": now,
                "behaviorHints": ["defaultVideoId": NSNull(), "featuredVideoId": NSNull(), "hasScheduledVideos": false],
            ]
            var state = (item["state"] as? [String: Any]) ?? [
                "timeWatched": 0, "overallTimeWatched": 0, "timesWatched": 0, "flaggedWatched": 0,
                "watched": "", "noNotif": false,
            ]
            let previousOffset = (state["timeOffset"] as? NSNumber)?.doubleValue ?? 0
            let watchedMore = max(0, position * 1000 - previousOffset)
            state["lastWatched"] = now
            state["video_id"] = ref.videoId
            state["duration"] = Int(duration * 1000)
            state["timeWatched"] = ((state["timeWatched"] as? NSNumber)?.intValue ?? 0) + Int(watchedMore)
            state["overallTimeWatched"] = ((state["overallTimeWatched"] as? NSNumber)?.intValue ?? 0) + Int(watchedMore)
            if finished {
                state["timeOffset"] = 0
                state["timesWatched"] = ((state["timesWatched"] as? NSNumber)?.intValue ?? 0) + 1
                if ref.type == "movie" { state["flaggedWatched"] = 1 }
            } else {
                state["timeOffset"] = Int(position * 1000)
            }
            item["state"] = state
            item["_mtime"] = now
            _ = try await StremioAPI.call("datastorePut",
                                          ["authKey": key, "collection": "libraryItem", "changes": [item]])
            PendingWrites.shared.resolve(op.key)
        } catch {
            self.failed(op, error, "progress sync")
        } }
    }
}

/// The parts of a Stremio library item the app uses.
struct LibraryItem {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let removed: Bool
    let temp: Bool
    let modified: Date
    let lastWatched: Date?
    let videoId: String?
    let offset: Double
    let duration: Double
    let watchedField: String?
    let movieWatched: Bool

    init?(_ json: [String: Any]) {
        guard let id = json["_id"] as? String, let type = json["type"] as? String else { return nil }
        self.id = id
        self.type = type
        name = (json["name"] as? String) ?? ""
        let rawPoster = json["poster"] as? String
        poster = (rawPoster?.isEmpty ?? true) ? nil : rawPoster
        removed = (json["removed"] as? Bool) ?? false
        temp = (json["temp"] as? Bool) ?? false
        modified = StremioAPI.date(json["_mtime"]) ?? .distantPast
        let state = (json["state"] as? [String: Any]) ?? [:]
        lastWatched = StremioAPI.date(state["lastWatched"])
        let video = state["video_id"] as? String
        videoId = (video?.isEmpty ?? true) ? nil : video
        offset = ((state["timeOffset"] as? NSNumber)?.doubleValue ?? 0) / 1000
        duration = ((state["duration"] as? NSNumber)?.doubleValue ?? 0) / 1000
        watchedField = state["watched"] as? String
        movieWatched = ((state["flaggedWatched"] as? NSNumber)?.intValue ?? 0) > 0
            || ((state["timesWatched"] as? NSNumber)?.intValue ?? 0) > 0
    }

    /// Stremio's own rule for Continue Watching.
    var inContinueWatching: Bool { type != "other" && (!removed || temp) && offset > 0 }

    var watchSnapshot: WatchStore.StremioSnapshot {
        let video = videoId ?? id
        return WatchStore.StremioSnapshot(
            ref: VideoRef(type: type, metaId: id, videoId: video, name: name, poster: poster,
                          episodeLabel: Self.episodeLabel(video, metaId: id)),
            position: offset, duration: duration,
            updated: lastWatched ?? modified, modified: modified,
            continueWatching: inContinueWatching)
    }

    /// "tt123:2:5" → "S2E5"; "kitsu:1376:5" → "E5". Only what follows the title's own id is
    /// read, so a number inside the id (Kitsu's 1376) is never taken for a season.
    static func episodeLabel(_ videoId: String, metaId: String) -> String? {
        guard videoId.hasPrefix(metaId + ":") else { return nil }
        let numbers = videoId.dropFirst(metaId.count + 1).split(separator: ":").map { Int($0) }
        switch numbers.count {
        case 2: if let season = numbers[0], let episode = numbers[1] { return "S\(season)E\(episode)" }
        case 1: if let episode = numbers[0] { return "E\(episode)" }
        default: break
        }
        return nil
    }
}

enum StremioAPI {
    enum Failure: LocalizedError {
        case message(String)
        case sessionExpired

        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            case .sessionExpired: return "Your Stremio session expired."
            }
        }
    }

    static func call(_ method: String, _ body: [String: Any]) async throws -> Any {
        var request = URLRequest(url: URL(string: "https://api.strem.io/api/\(method)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try? JSONSerialization.jsonObject(with: data)
        if let error = (json as? [String: Any])?["error"] {
            let info = error as? [String: Any]
            let message = (info?["message"] as? String) ?? (error as? String) ?? "Stremio returned an error."
            let code = (info?["code"] as? NSNumber)?.intValue
            // Code 1 is "session does not exist" in Stremio's API.
            if code == 1 || message.localizedCaseInsensitiveContains("session") { throw Failure.sessionExpired }
            throw Failure.message(message)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.message("Stremio answered with HTTP \(http.statusCode).")
        }
        guard let result = (json as? [String: Any])?["result"] else {
            throw Failure.message("Unexpected answer from Stremio.")
        }
        return result
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    static func timestamp(_ date: Date) -> String { formatter.string(from: date) }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return formatter.date(from: text) ?? plainFormatter.date(from: text)
    }
}

/// Minimal Keychain storage for the Stremio session key.
enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "AtmosPlayer",
         kSecAttrAccount as String: key]
    }

    static func read(_ key: String) -> String? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        delete(key)
        var item = query(key)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}
