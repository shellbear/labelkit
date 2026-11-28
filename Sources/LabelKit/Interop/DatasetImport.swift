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
        /// Bring in source images that have no boxes, as negative examples.
        /// Without it they are left out altogether: in someone else's dataset
        /// "no boxes" can mean a deliberate negative or simply unlabelled.
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
            /// Copied into the dataset by this run (with `dryRun`, that would be).
            public var copied: Int
            /// Already in the dataset; not copied again.
            public var alreadyPresent: Int
            /// Left out because they have no boxes and negatives weren't asked for.
            public var withoutBoxes: Int

            public init(found: Int, copied: Int, alreadyPresent: Int, withoutBoxes: Int = 0) {
                self.found = found
                self.copied = copied
                self.alreadyPresent = alreadyPresent
                self.withoutBoxes = withoutBoxes
            }
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
        let fm = FileManager.default
        let directory = document.location.imagesDirectory
        let included = foreign.images.filter { options.recordNegatives || !$0.boxes.isEmpty }
        // A symlinked image (common in download caches) is imported as the
        // file it points to; copying the link would leave it dangling.
        let sources = included.map { $0.source.resolvingSymlinksInPath() }
        let names = included.map(\.source.lastPathComponent)
        let plan = reusingEarlierCopies(
            ImageImporter.plan(sources: sources, into: directory,
                               reservedNames: Set(document.records.map(\.image)), names: names),
            named: names, in: directory)

        // Sizes come from the source files, so nothing has to be copied before
        // it is known that the whole import can go through.
        let measured = sources.concurrentMap(ImageMetadata.pixelSize(of:))
        var sizes: [String: CGSize] = [:]
        for (item, size) in zip(plan, measured) {
            if let size { sizes[item.finalName] = size }
        }

        var merged = document
        merged.imagesOnDisk = (document.imagesOnDisk + plan.map(\.finalName)).uniqued()
        let imports = zip(plan, included).map { ImportedImage(image: $0.finalName, boxes: $1.boxes) }
        let result = AnnotationMerge.apply(
            imports, to: &merged,
            options: .init(mode: .add, recordNegatives: options.recordNegatives, dedupeWithinInput: false),
            pixelSize: { sizes[$0] })

        let blocked = !result.problems.isEmpty && !options.lenient
        let toCopy = plan.filter(\.needsCopy)
        let apply = !options.dryRun && !blocked
        if apply {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var copied: [URL] = []
            do {
                for item in toCopy {
                    let destination = directory.appendingPathComponent(item.finalName)
                    try fm.copyItem(at: item.source, to: destination)
                    copied.append(destination)
                }
                if result.changed { try merged.save() }
            } catch {
                // All or nothing: take back what this run put there.
                copied.forEach { try? fm.removeItem(at: $0) }
                throw error
            }
            document = merged
        }

        let outcomes = result.outcomes
        return Report(
            schemaVersion: 1, labelkit: version,
            dataset: directory.path, annotations: document.location.annotationsURL.path,
            format: foreign.format.rawValue, dryRun: options.dryRun,
            written: apply && (result.changed || !toCopy.isEmpty),
            images: .init(found: foreign.images.count, copied: blocked ? 0 : toCopy.count,
                          alreadyPresent: plan.count - toCopy.count,
                          withoutBoxes: foreign.images.count - included.count),
            boxes: .init(added: outcomes.reduce(0) { $0 + $1.added },
                         duplicates: outcomes.reduce(0) { $0 + $1.duplicates },
                         clamped: outcomes.reduce(0) { $0 + $1.clamped }),
            labels: Set(foreign.images.flatMap { $0.boxes.map(\.label) }).sorted(),
            renamed: zip(plan, names).filter { $0.finalName != $1 }.map { .init(from: $1, to: $0.finalName) },
            missing: foreign.missingImages,
            problems: result.problems)
    }

    /// An image that had to be renamed on an earlier import (`a.jpg` → `a-2.jpg`)
    /// would be planned as a third copy the next time. Recognise the copy that
    /// is already there, by content, so repeating an import stays a no-op.
    private static func reusingEarlierCopies(
        _ plan: [ImageImporter.Item], named names: [String], in directory: URL
    ) -> [ImageImporter.Item] {
        let fm = FileManager.default
        let existing = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        var taken = Set(plan.filter { !$0.needsCopy }.map(\.finalName))
        return zip(plan, names).map { item, name in
            guard item.needsCopy, item.finalName != name else { return item }
            let stem = (name as NSString).deletingPathExtension + "-"
            let ext = (name as NSString).pathExtension
            let earlier = existing.first { candidate in
                candidate.hasPrefix(stem) && (candidate as NSString).pathExtension == ext
                    && !taken.contains(candidate)
                    && Int((candidate as NSString).deletingPathExtension.dropFirst(stem.count)) != nil
                    && fm.contentsEqual(atPath: item.source.path, andPath: directory.appendingPathComponent(candidate).path)
            }
            guard let earlier else { return item }
            taken.insert(earlier)
            return ImageImporter.Item(source: item.source, finalName: earlier, needsCopy: false)
        }
    }
}
