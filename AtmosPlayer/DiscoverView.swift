import SwiftUI

struct CatalogRow: Identifiable {
    let id: String
    let title: String
    let items: [MetaPreview]
}

/// Loads the browsable catalog rows of every installed addon, in addon order.
enum CatalogLoader {
    static func rows(_ addons: [InstalledAddon]) async -> [CatalogRow] {
        var jobs: [(String, String, InstalledAddon, StremioCatalog)] = []
        let showAddonName = addons.filter { !$0.manifest.catalogs.isEmpty }.count > 1
        for addon in addons {
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
                    let items = (try? await StremioClient.catalog(job.2, job.3)) ?? []
                    return (index, items.isEmpty ? nil : CatalogRow(id: job.0, title: job.1, items: items))
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

// MARK: - Home

struct HomeScreen: View {
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var account: StremioAccount

    @State private var rows: [CatalogRow] = []
    @State private var loading = false
    @State private var path = NavigationPath()
    @State private var startingId: String?
    @EnvironmentObject private var coordinator: PlayerCoordinator

    private var heroItems: [MetaPreview] {
        let source = rows.first?.items ?? []
        return Array(source.filter { $0.background != nil }.prefix(8))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if !heroItems.isEmpty {
                        HeroCarousel(items: heroItems)
                    }

                    if !watch.entries.isEmpty {
                        Shelf(title: "Continue Watching") {
                            ForEach(watch.entries) { entry in
                                Button {
                                    Task { await resume(entry.ref) }
                                } label: {
                                    ContinueCard(entry: entry)
                                        .overlay {
                                            if startingId == entry.id {
                                                ProgressView().controlSize(.large).tint(.white)
                                            }
                                        }
                                }
                                .buttonStyle(CardButtonStyle())
                                .contextMenu {
                                    Button("Remove from Continue Watching", systemImage: "xmark.circle", role: .destructive) {
                                        withAnimation { watch.remove(entry.ref.videoId) }
                                    }
                                }
                            }
                        }
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

                    if !account.library.isEmpty {
                        Shelf(title: "Stremio Library") {
                            ForEach(account.library, id: \.id) { ref in
                                NavigationLink(value: ref) {
                                    PosterCard(title: ref.name, subtitle: nil, poster: ref.poster)
                                }
                                .buttonStyle(CardButtonStyle())
                            }
                        }
                    }

                    ForEach(rows) { row in
                        Shelf(title: row.title) {
                            ForEach(row.items) { item in
                                NavigationLink(value: MetaRef(item)) {
                                    PosterCard(title: item.name, subtitle: item.releaseInfo, poster: item.poster)
                                }
                                .buttonStyle(CardButtonStyle())
                            }
                        }
                    }

                    if rows.isEmpty {
                        emptyState
                    }
                }
                .padding(.bottom, 30)
            }
            .background(Color.black)
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: heroItems.isEmpty ? [] : .top)
            .navigationTitle("Home")
            .toolbar(heroItems.isEmpty ? .visible : .hidden, for: .navigationBar)
            .modifier(BrowseDestinations())
            .task(id: addons.revision) { await load() }
            .refreshable {
                await account.sync(addons: addons, watch: watch)
                await load(force: true)
            }
            .task {
                // CI screenshots only: open a title page.
                if PreviewMode.screen == "detail", path.isEmpty {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    path.append(MetaRef(id: "tt0903747", type: "series", name: "Breaking Bad", poster: nil))
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
        } else {
            ContentUnavailableView {
                Label(addons.addons.isEmpty ? "No addons yet" : "Nothing to show", systemImage: "sparkles.tv")
            } description: {
                Text("Add Cinemeta and your stream addon in the Addons tab.")
            }
            .padding(.top, 60)
        }
    }

    /// Continue Watching resumes with the stream used last time, like Stremio; if there isn't
    /// one, the stream list opens.
    private func resume(_ video: VideoRef) async {
        guard startingId == nil else { return }
        startingId = video.videoId
        defer { startingId = nil }
        let queue = await EpisodeQueue.queue(after: video, addons: addons)
        if let item = await QuickPlay.resolve(video: video, queue: queue, addons: addons) {
            coordinator.play(item)
        } else {
            path.append(StreamsRoute(video: video, queue: queue))
        }
    }

    @State private var loadedRevision: Int?

    private func load(force: Bool = false) async {
        guard force || loadedRevision != addons.revision || rows.isEmpty else { return }
        loading = true
        defer { loading = false }
        let loaded = await CatalogLoader.rows(addons.addons)
        loadedRevision = addons.revision
        withAnimation(.easeOut(duration: 0.25)) { rows = loaded }
    }
}

/// Navigation targets shared by every browsing stack.
struct BrowseDestinations: ViewModifier {
    func body(content: Content) -> some View {
        content
            .navigationDestination(for: MetaRef.self) { ref in
                MetaDetailView(ref: ref)
            }
            .navigationDestination(for: StreamsRoute.self) { route in
                StreamsView(video: route.video, queue: route.queue)
            }
    }
}

// MARK: - Hero

struct HeroCarousel: View {
    let items: [MetaPreview]
    @State private var current: String?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { item in
                        NavigationLink(value: MetaRef(item)) {
                            HeroCard(item: item)
                                .frame(width: width, height: geo.size.height)
                        }
                        .buttonStyle(.plain)
                        .scrollTransition(.interactive, axis: .horizontal) { view, phase in
                            view.opacity(phase.isIdentity ? 1 : 0.6)
                        }
                        .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $current)
            .overlay(alignment: .bottom) {
                HStack(spacing: 6) {
                    ForEach(items) { item in
                        Capsule()
                            .fill(.white.opacity(item.id == (current ?? items.first?.id) ? 0.95 : 0.35))
                            .frame(width: item.id == (current ?? items.first?.id) ? 16 : 6, height: 6)
                    }
                }
                .animation(.spring(duration: 0.3), value: current)
                .padding(.bottom, 14)
            }
        }
        .aspectRatio(0.82, contentMode: .fit)
        .task {
            // Gentle auto-advance, like a storefront.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                guard !Task.isCancelled, items.count > 1 else { continue }
                let index = items.firstIndex { $0.id == current } ?? 0
                withAnimation(.easeInOut(duration: 0.6)) { current = items[(index + 1) % items.count].id }
            }
        }
    }
}

struct HeroCard: View {
    let item: MetaPreview

    var body: some View {
        ZStack(alignment: .bottom) {
            RemoteImage(url: item.background ?? item.poster, maxPixel: 1400)
                .clipped()
            LinearGradient(stops: [
                .init(color: .clear, location: 0.35),
                .init(color: .black.opacity(0.55), location: 0.65),
                .init(color: .black, location: 1),
            ], startPoint: .top, endPoint: .bottom)

            VStack(spacing: 12) {
                TitleArt(logo: item.logo, name: item.name, maxHeight: 90)
                    .padding(.horizontal, 40)
                let facts = [item.releaseInfo, item.imdbRating.map { "★ \($0)" }].compactMap { $0 }
                if !facts.isEmpty {
                    Text(facts.joined(separator: "  ·  "))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
                if let description = item.description {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
            }
            .padding(.bottom, 40)
        }
        .contentShape(Rectangle())
    }
}

/// The title's logo artwork when the addon has one, otherwise its name in big type.
struct TitleArt: View {
    let logo: String?
    let name: String
    var maxHeight: CGFloat = 80

    @State private var logoFailed = false

    var body: some View {
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

private struct LogoImage: View {
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
            if loaded == nil { failed = true } else { withAnimation { image = loaded } }
        }
    }
}

// MARK: - Shelves and cards

struct Shelf<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    content()
                }
                .scrollTargetLayout()
                .padding(.horizontal, 20)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }
}

/// Cards shrink slightly while pressed, the way storefront cards do.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

struct PosterCard: View {
    let title: String
    let subtitle: String?
    let poster: String?
    var width: CGFloat = 124

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: poster, maxPixel: 420)
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

struct ContinueCard: View {
    let entry: WatchStore.Entry
    private let width: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: entry.ref.background ?? entry.ref.poster, maxPixel: 700)
                    .frame(width: width, height: width * 9 / 16)
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .padding(7)
                        .background(.ultraThinMaterial, in: Circle())
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.3))
                            Capsule().fill(.white).frame(width: geo.size.width * entry.progress)
                        }
                    }
                    .frame(height: 4)
                }
                .padding(10)
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(entry.ref.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
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

/// Kept for screens that still use the old name.
typealias PosterImage = RemoteImage

// MARK: - Search

struct SearchScreen: View {
    @EnvironmentObject private var addons: AddonStore

    @State private var query = ""
    @State private var results: [CatalogRow] = []
    @State private var searching = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(results) { row in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(row.title).font(.title3.bold()).foregroundStyle(.white)
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(row.items) { item in
                                    NavigationLink(value: MetaRef(item)) {
                                        PosterCard(title: item.name, subtitle: item.releaseInfo,
                                                   poster: item.poster, width: 104)
                                    }
                                    .buttonStyle(CardButtonStyle())
                                }
                            }
                        }
                    }
                    if results.isEmpty {
                        Group {
                            if searching {
                                ProgressView()
                            } else if query.isEmpty {
                                ContentUnavailableView("Search", systemImage: "magnifyingglass",
                                                       description: Text("Movies and series from your addons' catalogs."))
                            } else {
                                ContentUnavailableView.search(text: query)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
            .background(Color.black)
            .navigationTitle("Search")
            .scrollDismissesKeyboard(.immediately)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Movies & Series")
            .modifier(BrowseDestinations())
            .task(id: query) { await search() }
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            results = []
            return
        }
        // Wait until typing pauses; a newer keystroke cancels this task.
        try? await Task.sleep(nanoseconds: 400_000_000)
        if Task.isCancelled { return }
        searching = true
        defer { searching = false }

        var jobs: [(String, String, InstalledAddon, StremioCatalog)] = []
        for addon in addons.addons {
            for catalog in addon.manifest.catalogs where catalog.isSearchable {
                jobs.append(("\(addon.id)/\(catalog.type)/\(catalog.id)/search",
                             CatalogLoader.typeLabel(catalog.type), addon, catalog))
            }
        }
        let found = await withTaskGroup(of: (Int, CatalogRow?).self) { group in
            for (index, job) in jobs.enumerated() {
                group.addTask {
                    let items = (try? await StremioClient.catalog(job.2, job.3, search: text)) ?? []
                    return (index, items.isEmpty ? nil : CatalogRow(id: job.0, title: job.1, items: items))
                }
            }
            var collected: [(Int, CatalogRow)] = []
            for await (index, row) in group {
                if let row { collected.append((index, row)) }
            }
            return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        if !Task.isCancelled {
            withAnimation(.easeOut(duration: 0.2)) { results = found }
        }
    }
}

/// Launch-argument hooks used only by the CI screenshot job (`-previewScreen home|detail|stremio|search|player`).
enum PreviewMode {
    static let screen = UserDefaults.standard.string(forKey: "previewScreen")

    static var initialTab: Int {
        switch screen {
        case "stremio": return 2
        case "search": return 3
        default: return 0
        }
    }
}
