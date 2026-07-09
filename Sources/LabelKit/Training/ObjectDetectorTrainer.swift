import Foundation

/// The training algorithm Create ML uses for object detection. String-backed and
/// `CaseIterable` so the CLI derives `--algorithm` parsing, `--help` listing, and
/// completion from this one enum (mirrors `VisionBuiltinDetector.Kind`), and the
/// GUI drives its picker from the same source so the two can't drift apart.
public enum TrainingAlgorithm: String, CaseIterable, Sendable {
    /// Builds on a feature extractor baked into the OS: small model, fast to
    /// train, effective on modest datasets. The labelkit default.
    case transferLearning
    /// Trains a full YOLO network from scratch: larger and slower, wants more
    /// data, but can edge out transfer learning on large custom datasets.
    case fullNetwork
}

/// The user-facing knobs for a training run — everything else Create ML decides
/// (batch size, grid). A value snapshot handed to a trainer, so a run never
/// reaches back into live UI state.
public struct TrainingOptions: Sendable, Equatable {
    public var algorithm: TrainingAlgorithm
    /// Training iterations; `nil` lets Create ML pick from the dataset size.
    public var maxIterations: Int?
    /// Fraction of the training set held out to measure validation accuracy;
    /// `nil` skips validation entirely (no mAP reported).
    public var validationSplitFraction: Double?

    public init(algorithm: TrainingAlgorithm = .transferLearning,
                maxIterations: Int? = nil,
                validationSplitFraction: Double? = 0.2) {
        self.algorithm = algorithm
        self.maxIterations = maxIterations
        self.validationSplitFraction = validationSplitFraction
    }
}

/// The accuracy Create ML reports after a run. Mean average precision (mAP) at
/// IoU 0.5 is the headline number; `nil` when validation was skipped or the
/// framework couldn't compute it.
public struct TrainingMetrics: Codable, Equatable, Sendable {
    /// mAP on the held-out validation split, `0…1`.
    public var validationMeanAveragePrecision: Double?
    /// mAP on the training set, `0…1`.
    public var trainingMeanAveragePrecision: Double?

    public init(validationMeanAveragePrecision: Double? = nil,
                trainingMeanAveragePrecision: Double? = nil) {
        self.validationMeanAveragePrecision = validationMeanAveragePrecision
        self.trainingMeanAveragePrecision = trainingMeanAveragePrecision
    }
}

/// The outcome of a completed run: where the model was written and how it scored.
public struct TrainingResult: Sendable {
    public let modelURL: URL
    public let metrics: TrainingMetrics

    public init(modelURL: URL, metrics: TrainingMetrics) {
        self.modelURL = modelURL
        self.metrics = metrics
    }
}

/// Progress emitted while a run is in flight, ending with a single `.finished`.
/// A run that fails throws through the stream instead (unlike a generation run,
/// which silently yields nothing) — a bad dataset must surface.
public enum TrainingEvent: Sendable {
    /// `fraction` is overall completion `0…1`; `phase` is a short human label
    /// (e.g. "Iteration 120 of 200"), possibly empty early on.
    case progress(fraction: Double, phase: String)
    /// Terminal event carrying the written model + its metrics.
    case finished(TrainingResult)
}

/// Trains a Create ML object detector from an annotated dataset. The seam that
/// lets the CLI and GUI drive training without importing Create ML directly, and
/// lets tests inject a stub — Create ML training is never invoked in CI (the same
/// reason detection tests use a stub detector).
public protocol ObjectDetectorTrainer: Sendable {
    /// Train from `location`'s images + annotations file, writing the resulting
    /// `.mlmodel` to `outputURL`. Emits progress and one terminal `.finished`;
    /// throws through the stream on failure.
    func train(location: DatasetLocation, outputURL: URL, options: TrainingOptions)
        -> AsyncThrowingStream<TrainingEvent, Error>
}

/// The machine-readable result of a training run — the stable contract the
/// `train` CLI emits as JSON, and the shape an agent parses. Pure `Codable` data
/// in the library, so its construction (fields, rounding, ordering) is unit-tested
/// without the CLI, mirroring `DetectionReport`.
public struct TrainingReport: Codable, Equatable, Sendable {
    /// Output schema version — bump on any breaking field change.
    public var schemaVersion: Int
    /// labelkit version that produced this, for provenance.
    public var labelkit: String
    /// The algorithm used, e.g. `"transferLearning"`.
    public var algorithm: String
    /// Iterations requested; absent when left to Create ML.
    public var maxIterations: Int?
    /// Absolute path to the written model.
    public var output: String
    /// Number of dataset entries trained on.
    public var images: Int
    /// Distinct labels seen, in first-seen dataset order.
    public var labels: [String]
    public var metrics: TrainingMetrics

    public init(schemaVersion: Int, labelkit: String, algorithm: String,
                maxIterations: Int?, output: String, images: Int,
                labels: [String], metrics: TrainingMetrics) {
        self.schemaVersion = schemaVersion
        self.labelkit = labelkit
        self.algorithm = algorithm
        self.maxIterations = maxIterations
        self.output = output
        self.images = images
        self.labels = labels
        self.metrics = metrics
    }
}

public extension TrainingReport {
    /// Build a report from a finished run plus the dataset context the caller
    /// already holds. mAP values are rounded to 4 places for stable output.
    static func make(
        algorithm: TrainingAlgorithm,
        maxIterations: Int?,
        result: TrainingResult,
        images: Int,
        labels: [String],
        labelkitVersion version: String = labelkitVersion
    ) -> TrainingReport {
        TrainingReport(
            schemaVersion: 1,
            labelkit: version,
            algorithm: algorithm.rawValue,
            maxIterations: maxIterations,
            output: result.modelURL.path,
            images: images,
            labels: labels,
            metrics: TrainingMetrics(
                validationMeanAveragePrecision: round4(result.metrics.validationMeanAveragePrecision),
                trainingMeanAveragePrecision: round4(result.metrics.trainingMeanAveragePrecision)))
    }
}

private func round4(_ value: Double?) -> Double? {
    guard let value else { return nil }
    return (value * 10_000).rounded() / 10_000
}
