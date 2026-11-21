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
        byTitle = DiskStore.load(key, as: [String: SavedStream].self) ?? [:]
    }

    func stream(forTitle metaId: String) -> SavedStream? { byTitle[metaId] }

    func remember(_ stream: SavedStream, forTitle metaId: String) {
        byTitle[metaId] = stream
        // Keep the newest 300 titles.
        if byTitle.count > 300 {
            let oldest = byTitle.sorted { $0.value.saved < $1.value.saved }.prefix(byTitle.count - 300)
            for (key, _) in oldest { byTitle[key] = nil }
        }
        DiskStore.save(byTitle, key)
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
    /// - for another episode of a series, the same release (bingeGroup) from the same addon, or
    /// - with "Play starts the best stream" on (Settings), the best one your addons have.
    /// Returns nil when the user should pick from the stream list.
    @MainActor
    static func resolve(video: VideoRef, queue: [VideoRef], addons: AddonStore) async -> PlayItem? {
        if let last = LastStreamStore.shared.stream(forTitle: video.metaId) {
            if last.videoId == video.videoId {
                return item(video: video, queue: queue, stream: last)
            }
            if let group = last.bingeGroup,
               let addon = addons.addons.first(where: { $0.id == last.addonId }),
               addon.manifest.supports("stream", type: video.type, id: video.videoId),
               let streams = try? await StremioClient.streams(addon, type: video.type, id: video.videoId),
               let match = streams.first(where: { $0.bingeGroup == group && $0.playableURL != nil }) {
                return item(video: video, queue: queue,
                            stream: SavedStream(match, addonId: addon.id, videoId: video.videoId))
            }
        }
        return autoPickOn ? await best(video: video, queue: queue, addons: addons) : nil
    }

    static let autoPickKey = "streams.autoPickBest"
    /// Off unless turned on: the first play of a title opens the stream list, so you choose.
    static var autoPickOn: Bool { Prefs.bool(autoPickKey, default: false) }

    /// Every addon asked at once (10 s at most); the best playable stream that passes your saved
    /// filters starts: resolution, then Dolby Vision / HDR, then Atmos and lossless sound, then
    /// source, the first addon in your order winning a tie. Never a camera recording.
    @MainActor
    static func best(video: VideoRef, queue: [VideoRef], addons: AddonStore) async -> PlayItem? {
        let sources = addons.supporting("stream", type: video.type, id: video.videoId)
        guard !sources.isEmpty else { return nil }
        let selected = StreamFilterStore.decode(UserDefaults.standard.string(forKey: StreamFilterStore.key) ?? "")
        let found = await withTaskGroup(of: (Int, [StremioStream]).self) { group in
            for (index, addon) in sources.enumerated() {
                group.addTask { (index, (try? await StremioClient.streams(addon, type: video.type, id: video.videoId)) ?? []) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return (-1, [])
            }
            var out: [Int: [StremioStream]] = [:]
            for await (index, streams) in group {
                if index < 0 { break }
                out[index] = streams
                if out.count == sources.count { break }
            }
            group.cancelAll()
            return out
        }
        guard let pick = pickBest(sources.indices.map { found[$0] ?? [] }, selected: selected) else { return nil }
        return item(video: video, queue: queue,
                    stream: SavedStream(pick.stream, addonId: sources[pick.addon].id, videoId: video.videoId))
    }

    /// The best stream across addons' answers (in addon order): highest quality score among
    /// playable ones that pass `selected`, earliest on a tie. No camera recordings.
    static func pickBest(_ answers: [[StremioStream]], selected: Set<StreamFilter>) -> (addon: Int, stream: StremioStream)? {
        var pick: (addon: Int, stream: StremioStream, score: Int)?
        for (index, streams) in answers.enumerated() {
            for stream in streams where stream.playableURL != nil && stream.traits.source != .cam
                && StreamFilter.matches(stream.traits, selected: selected) {
                let score = stream.traits.qualityScore
                if pick == nil || score > pick!.score { pick = (index, stream, score) }
            }
        }
        return pick.map { ($0.addon, $0.stream) }
    }
}
