import CoreGraphics
import Foundation
import Vision

/// A `BoxDetector` backed by one of Apple's built-in Vision requests — no model
/// file required. Handy for bootstrapping a dataset (rough boxes to refine) or
/// for domains Vision already covers (faces, animals).
///
/// `@unchecked Sendable`: each `detect` builds its own request + handler and
/// shares no mutable state.
public final class VisionBuiltinDetector: BoxDetector, @unchecked Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case rectangles, faces, humans, animals, saliency
    }

    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }

    public var name: String {
        switch kind {
        case .rectangles: return "Rectangles"
        case .faces: return "Faces"
        case .humans: return "People"
        case .animals: return "Animals"
        case .saliency: return "Salient Objects"
        }
    }

    /// Only the animal recognizer names a class; the rest merely localize.
    public var providesLabels: Bool { kind == .animals }

    public var defaultLabel: String {
        switch kind {
        case .rectangles: return "rectangle"
        case .faces: return "face"
        case .humans: return "person"
        case .animals: return "animal"
        case .saliency: return "object"
        }
    }

    public func detect(_ cgImage: CGImage) throws -> [RawDetection] {
        let request = makeRequest()
        try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([request])
        return rawDetections(from: request)
    }

    private func makeRequest() -> VNImageBasedRequest {
        switch kind {
        case .rectangles:
            let request = VNDetectRectanglesRequest()
            request.maximumObservations = 16   // default is 1 — allow a scene of them
            request.minimumConfidence = 0      // let the caller's threshold decide
            request.minimumAspectRatio = 0.1
            return request
        case .faces: return VNDetectFaceRectanglesRequest()
        case .humans: return VNDetectHumanRectanglesRequest()
        case .animals: return VNRecognizeAnimalsRequest()
        case .saliency: return VNGenerateAttentionBasedSaliencyImageRequest()
        }
    }

    private func rawDetections(from request: VNImageBasedRequest) -> [RawDetection] {
        switch kind {
        case .rectangles:
            return (request.results as? [VNRectangleObservation] ?? []).map {
                RawDetection(boundingBox: $0.boundingBox, confidence: $0.confidence)
            }
        case .faces, .humans:
            // VNFaceObservation / VNHumanObservation are VNDetectedObjectObservations.
            return (request.results as? [VNDetectedObjectObservation] ?? []).map {
                RawDetection(boundingBox: $0.boundingBox, confidence: $0.confidence)
            }
        case .animals:
            return (request.results as? [VNRecognizedObjectObservation] ?? []).map {
                let top = $0.labels.first
                return RawDetection(boundingBox: $0.boundingBox,
                                    label: top?.identifier,
                                    confidence: top?.confidence ?? $0.confidence)
            }
        case .saliency:
            // One saliency observation carries the salient regions as sub-boxes.
            return (request.results as? [VNSaliencyImageObservation] ?? [])
                .flatMap { $0.salientObjects ?? [] }
                .map { RawDetection(boundingBox: $0.boundingBox, confidence: $0.confidence) }
        }
    }
}
