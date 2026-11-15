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
    static func best(_ raw: String?, maxPixel: Int) -> URL? {
        guard var text = raw, !text.isEmpty else { return nil }
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
    let url: String?
    var maxPixel: Int = 400
    var placeholderSymbol: String = "film"

    @State private var image: UIImage?

    init(url: String?, maxPixel: Int = 400, placeholderSymbol: String = "film") {
        self.url = url
        self.maxPixel = maxPixel
        self.placeholderSymbol = placeholderSymbol
        // Already decoded: show it in the first frame instead of flashing the placeholder.
        if let resolved = ArtworkURL.best(url, maxPixel: maxPixel) {
            _image = State(initialValue: ImagePipeline.shared.cached(resolved, maxPixel: maxPixel))
        }
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
                if let hit = ImagePipeline.shared.cached(resolved, maxPixel: maxPixel) {
                    if image !== hit { image = hit }
                    return
                }
                let loaded = await ImagePipeline.shared.image(resolved, maxPixel: maxPixel)
                if !Task.isCancelled, let loaded {
                    withAnimation(.easeOut(duration: 0.2)) { image = loaded }
                }
            }
    }
}
