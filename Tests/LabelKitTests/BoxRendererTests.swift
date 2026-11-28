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

    /// Decode rendered bytes to RGBA so tests can look at actual pixels.
    private func pixels(of data: Data) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var rgba = [UInt8](repeating: 0, count: decoded.width * decoded.height * 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &rgba, width: decoded.width, height: decoded.height, bitsPerComponent: 8,
            bytesPerRow: decoded.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        return (decoded.width, decoded.height, rgba)
    }

    func testJPEGEncodingProducesAJPEGAtImageDimensions() throws {
        let data = try XCTUnwrap(BoxRenderer.render(
            image: image(200, 120), sourceSize: CGSize(width: 200, height: 120),
            boxes: [RenderableBox(rect: CGRect(x: 20, y: 15, width: 80, height: 60), label: "card", caption: "#1 card")],
            as: .jpeg(quality: 0.8)))
        XCTAssertEqual(Array(data.prefix(3)), [0xFF, 0xD8, 0xFF], "JPEG magic bytes")
        XCTAssertEqual(pixelSize(ofPNG: data), CGSize(width: 200, height: 120))
        XCTAssertEqual(BoxRenderer.Encoding.jpeg(quality: 0.8).fileExtension, "jpg")
        XCTAssertEqual(BoxRenderer.Encoding.png.fileExtension, "png")
    }

    /// The grid is measured in SOURCE pixels: on a 400x200 source drawn at
    /// 200x100, a 100px grid puts vertical lines at draw x = 50, 100, 150 and a
    /// horizontal line at draw y = 50 — and nowhere else.
    func testGridLinesFallOnSourcePixelMultiples() throws {
        let data = try XCTUnwrap(BoxRenderer.render(
            image: image(200, 100), sourceSize: CGSize(width: 400, height: 200), boxes: [],
            grid: RenderGrid(spacing: 100), as: .png))
        let (width, _, rgba) = try pixels(of: data)
        func brightness(x: Int, y: Int) -> Int { Int(rgba[(y * width + x) * 4]) }

        // Sample along a row clear of the labels (which hug the top and left).
        // The image is one flat grey, so any pixel that differs from an
        // untouched one has had a line drawn through it.
        let row = 80
        let background = brightness(x: 25, y: row)
        for x in [50, 100, 150] {
            XCTAssertGreaterThan(abs(brightness(x: x, y: row) - background), 5, "vertical line at draw x=\(x)")
        }
        XCTAssertGreaterThan(abs(brightness(x: 180, y: 50) - background), 5, "horizontal line at draw y=50")
        for x in [75, 125, 175] {
            XCTAssertEqual(brightness(x: x, y: row), background, "no line at draw x=\(x)")
        }
    }

    func testNoGridLeavesTheImageUntouched() throws {
        let data = try XCTUnwrap(BoxRenderer.render(
            image: image(200, 100), sourceSize: CGSize(width: 400, height: 200), boxes: [], as: .png))
        let (width, _, rgba) = try pixels(of: data)
        XCTAssertEqual(rgba[(80 * width + 50) * 4], rgba[(80 * width + 25) * 4])
        XCTAssertEqual(rgba[(50 * width + 180) * 4], rgba[(80 * width + 25) * 4])
    }

    func testOutputNamesKeepImagesThatShareAStemApart() {
        XCTAssertEqual(
            BoxRenderer.outputNames(for: ["a.jpg", "b.heic", "a.png", "c.tar.jpg", "B.JPG"], fileExtension: "jpg"),
            ["a.jpg.jpg", "b.heic.jpg", "a.png.jpg", "c.tar.jpg", "B.JPG.jpg"])
        XCTAssertEqual(BoxRenderer.outputNames(for: ["a.jpg", "b.heic"], fileExtension: "png"), ["a.png", "b.png"])
        XCTAssertEqual(BoxRenderer.outputNames(for: [], fileExtension: "jpg"), [])
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
