import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import LabelKit

final class BoxRendererTests: XCTestCase {
    private func image(_ width: Int, _ height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Decode PNG bytes back to pixel dimensions to prove a real image came out.
    private func pixelSize(ofPNG data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    func testRendersPNGAtImageDimensions() throws {
        let boxes = [
            RenderableBox(rect: CGRect(x: 20, y: 15, width: 80, height: 60), label: "card", confidence: 0.9),
            RenderableBox(rect: CGRect(x: 120, y: 40, width: 50, height: 50), label: "chip"),
        ]
        let data = try XCTUnwrap(
            BoxRenderer.renderPNG(image: image(200, 120),
                                  sourceSize: CGSize(width: 200, height: 120), boxes: boxes))
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(pixelSize(ofPNG: data), CGSize(width: 200, height: 120))
    }

    func testRendersEvenWithNoBoxes() throws {
        let data = try XCTUnwrap(
            BoxRenderer.renderPNG(image: image(64, 64),
                                  sourceSize: CGSize(width: 64, height: 64), boxes: []))
        XCTAssertEqual(pixelSize(ofPNG: data), CGSize(width: 64, height: 64))
    }

    func testScalesBoxesFromSourceSpaceToRenderSize() throws {
        // Boxes measured in a 400x240 space, drawn onto a 200x120 image — must
        // not crash and must still produce the render-sized PNG.
        let data = try XCTUnwrap(
            BoxRenderer.renderPNG(
                image: image(200, 120), sourceSize: CGSize(width: 400, height: 240),
                boxes: [RenderableBox(rect: CGRect(x: 40, y: 30, width: 160, height: 120),
                                      label: "a", confidence: 0.5)]))
        XCTAssertEqual(pixelSize(ofPNG: data), CGSize(width: 200, height: 120))
    }
}
