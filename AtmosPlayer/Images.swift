import SwiftUI
import UIKit
import ImageIO
import Vision

/// Poster / backdrop loader built for smooth scrolling: images are downloaded once (URLCache on
/// disk), decoded and downscaled off the main thread to the size they are shown at, and kept in
/// a memory cache. SwiftUI's AsyncImage decodes full-size images and caches nothing, which is
/// what makes poster rows stutter.
actor ImagePipeline {
    static let shared = ImagePipeline()

    // NSCache is thread-safe, so the synchronous cache check can skip the actor hop.
    private nonisolated(unsafe) let memory = NSCache<NSString, UIImage>()
    private nonisolated(unsafe) let focusMemory = NSCache<NSString, FocusBox>()
    private var focusInflight: [String: Task<ArtworkFocus, Never>] = [:]
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private let session: URLSession

    init() {
        memory.countLimit = 400
        memory.totalCostLimit = 120 * 1024 * 1024
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

    nonisolated func cachedFocus(_ url: URL) -> ArtworkFocus? {
        focusMemory.object(forKey: url.absoluteString as NSString)?.focus
    }

    /// Where the subject and any printed lettering sit in an image, worked out once per URL.
    func focus(of image: UIImage, url: URL) async -> ArtworkFocus {
        let key = url.absoluteString
        if let hit = focusMemory.object(forKey: key as NSString) { return hit.focus }
        if let running = focusInflight[key] { return await running.value }
        let task = Task<ArtworkFocus, Never>.detached(priority: .utility) { ArtworkFocus.analyse(image) }
        focusInflight[key] = task
        let result = await task.value
        focusInflight[key] = nil
        focusMemory.setObject(FocusBox(result), forKey: key as NSString)
        return result
    }

    /// Loads (and for wide artwork shown cropped, analyses) an image before it scrolls into
    /// view, so it appears in its first frame.
    func prefetch(_ raw: String?, maxPixel: Int, focused: Bool = false) async {
        guard let url = ArtworkURL.best(raw, maxPixel: maxPixel),
              let image = await image(url, maxPixel: maxPixel), focused else { return }
        _ = await focus(of: image, url: url)
    }

    func image(_ url: URL, maxPixel: Int) async -> UIImage? {
        let key = Self.key(url, maxPixel)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let running = inflight[key] { return await running.value }

        let session = self.session
        let task = Task<UIImage?, Never>.detached(priority: .utility) {
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            return Self.downsample(data, maxPixel: maxPixel)
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        if let result {
            let cost = Int(result.size.width * result.size.height * result.scale * result.scale * 4)
            memory.setObject(result, forKey: key as NSString, cost: cost)
        }
        return result
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
    static func logo(forMetaId id: String?) -> String? {
        guard let id, id.hasPrefix("tt") else { return nil }
        return "https://images.metahub.space/logo/medium/\(id)/img"
    }

    static func best(_ raw: String?, maxPixel: Int) -> URL? {
        guard var text = raw, !text.isEmpty else { return nil }
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

private final class FocusBox {
    let focus: ArtworkFocus
    init(_ focus: ArtworkFocus) { self.focus = focus }
}

/// Where to crop a wide image shown in a narrower frame (a 16:9 backdrop on the tall Home card
/// or title page). Cutting the middle out blindly can land on an empty wall beside the actor,
/// or on half of the title lettering some backdrops have printed on them, right behind the
/// logo. Vision finds what draws the eye and any text; the crop keeps the first and avoids
/// the second.
struct ArtworkFocus: Sendable, Equatable {
    /// Normalised boxes (0…1, any vertical origin: only overlap matters).
    var salient: [CGRect]
    var text: [CGRect]

    static func analyse(_ image: UIImage) -> ArtworkFocus {
        guard let cgImage = image.cgImage else { return ArtworkFocus(salient: [], text: []) }
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let text = VNDetectTextRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        try? handler.perform([saliency, text])
        let salient = (saliency.results?.first?.salientObjects ?? []).map(\.boundingBox)
        // Small print (credits, a watermark) is fine to keep; title lettering is what clashes.
        let words = (text.results ?? []).map(\.boundingBox).filter { $0.height > 0.04 }
        return ArtworkFocus(salient: salient, text: words)
    }

    /// The horizontal centre (0…1 of the image width) to crop around when only `keep` of the
    /// width fits.
    func centre(keep: CGFloat) -> CGFloat {
        guard keep < 0.98, keep > 0 else { return 0.5 }
        func area(_ boxes: [CGRect], _ window: CGRect) -> CGFloat {
            boxes.reduce(0) { sum, box in
                let part = box.intersection(window)
                return part.isNull ? sum : sum + part.width * part.height
            }
        }
        let half = keep / 2
        let steps = 48
        var best: CGFloat = 0.5
        var bestScore = -CGFloat.infinity
        for step in 0...steps {
            let centre = half + (1 - keep) * CGFloat(step) / CGFloat(steps)
            let window = CGRect(x: centre - half, y: -1, width: keep, height: 3)
            // Text costs more than a subject earns, so lettering is left out when it can be;
            // a slight pull to the middle decides when nothing stands out.
            let score = area(salient, window) - 3 * area(text, window) - 0.02 * abs(centre - 0.5)
            if score > bestScore { bestScore = score; best = centre }
        }
        return best
    }

    /// How far to slide an image (filling `frame`, centred) so the crop lands on the subject.
    static func shift(image: CGSize, frame: CGSize, focus: ArtworkFocus?) -> CGFloat {
        guard let focus, image.width > 0, image.height > 0, frame.width > 0, frame.height > 0 else { return 0 }
        let shown = image.width * max(frame.width / image.width, frame.height / image.height)
        guard shown > frame.width + 1 else { return 0 }
        return (0.5 - focus.centre(keep: frame.width / shown)) * shown
    }
}

/// A remote image that fills its frame (cropping, never growing past it). `maxPixel` is the
/// longest side, in pixels, it is decoded to: about the shown size in points times three.
/// `focused` crops a too-wide image around its subject instead of its middle.
struct RemoteImage: View {
    let url: String?
    var maxPixel: Int = 400
    var placeholderSymbol: String = "film"
    var focused = false

    @State private var image: UIImage?
    @State private var focus: ArtworkFocus?

    init(url: String?, maxPixel: Int = 400, placeholderSymbol: String = "film", focused: Bool = false) {
        self.url = url
        self.maxPixel = maxPixel
        self.placeholderSymbol = placeholderSymbol
        self.focused = focused
        // Already decoded: show it in the first frame instead of flashing the placeholder.
        if let resolved = ArtworkURL.best(url, maxPixel: maxPixel) {
            let hit = ImagePipeline.shared.cached(resolved, maxPixel: maxPixel)
            let spot = focused ? ImagePipeline.shared.cachedFocus(resolved) : nil
            // A focused image waits for its crop, so it never jumps sideways once shown.
            if !focused || spot != nil {
                _image = State(initialValue: hit)
                _focus = State(initialValue: spot)
            }
        }
    }

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Group {
                        if focused {
                            GeometryReader { geo in
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .offset(x: ArtworkFocus.shift(image: image.size, frame: geo.size, focus: focus))
                            }
                        } else {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        }
                    }
                    .transition(.opacity)
                } else {
                    ZStack {
                        Color.white.opacity(0.08)
                        if !placeholderSymbol.isEmpty {
                            Image(systemName: placeholderSymbol)
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                }
            }
            .clipped()
            .task(id: url) {
                guard let resolved = ArtworkURL.best(url, maxPixel: maxPixel) else {
                    image = nil
                    return
                }
                if let hit = ImagePipeline.shared.cached(resolved, maxPixel: maxPixel), image === hit,
                   !focused || focus != nil {
                    return
                }
                guard let loaded = await ImagePipeline.shared.image(resolved, maxPixel: maxPixel),
                      !Task.isCancelled else { return }
                let spot = focused ? await ImagePipeline.shared.focus(of: loaded, url: resolved) : nil
                guard !Task.isCancelled else { return }
                if image === loaded && focus == spot { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    image = loaded
                    focus = spot
                }
            }
    }
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
                        Color.white.opacity(0.08)
                        Image(systemName: "film").foregroundStyle(.white.opacity(0.3))
                    }
                }
            }
            .clipped()
            .task(id: candidates) {
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
