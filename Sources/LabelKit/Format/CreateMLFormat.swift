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
        // JSONSerialization returns NSArray/NSDictionary. They are read as
        // such: casting each one to a Swift dictionary copies it and bridges
        // every key, which on a large file costs several times the parse itself.
        guard let root = try JSONSerialization.jsonObject(with: data) as? NSArray else {
            throw CreateMLFormatError.rootIsNotArray
        }
        var records: [ImageAnnotationRecord] = []
        records.reserveCapacity(root.count)
        for (index, rawEntry) in root.enumerated() {
            let entry = rawEntry as? NSDictionary
            guard let image = entry?["image"] as? String else {
                throw CreateMLFormatError.entryMissingImage(index: index)
            }
            var boxes: [BoxRecord] = []
            if let rawAnnotations = entry?["annotations"] as? NSArray {
                boxes.reserveCapacity(rawAnnotations.count)
                for case let annotation as NSDictionary in rawAnnotations {
                    let coordinates = annotation["coordinates"] as? NSDictionary
                    func value(_ key: String) -> Double { (coordinates?[key] as? NSNumber)?.doubleValue ?? 0 }
                    boxes.append(BoxRecord(
                        label: (annotation["label"] as? String)?.native ?? "unlabeled",
                        x: value("x"), y: value("y"),
                        width: value("width"), height: value("height"),
                        extras: extras(of: annotation, excluding: annotationKeys)
                    ))
                }
            }
            records.append(ImageAnnotationRecord(
                image: image.native,
                boxes: boxes,
                extras: entry.map { extras(of: $0, excluding: entryKeys) } ?? [:]
            ))
        }
        return records
    }

    public static func serialize(_ records: [ImageAnnotationRecord]) -> Data {
        CreateMLWriter.serialize(records)
    }

    private static func extras(of dict: NSDictionary, excluding known: Set<String>) -> [String: JSONValue] {
        // Almost every entry carries only the modelled keys; count those
        // instead of building a filtered copy to find that out.
        let modelled = known.reduce(0) { $0 + (dict[$1] == nil ? 0 : 1) }
        guard dict.count > modelled else { return [:] }
        var result: [String: JSONValue] = [:]
        for (key, value) in dict {
            guard let key = key as? String, !known.contains(key) else { continue }
            result[key.native] = JSONValue(value)
        }
        return result
    }
}
