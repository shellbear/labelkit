import Foundation

/// Lossless JSON scalar/tree used to carry keys labelkit does not model
/// (e.g. `imageWidth` on a dataset entry) through a load → edit → save cycle.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Bridge from `JSONSerialization` output.
    public init(_ any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // NSNumber hides booleans; CFBoolean is the reliable discriminator.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init))
        case let dict as [String: Any]:
            self = .object(dict.mapValues(JSONValue.init))
        default:
            self = .null
        }
    }
}
