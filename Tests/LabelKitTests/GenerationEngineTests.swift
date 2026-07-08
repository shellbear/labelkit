import CoreGraphics
import Foundation
import XCTest
@testable import LabelKit

/// Exercises the streaming batch engine — fan-out, "only stream non-empty",
/// additive de-duplication — with a stub detector, so it's deterministic and
/// Vision-free (the Vision SDK's own behavior isn't labelkit's to test).
final class GenerationEngineTests: XCTestCase {
    private func collect(_ stream: AsyncStream<GenerationEngine.ImageResult>) async
        -> [String: [BoundingBox]] {
        var results: [String: [BoundingBox]] = [:]
        for await result in stream { results[result.filename] = result.newBoxes }
        return results
    }

    private var cardDetector: StubDetector {
        StubDetector([
            RawDetection(boundingBox: CGRect(x: 0.25, y: 0.3, width: 0.5, height: 0.4),
                         label: "card", confidence: 0.9),
        ])
    }

    func testStreamsNewBoxesForImagesThatDetectSomething() async throws {
        let url = try writeTempPNG(size: CGSize(width: 600, height: 400))
        defer { try? FileManager.default.removeItem(at: url) }

        let results = await collect(GenerationEngine.stream(
            jobs: [GenerationJob(filename: "a.png", imageURL: url, existingBoxes: [])],
            detector: cardDetector, settings: GenerationEngine.Settings()))

        let boxes = try XCTUnwrap(results["a.png"])
        XCTAssertEqual(boxes.map(\.label), ["card"])
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 600, height: 400).contains(boxes[0].rect))
    }

    func testDoesNotStreamImagesWithNoDetections() async throws {
        let url = try writeTempPNG(size: CGSize(width: 600, height: 400))
        defer { try? FileManager.default.removeItem(at: url) }

        let results = await collect(GenerationEngine.stream(
            jobs: [GenerationJob(filename: "blank.png", imageURL: url, existingBoxes: [])],
            detector: StubDetector([]), settings: GenerationEngine.Settings()))

        XCTAssertNil(results["blank.png"])   // nothing to apply → not streamed
    }

    func testDedupesAgainstExistingBoxesSoReRunAddsNothing() async throws {
        let url = try writeTempPNG(size: CGSize(width: 600, height: 400))
        defer { try? FileManager.default.removeItem(at: url) }
        let detector = cardDetector

        // First pass discovers the box.
        let first = await collect(GenerationEngine.stream(
            jobs: [GenerationJob(filename: "a.png", imageURL: url, existingBoxes: [])],
            detector: detector, settings: GenerationEngine.Settings()))
        let found = try XCTUnwrap(first["a.png"])
        XCTAssertFalse(found.isEmpty)

        // Second pass with it already present → nothing new streamed.
        let second = await collect(GenerationEngine.stream(
            jobs: [GenerationJob(filename: "a.png", imageURL: url, existingBoxes: found)],
            detector: detector, settings: GenerationEngine.Settings()))
        XCTAssertNil(second["a.png"])
    }
}
