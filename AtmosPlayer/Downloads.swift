import SwiftUI
import UIKit

// MARK: - Model

/// One movie or episode saved to the device for watching offline.
struct DownloadEntry: Identifiable, Codable, Hashable {
    enum Phase: String, Codable { case downloading, done, failed }

    let id: String
    let video: VideoRef
    /// The link it is fetched from, with the headers the addon asked for.
    let source: String
    var headers: [String: String] = [:]
    /// The addon's name for the stream ("4K DV Atmos…"), shown under the title.
    var label: String?
    /// The file's name inside Documents/Downloads once it has arrived.
    var fileName: String?
    var phase: Phase = .downloading
    var received: Int64 = 0
    var total: Int64 = 0
    var added = Date()
    var error: String?

    var fraction: Double { total > 0 ? min(Double(received) / Double(total), 1) : 0 }
}

// MARK: - Store

/// Downloads run in a background URLSession, so they carry on while the app is in the
/// background or the screen is locked. Files land in Documents/Downloads (visible in the Files
/// app under Atmos Player).
@MainActor
final class DownloadStore: NSObject, ObservableObject {
    static let shared = DownloadStore()

    @Published private(set) var entries: [DownloadEntry] = []

    /// Set by the app delegate when iOS wakes the app to finish background downloads.
    nonisolated(unsafe) static var backgroundCompletion: (() -> Void)?
    nonisolated static let sessionId = "com.atmosplayer.downloads"

    private static let key = "downloads.v1"
    private var lastPublish: [String: Date] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionId)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    nonisolated static var folder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var folder = documents.appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Big and re-downloadable: keep it out of iCloud backups.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
        }
        return folder
    }

    private override init() {
        super.init()
        entries = DiskStore.load(Self.key, as: [DownloadEntry].self) ?? []
        // Downloads that were running when the app was closed: still running in the session,
        // or lost (the app was force-quit), in which case they are offered for retry.
        session.getAllTasks { tasks in
            let alive = Set(tasks.compactMap(\.taskDescription))
            Task { @MainActor in
                for index in self.entries.indices where self.entries[index].phase == .downloading
                    && !alive.contains(self.entries[index].id) {
                    self.entries[index].phase = .failed
                    self.entries[index].error = "Interrupted"
                }
                self.save()
            }
        }
    }

    // MARK: Queries

    func entry(forVideo videoId: String) -> DownloadEntry? {
        entries.first { $0.video.videoId == videoId }
    }

    func fileURL(_ entry: DownloadEntry) -> URL? {
        guard entry.phase == .done, let name = entry.fileName else { return nil }
        let url = Self.folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// What can be saved: a direct file link. Playlists (HLS) are many small files, not one.
    static func canDownload(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !["m3u8", "m3u", "mpd"].contains(url.pathExtension.lowercased())
    }

    var totalBytes: Int64 { entries.filter { $0.phase == .done }.reduce(0) { $0 + $1.total } }

    // MARK: Actions

    func start(video: VideoRef, url: URL, headers: [String: String], label: String?) {
        if let existing = entry(forVideo: video.videoId) { remove(existing) }
        let entry = DownloadEntry(id: UUID().uuidString, video: video, source: url.absoluteString,
                                  headers: headers, label: label)
        entries.insert(entry, at: 0)
        save()
        launch(entry)
    }

    func retry(_ entry: DownloadEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].phase = .downloading
        entries[index].received = 0
        entries[index].error = nil
        save()
        launch(entries[index])
    }

    func remove(_ entry: DownloadEntry) {
        let id = entry.id
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == id }.forEach { $0.cancel() }
        }
        if let name = entry.fileName {
            try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(name))
        }
        entries.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        entries.forEach(remove)
    }

    private func launch(_ entry: DownloadEntry) {
        guard let url = URL(string: entry.source) else { return }
        var request = URLRequest(url: url)
        for (field, value) in entry.headers { request.setValue(value, forHTTPHeaderField: field) }
        let task = session.downloadTask(with: request)
        task.taskDescription = entry.id
        task.resume()
    }

    private func save() {
        DiskStore.save(entries, Self.key)
    }

    // MARK: Delegate results (hopped to the main actor)

    private func progress(id: String, received: Int64, total: Int64) {
        // A few updates a second are plenty for a progress bar.
        if let last = lastPublish[id], Date().timeIntervalSince(last) < 0.4 { return }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        lastPublish[id] = Date()
        entries[index].received = received
        if total > 0 { entries[index].total = total }
    }

    private func finished(id: String, fileName: String, size: Int64) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            // Removed while it was finishing.
            try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(fileName))
            return
        }
        entries[index].fileName = fileName
        entries[index].phase = .done
        entries[index].received = size
        entries[index].total = size
        entries[index].error = nil
        save()
    }

    private func failed(id: String, message: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].phase != .done else { return }
        entries[index].phase = .failed
        entries[index].error = message
        save()
    }
}

extension DownloadStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor in
            self.progress(id: id, received: totalBytesWritten, total: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let response = downloadTask.response as? HTTPURLResponse
        if let status = response?.statusCode, !(200..<300).contains(status) {
            Task { @MainActor in self.failed(id: id, message: "The server answered \(status)") }
            return
        }
        let mime = (response?.mimeType ?? "").lowercased()
        if mime.contains("mpegurl") || mime.contains("dash+xml") || mime.contains("text/html") {
            Task { @MainActor in
                self.failed(id: id, message: "This stream is a playlist, not a single file, and can't be saved")
            }
            return
        }
        // The temporary file is gone once this method returns, so it is moved right here.
        var ext = (response?.suggestedFilename as NSString?)?.pathExtension.lowercased() ?? ""
        if ext.isEmpty || ext.count > 4 { ext = downloadTask.originalRequest?.url?.pathExtension.lowercased() ?? "" }
        if !["mkv", "mp4", "m4v", "mov", "avi", "ts", "webm"].contains(ext) { ext = "mkv" }
        let fileName = "\(id).\(ext)"
        let target = Self.folder.appendingPathComponent(fileName)
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
            let size = Int64((try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            Task { @MainActor in self.finished(id: id, fileName: fileName, size: size) }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in self.failed(id: id, message: message) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        let message = error.localizedDescription
        Task { @MainActor in self.failed(id: id, message: message) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            Self.backgroundCompletion?()
            Self.backgroundCompletion = nil
        }
    }
}

// MARK: - Views

/// The Downloads list (Links tab).
struct DownloadsSection: View {
    @ObservedObject private var store = DownloadStore.shared
    @EnvironmentObject private var coordinator: PlayerCoordinator

    var body: some View {
        if !store.entries.isEmpty {
            Section {
                ForEach(store.entries) { entry in
                    DownloadRow(entry: entry) { open(entry) }
                        .downloadActions(entry)
                }
            } header: {
                Text("Downloads")
            } footer: {
                Text("\(Self.size(store.totalBytes)) on this \(Device.isPad ? "iPad" : "iPhone"). Swipe left or touch and hold to delete. Downloads continue in the background.")
            }
        }
    }

    private func open(_ entry: DownloadEntry) {
        switch entry.phase {
        case .done:
            if let url = store.fileURL(entry) {
                coordinator.play(DownloadPlayback.item(entry, url: url))
            } else {
                store.retry(entry)
            }
        case .failed: store.retry(entry)
        case .downloading: break
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension View {
    /// Delete (or cancel) a download: a red swipe button, plus the same in a touch-and-hold
    /// menu. The red is set explicitly: the app's white tint otherwise turns the swipe button
    /// white, which made it look broken.
    func downloadActions(_ entry: DownloadEntry) -> some View {
        let title = entry.phase == .downloading ? "Cancel" : "Delete"
        return self
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    withAnimation { DownloadStore.shared.remove(entry) }
                } label: {
                    Label(title, systemImage: entry.phase == .downloading ? "xmark" : "trash")
                }
                .tint(.red)
            }
            .contextMenu {
                if entry.phase == .failed {
                    Button("Retry", systemImage: "arrow.clockwise") { DownloadStore.shared.retry(entry) }
                }
                Button(entry.phase == .downloading ? "Cancel Download" : "Delete Download",
                       systemImage: "trash", role: .destructive) {
                    withAnimation { DownloadStore.shared.remove(entry) }
                }
            }
    }
}

enum DownloadPlayback {
    /// Plays the saved file; progress and watched marks are kept exactly as for the stream.
    static func item(_ entry: DownloadEntry, url: URL, queue: [VideoRef] = []) -> PlayItem {
        PlayItem(url: url, title: entry.video.displayTitle, watch: entry.video, queue: queue,
                 poster: entry.video.poster)
    }
}

struct DownloadRow: View {
    let entry: DownloadEntry
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                LandscapeArtwork(candidates: ArtworkURL.landscapeCandidates(for: entry.video), maxPixel: 300)
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.video.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let episode = entry.video.episodeLabel {
                        Text(episode).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    status
                }
                Spacer(minLength: 0)
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(entry.phase == .failed ? Color.orange : Color.white.opacity(0.85))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        switch entry.phase {
        case .done: return "play.circle.fill"
        case .failed: return "arrow.clockwise.circle.fill"
        case .downloading: return "arrow.down.circle"
        }
    }

    @ViewBuilder
    private var status: some View {
        switch entry.phase {
        case .done:
            Text("Downloaded · \(DownloadsSection.size(entry.total))")
                .font(.caption2).foregroundStyle(.secondary)
        case .failed:
            Text("\(entry.error ?? "Failed") · Tap to retry")
                .font(.caption2).foregroundStyle(.orange).lineLimit(2)
        case .downloading:
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: entry.fraction)
                    .tint(Brand.accent)
                Text(entry.total > 0
                     ? "\(DownloadsSection.size(entry.received)) of \(DownloadsSection.size(entry.total))"
                     : "Starting…")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}
