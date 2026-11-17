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
    @State private var people: [IMDbSuggest.Person] = []
    /// Searches still out: the main sources, and your addons.
    @State private var pending = 0
    @State private var addonsPending = 0
    /// What the rows on screen are for; older rows stay (dimmed) until the new ones arrive.
    @State private var shownQuery = ""
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
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Searching…").font(.footnote).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 80)
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
            .modifier(BrowseDestinations())
            .task(id: trimmed) { await search(trimmed) }
            .task { await feed.load() }
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
            PosterCard(title: item.name, subtitle: item.releaseInfo, poster: item.poster, width: Device.size(104))
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
                                PersonAvatar(name: person.name, size: Device.size(76))
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

    /// IMDb's suggestions (best match first, typo-tolerant, with people) and Cinemeta's movie and
    /// series search run together; each addon's results appear as it answers. Addons get 8
    /// seconds, so a slow or broken one never keeps the screen waiting.
    private func search(_ text: String) async {
        guard !text.isEmpty else {
            results = []
            people = []
            pending = 0
            addonsPending = 0
            shownQuery = ""
            return
        }
        // Wait until typing pauses; a newer keystroke cancels this task.
        try? await Task.sleep(nanoseconds: 300_000_000)
        if Task.isCancelled { return }

        enum Answer {
            case imdb(CatalogRow?, [IMDbSuggest.Person])
            case row(order: Int, CatalogRow?, addon: Bool)
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
        var arrived: [(Int, CatalogRow)] = []
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

        await withTaskGroup(of: Answer.self) { group in
            group.addTask {
                let found = await IMDbSuggest.search(text)
                let top = Array(found.titles.prefix(10))
                return .imdb(top.isEmpty ? nil : CatalogRow(id: "imdb/top", title: "Top Results", items: top),
                             Array(found.people.prefix(12)))
            }
            group.addTask {
                let items = await Cinemeta.search(type: "movie", text)
                return .row(order: 1, items.isEmpty ? nil : CatalogRow(id: "cinemeta/movie", title: "Movies", items: items), addon: false)
            }
            group.addTask {
                let items = await Cinemeta.search(type: "series", text)
                return .row(order: 2, items.isEmpty ? nil : CatalogRow(id: "cinemeta/series", title: "Series", items: items), addon: false)
            }
            for job in addonJobs {
                group.addTask {
                    let items = (try? await StremioClient.catalog(job.addon, job.catalog, search: text, timeout: 8)) ?? []
                    return .row(order: job.order, items.isEmpty ? nil : CatalogRow(id: job.id, title: job.title, items: items),
                                addon: true)
                }
            }
            for await answer in group {
                if Task.isCancelled { group.cancelAll(); return }
                var row: (Int, CatalogRow)?
                var found: [IMDbSuggest.Person] = []
                switch answer {
                case .imdb(let top, let list):
                    pending -= 1
                    if let top { row = (0, top) }
                    found = list
                case .row(let order, let result, let addon):
                    if addon { addonsPending -= 1 } else { pending -= 1 }
                    if let result { row = (order, result) }
                }
                guard row != nil || !found.isEmpty else { continue }
                if let row { arrived.append(row) }
                let sorted = arrived.sorted { $0.0 < $1.0 }.map { $0.1 }
                show {
                    results = sorted
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
