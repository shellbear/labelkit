import CoreGraphics
import Foundation

/// The machine-readable result of running a detector over one image — the
/// stable contract the `detect` CLI emits (as JSON or NDJSON) and the shape an
/// agent parses. Lives in the library, and is pure `Codable` data, so its
/// construction (coordinate conventions, rounding, ordering) is unit-tested
/// without the CLI.
///
/// Coordinates are given twice on purpose: `box` in image pixels and
/// `normalized` in `[0,1]`, **both top-left origin**, so no consumer has to
/// guess the convention or re-derive the Vision Y-flip.
public struct DetectionReport: Codable, Equatable, Sendable {
    /// Output schema version — bump on any breaking field change.
    public var schemaVersion: Int
    /// labelkit version that produced this, for provenance in saved runs.
    public var labelkit: String
    /// Display name of the detector (custom model base name, or built-in name).
    public var detector: String
    /// `"coreml"` for a custom model, `"vision"` for an Apple built-in.
    public var source: String
    /// Image file name (basename).
    public var image: String
    /// Absolute path to the image on disk.
    public var path: String
    /// Original image size in display orientation, pixels.
    public var width: Double
    public var height: Double
    /// Highest-confidence first.
    public var detections: [Item]

    public struct Item: Codable, Equatable, Sendable {
        public var label: String
        /// Model score, `0…1`.
        public var confidence: Double
        /// Image pixels, top-left origin (`x`,`y` = top-left corner).
        public var box: Box
        /// `[0,1]` fractions of the image, top-left origin.
        public var normalized: Box
    }

    public struct Box: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
    }
}

public extension DetectionReport {
    /// Build a report from the confidence/NMS-filtered detections for one image.
    /// `detections` are expected already sorted (as `DetectionMerge.detections`
    /// returns them, highest confidence first); ordering is preserved verbatim.
    static func make(
        detector: String,
        source: String,
        filename: String,
        path: String,
        pixelSize: CGSize,
        detections: [DetectionCandidate],
        labelkitVersion version: String = labelkitVersion
    ) -> DetectionReport {
        let w = pixelSize.width, h = pixelSize.height
        let items = detections.map { candidate -> Item in
            let r = candidate.box.rect
            return Item(
                label: candidate.box.label,
                confidence: round(Double(candidate.confidence), places: 4),
                box: Box(x: round(r.minX, places: 2), y: round(r.minY, places: 2),
                         width: round(r.width, places: 2), height: round(r.height, places: 2)),
                normalized: Box(x: round(divide(r.minX, w), places: 5),
                                y: round(divide(r.minY, h), places: 5),
                                width: round(divide(r.width, w), places: 5),
                                height: round(divide(r.height, h), places: 5)))
        }
        return DetectionReport(
            schemaVersion: 1, labelkit: version, detector: detector, source: source,
            image: filename, path: path,
            width: round(w, places: 2), height: round(h, places: 2), detections: items)
    }
}

private func divide(_ a: CGFloat, _ b: CGFloat) -> CGFloat { b > 0 ? a / b : 0 }

private func round(_ value: CGFloat, places: Int) -> Double {
    let f = pow(10.0, Double(places))
    return (Double(value) * f).rounded() / f
}
