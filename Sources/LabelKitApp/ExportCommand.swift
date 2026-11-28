import ArgumentParser
import Foundation
import LabelKit

/// `labelkit export` — write a Create ML dataset out as YOLO, COCO or a
/// Hugging Face image dataset, into a new folder. The dataset is only read.
struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Write a dataset out as YOLO, COCO or a Hugging Face image dataset.",
        discussion: """
        Examples:
          labelkit export ./cards --format huggingface --out ./cards-hf
          labelkit export ./cards --format yolo --out ./cards-yolo
          labelkit export ./cards --format coco --out ./cards-coco --no-images

        What is written into --out (which must be new or empty):

          yolo         images/, labels/<name>.txt ('class cx cy w h', normalized),
                       classes.txt and data.yaml
          coco         _annotations.coco.json with the images beside it
          huggingface  README.md (a dataset card) and train/metadata.jsonl with
                       the images under train/images/ — ready for
                       'hf upload <name> <out> --repo-type=dataset'

        Every entry whose image file exists is exported, negatives included.
        Images that have no entry yet are unlabelled and are left out. Class ids
        follow the labels in alphabetical order. Images are copied (on APFS a
        copy takes no extra space); --no-images writes only the annotations.

        stdout carries a JSON report. Exit 0 on success, 1 if the export failed,
        64 for a usage error.
        """)

    @Argument(help: "Dataset directory, or path to an annotations .json file.")
    var path: String

    @Option(name: .long, help: "Target format: yolo, coco or huggingface.")
    var format: DatasetFormat

    @Option(name: [.customShort("o"), .long], help: "Folder to write the export into. Must be new or empty.")
    var out: String

    @Option(name: .long, help: "Explicit annotations.json path (overrides auto-detection).")
    var annotations: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Copy the image files into the export.")
    var images = true

    func run() throws {
        let document = try Headless.openDocument(path: path, annotations: annotations)
        let outURL = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)

        // YOLO and COCO need each image's size; one parallel header-only pass.
        let onDisk = Set(document.imagesOnDisk)
        let sizes = format == .huggingface
            ? [:] : document.pixelSizes(of: document.uniqueRecords.map(\.image).filter(onDisk.contains))

        do {
            Headless.printJSON(try DatasetExport.run(
                document, to: outURL, options: .init(format: format, copyImages: images),
                pixelSize: { sizes[$0] }))
        } catch let error as DatasetExport.ExportError {
            throw ValidationError(error.message)
        } catch {
            Headless.note("export failed: \(Headless.describe(error))")
            throw ExitCode(1)
        }
    }
}
