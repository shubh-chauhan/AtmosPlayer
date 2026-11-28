import Foundation
import ActivityKit
import Combine
import UIKit
import WidgetKit
import EngineBundle

/// Runs the Live Activity for what's playing and answers its buttons.
@MainActor
final class PlaybackRemote {
    static let shared = PlaybackRemote()

    private weak var engine: AetherEngine?
    private var activity: Activity<PlaybackAttributes>?
    private var cancellables: Set<AnyCancellable> = []
    private var ticker: Task<Void, Never>?

    /// Starts (or retitles) the Live Activity for this engine's session.
    func attach(engine: AetherEngine, title: String, subtitle: String?) {
        self.engine = engine
        cancellables.removeAll()
        engine.$state.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        engine.$duration.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        // No Live Activity any more (it sat in the Dynamic Island the whole time something
        // played); end any an older build left behind.
        Task {
            for old in Activity<PlaybackAttributes>.activities {
                await old.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Ends the Live Activity (the player closed).
    func detach() {
        ticker?.cancel()
        cancellables.removeAll()
        engine = nil
        let ending = activity
        activity = nil
        Task {
            await ending?.end(nil, dismissalPolicy: .immediate)
            for old in Activity<PlaybackAttributes>.activities {
                await old.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func togglePlayPause() {
        engine?.togglePlayPause()
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            refresh()
        }
    }

    func skip(_ seconds: Double) {
        guard let engine else { return }
        var target = max(engine.clock.currentTime + seconds, 0)
        if engine.duration > 0 { target = min(target, max(engine.duration - 1, 0)) }
        Task {
            await engine.seek(to: target)
            refresh()
        }
    }

    /// Call after anything that moves the position (a seek in the app).
    func refresh() {
        guard let activity else { return }
        let content = ActivityContent(state: currentState(), staleDate: nil)
        Task { await activity.update(content) }
    }

    private func currentState() -> PlaybackAttributes.ContentState {
        PlaybackAttributes.ContentState(
            isPlaying: engine?.state == .playing,
            position: engine?.clock.currentTime ?? 0,
            duration: engine?.duration ?? 0,
            updatedAt: Date())
    }
}

/// Writes Continue Watching (with small artwork files) for the home-screen widget.
@MainActor
enum WidgetBridge {
    private static var running: Task<Void, Never>?

    static func update(_ entries: [WatchStore.Entry]) {
        running?.cancel()
        running = Task { await write(Array(entries.prefix(6))) }
    }

    private static func write(_ entries: [WatchStore.Entry]) async {
        guard WidgetFeed.available, let folder = SharedContainer.artFolder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var items: [WidgetWatchItem] = []
        var keep = Set<String>()
        for entry in entries {
            if Task.isCancelled { return }
            let file = fileName(entry.ref.videoId)
            let path = folder.appendingPathComponent(file)
            var art: String?
            if FileManager.default.fileExists(atPath: path.path) {
                art = file
            } else {
                for candidate in ArtworkURL.landscapeCandidates(for: entry.ref) {
                    guard let url = ArtworkURL.best(candidate, maxPixel: 700),
                          let image = await ImagePipeline.shared.image(url, maxPixel: 700),
                          let data = image.jpegData(compressionQuality: 0.8) else { continue }
                    try? data.write(to: path, options: .atomic)
                    art = file
                    break
                }
            }
            if let art { keep.insert(art) }
            items.append(WidgetWatchItem(id: entry.ref.videoId, name: entry.ref.name,
                                         subtitle: subtitle(entry), progress: entry.progress, artFile: art))
        }
        // Drop artwork of items no longer listed.
        if let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
            for name in files where !keep.contains(name) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }
        WidgetFeed.save(items)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func fileName(_ id: String) -> String {
        String(id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }) + ".jpg"
    }

    private static func subtitle(_ entry: WatchStore.Entry) -> String {
        let minutes = Int(max(entry.duration - entry.position, 0) / 60)
        let left = entry.duration <= 0 ? "Up next"
            : minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min left" : "\(minutes) min left"
        if let label = entry.ref.episodeLabel {
            let code = label.split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? label
            return "\(code) · \(left)"
        }
        return left
    }
}
