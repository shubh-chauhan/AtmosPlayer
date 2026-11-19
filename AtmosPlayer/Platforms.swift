import SwiftUI

// MARK: - Streaming platforms
//
// Where a title is licensed (Netflix, Prime Video…), from TMDB's watch providers, whose data
// comes from JustWatch. This is about licensing only: it never says whether your addons have
// a stream for a title, and the app never presents it as if it did.

struct StreamingPlatform: Identifiable, Hashable {
    let id: String
    let name: String
    /// TMDB/JustWatch provider ids (some services have more than one, by region).
    let providers: String
    /// TMDB's network id for the service's own series ("Originals").
    let network: Int
    let colors: [Color]

    static let all: [StreamingPlatform] = [
        StreamingPlatform(id: "netflix", name: "Netflix", providers: "8", network: 213,
                          colors: [Color(red: 0.6, green: 0.02, blue: 0.05), Color(red: 0.2, green: 0, blue: 0.02)]),
        StreamingPlatform(id: "prime", name: "Prime Video", providers: "9|119", network: 1024,
                          colors: [Color(red: 0.0, green: 0.45, blue: 0.75), Color(red: 0.02, green: 0.12, blue: 0.25)]),
        StreamingPlatform(id: "appletv", name: "Apple TV+", providers: "350", network: 2552,
                          colors: [Color(white: 0.32), Color(white: 0.08)]),
        StreamingPlatform(id: "disney", name: "Disney+", providers: "337", network: 2739,
                          colors: [Color(red: 0.05, green: 0.2, blue: 0.55), Color(red: 0.02, green: 0.05, blue: 0.2)]),
        StreamingPlatform(id: "max", name: "Max", providers: "1899|384", network: 3186,
                          colors: [Color(red: 0.2, green: 0.1, blue: 0.6), Color(red: 0.05, green: 0.02, blue: 0.2)]),
        StreamingPlatform(id: "hulu", name: "Hulu", providers: "15", network: 453,
                          colors: [Color(red: 0.05, green: 0.55, blue: 0.3), Color(red: 0.01, green: 0.15, blue: 0.08)]),
        StreamingPlatform(id: "paramount", name: "Paramount+", providers: "531", network: 4330,
                          colors: [Color(red: 0.0, green: 0.3, blue: 0.85), Color(red: 0.0, green: 0.08, blue: 0.3)]),
        StreamingPlatform(id: "peacock", name: "Peacock", providers: "386", network: 3353,
                          colors: [Color(white: 0.25), Color(red: 0.1, green: 0.05, blue: 0.2)]),
    ]

    /// Everything currently on the service in your region (movies; the page can switch to series).
    var catalogRoute: CatalogRoute {
        CatalogRoute(title: name, type: "movie", catalogId: "", allowsTypeSwitch: true,
                     source: .tmdbDiscover(kind: "movie", query: [
                        "with_watch_providers": providers, "watch_region": TMDB.region,
                        "with_watch_monetization_types": "flatrate|free|ads",
                        "sort_by": "popularity.desc",
                     ]))
    }

    /// The service's own series, popular first.
    var originals: CatalogSource {
        .tmdbDiscover(kind: "tv", query: ["with_networks": String(network), "sort_by": "popularity.desc",
                                          "vote_count.gte": "50"])
    }
}

/// TMDB's logo (fetched by CI from TMDB's brand page), or its name when the build has none.
struct TMDBMark: View {
    var height: CGFloat = 12

    var body: some View {
        if UIImage(named: "TMDBLogo") != nil {
            Image("TMDBLogo").resizable().scaledToFit().frame(height: height)
                .accessibilityLabel("TMDB")
        } else {
            Text("TMDB")
                .font(.system(size: height * 0.85, weight: .heavy))
                .foregroundStyle(Color(red: 0.56, green: 0.81, blue: 0.63))
        }
    }
}

/// "Where to Watch": the services a title streams, rents or sells on in your region.
struct WhereToWatch: View {
    let availability: MetaExtras.Availability
    @Environment(\.openURL) private var openURL

    private var groups: [(String, [MetaExtras.Offer])] {
        let stream = availability.offers.filter { [.subscription, .free, .ads].contains($0.kind) }
        let rent = availability.offers.filter { $0.kind == .rent }
        let buy = availability.offers.filter { $0.kind == .buy }
        return [("Stream", stream), ("Rent", rent), ("Buy", buy)].filter { !$0.1.isEmpty }
    }

    private var regionName: String {
        Locale.current.localizedString(forRegionCode: availability.region) ?? availability.region
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where to Watch")
                .font(.title3.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, Device.margin)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(groups, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.0.uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white.opacity(0.5))
                            HStack(spacing: 10) {
                                ForEach(unique(group.1), id: \.providerId) { offer in
                                    VStack(spacing: 5) {
                                        RemoteImage(url: offer.logo, maxPixel: 150, placeholderSymbol: "play.tv")
                                            .frame(width: 44, height: 44)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        Text(offer.name)
                                            .font(.caption2)
                                            .foregroundStyle(.white.opacity(0.75))
                                            .lineLimit(1)
                                            .frame(width: 64)
                                    }
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Device.margin)
            }
            .scrollIndicators(.hidden)
            // Licensing, not streams: said plainly, with the sources TMDB's terms ask to credit.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Licensed availability in \(regionName), from JustWatch via")
                TMDBMark(height: 10)
                Text("· not whether your addons have a stream.")
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, Device.margin)
            if let link = availability.link, let url = URL(string: link) {
                Button("See all options") { openURL(url) }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, Device.margin)
            }
        }
    }

    private func unique(_ offers: [MetaExtras.Offer]) -> [MetaExtras.Offer] {
        var seen = Set<Int>()
        return offers.filter { seen.insert($0.providerId).inserted }
    }
}

/// Discover's "Streaming Services" tiles: what's on each, in your region.
struct PlatformBrowser: View {
    private let columns = [GridItem(.adaptive(minimum: Device.size(150)), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Streaming Services").font(.title3.bold()).foregroundStyle(.white)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(StreamingPlatform.all) { platform in
                    NavigationLink(value: platform.catalogRoute) {
                        Text(platform.name)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .background(LinearGradient(colors: platform.colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(CardButtonStyle())
                }
            }
            HStack(spacing: 5) {
                Text("What each service offers where you are, from JustWatch via")
                TMDBMark(height: 9)
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, Device.margin)
    }
}
