import CoreGraphics
import Foundation

/// Converts detector output (Vision-normalized, bottom-left) into editor boxes
/// (image pixels, top-left origin). The Y-flip lives here and nowhere else, so
/// there is exactly one place to get the most error-prone step right.
public enum DetectionGeometry {
    /// Map one raw detection onto an image of `pixelSize`, clamped to the image
    /// bounds. Returns nil when the box falls entirely outside the image or
    /// collapses below `minSide` after clamping (a spurious edge sliver).
    /// Label-less detections take `fallbackLabel`.
    public static func candidate(
        from detection: RawDetection,
        pixelSize: CGSize,
        fallbackLabel: String,
        minSide: CGFloat = 1
    ) -> DetectionCandidate? {
        let w = pixelSize.width, h = pixelSize.height
        guard w > 0, h > 0 else { return nil }

        let n = detection.boundingBox
        // Vision's origin is bottom-left; the editor's is top-left → flip Y by
        // measuring the top edge (`1 - maxY`) down from the top of the image.
        let raw = CGRect(x: n.minX * w,
                         y: (1 - n.maxY) * h,
                         width: n.width * w,
                         height: n.height * h)
        let clamped = raw.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !clamped.isNull, clamped.width >= minSide, clamped.height >= minSide else { return nil }

        let label = detection.label.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackLabel
        return DetectionCandidate(
            box: BoundingBox(label: label, rect: clamped),
            confidence: detection.confidence)
    }
}
