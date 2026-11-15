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
            .padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: spacing) {
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
        case "settings": return 4
        default: return 0
        }
    }
}
