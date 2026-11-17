import SwiftUI
import UIKit

/// Every stream the installed addons return for one movie or episode.
struct StreamsView: View {
    let video: VideoRef
    var queue: [VideoRef] = []
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @EnvironmentObject private var watch: WatchStore
    @ObservedObject private var downloads = DownloadStore.shared

    private struct AddonResult: Identifiable {
        let id: String
        let name: String
        let streams: [StremioStream]
        let error: String?
    }

    @State private var results: [AddonResult] = []
    @State private var loading = true
    @AppStorage(StreamFilterStore.key) private var savedFilters = ""
    @AppStorage("streams.sort") private var sort: StreamSort = .addon

    /// Selected chips, kept between titles like Stremio's filters.
    private var selectedFilters: Binding<Set<StreamFilter>> {
        Binding(get: { StreamFilterStore.decode(savedFilters) },
                set: { savedFilters = StreamFilterStore.encode($0) })
    }

    /// How many loaded streams carry each value, for the chips.
    private var available: [StreamFilter: Int] {
        var counts: [StreamFilter: Int] = [:]
        for result in results {
            for stream in result.streams {
                for value in stream.traits.all { counts[value, default: 0] += 1 }
            }
        }
        return counts
    }

    private var totalCount: Int { results.reduce(0) { $0 + $1.streams.count } }

    private func visible(_ result: AddonResult) -> [StremioStream] {
        let selected = StreamFilterStore.decode(savedFilters)
        var list = result.streams.filter { StreamFilter.matches($0.traits, selected: selected) }
        switch sort {
        case .addon: break
        case .quality:
            list = list.enumerated().sorted {
                ($0.element.traits.qualityScore, -$0.offset) > ($1.element.traits.qualityScore, -$1.offset)
            }.map(\.element)
        case .size:
            list = list.enumerated().sorted {
                ($0.element.traits.sizeGB ?? -1, -$0.offset) > ($1.element.traits.sizeGB ?? -1, -$1.offset)
            }.map(\.element)
        case .sizeSmall:
            list = list.enumerated().sorted {
                ($0.element.traits.sizeGB ?? .infinity, $0.offset) < ($1.element.traits.sizeGB ?? .infinity, $1.offset)
            }.map(\.element)
        }
        // The stream played last time goes first, marked, as in Stremio.
        return list.filter { isLast($0, addonId: result.id) } + list.filter { !isLast($0, addonId: result.id) }
    }

    private var sources: [InstalledAddon] {
        addons.supporting("stream", type: video.type, id: video.videoId)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    LandscapeArtwork(candidates: ArtworkURL.landscapeCandidates(for: video), maxPixel: 400)
                        .frame(width: 120, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(video.name).font(.headline).lineLimit(2)
                        if let label = video.episodeLabel {
                            Text(label).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if let resume = watch.resumePosition(for: video.videoId) {
                            Label("Resumes at \(formatTime(resume))", systemImage: "clock.arrow.circlepath")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }

            if let saved = downloads.entry(forVideo: video.videoId) {
                Section("On this \(Device.isPad ? "iPad" : "iPhone")") {
                    DownloadRow(entry: saved) {
                        if let url = downloads.fileURL(saved) {
                            coordinator.play(DownloadPlayback.item(saved, url: url, queue: queue))
                        } else if saved.phase == .failed {
                            downloads.retry(saved)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) { downloads.remove(saved) }
                    }
                }
            }

            if totalCount > 0 || !savedFilters.isEmpty {
                Section {
                    StreamFilterBar(available: available, selected: selectedFilters, sort: $sort,
                                    shownCount: results.reduce(0) { $0 + visible($1).count },
                                    totalCount: totalCount)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            if sources.isEmpty {
                Section {
                    Text("None of your addons provides streams for this. Add your stream addon in the Addons tab.")
                        .font(.footnote)
                }
            }

            ForEach(results) { result in
                Section(result.name) {
                    if let error = result.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    } else {
                        let shown = visible(result)
                        if shown.isEmpty {
                            Text(result.streams.isEmpty ? "No streams." : "No streams match the filters.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(shown) { stream in
                            StreamRow(stream: stream, isLast: isLast(stream, addonId: result.id),
                                      onDownload: DownloadStore.canDownload(stream.playableURL) ? { download(stream) } : nil) {
                                play(stream, from: result.id)
                            }
                        }
                    }
                }
            }

            if loading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Text("Asking \(sources.count) addon\(sources.count == 1 ? "" : "s")…")
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
        .readableWidth()
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Choose a Stream")
        .navigationBarTitleDisplayMode(.inline)
        .task { if results.isEmpty { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let list = sources
        results = []
        await withTaskGroup(of: (Int, AddonResult).self) { group in
            for (index, addon) in list.enumerated() {
                group.addTask {
                    do {
                        let streams = try await StremioClient.streams(addon, type: video.type, id: video.videoId)
                        return (index, AddonResult(id: addon.id, name: addon.manifest.name, streams: streams, error: nil))
                    } catch {
                        return (index, AddonResult(id: addon.id, name: addon.manifest.name, streams: [],
                                                   error: error.localizedDescription))
                    }
                }
            }
            // Show each addon's answer as soon as it arrives, kept in addon order.
            var arrived: [(Int, AddonResult)] = []
            for await item in group {
                arrived.append(item)
                let ordered = arrived.sorted { $0.0 < $1.0 }.map { $0.1 }
                withAnimation(.easeOut(duration: 0.2)) { results = ordered }
            }
        }
    }

    private var lastStream: SavedStream? { LastStreamStore.shared.stream(forTitle: video.metaId) }

    private func isLast(_ stream: StremioStream, addonId: String) -> Bool {
        guard let lastStream, lastStream.addonId == addonId, lastStream.videoId == video.videoId else { return false }
        return lastStream.matches(stream)
    }

    private func download(_ stream: StremioStream) {
        guard let url = stream.playableURL else { return }
        downloads.start(video: video, url: url, headers: stream.requestHeaders,
                        label: stream.name ?? stream.title)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func play(_ stream: StremioStream, from addonId: String) {
        let saved = SavedStream(stream, addonId: addonId, videoId: video.videoId)
        if let item = QuickPlay.item(video: video, queue: queue, stream: saved) {
            coordinator.play(item)
        }
    }
}

struct StreamRow: View {
    let stream: StremioStream
    var isLast = false
    /// Saves the stream for offline; nil when it can't be saved (a playlist, or no link).
    var onDownload: (() -> Void)? = nil
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: stream.playableURL == nil ? "nosign" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(stream.playableURL == nil ? Color.secondary : Color.white)
                VStack(alignment: .leading, spacing: 5) {
                    if isLast {
                        Label("Last played", systemImage: "clock.arrow.circlepath")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Brand.accent)
                    }
                    if !stream.badges.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(stream.badges, id: \.self) { badge in
                                Text(badge)
                                    .font(.caption2.weight(.heavy))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(badge == "Atmos" || badge == "DV" ? Color.white : Color.white.opacity(0.15),
                                                in: RoundedRectangle(cornerRadius: 4))
                                    .foregroundStyle(badge == "Atmos" || badge == "DV" ? Color.black : Color.white)
                            }
                        }
                    }
                    if let name = stream.name {
                        Text(name).font(.subheadline.weight(.semibold))
                    }
                    if let detail = stream.title ?? stream.description {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    if stream.playableURL == nil {
                        Text(stream.unplayableReason).font(.caption2).foregroundStyle(.orange)
                    } else if stream.isTorrent {
                        Label("Torrent · via your streaming server", systemImage: "server.rack")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(stream.playableURL == nil)
        .contextMenu {
            if let onDownload {
                Button("Download", systemImage: "arrow.down.circle") { onDownload() }
            }
            if let url = stream.playableURL {
                Button("Copy Link", systemImage: "doc.on.doc") { UIPasteboard.general.string = url.absoluteString }
            }
        }
        .swipeActions(edge: .trailing) {
            if let onDownload {
                Button("Download", systemImage: "arrow.down.circle") { onDownload() }
                    .tint(Brand.accent)
            }
        }
    }
}
