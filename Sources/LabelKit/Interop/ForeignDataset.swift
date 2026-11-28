import CoreGraphics
import Foundation

/// The dataset layouts labelkit can read and write besides its own.
public enum DatasetFormat: String, CaseIterable, Sendable {
    /// Ultralytics YOLO: `images/` and `labels/*.txt` (`class cx cy w h`,
    /// normalized), class names in `data.yaml` or `classes.txt`.
    case yolo
    /// COCO detection JSON: `images`, `annotations`, `categories`.
    case coco
    /// Hugging Face ImageFolder: images plus `metadata.jsonl` whose rows carry
    /// `objects.bbox` (`[x, y, width, height]`, pixels) and `objects.categories`.
    case huggingface
}

/// A dataset in another layout, read into neutral terms: where each image file
/// is, and its boxes. Nothing has been copied or converted yet.
public struct ForeignDataset: Equatable, Sendable {
    public struct Image: Equatable, Sendable {
        /// The image file on disk.
        public var source: URL
        public var boxes: [ImportedBox]

        public init(source: URL, boxes: [ImportedBox]) {
            self.source = source
            self.boxes = boxes
        }
    }

    public var format: DatasetFormat
    public var images: [Image]
    /// Entries that named an image file which isn't there.
    public var missingImages: [String]

    public init(format: DatasetFormat, images: [Image], missingImages: [String] = []) {
        self.format = format
        self.images = images
        self.missingImages = missingImages
    }
}

public struct ForeignDatasetError: LocalizedError, Equatable {
    public var message: String
    /// True when the caller pointed at the wrong thing (no such path, not a
    /// dataset), as opposed to a dataset whose contents are broken.
    public var isUsage = false
    public var errorDescription: String? { message }
}

/// Reads YOLO, COCO and Hugging Face datasets from disk. Splits
/// (`train/`, `valid/`, `test/`) are read together: a Create ML dataset is one
/// folder, and Create ML makes its own validation split when training.
public enum ForeignDatasetReader {
    /// Read the dataset at `url` (a folder, or for COCO its JSON file),
    /// working out the format from what is there unless one is given.
    ///
    /// - Parameter classNames: names for numeric class ids, in id order, when
    ///   the dataset doesn't carry them itself (many YOLO downloads ship
    ///   without their `data.yaml`). They take precedence over any found.
    public static func read(at url: URL, format: DatasetFormat? = nil,
                            classNames: [String]? = nil) throws -> ForeignDataset {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ForeignDatasetError(message: "no such file or directory: \(url.path)", isUsage: true)
        }
        let files: Tree
        if isDirectory.boolValue {
            files = Tree(root: url)
        } else {
            // A lone annotation file: its images are beside it, or — in the
            // standard COCO layout, annotations/instances_*.json — one level up.
            let folder = url.deletingLastPathComponent()
            let root = folder.lastPathComponent == "annotations" ? folder.deletingLastPathComponent() : folder
            files = Tree(root: root, only: url)
        }

        switch try format ?? detect(files, at: url) {
        case .coco: return try readCOCO(files)
        case .yolo: return try readYOLO(files, classNames: classNames)
        case .huggingface: return try readHuggingFace(files, classNames: classNames)
        }
    }

    static func detect(_ files: Tree, at url: URL) throws -> DatasetFormat {
        if !files.named("metadata.jsonl").isEmpty { return .huggingface }
        if !files.cocoFiles().isEmpty { return .coco }
        if !files.yoloLabelFiles().isEmpty { return .yolo }
        throw ForeignDatasetError(
            message: "couldn't tell what kind of dataset \(url.path) is; pass --format yolo, coco or huggingface",
            isUsage: true)
    }

    // MARK: - COCO

    private static func readCOCO(_ files: Tree) throws -> ForeignDataset {
        let jsons = files.cocoFiles()
        guard !jsons.isEmpty else { throw ForeignDatasetError(message: "no COCO annotation file found") }
        var result = ForeignDataset(format: .coco, images: [])
        for json in jsons {
            let parsed: [ImportedImage]
            do {
                parsed = try BoxImportParser.parse(Data(contentsOf: json))
            } catch {
                throw ForeignDatasetError(message: "\(json.lastPathComponent): \(describe(error))")
            }
            for entry in parsed {
                // COCO file names are relative to an images folder that varies
                // by tool; the parser keeps the basename, which is looked up
                // next to the JSON first and then anywhere in the dataset.
                if let source = files.image(named: entry.image, near: json.deletingLastPathComponent()) {
                    result.images.append(.init(source: source, boxes: entry.boxes))
                } else {
                    result.missingImages.append(entry.image)
                }
            }
        }
        return result
    }

    // MARK: - YOLO

    private static func readYOLO(_ files: Tree, classNames: [String]?) throws -> ForeignDataset {
        let names = try classNames ?? yoloClassNames(files)
        var boxesByImage: [URL: [ImportedBox]] = [:]
        var result = ForeignDataset(format: .yolo, images: [])

        for label in files.yoloLabelFiles() {
            let stem = label.deletingPathExtension().lastPathComponent
            guard let image = files.yoloImage(forLabel: label) else {
                result.missingImages.append(stem)
                continue
            }
            let text = try String(contentsOf: label, encoding: .utf8)
            var boxes: [ImportedBox] = []
            for (index, line) in text.split(whereSeparator: \.isNewline).enumerated() {
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.isEmpty { continue }
                let numbers = fields.compactMap { Double($0) }
                guard numbers.count == fields.count, numbers.count >= 5, let rect = yoloRect(numbers.dropFirst()) else {
                    throw ForeignDatasetError(
                        message: "\(label.lastPathComponent) line \(index + 1): expected 'class cx cy w h'")
                }
                let classIndex = Int(numbers[0])
                let name = names.indices.contains(classIndex) ? names[classIndex] : "class_\(classIndex)"
                boxes.append(ImportedBox(label: name, geometry: .normalized(rect)))
            }
            boxesByImage[image] = boxes
        }
        // An image with no label file is a background image in YOLO — as long
        // as it sits in a folder the dataset demonstrably uses for images.
        let imageFolders = Set(boxesByImage.keys.map { $0.deletingLastPathComponent().path })
        for image in files.images where imageFolders.contains(image.deletingLastPathComponent().path) {
            result.images.append(.init(source: image, boxes: boxesByImage[image] ?? []))
        }
        return result
    }

    /// `cx cy w h`, or a segmentation polygon `x1 y1 x2 y2 …` reduced to the
    /// box around it. Normalized, top-left origin.
    private static func yoloRect(_ values: ArraySlice<Double>) -> CGRect? {
        let v = Array(values)
        if v.count == 4 {
            return CGRect(x: v[0] - v[2] / 2, y: v[1] - v[3] / 2, width: v[2], height: v[3])
        }
        guard v.count >= 6, v.count.isMultiple(of: 2) else { return nil }
        let xs = stride(from: 0, to: v.count, by: 2).map { v[$0] }
        let ys = stride(from: 1, to: v.count, by: 2).map { v[$0] }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func yoloClassNames(_ files: Tree) throws -> [String] {
        for name in ["data.yaml", "data.yml", "dataset.yaml", "classes.txt", "obj.names", "labels.txt"] {
            if let file = files.named(name).first {
                let names = try ClassNames.read(file)
                if !names.isEmpty { return names }
            }
        }
        return []
    }

    // MARK: - Hugging Face

    private static func readHuggingFace(_ files: Tree, classNames: [String]?) throws -> ForeignDataset {
        let metadataFiles = files.named("metadata.jsonl")
        guard !metadataFiles.isEmpty else { throw ForeignDatasetError(message: "no metadata.jsonl found") }
        // Integer categories take their names from the dataset card, if it has them.
        let names = try classNames ?? files.named("README.md").first
            .map { ClassNames.parseYAML(try String(contentsOf: $0, encoding: .utf8)) } ?? []

        var result = ForeignDataset(format: .huggingface, images: [])
        for metadata in metadataFiles {
            let directory = metadata.deletingLastPathComponent()
            let text = try String(contentsOf: metadata, encoding: .utf8)
            for (index, line) in text.split(whereSeparator: \.isNewline).enumerated() {
                let here = "\(metadata.lastPathComponent) line \(index + 1)"
                guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let fileName = row["file_name"] as? String else {
                    throw ForeignDatasetError(message: "\(here): expected a JSON object with \"file_name\"")
                }
                let boxes = try huggingFaceBoxes(row["objects"], names: names, at: here)
                // The row is untrusted input: only an image that the listing of
                // this dataset found is accepted, so a `file_name` such as
                // `../../x.png` can't pull a file in from outside it.
                if let source = files.listedImage(at: directory.appendingPathComponent(fileName)) {
                    result.images.append(.init(source: source, boxes: boxes))
                } else {
                    result.missingImages.append(fileName)
                }
            }
        }
        return result
    }

    /// `{"bbox": [[x, y, w, h], …], "categories": […]}` — boxes are pixels from
    /// the top-left corner. The label list is `categories` in the ImageFolder
    /// docs and `category` in many published datasets; both are read.
    private static func huggingFaceBoxes(_ raw: Any?, names: [String], at place: String) throws -> [ImportedBox] {
        guard let objects = raw as? [String: Any], let rawBoxes = objects["bbox"] as? [[Any]] else { return [] }
        let labels = (objects["categories"] ?? objects["category"]) as? [Any] ?? []
        return try rawBoxes.enumerated().map { index, raw in
            let numbers = raw.compactMap { ($0 as? NSNumber)?.doubleValue }
            guard numbers.count == 4, raw.count == 4 else {
                throw ForeignDatasetError(message: "\(place): box #\(index + 1) is not [x, y, width, height]")
            }
            let label: String
            switch index < labels.count ? labels[index] : nil {
            case let name as String: label = name
            case let number as NSNumber:
                label = names.indices.contains(number.intValue) ? names[number.intValue] : "class_\(number.intValue)"
            default: throw ForeignDatasetError(message: "\(place): box #\(index + 1) has no category")
            }
            return ImportedBox(label: label, geometry: .pixels(
                CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])))
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

/// Class names as YOLO's `data.yaml` and a Hugging Face dataset card write
/// them. Both are YAML, and both use one of three small shapes, so those
/// shapes are read directly rather than pulling in a YAML parser:
///
/// ```yaml
/// names: [cat, dog]        # inline list
/// names:                   # block list
///   - cat
///   - dog
/// names:                   # index map
///   0: cat
///   '1': dog
/// ```
public enum ClassNames {
    /// Class names from a file: a YAML file with a `names:` entry (a YOLO
    /// `data.yaml`, a dataset card), or a plain list with one name per line.
    public static func read(_ url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        if ["yaml", "yml", "md"].contains(url.pathExtension.lowercased()) { return parseYAML(text) }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func parseYAML(_ text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("names:") })
        else { return [] }

        let inline = lines[start].trimmingCharacters(in: .whitespaces).dropFirst("names:".count)
            .trimmingCharacters(in: .whitespaces)
        if inline.hasPrefix("[") {
            return inline.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .split(separator: ",").map { unquote(String($0)) }.filter { !$0.isEmpty }
        }

        let indent = lines[start].prefix { $0 == " " || $0 == "\t" }.count
        var listed: [String] = []
        var indexed: [Int: String] = [:]
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let depth = line.prefix { $0 == " " || $0 == "\t" }.count
            if trimmed.hasPrefix("- ") {
                guard depth >= indent else { break }
                listed.append(unquote(String(trimmed.dropFirst(2))))
            } else if depth > indent, let colon = trimmed.firstIndex(of: ":"),
                      let index = Int(unquote(String(trimmed[..<colon]))) {
                indexed[index] = unquote(String(trimmed[trimmed.index(after: colon)...]))
            } else {
                break
            }
        }
        if !listed.isEmpty { return listed }
        guard let last = indexed.keys.max() else { return [] }
        return (0...last).map { indexed[$0] ?? "class_\($0)" }
    }

    private static func unquote(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }
}

/// The files under a dataset folder, listed once. Dataset layouts differ in
/// where they keep things, so readers ask this for files by name or role
/// instead of assuming paths.
struct Tree {
    let root: URL
    private(set) var all: [URL] = []
    private(set) var images: [URL] = []
    private var imagesByName: [String: [URL]] = [:]
    /// Folder path + file stem → image, for matching a label file to its image.
    private var imageByFolderAndStem: [String: URL] = [:]

    /// Everything under `root`, a few levels deep (splits and their
    /// `images`/`labels` folders), hidden files skipped.
    init(root: URL) {
        self.root = root
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        var found: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if enumerator?.level ?? 0 > 6 { enumerator?.skipDescendants(); continue }
            found.append(url.standardizedFileURL)
        }
        index(found.sorted { $0.path < $1.path })
    }

    /// A single annotation file plus the images around it.
    init(root: URL, only file: URL) {
        self.init(root: root)
        all = all.filter { $0.pathExtension.lowercased() != "json" } + [file.standardizedFileURL]
    }

    private mutating func index(_ urls: [URL]) {
        all = urls
        images = urls.filter(ImageImporter.isImageFile)
        imagesByName = Dictionary(grouping: images, by: \.lastPathComponent)
        for image in images {
            let key = Self.key(image.deletingLastPathComponent().path, image.deletingPathExtension().lastPathComponent)
            if imageByFolderAndStem[key] == nil { imageByFolderAndStem[key] = image }
        }
    }

    private static func key(_ folder: String, _ stem: String) -> String { folder + "\u{0}" + stem }

    /// The image at `url`, if it is one of the image files found under `root`.
    /// A path that leads anywhere else — outside the dataset, or to a file
    /// that isn't an image — is nil.
    func listedImage(at url: URL) -> URL? {
        let path = url.standardizedFileURL.path
        return imagesByName[url.lastPathComponent]?.first { $0.path == path }
    }

    func named(_ name: String) -> [URL] {
        all.filter { $0.lastPathComponent == name }
    }

    /// JSON files that are COCO annotation files (checked by content, since
    /// their names follow no single convention).
    func cocoFiles() -> [URL] {
        all.filter { $0.pathExtension.lowercased() == "json" }.filter { url in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return object["images"] is [Any] && object["annotations"] is [Any] && object["categories"] is [Any]
        }
    }

    /// An image by file name: next to `directory` if there, otherwise the only
    /// one of that name anywhere in the dataset.
    func image(named name: String, near directory: URL) -> URL? {
        let candidates = imagesByName[name] ?? []
        let base = directory.standardizedFileURL.path
        return candidates.first { $0.path.hasPrefix(base + "/") } ?? (candidates.count == 1 ? candidates[0] : nil)
    }

    // MARK: YOLO layout

    /// Label files: `.txt` files that have an image of the same name, either
    /// beside them or in the matching `images` folder. (This is what tells
    /// them apart from `classes.txt` and READMEs.)
    func yoloLabelFiles() -> [URL] {
        all.filter { $0.pathExtension.lowercased() == "txt" && yoloImage(forLabel: $0) != nil }
    }

    /// `…/labels/train/a.txt` ↔ `…/images/train/a.jpg`, or the image beside it.
    func yoloImage(forLabel label: URL) -> URL? {
        let stem = label.deletingPathExtension().lastPathComponent
        var folders = [label.deletingLastPathComponent().path]
        var components = label.deletingLastPathComponent().pathComponents
        if let index = components.lastIndex(of: "labels") {
            components[index] = "images"
            folders.append(NSString.path(withComponents: components))
        }
        return folders.lazy.compactMap { imageByFolderAndStem[Self.key($0, stem)] }.first
    }
}
