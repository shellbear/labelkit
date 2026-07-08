import CoreGraphics
import Foundation
import Observation

/// Publishes the currently displayed image at display resolution, backed by
/// the shared `DetailImageService` (bounded-concurrency decode + per-URL
/// cache). Callers state how many physical pixels the image currently
/// occupies (`neededMaxPixel`); a re-decode is requested only when the
/// bitmap is meaningfully smaller (1.25× hysteresis, so continuous zoom
/// doesn't thrash), never past native resolution.
@Observable
@MainActor
public final class DetailImageLoader {
    public private(set) var image: CGImage?

    private var currentURL: URL?
    private var nominalMaxDimension: CGFloat = 0
    private var decodedMaxDimension: CGFloat = 0
    private var requestTask: Task<Void, Never>?
    private let service: DetailImageService

    public init(service: DetailImageService = .shared) {
        self.service = service
    }

    /// Show `url` (dropping any previous image) at `neededMaxPixel`.
    /// `immediate` false (a held-arrow scrub) debounces the cache-miss decode.
    public func display(url: URL, imageSize: CGSize, neededMaxPixel: CGFloat, immediate: Bool = true) {
        if url != currentURL {
            currentURL = url
            image = nil
            decodedMaxDimension = 0
            nominalMaxDimension = max(imageSize.width, imageSize.height)
        }
        ensure(neededMaxPixel, immediate: immediate)
    }

    /// Re-decode if the displayed physical size outgrew the decoded bitmap.
    public func ensure(_ neededMaxPixel: CGFloat, immediate: Bool = true) {
        guard let url = currentURL, nominalMaxDimension > 0 else { return }
        let target = min(nominalMaxDimension, max(neededMaxPixel, 64))
        if image != nil, decodedMaxDimension >= min(nominalMaxDimension, target / 1.25),
           decodedMaxDimension >= target * 0.8 || decodedMaxDimension >= nominalMaxDimension {
            return
        }
        let nominal = nominalMaxDimension
        requestTask?.cancel()
        requestTask = Task { [weak self, service] in
            // Already decoded (a revisit): publish instantly, no debounce.
            if let cached = await service.cachedImage(url: url, maxPixel: target, nominalMax: nominal) {
                self?.publish(cached, from: url)
                return
            }
            // During a held-arrow scrub, coalesce: this loader is torn down
            // (canvas .onDisappear → cancel()) as the next image arrives,
            // cancelling the sleep before any full 4000px decode starts — so a
            // scrub spends CPU on cheap thumbnails, not doomed decodes. A
            // discrete step (immediate) skips the wait and sharpens at once.
            if !immediate {
                try? await Task.sleep(nanoseconds: Self.settleDelayNanos)
                guard !Task.isCancelled else { return }
            }
            let decoded = await service.image(url: url, maxPixel: target, nominalMax: nominal)
            guard let decoded else { return }
            self?.publish(decoded, from: url)
        }
    }

    private static let settleDelayNanos: UInt64 = 120_000_000  // 120 ms

    private func publish(_ decoded: CGImage, from url: URL) {
        guard !Task.isCancelled, url == currentURL else { return }
        // Never replace a sharper image with a blurrier one (stale task).
        let dimension = CGFloat(max(decoded.width, decoded.height))
        guard dimension > decodedMaxDimension || image == nil else { return }
        image = decoded
        decodedMaxDimension = dimension
    }

    /// Drop the in-flight request when the canvas goes away (navigation), so
    /// a not-yet-started decode is skipped instead of running off-screen.
    public func cancel() {
        requestTask?.cancel()
        requestTask = nil
    }
}
