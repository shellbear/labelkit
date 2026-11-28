import Foundation

/// Canonical Create ML JSON serializer. Hand-rolled instead of `JSONEncoder`
/// so saved files are byte-stable and git-diff friendly:
/// - fixed key order: `image`, `annotations`, extras (alphabetical);
///   annotation: `label`, `coordinates`, extras; coordinates: `x,y,width,height`
/// - numbers rounded to 2 decimal places, trailing zeros stripped (`450.28`,
///   `427.5`, `800`)
/// - indentation follows the loaded file's own unit (see JSONIndent);
///   defaults to 2 spaces for fresh files
/// - trailing newline
public enum CreateMLWriter {
    public static let defaultIndentUnit = "  "

    public static func serialize(
        _ records: [ImageAnnotationRecord],
        indentUnit: String = defaultIndentUnit
    ) -> Data {
        var out = String()
        out.reserveCapacity(records.count * 256)
        // The writer asks for the same six indentation strings tens of
        // thousands of times; build them once.
        let cached = (0..<8).map { String(repeating: indentUnit, count: $0) }
        let pad = { (depth: Int) in
            depth < cached.count ? cached[depth] : String(repeating: indentUnit, count: depth)
        }

        out.append("[")
        for (index, record) in records.enumerated() {
            out.append(index == 0 ? "\n" : ",\n")
            appendEntry(record, to: &out, pad: pad)
        }
        out.append(records.isEmpty ? "]\n" : "\n]\n")
        return Data(out.utf8)
    }

    /// Canonical number formatting: round half-away-from-zero to 2 dp, then
    /// drop trailing zeros and a dangling decimal point.
    public static func coordString(_ value: Double) -> String {
        // Work in whole hundredths: integer formatting is several times faster
        // than `String(format:)`, and this runs four times per box.
        let scaled = (value * 100).rounded()
        guard scaled.isFinite, abs(scaled) < 1e15 else { return formattedCoordString(value) }
        let hundredths = Int64(scaled)
        let magnitude = hundredths.magnitude
        let fraction = magnitude % 100
        var text = hundredths < 0 ? "-" : ""
        text += String(magnitude / 100)
        if fraction != 0 {
            text += fraction < 10 ? ".0" : "."
            text += String(fraction % 10 == 0 ? fraction / 10 : fraction)
        }
        return text
    }

    /// The reference formatting, used directly only for values too large (or
    /// not finite) for the integer path. `coordString` must agree with it.
    static func formattedCoordString(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded(), abs(rounded) < 1e15 {
            return String(Int(rounded))
        }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    // MARK: - Entries

    private static func appendEntry(
        _ record: ImageAnnotationRecord, to out: inout String, pad: (Int) -> String
    ) {
        out.append("\(pad(1)){\n")
        out.append("\(pad(2))\"image\": \(escape(record.image)),\n")
        out.append("\(pad(2))\"annotations\": [")
        for (index, box) in record.boxes.enumerated() {
            out.append(index == 0 ? "\n" : ",\n")
            appendBox(box, to: &out, pad: pad)
        }
        out.append(record.boxes.isEmpty ? "]" : "\n\(pad(2))]")
        for (key, value) in record.extras.sorted(by: { $0.key < $1.key }) {
            out.append(",\n\(pad(2))\(escape(key)): \(encode(value, depth: 2, pad: pad))")
        }
        out.append("\n\(pad(1))}")
    }

    private static func appendBox(_ box: BoxRecord, to out: inout String, pad: (Int) -> String) {
        out.append("\(pad(3)){\n")
        out.append("\(pad(4))\"label\": \(escape(box.label)),\n")
        out.append("\(pad(4))\"coordinates\": {\n")
        out.append("\(pad(5))\"x\": \(coordString(box.x)),\n")
        out.append("\(pad(5))\"y\": \(coordString(box.y)),\n")
        out.append("\(pad(5))\"width\": \(coordString(box.width)),\n")
        out.append("\(pad(5))\"height\": \(coordString(box.height))\n")
        out.append("\(pad(4))}")
        for (key, value) in box.extras.sorted(by: { $0.key < $1.key }) {
            out.append(",\n\(pad(4))\(escape(key)): \(encode(value, depth: 4, pad: pad))")
        }
        out.append("\n\(pad(3))}")
    }

    // MARK: - Generic JSON encoding (extras)

    private static func encode(_ value: JSONValue, depth: Int, pad: (Int) -> String) -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number): return coordString(number)
        case .string(let string): return escape(string)
        case .array(let items):
            if items.isEmpty { return "[]" }
            let inner = items
                .map { "\(pad(depth + 1))\(encode($0, depth: depth + 1, pad: pad))" }
                .joined(separator: ",\n")
            return "[\n\(inner)\n\(pad(depth))]"
        case .object(let dict):
            if dict.isEmpty { return "{}" }
            let inner = dict.sorted(by: { $0.key < $1.key })
                .map { "\(pad(depth + 1))\(escape($0.key)): \(encode($0.value, depth: depth + 1, pad: pad))" }
                .joined(separator: ",\n")
            return "{\n\(inner)\n\(pad(depth))}"
        }
    }

    private static func escape(_ string: String) -> String {
        // Nearly every label and filename needs no escaping at all.
        if !string.utf8.contains(where: { $0 < 0x20 || $0 == UInt8(ascii: "\"") || $0 == UInt8(ascii: "\\") }) {
            return "\"\(string)\""
        }
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            case let s where s.value < 0x20:
                out.append(String(format: "\\u%04x", s.value))
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out.append("\"")
        return out
    }
}
