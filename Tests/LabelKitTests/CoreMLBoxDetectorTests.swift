import CoreGraphics
import Foundation
import XCTest
@testable import LabelKit

/// Opt-in end-to-end check of the custom Core ML path. Skips unless both env
/// vars point at a real object-detection model and a test image, so CI (which
/// ships neither) stays green while local dev can validate against, e.g., the
/// iris `cards_real.mlmodel`:
///
///   LABELKIT_TEST_MODEL=…/cards_real.mlmodel \
///   LABELKIT_TEST_IMAGE=…/images/foo.jpg swift test --filter CoreMLBoxDetector
final class CoreMLBoxDetectorTests: XCTestCase {
    func testLoadsModelAndDetectsBoxes() throws {
        let env = ProcessInfo.processInfo.environment
        let modelPath = env["LABELKIT_TEST_MODEL"] ?? ""
        let imagePath = env["LABELKIT_TEST_IMAGE"] ?? ""
        try XCTSkipIf(modelPath.isEmpty || imagePath.isEmpty,
                      "set LABELKIT_TEST_MODEL and LABELKIT_TEST_IMAGE to run")

        let imageURL = URL(fileURLWithPath: imagePath)
        let detector = try CoreMLBoxDetector(modelURL: URL(fileURLWithPath: modelPath))
        let pixelSize = try XCTUnwrap(ImageMetadata.pixelSize(of: imageURL))
        let cgImage = try XCTUnwrap(ImageDownsampler.decode(url: imageURL, maxPixel: 1536))

        let raw = try detector.detect(cgImage)
        let candidates = raw.compactMap {
            DetectionGeometry.candidate(from: $0, pixelSize: pixelSize,
                                        fallbackLabel: detector.defaultLabel)
        }
        let kept = DetectionMerge.newBoxes(candidates: candidates, existing: [], minConfidence: 0.5)

        print("CoreML detector '\(detector.name)': \(raw.count) raw → \(kept.count) boxes")
        for box in kept {
            print("  \(box.label) \(box.rect)")
            XCTAssertTrue(CGRect(origin: .zero, size: pixelSize).contains(box.rect))
        }
        XCTAssertFalse(kept.isEmpty, "expected at least one detection on the test image")
    }
}
