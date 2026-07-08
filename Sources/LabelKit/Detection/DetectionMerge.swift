import CoreGraphics
import Foundation

/// Turns raw candidates into the boxes to **add** to an entry: confidence
/// filter → per-label non-max suppression among candidates → drop any that
/// already exist (IoU against the entry's current same-label boxes).
///
/// Additive by design: existing boxes are never inspected for removal, only for
/// de-duplication, so generation preserves hand-drawn work and re-running on an
/// already-processed image is effectively idempotent.
public enum DetectionMerge {
    /// The subset of `candidates` worth adding, given what `existing` already
    /// holds. `nmsIoU` suppresses overlapping detections of the same label;
    /// `dedupeIoU` drops a detection that overlaps an existing same-label box.
    public static func newBoxes(
        candidates: [DetectionCandidate],
        existing: [BoundingBox],
        minConfidence: Float,
        nmsIoU: CGFloat = 0.45,
        dedupeIoU: CGFloat = 0.5
    ) -> [BoundingBox] {
        let survivors = detections(candidates, minConfidence: minConfidence, nmsIoU: nmsIoU)

        let existingByLabel = Dictionary(grouping: existing, by: \.label)
        return survivors.compactMap { candidate in
            let peers = existingByLabel[candidate.box.label] ?? []
            let alreadyThere = peers.contains { iou($0.rect, candidate.box.rect) > dedupeIoU }
            return alreadyThere ? nil : candidate.box
        }
    }

    /// The detections for one image: confidence filter → per-label non-max
    /// suppression, highest confidence first. This is the "what did the model
    /// see" step, with no notion of an entry's existing boxes — the CLI reports
    /// it directly, `newBoxes` layers additive de-duplication on top.
    public static func detections(
        _ candidates: [DetectionCandidate],
        minConfidence: Float,
        nmsIoU: CGFloat = 0.45
    ) -> [DetectionCandidate] {
        suppress(candidates.filter { $0.confidence >= minConfidence }, iouThreshold: nmsIoU)
    }

    /// Greedy per-label non-max suppression, highest confidence first. A model
    /// legitimately overlaps boxes of *different* classes (a phone on a desk),
    /// so suppression is grouped by label and never crosses it.
    static func suppress(_ candidates: [DetectionCandidate], iouThreshold: CGFloat) -> [DetectionCandidate] {
        let ordered = candidates.sorted { $0.confidence > $1.confidence }
        var kept: [DetectionCandidate] = []
        for candidate in ordered {
            let overlapsKept = kept.contains {
                $0.box.label == candidate.box.label && iou($0.box.rect, candidate.box.rect) > iouThreshold
            }
            if !overlapsKept { kept.append(candidate) }
        }
        return kept
    }

    /// Intersection-over-union of two rects; 0 when they don't overlap.
    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let interArea = inter.width * inter.height
        guard interArea > 0 else { return 0 }
        let union = a.width * a.height + b.width * b.height - interArea
        return union > 0 ? interArea / union : 0
    }
}
