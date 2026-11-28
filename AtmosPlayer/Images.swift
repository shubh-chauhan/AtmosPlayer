import SwiftUI
import UIKit
import ImageIO

/// Poster / backdrop loader built for smooth scrolling: images are downloaded once (URLCache on
/// disk), decoded and downscaled off the main thread to the size they are shown at, and kept in
/// a memory cache. SwiftUI's AsyncImage decodes full-size images and caches nothing, which is
/// what makes poster rows stutter.
actor ImagePipeline {
    static let shared = ImagePipeline()

    // NSCache is thread-safe, so the synchronous cache check can skip the actor hop.
    private nonisolated(unsafe) let memory = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    /// Addresses that just failed, skipped for a couple of minutes so the next candidate in a
    /// card's list is tried at once instead of waiting on the same failure again.
    private var failed: [String: Date] = [:]
    private let session: URLSession

    init() {
        memory.countLimit = 400
        // iPad heroes decode bigger, and iPads have the memory for it.
        memory.totalCostLimit = (Device.isPad ? 220 : 120) * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 400 * 1024 * 1024,
                                   diskPath: "images")
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
    }

    /// Empties the memory and disk caches (Settings › Storage).
    nonisolated func clearAll() {
        memory.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    nonisolated func cached(_ url: URL, maxPixel: Int) -> UIImage? {
        memory.object(forKey: Self.key(url, maxPixel) as NSString)
    }

    /// Loads an image before it scrolls into view, so it appears in its first frame.
    func prefetch(_ raw: String?, maxPixel: Int) async {
        guard let url = ArtworkURL.best(raw, maxPixel: maxPixel) else { return }
        _ = await image(url, maxPixel: maxPixel)
    }

    func image(_ url: URL, maxPixel: Int) async -> UIImage? {
        let key = Self.key(url, maxPixel)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let running = inflight[key] { return await running.value }
        if let when = failed[key], Date().timeIntervalSince(when) < 120 { return nil }

        let session = self.session
        let task = Task<UIImage?, Never>.detached(priority: .utility) {
            // Saved copies older than a month are fetched again (artwork does change); the old
            // copy is still used when the network fails.
            let saved = session.configuration.urlCache?.cachedResponse(for: URLRequest(url: url))
            if let saved, Self.isStale(saved.response) {
                var fresh = URLRequest(url: url)
                fresh.cachePolicy = .reloadIgnoringLocalCacheData
                if let (data, response) = try? await session.data(for: fresh),
                   ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400,
                   let image = Self.downsample(data, maxPixel: maxPixel) {
                    return image
                }
                return Self.downsample(saved.data, maxPixel: maxPixel)
            }
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            return Self.downsample(data, maxPixel: maxPixel)
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        if let result {
            let cost = Int(result.size.width * result.size.height * result.scale * result.scale * 4)
            memory.setObject(result, forKey: key as NSString, cost: cost)
            failed[key] = nil
        } else {
            failed[key] = Date()
        }
        return result
    }

    /// How long a downloaded image is used before it's checked again.
    static let maxAge: TimeInterval = 30 * 24 * 3600

    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    /// Older than `maxAge`, going by the server's Date header (no header: kept).
    nonisolated static func isStale(_ response: URLResponse, now: Date = Date()) -> Bool {
        guard let text = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Date"),
              let date = httpDate.date(from: text) else { return false }
        return now.timeIntervalSince(date) > maxAge
    }

    private static func key(_ url: URL, _ maxPixel: Int) -> String {
        "\(maxPixel)|\(url.absoluteString)"
    }

    private static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Asks image services for the size the app actually needs. Cinemeta catalogs link the small
/// poster (300×450), which looks soft at three pixels per point; the same image exists at
/// 500×750 ("medium") and 780×1170 ("large").
enum ArtworkURL {
    /// The title's logo from MetaHub (what Cinemeta itself lists), for IMDb ids.
    /// A title's posters, best first: TMDB's when the title came with one, then MetaHub's (the
    /// art Cinemeta lists, at the size needed), then whatever its addon gave.
    static func posters(id: String?, poster: String?) -> [String] {
        ranked(id: id, own: poster) { "https://images.metahub.space/poster/medium/\($0)/img" }
    }

    /// What a hero tries when TMDB's art isn't there: posters first for a tall frame (a backdrop
    /// cropped that narrow is mostly blown-up middle), backdrops first for a wide one.
    static func heroFallbacks(id: String?, background: String?, poster: String?, portrait: Bool) -> [String] {
        let wide = backdrops(id: id, background: background, poster: poster)
        guard portrait else { return wide }
        var seen = Set<String>()
        return (posters(id: id, poster: poster) + wide).filter { seen.insert($0).inserted }
    }

    /// Backdrops ranked the same way, with the poster last so a card is never left empty.
    static func backdrops(id: String?, background: String?, poster: String? = nil) -> [String] {
        var list = ranked(id: id, own: background) { "https://images.metahub.space/background/medium/\($0)/img" }
        if let poster, !list.contains(poster) { list.append(poster) }
        return list
    }

    private static func ranked(id: String?, own: String?, metaHub: (String) -> String) -> [String] {
        var list: [String] = []
        if let own, own.contains("image.tmdb.org") { list.append(own) }
        if let id, id.hasPrefix("tt") { list.append(metaHub(id)) }
        // Cinemeta's own address is MetaHub's at another size: already in the list.
        if let own, !list.contains(own), !(own.contains("images.metahub.space") && id?.hasPrefix("tt") == true) {
            list.append(own)
        }
        return list
    }

    static func logo(forMetaId id: String?) -> String? {
        guard let id, id.hasPrefix("tt") else { return nil }
        return "https://images.metahub.space/logo/medium/\(id)/img"
    }

    static func best(_ raw: String?, maxPixel: Int) -> URL? {
        guard var text = raw, !text.isEmpty else { return nil }
        // TMDB's w780 / w1280 are soft when a frame needs more (an iPad hero is ~2400 px tall):
        // the full-size file is asked for then, and decoded down to what's needed.
        if text.contains("image.tmdb.org/t/p/") {
            for (size, width) in [("/w780/", 780), ("/w1280/", 1280)] where text.contains(size) && maxPixel > width * 6 / 5 {
                text = text.replacingOccurrences(of: size, with: "/original/")
            }
        }
        // IMDb artwork (from search): ask Amazon's image server for the size needed, not the original.
        if text.contains("media-amazon.com/images/"), let range = text.range(of: "._V1_") {
            text = String(text[..<range.lowerBound]) + "._V1_QL80_UX\(min(maxPixel, 1600))_.jpg"
        }
        if text.contains("images.metahub.space/poster/") {
            let size = maxPixel > 800 ? "large" : "medium"
            for tier in ["small", "medium", "large"] where tier != size {
                text = text.replacingOccurrences(of: "/poster/\(tier)/", with: "/poster/\(size)/")
            }
        }
        return URL(string: text)
    }
}

/// A remote image that fills its frame (cropping, never growing past it). `maxPixel` is the
/// longest side, in pixels, it is decoded to: about the shown size in points times three.
struct RemoteImage: View {
    /// Addresses best first: when one doesn't load, the next is tried.
    let candidates: [String]
    /// Asked last, when none of the addresses load.
    var lookup: ArtworkLookup?
    var maxPixel: Int = 400
    var placeholderSymbol: String = "film"

    @State private var image: UIImage?
    /// Still looking: the placeholder pulses instead of showing the "no picture" symbol.
    @State private var loading = false

    init(url: String?, maxPixel: Int = 400, placeholderSymbol: String = "film") {
        self.init(candidates: url.map { [$0] } ?? [], maxPixel: maxPixel, placeholderSymbol: placeholderSymbol)
    }

    init(candidates: [String], lookup: ArtworkLookup? = nil, maxPixel: Int = 400, placeholderSymbol: String = "film") {
        self.candidates = candidates
        self.lookup = lookup
        self.maxPixel = maxPixel
        self.placeholderSymbol = placeholderSymbol
        // Already decoded: show it in the first frame instead of flashing the placeholder.
        for candidate in candidates {
            if let resolved = ArtworkURL.best(candidate, maxPixel: maxPixel),
               let hit = ImagePipeline.shared.cached(resolved, maxPixel: maxPixel) {
                _image = State(initialValue: hit)
                break
            }
        }
    }

    private struct LoadKey: Hashable {
        let candidates: [String]
        let lookup: ArtworkLookup?
    }

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    ZStack {
                        LoadingShade(active: loading)
                        if !placeholderSymbol.isEmpty && !loading {
                            Image(systemName: placeholderSymbol)
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                }
            }
            .clipped()
            .task(id: LoadKey(candidates: candidates, lookup: lookup)) {
                loading = image == nil && !(candidates.isEmpty && lookup == nil)
                defer { loading = false }
                if candidates.isEmpty && lookup == nil {
                    image = nil
                    return
                }
                for candidate in candidates {
                    guard let resolved = ArtworkURL.best(candidate, maxPixel: maxPixel) else { continue }
                    if let hit = ImagePipeline.shared.cached(resolved, maxPixel: maxPixel) {
                        if image !== hit { image = hit }
                        return
                    }
                    if let loaded = await ImagePipeline.shared.image(resolved, maxPixel: maxPixel) {
                        if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { image = loaded } }
                        return
                    }
                    if Task.isCancelled { return }
                }
                // None loaded: TMDB's art for the title, when it has some.
                guard let lookup, let found = await MetaResolver.artwork(lookup), !candidates.contains(found),
                      let resolved = ArtworkURL.best(found, maxPixel: maxPixel),
                      let loaded = await ImagePipeline.shared.image(resolved, maxPixel: maxPixel),
                      !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
    }
}

/// A grey stand-in that pulses gently while a picture is on its way.
struct LoadingShade: View {
    var active = true
    @State private var dim = false

    var body: some View {
        Color.white.opacity(active && dim ? 0.05 : 0.09)
            .animation(active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: dim)
            .onAppear { dim = true }
            .accessibilityHidden(true)
    }
}

/// The last place a picture is looked for when none of its addresses load: TMDB's art for
/// the title (IMDb and anime ids).
struct ArtworkLookup: Hashable {
    enum Kind: Hashable { case poster, backdrop }
    let id: String
    let type: String
    let kind: Kind
}

extension ArtworkURL {
    /// Landscape artwork for a video, best first: its own still or backdrop, then Cinemeta's
    /// episode still and backdrop for IMDb titles, and the poster last.
    static func landscapeCandidates(for ref: VideoRef) -> [String] {
        var list: [String] = []
        if let background = ref.background, !background.contains("/poster/") { list.append(background) }
        if ref.metaId.hasPrefix("tt") {
            let parts = ref.videoId.split(separator: ":")
            if parts.count == 3, Int(parts[1]) != nil, Int(parts[2]) != nil {
                list.append("https://episodes.metahub.space/\(parts[0])/\(parts[1])/\(parts[2])/w780.jpg")
            }
            list.append("https://images.metahub.space/background/medium/\(ref.metaId)/img")
        }
        if let background = ref.background { list.append(background) }
        if let poster = ref.poster { list.append(poster) }
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }
}

/// A 16:9 picture from the first candidate that loads. A portrait image (a poster) is shown
/// whole over a blurred copy of itself instead of being cropped to a strip.
struct LandscapeArtwork: View {
    let candidates: [String]
    var maxPixel: Int = 1000

    @State private var image: UIImage?
    /// Still looking: a pulsing stand-in, not the "no picture" symbol.
    @State private var loading = false

    init(candidates: [String], maxPixel: Int = 1000) {
        self.candidates = candidates
        self.maxPixel = maxPixel
        for candidate in candidates {
            if let url = ArtworkURL.best(candidate, maxPixel: maxPixel),
               let hit = ImagePipeline.shared.cached(url, maxPixel: maxPixel) {
                _image = State(initialValue: hit)
                break
            }
        }
    }

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    if image.size.height > image.size.width {
                        ZStack {
                            Image(uiImage: image).resizable().scaledToFill()
                                .blur(radius: 18).opacity(0.7)
                            Image(uiImage: image).resizable().scaledToFit()
                        }
                        .transition(.opacity)
                    } else {
                        Image(uiImage: image).resizable().scaledToFill()
                            .transition(.opacity)
                    }
                } else {
                    ZStack {
                        LoadingShade(active: loading)
                        if !loading {
                            Image(systemName: "film").foregroundStyle(.white.opacity(0.3))
                        }
                    }
                }
            }
            .clipped()
            .task(id: candidates) {
                loading = image == nil && !candidates.isEmpty
                defer { loading = false }
                for candidate in candidates {
                    guard let url = ArtworkURL.best(candidate, maxPixel: maxPixel) else { continue }
                    if let hit = ImagePipeline.shared.cached(url, maxPixel: maxPixel) {
                        if image !== hit { image = hit }
                        return
                    }
                    if let loaded = await ImagePipeline.shared.image(url, maxPixel: maxPixel) {
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.2)) { image = loaded }
                        return
                    }
                    if Task.isCancelled { return }
                }
            }
    }
}
