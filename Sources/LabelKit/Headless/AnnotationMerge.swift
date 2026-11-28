import CoreGraphics
import Foundation

/// Applies imported boxes to a `DatasetDocument` — the write path behind
/// `labelkit annotate`.
///
/// Built for callers that retry: in the default `add` mode a box that already
/// exists (same label, overlapping an existing one) is skipped, so sending the
/// same input twice changes nothing and saves the same bytes. Geometry is
/// resolved against the real image: normalized boxes are scaled, boxes hanging
/// over an edge are clamped, and boxes that end up empty are rejected rather
/// than written.
public enum AnnotationMerge {
    public enum Mode: String, Sendable, CaseIterable {
        /// Keep existing boxes; add the new ones that aren't already there.
        case add
        /// The listed images get exactly the supplied boxes; other images are
        /// untouched.
        case replace
    }

    public struct Options: Sendable {
        public var mode: Mode
        /// In `add` mode, a new box overlapping an existing same-label box by
        /// more than this IoU counts as already present.
        public var dedupeIoU: CGFloat
        /// Record an image supplied with no boxes as a negative example (an
        /// entry with zero annotations). Off by default so that "the detector
        /// found nothing" is never silently turned into training signal.
        public var recordNegatives: Bool

        public init(mode: Mode = .add, dedupeIoU: CGFloat = 0.5, recordNegatives: Bool = false) {
            self.mode = mode
            self.dedupeIoU = dedupeIoU
            self.recordNegatives = recordNegatives
        }
    }

    /// What happened to one image. Counts are boxes.
    public struct ImageOutcome: Codable, Equatable, Sendable {
        public var image: String
        /// Boxes written by this run.
        public var added: Int
        /// Supplied boxes skipped because an equivalent one already existed.
        public var duplicates: Int
        /// Existing boxes removed (`replace` mode only).
        public var removed: Int
        /// Supplied boxes that had to be trimmed to the image bounds.
        public var clamped: Int
        /// Boxes on the image after this run.
        public var total: Int
        /// True when the image had no entry in the annotations file before.
        public var created: Bool
    }

    /// Input that could not be applied. Any problem makes the run fail unless
    /// the caller opts into applying the rest.
    public struct Problem: Codable, Equatable, Sendable {
        public var image: String
        public var message: String
    }

    public struct Result: Equatable, Sendable {
        public var outcomes: [ImageOutcome]
        public var problems: [Problem]
        /// True when the document's records differ from before the run.
        public var changed: Bool
    }

    /// - Parameter pixelSize: display-orientation size of a dataset image, or
    ///   nil if it can't be read. Injected so the merge stays pure and testable.
    public static func apply(
        _ imports: [ImportedImage],
        to document: inout DatasetDocument,
        options: Options = Options(),
        pixelSize: (String) -> CGSize?
    ) -> Result {
        let before = document.records
        let onDisk = Set(document.imagesOnDisk)
        var indexByImage: [String: Int] = [:]
        for (index, record) in document.records.enumerated() where indexByImage[record.image] == nil {
            indexByImage[record.image] = index
        }

        // Several input entries for one image are one request for that image.
        var order: [String] = []
        var grouped: [String: [ImportedBox]] = [:]
        for item in imports {
            if grouped[item.image] == nil { order.append(item.image) }
            grouped[item.image, default: []].append(contentsOf: item.boxes)
        }

        var outcomes: [ImageOutcome] = []
        var problems: [Problem] = []
        var newRecords: [ImageAnnotationRecord] = []

        for image in order {
            let supplied = grouped[image] ?? []
            let existingIndex = indexByImage[image]
            guard existingIndex != nil || onDisk.contains(image) else {
                problems.append(Problem(image: image, message: "no such image in the dataset"))
                continue
            }

            let size = pixelSize(image)
            var resolved: [BoxRecord] = []
            var clamped = 0
            for (offset, box) in supplied.enumerated() {
                switch resolve(box, imageSize: size) {
                case .success(let (record, wasClamped)):
                    resolved.append(record)
                    if wasClamped { clamped += 1 }
                case .failure(let reason):
                    problems.append(Problem(image: image, message: "box #\(offset + 1) (\(box.label)): \(reason.message)"))
                }
            }

            var boxes = existingIndex.map { document.records[$0].boxes } ?? []
            var added = 0, duplicates = 0, removed = 0
            switch options.mode {
            case .add:
                for candidate in resolved {
                    if boxes.contains(where: { isSameBox($0, candidate, threshold: options.dedupeIoU) }) {
                        duplicates += 1
                    } else {
                        boxes.append(candidate)
                        added += 1
                    }
                }
            case .replace:
                removed = boxes.count
                boxes = resolved
                added = resolved.count
            }

            if let existingIndex {
                document.records[existingIndex].boxes = boxes
            } else if !boxes.isEmpty || options.recordNegatives {
                newRecords.append(ImageAnnotationRecord(image: image, boxes: boxes))
            } else {
                continue  // nothing to record for an image with no entry and no boxes
            }
            outcomes.append(ImageOutcome(
                image: image, added: added, duplicates: duplicates, removed: removed,
                clamped: clamped, total: boxes.count, created: existingIndex == nil))
        }

        // New entries go after the existing ones in name order — the same place
        // the editor puts them — so the file doesn't depend on input order.
        newRecords.sort { $0.image.localizedStandardCompare($1.image) == .orderedAscending }
        document.records.append(contentsOf: newRecords)

        return Result(outcomes: outcomes, problems: problems, changed: document.records != before)
    }

    // MARK: - Geometry

    private static func resolve(
        _ box: ImportedBox, imageSize: CGSize?
    ) -> Swift.Result<(BoxRecord, Bool), BoxImportError> {
        let label = box.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return .failure(BoxImportError(message: "empty label")) }

        var rect: CGRect
        switch box.geometry {
        case .pixels(let pixels):
            rect = pixels
        case .scaledPixels(let pixels, let reference):
            // Same size (the usual case, e.g. `labelkit detect` output), or no
            // way to tell: the numbers are used as they are, with no float
            // round trip. Otherwise scale from the copy to the real image.
            if let imageSize, imageSize != reference {
                let sx = imageSize.width / reference.width, sy = imageSize.height / reference.height
                rect = CGRect(x: pixels.minX * sx, y: pixels.minY * sy,
                              width: pixels.width * sx, height: pixels.height * sy)
            } else {
                rect = pixels
            }
        case .normalized(let fraction):
            guard let imageSize else {
                return .failure(BoxImportError(
                    message: "normalized coordinates need the image's size, and the file can't be read"))
            }
            rect = CGRect(x: fraction.minX * imageSize.width, y: fraction.minY * imageSize.height,
                          width: fraction.width * imageSize.width, height: fraction.height * imageSize.height)
        }
        guard rect.width.isFinite, rect.height.isFinite, rect.minX.isFinite, rect.minY.isFinite,
              rect.width > 0, rect.height > 0 else {
            return .failure(BoxImportError(message: "width and height must be positive"))
        }

        var wasClamped = false
        // A box already inside its image is written exactly as given; only one
        // that reaches past an edge is trimmed.
        if let imageSize, !CGRect(origin: .zero, size: imageSize).contains(rect) {
            let inside = rect.intersection(CGRect(origin: .zero, size: imageSize))
            guard !inside.isNull, inside.width >= 1, inside.height >= 1 else {
                return .failure(BoxImportError(
                    message: "lies outside the image (\(Int(imageSize.width))x\(Int(imageSize.height)))"))
            }
            // Sub-pixel overhang is rounding noise, not a mistake worth reporting.
            wasClamped = abs(inside.width - rect.width) > 0.5 || abs(inside.height - rect.height) > 0.5
            rect = inside
        }
        return .success((BoxRecord(label: label, x: rect.midX, y: rect.midY,
                                   width: rect.width, height: rect.height), wasClamped))
    }

    private static func isSameBox(_ a: BoxRecord, _ b: BoxRecord, threshold: CGFloat) -> Bool {
        a.label == b.label && DetectionMerge.iou(a.rect, b.rect) > threshold
    }
}

/// What `labelkit annotate` prints: the outcome of one run, per image and in
/// total, plus anything that could not be applied.
public struct AnnotateReport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var labelkit: String
    public var dataset: String
    public var annotations: String
    /// `add` or `replace`.
    public var mode: String
    public var dryRun: Bool
    /// True when the annotations file was rewritten by this run.
    public var written: Bool
    public var totals: Totals
    public var images: [AnnotationMerge.ImageOutcome]
    public var problems: [AnnotationMerge.Problem]

    public struct Totals: Codable, Equatable, Sendable {
        public var images: Int
        public var added: Int
        public var duplicates: Int
        public var removed: Int
        public var clamped: Int
    }

    public static func make(
        document: DatasetDocument, result: AnnotationMerge.Result, mode: AnnotationMerge.Mode,
        dryRun: Bool, written: Bool, labelkitVersion version: String = labelkitVersion
    ) -> AnnotateReport {
        let outcomes = result.outcomes
        return AnnotateReport(
            schemaVersion: 1, labelkit: version,
            dataset: document.location.imagesDirectory.path,
            annotations: document.location.annotationsURL.path,
            mode: mode.rawValue, dryRun: dryRun, written: written,
            totals: Totals(
                images: outcomes.count,
                added: outcomes.reduce(0) { $0 + $1.added },
                duplicates: outcomes.reduce(0) { $0 + $1.duplicates },
                removed: outcomes.reduce(0) { $0 + $1.removed },
                clamped: outcomes.reduce(0) { $0 + $1.clamped }),
            images: outcomes, problems: result.problems)
    }
}
