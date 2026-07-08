import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One box to draw: a rect in source-image pixels (top-left origin), a label,
/// and an optional score that becomes a "label 97%" chip.
public struct RenderableBox: Sendable {
    public var rect: CGRect
    public var label: String
    public var confidence: Float?

    public init(rect: CGRect, label: String, confidence: Float? = nil) {
        self.rect = rect
        self.label = label
        self.confidence = confidence
    }
}

/// Draws labeled bounding boxes onto an image and encodes a PNG — fully
/// headless (CoreGraphics + CoreText + ImageIO, no AppKit), so it lives in the
/// library and backs the `detect --render` flow (and any future UI export).
///
/// The point is agent perception: a rendered overlay is something Claude Code
/// can open and *see*, closing the loop that raw coordinates can't.
public enum BoxRenderer {
    /// Draw `boxes` onto `image`, scaling from `sourceSize` (the coordinate
    /// space the boxes are measured in — normally the image's full pixel size)
    /// to the decoded image's own dimensions. Returns PNG bytes, or nil if a
    /// context/encoder couldn't be created.
    public static func renderPNG(image: CGImage, sourceSize: CGSize, boxes: [RenderableBox]) -> Data? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let scaleX = sourceSize.width > 0 ? CGFloat(width) / sourceSize.width : 1
        let scaleY = sourceSize.height > 0 ? CGFloat(height) / sourceSize.height : 1
        let minEdge = CGFloat(min(width, height))
        let lineWidth = max(2, minEdge / 300)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, max(11, minEdge / 45), nil)

        for box in boxes {
            let color = color(for: box.label)
            // Scale into draw space and flip Y (CGContext origin is bottom-left).
            let w = box.rect.width * scaleX
            let h = box.rect.height * scaleY
            let x = box.rect.minX * scaleX
            let yTop = box.rect.minY * scaleY
            let rect = CGRect(x: x, y: CGFloat(height) - (yTop + h), width: w, height: h)

            ctx.setStrokeColor(color)
            ctx.setLineWidth(lineWidth)
            ctx.stroke(rect)

            // Chip anchored at the box's top-left corner (rect.maxY is the top
            // edge in flipped space), growing downward into the box.
            drawChip(text: caption(box), topLeft: CGPoint(x: rect.minX, y: rect.maxY),
                     font: font, fill: color, in: ctx)
        }

        guard let output = ctx.makeImage() else { return nil }
        return encodePNG(output)
    }

    // MARK: - Text

    private static func caption(_ box: RenderableBox) -> String {
        guard let confidence = box.confidence else { return box.label }
        return "\(box.label) \(Int((confidence * 100).rounded()))%"
    }

    private static func drawChip(text: String, topLeft: CGPoint, font: CTFont,
                                 fill: CGColor, in ctx: CGContext) {
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let attributes = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: white,
        ] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes) else { return }
        let line = CTLineCreateWithAttributedString(attributed)

        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let padX = ascent * 0.35, padY = descent + 2
        let chip = CGRect(x: topLeft.x, y: topLeft.y - (ascent + descent + padY * 2),
                          width: textWidth + padX * 2, height: ascent + descent + padY * 2)

        ctx.setFillColor(fill)
        ctx.fill(chip)
        ctx.textPosition = CGPoint(x: chip.minX + padX, y: chip.minY + descent + padY)
        CTLineDraw(line, ctx)
    }

    // MARK: - Color

    /// A distinct, stable color per label. FNV-1a (not `hashValue`, which is
    /// per-process randomized) keeps a given label's color reproducible across
    /// runs — so an agent diffing two renders sees real changes, not recoloring.
    private static func color(for label: String) -> CGColor {
        palette[Int(fnv1a(label) % UInt64(palette.count))]
    }

    private static let palette: [CGColor] = [
        rgb(0.20, 0.60, 0.86), rgb(0.18, 0.80, 0.44), rgb(0.91, 0.30, 0.24),
        rgb(0.95, 0.61, 0.07), rgb(0.61, 0.35, 0.71), rgb(0.10, 0.74, 0.61),
        rgb(0.20, 0.29, 0.37), rgb(0.90, 0.49, 0.13),
    ]

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: 1)
    }

    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in string.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return hash
    }

    // MARK: - Encode

    private static func encodePNG(_ image: CGImage) -> Data? {
        guard let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
