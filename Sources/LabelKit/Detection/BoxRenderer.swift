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
    /// Text for the chip, when it should differ from the label (e.g. "#2 card").
    /// The colour still follows `label`, so a given label keeps its colour.
    public var caption: String?

    public init(rect: CGRect, label: String, confidence: Float? = nil, caption: String? = nil) {
        self.rect = rect
        self.label = label
        self.confidence = confidence
        self.caption = caption
    }
}

/// A coordinate grid drawn over the image, in **source-image pixels**: a line
/// every `spacing` pixels, each labelled with its coordinate. It turns a render
/// into a ruler — a vision model can read a box's extents straight off the
/// picture and write them back as pixel coordinates.
public struct RenderGrid: Sendable, Equatable {
    public var spacing: CGFloat

    public init(spacing: CGFloat) {
        self.spacing = spacing
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
        render(image: image, sourceSize: sourceSize, boxes: boxes, as: .png)
    }

    /// Output encoding. JPEG is several times smaller and faster to write than
    /// PNG for photos, which matters when an agent renders a batch only to
    /// look at it; PNG stays lossless.
    public enum Encoding: Sendable, Equatable {
        case png
        case jpeg(quality: Double)

        public var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            }
        }
    }

    /// File names for a batch of rendered images: `photo.jpg` → `photo.<ext>`.
    /// Images that differ only in their extension (`a.jpg`, `a.png`) would
    /// land on the same file, so those keep their full name: `a.png.<ext>`.
    /// Compared without regard to case, as the default macOS file system does.
    public static func outputNames(for images: [String], fileExtension: String) -> [String] {
        let stems = images.map { ($0 as NSString).deletingPathExtension }
        let shared = Set(Dictionary(grouping: stems, by: { $0.lowercased() }).filter { $1.count > 1 }.keys)
        return zip(images, stems).map { image, stem in
            (shared.contains(stem.lowercased()) ? image : stem) + "." + fileExtension
        }
    }

    /// As `renderPNG`, with a choice of encoding.
    public static func render(image: CGImage, sourceSize: CGSize, boxes: [RenderableBox],
                              grid: RenderGrid? = nil, as encoding: Encoding) -> Data? {
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

        if let grid, grid.spacing > 0, sourceSize.width > 0, sourceSize.height > 0 {
            drawGrid(grid, sourceSize: sourceSize, scaleX: scaleX, scaleY: scaleY,
                     drawSize: CGSize(width: width, height: height), in: ctx)
        }

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
        return encode(output, as: encoding)
    }

    // MARK: - Text

    private static func caption(_ box: RenderableBox) -> String {
        let text = box.caption ?? box.label
        guard let confidence = box.confidence else { return text }
        return "\(text) \(Int((confidence * 100).rounded()))%"
    }

    // MARK: - Grid

    /// Lines at multiples of `grid.spacing` source pixels, labelled along the
    /// top and left edges. Each line is a light stroke over a dark one so it
    /// stays readable on any photo.
    private static func drawGrid(_ grid: RenderGrid, sourceSize: CGSize, scaleX: CGFloat, scaleY: CGFloat,
                                 drawSize: CGSize, in ctx: CGContext) {
        let minEdge = min(drawSize.width, drawSize.height)
        let thin = max(1, minEdge / 900)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, max(9, minEdge / 70), nil)
        let chipFill = CGColor(red: 0, green: 0, blue: 0, alpha: 0.62)

        var path = [(from: CGPoint, to: CGPoint)]()
        var labels = [(text: String, topLeft: CGPoint)]()
        var value = grid.spacing
        while value < sourceSize.width {
            let x = value * scaleX
            path.append((CGPoint(x: x, y: 0), CGPoint(x: x, y: drawSize.height)))
            labels.append((String(Int(value.rounded())), CGPoint(x: x + thin, y: drawSize.height)))
            value += grid.spacing
        }
        value = grid.spacing
        while value < sourceSize.height {
            let y = drawSize.height - value * scaleY
            path.append((CGPoint(x: 0, y: y), CGPoint(x: drawSize.width, y: y)))
            labels.append((String(Int(value.rounded())), CGPoint(x: 0, y: y - thin)))
            value += grid.spacing
        }

        for (color, width) in [(CGColor(red: 0, green: 0, blue: 0, alpha: 0.35), thin * 3),
                               (CGColor(red: 1, green: 1, blue: 1, alpha: 0.75), thin)] {
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width)
            for segment in path {
                ctx.move(to: segment.from)
                ctx.addLine(to: segment.to)
            }
            ctx.strokePath()
        }
        for label in labels {
            drawChip(text: label.text, topLeft: label.topLeft, font: font, fill: chipFill, in: ctx)
        }
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

    private static func encode(_ image: CGImage, as encoding: Encoding) -> Data? {
        let type: UTType
        var properties: [CFString: Any] = [:]
        switch encoding {
        case .png:
            type = .png
        case .jpeg(let quality):
            type = .jpeg
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        guard let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                data, type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
