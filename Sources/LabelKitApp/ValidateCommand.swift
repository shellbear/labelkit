import ArgumentParser
import Foundation
import LabelKit

/// `labelkit validate` — check a dataset for the things that make it wrong to
/// train on, and say so with an exit code. Read-only: it never changes the
/// dataset. Image files are probed for their size only (header read, no pixel
/// decode), in parallel.
struct ValidateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Check a dataset for problems; exits 1 if it finds errors.",
        discussion: """
        Examples:
          labelkit validate ./cards
          labelkit validate ./cards --labels card,coin
          labelkit validate ./cards --strict --format text

        Errors (exit 1): no-annotations-file, missing-image, duplicate-entry,
        empty-label, empty-box, box-outside-image, unknown-label.
        Warnings (exit 0 unless --strict): unreadable-image, box-overflows-image,
        duplicate-box, duplicate-image, unused-label.

        stdout carries the report (JSON by default) whether or not problems were
        found. Exit 0 when clean, 1 when there are errors, 64 for a usage error.
        """)

    @Argument(help: "Dataset directory, or path to an annotations .json file.")
    var path: String

    @Option(name: .long, help: "Explicit annotations.json path (overrides auto-detection).")
    var annotations: String?

    @Option(name: .long, help: "Comma-separated labels the dataset may use. Any other label is an error.")
    var labels: String?

    @Flag(name: .long, help: "Treat warnings as failures too (exit 1).")
    var strict = false

    @Option(name: .long, help: "Output format: json or text.")
    var format: Headless.OutputFormat = .json

    func run() throws {
        let document = try Headless.openDocument(path: path, annotations: annotations)
        let allowed = labels?.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        // Only images that have an entry are read: their size bounds-checks the
        // boxes, and their contents are compared to catch the same photo saved
        // under two names.
        let onDisk = Set(document.imagesOnDisk)
        let toMeasure = document.uniqueRecords.map(\.image).filter(onDisk.contains)
        let sizes = document.pixelSizes(of: toMeasure)

        let duplicates = DuplicateImages.groups(in: document.location.imagesDirectory, filenames: toMeasure)

        let report = DatasetValidator.validate(
            document, options: .init(allowedLabels: allowed, duplicateImages: duplicates),
            pixelSize: { sizes[$0] })

        switch format {
        case .json: Headless.printJSON(report)
        case .text: print(text(report))
        }
        if !report.ok || (strict && report.warnings > 0) { throw ExitCode(1) }
    }

    private func text(_ report: ValidationReport) -> String {
        var lines = report.issues.map { issue -> String in
            var place = issue.image ?? "dataset"
            if let box = issue.box { place += " #\(box)" }
            return "\(issue.severity.rawValue)  \(issue.code.rawValue)  \(place): \(issue.message)"
        }
        lines.append(report.issues.isEmpty
            ? "ok: no problems found"
            : "\(report.errors) error\(report.errors == 1 ? "" : "s"), "
                + "\(report.warnings) warning\(report.warnings == 1 ? "" : "s")")
        return lines.joined(separator: "\n")
    }
}
