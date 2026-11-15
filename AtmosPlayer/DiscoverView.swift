import SwiftUI

struct CatalogRow: Identifiable {
    let id: String
    let title: String
    let items: [MetaPreview]
}

struct DiscoverView: View {
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var watch: WatchStore

    @State private var rows: [CatalogRow] = []
    @State private var loadingRows = false
    @State private var query = ""
    @State private var results: [CatalogRow] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        browseContent
                    } else {
                        searchContent
                    }
                }
                .padding(.vertical, 12)
            }
            .navigationTitle("Discover")
            .searchable(text: $query, prompt: "Search movies & series")
            .navigationDestination(for: MetaRef.self) { ref in
                MetaDetailView(ref: ref)
            }
            .navigationDestination(for: VideoRef.self) { ref in
                StreamsView(video: ref)
            }
            .task(id: addons.revision) { await loadRows() }
            .task(id: query) { await search() }
            .refreshable { await loadRows() }
        }
    }

    // MARK: Browse

    @ViewBuilder
    private var browseContent: some View {
        if !watch.entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Continue watching").font(.title3.bold()).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(watch.entries) { entry in
                            NavigationLink(value: entry.ref) {
                                ContinueCard(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Remove", role: .destructive) { watch.remove(entry.ref.videoId) }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }

        if addons.addons.isEmpty {
            emptyState("No addons yet", "Add Cinemeta and your stream addon in the Addons tab.")
        } else if rows.isEmpty && loadingRows {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        } else if rows.isEmpty {
            emptyState("Nothing to browse", "None of your addons has a catalog. Add Cinemeta in the Addons tab.")
        }

        ForEach(rows) { row in
            PosterRow(row: row)
        }
    }

    private func loadRows() async {
        loadingRows = true
        defer { loadingRows = false }

        var jobs: [(String, String, InstalledAddon, StremioCatalog)] = []
        let showAddonName = addons.addons.filter { !$0.manifest.catalogs.isEmpty }.count > 1
        for addon in addons.addons {
            for catalog in addon.manifest.catalogs where catalog.isBrowsable {
                let name = catalog.name ?? catalog.id
                var title = "\(name) \(typeLabel(catalog.type))"
                if showAddonName { title += " · \(addon.manifest.name)" }
                jobs.append(("\(addon.id)/\(catalog.type)/\(catalog.id)", title, addon, catalog))
            }
        }

        let loaded = await withTaskGroup(of: (Int, CatalogRow?).self) { group in
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
        rows = loaded
    }

    // MARK: Search

    @ViewBuilder
    private var searchContent: some View {
        if searching && results.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        } else if results.isEmpty {
            emptyState("No results", "Try another title. Search uses the catalogs of your addons (Cinemeta by default).")
        }
        ForEach(results) { row in
            PosterRow(row: row)
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            results = []
            return
        }
        // Wait until typing pauses; a newer keystroke cancels this task.
        try? await Task.sleep(nanoseconds: 450_000_000)
        if Task.isCancelled { return }
        searching = true
        defer { searching = false }

        var jobs: [(String, String, InstalledAddon, StremioCatalog)] = []
        for addon in addons.addons {
            for catalog in addon.manifest.catalogs where catalog.isSearchable {
                jobs.append(("\(addon.id)/\(catalog.type)/\(catalog.id)/search",
                             "\(typeLabel(catalog.type)) · \(addon.manifest.name)", addon, catalog))
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
        if !Task.isCancelled { results = found }
    }

    // MARK: Helpers

    private func typeLabel(_ type: String) -> String {
        switch type {
        case "movie": return "Movies"
        case "series": return "Series"
        case "tv": return "TV"
        default: return type.capitalized
        }
    }

    private func emptyState(_ title: String, _ message: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 40)
    }
}

struct PosterRow: View {
    let row: CatalogRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.title).font(.title3.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(row.items) { item in
                        NavigationLink(value: MetaRef(id: item.id, type: item.type, name: item.name, poster: item.poster)) {
                            PosterCard(title: item.name, subtitle: item.releaseInfo, poster: item.poster)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct PosterCard: View {
    let title: String
    let subtitle: String?
    let poster: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PosterImage(url: poster)
                .frame(width: 112, height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(title)
                .font(.caption)
                .lineLimit(2)
                .frame(width: 112, alignment: .leading)
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct ContinueCard: View {
    let entry: WatchStore.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottom) {
                PosterImage(url: entry.ref.poster)
                    .frame(width: 112, height: 168)
                ProgressView(value: entry.progress)
                    .tint(.accentColor)
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(entry.ref.name).font(.caption).lineLimit(1).frame(width: 112, alignment: .leading)
            Text(entry.ref.episodeLabel ?? "\(formatTime(entry.position)) / \(formatTime(entry.duration))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)
        }
    }
}

struct PosterImage: View {
    let url: String?

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Color.gray.opacity(0.25)
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
        }
    }
}
