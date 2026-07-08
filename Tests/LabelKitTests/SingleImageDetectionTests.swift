import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LabelKit

/// Covers the shared per-image primitive both the GUI engine and the `detect`
/// CLI call — decode + detect + geometry, in one place. Uses a built-in Vision
/// detector so it needs no model file (the real pipeline still runs headlessly).
final class SingleImageDetectionTests: XCTestCase {
    func testReadsPixelSizeAndRunsDetector() throws {
        let size = CGSize(width: 600, height: 400)
        let url = try writeImage(size: size, rect: CGRect(x: 150, y: 120, width: 300, height: 160))
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try SingleImageDetection.run(
            imageURL: url, detector: VisionBuiltinDetector(.rectangles),
            maxDecodePixel: 1536, fallbackLabel: "rect")

        XCTAssertEqual(result.pixelSize, size)
        // Candidates carry confidence and map inside the image bounds.
        for candidate in result.candidates {
            XCTAssertTrue((0...1).contains(candidate.confidence))
            XCTAssertTrue(CGRect(origin: .zero, size: size).contains(candidate.box.rect))
        }
    }

    func testUnreadableImageThrows() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("labelkit-does-not-exist.jpg")
        XCTAssertThrowsError(
            try SingleImageDetection.run(imageURL: missing,
                                         detector: VisionBuiltinDetector(.rectangles),
                                         maxDecodePixel: 1536, fallbackLabel: "x")
        ) { error in
            XCTAssertEqual(error as? SingleImageDetection.Failure, .unreadableImage)
        }
    }

    // MARK: -

    private func writeImage(size: CGSize, rect: CGRect) throws -> URL {
        let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(CGColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 1))
        ctx.fill(rect)
        let image = ctx.makeImage()!

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("labelkit-\(UUID().uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw XCTSkip("couldn't create PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
