import CoreGraphics
import CoreML
import Foundation
import Vision

/// A `BoxDetector` backed by a custom Core ML object-detection model — the kind
/// Create ML exports and the format labelkit is built to edit. Loads a
/// `.mlmodel` / `.mlpackage` (compiled + cached on first use) or a precompiled
/// `.mlmodelc`, and runs it through Vision, which yields labelled boxes.
///
/// `@unchecked Sendable`: the `VNCoreMLModel` is immutable after construction
/// and Vision supports one shared model driving a fresh request per thread, so
/// concurrent `detect` calls are safe.
public final class CoreMLBoxDetector: BoxDetector, @unchecked Sendable {
    public let name: String
    public let providesLabels = true
    public let defaultLabel: String
    private let model: VNCoreMLModel
    private let cropAndScale: VNImageCropAndScaleOption

    /// - Parameters:
    ///   - modelURL: `.mlmodel`, `.mlpackage`, or `.mlmodelc` on disk.
    ///   - name: display name; defaults to the file's base name.
    ///   - defaultLabel: label for any observation the model leaves unlabeled.
    ///   - cropAndScale: how Vision fits the image to the model's input;
    ///     `.scaleFill` matches how Create ML detectors are typically trained.
    public init(modelURL: URL, name: String? = nil, defaultLabel: String = "object",
                cropAndScale: VNImageCropAndScaleOption = .scaleFill) throws {
        let compiled = try CompiledModelCache.compiledURL(for: modelURL)
        self.model = try VNCoreMLModel(for: MLModel(contentsOf: compiled))
        self.name = name ?? modelURL.deletingPathExtension().lastPathComponent
        self.defaultLabel = defaultLabel
        self.cropAndScale = cropAndScale
    }

    public func detect(_ cgImage: CGImage) throws -> [RawDetection] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = cropAndScale
        // The image is already EXIF-transformed by the decode path, so .up.
        try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([request])
        let observations = request.results as? [VNRecognizedObjectObservation] ?? []
        return observations.map { observation in
            let top = observation.labels.first
            return RawDetection(
                boundingBox: observation.boundingBox,
                label: top?.identifier,
                confidence: top?.confidence ?? observation.confidence)
        }
    }
}
