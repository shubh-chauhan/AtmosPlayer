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
    /// Landscape artwork (episode still or backdrop) for Continue Watching cards.
    var background: String? = nil

    var displayTitle: String {
        if let episodeLabel { return "\(name) · \(episodeLabel)" }
        return name
    }
}

/// Opening the stream list: the video plus the episodes after it (for "Next episode").
struct StreamsRoute: Hashable {
    let video: VideoRef
    var queue: [VideoRef] = []
}

/// A title shown in Home / Search, opened into its detail page.
struct MetaRef: Hashable, Codable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    var background: String? = nil
    var logo: String? = nil

    init(id: String, type: String, name: String, poster: String?, background: String? = nil, logo: String? = nil) {
        self.id = id
        self.type = type
        self.name = name
        self.poster = poster
        self.background = background
        self.logo = logo
    }

    init(_ preview: MetaPreview) {
        self.init(id: preview.id, type: preview.type, name: preview.name, poster: preview.poster,
                  background: preview.background, logo: preview.logo)
    }
}

/// "My List": titles saved from their detail page.
@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var items: [MetaRef] = []
    private let key = "favorites.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let stored = try? JSONDecoder().decode([MetaRef].self, from: data) {
            items = stored
        }
    }

    func contains(_ id: String) -> Bool { items.contains { $0.id == id } }

    func toggle(_ ref: MetaRef) {
        if contains(ref.id) {
            items.removeAll { $0.id == ref.id }
        } else {
            items.insert(ref, at: 0)
        }
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
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
        // Installing again undoes an earlier removal.
        let removed = (UserDefaults.standard.stringArray(forKey: removedKey) ?? []).filter { $0 != manifest.id }
        UserDefaults.standard.set(removed, forKey: removedKey)
        if let index = addons.firstIndex(where: { $0.id == manifest.id }) {
            addons[index] = addon
        } else {
            addons.append(addon)
        }
        save()
        return manifest.name
    }

    /// Takes over the addon list of the signed-in Stremio account, in its order. Addons added
    /// only in this app stay, after the account's. Stremio's on-device "local" addon is skipped.
    func adoptAccountAddons(_ collection: [(url: String, manifest: Data)]) {
        var adopted: [InstalledAddon] = []
        let removed = Set(UserDefaults.standard.stringArray(forKey: removedKey) ?? [])
        for entry in collection {
            guard let url = URL(string: entry.url), let host = url.host?.lowercased(),
                  host != "127.0.0.1", host != "localhost",
                  let manifest = try? JSONDecoder().decode(StremioManifest.self, from: entry.manifest),
                  !removed.contains(manifest.id),
                  !adopted.contains(where: { $0.id == manifest.id }) else { continue }
            adopted.append(InstalledAddon(transportURL: entry.url, manifest: manifest))
            manifestCache[manifest.id] = entry.manifest
        }
        guard !adopted.isEmpty else { return }
        let extras = addons.filter { local in !adopted.contains { $0.id == local.id } }
        let merged = adopted + extras
        // Skip the save (and the Home reload it triggers) when nothing changed.
        let unchanged = merged.map { "\($0.id)|\($0.transportURL)" } == addons.map { "\($0.id)|\($0.transportURL)" }
        addons = merged
        UserDefaults.standard.set(true, forKey: seededKey)
        if !unchanged { save() }
    }

    /// Addons removed here stay removed even though the Stremio account still lists them.
    private let removedKey = "addons.removed"

    func remove(at offsets: IndexSet) {
        var removed = UserDefaults.standard.stringArray(forKey: removedKey) ?? []
        for index in offsets {
            manifestCache[addons[index].id] = nil
            if !removed.contains(addons[index].id) { removed.append(addons[index].id) }
        }
        UserDefaults.standard.set(removed, forKey: removedKey)
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

    /// One Stremio library item's progress, as `StremioAccount` reads it.
    struct StremioSnapshot {
        let ref: VideoRef
        let position: Double
        let duration: Double
        let updated: Date
        let modified: Date
        let continueWatching: Bool
    }

    @Published private(set) var entries: [Entry] = []
    /// Set by the app to forward progress to the Stremio account.
    var onRecord: ((VideoRef, Double, Double) -> Void)?
    private let key = "watch.v1"
    private let limit = 40

    /// Merges Stremio's Continue Watching: whichever side was watched more recently wins, and
    /// a title cleared in Stremio after it was last watched here leaves the list. One entry per title.
    func mergeFromStremio(_ snapshots: [StremioSnapshot]) {
        var byTitle: [String: Entry] = [:]
        for entry in entries {
            if let existing = byTitle[entry.ref.metaId], existing.updated >= entry.updated { continue }
            byTitle[entry.ref.metaId] = entry
        }
        for snapshot in snapshots {
            let local = byTitle[snapshot.ref.metaId]
            if snapshot.continueWatching {
                if local == nil || snapshot.updated > local!.updated {
                    var ref = snapshot.ref
                    // Keep the nicer artwork and episode title known locally for the same episode.
                    if let local, local.ref.videoId == ref.videoId { ref = local.ref }
                    byTitle[snapshot.ref.metaId] = Entry(ref: ref, position: snapshot.position,
                                                         duration: snapshot.duration, updated: snapshot.updated)
                }
            } else if let local, local.position > 0, snapshot.modified > local.updated + 60 {
                byTitle[snapshot.ref.metaId] = nil
            }
        }
        let merged = Array(byTitle.values.sorted { $0.updated > $1.updated }.prefix(limit))
        let same = merged.map { "\($0.id)@\($0.position)" } == entries.map { "\($0.id)@\($0.position)" }
        guard !same else { return }
        entries = merged
        if let data = try? JSONEncoder().encode(merged) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

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

    /// Set by the app to clear a title from Stremio's Continue Watching too.
    var onRemove: ((VideoRef) -> Void)?

    /// Saves where playback is. Views under 30 seconds change nothing (so closing a stream
    /// that never started can't wipe a resume point). A finished episode is replaced by the
    /// next one at its start, so the series continues where you are; a finished movie leaves.
    /// `push` sends it to the Stremio account too (on close / background, not every save).
    func record(_ ref: VideoRef, position: Double, duration: Double, next: VideoRef? = nil, push: Bool = true) {
        guard position.isFinite, duration.isFinite, duration > 0 else { return }
        let finished = position > duration - max(120, duration * 0.05)
        guard position >= 30 || finished else { return }
        if push { onRecord?(ref, position, duration) }
        if finished { WatchedStore.shared.markFinished(ref) }
        // One entry per title: a new episode replaces the previous one of the same series.
        var updated = entries.filter { $0.ref.videoId != ref.videoId && $0.ref.metaId != ref.metaId }
        if !finished {
            updated.insert(Entry(ref: ref, position: position, duration: duration, updated: Date()), at: 0)
        } else if let next {
            updated.insert(Entry(ref: next, position: 0, duration: 0, updated: Date()), at: 0)
        }
        if updated.count > limit { updated = Array(updated.prefix(limit)) }
        entries = updated
        if let data = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func clearAll() {
        entries = []
        UserDefaults.standard.removeObject(forKey: key)
    }

    func remove(_ videoId: String) {
        if let entry = entries.first(where: { $0.ref.videoId == videoId }) { onRemove?(entry.ref) }
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
    /// A Continue Watching item the widget asked to resume (its video id).
    @Published var pendingResume: String?

    func play(_ item: PlayItem) {
        current = item
    }
}
