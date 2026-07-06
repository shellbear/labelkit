import CoreGraphics
import Foundation

/// Editor-side box: top-left-origin CGRect in image pixels (natural for
/// hit-testing and resizing). Conversion to Create ML's center-anchored
/// coordinates happens only at the IO boundary.
public struct BoundingBox: Identifiable, Equatable, Sendable {
    /// Editor identity only — never serialized.
    public let id: UUID
    public var label: String
    /// Image pixels, top-left origin, `origin` = min corner.
    public var rect: CGRect
    /// Annotation-level unknown keys, carried through save.
    public var extras: [String: JSONValue]
    /// Editor-session visibility. NOT serialized: hidden boxes still save,
    /// toggling never dirties the dataset.
    public var isHidden = false

    public init(id: UUID = UUID(), label: String, rect: CGRect, extras: [String: JSONValue] = [:]) {
        self.id = id
        self.label = label
        self.rect = rect
        self.extras = extras
    }

    public init(record: BoxRecord) {
        self.init(
            label: record.label,
            rect: CGRect(
                x: record.x - record.width / 2,
                y: record.y - record.height / 2,
                width: record.width,
                height: record.height
            ),
            extras: record.extras
        )
    }

    public var record: BoxRecord {
        BoxRecord(
            label: label,
            x: rect.midX, y: rect.midY,
            width: rect.width, height: rect.height,
            extras: extras
        )
    }
}
