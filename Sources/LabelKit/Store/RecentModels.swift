import Foundation

/// Most-recently-used custom Core ML models, persisted in UserDefaults. Newest
/// first, deduplicated by path, capped at `maxCount`, and filtered to files
/// that still exist — so the Detect menu never lists a model that was moved or
/// deleted. Mirrors `RecentProjects`.
public struct RecentModels {
    public static let maxCount = 5
    private static let defaultsKey = "recentModels"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var urls: [URL] {
        paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    public func record(_ url: URL) {
        var updated = paths.filter { $0 != url.path }
        updated.insert(url.path, at: 0)
        defaults.set(Array(updated.prefix(Self.maxCount)), forKey: Self.defaultsKey)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private var paths: [String] {
        defaults.array(forKey: Self.defaultsKey) as? [String] ?? []
    }
}
