import CoreGraphics
import Foundation

/// One image queued for generation: where to read it and what it already holds
/// (a value snapshot, so the engine never reaches back into the main-actor
/// store). Existing boxes drive additive de-duplication.
public struct GenerationJob: Sendable {
    public let filename: String
    public let imageURL: URL
    public let existingBoxes: [BoundingBox]

    public init(filename: String, imageURL: URL, existingBoxes: [BoundingBox]) {
        self.filename = filename
        self.imageURL = imageURL
        self.existingBoxes = existingBoxes
    }
}

/// Runs a `BoxDetector` over a batch of images off the main thread, with
/// bounded concurrency, streaming each image's boxes as its detection finishes
/// so the UI can apply them (and refresh badges) incrementally.
///
/// The engine returns only the boxes to **add** (post-confidence, post-NMS,
/// post-dedupe); applying them to the store — and grouping the run into one
/// undo step — is the caller's job on the main actor.
public enum GenerationEngine {
    public struct Settings: Sendable {
        /// Drop detections below this score.
        public var minConfidence: Float
        /// Label for detections a detector leaves unlabeled.
        public var fallbackLabel: String
        /// Longest edge the image is decoded to before detection. Vision
        /// rescales to the model's fixed input anyway, so a full-res decode
        /// buys nothing — this only bounds decode cost.
        public var maxDecodePixel: CGFloat
        /// How many images decode + detect at once.
        public var maxConcurrent: Int

        public init(minConfidence: Float = 0.5, fallbackLabel: String = "object",
                    maxDecodePixel: CGFloat = 1536, maxConcurrent: Int = 3) {
            self.minConfidence = minConfidence
            self.fallbackLabel = fallbackLabel
            self.maxDecodePixel = maxDecodePixel
            self.maxConcurrent = maxConcurrent
        }
    }

    public struct ImageResult: Sendable {
        public let filename: String
        /// Boxes to add — only non-empty results are streamed.
        public let newBoxes: [BoundingBox]
    }

    /// Stream each image's new boxes as its detection finishes. Only images
    /// that gained boxes are yielded. Cancelling the consuming task (or breaking
    /// out of the `for await`) stops further work: the stream's termination
    /// handler cancels the producer, and in-flight jobs bail at their next
    /// cancellation check.
    public static func stream(jobs: [GenerationJob], detector: BoxDetector,
                              settings: Settings) -> AsyncStream<ImageResult> {
        AsyncStream { continuation in
            let task = Task {
                await process(jobs: jobs, detector: detector, settings: settings,
                              continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func process(jobs: [GenerationJob], detector: BoxDetector,
                                settings: Settings,
                                continuation: AsyncStream<ImageResult>.Continuation) async {
        guard !jobs.isEmpty else { return }
        // Sliding-window task group: keep at most `maxConcurrent` decodes in
        // flight, refilling as each finishes.
        await withTaskGroup(of: ImageResult.self) { group in
            var next = jobs.makeIterator()
            for _ in 0..<max(1, settings.maxConcurrent) {
                guard let job = next.next() else { break }
                group.addTask { detect(job: job, detector: detector, settings: settings) }
            }
            while let result = await group.next() {
                if !result.newBoxes.isEmpty { continuation.yield(result) }
                if Task.isCancelled { group.cancelAll(); break }
                if let job = next.next() {
                    group.addTask { detect(job: job, detector: detector, settings: settings) }
                }
            }
        }
    }

    /// Detect for one image via the shared `SingleImageDetection` primitive,
    /// then merge additively against what the entry already holds. Runs on a
    /// background task; any failure (unreadable image, detector error) yields no
    /// boxes rather than aborting the batch.
    private static func detect(job: GenerationJob, detector: BoxDetector,
                               settings: Settings) -> ImageResult {
        let empty = ImageResult(filename: job.filename, newBoxes: [])
        guard !Task.isCancelled,
              let result = try? SingleImageDetection.run(
                  imageURL: job.imageURL, detector: detector,
                  maxDecodePixel: settings.maxDecodePixel,
                  fallbackLabel: settings.fallbackLabel)
        else { return empty }

        let newBoxes = DetectionMerge.newBoxes(
            candidates: result.candidates, existing: job.existingBoxes,
            minConfidence: settings.minConfidence)
        return ImageResult(filename: job.filename, newBoxes: newBoxes)
    }
}
