import SwiftUI

struct CatalogRow: Identifiable {
    let id: String
    let title: String
    let items: [MetaPreview]
    /// Where "See All" pages from (an addon's catalog), if anywhere.
    var source: CatalogSource? = nil
}

/// Loads the browsable catalog rows of every installed addon, in addon order.
enum CatalogLoader {
    /// `excludingCinemeta`: Discover already has Cinemeta's lists (Home, genres, Popular).
    static func rows(_ addons: [InstalledAddon], excludingCinemeta: Bool = false) async -> [CatalogRow] {
        var jobs: [(String, String, InstalledAddon, StremioCatalog)] = []
        let shown = excludingCinemeta ? addons.filter { !$0.transportURL.contains("cinemeta") } : addons
        let showAddonName = shown.filter { !$0.manifest.catalogs.isEmpty }.count > 1
        for addon in shown {
            for catalog in addon.manifest.catalogs where catalog.isBrowsable {
                let name = catalog.name ?? catalog.id
                var title = "\(name) \(typeLabel(catalog.type))"
                if showAddonName { title += " · \(addon.manifest.name)" }
                jobs.append(("\(addon.id)/\(catalog.type)/\(catalog.id)", title, addon, catalog))
            }
        }
        return await withTaskGroup(of: (Int, CatalogRow?).self) { group in
            for (index, job) in jobs.enumerated() {
                group.addTask {
                    // A down or slow addon just leaves its rows out.
                    let items = (try? await StremioClient.catalog(job.2, job.3, timeout: 12)) ?? []
                    let source = CatalogSource.addon(addonId: job.2.id, type: job.3.type, catalog: job.3.id, genre: nil)
                    return (index, items.isEmpty ? nil : CatalogRow(id: job.0, title: job.1, items: items, source: source))
                }
            }
            var collected: [(Int, CatalogRow)] = []
            for await (index, row) in group {
                if let row { collected.append((index, row)) }
            }
            return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    static func typeLabel(_ type: String) -> String {
        switch type {
        case "movie": return "Movies"
        case "series": return "Series"
        case "tv": return "TV"
        default: return type.capitalized
        }
    }
}

/// Navigation targets shared by every browsing stack.
struct BrowseDestinations: ViewModifier {
    /// The stack's zoom namespace: title pages zoom out of the card tapped, and the pages
    /// pushed after them zoom from their own cards too.
    var zoom: Namespace.ID? = nil

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: MetaRef.self) { ref in
                MetaDetailView(ref: ref)
                    .modifier(ZoomDestination(id: ref.id, namespace: zoom))
                    .environment(\.zoomNamespace, zoom)
            }
            .navigationDestination(for: StreamsRoute.self) { route in
                StreamsView(video: route.video, queue: route.queue, startOver: route.startOver)
            }
            .navigationDestination(for: CatalogRoute.self) { route in
                CatalogGridScreen(route: route)
                    .environment(\.zoomNamespace, zoom)
            }
            .navigationDestination(for: PersonRoute.self) { route in
                PersonScreen(route: route)
                    .environment(\.zoomNamespace, zoom)
            }
    }
}

/// The title's logo artwork when the addon has one, otherwise its name in big type.
struct TitleArt: View {
    let logo: String?
    let name: String
    var maxHeight: CGFloat = 80

    @State private var logoFailed = false

    var body: some View {
        content.onChange(of: logo) { _, _ in logoFailed = false }
    }

    @ViewBuilder
    private var content: some View {
        if let logo, !logoFailed, let url = URL(string: logo) {
            LogoImage(url: url, failed: $logoFailed)
                .frame(maxHeight: maxHeight)
        } else {
            Text(name)
                .font(.system(size: 30, weight: .heavy))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
        }
    }
}

struct LogoImage: View {
    let url: URL
    @Binding var failed: Bool
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            if let hit = ImagePipeline.shared.cached(url, maxPixel: 800) {
                image = hit
                return
            }
            let loaded = await ImagePipeline.shared.image(url, maxPixel: 800)
            guard !Task.isCancelled else { return }
            if loaded == nil { failed = true } else { withAnimation { image = loaded } }
        }
    }
}

// MARK: - Shelves and cards

struct Shelf<Content: View>: View {
    let title: String
    /// Shown as "Title ›", opening the full catalog.
    var seeAll: CatalogRoute? = nil
    var spacing: CGFloat = 12
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let seeAll {
                    NavigationLink(value: seeAll) {
                        HStack(spacing: 4) {
                            Text(title)
                            Image(systemName: "chevron.right")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(title)
                }
            }
            .font(.title3.bold())
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, Device.margin)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: spacing) {
                    content()
                }
                .scrollTargetLayout()
                .padding(.horizontal, Device.margin)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }
}

/// Cards sink slightly and dim a touch while pressed, then spring back, the way storefront cards do.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Zoom into title pages

/// The namespace a stack's title pages zoom out of (set on each browsing stack).
private struct ZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
}

/// Titles to open with a plain push: the hero has no card to zoom out of.
enum ZoomTap {
    nonisolated(unsafe) static var plain: Set<String> = []
}

/// A card a title page grows out of when it opens, and shrinks back into when you go back.
/// No gesture of its own: on iOS 18 a tap gesture inside a link's label swallows the link's tap.
struct ZoomSource: ViewModifier {
    let id: String
    @Environment(\.zoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            // shortcut: a title shown twice on one screen (My List and a row) zooms from either.
            content.matchedTransitionSource(id: id, in: namespace) { source in
                source.clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        } else {
            content
        }
    }
}

/// A title page that opens by zooming out of its card; from the hero, a plain push.
struct ZoomDestination: ViewModifier {
    let id: String
    let namespace: Namespace.ID?
    /// Decided when the page is made, so it stays the same for the page's whole life.
    @State private var zooms: Bool

    init(id: String, namespace: Namespace.ID?) {
        self.id = id
        self.namespace = namespace
        _zooms = State(initialValue: ZoomTap.plain.remove(id) == nil)
    }

    func body(content: Content) -> some View {
        if let namespace, zooms {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

struct PosterCard: View {
    let title: String
    let subtitle: String?
    let poster: String?
    /// The title's id and type: other places to find its poster when this one doesn't load.
    var id: String?
    var type: String = "movie"
    var width: CGFloat = Device.size(124)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(candidates: ArtworkURL.posters(id: id, poster: poster),
                        lookup: id.map { ArtworkLookup(id: $0, type: type, kind: .poster) }, maxPixel: 720)
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.08)))
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
            if let subtitle {
                // One line at the card's width: a long one would widen the card and break the row's rhythm.
                Text(subtitle).font(.caption2).foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
        .titleCard(id.map { MetaRef(id: $0, type: type, name: title, poster: poster) })
    }
}

extension View {
    /// Long-press menu and early loading for a card that opens a title.
    func titleCard(_ ref: MetaRef?) -> some View { modifier(TitleCardExtras(ref: ref)) }
}

/// A title card's long-press menu (My List, watched, share), and its details fetched while
/// the card is on screen, so the title page opens with everything (hero art too) at once.
struct TitleCardExtras: ViewModifier {
    let ref: MetaRef?
    @EnvironmentObject private var favorites: FavoritesStore
    @ObservedObject private var watched = WatchedStore.shared

    @ViewBuilder
    func body(content: Content) -> some View {
        if let ref {
            content
                .modifier(ZoomSource(id: ref.id))
                .contextMenu { menu(ref) }
                .task(id: ref.id) {
                    // Only cards you stop on, not every one scrolled past.
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard !Task.isCancelled, PreviewMode.screen == nil else { return }
                    await MetaResolver.warm(ref)
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private func menu(_ ref: MetaRef) -> some View {
        let saved = favorites.contains(ref.id)
        Button(saved ? "Remove from My List" : "Add to My List", systemImage: saved ? "minus.circle" : "plus.circle") {
            withAnimation(.snappy) { favorites.toggle(ref) }
        }
        if ref.type == "movie" {
            let done = watched.isWatched(ref.id, metaId: ref.id)
            Button(done ? "Mark as Unwatched" : "Mark as Watched", systemImage: done ? "eye.slash" : "checkmark.circle") {
                watched.set([ref.id], watched: !done, metaId: ref.id, type: "movie", videoIds: nil)
            }
        }
        if ref.id.hasPrefix("tt"), let url = URL(string: "https://www.imdb.com/title/\(ref.id)/") {
            ShareLink(item: url, subject: Text(ref.name)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }
}

/// Grey stand-ins for a row that is still loading.
struct ShelfSkeleton: View {
    var count = 4
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.1)).frame(width: 160, height: 18)
                .padding(.horizontal, Device.margin)
            HStack(spacing: 12) {
                ForEach(0..<count, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.08))
                        .frame(width: Device.size(124), height: Device.size(124) * 1.5)
                }
            }
            .padding(.horizontal, Device.margin)
        }
        .opacity(dim ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
        .accessibilityLabel("Loading")
    }
}

/// Kept for screens that still use the old name.
typealias PosterImage = RemoteImage

// MARK: - Search

struct SearchScreen: View {
    @EnvironmentObject private var addons: AddonStore
    @ObservedObject private var feed = HomeFeed.shared
    @ObservedObject private var router = AppRouter.shared
    @Namespace private var zoom

    @State private var query = ""
    @State private var results: [CatalogRow] = []
    @State private var people: [IMDbSuggest.Person] = []
    /// Searches still out: the main sources, and your addons.
    @State private var pending = 0
    @State private var addonsPending = 0
    /// What the rows on screen are for; older rows stay (dimmed) until the new ones arrive.
    @State private var shownQuery = ""
    /// The last search that ran to the end (not cut short by leaving the screen).
    @State private var completedQuery: String?
    /// Your addons' own catalogs, shown under Popular before you type.
    @State private var addonRows: [CatalogRow] = []
    @State private var addonRowsFor: [String] = []
    @State private var addonRowsLoading = false
    /// What was searched for lately, newest first, one per line.
    @AppStorage("search.recent") private var recentRaw = ""

    private let columns = [GridItem(.adaptive(minimum: Device.size(104)), spacing: Device.isPad ? 18 : 12)]

    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init) }

    /// Remembers a search once it led somewhere (a result was opened, or Search was pressed).
    private func remember(_ text: String) {
        guard text.count >= 2 else { return }
        var list = recent.filter { $0.caseInsensitiveCompare(text) != .orderedSame }
        list.insert(text, at: 0)
        recentRaw = list.prefix(8).joined(separator: "\n")
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if trimmed.isEmpty {
                        idleContent
                    } else {
                        Group {
                            ForEach(results) { row in
                                resultRow(row)
                                    .transition(.opacity)
                            }
                            if !people.isEmpty {
                                peopleRow
                            }
                        }
                        .opacity(shownQuery == trimmed ? 1 : 0.45)
                        .animation(.easeInOut(duration: 0.2), value: shownQuery == trimmed)
                        if results.isEmpty && people.isEmpty {
                            if pending + addonsPending > 0 || shownQuery != trimmed {
                                VStack(alignment: .leading, spacing: 10) {
                                    RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.1)).frame(width: 130, height: 18)
                                    LazyVGrid(columns: columns, spacing: 16) {
                                        ForEach(0..<9, id: \.self) { _ in
                                            LoadingShade()
                                                .aspectRatio(2 / 3, contentMode: .fit)
                                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        }
                                    }
                                }
                                .padding(.horizontal, Device.margin)
                                .padding(.top, 8)
                                .accessibilityLabel("Searching")
                            } else {
                                ContentUnavailableView.search(text: trimmed)
                                    .padding(.top, 60)
                            }
                        } else if addonsPending > 0 && pending == 0 && shownQuery == trimmed {
                            // Quiet: the main results are in; a slow addon may still add a row.
                            Text(addonsPending == 1 ? "Checking 1 more addon…" : "Checking \(addonsPending) more addons…")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.bottom, 30)
            }
            .background(Color.black)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Movies, series, people")
            .autocorrectionDisabled()
            .onSubmit(of: .search) { remember(trimmed) }
            .modifier(BrowseDestinations(zoom: zoom))
            .environment(\.zoomNamespace, zoom)
            .task(id: trimmed) { await search(trimmed) }
            // "Search Atmos Player for …" from Siri or Shortcuts.
            .task(id: router.revision) {
                if case .search(let text)? = router.pending {
                    _ = router.take()
                    query = text
                }
            }
            // Its own task, so leaving Search mid-load doesn't cut the rows short.
            .task { await Task { await feed.load() }.value }
            .task {
                // CI screenshots only: type a search.
                if PreviewMode.screen == "search-results", query.isEmpty {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    query = "the office"
                }
            }
        }
    }

    /// "Top Results" as a grid; the other sources as rows you swipe through.
    @ViewBuilder
    private func resultRow(_ row: CatalogRow) -> some View {
        if row.id == "imdb/top" {
            VStack(alignment: .leading, spacing: 10) {
                Text(row.title).font(.title3.bold()).foregroundStyle(.white)
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(row.items) { item in resultCard(item) }
                }
            }
            .padding(.horizontal, Device.margin)
        } else {
            Shelf(title: row.title) {
                ForEach(row.items) { item in resultCard(item) }
            }
        }
    }

    private func resultCard(_ item: MetaPreview) -> some View {
        NavigationLink(value: MetaRef(item)) {
            PosterCard(title: item.name, subtitle: item.releaseInfo, poster: item.poster, id: item.id, type: item.type, width: Device.size(104))
        }
        .buttonStyle(CardButtonStyle())
        .simultaneousGesture(TapGesture().onEnded { remember(trimmed) })
    }

    private var peopleRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("People").font(.title3.bold()).foregroundStyle(.white)
                .padding(.horizontal, Device.margin)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(people) { person in
                        NavigationLink(value: PersonRoute(name: person.name)) {
                            VStack(spacing: 6) {
                                PersonAvatar(name: person.name, size: Device.size(76), photoURL: person.photo)
                                Text(person.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(width: Device.size(84))
                        }
                        .buttonStyle(CardButtonStyle())
                        .simultaneousGesture(TapGesture().onEnded { remember(trimmed) })
                    }
                }
                .padding(.horizontal, Device.margin)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Before typing: genres and what's popular, like the TV app's Search tab.
    @ViewBuilder
    private var idleContent: some View {
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent Searches").font(.title3.bold()).foregroundStyle(.white)
                    Spacer()
                    Button("Clear") { withAnimation { recentRaw = "" } }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, Device.margin)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(recent, id: \.self) { text in
                            Button { query = text } label: {
                                Label(text, systemImage: "clock.arrow.circlepath")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 14)
                                    .frame(height: 36)
                                    .background(.white.opacity(0.12), in: Capsule())
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Device.margin)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.top, 8)
        }
        GenreBrowser()
            .padding(.top, 8)
        if TMDB.isConfigured {
            PlatformBrowser()
        }
        if let popular = feed.top.first(where: { $0.id == "top-movies" }) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Popular Right Now").font(.title3.bold()).foregroundStyle(.white)
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(popular.items) { item in
                        NavigationLink(value: MetaRef(item)) {
                            PosterCard(title: item.name, subtitle: item.releaseInfo, poster: item.poster, id: item.id, type: item.type, width: Device.size(104))
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }
            }
            .padding(.horizontal, Device.margin)
        }
        if addonRowsLoading && addonRows.isEmpty {
            ShelfSkeleton()
        }
        ForEach(addonRows) { row in
            Shelf(title: row.title,
                  seeAll: row.source.map { CatalogRoute(title: row.title, type: "", catalogId: "", source: $0) }) {
                ForEach(row.items.filter { $0.poster != nil || $0.id.hasPrefix("tt") }.prefix(20)) { item in
                    NavigationLink(value: MetaRef(item)) {
                        PosterCard(title: item.name, subtitle: item.releaseInfo, poster: item.poster, id: item.id, type: item.type)
                    }
                    .buttonStyle(CardButtonStyle())
                }
            }
        }
        Color.clear.frame(height: 1)
            .task(id: addons.addons.map(\.id)) {
                let ids = addons.addons.map(\.id)
                guard ids != addonRowsFor else { return }
                addonRowsLoading = addons.addons.contains { !$0.transportURL.contains("cinemeta") && !$0.manifest.catalogs.isEmpty }
                let rows = await CatalogLoader.rows(addons.addons, excludingCinemeta: true)
                addonRowsLoading = false
                guard !Task.isCancelled else { return }
                addonRowsFor = ids
                withAnimation(.easeOut(duration: 0.25)) { addonRows = rows }
            }
    }

    /// IMDb's suggestions (best match first, typo-tolerant, with people) and Cinemeta's movie and
    /// series search run together; each addon's results appear as it answers. Addons get 8
    /// seconds, so a slow or broken one never keeps the screen waiting.
    private func search(_ text: String) async {
        guard !text.isEmpty else {
            completedQuery = nil
            results = []
            people = []
            pending = 0
            addonsPending = 0
            shownQuery = ""
            return
        }
        // Back from a title or another tab: its results are still showing.
        guard text != completedQuery else { return }
        defer { if !Task.isCancelled { completedQuery = text } }
        // Wait until typing pauses; a newer keystroke cancels this task.
        try? await Task.sleep(nanoseconds: 300_000_000)
        if Task.isCancelled { return }

        enum Answer {
            /// A title source for the merged list (and people, from the source that has them).
            case main(String, [MetaPreview], [IMDbSuggest.Person])
            case row(order: Int, CatalogRow?)
        }
        let others = addons.addons.filter { !$0.transportURL.contains("cinemeta") }
        let named = others.filter { addon in addon.manifest.catalogs.contains { $0.isSearchable } }.count > 1
        var addonJobs: [(order: Int, id: String, title: String, addon: InstalledAddon, catalog: StremioCatalog)] = []
        for addon in others {
            for catalog in addon.manifest.catalogs where catalog.isSearchable {
                var title = catalog.name ?? CatalogLoader.typeLabel(catalog.type)
                if named || title.isEmpty { title = "\(addon.manifest.name) · \(CatalogLoader.typeLabel(catalog.type))" }
                addonJobs.append((3 + addonJobs.count, "\(addon.id)/\(catalog.type)/\(catalog.id)", title, addon, catalog))
            }
        }

        pending = 3
        addonsPending = addonJobs.count
        var pools: [String: [MetaPreview]] = [:]
        var addonRows: [(Int, CatalogRow)] = []
        var fresh = true
        // The first answer replaces the previous search's rows; later ones add to them.
        func show(_ update: () -> Void) {
            if fresh {
                fresh = false
                results = []
                people = []
                shownQuery = text
            }
            withAnimation(.easeOut(duration: 0.2)) { update() }
        }
        // One merged list (best matches as a grid, then more movies and series); each addon's
        // own row after it, without the titles already above.
        func rows() -> [CatalogRow] {
            let order = ["tmdb", "imdb", "cinemeta/movie", "cinemeta/series"]
            let merged = UnifiedSearch.merge(text, order.compactMap { pools[$0] })
            var out: [CatalogRow] = []
            let top = Array(merged.prefix(12))
            if !top.isEmpty { out.append(CatalogRow(id: "imdb/top", title: "Top Results", items: top)) }
            let more = merged.dropFirst(12)
            let movies = more.filter { $0.type == "movie" }
            let series = more.filter { $0.type == "series" }
            if !movies.isEmpty { out.append(CatalogRow(id: "more/movie", title: "More Movies", items: Array(movies))) }
            if !series.isEmpty { out.append(CatalogRow(id: "more/series", title: "More Series", items: Array(series))) }
            let shown = Set(merged.map(\.id))
            for (_, row) in addonRows.sorted(by: { $0.0 < $1.0 }) {
                let items = row.items.filter { !shown.contains($0.id) }
                if !items.isEmpty { out.append(CatalogRow(id: row.id, title: row.title, items: items, source: row.source)) }
            }
            return out
        }

        await withTaskGroup(of: Answer.self) { group in
            if TMDB.isConfigured {
                // TMDB's documented search instead of IMDb's undocumented suggestions.
                group.addTask { @MainActor in
                    let found = await UnifiedSearch.tmdb(text)
                    return .main("tmdb", found.titles, Array(found.people.prefix(12)))
                }
            } else {
                group.addTask {
                    let found = await IMDbSuggest.search(text)
                    return .main("imdb", Array(found.titles.prefix(10)), Array(found.people.prefix(12)))
                }
            }
            group.addTask {
                .main("cinemeta/movie", await Cinemeta.search(type: "movie", text), [])
            }
            group.addTask {
                .main("cinemeta/series", await Cinemeta.search(type: "series", text), [])
            }
            for job in addonJobs {
                group.addTask {
                    let items = (try? await StremioClient.catalog(job.addon, job.catalog, search: text, timeout: 8)) ?? []
                    return .row(order: job.order, items.isEmpty ? nil : CatalogRow(id: job.id, title: job.title, items: items))
                }
            }
            for await answer in group {
                if Task.isCancelled { group.cancelAll(); return }
                var changed = false
                var found: [IMDbSuggest.Person] = []
                switch answer {
                case .main(let key, let items, let list):
                    pending -= 1
                    if !items.isEmpty { pools[key] = items; changed = true }
                    found = list
                case .row(let order, let result):
                    addonsPending -= 1
                    if let result { addonRows.append((order, result)); changed = true }
                }
                guard changed || !found.isEmpty else { continue }
                let next = rows()
                show {
                    results = next
                    if !found.isEmpty { people = found }
                }
            }
        }
        if !Task.isCancelled {
            pending = 0
            addonsPending = 0
            // Nothing anywhere: clear the old rows so "No Results" shows.
            if fresh { show {} }
        }
    }
}

/// Launch-argument hooks used only by the CI screenshot job (`-previewScreen home|detail|stremio|search|player`).
enum PreviewMode {
    static let screen = UserDefaults.standard.string(forKey: "previewScreen")

    static var initialTab: Int {
        switch screen {
        case "stremio": return 2
        case "search", "search-results": return 3
        case "settings": return 4
        default: return 0
        }
    }
}
