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
            .navigationDestination(for: CatalogRoute.self) { route in
                CatalogGridScreen(route: route)
            }
            .navigationDestination(for: PersonRoute.self) { route in
                PersonScreen(route: route)
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
    var width: CGFloat = Device.size(124)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: poster, maxPixel: 720)
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.08)))
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

/// Kept for screens that still use the old name.
typealias PosterImage = RemoteImage

// MARK: - Search

struct SearchScreen: View {
    @EnvironmentObject private var addons: AddonStore
    @ObservedObject private var feed = HomeFeed.shared

    @State private var query = ""
    @State private var results: [CatalogRow] = []
    @State private var pending = 0

    private let columns = [GridItem(.adaptive(minimum: Device.size(104)), spacing: Device.isPad ? 18 : 12)]

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if trimmed.isEmpty {
                        idleContent
                    } else {
                        ForEach(results) { row in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(row.title).font(.title3.bold()).foregroundStyle(.white)
                                LazyVGrid(columns: columns, spacing: 16) {
                                    ForEach(row.items) { item in
                                        NavigationLink(value: MetaRef(item)) {
                                            PosterCard(title: item.name, subtitle: item.releaseInfo,
                                                       poster: item.poster, width: Device.size(104))
                                        }
                                        .buttonStyle(CardButtonStyle())
                                    }
                                }
                            }
                            .transition(.opacity)
                        }
                        if pending > 0 {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(results.isEmpty ? "Searching…" : "Still asking your addons…")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, results.isEmpty ? 80 : 0)
                        } else if results.isEmpty {
                            ContentUnavailableView.search(text: trimmed)
                                .padding(.top, 60)
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
            .modifier(BrowseDestinations())
            .task(id: trimmed) { await search(trimmed) }
            .task { await feed.load() }
        }
    }

    /// Before typing: genres and what's popular, like the TV app's Search tab.
    @ViewBuilder
    private var idleContent: some View {
        GenreBrowser()
            .padding(.top, 8)
        if let popular = feed.top.first(where: { $0.id == "top-movies" }) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Popular Right Now").font(.title3.bold()).foregroundStyle(.white)
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(popular.items) { item in
                        NavigationLink(value: MetaRef(item)) {
                            PosterCard(title: item.name, subtitle: item.releaseInfo, poster: item.poster, width: Device.size(104))
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }
            }
            .padding(.horizontal, Device.margin)
        }
    }

    /// Cinemeta answers first (it is fast and covers everything on IMDb); each addon's results
    /// appear as soon as that addon answers, so a slow one never holds the screen.
    private func search(_ text: String) async {
        guard !text.isEmpty else {
            results = []
            pending = 0
            return
        }
        // Wait until typing pauses; a newer keystroke cancels this task.
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }

        struct Job: Sendable {
            let order: Int
            let id: String
            let title: String
            let run: @Sendable () async -> [MetaPreview]
        }
        var jobs: [Job] = [
            Job(order: 0, id: "cinemeta/movie", title: "Movies") { await Cinemeta.search(type: "movie", text) },
            Job(order: 1, id: "cinemeta/series", title: "Series") { await Cinemeta.search(type: "series", text) },
        ]
        let others = addons.addons.filter { !$0.transportURL.contains("v3-cinemeta.strem.io") }
        let named = others.filter { addon in addon.manifest.catalogs.contains { $0.isSearchable } }.count > 1
        for addon in others {
            for catalog in addon.manifest.catalogs where catalog.isSearchable {
                var title = "\(catalog.name ?? CatalogLoader.typeLabel(catalog.type))"
                if named || title.isEmpty { title = "\(addon.manifest.name) · \(CatalogLoader.typeLabel(catalog.type))" }
                jobs.append(Job(order: jobs.count, id: "\(addon.id)/\(catalog.type)/\(catalog.id)", title: title) {
                    (try? await StremioClient.catalog(addon, catalog, search: text)) ?? []
                })
            }
        }

        results = []
        pending = jobs.count
        var arrived: [(Int, CatalogRow)] = []
        await withTaskGroup(of: (Int, CatalogRow?).self) { group in
            for job in jobs {
                group.addTask {
                    let items = await job.run()
                    return (job.order, items.isEmpty ? nil : CatalogRow(id: job.id, title: job.title, items: items))
                }
            }
            for await (order, row) in group {
                if Task.isCancelled { group.cancelAll(); return }
                pending -= 1
                if let row {
                    arrived.append((order, row))
                    withAnimation(.easeOut(duration: 0.2)) {
                        results = arrived.sorted { $0.0 < $1.0 }.map { $0.1 }
                    }
                }
            }
        }
        if !Task.isCancelled { pending = 0 }
    }
}

/// Launch-argument hooks used only by the CI screenshot job (`-previewScreen home|detail|stremio|search|player`).
enum PreviewMode {
    static let screen = UserDefaults.standard.string(forKey: "previewScreen")

    static var initialTab: Int {
        switch screen {
        case "stremio": return 2
        case "search": return 3
        case "settings": return 4
        default: return 0
        }
    }
}
