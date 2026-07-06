import Foundation

/// Canonical Create ML JSON serializer. Hand-rolled instead of `JSONEncoder`
/// so saved files are byte-stable and git-diff friendly:
/// - fixed key order: `image`, `annotations`, extras (alphabetical);
///   annotation: `label`, `coordinates`, extras; coordinates: `x,y,width,height`
/// - numbers rounded to 2 decimal places, trailing zeros stripped (`450.28`,
///   `427.5`, `800`)
/// - 2-space indent, trailing newline
public enum CreateMLWriter {
    public static func serialize(_ records: [ImageAnnotationRecord]) -> Data {
        var out = String()
        out.reserveCapacity(records.count * 256)
        out.append("[")
        for (index, record) in records.enumerated() {
            out.append(index == 0 ? "\n" : ",\n")
            appendEntry(record, to: &out)
        }
        out.append(records.isEmpty ? "]\n" : "\n]\n")
        return Data(out.utf8)
    }

    /// Canonical number formatting: round half-away-from-zero to 2 dp, then
    /// drop trailing zeros and a dangling decimal point.
    public static func coordString(_ value: Double) -> String {
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

    private static func appendEntry(_ record: ImageAnnotationRecord, to out: inout String) {
        out.append("  {\n")
        out.append("    \"image\": \(escape(record.image)),\n")
        out.append("    \"annotations\": [")
        for (index, box) in record.boxes.enumerated() {
            out.append(index == 0 ? "\n" : ",\n")
            appendBox(box, to: &out)
        }
        out.append(record.boxes.isEmpty ? "]" : "\n    ]")
        for (key, value) in record.extras.sorted(by: { $0.key < $1.key }) {
            out.append(",\n    \(escape(key)): \(encode(value, indent: 4))")
        }
        out.append("\n  }")
    }

    private static func appendBox(_ box: BoxRecord, to out: inout String) {
        out.append("      {\n")
        out.append("        \"label\": \(escape(box.label)),\n")
        out.append("        \"coordinates\": {\n")
        out.append("          \"x\": \(coordString(box.x)),\n")
        out.append("          \"y\": \(coordString(box.y)),\n")
        out.append("          \"width\": \(coordString(box.width)),\n")
        out.append("          \"height\": \(coordString(box.height))\n")
        out.append("        }")
        for (key, value) in box.extras.sorted(by: { $0.key < $1.key }) {
            out.append(",\n        \(escape(key)): \(encode(value, indent: 8))")
        }
        out.append("\n      }")
    }

    // MARK: - Generic JSON encoding (extras)

    private static func encode(_ value: JSONValue, indent: Int) -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number): return coordString(number)
        case .string(let string): return escape(string)
        case .array(let items):
            if items.isEmpty { return "[]" }
            let pad = String(repeating: " ", count: indent)
            let inner = items
                .map { "\(pad)  \(encode($0, indent: indent + 2))" }
                .joined(separator: ",\n")
            return "[\n\(inner)\n\(pad)]"
        case .object(let dict):
            if dict.isEmpty { return "{}" }
            let pad = String(repeating: " ", count: indent)
            let inner = dict.sorted(by: { $0.key < $1.key })
                .map { "\(pad)  \(escape($0.key)): \(encode($0.value, indent: indent + 2))" }
                .joined(separator: ",\n")
            return "{\n\(inner)\n\(pad)}"
        }
    }

    private static func escape(_ string: String) -> String {
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
