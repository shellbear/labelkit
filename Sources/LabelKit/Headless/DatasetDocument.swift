import CoreGraphics
import Foundation

/// A dataset opened for scripted, headless work: the annotations file as plain
/// records plus the list of images on disk. This is what the `stats`,
/// `validate`, `annotate` and `render` subcommands operate on.
///
/// It is deliberately not `DatasetStore`: that one is main-actor, observable
/// and built around undo for the editor. A document is a value — load it,
/// change `records`, `save()` — and it writes through the same
/// `CreateMLWriter`, so the format contract (order, unknown keys, negatives,
/// byte-stable output, the file's own indentation) holds for scripted edits
/// exactly as it does for the GUI.
public struct DatasetDocument: Sendable {
    public let location: DatasetLocation
    /// Entries in file order. Never reordered or dropped by a load → save.
    public var records: [ImageAnnotationRecord]
    /// Image filenames found in the images directory, name-sorted.
    public let imagesOnDisk: [String]
    /// Indentation sniffed from the loaded file, reused on save.
    public let indentUnit: String

    /// - Parameter onlyImages: when the caller will only ever ask about these
    ///   images (as `annotate` does), they are checked on disk one by one and
    ///   the directory is not listed at all. `imagesOnDisk` then holds just the
    ///   ones that exist. Past a few hundred names a full listing is cheaper,
    ///   so that is what happens instead.
    public init(location: DatasetLocation, imageGlob: String? = nil, onlyImages: [String]? = nil) throws {
        self.location = location
        if location.annotationsExists {
            let data = try Data(contentsOf: location.annotationsURL)
            records = try CreateMLFormat.load(data)
            indentUnit = JSONIndent.detectUnit(in: data) ?? CreateMLWriter.defaultIndentUnit
        } else {
            records = []
            indentUnit = CreateMLWriter.defaultIndentUnit
        }
        if let onlyImages, onlyImages.count <= Self.listingThreshold {
            imagesOnDisk = onlyImages.uniqued().filter { Self.isListedImage($0, in: location.imagesDirectory) }
        } else {
            imagesOnDisk = ImageDirectoryScanner.scan(directory: location.imagesDirectory, glob: imageGlob)
        }
    }

    /// Up to this many images, checking each beats listing a large directory.
    static let listingThreshold = 256

    /// Whether a directory listing would include `name` — answered for one
    /// file without listing. The checks mirror `ImageDirectoryScanner`: an
    /// image extension, directly in the folder, not hidden, and spelled exactly
    /// as stored (the file system matches `A.JPG` to `a.jpg`; a listing never
    /// would, and two spellings of one image must not become two entries).
    static func isListedImage(_ name: String, in directory: URL) -> Bool {
        guard !name.contains("/"),
              ImageDirectoryScanner.imageExtensions.contains((name as NSString).pathExtension.lowercased()),
              let values = try? URL(fileURLWithPath: directory.path + "/" + name)
                  .resourceValues(forKeys: [.nameKey, .isHiddenKey])
        else { return false }
        return values.name == name && values.isHidden != true
    }

    /// True when `url` is this dataset's images folder, however it is spelled
    /// (symlinks, case, trailing slash). Output must never be written there:
    /// a rendered `a.jpg` would replace the source `a.jpg`.
    public func isImagesDirectory(_ url: URL) -> Bool {
        func identity(_ url: URL) -> (any NSCopying & NSSecureCoding & NSObjectProtocol)? {
            (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileResourceIdentifierKey]))?
                .fileResourceIdentifier
        }
        if let a = identity(url), let b = identity(location.imagesDirectory) { return a.isEqual(b) }
        return url.resolvingSymlinksInPath().standardizedFileURL.path
            == location.imagesDirectory.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// For tests and callers that already hold the pieces.
    public init(location: DatasetLocation, records: [ImageAnnotationRecord],
                imagesOnDisk: [String], indentUnit: String = CreateMLWriter.defaultIndentUnit) {
        self.location = location
        self.records = records
        self.imagesOnDisk = imagesOnDisk
        self.indentUnit = indentUnit
    }

    public func imageURL(for filename: String) -> URL {
        location.imagesDirectory.appendingPathComponent(filename)
    }

    /// Display-orientation pixel size of an image in the dataset, or nil when
    /// the file is missing or unreadable.
    public func pixelSize(of filename: String) -> CGSize? {
        ImageMetadata.pixelSize(of: imageURL(for: filename))
    }

    /// The exact bytes `save()` would write.
    public func serialized() -> Data {
        CreateMLWriter.serialize(records, indentUnit: indentUnit)
    }

    public func save() throws {
        try serialized().write(to: location.annotationsURL, options: .atomic)
    }
}

public extension DatasetDocument {
    /// The file's entries with repeats of an image dropped — the first entry
    /// wins, as in the editor. (`validate` reports the repeats.)
    var uniqueRecords: [ImageAnnotationRecord] {
        var seen = Set<String>()
        return records.filter { seen.insert($0.image).inserted }
    }

    /// Pixel sizes for many images at once, read in parallel. Each read is a
    /// header-only probe (no pixel decode), so this stays cheap on datasets of
    /// tens of thousands of images; images that are missing or unreadable are
    /// simply absent from the result.
    func pixelSizes(of filenames: [String]) -> [String: CGSize] {
        let directory = location.imagesDirectory
        let sizes = filenames.concurrentMap { ImageMetadata.pixelSize(of: directory.appendingPathComponent($0)) }
        var result: [String: CGSize] = [:]
        result.reserveCapacity(filenames.count)
        for (name, size) in zip(filenames, sizes) {
            if let size { result[name] = size }
        }
        return result
    }
}
