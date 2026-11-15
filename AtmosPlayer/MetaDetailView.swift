import SwiftUI

/// Title page: full-bleed artwork, Play / Resume, My List, seasons and an episode shelf.
struct MetaDetailView: View {
    let ref: MetaRef
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var coordinator: PlayerCoordinator

    /// Set to open the stream list from the Play button.
    @State private var streamsRoute: StreamsRoute?
    @State private var starting = false

    @State private var meta: StremioMeta?
    @State private var loading = true
    @State private var season: Int = 1
    @State private var expandedDescription = false

    private let heroHeight: CGFloat = 540

    // MARK: Derived data

    private var name: String { meta?.name ?? ref.name }
    private var type: String { meta?.type ?? ref.type }
    private var background: String? { meta?.background ?? ref.background ?? meta?.poster ?? ref.poster }
    private var isSeries: Bool { !(meta?.videos.isEmpty ?? true) || ref.type == "series" }

    /// Every episode in watching order (regular seasons first, specials last), and the season
    /// list. Worked out once when the meta arrives, not on every scroll frame.
    @State private var orderedVideos: [StremioMeta.Video] = []
    @State private var seasons: [Int] = []

    private var episodes: [StremioMeta.Video] {
        seasons.isEmpty ? orderedVideos : orderedVideos.filter { $0.season == season }
    }

    private var movieRef: VideoRef {
        VideoRef(type: type, metaId: ref.id, videoId: meta?.id ?? ref.id, name: name,
                 poster: meta?.poster ?? ref.poster, episodeLabel: nil, background: background)
    }

    private func videoRef(_ video: StremioMeta.Video) -> VideoRef {
        let label = [video.code, video.title].compactMap { $0 }.joined(separator: " · ")
        return VideoRef(type: type, metaId: ref.id, videoId: video.id, name: name,
                        poster: meta?.poster ?? ref.poster,
                        episodeLabel: label.isEmpty ? video.id : label,
                        background: video.thumbnail ?? background)
    }

    private func route(for video: StremioMeta.Video) -> StreamsRoute {
        let following = EpisodeQueue.following(video.id, in: orderedVideos).map { videoRef($0) }
        return StreamsRoute(video: videoRef(video), queue: following)
    }

    /// What the big button plays: the episode you were watching (or the next one after the
    /// last you finished), or the first one. The route is built only when tapped.
    private var primary: (video: StremioMeta.Video?, label: String)? {
        if isSeries {
            if let latest = watch.entries.first(where: { $0.ref.metaId == ref.id }),
               let video = orderedVideos.first(where: { $0.id == latest.ref.videoId }) {
                let verb = latest.position > 0 ? "Resume" : "Play"
                return (video, "\(verb) \(video.code ?? "")".trimmingCharacters(in: .whitespaces))
            }
            guard let first = orderedVideos.first(where: { $0.season != 0 }) ?? orderedVideos.first else { return nil }
            return (first, "Play \(first.code ?? "")".trimmingCharacters(in: .whitespaces))
        }
        let resume = (watch.resumePosition(for: movieRef.videoId) ?? 0) > 0
        return (nil, resume ? "Resume" : "Play")
    }

    private func primaryRoute(_ video: StremioMeta.Video?) -> StreamsRoute {
        if let video { return route(for: video) }
        return StreamsRoute(video: movieRef)
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: 26) {
                    descriptionBlock
                    if isSeries && !orderedVideos.isEmpty {
                        seasonPicker
                        episodeShelf
                    }
                    if loading && meta == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    infoBlock
                }
                .padding(.top, 18)
                .padding(.bottom, 40)
            }
        }
        .scrollIndicators(.hidden)
        .background(Color.black)
        .ignoresSafeArea(edges: .top)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .navigationDestination(item: $streamsRoute) { route in
            StreamsView(video: route.video, queue: route.queue)
        }
    }

    private var hero: some View {
        GeometryReader { geo in
            let minY = geo.frame(in: .scrollView).minY
            let stretch = max(minY, 0)
            ZStack(alignment: .bottom) {
                RemoteImage(url: background, maxPixel: 2000)
                    .frame(width: geo.size.width, height: heroHeight + stretch)
                    .clipped()
                    .offset(y: -stretch)
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.3),
                    .init(color: .black.opacity(0.6), location: 0.62),
                    .init(color: .black, location: 1),
                ], startPoint: .top, endPoint: .bottom)

                VStack(spacing: 14) {
                    TitleArt(logo: meta?.logo ?? ref.logo, name: name, maxHeight: 96)
                        .padding(.horizontal, 44)
                    factsLine
                    actionButtons
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .frame(height: heroHeight)
    }

    private var factsLine: some View {
        let facts: [String] = [
            meta?.releaseInfo,
            meta?.runtime,
            meta?.genres.prefix(2).joined(separator: ", "),
            meta?.imdbRating.map { "IMDb \($0)" },
        ].compactMap { $0 }.filter { !$0.isEmpty }
        return Text(facts.joined(separator: "  ·  "))
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white.opacity(0.75))
            .multilineTextAlignment(.center)
    }

    /// Play like Stremio: the stream used last time starts straight away; otherwise the list opens.
    private func start(_ route: StreamsRoute) async {
        starting = true
        defer { starting = false }
        if let item = await QuickPlay.resolve(video: route.video, queue: route.queue, addons: addons) {
            coordinator.play(item)
        } else {
            streamsRoute = route
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            if let primary {
                Button {
                    Task { await start(primaryRoute(primary.video)) }
                } label: {
                    HStack(spacing: 8) {
                        if starting {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(starting ? "Starting…" : primary.label)
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.black)
                }
                .buttonStyle(CardButtonStyle())
                .disabled(starting)
                .contextMenu {
                    Button("Choose Stream…", systemImage: "list.bullet") { streamsRoute = primaryRoute(primary.video) }
                }
            } else {
                RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.15)).frame(height: 50)
            }

            let saved = favorites.contains(ref.id)
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    favorites.toggle(MetaRef(id: ref.id, type: type, name: name,
                                             poster: meta?.poster ?? ref.poster,
                                             background: background, logo: meta?.logo ?? ref.logo))
                }
            } label: {
                Image(systemName: saved ? "checkmark" : "plus")
                    .font(.headline)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 50, height: 50)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.white)
            }
            .buttonStyle(CardButtonStyle())
            .sensoryFeedback(.success, trigger: saved)
        }
    }

    @ViewBuilder
    private var descriptionBlock: some View {
        if let description = meta?.description, !description.isEmpty {
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(expandedDescription ? nil : 3)
                .padding(.horizontal, 20)
                .onTapGesture { withAnimation(.easeInOut) { expandedDescription.toggle() } }
        }
    }

    private var seasonPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(seasons, id: \.self) { number in
                    Button {
                        withAnimation(.spring(duration: 0.3)) { season = number }
                    } label: {
                        Text(number == 0 ? "Specials" : "Season \(number)")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(season == number ? Color.white : Color.white.opacity(0.12), in: Capsule())
                            .foregroundStyle(season == number ? .black : .white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: season)
    }

    private var episodeShelf: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(episodes) { video in
                    Button { streamsRoute = route(for: video) } label: {
                        EpisodeCard(video: video, progress: progress(for: video))
                    }
                    .buttonStyle(CardButtonStyle())
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .id(season)
        .transition(.opacity)
    }

    @ViewBuilder
    private var infoBlock: some View {
        if let meta {
            VStack(alignment: .leading, spacing: 10) {
                Text("Information").font(.title3.bold()).foregroundStyle(.white)
                if !meta.genres.isEmpty { infoRow("Genres", meta.genres.joined(separator: ", ")) }
                if let released = meta.releaseInfo { infoRow("Released", released) }
                if let runtime = meta.runtime { infoRow("Runtime", runtime) }
                if let rating = meta.imdbRating { infoRow("IMDb", rating) }
                if isSeries { infoRow("Episodes", "\(orderedVideos.count)") }
            }
            .padding(.horizontal, 20)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.white.opacity(0.5)).frame(width: 90, alignment: .leading)
            Text(value).foregroundStyle(.white.opacity(0.85))
        }
        .font(.subheadline)
    }

    private func progress(for video: StremioMeta.Video) -> Double? {
        watch.entries.first { $0.ref.videoId == video.id }?.progress
    }

    private func load() async {
        guard meta == nil else { return }
        loading = true
        defer { loading = false }
        for addon in addons.supporting("meta", type: ref.type, id: ref.id) {
            if let found = try? await StremioClient.meta(addon, type: ref.type, id: ref.id) {
                let ordered = EpisodeQueue.ordered(found.videos)
                var seen: [Int] = []
                for video in ordered {
                    if let s = video.season, !seen.contains(s) { seen.append(s) }
                }
                orderedVideos = ordered
                seasons = seen
                withAnimation(.easeOut(duration: 0.25)) { meta = found }
                break
            }
        }
        // Open on the season you were watching, otherwise the first regular season.
        if let latest = watch.entries.first(where: { $0.ref.metaId == ref.id }),
           let video = orderedVideos.first(where: { $0.id == latest.ref.videoId }),
           let s = video.season {
            season = s
        } else if let first = seasons.first {
            season = first
        }
    }
}

struct EpisodeCard: View {
    let video: StremioMeta.Video
    let progress: Double?
    private let width: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: video.thumbnail, maxPixel: 900, placeholderSymbol: "tv")
                    .frame(width: width, height: width * 9 / 16)
                if let progress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.3))
                            Capsule().fill(.white).frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 4)
                    .padding(10)
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(video.episode.map { "EPISODE \($0)" } ?? "EPISODE")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.5))
            Text(video.title ?? "Episode")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let overview = video.overview {
                Text(overview)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// Episode order and "what comes next", shared by the title page and Continue Watching.
enum EpisodeQueue {
    static func ordered(_ videos: [StremioMeta.Video]) -> [StremioMeta.Video] {
        videos.sorted { a, b in
            let sa = a.season == 0 ? Int.max : (a.season ?? 0)
            let sb = b.season == 0 ? Int.max : (b.season ?? 0)
            if sa != sb { return sa < sb }
            return (a.episode ?? 0) < (b.episode ?? 0)
        }
    }

    /// Up to 40 episodes after `videoId`; specials only follow a special.
    static func following(_ videoId: String, in ordered: [StremioMeta.Video]) -> [StremioMeta.Video] {
        guard let index = ordered.firstIndex(where: { $0.id == videoId }) else { return [] }
        let current = ordered[index]
        return Array(ordered[(index + 1)...]
            .filter { current.season == 0 || $0.season != 0 }
            .prefix(40))
    }

    /// The queue after an episode, fetched from the meta addons (for Continue Watching).
    @MainActor
    static func queue(after video: VideoRef, addons: AddonStore) async -> [VideoRef] {
        guard video.type == "series" else { return [] }
        for addon in addons.supporting("meta", type: video.type, id: video.metaId) {
            guard let meta = try? await StremioClient.meta(addon, type: video.type, id: video.metaId) else { continue }
            let background = meta.background ?? video.background
            return following(video.videoId, in: ordered(meta.videos)).map { episode in
                let label = [episode.code, episode.title].compactMap { $0 }.joined(separator: " · ")
                return VideoRef(type: video.type, metaId: video.metaId, videoId: episode.id, name: video.name,
                                poster: video.poster, episodeLabel: label.isEmpty ? episode.id : label,
                                background: episode.thumbnail ?? background)
            }
        }
        return []
    }
}
