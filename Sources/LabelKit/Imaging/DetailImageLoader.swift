import CoreGraphics
import Foundation
import Observation

/// Holds exactly ONE decoded image — the currently displayed one — at
/// display resolution. Zooming past the decoded resolution re-decodes at the
/// next rung of a ×2 ladder (cancelling any in-flight rung); the lower-res
/// image keeps displaying meanwhile. Navigation drops the previous image.
@Observable
@MainActor
public final class DetailImageLoader {
    public private(set) var image: CGImage?
    /// Decoded pixels per image pixel (≤ 1). Views divide by this when the
    /// decoded bitmap is smaller than the nominal image.
    public private(set) var decodedScale: CGFloat = 1

    private var currentURL: URL?
    private var nominalMaxDimension: CGFloat = 0
    private var decodeTask: Task<Void, Never>?

    public init() {}

    public func display(url: URL, imageSize: CGSize, viewportMaxPixel: CGFloat) {
        if url != currentURL {
            currentURL = url
            image = nil
            nominalMaxDimension = max(imageSize.width, imageSize.height)
        }
        decode(maxPixel: min(nominalMaxDimension, viewportMaxPixel))
    }

    /// Call when zoom changes; re-decodes only when displaying above ~1.25×
    /// the decoded resolution and there is more resolution to be had.
    public func zoomChanged(displayZoom: CGFloat, viewportMaxPixel: CGFloat) {
        guard currentURL != nil, nominalMaxDimension > 0 else { return }
        let currentDecoded = nominalMaxDimension * decodedScale
        guard displayZoom * nominalMaxDimension > currentDecoded * 1.25,
              currentDecoded < nominalMaxDimension else { return }
        let next = min(nominalMaxDimension, currentDecoded * 2)
        decode(maxPixel: max(next, viewportMaxPixel))
    }

    private func decode(maxPixel: CGFloat) {
        guard let url = currentURL else { return }
        decodeTask?.cancel()
        decodeTask = Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) {
                ImageDownsampler.decode(url: url, maxPixel: maxPixel)
            }.value
            guard !Task.isCancelled, let self, url == self.currentURL, let decoded else { return }
            self.image = decoded
            self.decodedScale = self.nominalMaxDimension > 0
                ? min(1, CGFloat(max(decoded.width, decoded.height)) / self.nominalMaxDimension)
                : 1
        }
    }
}
