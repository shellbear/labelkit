import CoreGraphics
import Foundation
import Observation

/// Holds exactly ONE decoded image — the currently displayed one — at
/// display resolution. Callers state how many physical pixels the image
/// currently occupies (`neededMaxPixel`); the loader re-decodes only when
/// the decoded bitmap is meaningfully smaller (1.25× hysteresis, so
/// continuous zoom doesn't thrash), never past native resolution.
@Observable
@MainActor
public final class DetailImageLoader {
    public private(set) var image: CGImage?

    private var currentURL: URL?
    private var nominalMaxDimension: CGFloat = 0
    private var decodedMaxDimension: CGFloat = 0
    private var decodeTask: Task<Void, Never>?

    public init() {}

    /// Show `url` (dropping any previous image) at `neededMaxPixel`.
    public func display(url: URL, imageSize: CGSize, neededMaxPixel: CGFloat) {
        if url != currentURL {
            currentURL = url
            image = nil
            decodedMaxDimension = 0
            nominalMaxDimension = max(imageSize.width, imageSize.height)
        }
        ensure(neededMaxPixel)
    }

    /// Re-decode if the displayed physical size outgrew the decoded bitmap.
    public func ensure(_ neededMaxPixel: CGFloat) {
        guard currentURL != nil, nominalMaxDimension > 0 else { return }
        let target = min(nominalMaxDimension, max(neededMaxPixel, 64))
        if image != nil, decodedMaxDimension >= min(nominalMaxDimension, target / 1.25),
           decodedMaxDimension >= target * 0.8 || decodedMaxDimension >= nominalMaxDimension {
            return
        }
        decode(maxPixel: target)
    }

    private func decode(maxPixel: CGFloat) {
        guard let url = currentURL else { return }
        decodeTask?.cancel()
        decodeTask = Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) {
                ImageDownsampler.decode(url: url, maxPixel: maxPixel)
            }.value
            guard !Task.isCancelled, let self, url == self.currentURL, let decoded else { return }
            // Never replace a sharper image with a blurrier one (stale task).
            let dimension = CGFloat(max(decoded.width, decoded.height))
            guard dimension > self.decodedMaxDimension || self.image == nil else { return }
            self.image = decoded
            self.decodedMaxDimension = dimension
        }
    }
}
