import CoreGraphics
import Foundation

/// Writes a Create ML dataset out in another layout, into a fresh folder. The
/// dataset itself is only read.
///
/// What is exported is what a trainer would see: every entry whose image file
/// exists, negatives included. Images with no entry are unlabelled work in
/// progress and are left out. Class ids follow the labels in alphabetical
/// order, so the same dataset always exports the same numbering.
public enum DatasetExport {
    public struct Options: Sendable {
        public var format: DatasetFormat
        /// Copy the image files alongside the annotations. On APFS a copy is a
        /// clone and takes no extra space until one side changes.
        public var copyImages: Bool

        public init(format: DatasetFormat, copyImages: Bool = true) {
            self.format = format
            self.copyImages = copyImages
        }
    }

    public struct Report: Codable, Equatable, Sendable {
        public var schemaVersion: Int
        public var labelkit: String
        public var dataset: String
        public var out: String
        public var format: String
        /// Images written to the export (entries with a file on disk).
        public var images: Int
        public var boxes: Int
        /// Class names in id order.
        public var labels: [String]
        /// Entries left out, each with the reason.
        public var skipped: [Skipped]
        /// The annotation files written, relative to `out`.
        public var files: [String]

        public struct Skipped: Codable, Equatable, Sendable {
            public var image: String
            public var reason: String
        }
    }

    public struct ExportError: LocalizedError, Equatable {
        public var message: String
        /// True when the call was wrong (a bad `--out`), as opposed to a
        /// dataset that can't be exported as it stands.
        public var isUsage = false
        public var errorDescription: String? { message }
    }

    /// Hugging Face asks for at most 10,000 entries per folder; stay well under.
    static let imagesPerFolder = 5_000

    /// - Parameter pixelSize: display-orientation size of a dataset image, or
    ///   nil if it can't be read. YOLO and COCO need it; such images are skipped.
    public static func run(
        _ document: DatasetDocument,
        to out: URL,
        options: Options,
        labelkitVersion version: String = labelkitVersion,
        pixelSize: (String) -> CGSize?
    ) throws -> Report {
        let fm = FileManager.default
        guard !document.isImagesDirectory(out) else {
            throw ExportError(message: "the output folder is the dataset itself; choose another directory",
                              isUsage: true)
        }
        // Finder's .DS_Store and the like don't make a folder "not empty".
        let existed = fm.fileExists(atPath: out.path)
        if let existing = try? fm.contentsOfDirectory(atPath: out.path),
           existing.contains(where: { !$0.hasPrefix(".") }) {
            throw ExportError(message: "\(out.path) is not empty; export into a new or empty directory",
                              isUsage: true)
        }
        do {
            return try write(document, to: out, options: options, version: version, pixelSize: pixelSize)
        } catch {
            // A half-written export would be refused as "not empty" next time.
            if !existed { try? fm.removeItem(at: out) }
            throw error
        }
    }

    private static func write(
        _ document: DatasetDocument, to out: URL, options: Options, version: String,
        pixelSize: (String) -> CGSize?
    ) throws -> Report {
        let fm = FileManager.default

        let onDisk = Set(document.imagesOnDisk)
        var skipped: [Report.Skipped] = []
        var entries: [(record: ImageAnnotationRecord, size: CGSize?)] = []
        for record in document.uniqueRecords {
            guard onDisk.contains(record.image) else {
                skipped.append(.init(image: record.image, reason: "image file not found"))
                continue
            }
            let size = pixelSize(record.image)
            if options.format != .huggingface, size == nil {
                skipped.append(.init(image: record.image, reason: "couldn't read the image's size"))
                continue
            }
            entries.append((record, size))
        }
        let labels = Set(entries.flatMap { $0.record.boxes.map(\.label) }).sorted()
        let classID = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($1, $0) })

        // Where each image goes inside the export, relative to `out`.
        let imagePaths: [String]
        var files: [String]
        switch options.format {
        case .yolo:
            let stems = entries.map { ($0.record.image as NSString).deletingPathExtension.lowercased() }
            if let clash = Dictionary(grouping: stems, by: { $0 }).first(where: { $1.count > 1 })?.key {
                throw ExportError(message: "two images are named '\(clash)' with different extensions; "
                    + "YOLO pairs images and labels by name, so rename one first")
            }
            imagePaths = entries.map { "images/" + $0.record.image }
            try fm.createDirectory(at: out.appendingPathComponent("labels"), withIntermediateDirectories: true)
            for (record, size) in entries {
                let stem = (record.image as NSString).deletingPathExtension
                try yoloRows(record.boxes, size: size ?? .zero, classID: classID)
                    .write(to: out.appendingPathComponent("labels/\(stem).txt"), atomically: true, encoding: .utf8)
            }
            try (labels.joined(separator: "\n") + "\n")
                .write(to: out.appendingPathComponent("classes.txt"), atomically: true, encoding: .utf8)
            try yoloConfig(labels).write(to: out.appendingPathComponent("data.yaml"), atomically: true, encoding: .utf8)
            files = ["data.yaml", "classes.txt", "labels/"]

        case .coco:
            imagePaths = entries.map(\.record.image)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            try coco(entries, labels: labels, classID: classID)
                .write(to: out.appendingPathComponent("_annotations.coco.json"), options: .atomic)
            files = ["_annotations.coco.json"]

        case .huggingface:
            let shard = entries.count > imagesPerFolder
            imagePaths = entries.enumerated().map { index, entry in
                shard ? String(format: "train/images/%03d/", index / imagesPerFolder) + entry.record.image
                      : "train/images/" + entry.record.image
            }
            try fm.createDirectory(at: out.appendingPathComponent("train"), withIntermediateDirectories: true)
            // metadata.jsonl sits in train/, so file_name is relative to that.
            let rows = try zip(entries, imagePaths).map { entry, path in
                try huggingFaceRow(entry.record, fileName: String(path.dropFirst("train/".count)))
            }
            try (rows.joined(separator: "\n") + "\n")
                .write(to: out.appendingPathComponent("train/metadata.jsonl"), atomically: true, encoding: .utf8)
            try datasetCard(name: document.location.displayName, labels: labels, images: entries.count)
                .write(to: out.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            files = ["README.md", "train/metadata.jsonl"]
        }

        if options.copyImages {
            for (entry, path) in zip(entries, imagePaths) {
                let destination = out.appendingPathComponent(path)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                // The file itself, even when the dataset holds a symlink to it.
                try fm.copyItem(at: document.imageURL(for: entry.record.image).resolvingSymlinksInPath(),
                                to: destination)
            }
            switch options.format {
            case .yolo: files.append("images/")
            case .coco: files.append("images alongside the JSON")
            case .huggingface: files.append("train/images/")
            }
        }

        return Report(
            schemaVersion: 1, labelkit: version,
            dataset: document.location.imagesDirectory.path, out: out.path,
            format: options.format.rawValue, images: entries.count,
            boxes: entries.reduce(0) { $0 + $1.record.boxes.count },
            labels: labels, skipped: skipped, files: files)
    }

    // MARK: - YOLO

    /// One `class cx cy w h` row per box, normalized, 6 decimals. An image with
    /// no boxes gets an empty file, which is how YOLO marks a background image.
    static func yoloRows(_ boxes: [BoxRecord], size: CGSize, classID: [String: Int]) -> String {
        guard size.width > 0, size.height > 0 else { return "" }
        return boxes.map { box in
            String(format: "%d %.6f %.6f %.6f %.6f\n", classID[box.label] ?? 0,
                   box.x / size.width, box.y / size.height, box.width / size.width, box.height / size.height)
        }.joined()
    }

    static func yoloConfig(_ labels: [String]) -> String {
        var text = "# Exported by labelkit. Every image is under train; make a validation split before training.\n"
        // No `path:` — YOLO tooling then resolves train/val against this file's
        // own folder, wherever the export is moved to.
        text += "train: images\nval: images\nnames:\n"
        for (index, label) in labels.enumerated() {
            text += "  \(index): \(yamlString(label))\n"
        }
        return text
    }

    // MARK: - COCO

    /// `bbox` is `[x, y, width, height]` in pixels from the top-left corner;
    /// ids start at 1, as COCO tools expect.
    static func coco(_ entries: [(record: ImageAnnotationRecord, size: CGSize?)],
                     labels: [String], classID: [String: Int]) throws -> Data {
        var images: [[String: Any]] = []
        var annotations: [[String: Any]] = []
        for (index, entry) in entries.enumerated() {
            let size = entry.size ?? .zero
            images.append(["id": index + 1, "file_name": entry.record.image,
                           "width": Int(size.width), "height": Int(size.height)])
            for box in entry.record.boxes {
                annotations.append([
                    "id": annotations.count + 1, "image_id": index + 1,
                    "category_id": (classID[box.label] ?? 0) + 1,
                    "bbox": pixelBox(box),
                    "area": hundredths(box.width * box.height), "iscrowd": 0,
                ])
            }
        }
        let root: [String: Any] = [
            "info": ["description": "Exported by labelkit"],
            "images": images, "annotations": annotations,
            "categories": labels.enumerated().map { ["id": $0 + 1, "name": $1] },
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - Hugging Face

    /// The row shape from Hugging Face's image-dataset docs. Categories are
    /// written as names rather than ids, so the file needs no side table.
    static func huggingFaceRow(_ record: ImageAnnotationRecord, fileName: String) throws -> String {
        let row: [String: Any] = [
            "file_name": fileName,
            "objects": [
                "bbox": record.boxes.map(pixelBox),
                "categories": record.boxes.map(\.label),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func datasetCard(name: String, labels: [String], images: Int) -> String {
        """
        ---
        pretty_name: \(yamlString(name))
        task_categories:
        - object-detection
        tags:
        - labelkit
        - createml
        ---

        # \(name)

        An object-detection dataset of \(images) images, exported from an Apple Create ML
        dataset with [labelkit](https://github.com/shellbear/labelkit).

        Boxes are in `train/metadata.jsonl` as `objects.bbox` — `[x, y, width, height]` in
        pixels from the top-left corner — with the matching class names in
        `objects.categories`.

        Classes: \(labels.map { "`\($0)`" }.joined(separator: ", "))

        Add a `license:` to the YAML above before publishing. To turn this back into a
        Create ML dataset: `labelkit import <this folder> --into <dataset>`.

        """
    }

    // MARK: - Helpers

    /// `[x, y, width, height]` in pixels from the top-left corner, as COCO and
    /// Hugging Face both write a box.
    private static func pixelBox(_ box: BoxRecord) -> [NSDecimalNumber] {
        [hundredths(box.rect.minX), hundredths(box.rect.minY), hundredths(box.width), hundredths(box.height)]
    }

    /// A coordinate at labelkit's 2-decimal precision, as a decimal number so
    /// JSON prints `810.03` rather than the nearest binary double's
    /// `810.02999999999997`.
    private static func hundredths(_ value: CGFloat) -> NSDecimalNumber {
        NSDecimalNumber(string: CreateMLWriter.coordString(Double(value)))
    }

    /// A YAML scalar that is safe whatever the label contains.
    private static func yamlString(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
