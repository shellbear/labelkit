import Combine
import CoreGraphics
import CreateML
import Foundation

/// The real trainer: Apple's `CreateML.MLObjectDetector`. Lives in the library
/// alongside `CoreMLBoxDetector` (which already uses Core ML) — Create ML is a
/// headless framework, so this stays within the "no AppKit/SwiftUI" rule.
///
/// labelkit's on-disk annotations are already exactly what Create ML expects:
/// `directoryWithImages` reads them as-is, and `.boundingBox()` defaults
/// (`.pixel`, origin `.topLeft`, anchor `.center`) match the center-anchored
/// pixel coordinates labelkit writes — so no coordinate conversion is needed.
public struct CreateMLObjectDetectorTrainer: ObjectDetectorTrainer {
    public init() {}

    public func train(location: DatasetLocation, outputURL: URL, options: TrainingOptions)
        -> AsyncThrowingStream<TrainingEvent, Error>
    {
        AsyncThrowingStream { continuation in
            // The session is retained by `onTermination` for the life of the
            // stream; when the consumer stops (or we finish), it cancels the job.
            let session = TrainingSession(
                location: location, outputURL: outputURL, options: options,
                continuation: continuation)
            continuation.onTermination = { _ in session.cancel() }
            session.start()
        }
    }
}

/// Bridges one `MLJob` (a `Foundation.Progress` + a Combine result publisher) to
/// the `AsyncThrowingStream<TrainingEvent>` the app consumes, and maps a
/// terminated stream to `MLJob.cancel()` — the same stream+`onTermination`-cancels
/// shape `GenerationEngine` uses. `@unchecked Sendable`: the mutable state is
/// created once in `start()` and torn down once under `lock`.
private final class TrainingSession: @unchecked Sendable {
    private let location: DatasetLocation
    private let outputURL: URL
    private let options: TrainingOptions
    private let continuation: AsyncThrowingStream<TrainingEvent, Error>.Continuation

    private var job: MLJob<MLObjectDetector>?
    private var progressObservation: NSKeyValueObservation?
    private var resultCancellable: AnyCancellable?
    private let lock = NSLock()
    private var finished = false

    init(location: DatasetLocation, outputURL: URL, options: TrainingOptions,
         continuation: AsyncThrowingStream<TrainingEvent, Error>.Continuation) {
        self.location = location
        self.outputURL = outputURL
        self.options = options
        self.continuation = continuation
    }

    func start() {
        do {
            let source = MLObjectDetector.DataSource.directoryWithImages(
                at: location.imagesDirectory, annotationFile: location.annotationsURL)

            let algorithm: MLObjectDetector.ModelParameters.ModelAlgorithmType
            switch options.algorithm {
            case .transferLearning: algorithm = .transferLearning(.objectPrint())
            case .fullNetwork:      algorithm = .darknetYolo
            }
            let validation: MLObjectDetector.ModelParameters.ValidationData =
                options.validationSplitFraction
                    .map { .split(strategy: .fixed(ratio: $0, seed: nil)) } ?? MLObjectDetector.ModelParameters.ValidationData.none

            let parameters = MLObjectDetector.ModelParameters(
                validation: validation,
                batchSize: nil,
                maxIterations: options.maxIterations,
                gridSize: CGSize(width: 13, height: 13),
                algorithm: algorithm)

            // Route iteration count through the session too, so progress totals
            // and the model's cap agree; omit it (framework default) otherwise.
            let job: MLJob<MLObjectDetector>
            if let iterations = options.maxIterations {
                job = try MLObjectDetector.train(
                    trainingData: source, annotationType: .boundingBox(),
                    parameters: parameters,
                    sessionParameters: MLTrainingSessionParameters(iterations: iterations))
            } else {
                job = try MLObjectDetector.train(
                    trainingData: source, annotationType: .boundingBox(),
                    parameters: parameters)
            }
            self.job = job

            let startDate = job.startDate
            progressObservation = job.progress.observe(
                \.fractionCompleted, options: [.initial, .new]
            ) { [weak self] progress, _ in
                self?.continuation.yield(.progress(Self.snapshot(progress, startDate: startDate)))
            }

            resultCancellable = job.result.sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let error) = completion { self?.finish(throwing: error) }
                },
                receiveValue: { [weak self] detector in
                    self?.complete(with: detector)
                })
        } catch {
            finish(throwing: error)
        }
    }

    private func complete(with detector: MLObjectDetector) {
        do {
            try detector.write(to: outputURL, metadata: nil)
            let metrics = Self.summarize(
                detector, hasValidation: options.validationSplitFraction != nil)
            continuation.yield(.finished(TrainingResult(modelURL: outputURL, metrics: metrics)))
            finish(throwing: nil)
        } catch {
            finish(throwing: error)
        }
    }

    /// Consumer stopped the stream — cancel the job without emitting anything
    /// (the stream is already terminating).
    func cancel() {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()
        cleanup()
    }

    private func finish(throwing error: Error?) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()
        cleanup()
        continuation.finish(throwing: error)
    }

    private func cleanup() {
        progressObservation?.invalidate()
        progressObservation = nil
        resultCancellable?.cancel()
        resultCancellable = nil
        job?.cancel()
        job = nil
    }

    /// Turn Create ML's `Foundation.Progress` into a rich snapshot. `MLProgress`
    /// parses the progress's userInfo for the phase, per-phase item counts, live
    /// metrics, and elapsed time; we fall back to the plain `Progress` fields if
    /// that parse ever comes up empty.
    private static func snapshot(_ progress: Progress, startDate: Date) -> TrainingProgress {
        let ml = MLProgress(progress: progress)
        let phase: TrainingPhase
        switch ml?.phase {
        case .extractingFeatures: phase = .preparing
        case .training: phase = .training
        case .evaluating: phase = .evaluating
        default: phase = .other
        }
        let loss = (ml?.metrics[.loss] as? Double) ?? (ml?.metrics[.loss] as? NSNumber)?.doubleValue
        let total = ml?.totalItemCount ?? (progress.totalUnitCount > 0 ? Int(progress.totalUnitCount) : nil)
        return TrainingProgress(
            fraction: progress.fractionCompleted,
            phase: phase,
            itemCount: ml?.itemCount ?? Int(progress.completedUnitCount),
            totalItemCount: total,
            elapsedTime: ml?.elapsedTime ?? Date().timeIntervalSince(startDate),
            loss: loss)
    }

    private static func summarize(_ detector: MLObjectDetector, hasValidation: Bool) -> TrainingMetrics {
        func clean(_ value: Double) -> Double? { value.isFinite && value >= 0 ? value : nil }
        let training = detector.trainingMetrics
        let validation = detector.validationMetrics
        return TrainingMetrics(
            validationMeanAveragePrecision:
                hasValidation && validation.isValid ? clean(validation.meanAveragePrecision.IoU50) : nil,
            trainingMeanAveragePrecision:
                training.isValid ? clean(training.meanAveragePrecision.IoU50) : nil)
    }
}
