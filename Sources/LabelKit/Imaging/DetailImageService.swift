import CoreGraphics
import Foundation

/// Shared decoder + LRU cache for the ONE full-detail image on the canvas.
///
/// Two properties the sidebar's thumbnail path already had but the detail
/// path lacked, and which the 10k-image profile showed were missing:
///
/// - **Bounded concurrency.** Arrow-key spam used to fan out one full-size
///   decode per keypress with no ceiling (each `CanvasView` made its own
///   loader and nothing cancelled the losers), spiking to a ~830 MB peak
///   footprint. Decodes now pass through a `maxConcurrentDecodes` gate, and a
///   caller whose task is cancelled before its slot frees never decodes.
/// - **A small per-URL cache** keyed at the largest resolution decoded so
///   far, so navigating back to a recently viewed image is instant instead
///   of a fresh from-disk decode. LRU-evicted at the byte budget and
///   memory-pressure reactive, like the thumbnail cache.
public actor DetailImageService {
    public static let shared = DetailImageService()

    private let cache = NSCache<NSURL, Cached>()
    private var activeDecodes = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let maxConcurrentDecodes: Int

    final class Cached {
        let image: CGImage
        let maxDimension: CGFloat
        init(_ image: CGImage, maxDimension: CGFloat) {
            self.image = image
            self.maxDimension = maxDimension
        }
    }

    public init(byteBudget: Int = 96 << 20, maxConcurrentDecodes: Int = 3) {
        cache.totalCostLimit = byteBudget
        self.maxConcurrentDecodes = maxConcurrentDecodes
    }

    /// A bitmap for `url` at least `maxPixel` on its longest edge (clamped to
    /// the image's native `nominalMax`), decoding only if the cache lacks a
    /// large-enough one. Returns nil if the surrounding task is cancelled
    /// before the decode starts — the caller (a superseded navigation) is
    /// gone and its bitmap would be discarded anyway.
    public func image(url: URL, maxPixel: CGFloat, nominalMax: CGFloat) async -> CGImage? {
        let target = min(nominalMax, max(maxPixel, 64))
        if let hit = cached(url: url, target: target, nominalMax: nominalMax) { return hit }
        if Task.isCancelled { return nil }

        await acquireSlot()
        defer { releaseSlot() }
        if Task.isCancelled { return nil }
        // Another request may have decoded the same url while we waited.
        if let hit = cached(url: url, target: target, nominalMax: nominalMax) { return hit }

        let decoded = await Task.detached(priority: .userInitiated) {
            ImageDownsampler.decode(url: url, maxPixel: target)
        }.value
        guard let decoded else { return nil }
        store(decoded, for: url)
        return decoded
    }

    /// A cached bitmap for `url` if one large enough already exists, without
    /// ever decoding. Lets the loader show a revisited image instantly while
    /// debouncing only the expensive cache-miss decodes.
    public func cachedImage(url: URL, maxPixel: CGFloat, nominalMax: CGFloat) -> CGImage? {
        cached(url: url, target: min(nominalMax, max(maxPixel, 64)), nominalMax: nominalMax)
    }

    /// Warm the cache for a soon-to-be-shown neighbor at low priority, so a
    /// deliberate step lands on a hit instead of a cold decode. No-op if
    /// already cached or if the surrounding task was cancelled (a reversed or
    /// superseded navigation). Shares the decode gate but at `.utility`, so
    /// the visible `.userInitiated` decode wins contention.
    public func prefetch(url: URL, maxPixel: CGFloat, nominalMax: CGFloat) async {
        let target = min(nominalMax, max(maxPixel, 64))
        if cached(url: url, target: target, nominalMax: nominalMax) != nil { return }
        if Task.isCancelled { return }
        await acquireSlot()
        defer { releaseSlot() }
        if Task.isCancelled { return }
        if cached(url: url, target: target, nominalMax: nominalMax) != nil { return }
        let decoded = await Task.detached(priority: .utility) {
            ImageDownsampler.decode(url: url, maxPixel: target)
        }.value
        if let decoded { store(decoded, for: url) }
    }

    private func cached(url: URL, target: CGFloat, nominalMax: CGFloat) -> CGImage? {
        guard let hit = cache.object(forKey: url as NSURL) else { return nil }
        // Sharp enough if it already covers the target (or is native-res).
        return hit.maxDimension + 0.5 >= min(target, nominalMax) ? hit.image : nil
    }

    private func store(_ image: CGImage, for url: URL) {
        let dimension = CGFloat(max(image.width, image.height))
        // Keep the sharpest bitmap seen for a url; a smaller re-decode (zoom
        // out) must not evict a larger cached one.
        if let existing = cache.object(forKey: url as NSURL), existing.maxDimension >= dimension {
            return
        }
        cache.setObject(Cached(image, maxDimension: dimension),
                        forKey: url as NSURL, cost: image.bytesPerRow * image.height)
    }

    private func acquireSlot() async {
        if activeDecodes < maxConcurrentDecodes {
            activeDecodes += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        activeDecodes += 1
    }

    private nonisolated func releaseSlot() {
        Task { await self.release() }
    }

    private func release() {
        activeDecodes -= 1
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        }
    }
}
