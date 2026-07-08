import XCTest
@testable import LabelKit

final class DetectionGeometryTests: XCTestCase {
    private func candidate(_ n: CGRect, label: String? = nil, conf: Float = 1,
                           size: CGSize, fallback: String = "obj") -> DetectionCandidate? {
        DetectionGeometry.candidate(
            from: RawDetection(boundingBox: n, label: label, confidence: conf),
            pixelSize: size, fallbackLabel: fallback)
    }

    func testFlipsBottomLeftToTopLeft() {
        // Vision bottom-left quadrant → editor's bottom-left (y grows downward).
        let c = candidate(CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                          size: CGSize(width: 100, height: 200))
        XCTAssertEqual(c?.box.rect, CGRect(x: 0, y: 100, width: 50, height: 100))
    }

    func testTopStripLandsAtOrigin() {
        // A band hugging the TOP of the image (maxY == 1) starts at pixel y = 0.
        let c = candidate(CGRect(x: 0.2, y: 0.7, width: 0.4, height: 0.3),
                          size: CGSize(width: 1000, height: 500))
        XCTAssertEqual(c?.box.rect, CGRect(x: 200, y: 0, width: 400, height: 150))
    }

    func testClampsToImageBounds() {
        // Straddles the left edge and the bottom edge → clipped to the image.
        let c = candidate(CGRect(x: -0.1, y: -0.1, width: 0.3, height: 0.3),
                          size: CGSize(width: 100, height: 100))
        XCTAssertEqual(c?.box.rect, CGRect(x: 0, y: 80, width: 20, height: 20))
    }

    func testRejectsFullyOutsideOrDegenerate() {
        XCTAssertNil(candidate(CGRect(x: 2, y: 2, width: 0.1, height: 0.1),
                               size: CGSize(width: 100, height: 100)))
        XCTAssertNil(candidate(CGRect(x: 0.5, y: 0.5, width: 0, height: 0),
                               size: CGSize(width: 100, height: 100)))
        XCTAssertNil(candidate(CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                               size: .zero))
    }

    func testLabelFallbackOnlyWhenMissingOrEmpty() {
        let size = CGSize(width: 100, height: 100)
        let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        XCTAssertEqual(candidate(box, label: "card", size: size)?.box.label, "card")
        XCTAssertEqual(candidate(box, label: nil, size: size, fallback: "obj")?.box.label, "obj")
        XCTAssertEqual(candidate(box, label: "", size: size, fallback: "obj")?.box.label, "obj")
    }
}
