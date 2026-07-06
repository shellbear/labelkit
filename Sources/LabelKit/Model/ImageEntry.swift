import CoreGraphics
import Foundation
import Observation

/// One image of the dataset. An @Observable class on purpose: box edits
/// invalidate only the views reading THIS entry (the canvas and one sidebar
/// row), keeping a 10k-row sidebar inert during drags.
@Observable
public final class ImageEntry: Identifiable {
    /// Byte-exact filename from disk/annotations file. Also the stable `id`.
    public let filename: String
    public var boxes: [BoundingBox]
    /// True when the annotations file has an entry for this image. Entries
    /// are never dropped on save: deleting the last box turns the entry into
    /// a negative example, not a hole in the dataset.
    public var hasEntryInFile: Bool
    /// Entry-level unknown keys (e.g. imageWidth), carried through save.
    public var extras: [String: JSONValue]
    /// True when the annotations file references this image but the file is
    /// missing on disk. Kept (and saved) so datasets don't silently shrink.
    public let imageFileMissing: Bool
    /// Lazily read via ImageMetadata on first display; nil until then.
    public var pixelSize: CGSize?

    public init(filename: String, boxes: [BoundingBox] = [], hasEntryInFile: Bool = false,
                extras: [String: JSONValue] = [:], imageFileMissing: Bool = false) {
        self.filename = filename
        self.boxes = boxes
        self.hasEntryInFile = hasEntryInFile
        self.extras = extras
        self.imageFileMissing = imageFileMissing
    }

    public var id: String { filename }
}
