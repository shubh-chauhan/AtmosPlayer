import SwiftUI

/// Title page in the style of the TV app: a full-bleed backdrop that melts into a blurred
/// wash of its own colours, the title's logo, Play and a row of actions, then episodes with
/// ✓ marks, ratings, cast, similar titles and the details Cinemeta has.
struct MetaDetailView: View {
    let ref: MetaRef
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @ObservedObject private var watched = WatchedStore.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.verticalSizeClass) private var verticalSize
    @Environment(\.horizontalSizeClass) private var horizontalSize

    /// Set to open the stream list from the Play button.
    @State private var streamsRoute: StreamsRoute?
    @State private var starting = false

    @State private var meta: StremioMeta?
    @State private var loading = true
    @State private var season: Int = 1
    @State private var expandedDescription = false
    @State private var similar: [MetaPreview] = []
    /// The navigation bar fades in once the backdrop has scrolled away.
    @State private var showBar = false

    /// Every episode in watching order (regular seasons first, specials last), and the season
    /// list. Worked out once when the meta arrives, not on every scroll frame.
    @State private var orderedVideos: [StremioMeta.Video] = []
    @State private var seasons: [Int] = []
    /// Episode ids in the addon's own order: what Stremio's watched field is indexed by.
    @State private var addonVideoIds: [String] = []

    /// Landscape iPhone or iPad: the title block sits on the left over the backdrop.
    private var wide: Bool { verticalSize == .compact || horizontalSize == .regular }
    /// Landscape iPhone: little height, so the title block is compact.
    private var short: Bool { verticalSize == .compact }

    // MARK: Derived data

    private var name: String { meta?.name ?? ref.name }
    private var type: String { meta?.type ?? ref.type }
    private var background: String? { meta?.background ?? ref.background ?? meta?.poster ?? ref.poster }
    private var logo: String? { meta?.logo ?? ref.logo }
    private var isSeries: Bool { !(meta?.videos.isEmpty ?? true) || ref.type == "series" }

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

    private func isWatched(_ id: String) -> Bool { watched.isWatched(id, metaId: ref.id) }

    /// The episode after the last one watched (skipping ones already ✓), or the first.
    private var nextUp: StremioMeta.Video? {
        let regular = orderedVideos.filter { $0.season != 0 }
        let list = regular.isEmpty ? orderedVideos : regular
        guard let last = list.lastIndex(where: { isWatched($0.id) }) else { return list.first }
        return list[(last + 1)...].first { !$0.upcoming && !isWatched($0.id) } ?? list.first
    }

    /// What the big button plays: the episode in Continue Watching, else the next one up.
    private var primary: (video: StremioMeta.Video?, label: String, note: String?)? {
        if isSeries {
            if let latest = watch.entries.first(where: { $0.ref.metaId == ref.id }),
               let video = orderedVideos.first(where: { $0.id == latest.ref.videoId }) {
                let verb = latest.position > 0 ? "Resume" : "Play"
                let note = latest.position > 0 && latest.duration > 0
                    ? "\(video.code ?? "") · \(Self.minutesLeft(latest.duration - latest.position))" : nil
                return (video, "\(verb) \(video.code ?? "")".trimmingCharacters(in: .whitespaces), note)
            }
            guard let next = nextUp else { return nil }
            return (next, "Play \(next.code ?? "")".trimmingCharacters(in: .whitespaces), next.title)
        }
        let position = watch.resumePosition(for: movieRef.videoId) ?? 0
        if position > 0, let entry = watch.entries.first(where: { $0.ref.videoId == movieRef.videoId }) {
            return (nil, "Resume", Self.minutesLeft(entry.duration - entry.position))
        }
        return (nil, "Play", nil)
    }

    private func primaryRoute(_ video: StremioMeta.Video?) -> StreamsRoute {
        if let video { return route(for: video) }
        return StreamsRoute(video: movieRef)
    }

    static func minutesLeft(_ seconds: Double) -> String {
        let minutes = max(Int(seconds / 60), 1)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min left" : "\(minutes) min left"
    }

    // MARK: Body

    var body: some View {
        GeometryReader { outer in
            let heroHeight = heroHeight(for: outer.size)
            // The page runs edge to edge; content keeps clear of the notch in landscape.
            let side = max(outer.safeAreaInsets.leading, outer.safeAreaInsets.trailing)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero(height: heroHeight, side: side)
                    VStack(alignment: .leading, spacing: 30) {
                        if !wide { descriptionBlock }
                        if let meta {
                            RatingsRow(meta: meta)
                        }
                        if isSeries && !orderedVideos.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                seasonPicker
                                episodeShelf
                            }
                        }
                        if loading && meta == nil {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                        if let meta, !(meta.cast.isEmpty && meta.directors.isEmpty && meta.writers.isEmpty) {
                            CastShelf(meta: meta)
                        }
                        if !similar.isEmpty {
                            Shelf(title: "More Like This") {
                                ForEach(similar) { item in
                                    NavigationLink(value: MetaRef(item)) {
                                        PosterCard(title: item.name, subtitle: item.releaseInfo, poster: item.poster)
                                    }
                                    .buttonStyle(CardButtonStyle())
                                }
                            }
                        }
                        aboutBlock
                    }
                    .padding(.top, 22)
                    .padding(.bottom, 44)
                    .padding(.horizontal, side)
                }
            }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y > heroHeight - 150
            } action: { _, past in
                withAnimation(.easeInOut(duration: 0.2)) { showBar = past }
            }
            .background { AmbientBackdrop(url: background) }
            .ignoresSafeArea(edges: [.top, .horizontal])
        }
        .background(Color.black)
        .toolbarBackground(showBar ? .visible : .hidden, for: .navigationBar)
        .navigationTitle(showBar ? name : "")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .task(id: meta?.id) {
            if let meta, similar.isEmpty { similar = await SimilarTitles.find(for: meta) }
        }
        .navigationDestination(item: $streamsRoute) { route in
            StreamsView(video: route.video, queue: route.queue)
        }
    }

    private func heroHeight(for size: CGSize) -> CGFloat {
        if verticalSize == .compact { return max(size.height * 0.96, 320) }   // landscape iPhone
        if horizontalSize == .regular { return min(size.height * 0.72, 760) }  // iPad
        return min(max(size.width * 1.42, 520), 680)
    }

    // MARK: Hero

    private func hero(height: CGFloat, side: CGFloat) -> some View {
        GeometryReader { geo in
            let minY = geo.frame(in: .scrollView).minY
            let stretch = max(minY, 0)
            let lift = max(-minY, 0)
            ZStack(alignment: wide ? .bottomLeading : .bottom) {
                // The backdrop scrolls a little slower than the page and fades into the wash below.
                RemoteImage(url: background, maxPixel: 2000, placeholderSymbol: "")
                    .frame(width: geo.size.width, height: height + stretch)
                    .clipped()
                    .mask(LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: wide ? 0.7 : 0.55),
                        .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom))
                    .offset(y: -stretch + lift * 0.4)

                LinearGradient(stops: [
                    .init(color: .black.opacity(0.35), location: 0),
                    .init(color: .clear, location: 0.2),
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(0.55), location: 0.78),
                    .init(color: .black.opacity(0.45), location: 0.92),
                    // Clear at the very bottom, so the hero runs into the page below without a seam.
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                if wide {
                    LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.45), .clear],
                                   startPoint: .leading, endPoint: UnitPoint(x: 0.75, y: 0.5))
                }

                heroContent
                    .opacity(1 - min(lift / (height * 0.55), 1))
                    .padding(.horizontal, wide ? side + 36 : 20)
                    .padding(.bottom, wide ? 30 : 18)
            }
            .mask(Rectangle().padding(.top, -2000))
        }
        .frame(height: height)
    }

    private var heroContent: some View {
        VStack(alignment: wide ? .leading : .center, spacing: 14) {
            TitleArt(logo: logo, name: name, maxHeight: short ? 64 : wide ? 104 : 100)
                .frame(maxWidth: wide ? 340 : .infinity, maxHeight: short ? 64 : wide ? 104 : 100,
                       alignment: wide ? .leading : .center)
                .padding(.horizontal, wide ? 0 : 36)
            factsLine
            if wide, let description = meta?.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(short ? 2 : 3)
                    .frame(maxWidth: 480, alignment: .leading)
            }
            actionButtons
                .frame(maxWidth: wide ? (short ? 560 : 440) : .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
    }

    private var factsLine: some View {
        var facts: [String] = []
        if let year = meta?.releaseInfo, !year.isEmpty { facts.append(year) }
        if let runtime = meta?.runtime, !runtime.isEmpty { facts.append(runtime) }
        if let genres = meta?.genres, !genres.isEmpty { facts.append(genres.prefix(2).joined(separator: ", ")) }
        if isSeries, seasons.filter({ $0 != 0 }).count > 0 {
            let count = seasons.filter { $0 != 0 }.count
            facts.append(count == 1 ? "1 Season" : "\(count) Seasons")
        }
        return HStack(spacing: 8) {
            if let rating = meta?.imdbRating, !rating.isEmpty {
                HStack(spacing: 4) {
                    Text("IMDb")
                        .font(.system(size: 10, weight: .black))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(Color(red: 0.96, green: 0.77, blue: 0.09), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.black)
                    Text(rating).font(.footnote.weight(.bold).monospacedDigit())
                }
            }
            Text(facts.joined(separator: " · "))
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            if let status = meta?.status, isSeries, status == "Continuing" || status == "Returning Series" {
                Text("NEW EPISODES")
                    .font(.system(size: 9, weight: .heavy))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.6), lineWidth: 1))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .foregroundStyle(.white)
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
        // Landscape iPhone: Play and the actions share one row.
        let layout = short ? AnyLayout(HStackLayout(alignment: .center, spacing: 22))
                           : AnyLayout(VStackLayout(alignment: wide ? .leading : .center, spacing: 16))
        return layout {
            if let primary {
                VStack(spacing: 7) {
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
                        .frame(maxWidth: short ? 220 : .infinity)
                        .frame(height: short ? 46 : 50)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(.black)
                    }
                    .buttonStyle(CardButtonStyle())
                    .disabled(starting)
                    .contextMenu {
                        Button("Choose Stream…", systemImage: "list.bullet") { streamsRoute = primaryRoute(primary.video) }
                    }
                    if let note = primary.note, !note.isEmpty, !short {
                        Text(note)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.15)).frame(height: 50)
            }

            HStack(spacing: wide ? 26 : 0) {
                let saved = favorites.contains(ref.id)
                HeroAction(symbol: saved ? "checkmark" : "plus", label: "My List", wide: wide) {
                    withAnimation(.spring(duration: 0.3)) {
                        favorites.toggle(MetaRef(id: ref.id, type: type, name: name,
                                                 poster: meta?.poster ?? ref.poster,
                                                 background: background, logo: logo))
                    }
                }
                .sensoryFeedback(.success, trigger: saved)

                if let trailer = meta?.trailerId, let url = URL(string: "https://www.youtube.com/watch?v=\(trailer)") {
                    HeroAction(symbol: "play.rectangle", label: "Trailer", wide: wide) { openURL(url) }
                }

                if !isSeries {
                    let done = isWatched(movieRef.videoId)
                    HeroAction(symbol: done ? "checkmark.circle.fill" : "checkmark.circle", label: done ? "Watched" : "Mark Watched",
                               wide: wide) {
                        withAnimation(.snappy) {
                            watched.set([movieRef.videoId], watched: !done, metaId: ref.id, type: "movie", videoIds: nil)
                        }
                    }
                    .sensoryFeedback(.success, trigger: done)
                }

                if let url = shareLink {
                    ShareLink(item: url, subject: Text(name)) {
                        HeroActionLabel(symbol: "square.and.arrow.up", label: "Share", wide: wide)
                    }
                    .buttonStyle(PressScaleButtonStyle(scale: 0.9))
                }
            }
        }
    }

    private var shareLink: URL? {
        if let share = meta?.shareURL, let url = URL(string: share) { return url }
        if ref.id.hasPrefix("tt") { return URL(string: "https://www.imdb.com/title/\(ref.id)/") }
        return nil
    }

    @ViewBuilder
    private var descriptionBlock: some View {
        if let description = meta?.description, !description.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(expandedDescription ? nil : 3)
                if !expandedDescription && description.count > 160 {
                    Text("MORE")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, Device.margin)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut) { expandedDescription.toggle() } }
        }
    }

    // MARK: Episodes

    private var seasonPicker: some View {
        HStack(alignment: .firstTextBaseline) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(seasons, id: \.self) { number in
                        let ids = orderedVideos.filter { $0.season == number }.map(\.id)
                        let complete = !ids.isEmpty && ids.allSatisfy(isWatched)
                        Button {
                            withAnimation(.spring(duration: 0.3)) { season = number }
                        } label: {
                            HStack(spacing: 5) {
                                Text(number == 0 ? "Specials" : "Season \(number)")
                                if complete {
                                    Image(systemName: "checkmark").font(.caption2.weight(.heavy))
                                }
                            }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(season == number ? Color.white : Color.white.opacity(0.12), in: Capsule())
                            .foregroundStyle(season == number ? .black : .white)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if complete {
                                Button("Mark Season as Unwatched", systemImage: "circle") { mark(ids, false) }
                            } else {
                                Button("Mark Season as Watched", systemImage: "checkmark.circle") { mark(ids, true) }
                            }
                        }
                    }
                }
                .padding(.horizontal, Device.margin)
            }
            .scrollIndicators(.hidden)
        }
        .sensoryFeedback(.selection, trigger: season)
    }

    private var episodeShelf: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(episodes) { video in
                    let done = isWatched(video.id)
                    Button { streamsRoute = route(for: video) } label: {
                        EpisodeCard(video: video, progress: progress(for: video), watched: done)
                    }
                    .buttonStyle(CardButtonStyle())
                    .contextMenu {
                        Button("Play", systemImage: "play.fill") { Task { await start(route(for: video)) } }
                        Button("Choose Stream…", systemImage: "list.bullet") { streamsRoute = route(for: video) }
                        Divider()
                        if done {
                            Button("Mark as Unwatched", systemImage: "circle") { mark([video.id], false) }
                        } else {
                            Button("Mark as Watched", systemImage: "checkmark.circle") { mark([video.id], true) }
                            Button("Mark All Up to Here as Watched", systemImage: "checkmark.circle.badge.questionmark") {
                                markThrough(video)
                            }
                        }
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, Device.margin)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .id(season)
        .transition(.opacity)
    }

    private func mark(_ ids: [String], _ on: Bool) {
        withAnimation(.snappy) {
            watched.set(ids, watched: on, metaId: ref.id, type: "series",
                        videoIds: addonVideoIds.isEmpty ? nil : addonVideoIds)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// This episode and every regular episode before it.
    private func markThrough(_ video: StremioMeta.Video) {
        guard let index = orderedVideos.firstIndex(where: { $0.id == video.id }) else { return }
        let ids = orderedVideos[...index].filter { $0.season != 0 || video.season == 0 }.map(\.id)
        mark(ids, true)
    }

    // MARK: About

    @ViewBuilder
    private var aboutBlock: some View {
        if let meta {
            VStack(alignment: .leading, spacing: 16) {
                Text("About").font(.title3.bold()).foregroundStyle(.white)
                if wide, let description = meta.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: 720, alignment: .leading)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: wide ? 220 : 150), spacing: 16, alignment: .topLeading)],
                          alignment: .leading, spacing: 18) {
                    ForEach(aboutFacts(meta), id: \.label) { fact in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(fact.label.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.45))
                            Text(fact.value)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if ref.id.hasPrefix("tt"), let imdb = URL(string: "https://www.imdb.com/title/\(ref.id)/") {
                    Link(destination: imdb) {
                        Label("View on IMDb", systemImage: "arrow.up.right.square")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(0.1), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(.horizontal, Device.margin)
        }
    }

    private struct Fact { let label: String; let value: String }

    private func aboutFacts(_ meta: StremioMeta) -> [Fact] {
        var facts: [Fact] = []
        if let date = meta.releaseDate {
            facts.append(Fact(label: isSeries ? "First aired" : "Released",
                              value: date.formatted(date: .long, time: .omitted)))
        } else if let year = meta.releaseInfo, !year.isEmpty {
            facts.append(Fact(label: "Released", value: year))
        }
        if let runtime = meta.runtime, !runtime.isEmpty {
            facts.append(Fact(label: isSeries ? "Episode length" : "Runtime", value: runtime))
        }
        if isSeries {
            let regular = seasons.filter { $0 != 0 }.count
            if regular > 0 { facts.append(Fact(label: "Seasons", value: "\(regular)")) }
            let aired = orderedVideos.filter { $0.season != 0 && !$0.upcoming }.count
            if aired > 0 { facts.append(Fact(label: "Episodes", value: "\(aired)")) }
            if let status = meta.status, !status.isEmpty { facts.append(Fact(label: "Status", value: status)) }
            if let upcoming = orderedVideos.filter(\.upcoming).compactMap(\.releaseDate).min() {
                facts.append(Fact(label: "Next episode", value: upcoming.formatted(date: .abbreviated, time: .omitted)))
            }
        }
        if !meta.genres.isEmpty { facts.append(Fact(label: "Genres", value: meta.genres.joined(separator: ", "))) }
        if !meta.directors.isEmpty { facts.append(Fact(label: meta.directors.count > 1 ? "Directors" : "Director",
                                                       value: meta.directors.joined(separator: ", "))) }
        if !meta.writers.isEmpty { facts.append(Fact(label: "Writers", value: meta.writers.prefix(4).joined(separator: ", "))) }
        if let country = meta.country, !country.isEmpty { facts.append(Fact(label: "Country", value: country)) }
        if let language = meta.language, !language.isEmpty { facts.append(Fact(label: "Language", value: language)) }
        if let awards = meta.awards, !awards.isEmpty { facts.append(Fact(label: "Awards", value: awards)) }
        return facts
    }

    // MARK: Data

    private func progress(for video: StremioMeta.Video) -> Double? {
        watch.entries.first { $0.ref.videoId == video.id }?.progress
    }

    private func load() async {
        guard meta == nil else { return }
        loading = true
        defer { loading = false }
        var found: StremioMeta?
        // Cinemeta has the richest details for IMDb titles (cast, trailer, ratings, status).
        if ref.id.hasPrefix("tt"), ref.type == "movie" || ref.type == "series" {
            found = await Cinemeta.meta(type: ref.type, id: ref.id)
        }
        if found == nil {
            for addon in addons.supporting("meta", type: ref.type, id: ref.id) {
                if let result = try? await StremioClient.meta(addon, type: ref.type, id: ref.id) {
                    found = result
                    break
                }
            }
        }
        guard let found else { return }
        let ordered = EpisodeQueue.ordered(found.videos)
        var seen: [Int] = []
        for video in ordered {
            if let s = video.season, !seen.contains(s) { seen.append(s) }
        }
        orderedVideos = ordered
        seasons = seen
        addonVideoIds = found.videos.map(\.id)
        if !addonVideoIds.isEmpty { watched.reconcile(metaId: ref.id, videoIds: addonVideoIds) }
        withAnimation(.easeOut(duration: 0.3)) { meta = found }

        // Open on the season you were watching, otherwise the next one up.
        if let latest = watch.entries.first(where: { $0.ref.metaId == ref.id }),
           let video = orderedVideos.first(where: { $0.id == latest.ref.videoId }),
           let s = video.season {
            season = s
        } else if let s = nextUp?.season {
            season = s
        } else if let first = seasons.first {
            season = first
        }
    }
}

// MARK: - Pieces

/// The page's backdrop, blurred into a wash of colour behind everything.
private struct AmbientBackdrop: View {
    let url: String?

    var body: some View {
        ZStack {
            Color.black
            RemoteImage(url: url, maxPixel: 240, placeholderSymbol: "")
                .scaleEffect(1.4)
                .blur(radius: 60)
                .opacity(0.55)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.2), location: 0),
                .init(color: .black.opacity(0.6), location: 0.5),
                .init(color: .black.opacity(0.92), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct HeroAction: View {
    let symbol: String
    let label: String
    let wide: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HeroActionLabel(symbol: symbol, label: label, wide: wide)
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.9))
    }
}

private struct HeroActionLabel: View {
    let symbol: String
    let label: String
    let wide: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 24)
            Text(label)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.9))
        .frame(maxWidth: wide ? nil : .infinity)
        .frame(minWidth: 64)
        .contentShape(Rectangle())
    }
}

struct EpisodeCard: View {
    let video: StremioMeta.Video
    let progress: Double?
    var watched: Bool = false
    private let width: CGFloat = Device.size(280)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: video.thumbnail, maxPixel: 900, placeholderSymbol: "tv")
                    .frame(width: width, height: width * 9 / 16)
                    .opacity(video.upcoming ? 0.45 : 1)
                if let progress, !watched {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.3))
                            Capsule().fill(.white).frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 4)
                    .padding(10)
                }
                if watched {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.black)
                        .frame(width: 24, height: 24)
                        .background(.white, in: Circle())
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.08)))

            Text(caption)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
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

    /// "EPISODE 3 · JAN 21, 2008 · ★ 7.7", or "COMING MAR 3" for one not out yet.
    private var caption: String {
        var parts = [video.episode.map { "EPISODE \($0)" } ?? "EPISODE"]
        if let date = video.releaseDate {
            let text = date.formatted(date: .abbreviated, time: .omitted).uppercased()
            parts.append(video.upcoming ? "COMING \(text)" : text)
        }
        if let rating = video.rating, !video.upcoming { parts.append("★ \(rating)") }
        return parts.joined(separator: " · ")
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
