import Foundation

public enum CreateMLFormatError: LocalizedError, Equatable {
    case rootIsNotArray
    case entryMissingImage(index: Int)

    public var errorDescription: String? {
        switch self {
        case .rootIsNotArray:
            return "annotations file is not a JSON array of entries"
        case .entryMissingImage(let index):
            return "entry #\(index) has no \"image\" key"
        }
    }
}

/// Apple Create ML object-detection JSON:
/// `[{"image": "f.jpg", "annotations": [{"label": "card", "coordinates": {"x","y","width","height"}}]}]`
/// Coordinates are box CENTERS in image pixels, top-left image origin.
public enum CreateMLFormat: AnnotationFormat {
    /// Keys the editor models; everything else rides along in `extras`.
    private static let entryKeys: Set<String> = ["image", "annotations"]
    private static let annotationKeys: Set<String> = ["label", "coordinates"]

    public static func load(_ data: Data) throws -> [ImageAnnotationRecord] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw CreateMLFormatError.rootIsNotArray
        }
        return try root.enumerated().map { index, rawEntry in
            let entry = rawEntry as? [String: Any] ?? [:]
            guard let image = entry["image"] as? String else {
                throw CreateMLFormatError.entryMissingImage(index: index)
            }
            let rawAnnotations = entry["annotations"] as? [Any] ?? []
            let boxes = rawAnnotations.compactMap { rawAnnotation -> BoxRecord? in
                guard let annotation = rawAnnotation as? [String: Any] else { return nil }
                let coordinates = annotation["coordinates"] as? [String: Any] ?? [:]
                func value(_ key: String) -> Double { (coordinates[key] as? NSNumber)?.doubleValue ?? 0 }
                return BoxRecord(
                    label: annotation["label"] as? String ?? "unlabeled",
                    x: value("x"), y: value("y"),
                    width: value("width"), height: value("height"),
                    extras: extras(of: annotation, excluding: annotationKeys)
                )
            }
            return ImageAnnotationRecord(
                image: image,
                boxes: boxes,
                extras: extras(of: entry, excluding: entryKeys)
            )
        }
    }

    public static func serialize(_ records: [ImageAnnotationRecord]) -> Data {
        CreateMLWriter.serialize(records)
    }

    private static func extras(of dict: [String: Any], excluding known: Set<String>) -> [String: JSONValue] {
        dict.filter { !known.contains($0.key) }.mapValues(JSONValue.init)
    }
}
