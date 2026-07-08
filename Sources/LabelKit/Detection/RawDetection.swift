import CoreGraphics
import Foundation

/// One detection straight out of a detector, in Vision's native coordinate
/// space: a normalized `[0,1]` rect with a **bottom-left** origin. Converting
/// it to an editor `BoundingBox` (image pixels, top-left origin) is
/// `DetectionGeometry`'s job — detectors stay coordinate-dumb.
public struct RawDetection: Equatable, Sendable {
    /// Normalized `[0,1]`, bottom-left origin (Vision convention).
    public var boundingBox: CGRect
    /// The model's class label, or nil for label-less detectors (rectangles,
    /// saliency) that only localize.
    public var label: String?
    public var confidence: Float

    public init(boundingBox: CGRect, label: String? = nil, confidence: Float) {
        self.boundingBox = boundingBox
        self.label = label
        self.confidence = confidence
    }
}

/// A candidate editor box (image pixels, top-left) paired with the confidence
/// that produced it — the currency `DetectionMerge` sorts and suppresses on.
public struct DetectionCandidate: Equatable, Sendable {
    public var box: BoundingBox
    public var confidence: Float

    public init(box: BoundingBox, confidence: Float) {
        self.box = box
        self.confidence = confidence
    }
}
