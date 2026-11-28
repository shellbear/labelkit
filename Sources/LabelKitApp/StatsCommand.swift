import ArgumentParser
import Foundation
import LabelKit

/// `labelkit stats` — summarize a dataset without opening it: how many images
/// are labelled, which still need labels, how the labels are distributed.
/// Reads only the annotations file and the directory listing (no image is
/// opened), so it is instant even on very large datasets.
struct StatsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Summarize a dataset: labelled and unlabelled images, boxes per label.",
        discussion: """
        Examples:
          labelkit stats ./cards
          labelkit stats ./cards --per-image
          labelkit stats ./cards --format text

        "unlabeled" lists images on disk with no entry in the annotations file —
        the work still to do. "negatives" are entries with zero boxes, which are
        deliberate training signal, not missing work.

        stdout carries the result (JSON by default). Exit 0 on success, 64 for a
        usage error.
        """)

    @Argument(help: "Dataset directory, or path to an annotations .json file.")
    var path: String

    @Option(name: .long, help: "Explicit annotations.json path (overrides auto-detection).")
    var annotations: String?

    @Flag(name: .long, help: "Include one row per image (status, box count, labels).")
    var perImage = false

    @Option(name: .long, help: "Output format: json or text.")
    var format: Headless.OutputFormat = .json

    func run() throws {
        let document = try Headless.openDocument(path: path, annotations: annotations)
        let summary = DatasetSummary.make(of: document, includePerImage: perImage)
        switch format {
        case .json: Headless.printJSON(summary)
        case .text: print(text(summary))
        }
    }

    private func text(_ summary: DatasetSummary) -> String {
        let images = summary.images
        var lines = [
            "\(summary.dataset)",
            "  images      \(images.total)  (\(images.onDisk) on disk)",
            "  annotated   \(images.annotated)",
            "  negatives   \(images.negatives)",
            "  unlabeled   \(images.unlabeled)",
            "  missing     \(images.missing)",
            "  boxes       \(summary.boxes)",
        ]
        if let spread = summary.boxesPerImage {
            lines.append("  per image   min \(spread.min), median \(CreateMLWriter.coordString(spread.median)), "
                + "max \(spread.max) (\(spread.maxImage))")
        }
        if !summary.labels.isEmpty {
            lines.append("labels")
            let width = summary.labels.map(\.label.count).max() ?? 0
            for label in summary.labels {
                lines.append("  \(label.label.padded(to: width))  \(String(label.boxes).leftPadded(to: 6)) boxes  "
                    + "\(String(label.images).leftPadded(to: 6)) images")
            }
        }
        for row in summary.perImage ?? [] {
            lines.append("\(row.image)  \(row.status.rawValue)  \(row.boxes)  \(row.labels.joined(separator: ","))")
        }
        return lines.joined(separator: "\n")
    }
}
