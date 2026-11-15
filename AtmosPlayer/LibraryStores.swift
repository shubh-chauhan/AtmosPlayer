import Foundation
import SwiftUI

/// One playable video in Stremio terms: a movie, or one episode of a series.
struct VideoRef: Hashable, Codable {
    let type: String
    let metaId: String
    /// The id streams are asked for: the movie id, or "tt…:season:episode".
    let videoId: String
    let name: String
    let poster: String?
    /// "S1E2 · Episode title" for episodes, nil for movies.
    let episodeLabel: String?

    var displayTitle: String {
        if let episodeLabel { return "\(name) · \(episodeLabel)" }
        return name
    }
}

/// A title shown in Discover / search, opened into its detail page.
struct MetaRef: Hashable {
    let id: String
    let type: String
    let name: String
    let poster: String?
}

/// Installed Stremio addons, in the order the user added them. Persisted as the manifest URL
/// plus the manifest JSON, so the app opens without re-fetching every manifest.
@MainActor
final class AddonStore: ObservableObject {
    @Published private(set) var addons: [InstalledAddon] = []
    /// Bumped on every change so screens can reload what depends on the addon list.
    @Published private(set) var revision = 0

    private struct Stored: Codable {
        let url: String
        let manifest: Data
    }

    private let key = "addons.v1"
    private let seededKey = "addons.seeded"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let stored = try? JSONDecoder().decode([Stored].self, from: data) {
            var loaded: [InstalledAddon] = []
            for entry in stored {
                guard let manifest = try? JSONDecoder().decode(StremioManifest.self, from: entry.manifest) else { continue }
                loaded.append(InstalledAddon(transportURL: entry.url, manifest: manifest))
                manifestCache[manifest.id] = entry.manifest
            }
            addons = loaded
        }
        if !UserDefaults.standard.bool(forKey: seededKey) {
            // First launch: Cinemeta, Stremio's official catalog addon, so Discover has something to show.
            Task { [weak self] in
                guard let self else { return }
                if (try? await self.install(StremioClient.cinemetaURL)) != nil {
                    UserDefaults.standard.set(true, forKey: self.seededKey)
                }
            }
        }
    }

    /// Installs (or refreshes) the addon behind a pasted link. Returns its name.
    @discardableResult
    func install(_ raw: String) async throws -> String {
        guard let url = StremioClient.normalizeManifestURL(raw) else { throw StremioError.badURL }
        let (manifest, data) = try await StremioClient.fetchManifest(url)
        let addon = InstalledAddon(transportURL: url.absoluteString, manifest: manifest)
        manifestCache[manifest.id] = data
        if let index = addons.firstIndex(where: { $0.id == manifest.id }) {
            addons[index] = addon
        } else {
            addons.append(addon)
        }
        save()
        return manifest.name
    }

    func remove(at offsets: IndexSet) {
        for index in offsets { manifestCache[addons[index].id] = nil }
        addons.remove(atOffsets: offsets)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        addons.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func supporting(_ resource: String, type: String, id: String) -> [InstalledAddon] {
        addons.filter { $0.manifest.supports(resource, type: type, id: id) }
    }

    // Raw manifest JSON per addon id, kept so `save` can persist without re-encoding.
    private var manifestCache: [String: Data] = [:]

    private func save() {
        let stored: [Stored] = addons.compactMap { addon in
            guard let json = manifestCache[addon.id] else { return nil }
            return Stored(url: addon.transportURL, manifest: json)
        }
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: key)
        }
        revision += 1
    }
}

/// Where you stopped in each movie or episode, for "Continue watching" and resuming.
@MainActor
final class WatchStore: ObservableObject {
    struct Entry: Codable, Identifiable {
        var id: String { ref.videoId }
        let ref: VideoRef
        let position: Double
        let duration: Double
        let updated: Date

        var progress: Double { duration > 0 ? min(position / duration, 1) : 0 }
    }

    @Published private(set) var entries: [Entry] = []
    private let key = "watch.v1"
    private let limit = 40

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let stored = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = stored
        }
    }

    /// Resume point for a video, or nil to start from the beginning.
    func resumePosition(for videoId: String) -> Double? {
        entries.first { $0.ref.videoId == videoId }?.position
    }

    /// Called when the player closes. Very short views are ignored, and a video watched to
    /// (nearly) the end leaves the list.
    func record(_ ref: VideoRef, position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite else { return }
        var updated = entries.filter { $0.ref.videoId != ref.videoId }
        let finished = duration > 0 && position > duration - max(120, duration * 0.05)
        if position >= 30 && !finished {
            updated.insert(Entry(ref: ref, position: position, duration: duration, updated: Date()), at: 0)
        }
        if updated.count > limit { updated = Array(updated.prefix(limit)) }
        entries = updated
        if let data = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func remove(_ videoId: String) {
        entries.removeAll { $0.ref.videoId == videoId }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Presents the full-screen player from any tab.
@MainActor
final class PlayerCoordinator: ObservableObject {
    @Published var current: PlayItem?

    func play(_ item: PlayItem) {
        current = item
    }
}
