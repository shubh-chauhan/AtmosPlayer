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

/// A remote image that fills its frame. `maxPixel` is the longest side it is decoded to.
struct RemoteImage: View {
    let url: String?
    var maxPixel: Int = 400
    var placeholderSymbol: String = "film"

    @State private var image: UIImage?

    private var parsed: URL? { url.flatMap(URL.init(string:)) }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Color.white.opacity(0.08)
                Image(systemName: placeholderSymbol)
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .task(id: url) {
            guard let parsed else {
                image = nil
                return
            }
            if let hit = ImagePipeline.shared.cached(parsed, maxPixel: maxPixel) {
                image = hit
                return
            }
            image = nil
            let loaded = await ImagePipeline.shared.image(parsed, maxPixel: maxPixel)
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
        }
    }
}
