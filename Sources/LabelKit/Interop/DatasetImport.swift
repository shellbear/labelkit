import CoreGraphics
import Foundation

/// Brings a dataset in another layout into a Create ML dataset: its images are
/// copied into the folder and its boxes merged into `annotations.json`.
///
/// It is built from the same parts as the rest of labelkit rather than beside
/// them — `ImageImporter` decides file names (never overwriting), and
/// `AnnotationMerge` writes the boxes — so an import has the properties an
/// `annotate` run has: running it twice changes nothing, and if anything in
/// the source can't be applied, nothing is copied or written.
public enum DatasetImport {
    public struct Options: Sendable {
        /// Record source images that have no boxes as negative examples.
        public var recordNegatives: Bool
        /// Apply what is valid instead of refusing the whole import.
        public var lenient: Bool
        /// Work everything out, copy and write nothing.
        public var dryRun: Bool

        public init(recordNegatives: Bool = false, lenient: Bool = false, dryRun: Bool = false) {
            self.recordNegatives = recordNegatives
            self.lenient = lenient
            self.dryRun = dryRun
        }
    }

    public struct Report: Codable, Equatable, Sendable {
        public var schemaVersion: Int
        public var labelkit: String
        public var dataset: String
        public var annotations: String
        /// `yolo`, `coco` or `huggingface`.
        public var format: String
        public var dryRun: Bool
        /// True when images were copied and/or the annotations file rewritten.
        public var written: Bool
        public var images: ImageCounts
        public var boxes: BoxCounts
        /// Labels found in the source, sorted.
        public var labels: [String]
        /// Images whose name was taken by a different file and were given a new one.
        public var renamed: [Rename]
        /// Source entries whose image file wasn't found; they are skipped.
        public var missing: [String]
        public var problems: [AnnotationMerge.Problem]

        public struct ImageCounts: Codable, Equatable, Sendable {
            /// Images in the source.
            public var found: Int
            /// Copied into the dataset by this run.
            public var copied: Int
            /// Already in the dataset (same name and size); not copied again.
            public var alreadyPresent: Int
        }

        public struct BoxCounts: Codable, Equatable, Sendable {
            public var added: Int
            public var duplicates: Int
            public var clamped: Int
        }

        public struct Rename: Codable, Equatable, Sendable {
            public var from: String
            public var to: String
        }
    }

    public static func run(
        _ foreign: ForeignDataset,
        into document: inout DatasetDocument,
        options: Options = Options(),
        labelkitVersion version: String = labelkitVersion
    ) throws -> Report {
        let directory = document.location.imagesDirectory
        let plan = ImageImporter.plan(
            sources: foreign.images.map(\.source), into: directory,
            reservedNames: Set(document.records.map(\.image)))

        // Sizes come from the source files, so nothing has to be copied before
        // it is known that the whole import can go through.
        let measured = foreign.images.map(\.source).concurrentMap(ImageMetadata.pixelSize(of:))
        var sizes: [String: CGSize] = [:]
        for (item, size) in zip(plan, measured) {
            if let size { sizes[item.finalName] = size }
        }

        var merged = document
        merged.imagesOnDisk = (document.imagesOnDisk + plan.map(\.finalName)).uniqued()
        let imports = zip(plan, foreign.images).map { ImportedImage(image: $0.finalName, boxes: $1.boxes) }
        let result = AnnotationMerge.apply(
            imports, to: &merged,
            options: .init(mode: .add, recordNegatives: options.recordNegatives),
            pixelSize: { sizes[$0] })

        let blocked = !result.problems.isEmpty && !options.lenient
        let toCopy = plan.filter(\.needsCopy)
        let apply = !options.dryRun && !blocked
        if apply {
            try ImageImporter.execute(plan, into: directory)
            if result.changed { try merged.save() }
            document = merged
        }

        let outcomes = result.outcomes
        return Report(
            schemaVersion: 1, labelkit: version,
            dataset: directory.path, annotations: document.location.annotationsURL.path,
            format: foreign.format.rawValue, dryRun: options.dryRun,
            written: apply && (result.changed || !toCopy.isEmpty),
            images: .init(found: foreign.images.count, copied: toCopy.count,
                          alreadyPresent: plan.count - toCopy.count),
            boxes: .init(added: outcomes.reduce(0) { $0 + $1.added },
                         duplicates: outcomes.reduce(0) { $0 + $1.duplicates },
                         clamped: outcomes.reduce(0) { $0 + $1.clamped }),
            labels: Set(foreign.images.flatMap { $0.boxes.map(\.label) }).sorted(),
            renamed: plan.filter { $0.finalName != $0.source.lastPathComponent }
                .map { .init(from: $0.source.lastPathComponent, to: $0.finalName) },
            missing: foreign.missingImages,
            problems: result.problems)
    }
}
