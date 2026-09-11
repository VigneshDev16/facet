import SwiftUI
import AppKit

/// Disk-backed thumbnail cache with an in-memory LRU in front of it.
actor ThumbnailStore {
    static let shared = ThumbnailStore()
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 1200
        c.totalCostLimit = 256 * 1024 * 1024
        return c
    }()

    func image(at url: URL) -> NSImage? {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: key, cost: data.count)
        return img
    }

    /// Falls back to decoding the original when no cached thumbnail exists yet.
    func imageDecodingIfNeeded(cached: URL, original: URL, maxPixel: Int) -> NSImage? {
        if let img = image(at: cached) { return img }
        guard let cg = ImageDecoder.decode(url: original, maxPixel: maxPixel) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: cached.path as NSString, cost: cg.width * cg.height * 4)
        return img
    }

    func drop(_ url: URL) { cache.removeObject(forKey: url.path as NSString) }
}

/// Async thumbnail view that cancels its load when scrolled away.
struct ThumbImage<Placeholder: View>: View {
    let cached: URL
    var original: URL?
    var maxPixel: Int = Tuning.thumbMaxPixel
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: cached.path) {
            let orig = original
            let px = maxPixel
            let url = cached
            let loaded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                if let orig {
                    return await ThumbnailStore.shared.imageDecodingIfNeeded(cached: url, original: orig, maxPixel: px)
                }
                return await ThumbnailStore.shared.image(at: url)
            }.value
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.12)) { image = loaded }
        }
    }
}

extension ThumbImage where Placeholder == AnyView {
    init(cached: URL, original: URL? = nil, maxPixel: Int = Tuning.thumbMaxPixel) {
        self.init(cached: cached, original: original, maxPixel: maxPixel) {
            AnyView(Rectangle().fill(Color.secondary.opacity(0.12)))
        }
    }
}
