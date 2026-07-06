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

        // macOS 14+ denies terminal-spawned processes self-activation, and
        // SwiftUI won't even create the window of an inactive app. Relaunch
        // through LaunchServices via the sibling .app bundle when running as
        // a bare binary — LS-launched apps activate and focus normally.
        if Bundle.main.bundlePath.hasSuffix(".app") == false,
           let bundle = Self.siblingAppBundle() {
            var arguments = ["-na", bundle, "--args"]
            if let location {
                arguments.append(location.imagesDirectory.path)
                arguments.append(contentsOf: ["--annotations", location.annotationsURL.path])
            }
            if let images { arguments.append(contentsOf: ["--images", images]) }
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = arguments
            try open.run()
            open.waitUntilExit()
            if open.terminationStatus == 0 { return }
            // fall through to inline UI when `open` failed
        }

        LaunchContext.current = LaunchContext(location: location, imageGlob: images)
        MainActor.assumeIsolated { runLabelKitApp() } // never returns
    }

    /// labelkit.app next to the binary (build tree or install prefix), or
    /// LABELKIT_APP override.
    private static func siblingAppBundle() -> String? {
        if let override = ProcessInfo.processInfo.environment["LABELKIT_APP"] {
            return FileManager.default.fileExists(atPath: override) ? override : nil
        }
        let binaryDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [
            binaryDirectory.appendingPathComponent("labelkit.app").path,
            // Homebrew Cellar layout: <prefix>/bin/labelkit + <prefix>/labelkit.app
            binaryDirectory.deletingLastPathComponent()
                .appendingPathComponent("labelkit.app").path,
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }
}
