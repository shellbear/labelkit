import XCTest
@testable import LabelKit

final class DetectionMergeTests: XCTestCase {
    private func candidate(_ rect: CGRect, _ label: String, _ conf: Float) -> DetectionCandidate {
        DetectionCandidate(box: BoundingBox(label: label, rect: rect), confidence: conf)
    }

    private func rects(_ boxes: [BoundingBox]) -> Set<CGRect> { Set(boxes.map(\.rect)) }

    func testFiltersBelowConfidence() {
        let out = DetectionMerge.newBoxes(
            candidates: [candidate(CGRect(x: 0, y: 0, width: 10, height: 10), "a", 0.4),
                         candidate(CGRect(x: 100, y: 100, width: 10, height: 10), "a", 0.8)],
            existing: [], minConfidence: 0.5)
        XCTAssertEqual(rects(out), [CGRect(x: 100, y: 100, width: 10, height: 10)])
    }

    func testNMSSuppressesLowerConfidenceOverlapOfSameLabel() {
        let out = DetectionMerge.newBoxes(
            candidates: [candidate(CGRect(x: 0, y: 0, width: 100, height: 100), "a", 0.9),
                         candidate(CGRect(x: 10, y: 10, width: 100, height: 100), "a", 0.7)],
            existing: [], minConfidence: 0.5)
        XCTAssertEqual(rects(out), [CGRect(x: 0, y: 0, width: 100, height: 100)])  // kept the 0.9
    }

    func testNMSKeepsOverlapOfDifferentLabels() {
        let out = DetectionMerge.newBoxes(
            candidates: [candidate(CGRect(x: 0, y: 0, width: 100, height: 100), "a", 0.9),
                         candidate(CGRect(x: 10, y: 10, width: 100, height: 100), "b", 0.7)],
            existing: [], minConfidence: 0.5)
        XCTAssertEqual(out.count, 2)
    }

    func testDedupesAgainstExistingSameLabelOnly() {
        let existing = [BoundingBox(label: "a", rect: CGRect(x: 0, y: 0, width: 100, height: 100))]
        // Same label, heavy overlap → dropped.
        let overlapSame = DetectionMerge.newBoxes(
            candidates: [candidate(CGRect(x: 5, y: 5, width: 100, height: 100), "a", 0.9)],
            existing: existing, minConfidence: 0.5)
        XCTAssertTrue(overlapSame.isEmpty)
        // Same rect, different label → kept.
        let overlapOther = DetectionMerge.newBoxes(
            candidates: [candidate(CGRect(x: 5, y: 5, width: 100, height: 100), "b", 0.9)],
            existing: existing, minConfidence: 0.5)
        XCTAssertEqual(overlapOther.count, 1)
        // Same label, no overlap → kept.
        let disjoint = DetectionMerge.newBoxes(
            candidates: [candidate(CGRect(x: 500, y: 500, width: 100, height: 100), "a", 0.9)],
            existing: existing, minConfidence: 0.5)
        XCTAssertEqual(disjoint.count, 1)
    }

    func testIoU() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(DetectionMerge.iou(a, a), 1, accuracy: 1e-9)
        XCTAssertEqual(DetectionMerge.iou(a, CGRect(x: 200, y: 200, width: 10, height: 10)), 0)
        // Half-overlap: intersection 5000, union 15000 → 1/3.
        XCTAssertEqual(DetectionMerge.iou(a, CGRect(x: 50, y: 0, width: 100, height: 100)),
                       1.0 / 3.0, accuracy: 1e-9)
    }
}
