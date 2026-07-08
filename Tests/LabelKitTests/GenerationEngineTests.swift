import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LabelKit

final class GenerationEngineTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("labelkit-gen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Write a `rect`-on-light-background PNG (rect nil → blank) and return its URL.
    private func writeImage(_ name: String, size: CGSize, rect: CGRect?) throws -> URL {
        let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        if let rect {
            ctx.setFillColor(CGColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 1))
            ctx.fill(rect)
        }
        let image = ctx.makeImage()!
        let url = tempDir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func collect(_ stream: AsyncStream<GenerationEngine.ImageResult>) async
        -> [String: [BoundingBox]] {
        var results: [String: [BoundingBox]] = [:]
        for await result in stream { results[result.filename] = result.newBoxes }
        return results
    }

    func testRunsOverBatchAndStreamsOnlyNonEmptyResults() async throws {
        let size = CGSize(width: 600, height: 400)
        _ = try writeImage("rect.png", size: size, rect: CGRect(x: 150, y: 120, width: 300, height: 160))
        _ = try writeImage("blank.png", size: size, rect: nil)

        let jobs = ["rect.png", "blank.png"].map {
            GenerationJob(filename: $0, imageURL: tempDir.appendingPathComponent($0), existingBoxes: [])
        }
        var settings = GenerationEngine.Settings()
        settings.fallbackLabel = "rectangle"
        let stream = GenerationEngine.stream(
            jobs: jobs, detector: VisionBuiltinDetector(.rectangles), settings: settings)

        let results = await collect(stream)

        // Blank yields no result (nothing to apply); the rect one should.
        XCTAssertNil(results["blank.png"])
        try XCTSkipIf(results["rect.png"] == nil, "Vision found no rectangle")
        let boxes = try XCTUnwrap(results["rect.png"])
        XCTAssertFalse(boxes.isEmpty)
        for box in boxes {
            XCTAssertEqual(box.label, "rectangle")
            XCTAssertTrue(CGRect(origin: .zero, size: size).contains(box.rect))
        }
    }

    func testDedupesAgainstExistingBoxesSoReRunAddsNothing() async throws {
        let size = CGSize(width: 600, height: 400)
        _ = try writeImage("rect.png", size: size, rect: CGRect(x: 150, y: 120, width: 300, height: 160))
        let url = tempDir.appendingPathComponent("rect.png")
        var settings = GenerationEngine.Settings()
        settings.fallbackLabel = "rectangle"
        let detector = VisionBuiltinDetector(.rectangles)

        // First pass: discover the boxes.
        let first = await collect(GenerationEngine.stream(
            jobs: [GenerationJob(filename: "rect.png", imageURL: url, existingBoxes: [])],
            detector: detector, settings: settings))
        let found = first["rect.png"] ?? []
        try XCTSkipIf(found.isEmpty, "Vision found no rectangle")

        // Second pass with those boxes already present → nothing new to add.
        let second = await collect(GenerationEngine.stream(
            jobs: [GenerationJob(filename: "rect.png", imageURL: url, existingBoxes: found)],
            detector: detector, settings: settings))
        XCTAssertNil(second["rect.png"])   // nothing new streamed on the re-run
    }
}
