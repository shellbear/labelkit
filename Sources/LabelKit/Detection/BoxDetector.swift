import CoreGraphics

/// A source of bounding boxes for one image. Implementations run fully
/// on-device — a custom Core ML object detector or an Apple Vision built-in —
/// and hand back detections in Vision's normalized, bottom-left space, which
/// `DetectionGeometry` maps into editor boxes.
///
/// `detect` runs synchronously on the calling (background) thread; Vision does
/// its own ANE/GPU scheduling. Conformers must be safe to invoke concurrently
/// from `GenerationEngine`'s decode fan-out — the pattern is a shared model
/// object with a fresh request + handler per call.
public protocol BoxDetector: Sendable {
    /// Human-facing name for the toolbar/menu (e.g. "cards_real", "Rectangles").
    var name: String { get }
    /// True when the detector emits its own class labels (a custom Core ML
    /// detector, the animal recognizer). False for pure localizers
    /// (rectangles, faces, saliency), which need a caller-supplied label.
    var providesLabels: Bool { get }
    /// The label to attach to detections that carry none — pre-filled in the
    /// UI for label-less detectors, and a safety net for the odd unlabeled
    /// observation from a labelled model.
    var defaultLabel: String { get }

    func detect(_ cgImage: CGImage) throws -> [RawDetection]
}
