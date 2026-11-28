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
        /// Act on an image supplied with no boxes: record it as a negative
        /// example (an entry with zero annotations), which in `replace` mode
        /// also means clearing the boxes it had. Off by default, in both
        /// modes, so that "the detector found nothing" never silently becomes
        /// training signal or wipes existing labels.
        public var recordNegatives: Bool
        /// In `add` mode, also treat two overlapping same-label boxes within
        /// the input as one. Right for a model's answer, where that is a
        /// repeated detection; wrong for an existing dataset, where crowded
        /// objects legitimately overlap, so `import` turns it off.
        public var dedupeWithinInput: Bool

        public init(mode: Mode = .add, dedupeIoU: CGFloat = 0.5, recordNegatives: Bool = false,
                    dedupeWithinInput: Bool = true) {
            self.mode = mode
            self.dedupeIoU = dedupeIoU
            self.recordNegatives = recordNegatives
            self.dedupeWithinInput = dedupeWithinInput
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

            // "No boxes" only means something when asked for; and an image
            // whose every box was refused is left alone rather than emptied.
            if supplied.isEmpty ? !options.recordNegatives : resolved.isEmpty { continue }

            var boxes = existingIndex.map { document.records[$0].boxes } ?? []
            var added = 0, duplicates = 0, removed = 0
            switch options.mode {
            case .add:
                let alreadyThere = boxes
                for candidate in resolved {
                    let known = options.dedupeWithinInput ? boxes : alreadyThere
                    if known.contains(where: { isSameBox($0, candidate, threshold: options.dedupeIoU) }) {
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
            } else {
                newRecords.append(ImageAnnotationRecord(image: image, boxes: boxes))
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

        // Judge the numbers as given: CGRect's own accessors would quietly
        // flip a negative width or height into a positive one.
        let given: CGRect
        switch box.geometry {
        case .pixels(let rect), .normalized(let rect), .scaledPixels(let rect, _): given = rect
        }
        guard given.origin.x.isFinite, given.origin.y.isFinite,
              given.size.width.isFinite, given.size.height.isFinite,
              given.size.width > 0, given.size.height > 0 else {
            return .failure(BoxImportError(message: "width and height must be positive"))
        }

        var rect: CGRect
        switch box.geometry {
        case .pixels:
            rect = given
        case .scaledPixels(_, let reference):
            guard let imageSize else {
                return .failure(BoxImportError(
                    message: "coordinates measured on a \(Int(reference.width))x\(Int(reference.height)) copy "
                        + "need the image's own size, and the file can't be read"))
            }
            // A size that is the image's own turned on its side means the
            // numbers were measured before the photo's EXIF rotation. Which way
            // it was turned isn't known here, so scaling would place the box
            // somewhere wrong without saying so.
            if imageSize != reference, reference.width == imageSize.height, reference.height == imageSize.width {
                return .failure(BoxImportError(
                    message: "coordinates are for the image before its EXIF rotation "
                        + "(\(Int(reference.width))x\(Int(reference.height)) stored, "
                        + "\(Int(imageSize.width))x\(Int(imageSize.height)) as displayed)"))
            }
            // Same size (the usual case, e.g. `labelkit detect` output): the
            // numbers are used as they are, with no float round trip.
            // Otherwise scale from the copy to the real image.
            let sx = imageSize.width / reference.width, sy = imageSize.height / reference.height
            rect = imageSize == reference ? given : CGRect(
                x: given.minX * sx, y: given.minY * sy, width: given.width * sx, height: given.height * sy)
        case .normalized:
            guard let imageSize else {
                return .failure(BoxImportError(
                    message: "normalized coordinates need the image's size, and the file can't be read"))
            }
            rect = CGRect(x: given.minX * imageSize.width, y: given.minY * imageSize.height,
                          width: given.width * imageSize.width, height: given.height * imageSize.height)
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
        // Coordinates are saved to 2 decimals, so a box under a pixel can round
        // to nothing on disk — and then never match itself on a second run.
        guard rect.width >= 1, rect.height >= 1 else {
            return .failure(BoxImportError(message: "smaller than one pixel"))
        }
        // Hold the values the file will hold, so comparing records is the same
        // as comparing saved bytes.
        return .success((BoxRecord(label: label, x: saved(rect.midX), y: saved(rect.midY),
                                   width: saved(rect.width), height: saved(rect.height)), wasClamped))
    }

    /// A coordinate at the precision `CreateMLWriter` stores.
    private static func saved(_ value: CGFloat) -> Double {
        (Double(value) * 100).rounded() / 100
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
