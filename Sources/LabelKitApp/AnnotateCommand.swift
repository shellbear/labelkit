import ArgumentParser
import Foundation
import LabelKit

/// `labelkit annotate` — write boxes into a dataset from the terminal. The
/// headless counterpart of drawing boxes in the editor: input goes through the
/// same writer, so everything the editor guarantees about the file (order,
/// unknown keys, negatives, byte-stable output) holds here too.
struct AnnotateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "annotate",
        abstract: "Add or replace boxes in a dataset from JSON, NDJSON or --box flags.",
        discussion: """
        Give boxes one of two ways:

          --from FILE   JSON, a JSON array, or NDJSON; '-' reads stdin (stdin is
                        never read unless you ask for it this way). Each entry
                        names an image and lists its boxes:
                          {"image": "a.jpg", "boxes": [
                            {"label": "cat", "x": 40, "y": 30, "width": 200, "height": 160}]}
                        The output of 'labelkit detect' and Create ML annotations
                        files are accepted as they are.
                        With --image NAME the input is that one image's boxes,
                        so a model's bare answer works as it is:
                          [{"label": "cat", "xyxy": [40, 30, 240, 190]}]
          --image NAME --box 'label:x,y,width,height' [--box …]
                        boxes for one image, straight on the command line.

        By default four numbers are x, y, width, height with x,y the box's
        TOP-LEFT corner, in pixels of the image file. If your boxes use another
        convention, say so instead of converting them:
          --order xyxy                           two corners: x1,y1,x2,y2
          --anchor center                        x,y is the box centre
          --units normalized                     fractions of the image, 0-1
          --units 0-1000                         0-1000 across the image
          --image-size 1568x1176                 pixels of a resized copy that size
          --units normalized --anchor center     YOLO
          --units normalized --origin bottom-left   Apple Vision

        Shapes that say what they are need no flags: "coordinates" (Create ML),
        "box_2d" (Gemini: y first, 0-1000), "xyxy", x1/y1/x2/y2 keys, and COCO
        files. An entry's own "width"/"height" work like --image-size.

        Examples:
          labelkit annotate ./cards --from boxes.json
          labelkit detect ./cards --detector rectangles --format ndjson \\
            | labelkit annotate ./cards --from -
          labelkit annotate ./cards --image a.jpg --box 'card:40,30,200,160'
          labelkit annotate ./cards --image a.jpg -l card --box 40,30,200,160
          labelkit annotate ./cards --image a.jpg --from model-answer.json
          labelkit annotate ./cards --from coco.json
          labelkit annotate ./cards --from boxes.json --mode replace --dry-run

        The default mode, add, keeps existing boxes and skips any new box that
        is already there (same label, overlapping), so running the same input
        twice changes nothing. replace gives the listed images exactly the boxes
        supplied and leaves every other image alone.

        An image given with NO boxes is left untouched in both modes, so a
        detector that found nothing can't create negatives or wipe labels by
        accident. --negatives makes it count: the image is recorded as a
        negative example, and with --mode replace its existing boxes are cleared.

        If any input can't be applied (unknown image, a box outside its image),
        nothing is written and the command exits 1; --lenient applies the rest.
        Boxes that hang over an image edge are trimmed to fit and counted as
        "clamped".

        stdout carries a JSON report of what changed. Exit 0 on success, 1 when
        there were problems, 64 for a usage error.
        """)

    @Argument(help: "Dataset directory, or path to an annotations .json file.")
    var path: String

    @Option(name: .long, help: "Explicit annotations.json path (overrides auto-detection).")
    var annotations: String?

    @Option(name: .long, help: "Read boxes from this JSON/NDJSON file; '-' for stdin.")
    var from: String?

    @Option(name: .long, help: "The one image all the given boxes belong to (a filename in the dataset).")
    var image: String?

    @Option(name: .long, help: "A box as 'label:x,y,width,height' (top-left corner, pixels). Repeatable.")
    var box: [String] = []

    @Option(name: .long, help: "What the numbers are measured in: pixel, normalized (0-1), 0-1000, or percent.")
    var units: BoxConvention.Units = .pixel

    @Option(name: .long, help: "What four bare numbers mean: xywh, xyxy (two corners), or yxyx (two corners, y first).")
    var order: BoxConvention.Order = .xywh

    @Option(name: .long, help: "Size of the picture the pixel coordinates refer to, as WxH, when it isn't the file's own size.")
    var imageSize: String?

    @Option(name: .long, help: "Where y=0 is: top-left, or bottom-left (Apple Vision; normalized units only).")
    var origin: BoxConvention.Origin = .topLeft

    @Option(name: .long, help: "What x,y points at: the box corner nearest the origin, or its center (Create ML, YOLO).")
    var anchor: BoxConvention.Anchor = .corner

    @Option(name: [.customShort("l"), .long], help: "Label for boxes that don't carry one.")
    var label: String?

    @Option(name: .long, help: "add: keep existing boxes, skip duplicates. replace: listed images get exactly these boxes.")
    var mode: AnnotationMerge.Mode = .add

    @Flag(name: .long, help: "Act on an image given with no boxes: record it as a negative example (with --mode replace, clearing its boxes).")
    var negatives = false

    @Flag(name: .long, help: "Report what would change without writing the file.")
    var dryRun = false

    @Flag(name: .long, help: "Apply the input that is valid instead of refusing the whole run.")
    var lenient = false

    @Option(name: .long, help: "Output format: json or text.")
    var format: Headless.OutputFormat = .json

    func validate() throws {
        if image == nil, !box.isEmpty {
            throw ValidationError("--box needs --image to say which image the boxes belong to.")
        }
        if !box.isEmpty, from != nil {
            throw ValidationError("Use either --from or --box, not both.")
        }
        // An image with no boxes and no --negatives changes nothing. Saying so
        // beats exiting 0 — most often the boxes were piped in without --from -.
        if let image, from == nil, box.isEmpty, !negatives {
            throw ValidationError("No boxes given for \(image). Pass --box, read them with --from <file> "
                + "(--from - for stdin), or add --negatives to record an image that has none.")
        }
        if let imageSize, BoxImportParser.parseSize(imageSize) == nil {
            throw ValidationError("--image-size must look like 1568x1176.")
        }
        if let reason = convention.unsupportedReason {
            throw ValidationError("--origin \(origin.rawValue) with --units \(units.rawValue): \(reason).")
        }
    }

    private var convention: BoxConvention {
        BoxConvention(units: units, origin: origin, anchor: anchor, order: order,
                      referenceSize: imageSize.flatMap(BoxImportParser.parseSize))
    }

    private var parserOptions: BoxImportParser.Options {
        let trimmed = label?.trimmingCharacters(in: .whitespaces) ?? ""
        return .init(convention: convention, defaultLabel: trimmed.isEmpty ? nil : trimmed, image: image)
    }

    func run() throws {
        // Read the boxes first: knowing which images they name lets the dataset
        // open without listing its whole directory.
        let imports = try readImports()
        var document = try Headless.openDocument(
            path: path, annotations: annotations, onlyImages: imports.map(\.image))

        // Sizes are needed to scale normalized boxes and to keep every box
        // inside its image; one parallel header-only pass covers the run.
        let onDisk = Set(document.imagesOnDisk)
        let sizes = document.pixelSizes(of: imports.map(\.image).uniqued().filter(onDisk.contains))

        let result = AnnotationMerge.apply(
            imports, to: &document,
            options: .init(mode: mode, recordNegatives: negatives),
            pixelSize: { sizes[$0] })

        let blocked = !result.problems.isEmpty && !lenient
        let shouldWrite = result.changed && !dryRun && !blocked
        if shouldWrite {
            do { try document.save() } catch {
                Headless.note("couldn't write \(document.location.annotationsURL.path): \(Headless.describe(error))")
                throw ExitCode(1)
            }
        }

        let report = AnnotateReport.make(
            document: document, result: result, mode: mode, dryRun: dryRun, written: shouldWrite)
        switch format {
        case .json: Headless.printJSON(report)
        case .text: print(text(report))
        }
        if blocked {
            Headless.note("nothing written: \(result.problems.count) problem(s) in the input "
                + "(--lenient applies the rest)")
        }
        if !result.problems.isEmpty { throw ExitCode(1) }
    }

    // MARK: - Input

    private func readImports() throws -> [ImportedImage] {
        // Without --from, the boxes are the --box flags and nothing else.
        // stdin is read only when asked for: a command that drained it
        // unprompted would swallow the input of a surrounding `while read` loop.
        guard let from else {
            guard let image else {
                throw ValidationError("Give boxes with --from <file> (--from - for stdin), or --image with --box.")
            }
            do {
                let boxes = try box.map { try BoxImportParser.parseInlineBox($0, options: parserOptions) }
                return [ImportedImage(image: image, boxes: boxes)]
            } catch {
                throw ValidationError(Headless.describe(error))
            }
        }

        let data: Data
        if from == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            let url = URL(fileURLWithPath: (from as NSString).expandingTildeInPath)
            guard let contents = try? Data(contentsOf: url) else {
                throw ValidationError("Couldn't read \(from).")
            }
            data = contents
        }
        do {
            let parsed = try BoxImportParser.parse(data, options: parserOptions)
            // A named image with empty input still means "this image, no boxes".
            if parsed.isEmpty, let image { return [ImportedImage(image: image, boxes: [])] }
            return parsed
        } catch {
            // The call was fine; what it was given was not.
            Headless.note("couldn't read the boxes: \(Headless.describe(error))")
            throw ExitCode(1)
        }
    }

    // MARK: - Output

    private func text(_ report: AnnotateReport) -> String {
        var lines = report.images.map { outcome -> String in
            var parts = ["+\(outcome.added)"]
            if outcome.removed > 0 { parts.append("-\(outcome.removed)") }
            if outcome.duplicates > 0 { parts.append("\(outcome.duplicates) already there") }
            if outcome.clamped > 0 { parts.append("\(outcome.clamped) clamped") }
            return "\(outcome.image)  \(parts.joined(separator: ", "))  (\(outcome.total) total)"
        }
        lines += report.problems.map { "problem  \($0.image): \($0.message)" }
        let verb = report.dryRun ? "would add" : "added"
        var summary = "\(verb) \(report.totals.added) box\(report.totals.added == 1 ? "" : "es") "
            + "across \(report.totals.images) image\(report.totals.images == 1 ? "" : "s")"
        if !report.written, !report.dryRun { summary += " — file not changed" }
        lines.append(summary)
        return lines.joined(separator: "\n")
    }
}

extension AnnotationMerge.Mode: ExpressibleByArgument {}
extension BoxConvention.Units: ExpressibleByArgument {}
extension BoxConvention.Origin: ExpressibleByArgument {}
extension BoxConvention.Anchor: ExpressibleByArgument {}
extension BoxConvention.Order: ExpressibleByArgument {}
