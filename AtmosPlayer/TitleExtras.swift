import SwiftUI

// MARK: - Ratings row

/// IMDb score, awards, runtime and year as a row of tiles under the description.
struct RatingsRow: View {
    let meta: StremioMeta
    /// TMDB's user score, shown beside IMDb's (never in place of it).
    var tmdbRating: Double? = nil

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                if let rating = meta.imdbRating, let value = Double(rating), value > 0 {
                    tile {
                        HStack(spacing: 6) {
                            Text("IMDb")
                                .font(.system(size: 12, weight: .black))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color(red: 0.96, green: 0.77, blue: 0.09), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.black)
                            Text(rating).font(.title3.weight(.bold).monospacedDigit())
                            Text("/10").font(.caption).foregroundStyle(.white.opacity(0.5))
                        }
                    } caption: {
                        Stars(value: value / 2)
                    }
                }
                if let tmdbRating, tmdbRating > 0 {
                    tile {
                        HStack(spacing: 6) {
                            TMDBMark(height: 14)
                            Text(String(format: "%.0f%%", tmdbRating * 10)).font(.title3.weight(.bold).monospacedDigit())
                        }
                    } caption: {
                        Text("User score")
                    }
                }
                if let awards = meta.awards, !awards.isEmpty {
                    tile {
                        Label(awardHeadline(awards), systemImage: "trophy.fill")
                            .font(.subheadline.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Color(red: 0.98, green: 0.82, blue: 0.35), .white)
                    } caption: {
                        Text(awards).lineLimit(1)
                    }
                }
                if let runtime = meta.runtime, !runtime.isEmpty {
                    tile {
                        Label(runtime, systemImage: "clock").font(.subheadline.weight(.semibold))
                    } caption: {
                        Text(meta.type == "series" ? "Per episode" : "Runtime")
                    }
                }
                if let year = meta.releaseInfo, !year.isEmpty {
                    tile {
                        Label(year, systemImage: "calendar").font(.subheadline.weight(.semibold))
                    } caption: {
                        Text(meta.type == "series" ? "On air" : "Released")
                    }
                }
            }
            .padding(.horizontal, Device.margin)
        }
        .scrollIndicators(.hidden)
    }

    private func tile<Top: View, Bottom: View>(@ViewBuilder _ top: () -> Top,
                                                @ViewBuilder caption: () -> Bottom) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            top()
            caption()
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minWidth: 120, maxWidth: 260, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// "Won 1 Oscar. 45 wins & 148 nominations total" → "Won 1 Oscar".
    private func awardHeadline(_ text: String) -> String {
        let first = text.split(separator: ".").first.map(String.init) ?? text
        return first.count > 28 ? "Awards" : first
    }
}

private struct Stars: View {
    let value: Double   // 0…5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let fill = min(max(value - Double(index), 0), 1)
                Image(systemName: fill >= 0.75 ? "star.fill" : fill >= 0.25 ? "star.leadinghalf.filled" : "star")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(red: 0.96, green: 0.77, blue: 0.09))
            }
        }
    }
}

// MARK: - Cast & crew

/// A person shown on a title page; opens their other titles.
struct PersonRoute: Hashable {
    let name: String
}

struct CastShelf: View {
    let meta: StremioMeta
    /// With TMDB: photos, and the character each actor plays.
    var extras: MetaExtras? = nil

    private var people: [(name: String, role: String)] {
        var list: [(String, String)] = []
        var seen = Set<String>()
        if let extras, !extras.cast.isEmpty {
            for person in extras.crew where person.role == "Director" && seen.insert(person.name).inserted {
                list.append((person.name, "Director"))
            }
            for person in extras.cast.prefix(20) where seen.insert(person.name).inserted {
                list.append((person.name, person.role ?? "Actor"))
            }
            for person in extras.crew where ["Creator", "Writer", "Screenplay"].contains(person.role ?? "")
                && seen.insert(person.name).inserted {
                list.append((person.name, person.role ?? "Writer"))
            }
            return list
        }
        for name in meta.directors where seen.insert(name).inserted { list.append((name, "Director")) }
        for name in meta.cast where seen.insert(name).inserted { list.append((name, "Actor")) }
        for name in meta.writers where seen.insert(name).inserted { list.append((name, "Writer")) }
        return list
    }

    private func photo(_ name: String) -> String? {
        extras.flatMap { x in (x.cast + x.crew).first { $0.name == name }?.photo }
    }

    var body: some View {
        Shelf(title: "Cast & Crew", spacing: 16) {
            ForEach(people, id: \.name) { person in
                NavigationLink(value: PersonRoute(name: person.name)) {
                    VStack(spacing: 8) {
                        PersonAvatar(name: person.name, size: 76, photoURL: photo(person.name))
                        VStack(spacing: 2) {
                            Text(person.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            Text(person.role)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .frame(width: 88)
                }
                .buttonStyle(CardButtonStyle())
            }
        }
    }
}

/// A person's photo and short biography, from Wikipedia (Cinemeta has neither). Looked up by
/// name and kept only when the article is plainly about someone who works in film or TV.
struct PersonInfo: Codable, Equatable {
    var photo: String?
    var summary: String?
    var tagline: String?
    var page: String?
}

actor PersonDirectory {
    static let shared = PersonDirectory()

    private var cache: [String: PersonInfo] = [:]
    private var inflight: [String: Task<PersonInfo, Never>] = [:]
    private static let trades = ["actor", "actress", "director", "filmmaker", "writer", "producer", "comedian",
                                 "screenwriter", "showrunner", "animator", "performer", "cinematographer",
                                 "composer", "singer", "musician", "presenter", "model", "rapper", "author"]

    func info(for name: String) async -> PersonInfo {
        if let hit = cache[name] { return hit }
        if let running = inflight[name] { return await running.value }
        let task = Task { await Self.fetch(name) }
        inflight[name] = task
        let result = await task.value
        inflight[name] = nil
        cache[name] = result
        return result
    }

    private struct Summary: Decodable {
        struct Image: Decodable { let source: String? }
        struct Pages: Decodable {
            struct Page: Decodable { let page: String? }
            let mobile: Page?
        }
        let type: String?
        let description: String?
        let extract: String?
        let thumbnail: Image?
        let content_urls: Pages?
    }

    private static func fetch(_ name: String) async -> PersonInfo {
        let title = name.replacingOccurrences(of: " ", with: "_")
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)?redirect=true") else {
            return PersonInfo()
        }
        var request = URLRequest(url: url)
        request.setValue("AtmosPlayer/0.1 (iOS video player)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .returnCacheDataElseLoad
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let summary = try? JSONDecoder().decode(Summary.self, from: data),
              summary.type == "standard" else { return PersonInfo() }
        // Another person or thing with the same name: better initials than the wrong face.
        let about = ((summary.description ?? "") + " " + String((summary.extract ?? "").prefix(260))).lowercased()
        guard trades.contains(where: { about.contains($0) }) else { return PersonInfo() }
        return PersonInfo(photo: summary.thumbnail?.source, summary: summary.extract,
                          tagline: summary.description, page: summary.content_urls?.mobile?.page)
    }
}

/// The person's photo when one is found, else initials on a soft gradient.
struct PersonAvatar: View {
    let name: String
    let size: CGFloat
    /// A known photo (TMDB's); without one, Wikipedia is asked by name.
    var photoURL: String? = nil
    @State private var photo: String?

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
    }

    private var hue: Double {
        Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.55),
                                    Color(hue: hue, saturation: 0.55, brightness: 0.3)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(initials)
                .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
            if let photo {
                // Faces sit in the upper part of a portrait photo.
                RemoteImage(url: photo, maxPixel: Int(size * 3), placeholderSymbol: "")
                    .frame(width: size, height: size * 1.25)
                    .frame(width: size, height: size, alignment: .top)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.1)))
        .task(id: name + (photoURL ?? "")) {
            if let photoURL {
                photo = photoURL
                return
            }
            let found = await PersonDirectory.shared.info(for: name).photo
            if found != photo { withAnimation(.easeOut(duration: 0.25)) { photo = found } }
        }
    }
}

/// Everything Cinemeta finds for a person's name, movies and series.
struct PersonScreen: View {
    let route: PersonRoute
    @State private var movies: [MetaPreview] = []
    @State private var series: [MetaPreview] = []
    @State private var loading = true
    @State private var info = PersonInfo()
    @State private var expanded = false
    @Environment(\.openURL) private var openURL

    private let columns = [GridItem(.adaptive(minimum: Device.size(104)), spacing: Device.isPad ? 18 : 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 18) {
                    PersonAvatar(name: route.name, size: Device.size(108))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(route.name).font(.title.bold()).foregroundStyle(.white)
                        if let tagline = info.tagline, !tagline.isEmpty {
                            Text(tagline.prefix(1).uppercased() + tagline.dropFirst())
                                .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                        }
                        if !loading {
                            Text("\(movies.count + series.count) titles")
                                .font(.subheadline).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                .padding(.top, 8)
                if let summary = info.summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(expanded ? nil : 4)
                            .frame(maxWidth: 720, alignment: .leading)
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
                        if let page = info.page, let url = URL(string: page) {
                            Button { openURL(url) } label: {
                                Label("Wikipedia", systemImage: "arrow.up.right.square")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                section("Movies", movies)
                section("Series", series)
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if movies.isEmpty && series.isEmpty {
                    ContentUnavailableView("No titles found", systemImage: "person.crop.circle.badge.questionmark")
                }
            }
            .padding(.horizontal, Device.margin)
            .padding(.bottom, 30)
        }
        .background(Color.black)
        .scrollIndicators(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let found = await PersonDirectory.shared.info(for: route.name)
            withAnimation(.easeOut(duration: 0.2)) { info = found }
        }
        .task {
            async let m = Cinemeta.search(type: "movie", route.name)
            async let s = Cinemeta.search(type: "series", route.name)
            let (foundMovies, foundSeries) = await (m, s)
            withAnimation(.easeOut(duration: 0.2)) {
                movies = foundMovies.filter { $0.poster != nil }
                series = foundSeries.filter { $0.poster != nil }
                loading = false
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [MetaPreview]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.title3.bold()).foregroundStyle(.white)
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(items) { item in
                        NavigationLink(value: MetaRef(item)) {
                            PosterCard(title: item.name, subtitle: item.releaseInfo, poster: item.poster, width: Device.size(104))
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }
            }
        }
    }
}

// MARK: - More like this

enum SimilarTitles {
    /// Popular titles of the same kind sharing its genres: both main genres first, then the first.
    static func find(for meta: StremioMeta) async -> [MetaPreview] {
        // With TMDB: its recommendations and similar titles, ranked for you.
        let personal = await Recommender.shared.similar(to: meta)
        if personal.count >= 6 { return personal }
        guard let first = meta.genres.first else { return [] }
        let type = meta.type == "series" ? "series" : "movie"
        let pool = await Cinemeta.catalog(type: type, id: "top", genre: first)
            .filter { $0.id != meta.id && $0.poster != nil }
        let others = Set(meta.genres.dropFirst())
        let close = pool.filter { !others.isDisjoint(with: $0.genres) }
        let rest = pool.filter { others.isDisjoint(with: $0.genres) }
        return Array((close + rest).prefix(20))
    }
}
