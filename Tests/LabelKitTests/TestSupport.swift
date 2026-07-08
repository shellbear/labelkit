import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LabelKit

/// A deterministic `BoxDetector` for tests: hands back canned detections and
/// never touches Vision. It lets the detection *pipeline* — decode, geometry
/// mapping, streaming, additive merge — be exercised headlessly and
/// reproducibly, without depending on the Vision SDK (whose real behavior is
/// environment-sensitive and belongs to Apple, not to labelkit). Real Vision /
/// Core ML runs are validated locally via CoreMLBoxDetectorTests, not in CI.
struct StubDetector: BoxDetector {
    var name = "stub"
    var providesLabels = true
    var defaultLabel = "object"
    /// Returned verbatim from `detect`, in Vision's normalized, bottom-left space.
    var detections: [RawDetection]

    init(_ detections: [RawDetection] = []) { self.detections = detections }

    func detect(_ cgImage: CGImage) throws -> [RawDetection] { detections }
}

extension XCTestCase {
    /// Write a solid-gray PNG of `size` to a unique temp file and return its URL.
    /// Enough for the decode/metadata path; detectors under test are stubs, so
    /// the pixels' content doesn't matter.
    func writeTempPNG(size: CGSize) throws -> URL {
        let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let image = ctx.makeImage()!

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("labelkit-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw XCTSkip("couldn't create PNG destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }
}
