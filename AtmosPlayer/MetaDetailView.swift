import SwiftUI

struct MetaDetailView: View {
    let ref: MetaRef
    @EnvironmentObject private var addons: AddonStore

    @State private var meta: StremioMeta?
    @State private var loading = true
    @State private var season: Int = 1

    private var seasons: [Int] {
        guard let meta else { return [] }
        let numbers = Set(meta.videos.compactMap(\.season))
        // Specials (season 0) go last.
        return numbers.sorted { a, b in
            if a == 0 { return false }
            if b == 0 { return true }
            return a < b
        }
    }

    private var episodes: [StremioMeta.Video] {
        guard let meta else { return [] }
        if seasons.isEmpty { return meta.videos }
        return meta.videos
            .filter { $0.season == season }
            .sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
    }

    private var isSeries: Bool {
        if let meta, !meta.videos.isEmpty { return true }
        return ref.type == "series"
    }

    var body: some View {
        List {
            Section {
                header
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if loading {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if isSeries && !episodes.isEmpty {
                if seasons.count > 1 {
                    Section {
                        Picker("Season", selection: $season) {
                            ForEach(seasons, id: \.self) { number in
                                Text(number == 0 ? "Specials" : "Season \(number)").tag(number)
                            }
                        }
                    }
                }
                Section("Episodes") {
                    ForEach(episodes) { video in
                        NavigationLink(value: videoRef(for: video)) {
                            EpisodeRow(video: video)
                        }
                    }
                }
            } else {
                Section {
                    NavigationLink(value: movieRef) {
                        Label("Find streams", systemImage: "play.circle.fill")
                            .font(.headline)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(meta?.name ?? ref.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                PosterImage(url: meta?.background ?? meta?.poster ?? ref.poster)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 200)
                Text(meta?.name ?? ref.name)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .padding()
            }
            VStack(alignment: .leading, spacing: 6) {
                let facts = [meta?.releaseInfo, meta?.runtime, meta?.imdbRating.map { "IMDb \($0)" }].compactMap { $0 }
                if !facts.isEmpty {
                    Text(facts.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                }
                if let genres = meta?.genres, !genres.isEmpty {
                    Text(genres.prefix(4).joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
                }
                if let description = meta?.description {
                    Text(description).font(.footnote)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private var movieRef: VideoRef {
        VideoRef(type: meta?.type ?? ref.type, metaId: ref.id, videoId: meta?.id ?? ref.id,
                 name: meta?.name ?? ref.name, poster: meta?.poster ?? ref.poster, episodeLabel: nil)
    }

    private func videoRef(for video: StremioMeta.Video) -> VideoRef {
        let label = [video.code, video.title].compactMap { $0 }.joined(separator: " · ")
        return VideoRef(type: meta?.type ?? ref.type, metaId: ref.id, videoId: video.id,
                        name: meta?.name ?? ref.name, poster: meta?.poster ?? ref.poster,
                        episodeLabel: label.isEmpty ? video.id : label)
    }

    private func load() async {
        guard meta == nil else { return }
        loading = true
        defer { loading = false }
        for addon in addons.supporting("meta", type: ref.type, id: ref.id) {
            if let found = try? await StremioClient.meta(addon, type: ref.type, id: ref.id) {
                meta = found
                break
            }
        }
        // Start on the first regular season.
        if let first = seasons.first { season = first }
    }
}

struct EpisodeRow: View {
    let video: StremioMeta.Video

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterImage(url: video.thumbnail)
                .frame(width: 112, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text([video.code, video.title].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let released = video.released, released.count >= 10 {
                    Text(String(released.prefix(10))).font(.caption2).foregroundStyle(.secondary)
                }
                if let overview = video.overview {
                    Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
