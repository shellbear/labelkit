import ArgumentParser
import CoreGraphics
import Foundation
import LabelKit

/// `labelkit detect` — run an object detector over one image or a directory and
/// emit boxes as JSON/NDJSON/text, optionally rendering an annotated PNG.
///
/// Headless by contract: this path never touches AppKit (same rule as
/// `--version`). All the work is the shared `LabelKit` detection engine; this
/// command is a thin adapter that formats and writes the result.
struct DetectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "detect",
        abstract: "Run an object detector over an image (or directory) and emit boxes.",
        discussion: """
        Pick exactly one detector:
          --model PATH        a custom Core ML model (.mlmodel/.mlpackage/.mlmodelc)
          --detector NAME     a built-in Vision detector: \
        \(VisionBuiltinDetector.Kind.allCases.map(\.rawValue).joined(separator: ", "))

        Examples:
          labelkit detect photo.jpg --model cards.mlpackage
          labelkit detect ./images --detector rectangles --format ndjson
          labelkit detect photo.jpg --model cards.mlpackage --render out.png

        stdout carries the machine-readable result; progress and warnings go to
        stderr. Boxes are reported in image pixels and normalized [0,1], both
        top-left origin.
        """)

    @Argument(help: "Image file, or a directory of images.")
    var input: String

    @Option(name: .long, help: "Custom Core ML model path (.mlmodel/.mlpackage/.mlmodelc).")
    var model: String?

    @Option(name: .long, help: "Built-in Vision detector name.")
    var detector: String?

    @Option(name: [.customShort("l"), .long],
            help: "Label for localize-only detectors (rectangles, faces, …). Defaults to the detector's own.")
    var label: String?

    @Option(name: .long, help: "Drop detections scoring below this (0–1).")
    var minConfidence: Double = 0.5

    @Option(name: .long, help: "Output format: json, ndjson, or text.")
    var format: OutputFormat = .json

    @Option(name: .long, help: "Filename glob for directory input, e.g. '*.jpg'.")
    var glob: String?

    @Option(name: .long, help: "Write annotated PNG(s) here: a file for one image, a directory for many.")
    var render: String?

    @Option(name: .long, help: "Longest edge to decode to before detection.")
    var maxPixel: Double = 1536

    enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
        case json, ndjson, text
    }

    func run() throws {
        let spec = try resolveDetector()
        let images = try gatherImages()
        let fallback = effectiveLabel(for: spec.detector)

        var reports: [DetectionReport] = []
        for imageURL in images {
            let result: SingleImageDetection.Result
            do {
                result = try SingleImageDetection.run(
                    imageURL: imageURL, detector: spec.detector,
                    maxDecodePixel: CGFloat(maxPixel), fallbackLabel: fallback)
            } catch {
                warn("\(imageURL.lastPathComponent): \(describe(error))")
                continue  // skip a bad image, keep processing the batch
            }

            let detections = DetectionMerge.detections(
                result.candidates, minConfidence: Float(minConfidence))
            let report = DetectionReport.make(
                detector: spec.name, source: spec.source,
                filename: imageURL.lastPathComponent, path: imageURL.path,
                pixelSize: result.pixelSize, detections: detections)
            reports.append(report)

            if format == .ndjson { print(encode(report, pretty: false)) }  // stream as we go
            if render != nil {
                try renderAnnotated(imageURL: imageURL, pixelSize: result.pixelSize,
                                    detections: detections, batch: images.count > 1)
            }
        }

        switch format {
        case .ndjson:
            break  // already streamed per image
        case .json:
            // A single image emits the object; a batch emits an array.
            if images.count == 1, let only = reports.first {
                print(encode(only, pretty: true))
            } else {
                print(encode(reports, pretty: true))
            }
        case .text:
            print(renderText(reports))
        }
    }

    // MARK: - Detector

    private struct DetectorSpec {
        let detector: BoxDetector
        let name: String
        let source: String
    }

    private func resolveDetector() throws -> DetectorSpec {
        switch (model, detector) {
        case (nil, nil):
            throw ValidationError("Specify a detector: --model <path> or --detector <name>.")
        case (.some, .some):
            throw ValidationError("Use either --model or --detector, not both.")
        case let (path?, nil):
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError("Model not found: \(path)")
            }
            do {
                let coreML = try CoreMLBoxDetector(modelURL: url)
                return DetectorSpec(detector: coreML, name: coreML.name, source: "coreml")
            } catch {
                throw ValidationError("Couldn't load model \(path): \(describe(error))")
            }
        case let (nil, name?):
            guard let kind = VisionBuiltinDetector.Kind(rawValue: name.lowercased()) else {
                let all = VisionBuiltinDetector.Kind.allCases.map(\.rawValue).joined(separator: ", ")
                throw ValidationError("Unknown detector '\(name)'. Choose one of: \(all).")
            }
            let builtin = VisionBuiltinDetector(kind)
            return DetectorSpec(detector: builtin, name: builtin.name, source: "vision")
        }
    }

    private func effectiveLabel(for detector: BoxDetector) -> String {
        let trimmed = label?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? detector.defaultLabel : trimmed
    }

    // MARK: - Inputs

    private func gatherImages() throws -> [URL] {
        let url = URL(fileURLWithPath: input)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ValidationError("No such file or directory: \(input)")
        }
        guard isDirectory.boolValue else { return [url] }

        let names = ImageDirectoryScanner.scan(directory: url, glob: glob)
        guard !names.isEmpty else {
            throw ValidationError("No images\(glob.map { " matching '\($0)'" } ?? "") in \(input).")
        }
        return names.map { url.appendingPathComponent($0) }
    }

    // MARK: - Render

    private func renderAnnotated(imageURL: URL, pixelSize: CGSize,
                                 detections: [DetectionCandidate], batch: Bool) throws {
        guard let render else { return }
        guard let image = ImageDownsampler.decode(url: imageURL, maxPixel: CGFloat(maxPixel)) else {
            warn("\(imageURL.lastPathComponent): couldn't decode for --render")
            return
        }
        let boxes = detections.map {
            RenderableBox(rect: $0.box.rect, label: $0.box.label, confidence: $0.confidence)
        }
        guard let png = BoxRenderer.renderPNG(image: image, sourceSize: pixelSize, boxes: boxes) else {
            warn("\(imageURL.lastPathComponent): couldn't render overlay")
            return
        }
        let outputURL = try renderDestination(for: imageURL, batch: batch, dest: render)
        try png.write(to: outputURL)
        warn("wrote \(outputURL.path)")
    }

    /// A file when rendering one image to a `.png` path; otherwise a directory
    /// holding `<name>.png` per image (auto-created).
    private func renderDestination(for imageURL: URL, batch: Bool, dest: String) throws -> URL {
        let destURL = URL(fileURLWithPath: dest)
        let asDirectory = batch
            || isExistingDirectory(destURL)
            || destURL.pathExtension.lowercased() != "png"
        if asDirectory {
            try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
            return destURL.appendingPathComponent(imageURL.deletingPathExtension().lastPathComponent + ".png")
        }
        try FileManager.default.createDirectory(
            at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        return destURL
    }

    private func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // MARK: - Encoding

    private func encode<T: Encodable>(_ value: T, pretty: Bool) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func renderText(_ reports: [DetectionReport]) -> String {
        var lines: [String] = []
        for report in reports {
            let count = report.detections.count
            lines.append("\(report.image)  \(Int(report.width))x\(Int(report.height))  "
                + "\(count) detection\(count == 1 ? "" : "s")")
            for item in report.detections {
                let score = String(format: "%5.1f%%", item.confidence * 100)
                let coords = String(format: "x=%.1f y=%.1f w=%.1f h=%.1f",
                                    item.box.x, item.box.y, item.box.width, item.box.height)
                lines.append("  \(item.label.padded(to: 16)) \(score)  \(coords)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Diagnostics

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("labelkit: \(message)\n".utf8))
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

private extension String {
    /// Left-justify to `width` for aligned text output (never truncates).
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
