import ArgumentParser
import Foundation
import LabelKit

/// `labelkit import` — bring a YOLO, COCO or Hugging Face dataset into a
/// Create ML dataset: images copied in, boxes merged into annotations.json.
struct ImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Bring a YOLO, COCO or Hugging Face dataset into a Create ML dataset.",
        discussion: """
        Examples:
          labelkit import ./yolo-export --into ./cards
          labelkit import ./coco/_annotations.coco.json --into ./cards
          labelkit import ./hf-download --into ./cards --format huggingface --negatives
          labelkit import ./yolo-export --into ./cards --dry-run
          labelkit import ./coco8 --into ./coco8-ml --names coco8.yaml

        The source is a folder (or a COCO .json file). Its format is worked out
        from what is there: metadata.jsonl means Hugging Face, a JSON with
        images/annotations/categories means COCO, .txt label files next to
        images mean YOLO. --format overrides. Splits (train/valid/test) are
        imported together, since a Create ML dataset is one folder and Create ML
        makes its own validation split.

        A YOLO download often comes without its class names; boxes then import
        as class_0, class_1, … Pass the names with --names data.yaml (or a text
        file, one name per line, in id order).

        Images are copied into <dataset> (created if needed); an existing file
        is never overwritten — a different image with the same name is given a
        new one, reported under "renamed". Boxes are added the way 'annotate'
        adds them, so importing the same source twice changes nothing.

        Source images that have no boxes are left out (not copied) unless
        --negatives is given, which brings them in as negative examples. If anything in the source can't be applied, nothing is copied or
        written and the command exits 1; --lenient applies the rest.

        stdout carries a JSON report. Exit 0 on success, 1 when there were
        problems, 64 for a usage error.
        """)

    @Argument(help: "The dataset to import: a folder, or a COCO .json file.")
    var source: String

    @Option(name: .long, help: "The Create ML dataset folder to import into (created if it doesn't exist).")
    var into: String

    @Option(name: .long, help: "Source format: yolo, coco or huggingface. Default: detected.")
    var format: DatasetFormat?

    @Option(name: .long, help: "File naming the classes, for a source that only has numeric ids: a YOLO data.yaml, or a text file with one name per line.")
    var names: String?

    @Flag(name: .long, help: "Record source images that have no boxes as negative examples.")
    var negatives = false

    @Flag(name: .long, help: "Report what would happen without copying or writing anything.")
    var dryRun = false

    @Flag(name: .long, help: "Apply what is valid instead of refusing the whole import.")
    var lenient = false

    func run() throws {
        let sourceURL = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
        var classNames: [String]?
        if let names {
            let url = URL(fileURLWithPath: (names as NSString).expandingTildeInPath)
            guard let read = try? ClassNames.read(url), !read.isEmpty else {
                throw ValidationError("Couldn't read class names from \(names).")
            }
            classNames = read
        }
        let foreign: ForeignDataset
        do {
            foreign = try ForeignDatasetReader.read(at: sourceURL, format: format, classNames: classNames)
        } catch let error as ForeignDatasetError where error.isUsage {
            throw ValidationError(error.message)
        } catch {
            // A dataset that is there but broken is a problem with the data, not the call.
            Headless.note("couldn't read \(source): \(Headless.describe(error))")
            throw ExitCode(1)
        }

        let datasetURL = URL(fileURLWithPath: (into as NSString).expandingTildeInPath)
        // A target inside the source would be read back as part of the source
        // on the next run.
        let sourceFolder = sourceURL.hasDirectoryPath || (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            ? sourceURL : sourceURL.deletingLastPathComponent()
        let sourcePath = sourceFolder.resolvingSymlinksInPath().standardizedFileURL.path
        let targetPath = datasetURL.resolvingSymlinksInPath().standardizedFileURL.path
        if targetPath == sourcePath || targetPath.hasPrefix(sourcePath + "/") {
            throw ValidationError("--into is inside the dataset being imported; choose a folder outside \(source).")
        }

        // The folder is only created once the import is known to go through.
        var document: DatasetDocument
        if FileManager.default.fileExists(atPath: datasetURL.path) {
            document = try Headless.openDocument(path: datasetURL.path, annotations: nil)
        } else {
            document = DatasetDocument(
                location: DatasetLocation(
                    imagesDirectory: datasetURL,
                    annotationsURL: datasetURL.appendingPathComponent("annotations.json"),
                    annotationsExists: false),
                records: [], imagesOnDisk: [])
        }

        let report: DatasetImport.Report
        do {
            report = try DatasetImport.run(
                foreign, into: &document,
                options: .init(recordNegatives: negatives, lenient: lenient, dryRun: dryRun))
        } catch {
            Headless.note("import failed: \(Headless.describe(error))")
            throw ExitCode(1)
        }
        Headless.printJSON(report)
        if !report.problems.isEmpty {
            if !lenient { Headless.note("nothing imported: \(report.problems.count) problem(s) (--lenient applies the rest)") }
            throw ExitCode(1)
        }
    }
}

extension DatasetFormat: ExpressibleByArgument {}
