import Foundation

/// One addon stream, kept so it can be played again without asking the addons.
struct SavedStream: Codable, Hashable {
    let addonId: String
    let videoId: String
    let url: String?
    let infoHash: String?
    let fileIdx: Int?
    let sources: [String]
    let fileMustInclude: [String]
    let headers: [String: String]
    let bingeGroup: String?
    /// The addon's own name / description for the stream.
    let label: String?
    let saved: Date

    init(_ stream: StremioStream, addonId: String, videoId: String) {
        self.addonId = addonId
        self.videoId = videoId
        url = stream.url
        infoHash = stream.infoHash
        fileIdx = stream.fileIdx
        sources = stream.sources
        fileMustInclude = stream.fileMustInclude
        headers = stream.requestHeaders
        bingeGroup = stream.bingeGroup
        label = [stream.name, stream.title ?? stream.description].compactMap { $0 }.joined(separator: " · ")
        saved = Date()
    }

    var isTorrent: Bool { url == nil && infoHash != nil }

    /// Rebuilt each time, so a torrent follows the streaming server address currently set.
    var playableURL: URL? {
        StremioStream.makeURL(url: url, infoHash: infoHash, fileIdx: fileIdx, sources: sources,
                              fileMustInclude: fileMustInclude)
    }

    /// Whether `stream` (from a fresh addon answer) is this same stream.
    func matches(_ stream: StremioStream) -> Bool {
        if let infoHash, let other = stream.infoHash {
            return infoHash.lowercased() == other.lowercased() && fileIdx == stream.fileIdx
        }
        if let url, let other = stream.url { return url == other }
        return false
    }
}

/// The last stream played for each title, like Stremio's stream memory: Play and Continue
/// Watching start it straight away, and other episodes look for the same release.
@MainActor
final class LastStreamStore {
    static let shared = LastStreamStore()

    private let key = "lastStreams.v1"
    private var byTitle: [String: SavedStream] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let stored = try? JSONDecoder().decode([String: SavedStream].self, from: data) {
            byTitle = stored
        }
    }

    func stream(forTitle metaId: String) -> SavedStream? { byTitle[metaId] }

    func remember(_ stream: SavedStream, forTitle metaId: String) {
        byTitle[metaId] = stream
        // Keep the newest 300 titles.
        if byTitle.count > 300 {
            let oldest = byTitle.sorted { $0.value.saved < $1.value.saved }.prefix(byTitle.count - 300)
            for (key, _) in oldest { byTitle[key] = nil }
        }
        if let data = try? JSONEncoder().encode(byTitle) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Starting playback the way Stremio does when you press Play.
enum QuickPlay {
    /// Builds the player item for a video from a stream, and remembers the stream.
    @MainActor
    static func item(video: VideoRef, queue: [VideoRef], stream: SavedStream) -> PlayItem? {
        guard let url = stream.playableURL else { return nil }
        LastStreamStore.shared.remember(stream, forTitle: video.metaId)
        return PlayItem(url: url, title: video.displayTitle, headers: stream.headers, watch: video,
                        queue: queue, addonId: stream.addonId, bingeGroup: stream.bingeGroup,
                        poster: video.poster, stream: stream)
    }

    /// The stream to start without showing the list:
    /// - the exact stream last played for this movie / episode, or
    /// - for another episode of a series, the same release (bingeGroup) from the same addon.
    /// Returns nil when the user should pick from the stream list.
    @MainActor
    static func resolve(video: VideoRef, queue: [VideoRef], addons: AddonStore) async -> PlayItem? {
        guard let last = LastStreamStore.shared.stream(forTitle: video.metaId) else { return nil }
        if last.videoId == video.videoId {
            return item(video: video, queue: queue, stream: last)
        }
        guard let group = last.bingeGroup,
              let addon = addons.addons.first(where: { $0.id == last.addonId }),
              addon.manifest.supports("stream", type: video.type, id: video.videoId),
              let streams = try? await StremioClient.streams(addon, type: video.type, id: video.videoId),
              let match = streams.first(where: { $0.bingeGroup == group && $0.playableURL != nil }) else {
            return nil
        }
        return item(video: video, queue: queue,
                    stream: SavedStream(match, addonId: addon.id, videoId: video.videoId))
    }
}
