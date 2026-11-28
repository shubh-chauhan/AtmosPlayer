import Foundation

/// Finds a stream for the next episode, preferring the same addon and the same release
/// (`bingeGroup`) as the one playing, the way Stremio's binge-watching does.
enum StreamResolver {
    @MainActor
    static func next(after item: PlayItem, addons: AddonStore) async -> PlayItem? {
        guard let next = item.queue.first else { return nil }
        if let saved = QuickPlay.downloaded(next, queue: Array(item.queue.dropFirst())) { return saved }
        var sources = addons.supporting("stream", type: next.type, id: next.videoId)
        if let same = sources.firstIndex(where: { $0.id == item.addonId }) {
            sources.insert(sources.remove(at: same), at: 0)
        }
        let selected = StreamFilterStore.decode(UserDefaults.standard.string(forKey: StreamFilterStore.key) ?? "")
        // The best stream (your filters) from the first addon that has one, if the release doesn't match.
        var fallback: (stream: StremioStream, addonId: String)?
        for addon in sources {
            guard let streams = try? await StremioClient.streams(addon, type: next.type, id: next.videoId) else { continue }
            let playable = streams.filter { $0.playableURL != nil }
            if fallback == nil, let best = QuickPlay.pickBest([playable], selected: selected)?.stream {
                fallback = (best, addon.id)
            }
            var pick: StremioStream?
            if let group = item.bingeGroup {
                pick = playable.first { $0.bingeGroup == group }
            } else if addon.id == item.addonId {
                pick = playable.first { $0.badges.contains("Atmos") } ?? playable.first
            }
            if let pick,
               let resolved = QuickPlay.item(video: next, queue: Array(item.queue.dropFirst()),
                                             stream: SavedStream(pick, addonId: addon.id, videoId: next.videoId)) {
                return resolved
            }
        }
        if let fallback {
            return QuickPlay.item(video: next, queue: Array(item.queue.dropFirst()),
                                  stream: SavedStream(fallback.stream, addonId: fallback.addonId, videoId: next.videoId))
        }
        return nil
    }
}
