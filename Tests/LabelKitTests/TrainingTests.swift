import Foundation
import XCTest
@testable import LabelKit

/// Exercises the training report shape, the option/algorithm contracts the CLI
/// depends on, and the `ObjectDetectorTrainer` streaming protocol — all via a
/// stub trainer, so Create ML is never invoked (the same reason detection tests
/// use a stub detector: the framework's own behavior isn't labelkit's to test,
/// and it SIGSEGVs on CI runners).
final class TrainingTests: XCTestCase {

    // MARK: - TrainingReport

    func testReportCarriesRunContextAndRoundsMetrics() {
        let result = TrainingResult(
            modelURL: URL(fileURLWithPath: "/out/cards.mlmodel"),
            metrics: TrainingMetrics(validationMeanAveragePrecision: 0.83219,
                                     trainingMeanAveragePrecision: 0.9))
        let report = TrainingReport.make(
            algorithm: .transferLearning, maxIterations: 200, result: result,
            images: 40, labels: ["card", "back"], labelkitVersion: "9.9.9")

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.labelkit, "9.9.9")
        XCTAssertEqual(report.algorithm, "transferLearning")
        XCTAssertEqual(report.maxIterations, 200)
        XCTAssertEqual(report.output, "/out/cards.mlmodel")
        XCTAssertEqual(report.images, 40)
        XCTAssertEqual(report.labels, ["card", "back"])
        XCTAssertEqual(try XCTUnwrap(report.metrics.validationMeanAveragePrecision),
                       0.8322, accuracy: 1e-9)   // rounded to 4 places
        XCTAssertEqual(try XCTUnwrap(report.metrics.trainingMeanAveragePrecision),
                       0.9, accuracy: 1e-9)
    }

    func testReportOmitsMaxIterationsAndMetricsWhenAbsent() {
        let result = TrainingResult(
            modelURL: URL(fileURLWithPath: "/m.mlmodel"), metrics: TrainingMetrics())
        let report = TrainingReport.make(
            algorithm: .fullNetwork, maxIterations: nil, result: result,
            images: 1, labels: ["x"])

        XCTAssertNil(report.maxIterations)
        XCTAssertEqual(report.algorithm, "fullNetwork")
        XCTAssertNil(report.metrics.validationMeanAveragePrecision)
        XCTAssertNil(report.metrics.trainingMeanAveragePrecision)
    }

    func testReportCodableRoundTrips() throws {
        let result = TrainingResult(
            modelURL: URL(fileURLWithPath: "/m.mlmodel"),
            metrics: TrainingMetrics(validationMeanAveragePrecision: 0.5,
                                     trainingMeanAveragePrecision: nil))
        let report = TrainingReport.make(
            algorithm: .transferLearning, maxIterations: 10, result: result,
            images: 3, labels: ["a"])
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(TrainingReport.self, from: data)
        XCTAssertEqual(decoded, report)
    }

    // MARK: - Option / algorithm contracts (shared by the CLI's --algorithm)

    func testAlgorithmRawValuesAreStable() {
        // These strings are the CLI's `--algorithm` values; changing them breaks
        // scripts, so pin them.
        XCTAssertEqual(TrainingAlgorithm.transferLearning.rawValue, "transferLearning")
        XCTAssertEqual(TrainingAlgorithm.fullNetwork.rawValue, "fullNetwork")
        XCTAssertEqual(TrainingAlgorithm.allCases.map(\.rawValue),
                       ["transferLearning", "fullNetwork"])
    }

    func testDefaultOptions() {
        let options = TrainingOptions()
        XCTAssertEqual(options.algorithm, .transferLearning)
        XCTAssertNil(options.maxIterations)
        XCTAssertEqual(try XCTUnwrap(options.validationSplitFraction), 0.2, accuracy: 1e-9)
    }

    // MARK: - Streaming protocol

    func testTrainerReceivesLocationAndStreamsEventsInOrder() async throws {
        let location = DatasetLocation(
            imagesDirectory: URL(fileURLWithPath: "/data/cards"),
            annotationsURL: URL(fileURLWithPath: "/data/cards/annotations.json"),
            annotationsExists: true)
        let output = URL(fileURLWithPath: "/out/cards.mlmodel")
        let result = TrainingResult(
            modelURL: output, metrics: TrainingMetrics(validationMeanAveragePrecision: 0.7))
        let recorder = StubTrainer.Recorder()
        let trainer = StubTrainer(recorder: recorder, script: .events([
            .progress(fraction: 0.25, phase: "a"),
            .progress(fraction: 0.75, phase: "b"),
            .finished(result),
        ]))

        var fractions: [Double] = []
        var finished: TrainingResult?
        for try await event in trainer.train(
            location: location, outputURL: output,
            options: TrainingOptions(algorithm: .fullNetwork, maxIterations: 50)) {
            switch event {
            case let .progress(fraction, _): fractions.append(fraction)
            case let .finished(result): finished = result
            }
        }

        XCTAssertEqual(recorder.location, location)
        XCTAssertEqual(recorder.outputURL, output)
        XCTAssertEqual(recorder.options?.algorithm, .fullNetwork)
        XCTAssertEqual(recorder.options?.maxIterations, 50)
        XCTAssertEqual(fractions, [0.25, 0.75])
        XCTAssertEqual(finished?.modelURL, output)
        XCTAssertEqual(finished?.metrics.validationMeanAveragePrecision, 0.7)
    }

    func testTrainerFailurePropagatesThroughStream() async {
        let trainer = StubTrainer(recorder: .init(), script: .failure)
        do {
            for try await _ in trainer.train(
                location: Self.anyLocation, outputURL: Self.anyOutput, options: TrainingOptions()) {}
            XCTFail("expected the stream to throw")
        } catch {
            // expected
        }
    }

    func testStoppingEarlyTerminatesTheStream() async throws {
        let recorder = StubTrainer.Recorder()
        let trainer = StubTrainer(recorder: recorder, script: .slow)

        var count = 0
        for try await _ in trainer.train(
            location: Self.anyLocation, outputURL: Self.anyOutput, options: TrainingOptions()) {
            count += 1
            if count == 2 { break }   // consumer stops mid-run (the Cancel button)
        }
        XCTAssertEqual(count, 2)

        // Dropping the iterator must terminate the producer — the same plumbing
        // that lets the GUI's Cancel cancel the underlying MLJob.
        try await waitUntil { recorder.terminated }
        XCTAssertLessThan(recorder.yielded, StubTrainer.slowCount,
                          "producer should stop early, not run to completion")
    }

    // MARK: - Helpers

    private static let anyLocation = DatasetLocation(
        imagesDirectory: URL(fileURLWithPath: "/d"),
        annotationsURL: URL(fileURLWithPath: "/d/annotations.json"),
        annotationsExists: true)
    private static let anyOutput = URL(fileURLWithPath: "/out/m.mlmodel")

    /// Poll a condition for up to `timeout`, so a termination that lands slightly
    /// after the loop exits isn't a flake.
    private func waitUntil(timeout: TimeInterval = 2,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met within \(timeout)s"); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// A fake `ObjectDetectorTrainer`: records what it was handed and emits a
/// scripted event sequence, so the streaming contract is tested without Create ML.
private struct StubTrainer: ObjectDetectorTrainer {
    enum Script {
        case events([TrainingEvent])
        case failure
        case slow
    }

    static let slowCount = 1000

    let recorder: Recorder
    let script: Script

    final class Recorder: @unchecked Sendable {
        var location: DatasetLocation?
        var outputURL: URL?
        var options: TrainingOptions?
        var terminated = false
        var yielded = 0
    }

    struct StubError: Error {}

    func train(location: DatasetLocation, outputURL: URL, options: TrainingOptions)
        -> AsyncThrowingStream<TrainingEvent, Error> {
        recorder.location = location
        recorder.outputURL = outputURL
        recorder.options = options
        let recorder = self.recorder

        return AsyncThrowingStream { continuation in
            switch script {
            case let .events(events):
                for event in events { continuation.yield(event) }
                continuation.finish()
            case .failure:
                continuation.finish(throwing: StubError())
            case .slow:
                let task = Task {
                    for index in 0..<Self.slowCount {
                        if Task.isCancelled { break }
                        recorder.yielded += 1
                        continuation.yield(.progress(fraction: Double(index) / Double(Self.slowCount),
                                                     phase: "step \(index)"))
                        try? await Task.sleep(nanoseconds: 2_000_000)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in
                    recorder.terminated = true
                    task.cancel()
                }
            }
        }
    }
}
