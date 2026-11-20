import Foundation
import Compression

// MARK: - Stremio's watched field

/// Stremio keeps a series' watched episodes as one string:
/// `<anchor video id>:<anchor length>:<base64 of a zlib-compressed bitfield>`.
/// Bit i (least significant bit first) is the i-th video of the title's video list, and the
/// anchor lets the list grow (new episodes) without the bits shifting.
enum WatchedBitfield {
    static func decode(_ field: String, videoIds: [String]) -> Set<String> {
        // Video ids contain ":", so split from the right.
        guard let lastColon = field.lastIndex(of: ":") else { return [] }
        let packed = String(field[field.index(after: lastColon)...])
        let head = field[..<lastColon]
        guard let secondColon = head.lastIndex(of: ":"),
              let anchorLength = Int(head[head.index(after: secondColon)...]) else { return [] }
        let anchor = String(head[..<secondColon])
        guard let compressed = Data(base64Encoded: packed), let bytes = inflate(compressed),
              let anchorIndex = videoIds.firstIndex(of: anchor) else { return [] }
        let offset = anchorLength - anchorIndex - 1
        let bitCount = bytes.count * 8
        var watched = Set<String>()
        for (i, id) in videoIds.enumerated() {
            let previous = i + offset
            guard previous >= 0, previous < bitCount else { continue }
            if bytes[previous / 8] & (1 << UInt8(previous % 8)) != 0 { watched.insert(id) }
        }
        return watched
    }

    static func encode(_ watched: Set<String>, videoIds: [String]) -> String? {
        guard !videoIds.isEmpty else { return nil }
        var bytes = [UInt8](repeating: 0, count: (videoIds.count + 7) / 8)
        var last = -1
        for (i, id) in videoIds.enumerated() where watched.contains(id) {
            bytes[i / 8] |= 1 << UInt8(i % 8)
            last = i
        }
        guard let packed = deflate(Data(bytes)) else { return nil }
        let anchorIndex = max(last, 0)
        let anchor = last >= 0 ? videoIds[anchorIndex] : "undefined"
        return "\(anchor):\(anchorIndex + 1):\(packed.base64EncodedString())"
    }

    // zlib = 2-byte header + raw deflate + Adler-32. Apple's Compression speaks raw deflate.

    private static func inflate(_ data: Data) -> [UInt8]? {
        guard data.count > 2 else { return nil }
        let body = [UInt8](data.dropFirst(2))
        let capacity = 1 << 16
        var output = [UInt8](repeating: 0, count: capacity)
        let written = compression_decode_buffer(&output, capacity, body, body.count, nil, COMPRESSION_ZLIB)
        guard written > 0 else { return nil }
        return Array(output.prefix(written))
    }

    private static func deflate(_ data: Data) -> Data? {
        let input = [UInt8](data)
        let capacity = input.count + 64
        var output = [UInt8](repeating: 0, count: capacity)
        let written = compression_encode_buffer(&output, capacity, input, input.count, nil, COMPRESSION_ZLIB)
        guard written > 0 else { return nil }
        var result = Data([0x78, 0x9C])
        result.append(contentsOf: output.prefix(written))
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in input {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let adler = (b << 16) | a
        result.append(contentsOf: [UInt8(adler >> 24), UInt8((adler >> 16) & 0xff), UInt8((adler >> 8) & 0xff), UInt8(adler & 0xff)])
        return result
    }
}

// MARK: - Store

/// Which movies and episodes are watched, kept in step with the Stremio account both ways.
/// Whichever side changed a title last wins.
@MainActor
final class WatchedStore: ObservableObject {
    static let shared = WatchedStore()

    struct Record: Codable {
        /// Watched video ids (a movie uses its own id).
        var videos: Set<String> = []
        var changed: Date = .distantPast
        /// Stremio's copy, decoded once the title's episode list is known.
        var remoteField: String?
        var remoteChanged: Date = .distantPast
        /// What Trakt has as watched, kept so a newer Stremio copy can't drop it.
        var trakt: Set<String>?
    }

    @Published private(set) var records: [String: Record] = [:]
    /// Set by the app: sends a title's watched state to Stremio.
    var onChange: ((_ metaId: String, _ type: String, _ watched: Set<String>, _ videoIds: [String]?) -> Void)?
    /// Set by the app: marks changed by hand (not by finishing playback, which Trakt's
    /// scrobble already records), for Trakt's history.
    var onMarkByHand: ((_ metaId: String, _ type: String, _ ids: [String], _ watched: Bool) -> Void)?

    private let key = "watched.v1"

    private init() {
        records = DiskStore.load(key, as: [String: Record].self) ?? [:]
    }

    func isWatched(_ videoId: String, metaId: String) -> Bool {
        records[metaId]?.videos.contains(videoId) ?? false
    }

    func watchedCount(metaId: String) -> Int { records[metaId]?.videos.count ?? 0 }

    /// Marks videos watched or unwatched here and in Stremio. `videoIds` is the title's full
    /// episode list in the addon's order (nil for movies).
    func set(_ ids: [String], watched: Bool, metaId: String, type: String, videoIds: [String]?,
             byHand: Bool = true) {
        var record = records[metaId] ?? Record()
        if watched {
            record.videos.formUnion(ids)
        } else {
            record.videos.subtract(ids)
            record.trakt?.subtract(ids)
        }
        record.changed = Date()
        records[metaId] = record
        save()
        onChange?(metaId, type, record.videos, videoIds)
        if byHand { onMarkByHand?(metaId, type, ids, watched) }
    }

    /// A movie or episode played to the end.
    func markFinished(_ ref: VideoRef) {
        guard !isWatched(ref.videoId, metaId: ref.metaId) else { return }
        set([ref.videoId], watched: true, metaId: ref.metaId, type: ref.type, videoIds: nil, byHand: false)
    }

    /// From a Trakt sync: what Trakt has as watched for a title is added here (never removed,
    /// and Stremio isn't written to; a later Stremio copy keeps these marks).
    func adoptTrakt(metaId: String, ids: Set<String>) {
        var record = records[metaId] ?? Record()
        guard record.trakt != ids || !ids.isSubset(of: record.videos) else { return }
        record.trakt = ids
        record.videos.formUnion(ids)
        records[metaId] = record
        save()
    }

    /// From a Stremio sync. Movies apply at once; a series' field waits for its episode list.
    func adoptRemote(metaId: String, type: String, field: String?, movieWatched: Bool, modified: Date) {
        var record = records[metaId] ?? Record()
        guard modified > record.changed else { return }
        if type == "movie" {
            let remote: Set<String> = movieWatched ? [metaId] : []
            let videos = remote.union(record.trakt ?? [])
            guard videos != record.videos else { return }
            record.videos = videos
            record.changed = modified
        } else {
            guard let field, !field.isEmpty, field != record.remoteField else { return }
            record.remoteField = field
            record.remoteChanged = modified
        }
        records[metaId] = record
        save()
    }

    /// Called when a title page knows the episode list: applies a newer Stremio copy.
    func reconcile(metaId: String, videoIds: [String]) {
        guard var record = records[metaId], let field = record.remoteField,
              record.remoteChanged > record.changed else { return }
        record.videos = WatchedBitfield.decode(field, videoIds: videoIds).union(record.trakt ?? [])
        record.changed = record.remoteChanged
        records[metaId] = record
        save()
    }

    func clearAll() {
        records = [:]
        DiskStore.remove(key)
    }

    private func save() {
        DiskStore.save(records, key)
    }
}
