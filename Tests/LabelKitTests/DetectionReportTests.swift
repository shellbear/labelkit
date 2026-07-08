import CoreGraphics
import Foundation
import XCTest
@testable import LabelKit

final class DetectionReportTests: XCTestCase {
    private func candidate(_ rect: CGRect, _ label: String, _ conf: Float) -> DetectionCandidate {
        DetectionCandidate(box: BoundingBox(label: label, rect: rect), confidence: conf)
    }

    func testBuildsSchemaWithPixelAndNormalizedBoxes() {
        let report = DetectionReport.make(
            detector: "cards", source: "coreml",
            filename: "photo.jpg", path: "/data/photo.jpg",
            pixelSize: CGSize(width: 1000, height: 500),
            detections: [candidate(CGRect(x: 100, y: 50, width: 200, height: 100), "card", 0.9321)],
            labelkitVersion: "1.2.3")

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.labelkit, "1.2.3")
        XCTAssertEqual(report.detector, "cards")
        XCTAssertEqual(report.source, "coreml")
        XCTAssertEqual(report.image, "photo.jpg")
        XCTAssertEqual(report.path, "/data/photo.jpg")
        XCTAssertEqual(report.width, 1000)
        XCTAssertEqual(report.height, 500)

        let item = try! XCTUnwrap(report.detections.first)
        XCTAssertEqual(item.label, "card")
        XCTAssertEqual(item.confidence, 0.9321, accuracy: 1e-9)   // rounded to 4 places
        // Pixel box, top-left origin.
        XCTAssertEqual(item.box.x, 100)
        XCTAssertEqual(item.box.y, 50)
        XCTAssertEqual(item.box.width, 200)
        XCTAssertEqual(item.box.height, 100)
        // Normalized against the image size, top-left origin.
        XCTAssertEqual(item.normalized.x, 0.1, accuracy: 1e-9)
        XCTAssertEqual(item.normalized.y, 0.1, accuracy: 1e-9)
        XCTAssertEqual(item.normalized.width, 0.2, accuracy: 1e-9)
        XCTAssertEqual(item.normalized.height, 0.2, accuracy: 1e-9)
    }

    func testRoundsCoordinatesToTwoPlaces() {
        let report = DetectionReport.make(
            detector: "d", source: "vision", filename: "a.png", path: "/a.png",
            pixelSize: CGSize(width: 640, height: 480),
            detections: [candidate(CGRect(x: 12.3456, y: 7.891, width: 3.005, height: 9.999), "x", 0.5)])
        let box = report.detections[0].box
        XCTAssertEqual(box.x, 12.35)
        XCTAssertEqual(box.y, 7.89)
        XCTAssertEqual(box.width, 3.01)
        XCTAssertEqual(box.height, 10.0)
    }

    func testPreservesDetectionOrder() {
        // make() does not reorder — it trusts the caller's ranking.
        let report = DetectionReport.make(
            detector: "d", source: "vision", filename: "a.png", path: "/a.png",
            pixelSize: CGSize(width: 100, height: 100),
            detections: [candidate(CGRect(x: 0, y: 0, width: 1, height: 1), "hi", 0.9),
                         candidate(CGRect(x: 5, y: 5, width: 1, height: 1), "lo", 0.6)])
        XCTAssertEqual(report.detections.map(\.confidence), [0.9, 0.6])
    }

    func testCodableRoundTrips() throws {
        let report = DetectionReport.make(
            detector: "d", source: "coreml", filename: "a.png", path: "/a.png",
            pixelSize: CGSize(width: 800, height: 600),
            detections: [candidate(CGRect(x: 10, y: 20, width: 30, height: 40), "y", 0.75)])
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(DetectionReport.self, from: data)
        XCTAssertEqual(decoded, report)
    }
}
