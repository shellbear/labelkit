import CoreGraphics
import Foundation

/// One box handed to `labelkit annotate`, before it is resolved against the
/// image it belongs to.
public struct ImportedBox: Equatable, Sendable {
    /// Canonical geometry: top-left origin, `origin` = the box's top-left corner.
    public enum Geometry: Equatable, Sendable {
        /// Pixels of the image as it is on disk.
        case pixels(CGRect)
        /// Fractions of the image in `[0,1]`.
        case normalized(CGRect)
        /// Pixels of a copy of the image that is `reference` in size — what a
        /// model reports when it was shown a downscaled picture. Rescaled to
        /// the real image when the two sizes differ.
        case scaledPixels(CGRect, reference: CGSize)
    }

    public var label: String
    public var geometry: Geometry

    public init(label: String, geometry: Geometry) {
        self.label = label
        self.geometry = geometry
    }
}

/// All the boxes supplied for one image.
public struct ImportedImage: Equatable, Sendable {
    public var image: String
    public var boxes: [ImportedBox]

    public init(image: String, boxes: [ImportedBox]) {
        self.image = image
        self.boxes = boxes
    }
}

/// How to read four numbers as a box. `units`, `origin` and `anchor` are the
/// axes Create ML itself uses to describe annotations; `order` and the extra
/// unit scales cover what vision models and other tools emit. Naming a
/// convention replaces writing a conversion script.
public struct BoxConvention: Equatable, Sendable {
    public enum Units: String, Sendable, CaseIterable {
        /// Image pixels.
        case pixel
        /// Fractions of the image, `0…1`.
        case normalized
        /// `0…1000` across the image (Gemini, Qwen3-VL).
        case thousandths = "0-1000"
        /// `0…100` across the image (Label Studio).
        case percent

        /// The value that means "the full width or height"; nil for pixels.
        var fullScale: Double? {
            switch self {
            case .pixel: return nil
            case .normalized: return 1
            case .thousandths: return 1000
            case .percent: return 100
            }
        }
    }

    public enum Origin: String, Sendable, CaseIterable {
        /// y grows downward from the top edge (images, Create ML, most tools).
        case topLeft = "top-left"
        /// y grows upward from the bottom edge (Apple Vision).
        case bottomLeft = "bottom-left"
    }

    public enum Anchor: String, Sendable, CaseIterable {
        /// `x`,`y` is the box corner nearest the origin.
        case corner
        /// `x`,`y` is the centre of the box (Create ML, YOLO).
        case center
    }

    /// What four numbers in a row mean.
    public enum Order: String, Sendable, CaseIterable {
        /// x, y, width, height (COCO; with `anchor: .center`, YOLO).
        case xywh
        /// Two opposite corners, x first: x1, y1, x2, y2.
        case xyxy
        /// Two opposite corners, y first: y1, x1, y2, x2 (Gemini, PaliGemma).
        case yxyx
    }

    public var units: Units
    public var origin: Origin
    public var anchor: Anchor
    public var order: Order
    /// The image size that pixel coordinates refer to, when it is not the size
    /// of the file on disk — a model that was shown a downscaled copy reports
    /// pixels of that copy. Boxes are rescaled to the real image.
    public var referenceSize: CGSize?

    public init(units: Units = .pixel, origin: Origin = .topLeft, anchor: Anchor = .corner,
                order: Order = .xywh, referenceSize: CGSize? = nil) {
        self.units = units
        self.origin = origin
        self.anchor = anchor
        self.order = order
        self.referenceSize = referenceSize
    }

    /// labelkit's own reporting convention, and the default for input.
    public static let pixelTopLeftCorner = BoxConvention()
    /// What Create ML stores on disk.
    public static let createML = BoxConvention(units: .pixel, origin: .topLeft, anchor: .center)

    /// Why this convention can't be used, if it can't. A bottom-left origin in
    /// pixels would need every image's height before a box could be placed;
    /// nothing in practice emits it, so it is refused rather than guessed at.
    public var unsupportedReason: String? {
        units == .pixel && origin == .bottomLeft
            ? "a bottom-left origin is only supported with normalized units"
            : nil
    }

    /// Turn four numbers in this convention into canonical geometry.
    func geometry(_ v: (Double, Double, Double, Double)) -> ImportedBox.Geometry {
        var minX: Double, minY: Double, width: Double, height: Double
        switch order {
        case .xywh:
            width = v.2
            height = v.3
            minX = anchor == .center ? v.0 - width / 2 : v.0
            minY = anchor == .center ? v.1 - height / 2 : v.1
        case .xyxy:
            minX = min(v.0, v.2)
            minY = min(v.1, v.3)
            width = abs(v.2 - v.0)
            height = abs(v.3 - v.1)
        case .yxyx:
            minX = min(v.1, v.3)
            minY = min(v.0, v.2)
            width = abs(v.3 - v.1)
            height = abs(v.2 - v.0)
        }

        if let full = units.fullScale {
            if origin == .bottomLeft { minY = full - (minY + height) }
            return .normalized(CGRect(x: minX / full, y: minY / full, width: width / full, height: height / full))
        }
        let rect = CGRect(x: minX, y: minY, width: width, height: height)
        if let reference = referenceSize, reference.width > 0, reference.height > 0 {
            return .scaledPixels(rect, reference: reference)
        }
        return .pixels(rect)
    }
}

public struct BoxImportError: LocalizedError, Equatable {
    public var message: String
    public var errorDescription: String? { message }
}

/// Reads the box input `labelkit annotate` accepts. It is forgiving about
/// *shape*, so that what labelkit prints, what a vision model answers, and the
/// common dataset files all work without a conversion step — and strict about
/// *meaning*: where a shape doesn't say what its numbers are, `Options`
/// decides, and nothing is guessed from the values.
///
/// **Container** — one JSON object, a JSON array, or NDJSON (one object per
/// line). A Markdown code fence around it is ignored. A COCO file (`images`,
/// `annotations`, `categories`) is read as a whole dataset.
///
/// **Per image** — a name under `image` (also `imagefilename`, `file_name`,
/// `filename`, or the basename of `path`) and a list under `boxes` (also
/// `detections`, `annotations`, `annotation`, `objects`, `predictions`).
/// `width` + `height` (or `imageWidth` + `imageHeight`) on the entry say what
/// size its pixel coordinates refer to.
///
/// **Per box** — a label under `label` (also `class`, `name`, `category`; or
/// the default) and one geometry:
///
/// | Shape | Read as |
/// |---|---|
/// | `x, y, width, height` on the box or under `box` | `Options.convention` |
/// | `normalized: {x,y,width,height}` | the same, in fractions |
/// | `coordinates: {x,y,width,height}` | Create ML: pixels, centre-anchored |
/// | `xyxy: [x1,y1,x2,y2]`, or `x1,y1,x2,y2` / `xmin,…` / `x_min,…` keys | corners, in the convention's units |
/// | `bbox_2d: [x1,y1,x2,y2]` | corners, in the convention's units (Qwen) |
/// | `box_2d: [y1,x1,y2,x2]` | corners, y first, 0–1000 (Gemini) |
/// | `bbox: [a,b,c,d]` or `box: [a,b,c,d]` | the convention's order and units |
///
/// A list of bare `[a,b,c,d]` arrays with a parallel `labels` list is read the
/// same way as `bbox`.
public enum BoxImportParser {
    public struct Options: Equatable, Sendable {
        public var convention: BoxConvention
        /// Label for boxes that don't carry one. Without it a box with no
        /// label is an error.
        public var defaultLabel: String?
        /// When set, the input is the boxes of this one image: entries need no
        /// `image` key, and a bare list of boxes is accepted.
        public var image: String?

        public init(convention: BoxConvention = .pixelTopLeftCorner, defaultLabel: String? = nil,
                    image: String? = nil) {
            self.convention = convention
            self.defaultLabel = defaultLabel
            self.image = image
        }
    }

    public static func parse(_ data: Data, options: Options = Options()) throws -> [ImportedImage] {
        let text = stripCodeFence(String(decoding: data, as: UTF8.self))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        if let whole = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) {
            switch whole {
            case let object as [String: Any]:
                if let coco = try coco(from: object) { return coco }
                if let image = options.image, !isImageEntry(object) {
                    // A single box for the one named image.
                    return [ImportedImage(image: image, boxes: [try box(
                        from: object, at: "input (\(image))", convention: options.convention, options: options)])]
                }
                return [try image(from: object, at: "input", options: options)]
            case let array as [Any]:
                if let image = options.image, array.contains(where: { !isImageEntry($0) }) {
                    // A bare list of boxes for the one named image.
                    return [ImportedImage(image: image, boxes: try boxes(
                        from: array, labels: nil, at: "input (\(image))",
                        convention: options.convention, options: options))]
                }
                return try array.enumerated().map { index, element in
                    guard let object = element as? [String: Any] else {
                        throw BoxImportError(message: "entry #\(index + 1) is not a JSON object")
                    }
                    return try image(from: object, at: "entry #\(index + 1)", options: options)
                }
            default:
                throw BoxImportError(message: "expected a JSON object, an array of objects, or NDJSON")
            }
        }

        // Not one JSON document: read it as NDJSON.
        var images: [ImportedImage] = []
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                throw BoxImportError(message: "line \(index + 1) is not a JSON object")
            }
            images.append(try image(from: object, at: "line \(index + 1)", options: options))
        }
        return images
    }

    /// Parse the inline `--box` form: `label:a,b,c,d`, or just `a,b,c,d` when a
    /// default label is set. The four numbers are read with the convention's
    /// order. The label may itself contain colons; the numbers are whatever
    /// follows the last one.
    public static func parseInlineBox(_ text: String, options: Options = Options()) throws -> ImportedBox {
        var label = options.defaultLabel ?? ""
        var numbers = Substring(text)
        if let colon = text.lastIndex(of: ":") {
            label = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
            numbers = text[text.index(after: colon)...]
        }
        let parts = numbers.split(separator: ",", omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !label.isEmpty, parts.count == 4, let a = parts[0], let b = parts[1],
              let c = parts[2], let d = parts[3] else {
            throw BoxImportError(message: "expected label:x,y,width,height, got '\(text)'")
        }
        return ImportedBox(label: label, geometry: options.convention.geometry((a, b, c, d)))
    }

    /// Parse `WIDTHxHEIGHT`, e.g. `1568x1176`.
    public static func parseSize(_ text: String) -> CGSize? {
        let parts = text.lowercased().split(separator: "x").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let width = parts[0], let height = parts[1], width > 0, height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    // MARK: - Containers

    private static let imageKeys = ["image", "imagefilename", "file_name", "filename"]
    private static let listKeys = ["boxes", "detections", "annotations", "annotation", "objects",
                                   "predictions", "bboxes"]
    private static let labelKeys = ["label", "class", "name", "category"]
    private static let parallelLabelKeys = ["labels", "text_labels", "classes", "names"]

    /// A model asked for JSON usually wraps it in a Markdown fence, on its own
    /// lines or all on one. Returns what is between the first and last fence,
    /// without an info string such as `json`.
    static func stripCodeFence(_ text: String) -> String {
        guard let open = text.range(of: "```"),
              let close = text.range(of: "```", options: .backwards),
              close.lowerBound >= open.upperBound else { return text }
        var body = text[open.upperBound..<close.lowerBound]
        let info = body.prefix { $0.isLetter || $0.isNumber }
        if !info.isEmpty, body.dropFirst(info.count).first?.isWhitespace == true {
            body = body.dropFirst(info.count)
        }
        return String(body)
    }

    private static func isImageEntry(_ element: Any) -> Bool {
        guard let object = element as? [String: Any] else { return false }
        return listKeys.contains { object[$0] != nil }
    }

    private static func image(from object: [String: Any], at place: String,
                              options: Options) throws -> ImportedImage {
        let name: String
        if let fixed = options.image {
            name = fixed
        } else if let key = imageKeys.first(where: { (object[$0] as? String)?.isEmpty == false }),
                  let value = object[key] as? String {
            name = value
        } else if let path = object["path"] as? String, !path.isEmpty {
            name = URL(fileURLWithPath: path).lastPathComponent
        } else {
            throw BoxImportError(message: "\(place): missing \"image\"")
        }
        let here = "\(place) (\(name))"

        guard let key = listKeys.first(where: { object[$0] != nil }) else {
            throw BoxImportError(message: "\(here): expected a \"boxes\", \"detections\" or \"annotations\" list")
        }
        guard let rawBoxes = object[key] as? [Any] else {
            throw BoxImportError(message: "\(here): \"\(key)\" is not a list")
        }

        // Pixel coordinates are relative to the size the entry states, if any.
        var convention = options.convention
        if let width = number(object["width"] ?? object["imageWidth"]),
           let height = number(object["height"] ?? object["imageHeight"]), width > 0, height > 0 {
            convention.referenceSize = CGSize(width: width, height: height)
        }
        let labels = parallelLabelKeys.lazy.compactMap { object[$0] as? [Any] }.first
        return ImportedImage(image: name, boxes: try boxes(
            from: rawBoxes, labels: labels, at: here, convention: convention, options: options))
    }

    private static func boxes(from rawBoxes: [Any], labels: [Any]?, at place: String,
                              convention: BoxConvention, options: Options) throws -> [ImportedBox] {
        try rawBoxes.enumerated().map { index, raw in
            let here = "\(place), box #\(index + 1)"
            if let numbers = raw as? [Any] {
                // Bare [a,b,c,d]; its label comes from a parallel list or the default.
                let parallel = labels.flatMap { index < $0.count ? $0[index] as? String : nil }
                guard let label = parallel ?? options.defaultLabel else {
                    throw BoxImportError(message: "\(here): missing \"label\"")
                }
                return ImportedBox(label: label, geometry: convention.geometry(try four(numbers, at: here)))
            }
            return try box(from: raw, at: here, convention: convention, options: options)
        }
    }

    /// COCO detection JSON: boxes are `[x, y, width, height]` in pixels from
    /// the top-left corner, keyed to images and categories by id. Images with
    /// no annotations come through with an empty box list.
    private static func coco(from object: [String: Any]) throws -> [ImportedImage]? {
        guard let images = object["images"] as? [[String: Any]],
              let annotations = object["annotations"] as? [[String: Any]],
              let categories = object["categories"] as? [[String: Any]] else { return nil }

        var categoryName: [Int: String] = [:]
        for category in categories {
            if let id = (category["id"] as? NSNumber)?.intValue, let name = category["name"] as? String {
                categoryName[id] = name
            }
        }
        var order: [Int] = []
        var result: [Int: ImportedImage] = [:]
        var conventions: [Int: BoxConvention] = [:]
        for image in images {
            guard let id = (image["id"] as? NSNumber)?.intValue, let file = image["file_name"] as? String else {
                throw BoxImportError(message: "COCO: an image entry is missing \"id\" or \"file_name\"")
            }
            order.append(id)
            result[id] = ImportedImage(image: URL(fileURLWithPath: file).lastPathComponent, boxes: [])
            var convention = BoxConvention.pixelTopLeftCorner
            if let width = number(image["width"]), let height = number(image["height"]), width > 0, height > 0 {
                convention.referenceSize = CGSize(width: width, height: height)
            }
            conventions[id] = convention
        }
        for (index, annotation) in annotations.enumerated() {
            let here = "COCO annotation #\(index + 1)"
            guard let imageID = (annotation["image_id"] as? NSNumber)?.intValue, result[imageID] != nil else {
                throw BoxImportError(message: "\(here): \"image_id\" matches no image")
            }
            guard let categoryID = (annotation["category_id"] as? NSNumber)?.intValue,
                  let label = categoryName[categoryID] else {
                throw BoxImportError(message: "\(here): \"category_id\" matches no category")
            }
            guard let bbox = annotation["bbox"] as? [Any] else {
                throw BoxImportError(message: "\(here): missing \"bbox\"")
            }
            let convention = conventions[imageID] ?? .pixelTopLeftCorner
            result[imageID]?.boxes.append(
                ImportedBox(label: label, geometry: convention.geometry(try four(bbox, at: here))))
        }
        return order.compactMap { result[$0] }
    }

    // MARK: - Boxes

    private static func box(from raw: Any, at place: String, convention: BoxConvention,
                            options: Options) throws -> ImportedBox {
        guard let object = raw as? [String: Any] else {
            throw BoxImportError(message: "\(place): not a JSON object")
        }
        let ownLabel = labelKeys.lazy.compactMap { object[$0] as? String }.first
        guard let label = ownLabel ?? options.defaultLabel else {
            throw BoxImportError(message: "\(place): missing \"label\"")
        }
        func made(_ values: (Double, Double, Double, Double), _ convention: BoxConvention) -> ImportedBox {
            ImportedBox(label: label, geometry: convention.geometry(values))
        }
        func with(_ change: (inout BoxConvention) -> Void) -> BoxConvention {
            var copy = convention
            change(&copy)
            return copy
        }

        if let coordinates = object["coordinates"] as? [String: Any] {
            // Create ML's own shape; only the reference size carries over.
            var createML = BoxConvention.createML
            createML.referenceSize = convention.referenceSize
            return made(try named(coordinates, ["x", "y", "width", "height"], at: "\(place) coordinates"), createML)
        }
        if let gemini = object["box_2d"] as? [Any] {
            return made(try four(gemini, at: "\(place) box_2d"),
                        BoxConvention(units: .thousandths, order: .yxyx))
        }
        for key in ["xyxy", "bbox_2d"] {
            if let corners = object[key] as? [Any] {
                return made(try four(corners, at: "\(place) \(key)"), with { $0.order = .xyxy })
            }
        }
        for key in ["bbox", "box"] {
            if let numbers = object[key] as? [Any] {
                return made(try four(numbers, at: "\(place) \(key)"), convention)
            }
        }
        if let nested = object["box"] as? [String: Any] {
            return made(try rect(nested, at: "\(place) box"), with { $0.order = .xywh })
        }
        if let normalized = object["normalized"] as? [String: Any] {
            return made(try rect(normalized, at: "\(place) normalized"),
                        with { $0.order = .xywh; $0.units = .normalized })
        }
        for keys in [["x1", "y1", "x2", "y2"], ["xmin", "ymin", "xmax", "ymax"],
                     ["x_min", "y_min", "x_max", "y_max"]] where object[keys[0]] != nil {
            return made(try named(object, keys, at: place), with { $0.order = .xyxy })
        }
        if object["x"] != nil || object["width"] != nil || object["w"] != nil {
            return made(try rect(object, at: place), with { $0.order = .xywh })
        }
        throw BoxImportError(message: "\(place): no geometry — give x,y,width,height, or one of "
            + "\"box\", \"normalized\", \"coordinates\", \"xyxy\", \"bbox\", \"box_2d\", \"bbox_2d\"")
    }

    // MARK: - Numbers

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue
    }

    private static func four(_ values: [Any], at place: String) throws -> (Double, Double, Double, Double) {
        let numbers = values.compactMap(number)
        guard values.count == 4, numbers.count == 4 else {
            throw BoxImportError(message: "\(place): expected four numbers")
        }
        return (numbers[0], numbers[1], numbers[2], numbers[3])
    }

    private static func named(_ object: [String: Any], _ keys: [String],
                              at place: String) throws -> (Double, Double, Double, Double) {
        let numbers = try keys.map { key -> Double in
            guard let value = number(object[key]) else {
                throw BoxImportError(message: "\(place): \"\(key)\" must be a number")
            }
            return value
        }
        return (numbers[0], numbers[1], numbers[2], numbers[3])
    }

    /// `x, y, width, height`, accepting `w`/`h` for the last two.
    private static func rect(_ object: [String: Any], at place: String) throws -> (Double, Double, Double, Double) {
        let widthKey = object["width"] == nil && object["w"] != nil ? "w" : "width"
        let heightKey = object["height"] == nil && object["h"] != nil ? "h" : "height"
        return try named(object, ["x", "y", widthKey, heightKey], at: place)
    }
}
