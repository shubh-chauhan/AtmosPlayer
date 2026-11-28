import Foundation

// MARK: - Saved stores on disk

/// The app's own lists (My List, Continue Watching, watched marks, addons, the Stremio library,
/// downloads, stream memory), saved as JSON files in Application Support instead of
/// UserDefaults, which loads everything at launch and slows down as a library grows.
/// A store saved in UserDefaults by an older build is moved over the first time it's read.
enum DiskStore {
    private static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("stores", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Writes run in order, off the main thread.
    private static let queue = DispatchQueue(label: "atmosplayer.diskstore", qos: .utility)

    static func file(_ key: String) -> URL { folder.appendingPathComponent(key + ".json") }

    /// The saved value, from its file, else from UserDefaults (then moved to a file).
    static func load<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        if let data = try? Data(contentsOf: file(key)) {
            return try? JSONDecoder().decode(T.self, from: data)
        }
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(T.self, from: data) else { return nil }
        // Same encoder as before, so the bytes move over unchanged.
        if (try? data.write(to: file(key), options: .atomic)) != nil {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return value
    }

    static func save<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let url = file(key)
        queue.async { try? data.write(to: url, options: .atomic) }
    }

    static func remove(_ key: String) {
        UserDefaults.standard.removeObject(forKey: key)
        let url = file(key)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }
}

// MARK: - Account writes waiting to be sent

/// Progress, ✓ marks and history that couldn't reach Stremio or Trakt (no signal, server
/// down) are saved here and sent again on the next sync, so nothing you watch is lost.
@MainActor
final class PendingWrites {
    static let shared = PendingWrites()

    enum Op: Codable, Equatable {
        case stremioProgress(ref: VideoRef, position: Double, duration: Double, at: Date)
        case stremioWatched(metaId: String, type: String, watched: [String], videoIds: [String]?)
        case stremioClear(ref: VideoRef)
        case traktScrobble(ref: VideoRef, progress: Double, at: Date)
        case traktHistory(metaId: String, type: String, videoIds: [String], add: Bool, at: Date)

        /// A newer write with the same key replaces an older one (only the latest state matters).
        var key: String {
            switch self {
            case .stremioProgress(let ref, _, _, _): return "sp/\(ref.metaId)"
            case .stremioWatched(let metaId, _, _, _): return "sw/\(metaId)"
            case .stremioClear(let ref): return "sc/\(ref.metaId)"
            case .traktScrobble(let ref, _, _): return "ts/\(ref.videoId)"
            case .traktHistory(let metaId, _, let ids, _, _):
                return "th/\(metaId)/\(ids.sorted().joined(separator: ","))"
            }
        }

        var isStremio: Bool {
            switch self {
            case .stremioProgress, .stremioWatched, .stremioClear: return true
            default: return false
            }
        }
    }

    private let storeKey = "pendingWrites.v1"
    private(set) var ops: [Op]

    private init() {
        ops = DiskStore.load(storeKey, as: [Op].self) ?? []
    }

    func add(_ op: Op) {
        ops.removeAll { $0.key == op.key }
        ops.append(op)
        // shortcut: at most 300 waiting writes (the oldest go), plenty for weeks offline.
        if ops.count > 300 { ops.removeFirst(ops.count - 300) }
        DiskStore.save(ops, storeKey)
    }

    /// A write with this key went through: an older copy waiting here is no longer needed.
    func resolve(_ key: String) {
        guard ops.contains(where: { $0.key == key }) else { return }
        ops.removeAll { $0.key == key }
        DiskStore.save(ops, storeKey)
    }

    /// Only failures that can pass by themselves are kept: no connection, or a server error.
    static func isTemporary(_ error: Error) -> Bool {
        if error is URLError { return true }
        if let failure = error as? StremioAPI.Failure, case .message(let text) = failure { return text.contains("HTTP 5") }
        return false
    }

    /// Removes and returns the waiting writes for one service, oldest first.
    func take(stremio: Bool) -> [Op] {
        let taken = ops.filter { $0.isStremio == stremio }
        guard !taken.isEmpty else { return [] }
        ops.removeAll { $0.isStremio == stremio }
        DiskStore.save(ops, storeKey)
        return taken
    }

    var count: Int { ops.count }
}
