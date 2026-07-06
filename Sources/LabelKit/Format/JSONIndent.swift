import Foundation

/// Sniffs the indentation unit of an existing JSON file so saves follow the
/// file's own convention (Python's `indent=1`, tabs, 4-space, …) instead of
/// forcing a whole-file reformat on first save.
public enum JSONIndent {
    /// The leading whitespace of the first indented line — which, for a
    /// Create ML file (entries at depth 1), IS one indent unit. Returns nil
    /// for compact/single-line JSON.
    public static func detectUnit(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let whitespace = line.prefix { $0 == " " || $0 == "\t" }
            if !whitespace.isEmpty, whitespace.count < line.count {
                return String(whitespace)
            }
        }
        return nil
    }
}
