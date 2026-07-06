import CoreGraphics

/// Maps image pixels ↔ view points. Both spaces are top-left origin, so no
/// y-flip anywhere — image space matches Create ML's coordinate convention.
public struct CanvasTransform: Equatable, Sendable {
    public static let maxZoom: CGFloat = 64
    public static let minZoom: CGFloat = 0.02

    /// View points per image pixel.
    public var zoom: CGFloat
    /// View-space position of image pixel (0,0).
    public var pan: CGPoint

    public init(zoom: CGFloat = 1, pan: CGPoint = .zero) {
        self.zoom = zoom
        self.pan = pan
    }

    public func toView(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * zoom + pan.x, y: point.y * zoom + pan.y)
    }

    public func toImage(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - pan.x) / zoom, y: (point.y - pan.y) / zoom)
    }

    public func toView(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x * zoom + pan.x,
            y: rect.origin.y * zoom + pan.y,
            width: rect.width * zoom,
            height: rect.height * zoom
        )
    }

    /// Fit-to-window (⌘0 / default): image centered, fully visible.
    public static func fit(imageSize: CGSize, in frame: CGSize) -> CanvasTransform {
        guard imageSize.width > 0, imageSize.height > 0, frame.width > 0, frame.height > 0 else {
            return CanvasTransform()
        }
        let zoom = min(frame.width / imageSize.width, frame.height / imageSize.height)
        let pan = CGPoint(
            x: (frame.width - imageSize.width * zoom) / 2,
            y: (frame.height - imageSize.height * zoom) / 2
        )
        return CanvasTransform(zoom: zoom, pan: pan)
    }

    /// Zoom keeping the image pixel under `anchor` (view space) stationary.
    public mutating func zoom(by factor: CGFloat, anchor: CGPoint) {
        let imageAnchor = toImage(anchor)
        zoom = min(max(zoom * factor, Self.minZoom), Self.maxZoom)
        pan = CGPoint(
            x: anchor.x - imageAnchor.x * zoom,
            y: anchor.y - imageAnchor.y * zoom
        )
    }

    public mutating func panBy(_ delta: CGPoint) {
        pan.x += delta.x
        pan.y += delta.y
    }
}
