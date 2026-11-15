import Foundation

/// Finds a stream for the next episode, preferring the same addon and the same release
/// (`bingeGroup`) as the one playing, the way Stremio's binge-watching does.
enum StreamResolver {
    @MainActor
    static func next(after item: PlayItem, addons: AddonStore) async -> PlayItem? {
        guard let next = item.queue.first else { return nil }
        var sources = addons.supporting("stream", type: next.type, id: next.videoId)
        if let same = sources.firstIndex(where: { $0.id == item.addonId }) {
            sources.insert(sources.remove(at: same), at: 0)
        }
        for addon in sources {
            guard let streams = try? await StremioClient.streams(addon, type: next.type, id: next.videoId) else { continue }
            let playable = streams.filter { $0.playableURL != nil }
            var pick: StremioStream?
            if let group = item.bingeGroup {
                pick = playable.first { $0.bingeGroup == group }
            }
            if pick == nil, item.bingeGroup != nil, addon.id == item.addonId {
                // Same addon but the release changed: prefer one that keeps Atmos.
                pick = playable.first { $0.badges.contains("Atmos") } ?? playable.first
            }
            if pick == nil { pick = playable.first }
            if let pick, let url = pick.playableURL {
                return PlayItem(url: url,
                                title: next.displayTitle,
                                headers: pick.requestHeaders,
                                watch: next,
                                queue: Array(item.queue.dropFirst()),
                                addonId: addon.id,
                                bingeGroup: pick.bingeGroup,
                                poster: next.poster)
            }
        }
        return nil
    }
}
