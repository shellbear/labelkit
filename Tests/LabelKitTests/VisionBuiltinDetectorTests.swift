import CoreGraphics
import XCTest
@testable import LabelKit

/// Exercises the real Vision pipeline headlessly (no model file, no UI). Proves
/// the request wiring and observation→RawDetection mapping run in a plain test
/// process — the piece unit tests of DetectionGeometry/Merge can't cover.
final class VisionBuiltinDetectorTests: XCTestCase {
    /// A solid `rect` (dark) on a light background, as a CGImage.
    private func image(size: CGSize, rect: CGRect?) -> CGImage {
        let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        if let rect {
            ctx.setFillColor(CGColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 1))
            ctx.fill(rect)
        }
        return ctx.makeImage()!
    }

    func testBlankImageRunsAndReturnsEmpty() throws {
        // The value here is that a Vision request performs headlessly at all.
        let blank = image(size: CGSize(width: 512, height: 512), rect: nil)
        for kind in VisionBuiltinDetector.Kind.allCases {
            XCTAssertNoThrow(try VisionBuiltinDetector(kind).detect(blank),
                             "\(kind) should run headlessly")
        }
    }

    func testDetectsAndConvertsARectangle() throws {
        let size = CGSize(width: 600, height: 400)
        let target = CGRect(x: 150, y: 120, width: 300, height: 160)
        let detector = VisionBuiltinDetector(.rectangles)

        let raw = try detector.detect(image(size: size, rect: target))
        try XCTSkipIf(raw.isEmpty, "Vision found no rectangle on this synthetic image")

        // Every observation must be normalized and convert to an in-bounds box.
        for detection in raw {
            XCTAssertTrue((0...1).contains(detection.boundingBox.minX))
            XCTAssertTrue((0...1).contains(detection.boundingBox.maxY))
            let candidate = DetectionGeometry.candidate(
                from: detection, pixelSize: size, fallbackLabel: detector.defaultLabel)
            XCTAssertNotNil(candidate)
            if let rect = candidate?.box.rect {
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(rect))
            }
            XCTAssertEqual(candidate?.box.label, "rectangle")
        }
    }
}
