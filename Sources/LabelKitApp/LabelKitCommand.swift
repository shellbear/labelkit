import ArgumentParser
import Foundation
import LabelKit

struct LabelKitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "labelkit",
        abstract: "Annotate image datasets in Apple Create ML object-detection format.",
        version: labelkitVersion
    )

    @Argument(help: "Dataset directory, or path to an annotations .json file.")
    var path: String?

    @Option(name: .long, help: "Explicit annotations.json path (overrides auto-detection).")
    var annotations: String?

    @Option(name: .long, help: "Glob filter for image filenames, e.g. '*.jpg'.")
    var images: String?

    func run() throws {
        // Resolve + validate before any UI exists: --help/--version and bad
        // paths never touch AppKit (clean stderr + exit codes for CLI use).
        let location = try DatasetLocator.resolve(path: path, annotationsOverride: annotations)
        LaunchContext.current = LaunchContext(location: location, imageGlob: images)
        LabelKitApp.main() // never returns; the app run loop owns the process
    }
}
