import SwiftUI
import UIKit

struct StreamsView: View {
    let video: VideoRef
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @EnvironmentObject private var watch: WatchStore

    private struct AddonResult: Identifiable {
        let id: String
        let name: String
        let streams: [StremioStream]
        let error: String?
    }

    @State private var results: [AddonResult] = []
    @State private var loading = true
    @State private var atmosOnly = false

    private var sources: [InstalledAddon] {
        addons.supporting("stream", type: video.type, id: video.videoId)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.name).font(.headline)
                    if let label = video.episodeLabel {
                        Text(label).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let resume = watch.resumePosition(for: video.videoId) {
                        Text("Resumes at \(formatTime(resume))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Only streams labelled Atmos", isOn: $atmosOnly)
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
                        let shown = result.streams.filter { !atmosOnly || $0.badges.contains("Atmos") }
                        if shown.isEmpty {
                            Text(atmosOnly ? "No streams labelled Atmos." : "No streams.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(shown) { stream in
                            StreamRow(stream: stream) { play(stream) }
                        }
                    }
                }
            }

            if loading {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("Streams")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
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
                results = arrived.sorted { $0.0 < $1.0 }.map { $0.1 }
            }
        }
    }

    private func play(_ stream: StremioStream) {
        guard let url = stream.playableURL else { return }
        coordinator.play(PlayItem(url: url, title: video.displayTitle,
                                  headers: stream.requestHeaders, watch: video))
    }
}

struct StreamRow: View {
    let stream: StremioStream
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 4) {
                if !stream.badges.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(stream.badges, id: \.self) { badge in
                            Text(badge)
                                .font(.caption2.bold())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(badge == "Atmos" ? Color.accentColor : Color.gray.opacity(0.35),
                                            in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.white)
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
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(stream.playableURL == nil)
        .contextMenu {
            if let url = stream.playableURL {
                Button("Copy link") { UIPasteboard.general.string = url.absoluteString }
            }
        }
    }
}
