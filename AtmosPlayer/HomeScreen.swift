import SwiftUI

// MARK: - Home

/// A storefront like the TV app and Netflix: a featured hero, Continue Watching, Top 10s,
/// new releases, suggestions, genres. Everything comes from Cinemeta, not from every addon.
struct HomeScreen: View {
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @ObservedObject private var feed = HomeFeed.shared
    @ObservedObject private var calendar = EpisodeCalendar.shared

    @State private var path = NavigationPath()
    @State private var startingId: String?
    @State private var pull = HeroPull()

    private var showsHero: Bool { !feed.hero.isEmpty }

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { outer in
            // Runs edge to edge; rows keep clear of the notch in landscape.
            let side = max(outer.safeAreaInsets.leading, outer.safeAreaInsets.trailing)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if showsHero {
                        HeroCarousel(items: feed.hero, sideInset: side, pull: pull) { open($0) }
                            .padding(.bottom, 26)
                    } else if feed.loading {
                        HomeSkeleton()
                    }
                LazyVStack(alignment: .leading, spacing: 32) {
                    continueWatching

                    if !calendar.fresh.isEmpty {
                        Shelf(title: "New Episodes", spacing: 14) {
                            ForEach(calendar.fresh) { item in
                                NavigationLink(value: item.series) {
                                    CalendarEpisodeCard(item: item, upcoming: false)
                                }
                                .buttonStyle(CardButtonStyle())
                            }
                        }
                    }

                    ForEach(feed.top.prefix(2)) { section in
                        HomeSectionView(section: section)
                    }

                    if !favorites.items.isEmpty {
                        Shelf(title: "My List") {
                            ForEach(favorites.items, id: \.id) { ref in
                                NavigationLink(value: ref) {
                                    PosterCard(title: ref.name, subtitle: nil, poster: ref.poster)
                                }
                                .buttonStyle(CardButtonStyle())
                            }
                        }
                    }

                    ForEach(feed.top.dropFirst(2)) { section in
                        HomeSectionView(section: section)
                    }

                    if let suggestion = feed.suggestion {
                        HomeSectionView(section: suggestion)
                    }

                    if !calendar.upcoming.isEmpty {
                        Shelf(title: "Coming Soon to Your Shows", spacing: 14) {
                            ForEach(calendar.upcoming) { item in
                                NavigationLink(value: item.series) {
                                    CalendarEpisodeCard(item: item, upcoming: true)
                                }
                                .buttonStyle(CardButtonStyle())
                            }
                        }
                    }

                    if !feed.isEmpty {
                        GenreBrowser()
                    }

                    ForEach(feed.rest) { section in
                        HomeSectionView(section: section)
                    }

                    if !account.library.isEmpty {
                        Shelf(title: "From Your Stremio Library") {
                            ForEach(account.library, id: \.id) { ref in
                                NavigationLink(value: ref) {
                                    PosterCard(title: ref.name, subtitle: nil, poster: ref.poster)
                                }
                                .buttonStyle(CardButtonStyle())
                            }
                        }
                    }

                    if feed.isEmpty && !feed.loading {
                        ContentUnavailableView {
                            Label("Home couldn't load", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text("Check your connection and try again.")
                        } actions: {
                            Button("Try Again") { Task { await feed.load(force: true) } }
                                .buttonStyle(.borderedProminent)
                                .tint(Brand.accent)
                        }
                        .padding(.top, 80)
                    }
                }
                .padding(.horizontal, side)
                .padding(.top, showsHero ? 0 : 12)
                }
                .padding(.bottom, 36)
            }
            .background(Color.black)
            .scrollIndicators(.hidden)
            // How far Home is pulled down past its top: the hero's artwork grows into that room
            // instead of leaving black above it.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(-(geometry.contentOffset.y + geometry.contentInsets.top), 0)
            } action: { _, stretch in
                pull.stretch = stretch
            }
            .ignoresSafeArea(edges: showsHero ? [.top, .horizontal] : .horizontal)
            }
            .background(Color.black)
            .navigationTitle("Home")
            .toolbar(showsHero ? .hidden : .visible, for: .navigationBar)
            .modifier(BrowseDestinations())
            .task { await feed.load() }
            .task(id: watch.entries.first?.ref.metaId) {
                await feed.loadSuggestion(from: watch.entries.first)
            }
            // The shows you follow: refreshed when that list changes.
            .task(id: followedKey) {
                await calendar.load(series: followed)
            }
            .task(id: coordinator.pendingResume) {
                guard let id = coordinator.pendingResume else { return }
                coordinator.pendingResume = nil
                if let entry = watch.entries.first(where: { $0.ref.videoId == id }) {
                    path = NavigationPath()
                    await resume(entry.ref)
                }
            }
            .refreshable {
                await account.sync(addons: addons, watch: watch)
                await feed.load(force: true)
            }
            .task {
                // CI screenshots only: open a title page.
                if PreviewMode.screen?.hasPrefix("detail") == true, path.isEmpty {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if PreviewMode.screen == "detail-fallback" {
                        // Listed by Cinemeta search as a series, but only has details as a film.
                        path.append(MetaRef(id: "tt10163430", type: "series", name: "121212", poster: nil))
                    } else {
                        path.append(MetaRef(id: "tt0903747", type: "series", name: "Breaking Bad", poster: nil))
                    }
                }
            }
        }
    }

    /// Series in My List, the Stremio library and Continue Watching.
    private var followed: [MetaRef] {
        let watching = watch.entries.map {
            MetaRef(id: $0.ref.metaId, type: $0.ref.type, name: $0.ref.name, poster: $0.ref.poster,
                    background: $0.ref.background)
        }
        return favorites.items + account.library + watching
    }

    private var followedKey: String {
        followed.filter { $0.type == "series" }.map(\.id).sorted().joined(separator: ",")
    }

    // MARK: Continue Watching

    @ViewBuilder
    private var continueWatching: some View {
        if !watch.entries.isEmpty {
            Shelf(title: "Continue Watching", spacing: 14) {
                ForEach(watch.entries) { entry in
                    ContinueTile(entry: entry, busy: startingId == entry.id) {
                        Task { await resume(entry.ref) }
                    } actions: {
                        continueActions(entry)
                    }
                }
            }
        }
    }

    /// Long-press (or the ••• button) on a Continue Watching tile.
    @ViewBuilder
    private func continueActions(_ entry: WatchStore.Entry) -> some View {
        Button("Resume", systemImage: "play.fill") {
            Task { await resume(entry.ref) }
        }
        Button("Choose Another Stream…", systemImage: "list.bullet.rectangle") {
            Task { await chooseStream(entry.ref) }
        }
        Button("Play from Beginning", systemImage: "backward.end.fill") {
            Task { await resume(entry.ref, startOver: true) }
        }
        Button(entry.ref.type == "series" ? "Go to Series" : "Go to Movie", systemImage: "info.circle") {
            path.append(MetaRef(id: entry.ref.metaId, type: entry.ref.type, name: entry.ref.name,
                                poster: entry.ref.poster))
        }
        Divider()
        Button("Remove from Continue Watching", systemImage: "xmark.circle", role: .destructive) {
            withAnimation(.snappy) { watch.remove(entry.ref.videoId) }
        }
    }

    private func open(_ item: MetaPreview) {
        path.append(MetaRef(item))
    }

    /// Continue Watching resumes with the stream used last time, like Stremio; if there isn't
    /// one, the stream list opens.
    private func resume(_ video: VideoRef, startOver: Bool = false) async {
        guard startingId == nil else { return }
        startingId = video.videoId
        defer { startingId = nil }
        let queue = await EpisodeQueue.queue(after: video, addons: addons)
        if var item = await QuickPlay.resolve(video: video, queue: queue, addons: addons) {
            item.startOver = startOver
            coordinator.play(item)
        } else {
            path.append(StreamsRoute(video: video, queue: queue))
        }
    }

    /// Opens the stream list for this movie / episode, so another stream can be picked.
    private func chooseStream(_ video: VideoRef) async {
        guard startingId == nil else { return }
        startingId = video.videoId
        defer { startingId = nil }
        let queue = await EpisodeQueue.queue(after: video, addons: addons)
        path.append(StreamsRoute(video: video, queue: queue))
    }
}

// MARK: - Sections

struct HomeSectionView: View {
    let section: HomeSection

    var body: some View {
        switch section.style {
        case .ranked:
            Shelf(title: section.title, spacing: 2) {
                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                    NavigationLink(value: MetaRef(item)) {
                        RankedCard(rank: index + 1, item: item)
                    }
                    .buttonStyle(CardButtonStyle())
                }
            }
        case .wide:
            Shelf(title: section.title, seeAll: section.seeAll, spacing: 14) {
                ForEach(section.items) { item in
                    NavigationLink(value: MetaRef(item)) {
                        WideCard(item: item)
                    }
                    .buttonStyle(CardButtonStyle())
                }
            }
        case .poster:
            Shelf(title: section.title, seeAll: section.seeAll) {
                ForEach(section.items) { item in
                    NavigationLink(value: MetaRef(item)) {
                        PosterCard(title: item.name, subtitle: item.releaseInfo, poster: item.poster)
                    }
                    .buttonStyle(CardButtonStyle())
                }
            }
        }
    }
}

/// "1 [poster]" — a Top 10 entry with its big outlined number.
struct RankedCard: View {
    let rank: Int
    let item: MetaPreview

    var body: some View {
        HStack(alignment: .bottom, spacing: rank == 10 ? -30 : -18) {
            RankNumber(rank: rank)
            RemoteImage(url: item.poster, maxPixel: 600)
                .frame(width: Device.size(112), height: Device.size(168))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.08)))
        }
        .padding(.trailing, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Number \(rank), \(item.name)")
    }
}

private struct RankNumber: View {
    let rank: Int

    var body: some View {
        let text = Text("\(rank)").font(.system(size: 118, weight: .black, design: .rounded))
        ZStack {
            // A thin light outline around a dark figure, the classic Top 10 look.
            text.foregroundStyle(.white.opacity(0.55)).offset(x: -1.5)
            text.foregroundStyle(.white.opacity(0.55)).offset(x: 1.5)
            text.foregroundStyle(.white.opacity(0.55)).offset(y: -1.5)
            text.foregroundStyle(.white.opacity(0.55)).offset(y: 1.5)
            text.foregroundStyle(Color(white: 0.06))
        }
        .fixedSize()
        .offset(y: 18)
        .frame(height: 168, alignment: .bottom)
        .clipped()
    }
}

/// A 16:9 backdrop card with the title's logo, for New Releases and acclaimed rows.
struct WideCard: View {
    let item: MetaPreview
    var width: CGFloat = Device.size(280)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: item.background ?? item.poster, maxPixel: 900)
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                if let logo = item.logo, let url = URL(string: logo) {
                    LogoImage(url: url, failed: .constant(false))
                        .frame(maxWidth: width * 0.5, maxHeight: 42, alignment: .bottomLeading)
                        .padding(12)
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.08)))

            Text(item.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(HomeText.facts(item))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
    }
}

enum HomeText {
    /// "Thriller · Drama · 2025 · ★ 7.4"
    static func facts(_ item: MetaPreview, genres: Int = 2) -> String {
        var parts = Array(item.genres.prefix(genres))
        if let year = item.releaseInfo, !year.isEmpty { parts.append(year) }
        if let rating = item.imdbRating, !rating.isEmpty { parts.append("★ \(rating)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Continue Watching tile

struct ContinueTile<Actions: View>: View {
    let entry: WatchStore.Entry
    let busy: Bool
    let onPlay: () -> Void
    @ViewBuilder let actions: () -> Actions

    private let width: CGFloat = Device.size(270)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onPlay) {
                ZStack(alignment: .bottomLeading) {
                    LandscapeArtwork(candidates: ArtworkURL.landscapeCandidates(for: entry.ref), maxPixel: 1000)
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 30, height: 30)
                            .background(.ultraThinMaterial, in: Circle())
                        ProgressBar(progress: entry.progress)
                    }
                    .padding(12)
                    if busy {
                        Color.black.opacity(0.35)
                        ProgressView().controlSize(.large).tint(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: width, height: width * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.08)))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(CardButtonStyle())
            .contextMenu { actions() }

            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.ref.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Menu {
                    actions()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More for \(entry.ref.name)")
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private var subtitle: String {
        let left = max(entry.duration - entry.position, 0)
        let minutes = Int(left / 60)
        let remaining = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min left" : "\(minutes) min left"
        if let label = entry.ref.episodeLabel { return "\(label) · \(remaining)" }
        return remaining
    }
}

private struct ProgressBar: View {
    let progress: Double

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.3))
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule().fill(.white).frame(width: geo.size.width * max(progress, 0.02))
                }
            }
    }
}

// MARK: - Hero

/// How far Home is pulled past its top. A reference the carousel reads, so the pull redraws the
/// hero alone and not every shelf on the page.
@Observable
final class HeroPull {
    var stretch: CGFloat = 0
}

/// The featured carousel at the top of Home: one title at a time, full bleed, moving on by
/// itself with a progress line under the current page (like the TV app). Swiping pauses it.
struct HeroCarousel: View {
    let items: [MetaPreview]
    /// Room for the notch in landscape (the carousel itself runs edge to edge).
    var sideInset: CGFloat = 0
    var pull = HeroPull()
    let onOpen: (MetaPreview) -> Void
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @Environment(\.verticalSizeClass) private var verticalSize
    @Environment(\.horizontalSizeClass) private var horizontalSize
    @Environment(\.scenePhase) private var scenePhase

    @State private var current: String?
    @State private var dragging = false
    /// 0…1: how far the current page's timer has run (drives the indicator).
    @State private var fill: CGFloat = 0
    @State private var cycle = 0
    /// The page whose trailer is showing; it gets longer before moving on.
    @State private var trailerPage: String?
    @State private var timerPage: String?
    /// On screen: not scrolled away, not covered by a pushed page or another tab.
    @State private var onScreen = true
    @State private var appeared = true

    private let interval: Double = 7

    private var wide: Bool { verticalSize == .compact || horizontalSize == .regular }
    private var activeId: String? { current ?? items.first?.id }

    private struct TimerKey: Equatable {
        let page: String?
        let cycle: Int
        let paused: Bool
        let trailer: Bool
    }

    private var trailerShowing: Bool { trailerPage != nil && trailerPage == activeId }
    /// How long a page with its trailer playing stays before the next one.
    private let trailerInterval: Double = 28

    private var paused: Bool {
        dragging || coordinator.current != nil || scenePhase != .active
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { item in
                        HeroCard(item: item, wide: wide, active: item.id == activeId, sideInset: sideInset,
                                 previewing: item.id == activeId && !paused && onScreen && appeared,
                                 stretch: item.id == activeId ? pull.stretch : 0,
                                 onTrailer: { showing in
                                     if showing { trailerPage = item.id }
                                     else if trailerPage == item.id { trailerPage = nil }
                                 }) { onOpen(item) }
                            .frame(width: geo.size.width, height: geo.size.height)
                            .scrollTransition(.interactive, axis: .horizontal) { view, phase in
                                view.opacity(phase.isIdentity ? 1 : 0.55)
                            }
                            .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            // The current page's artwork grows above the carousel on pull-down.
            .scrollClipDisabled()
            .scrollPosition(id: $current)
            // Pages are exactly the screen's width: no extra inset for the notch, which would
            // shift every page sideways in landscape.
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .ignoresSafeArea(edges: .horizontal)
            // After a rotation, land back on the same page.
            .onChange(of: geo.size.width) { _, _ in
                if let id = activeId { proxy.scrollTo(id, anchor: .leading) }
            }
            .onScrollPhaseChange { _, phase in
                let interacting = phase == .interacting || phase == .tracking
                if dragging != interacting {
                    dragging = interacting
                    if !interacting { cycle += 1 }
                }
            }
            .overlay(alignment: wide ? .bottomTrailing : .bottom) {
                indicator
                    .padding(.bottom, wide ? 22 : 12)
                    .padding(.trailing, wide ? sideInset + 28 : 0)
            }
            }
        }
        .modifier(HeroSize(wide: wide, landscape: verticalSize == .compact))
        .onScrollVisibilityChange(threshold: 0.35) { onScreen = $0 }
        .onAppear { appeared = true }
        .onDisappear { appeared = false }
        // A page that was removed (its artwork never loaded) hands over to the first one.
        .onChange(of: items.map(\.id)) { _, ids in
            if let current, !ids.contains(current) { self.current = nil }
        }
        // Auto-advance. Restarts when the page changes, after a swipe, and pauses while
        // playing or in the background.
        .task(id: TimerKey(page: activeId, cycle: cycle, paused: paused, trailer: trailerShowing)) {
            // The trailer starting on this page only stretches the time left: the indicator
            // carries on from where it is instead of jumping back.
            let stretch = trailerShowing && timerPage == activeId && !paused
            timerPage = activeId
            if !stretch {
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { fill = 0 }
            }
            // The CI trailer screenshot stays on one page so its trailer has time to start.
            guard !paused, !TrailerPreviews.diagnosing, items.count > 1 else { return }
            if !stretch {
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard !Task.isCancelled else { return }
            }
            let duration = trailerShowing ? trailerInterval : interval
            withAnimation(.linear(duration: duration)) { fill = 1 }
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let index = items.firstIndex { $0.id == activeId } ?? 0
            withAnimation(.smooth(duration: 0.85)) { current = items[(index + 1) % items.count].id }
        }
    }

    private var indicator: some View {
        HStack(spacing: 6) {
            ForEach(items) { item in
                let on = item.id == activeId
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(width: on ? 26 : 6, height: 6)
                    .overlay(alignment: .leading) {
                        if on {
                            Capsule().fill(.white).frame(width: max(6, 26 * fill))
                        }
                    }
                    .clipShape(Capsule())
            }
        }
        .animation(.spring(duration: 0.35), value: activeId)
        .accessibilityHidden(true)
    }
}

/// Portrait iPhone: a tall poster-like card. Landscape / iPad: nearly the whole screen.
private struct HeroSize: ViewModifier {
    let wide: Bool
    let landscape: Bool

    func body(content: Content) -> some View {
        if wide {
            content.containerRelativeFrame(.vertical) { height, _ in
                landscape ? height * 0.94 : height * 0.68
            }
        } else {
            content.aspectRatio(0.72, contentMode: .fit)
        }
    }
}

struct HeroCard: View {
    let item: MetaPreview
    var wide = false
    var active = true
    var sideInset: CGFloat = 0
    /// Rested on and visible: its trailer may play.
    var previewing = false
    /// Points Home is pulled down past its top; the artwork scales up from the bottom to fill it.
    var stretch: CGFloat = 0
    var onTrailer: (Bool) -> Void = { _ in }
    let onOpen: () -> Void
    @EnvironmentObject private var favorites: FavoritesStore
    @Environment(\.verticalSizeClass) private var verticalSize
    /// Landscape iPhone: little height, so a smaller logo and shorter synopsis.
    private var short: Bool { verticalSize == .compact }

    var body: some View {
        ZStack(alignment: wide ? .bottomLeading : .bottom) {
            // Artwork, trailer and their shading move as one picture: on pull-down it scales up
            // from the bottom edge (a transform, so the trailer never re-lays out mid-gesture).
            ZStack {
                // A slow push-in on the page you're looking at.
                Color.clear
                    .overlay {
                        RemoteImage(url: item.background ?? item.poster, maxPixel: 1800, placeholderSymbol: "")
                            .scaleEffect(active ? 1.07 : 1, anchor: wide ? .center : .top)
                            .animation(active ? .linear(duration: 14) : .easeOut(duration: 0.4), value: active)
                    }
                    .overlay {
                        TrailerBackdrop(youtubeId: item.trailerId, active: previewing, onShowing: onTrailer)
                    }
                    .clipped()

                LinearGradient(stops: [
                    .init(color: .black.opacity(0.45), location: 0),
                    .init(color: .clear, location: 0.18),
                    .init(color: .clear, location: wide ? 0.5 : 0.38),
                    .init(color: .black.opacity(0.65), location: wide ? 0.82 : 0.66),
                    .init(color: .black, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                if wide {
                    LinearGradient(colors: [.black.opacity(0.8), .black.opacity(0.35), .clear],
                                   startPoint: .leading, endPoint: UnitPoint(x: 0.7, y: 0.5))
                }
            }
            .visualEffect { [stretch] content, proxy in
                content.scaleEffect((proxy.size.height + stretch) / max(proxy.size.height, 1), anchor: .bottom)
            }

            content
                .padding(.horizontal, wide ? sideInset + 40 : 0)
                .padding(.bottom, short ? 40 : wide ? 48 : 36)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    private var content: some View {
        VStack(alignment: wide ? .leading : .center, spacing: 12) {
            TitleArt(logo: item.logo, name: item.name, maxHeight: short ? 68 : wide ? 92 : 100)
                .frame(maxWidth: wide ? 320 : .infinity, maxHeight: short ? 68 : wide ? 92 : 100,
                       alignment: wide ? .leading : .center)
                .padding(.horizontal, wide ? 0 : 48)
            let facts = HomeText.facts(item, genres: 2)
            if !facts.isEmpty {
                Text(facts)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            if let description = item.description, !description.isEmpty {
                Text(description)
                    .font(wide ? .subheadline : .footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(wide && !short ? 3 : 2)
                    .multilineTextAlignment(wide ? .leading : .center)
                    .frame(maxWidth: wide ? 440 : .infinity, alignment: wide ? .leading : .center)
                    .padding(.horizontal, wide ? 0 : 36)
            }
            HStack(spacing: 12) {
                Button(action: onOpen) {
                    Label("Watch Now", systemImage: "play.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: wide ? 200 : 230)
                        .padding(.vertical, 13)
                        .padding(.horizontal, wide ? 22 : 0)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                }
                let inList = favorites.contains(item.id)
                Button {
                    withAnimation(.snappy) { favorites.toggle(MetaRef(item)) }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: inList ? "checkmark" : "plus")
                        .font(.headline)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 46, height: 46)
                        .glass(Circle(), interactive: true)
                }
                .accessibilityLabel(inList ? "Remove from My List" : "Add to My List")
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.95))
            .foregroundStyle(.white)
            .padding(.horizontal, wide ? 0 : 32)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
    }
}

/// Grey shapes while the very first Home loads (later launches show the saved one instantly).
private struct HomeSkeleton: View {
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .aspectRatio(0.74, contentMode: .fit)
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08))
                        .frame(width: 160, height: 18)
                    HStack(spacing: 12) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06))
                                .frame(width: Device.size(124), height: Device.size(186))
                        }
                    }
                }
                .padding(.horizontal, Device.margin)
            }
        }
        .opacity(pulse ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .ignoresSafeArea(edges: .top)
    }
}

// MARK: - Genres

struct GenreBrowser: View {
    private struct Genre: Identifiable {
        let name: String
        let symbol: String
        let colors: [Color]
        var id: String { name }
    }

    private let genres: [Genre] = [
        Genre(name: "Action", symbol: "flame.fill", colors: [Color(red: 0.85, green: 0.2, blue: 0.15), Color(red: 0.95, green: 0.55, blue: 0.1)]),
        Genre(name: "Comedy", symbol: "face.smiling.inverse", colors: [Color(red: 0.95, green: 0.7, blue: 0.1), Color(red: 0.95, green: 0.45, blue: 0.2)]),
        Genre(name: "Drama", symbol: "theatermasks.fill", colors: [Color(red: 0.45, green: 0.2, blue: 0.7), Color(red: 0.75, green: 0.3, blue: 0.6)]),
        Genre(name: "Sci-Fi", symbol: "sparkles", colors: [Color(red: 0.1, green: 0.35, blue: 0.85), Color(red: 0.2, green: 0.8, blue: 0.9)]),
        Genre(name: "Thriller", symbol: "eye.fill", colors: [Color(red: 0.15, green: 0.3, blue: 0.35), Color(red: 0.2, green: 0.55, blue: 0.5)]),
        Genre(name: "Crime", symbol: "magnifyingglass", colors: [Color(red: 0.25, green: 0.27, blue: 0.35), Color(red: 0.5, green: 0.5, blue: 0.6)]),
        Genre(name: "Horror", symbol: "moon.fill", colors: [Color(red: 0.35, green: 0.02, blue: 0.05), Color(red: 0.6, green: 0.1, blue: 0.15)]),
        Genre(name: "Romance", symbol: "heart.fill", colors: [Color(red: 0.9, green: 0.3, blue: 0.5), Color(red: 0.95, green: 0.55, blue: 0.6)]),
        Genre(name: "Animation", symbol: "wand.and.stars", colors: [Color(red: 0.1, green: 0.65, blue: 0.5), Color(red: 0.4, green: 0.85, blue: 0.4)]),
        Genre(name: "Adventure", symbol: "map.fill", colors: [Color(red: 0.6, green: 0.45, blue: 0.2), Color(red: 0.85, green: 0.7, blue: 0.35)]),
        Genre(name: "Fantasy", symbol: "crown.fill", colors: [Color(red: 0.4, green: 0.25, blue: 0.75), Color(red: 0.85, green: 0.6, blue: 0.95)]),
        Genre(name: "Mystery", symbol: "questionmark.circle.fill", colors: [Color(red: 0.2, green: 0.2, blue: 0.45), Color(red: 0.35, green: 0.4, blue: 0.7)]),
        Genre(name: "Family", symbol: "figure.2.and.child.holdinghands", colors: [Color(red: 0.2, green: 0.6, blue: 0.9), Color(red: 0.5, green: 0.85, blue: 0.95)]),
        Genre(name: "Documentary", symbol: "globe.americas.fill", colors: [Color(red: 0.15, green: 0.45, blue: 0.25), Color(red: 0.4, green: 0.7, blue: 0.4)]),
        Genre(name: "History", symbol: "building.columns.fill", colors: [Color(red: 0.5, green: 0.35, blue: 0.25), Color(red: 0.75, green: 0.6, blue: 0.45)]),
        Genre(name: "War", symbol: "shield.fill", colors: [Color(red: 0.3, green: 0.35, blue: 0.2), Color(red: 0.5, green: 0.55, blue: 0.35)]),
        Genre(name: "Sport", symbol: "sportscourt.fill", colors: [Color(red: 0.1, green: 0.5, blue: 0.3), Color(red: 0.2, green: 0.75, blue: 0.55)]),
        Genre(name: "Western", symbol: "sun.max.fill", colors: [Color(red: 0.7, green: 0.35, blue: 0.1), Color(red: 0.9, green: 0.65, blue: 0.3)]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Browse by Genre")
                .font(.title3.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, Device.margin)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(genres) { genre in
                        NavigationLink(value: CatalogRoute(title: genre.name, type: "movie", catalogId: "top",
                                                           genre: genre.name, allowsTypeSwitch: true)) {
                            tile(genre)
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, Device.margin)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }

    private func tile(_ genre: Genre) -> some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: genre.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: genre.symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white.opacity(0.22))
                .rotationEffect(.degrees(-12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 6)
                .padding(.trailing, 4)
            Text(genre.name)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .padding(12)
        }
        .frame(width: 150, height: 86)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Full catalog page

/// "See All" and genre pages: a poster grid that keeps loading as you scroll.
struct CatalogGridScreen: View {
    let route: CatalogRoute
    @State private var type: String
    /// Cinemeta's "top" (popular now) or "imdbRating" (best rated) list for the same genre.
    @State private var catalog: String
    @State private var items: [MetaPreview] = []
    @State private var loading = false
    @State private var exhausted = false

    private let columns = [GridItem(.adaptive(minimum: Device.size(104)), spacing: Device.isPad ? 18 : 12)]

    init(route: CatalogRoute) {
        self.route = route
        _type = State(initialValue: route.type)
        _catalog = State(initialValue: route.catalogId)
    }

    private struct LoadKey: Equatable {
        let type: String
        let catalog: String
    }

    /// Genre pages can sort by popularity or rating; "New" and year lists cannot.
    private var sortable: Bool { route.catalogId == "top" || route.catalogId == "imdbRating" }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if route.allowsTypeSwitch {
                    Picker("Type", selection: $type) {
                        Text("Movies").tag("movie")
                        Text("Series").tag("series")
                    }
                    .pickerStyle(.segmented)
                }
                if sortable {
                    Picker("Sort", selection: $catalog) {
                        Text("Popular").tag("top")
                        Text("Top Rated").tag("imdbRating")
                    }
                    .pickerStyle(.segmented)
                }
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(items) { item in
                        NavigationLink(value: MetaRef(item)) {
                            PosterCard(title: item.name, subtitle: item.releaseInfo, poster: item.poster, width: Device.size(104))
                        }
                        .buttonStyle(CardButtonStyle())
                        .onAppear {
                            if item.id == items.last?.id { Task { await loadMore() } }
                        }
                    }
                }
                if loading {
                    ProgressView().padding(.vertical, 20)
                } else if items.isEmpty && exhausted {
                    ContentUnavailableView("Nothing here", systemImage: "film.stack")
                        .padding(.top, 60)
                }
            }
            .padding(.horizontal, Device.margin)
            .padding(.bottom, 30)
        }
        .background(Color.black)
        .scrollIndicators(.hidden)
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.large)
        .task(id: LoadKey(type: type, catalog: catalog)) {
            items = []
            exhausted = false
            await loadMore()
        }
    }

    private func loadMore() async {
        guard !loading, !exhausted else { return }
        loading = true
        defer { loading = false }
        let wanted = type
        let list = catalog
        let page = await Cinemeta.catalog(type: wanted, id: list, genre: route.genre, skip: items.count)
        guard wanted == type, list == catalog else { return }
        let known = Set(items.map(\.id))
        let fresh = page.filter { !known.contains($0.id) && $0.poster != nil }
        if fresh.isEmpty { exhausted = true }
        items.append(contentsOf: fresh)
    }
}
