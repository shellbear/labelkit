import CoreGraphics
import Foundation

/// On-demand sidebar thumbnails with a hard byte budget.
///
/// - decode happens on background tasks, capped at `maxConcurrentDecodes`
///   (unbounded decode task explosion during a scroll fling is the classic
///   10k-image failure mode)
/// - in-flight requests are deduplicated by URL
/// - callers use SwiftUI `.task(id:)` so scrolled-away rows cancel; the
///   provider re-checks cancellation before decoding
/// - NSCache LRU-evicts at the byte budget and reacts to memory pressure
public actor ThumbnailProvider {
    public static let shared = ThumbnailProvider()

    private let cache = NSCache<NSURL, CGImageBox>()
    private var inFlight: [URL: Task<CGImage?, Never>] = [:]
    private var activeDecodes = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let maxConcurrentDecodes: Int

    final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    public init(byteBudget: Int = 128 << 20, maxConcurrentDecodes: Int = 4) {
        cache.totalCostLimit = byteBudget
        self.maxConcurrentDecodes = maxConcurrentDecodes
    }

    public func thumbnail(for url: URL, maxPixel: CGFloat) async -> CGImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached.image }

        let task = inFlight[url] ?? Task<CGImage?, Never> { [self] in
            await acquireSlot()
            defer { releaseSlot() }
            guard !Task.isCancelled else { return nil }
            let image = await Task.detached(priority: .utility) {
                ImageDownsampler.decode(url: url, maxPixel: maxPixel, preferEmbedded: true)
            }.value
            if let image {
                self.store(image, for: url)
            }
            return image
        }
        inFlight[url] = task

        // The old code awaited an unstructured task, so a row scrolling away
        // (SwiftUI `.task(id:)` cancellation) never reached the decode — only
        // the 4-slot semaphore throttled a fling. Forward cancellation to the
        // task so a still-queued decode is dropped before it starts.
        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        inFlight[url] = nil
        return image
    }

    private func store(_ image: CGImage, for url: URL) {
        cache.setObject(CGImageBox(image), forKey: url as NSURL, cost: image.bytesPerRow * image.height)
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
