import Foundation

/// Ordered, unique label names. Position is stable and drives both the
/// per-label color and the 1-9 digit shortcuts.
public struct LabelRegistry: Equatable, Sendable {
    public private(set) var ordered: [String]

    public init(_ labels: [String] = []) {
        ordered = []
        labels.forEach { register($0) }
    }

    /// Appends if unseen; returns the label's stable index either way.
    @discardableResult
    public mutating func register(_ label: String) -> Int {
        if let index = ordered.firstIndex(of: label) { return index }
        ordered.append(label)
        return ordered.count - 1
    }

    public func index(of label: String) -> Int? {
        ordered.firstIndex(of: label)
    }
}
