import CoreGraphics
import Foundation

/// What `labelkit validate` reports. Errors are things that make a dataset
/// wrong to train on; warnings are things worth a look. Nothing here modifies
/// the dataset.
public struct ValidationReport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var labelkit: String
    public var dataset: String
    public var annotations: String
    /// True when there are no errors (warnings don't count).
    public var ok: Bool
    public var errors: Int
    public var warnings: Int
    public var issues: [Issue]

    public struct Issue: Codable, Equatable, Sendable {
        public var severity: Severity
        /// Stable machine-readable identifier; see `Code`.
        public var code: Code
        public var image: String?
        /// 1-based position of the box within the image's annotations.
        public var box: Int?
        public var label: String?
        public var message: String
    }

    public enum Severity: String, Codable, Sendable { case error, warning }

    public enum Code: String, Codable, Sendable, CaseIterable {
        /// The annotations file doesn't exist.
        case noAnnotationsFile = "no-annotations-file"
        /// The annotations file exists but can't be read as Create ML JSON.
        case invalidAnnotationsFile = "invalid-annotations-file"
        /// An entry's image file is not on disk.
        case missingImage = "missing-image"
        /// An image file exists but its size can't be read.
        case unreadableImage = "unreadable-image"
        /// The same image has more than one entry.
        case duplicateEntry = "duplicate-entry"
        /// A box has an empty label.
        case emptyLabel = "empty-label"
        /// A box has a zero or negative width or height.
        case emptyBox = "empty-box"
        /// A box lies entirely outside its image.
        case boxOutsideImage = "box-outside-image"
        /// A box extends past an image edge.
        case boxOverflowsImage = "box-overflows-image"
        /// Two boxes on an image have the same label and near-identical geometry.
        case duplicateBox = "duplicate-box"
        /// Two labelled images are the same file under different names.
        case duplicateImage = "duplicate-image"
        /// A label is not in the allowed set.
        case unknownLabel = "unknown-label"
        /// An allowed label has no boxes at all.
        case unusedLabel = "unused-label"
    }
}

public extension ValidationReport {
    /// The report for a dataset whose annotations file can't be read at all:
    /// one error saying why, so `validate` still answers on stdout.
    static func unreadable(
        location: DatasetLocation, reason: String, labelkitVersion version: String = labelkitVersion
    ) -> ValidationReport {
        ValidationReport(
            schemaVersion: 1, labelkit: version,
            dataset: location.imagesDirectory.path, annotations: location.annotationsURL.path,
            ok: false, errors: 1, warnings: 0,
            issues: [Issue(severity: .error, code: .invalidAnnotationsFile, image: nil, box: nil, label: nil,
                           message: "the annotations file can't be read: \(reason)")])
    }
}

public enum DatasetValidator {
    public struct Options: Sendable {
        /// When set, any other label is an error and any of these with no boxes
        /// is a warning.
        public var allowedLabels: [String]?
        /// Same-label boxes overlapping by more than this IoU are duplicates.
        public var duplicateIoU: CGFloat
        /// How far (pixels) a box may hang over an edge before it's reported.
        public var overflowTolerance: CGFloat
        /// Groups of labelled images with identical file contents (see
        /// `DuplicateImages`); each image after the first in a group is reported.
        public var duplicateImages: [[String]]

        public init(allowedLabels: [String]? = nil, duplicateIoU: CGFloat = 0.95,
                    overflowTolerance: CGFloat = 1, duplicateImages: [[String]] = []) {
            self.allowedLabels = allowedLabels
            self.duplicateIoU = duplicateIoU
            self.overflowTolerance = overflowTolerance
            self.duplicateImages = duplicateImages
        }
    }

    /// - Parameter pixelSize: display-orientation size of a dataset image, or
    ///   nil if it can't be read. Injected so validation stays pure and testable.
    public static func validate(
        _ document: DatasetDocument,
        options: Options = Options(),
        labelkitVersion version: String = labelkitVersion,
        pixelSize: (String) -> CGSize?
    ) -> ValidationReport {
        typealias Issue = ValidationReport.Issue
        var issues: [Issue] = []
        let onDisk = Set(document.imagesOnDisk)
        let allowed = options.allowedLabels.map(Set.init)

        if !document.location.annotationsExists {
            issues.append(Issue(severity: .error, code: .noAnnotationsFile, image: nil, box: nil, label: nil,
                                message: "no annotations file at \(document.location.annotationsURL.path)"))
        }

        var seenImages = Set<String>()
        var usedLabels = Set<String>()
        for record in document.records {
            let image = record.image
            if !seenImages.insert(image).inserted {
                issues.append(Issue(severity: .error, code: .duplicateEntry, image: image, box: nil, label: nil,
                                    message: "more than one entry for this image; only the first is used"))
                continue
            }

            var size: CGSize?
            if !onDisk.contains(image) {
                issues.append(Issue(severity: .error, code: .missingImage, image: image, box: nil, label: nil,
                                    message: "image file not found in the dataset directory"))
            } else if let read = pixelSize(image) {
                size = read
            } else {
                issues.append(Issue(severity: .warning, code: .unreadableImage, image: image, box: nil, label: nil,
                                    message: "couldn't read the image's size; its boxes weren't bounds-checked"))
            }

            let rects = record.boxes.map(\.rect)
            for (index, box) in record.boxes.enumerated() {
                let number = index + 1
                let rect = rects[index]
                usedLabels.insert(box.label)

                if box.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(Issue(severity: .error, code: .emptyLabel, image: image, box: number,
                                        label: box.label, message: "box has an empty label"))
                } else if let allowed, !allowed.contains(box.label) {
                    issues.append(Issue(severity: .error, code: .unknownLabel, image: image, box: number,
                                        label: box.label, message: "label '\(box.label)' is not in the allowed set"))
                }

                guard box.width > 0, box.height > 0 else {
                    issues.append(Issue(severity: .error, code: .emptyBox, image: image, box: number,
                                        label: box.label, message: "box has no area (\(describe(box)))"))
                    continue
                }
                if let size {
                    let bounds = CGRect(origin: .zero, size: size)
                    let inside = rect.intersection(bounds)
                    let dimensions = "\(Int(size.width))x\(Int(size.height))"
                    if inside.isNull || inside.width <= 0 || inside.height <= 0 {
                        issues.append(Issue(severity: .error, code: .boxOutsideImage, image: image, box: number,
                                            label: box.label,
                                            message: "box lies outside the \(dimensions) image (\(describe(box)))"))
                    } else if !bounds.insetBy(dx: -options.overflowTolerance, dy: -options.overflowTolerance)
                        .contains(rect) {
                        issues.append(Issue(severity: .warning, code: .boxOverflowsImage, image: image, box: number,
                                            label: box.label,
                                            message: "box extends past the edge of the \(dimensions) image (\(describe(box)))"))
                    }
                }
                // Report each duplicate once, on the later box.
                if let earlier = (0..<index).first(where: {
                    record.boxes[$0].label == box.label
                        && DetectionMerge.iou(rects[$0], rect) > options.duplicateIoU
                }) {
                    issues.append(Issue(severity: .warning, code: .duplicateBox, image: image, box: number,
                                        label: box.label,
                                        message: "near-identical to box #\(earlier + 1) with the same label"))
                }
            }
        }

        // The same photo under two names: flag the copies, and say when the
        // copies were labelled differently, since that is the harmful case.
        let boxesByImage = Dictionary(
            uniqueKeysWithValues: document.uniqueRecords.map { ($0.image, $0.boxes) })
        for group in options.duplicateImages {
            guard let original = group.first else { continue }
            for copy in group.dropFirst() {
                let differ = boxesByImage[copy] != boxesByImage[original]
                issues.append(Issue(
                    severity: .warning, code: .duplicateImage, image: copy, box: nil, label: nil,
                    message: "same file contents as '\(original)'"
                        + (differ ? ", and the two are labelled differently" : "")))
            }
        }

        for label in (options.allowedLabels ?? []) where !usedLabels.contains(label) {
            issues.append(Issue(severity: .warning, code: .unusedLabel, image: nil, box: nil, label: label,
                                message: "no boxes carry the label '\(label)'"))
        }

        let errors = issues.filter { $0.severity == .error }.count
        return ValidationReport(
            schemaVersion: 1, labelkit: version,
            dataset: document.location.imagesDirectory.path,
            annotations: document.location.annotationsURL.path,
            ok: errors == 0, errors: errors, warnings: issues.count - errors, issues: issues)
    }

    private static func describe(_ box: BoxRecord) -> String {
        let rect = box.rect
        return "x=\(CreateMLWriter.coordString(rect.minX)) y=\(CreateMLWriter.coordString(rect.minY)) "
            + "width=\(CreateMLWriter.coordString(box.width)) height=\(CreateMLWriter.coordString(box.height))"
    }
}
