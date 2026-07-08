import CoreGraphics
import Foundation

/// Decode one image, run a detector over it, and map the raw output into editor
/// candidates (image pixels, top-left). This is the single unit of detection
/// work shared by the GUI's streaming `GenerationEngine` and the `detect` CLI —
/// so the decode/geometry pipeline exists in exactly one place.
///
/// It stops **before** confidence/NMS/dedupe so callers apply their own policy:
/// the CLI reports `DetectionMerge.detections`, the engine merges via
/// `DetectionMerge.newBoxes`. Confidence rides along in every candidate, which
/// the batch engine discards but the CLI surfaces.
///
/// Synchronous on purpose: `ImageDownsampler`/Vision force the work onto the
/// calling thread, so the engine wraps this in its task group and the CLI just
/// calls it in a loop.
public enum SingleImageDetection {
    public enum Failure: Error, Equatable {
        /// No readable pixel dimensions (missing file, non-image, corrupt header).
        case unreadableImage
        /// Header read but pixels wouldn't decode.
        case decodeFailed
    }

    public struct Result: Sendable {
        /// Original image size in display orientation — the space `candidates`
        /// (and any rendered overlay) are measured in.
        public let pixelSize: CGSize
        /// Geometry-mapped candidates, pre-confidence/NMS, confidence retained.
        public let candidates: [DetectionCandidate]

        public init(pixelSize: CGSize, candidates: [DetectionCandidate]) {
            self.pixelSize = pixelSize
            self.candidates = candidates
        }
    }

    /// - Parameters:
    ///   - maxDecodePixel: longest edge to decode to before detection. Vision
    ///     rescales to the model's fixed input anyway, so this only bounds
    ///     decode cost, not accuracy.
    ///   - fallbackLabel: label for detections a label-less detector leaves bare.
    public static func run(
        imageURL: URL,
        detector: BoxDetector,
        maxDecodePixel: CGFloat,
        fallbackLabel: String
    ) throws -> Result {
        guard let pixelSize = ImageMetadata.pixelSize(of: imageURL) else {
            throw Failure.unreadableImage
        }
        guard let cgImage = ImageDownsampler.decode(url: imageURL, maxPixel: maxDecodePixel) else {
            throw Failure.decodeFailed
        }
        let raw = try detector.detect(cgImage)
        let candidates = raw.compactMap {
            DetectionGeometry.candidate(from: $0, pixelSize: pixelSize, fallbackLabel: fallbackLabel)
        }
        return Result(pixelSize: pixelSize, candidates: candidates)
    }
}
