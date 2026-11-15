import Foundation
import SwiftUI

/// What the player screen is asked to play.
struct PlayItem: Identifiable {
    let id = UUID()
    let url: URL
    /// Name to show; links pasted by hand derive one from the URL.
    var title: String? = nil
    /// Request headers an addon asked for (`behaviorHints.proxyHeaders.request`).
    var headers: [String: String] = [:]
    /// Set when played from Discover, so the position is remembered for resuming.
    var watch: VideoRef? = nil
    /// True for a file picked from the Files app: access must be released when playback ends.
    var securityScoped: Bool = false

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        // Use the last path part that looks like a name; stream links often end in a bare
        // file index such as "/0".
        let parts = url.pathComponents
            .filter { $0 != "/" }
            .map { $0.removingPercentEncoding ?? $0 }
        if let named = parts.last(where: { $0.contains(".") || Int($0) == nil }) {
            return named
        }
        return url.host ?? url.absoluteString
    }
}

/// Recently played links, newest first, kept in UserDefaults.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [String] = []
    private let key = "history.urls"
    private let limit = 30

    init() {
        entries = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func add(_ url: URL) {
        let text = url.absoluteString
        var updated = entries.filter { $0 != text }
        updated.insert(text, at: 0)
        if updated.count > limit { updated = Array(updated.prefix(limit)) }
        save(updated)
    }

    func remove(at offsets: IndexSet) {
        var updated = entries
        updated.remove(atOffsets: offsets)
        save(updated)
    }

    func clear() {
        save([])
    }

    private func save(_ updated: [String]) {
        entries = updated
        UserDefaults.standard.set(updated, forKey: key)
    }
}

/// Thread-safe ring buffer of the engine's diagnostic lines. The engine calls `append` from any
/// thread, so this never touches the UI; the debug overlay reads a snapshot once a second.
final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity = 400

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        lock.unlock()
    }

    func tail(_ count: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(lines.suffix(count))
    }

    func all() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds)
    let h = total / 3600
    let m = (total / 60) % 60
    let s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}
