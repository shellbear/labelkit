import ArgumentParser
import CoreGraphics
import Foundation
import LabelKit

/// `labelkit render` — draw a dataset's existing boxes onto its images and
/// write the pictures out. This is the "look at it" step for an agent with
/// vision: annotate, render, open the picture, correct what's wrong.
struct RenderCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "render",
        abstract: "Write images with their boxes drawn on, to check labels by eye.",
        discussion: """
        Examples:
          labelkit render ./cards --out /tmp/check
          labelkit render ./cards a.jpg b.jpg --out /tmp/check
          labelkit render ./cards --out /tmp/check --limit 20 --image-format png
          labelkit render ./cards --unlabeled --grid 100 --out /tmp/todo

        With no image names, every image that has an entry in the annotations
        file is rendered (cap it with --limit). Output files are named after the
        image: a.heic → <out>/a.jpg; the JSON on stdout gives each one's path.
        Each label keeps the same colour from run to run.

        Renders are downscaled to --max-pixel on the longest edge and written as
        JPEG by default: small and quick to produce, and plenty to judge a box
        by. Boxes are numbered in file order (#1, #2, …), matching 'validate'.

        --grid N draws a labelled line every N pixels of the ORIGINAL image, so
        coordinates read off a render are already the pixel coordinates
        'annotate' expects, whatever size the render is. The JSON also reports
        each image's real width and height.

        stdout carries a JSON list of what was written. Exit 0 on success, 1 if
        any image couldn't be rendered, 64 for a usage error.
        """)

    @Argument(help: "Dataset directory, or path to an annotations .json file.")
    var path: String

    @Argument(help: "Image filenames to render. Default: every image with an entry.")
    var images: [String] = []

    @Option(name: [.customShort("o"), .long], help: "Directory to write the rendered images into (created if needed).")
    var out: String

    @Option(name: .long, help: "Explicit annotations.json path (overrides auto-detection).")
    var annotations: String?

    @Option(name: .long, help: "Render at most this many images.")
    var limit: Int?

    @Flag(name: .long, help: "Render the images that have no entry yet instead (to label them from the picture).")
    var unlabeled = false

    @Option(name: .long, help: "Overlay a coordinate grid: a labelled line every N image pixels.")
    var grid: Double?

    @Option(name: .long, help: "Longest edge of each render, in pixels.")
    var maxPixel: Double = 1280

    @Option(name: .long, help: "Encoding of the rendered files: jpg or png.")
    var imageFormat: ImageFormat = .jpg

    enum ImageFormat: String, ExpressibleByArgument, CaseIterable {
        case jpg, png
    }

    struct Report: Encodable {
        var schemaVersion = 1
        var labelkit = labelkitVersion
        var out: String
        var rendered: [Rendered]
        var failed: [Failure]

        struct Rendered: Encodable {
            var image: String
            var output: String
            var boxes: Int
            /// Size of the source image, in the pixels boxes are measured in.
            var width: Int
            var height: Int
        }

        struct Failure: Encodable {
            var image: String
            var message: String
        }
    }

    func run() throws {
        let document = try Headless.openDocument(path: path, annotations: annotations)
        let onDisk = Set(document.imagesOnDisk)
        let boxesByImage = Dictionary(
            uniqueKeysWithValues: document.uniqueRecords.map { ($0.image, $0.boxes) })

        var targets: [String]
        if unlabeled {
            guard images.isEmpty else {
                throw ValidationError("Use either image names or --unlabeled, not both.")
            }
            targets = document.imagesOnDisk.filter { boxesByImage[$0] == nil }
        } else if images.isEmpty {
            targets = document.uniqueRecords.map(\.image).filter(onDisk.contains)
        } else {
            if let unknown = images.first(where: { !onDisk.contains($0) }) {
                throw ValidationError("No such image in the dataset: \(unknown)")
            }
            targets = images
        }
        targets = targets.uniqued()
        if let limit { targets = Array(targets.prefix(max(0, limit))) }

        let outURL = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        do {
            try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        } catch {
            throw ValidationError("Couldn't create \(out): \(Headless.describe(error))")
        }

        let encoding: BoxRenderer.Encoding = imageFormat == .png ? .png : .jpeg(quality: 0.82)
        let edge = CGFloat(maxPixel)
        if let grid, grid <= 0 { throw ValidationError("--grid must be a positive number of pixels.") }
        let overlay = grid.map { RenderGrid(spacing: CGFloat($0)) }

        // Decode + draw + encode is the whole cost and each image is
        // independent, so fan out across cores.
        let outputs = BoxRenderer.outputNames(for: targets, fileExtension: encoding.fileExtension)
        let results = Array(zip(targets, outputs)).concurrentMap(maxConcurrency: Self.maxDecodes) { name, file in
            Self.renderOne(name: name, document: document, boxes: boxesByImage[name] ?? [],
                           maxPixel: edge, grid: overlay, encoding: encoding,
                           output: outURL.appendingPathComponent(file))
        }

        var report = Report(out: outURL.path, rendered: [], failed: [])
        for (name, result) in zip(targets, results) {
            switch result {
            case .success(let rendered): report.rendered.append(rendered)
            case .failure(let error): report.failed.append(.init(image: name, message: error.message))
            }
        }
        Headless.printJSON(report)
        if !report.failed.isEmpty { throw ExitCode(1) }
    }

    /// Images decoded at once. Each one in flight holds its bitmaps, so this —
    /// not the core count — bounds the peak memory of a render of very large
    /// photos. Measured on 12-megapixel images, six is within a quarter of
    /// the all-cores speed.
    private static let maxDecodes = 6

    private struct RenderError: Error { var message: String }

    private static func renderOne(
        name: String, document: DatasetDocument, boxes: [BoxRecord],
        maxPixel: CGFloat, grid: RenderGrid?, encoding: BoxRenderer.Encoding, output: URL
    ) -> Result<Report.Rendered, RenderError> {
        let url = document.imageURL(for: name)
        guard let size = ImageMetadata.pixelSize(of: url),
              let image = ImageDownsampler.decode(url: url, maxPixel: maxPixel) else {
            return .failure(RenderError(message: "couldn't decode the image"))
        }
        // Number the boxes the way `validate` does (#1, #2, … in file order) so
        // a problem report and a picture can be matched up.
        let renderable = boxes.enumerated().map { index, box in
            RenderableBox(rect: box.rect, label: box.label, caption: "#\(index + 1) \(box.label)")
        }
        guard let data = BoxRenderer.render(image: image, sourceSize: size, boxes: renderable,
                                            grid: grid, as: encoding) else {
            return .failure(RenderError(message: "couldn't draw the overlay"))
        }
        do {
            try data.write(to: output, options: .atomic)
        } catch {
            return .failure(RenderError(message: "couldn't write \(output.path)"))
        }
        return .success(.init(image: name, output: output.path, boxes: boxes.count,
                              width: Int(size.width), height: Int(size.height)))
    }
}
