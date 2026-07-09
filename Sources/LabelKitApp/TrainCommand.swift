import ArgumentParser
import Foundation
import LabelKit

/// `labelkit train` — train a Create ML object detector from an annotated
/// dataset and write a `.mlmodel`.
///
/// Headless by contract: this path never touches AppKit (same rule as `detect`).
/// The training engine lives in the shared `LabelKit` library; this command is a
/// thin adapter that resolves the dataset, streams progress to stderr, and emits
/// the machine-readable report on stdout.
struct TrainCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "train",
        abstract: "Train a Create ML object detector from an annotated dataset.",
        discussion: """
        The dataset is used as-is — the images plus their annotations.json are
        already in Create ML's format, so no conversion happens.

        Algorithms (--algorithm):
          transferLearning   small, fast, great on modest datasets (default)
          fullNetwork        trains a full network; larger, slower, wants more data

        Examples:
          labelkit train ./cards
          labelkit train ./cards -o cards.mlmodel --max-iterations 300
          labelkit train ./cards --algorithm fullNetwork --validation-split 0.15

        stdout carries the machine-readable JSON report; progress goes to stderr.
        With no -o, the model is written next to the dataset folder as
        <dataset>.mlmodel.
        """)

    @Argument(help: "Dataset directory, or path to an annotations .json file.")
    var path: String?

    @Option(name: .long, help: "Explicit annotations.json path (overrides auto-detection).")
    var annotations: String?

    @Option(name: [.customShort("o"), .long],
            help: "Where to write the .mlmodel. Defaults to <dataset>.mlmodel beside the dataset.")
    var output: String?

    @Option(name: .long, help: "Training algorithm: transferLearning or fullNetwork.")
    var algorithm: TrainingAlgorithm = .transferLearning

    @Option(name: .long, help: "Training iterations. Omit to let Create ML choose from the dataset size.")
    var maxIterations: Int?

    @Option(name: .long, help: "Fraction of the dataset held out for validation metrics (0 disables).")
    var validationSplit: Double = 0.2

    @Flag(name: [.customShort("q"), .long], help: "Suppress per-iteration progress on stderr.")
    var quiet = false

    func run() throws {
        guard let path,
              let location = try DatasetLocator.resolve(path: path, annotationsOverride: annotations) else {
            throw ValidationError("Specify a dataset directory or annotations.json path.")
        }
        guard location.annotationsExists else {
            throw ValidationError("No annotations found at \(location.annotationsURL.path). Annotate the dataset first.")
        }

        let records = try loadRecords(location)
        guard !records.isEmpty else {
            throw ValidationError("The dataset has no entries to train on.")
        }
        let labels = distinctLabels(records)
        guard !labels.isEmpty else {
            throw ValidationError("The dataset has no labeled boxes — nothing to train.")
        }

        let outputURL = resolveOutput(location)
        let options = TrainingOptions(
            algorithm: algorithm,
            maxIterations: maxIterations,
            validationSplitFraction: validationSplit > 0 ? validationSplit : nil)

        warn("training \(records.count) image\(records.count == 1 ? "" : "s"), "
            + "\(labels.count) label\(labels.count == 1 ? "" : "s") → \(outputURL.path)")

        let result = try runTraining(location: location, outputURL: outputURL, options: options)
        let report = TrainingReport.make(
            algorithm: algorithm, maxIterations: maxIterations,
            result: result, images: records.count, labels: labels)
        print(encode(report))
    }

    // MARK: - Training

    /// Drive the async training stream to completion from a synchronous command.
    /// The command thread blocks on a semaphore while the run streams progress —
    /// fine for a headless CLI, and it leaves the sync root/launch path untouched.
    private func runTraining(location: DatasetLocation, outputURL: URL,
                             options: TrainingOptions) throws -> TrainingResult {
        let stream = CreateMLObjectDetectorTrainer().train(
            location: location, outputURL: outputURL, options: options)
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let beQuiet = quiet

        Task {
            var lastPercent = -1
            do {
                for try await event in stream {
                    switch event {
                    case let .progress(fraction, phase):
                        let percent = Int((fraction * 100).rounded())
                        if !beQuiet, percent != lastPercent {
                            lastPercent = percent
                            let suffix = phase.isEmpty ? "" : " (\(phase))"
                            FileHandle.standardError.write(
                                Data("labelkit: training \(percent)%\(suffix)\n".utf8))
                        }
                    case let .finished(result):
                        box.value = .success(result)
                    }
                }
                if box.value == nil { box.value = .failure(TrainCommandError.noModel) }
            } catch {
                box.value = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()

        switch box.value {
        case let .success(result)?: return result
        case let .failure(error)?: throw TrainCommandError.failed(describe(error))
        case nil: throw TrainCommandError.noModel
        }
    }

    private final class ResultBox: @unchecked Sendable {
        var value: Result<TrainingResult, Error>?
    }

    // MARK: - Dataset

    private func loadRecords(_ location: DatasetLocation) throws -> [ImageAnnotationRecord] {
        let data = try Data(contentsOf: location.annotationsURL)
        return try CreateMLFormat.load(data)
    }

    private func distinctLabels(_ records: [ImageAnnotationRecord]) -> [String] {
        var seen = Set<String>()
        var labels: [String] = []
        for record in records {
            for box in record.boxes where seen.insert(box.label).inserted {
                labels.append(box.label)
            }
        }
        return labels
    }

    private func resolveOutput(_ location: DatasetLocation) -> URL {
        if let output {
            return URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        }
        return location.imagesDirectory.deletingLastPathComponent()
            .appendingPathComponent("\(location.displayName).mlmodel")
    }

    // MARK: - Output

    private func encode(_ report: TrainingReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("labelkit: \(message)\n".utf8))
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

private enum TrainCommandError: LocalizedError {
    case failed(String)
    case noModel

    var errorDescription: String? {
        switch self {
        case .failed(let message): return "training failed: \(message)"
        case .noModel: return "training finished without producing a model"
        }
    }
}

// Teach ArgumentParser the algorithm names: because `TrainingAlgorithm` is a
// `String`-backed `CaseIterable`, this one line yields parsing, `--help` value
// listing, and completion from the same library enum the GUI's picker uses.
// (No `@retroactive`: it's in the same package, so the conformance isn't retroactive.)
extension TrainingAlgorithm: ExpressibleByArgument {}
