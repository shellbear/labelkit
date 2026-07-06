import Foundation

/// One bounding box as it exists on disk: Create ML center-anchored pixels.
public struct BoxRecord: Equatable, Sendable {
    public var label: String
    /// Box center, in image pixels, top-left image origin.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Annotation-level keys labelkit does not model, preserved verbatim.
    public var extras: [String: JSONValue]

    public init(label: String, x: Double, y: Double, width: Double, height: Double,
                extras: [String: JSONValue] = [:]) {
        self.label = label
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.extras = extras
    }
}

/// One dataset entry as it exists on disk. `boxes` may be empty — a negative
/// example — and such entries MUST survive save (they are training signal).
public struct ImageAnnotationRecord: Equatable, Sendable {
    /// Image filename, byte-exact as found in the file. Never normalized.
    public var image: String
    public var boxes: [BoxRecord]
    /// Entry-level keys labelkit does not model, preserved verbatim.
    public var extras: [String: JSONValue]

    public init(image: String, boxes: [BoxRecord], extras: [String: JSONValue] = [:]) {
        self.image = image
        self.boxes = boxes
        self.extras = extras
    }
}

/// Seam for future formats (YOLO, COCO, …). labelkit's UI only ever speaks
/// records; converters plug in here without touching the editor.
public protocol AnnotationFormat {
    static func load(_ data: Data) throws -> [ImageAnnotationRecord]
    static func serialize(_ records: [ImageAnnotationRecord]) -> Data
}
