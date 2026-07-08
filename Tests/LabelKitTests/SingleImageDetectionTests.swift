import CoreGraphics
import Foundation
import XCTest
@testable import LabelKit

/// Covers the shared per-image primitive both the GUI engine and the `detect`
/// CLI call — decode + geometry mapping — using a stub detector so it's
/// deterministic and Vision-free.
final class SingleImageDetectionTests: XCTestCase {
    func testDecodesReadsSizeAndMapsDetectionsToPixelBoxes() throws {
        let size = CGSize(width: 600, height: 400)
        let url = try writeTempPNG(size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        // One detection in Vision's normalized, bottom-left space.
        let detector = StubDetector([
            RawDetection(boundingBox: CGRect(x: 0.25, y: 0.3, width: 0.5, height: 0.4),
                         label: "card", confidence: 0.9),
        ])
        let result = try SingleImageDetection.run(
            imageURL: url, detector: detector, maxDecodePixel: 1536, fallbackLabel: "object")

        XCTAssertEqual(result.pixelSize, size)
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.confidence, 0.9)
        XCTAssertEqual(candidate.box.label, "card")
        // Normalized bottom-left → image pixels top-left, with the Y-flip:
        // x=0.25·600=150, y=(1−0.7)·400=120, w=0.5·600=300, h=0.4·400=160.
        let rect = candidate.box.rect
        XCTAssertEqual(rect.minX, 150, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 120, accuracy: 0.001)
        XCTAssertEqual(rect.width, 300, accuracy: 0.001)
        XCTAssertEqual(rect.height, 160, accuracy: 0.001)
    }

    func testUnlabeledDetectionTakesFallbackLabel() throws {
        let url = try writeTempPNG(size: CGSize(width: 200, height: 200))
        defer { try? FileManager.default.removeItem(at: url) }

        let detector = StubDetector([
            RawDetection(boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), confidence: 0.7),
        ])
        let result = try SingleImageDetection.run(
            imageURL: url, detector: detector, maxDecodePixel: 1536, fallbackLabel: "thing")
        XCTAssertEqual(result.candidates.first?.box.label, "thing")
    }

    func testUnreadableImageThrows() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("labelkit-does-not-exist.jpg")
        XCTAssertThrowsError(
            try SingleImageDetection.run(imageURL: missing, detector: StubDetector(),
                                         maxDecodePixel: 1536, fallbackLabel: "x")
        ) { error in
            XCTAssertEqual(error as? SingleImageDetection.Failure, .unreadableImage)
        }
    }
}
