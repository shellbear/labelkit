import Foundation

/// What `labelkit stats` reports: enough for a script or an agent to decide
/// what to do next (which images still need labels, which labels are thin)
/// without parsing the annotations file itself.
public struct DatasetSummary: Codable, Equatable, Sendable {
    /// Output schema version — bump on any breaking field change.
    public var schemaVersion: Int
    public var labelkit: String
    /// Absolute path of the images directory.
    public var dataset: String
    /// Absolute path of the annotations file.
    public var annotations: String
    /// False when the annotations file doesn't exist yet.
    public var annotationsExists: Bool
    public var images: ImageCounts
    /// Total boxes across the dataset.
    public var boxes: Int
    /// How boxes are spread over the images that have any. An image far above
    /// the median is worth a look: one crowded outlier can skew a model.
    public var boxesPerImage: BoxSpread?
    /// Most-used label first; ties broken by name.
    public var labels: [LabelCount]
    /// Images on disk with no entry in the annotations file.
    public var unlabeled: [String]
    /// Entries whose image file is missing on disk.
    public var missing: [String]
    /// One row per image, when asked for.
    public var perImage: [ImageRow]?

    public struct ImageCounts: Codable, Equatable, Sendable {
        /// Every image the dataset knows about: on disk or in the file.
        public var total: Int
        public var onDisk: Int
        /// Entries with at least one box.
        public var annotated: Int
        /// Entries with zero boxes — negative examples.
        public var negatives: Int
        /// On disk, no entry yet.
        public var unlabeled: Int
        /// In the file, not on disk.
        public var missing: Int
    }

    public struct BoxSpread: Codable, Equatable, Sendable {
        public var min: Int
        public var median: Double
        public var max: Int
        /// The image holding `max` boxes (the first, if several tie).
        public var maxImage: String
    }

    public struct LabelCount: Codable, Equatable, Sendable {
        public var label: String
        /// Boxes carrying this label.
        public var boxes: Int
        /// Images with at least one box of this label.
        public var images: Int
    }

    public struct ImageRow: Codable, Equatable, Sendable {
        public var image: String
        public var status: Status
        public var boxes: Int
        public var labels: [String]
    }

    public enum Status: String, Codable, Sendable {
        case annotated, negative, unlabeled, missing
    }
}

public extension DatasetSummary {
    static func make(
        of document: DatasetDocument,
        includePerImage: Bool = false,
        labelkitVersion version: String = labelkitVersion
    ) -> DatasetSummary {
        let onDisk = Set(document.imagesOnDisk)
        // A file can list one image twice; summarize what the editor would show.
        let records = document.uniqueRecords
        let inFile = Set(records.map(\.image))

        var boxCount: [String: Int] = [:]
        var imageCount: [String: Int] = [:]
        var totalBoxes = 0
        for record in records {
            totalBoxes += record.boxes.count
            for box in record.boxes { boxCount[box.label, default: 0] += 1 }
            for label in Set(record.boxes.map(\.label)) { imageCount[label, default: 0] += 1 }
        }
        let labels = boxCount
            .map { LabelCount(label: $0.key, boxes: $0.value, images: imageCount[$0.key] ?? 0) }
            .sorted { $0.boxes != $1.boxes ? $0.boxes > $1.boxes : $0.label < $1.label }

        var spread: BoxSpread?
        let annotatedRecords = records.filter { !$0.boxes.isEmpty }
        if let busiest = annotatedRecords.max(by: { $0.boxes.count < $1.boxes.count }) {
            let counts = annotatedRecords.map(\.boxes.count).sorted()
            let middle = counts.count / 2
            let median = counts.count % 2 == 1
                ? Double(counts[middle]) : Double(counts[middle - 1] + counts[middle]) / 2
            // max(by:) returns the last of equal elements; report the first.
            let first = annotatedRecords.first { $0.boxes.count == busiest.boxes.count } ?? busiest
            spread = BoxSpread(min: counts[0], median: median, max: busiest.boxes.count, maxImage: first.image)
        }

        let unlabeled = document.imagesOnDisk.filter { !inFile.contains($0) }
        let missing = records.map(\.image).filter { !onDisk.contains($0) }
        let annotated = records.filter { !$0.boxes.isEmpty }.count

        var rows: [ImageRow]?
        if includePerImage {
            let recordByImage = Dictionary(records.map { ($0.image, $0) }, uniquingKeysWith: { first, _ in first })
            var built: [ImageRow] = document.imagesOnDisk.map { name in
                guard let record = recordByImage[name] else {
                    return ImageRow(image: name, status: .unlabeled, boxes: 0, labels: [])
                }
                return ImageRow(image: name, status: record.boxes.isEmpty ? .negative : .annotated,
                                boxes: record.boxes.count, labels: Set(record.boxes.map(\.label)).sorted())
            }
            built += records.filter { !onDisk.contains($0.image) }.map {
                ImageRow(image: $0.image, status: .missing, boxes: $0.boxes.count,
                         labels: Set($0.boxes.map(\.label)).sorted())
            }
            rows = built
        }

        return DatasetSummary(
            schemaVersion: 1, labelkit: version,
            dataset: document.location.imagesDirectory.path,
            annotations: document.location.annotationsURL.path,
            annotationsExists: document.location.annotationsExists,
            images: ImageCounts(
                total: onDisk.union(inFile).count, onDisk: onDisk.count, annotated: annotated,
                negatives: records.count - annotated, unlabeled: unlabeled.count, missing: missing.count),
            boxes: totalBoxes, boxesPerImage: spread, labels: labels,
            unlabeled: unlabeled, missing: missing, perImage: rows)
    }
}
