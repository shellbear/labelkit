import Foundation

/// Most-recently-opened datasets, persisted in UserDefaults. Newest first,
/// deduplicated by location, capped at `maxCount` — feeds File ▸ Open Recent
/// and the welcome screen.
public struct RecentProjects {
    public static let maxCount = 5
    private static let defaultsKey = "recentProjects"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `annotationsExists` is recomputed at read time — the file may have
    /// been created (first save) or deleted since the entry was recorded.
    public var locations: [DatasetLocation] {
        entries.map { entry in
            DatasetLocation(
                imagesDirectory: URL(fileURLWithPath: entry.imagesDirectory),
                annotationsURL: URL(fileURLWithPath: entry.annotationsURL),
                annotationsExists: FileManager.default.fileExists(atPath: entry.annotationsURL)
            )
        }
    }

    public func record(_ location: DatasetLocation) {
        let entry = (imagesDirectory: location.imagesDirectory.path,
                     annotationsURL: location.annotationsURL.path)
        var updated = entries.filter { $0 != entry }
        updated.insert(entry, at: 0)
        defaults.set(
            updated.prefix(Self.maxCount).map {
                ["imagesDirectory": $0.imagesDirectory, "annotationsURL": $0.annotationsURL]
            },
            forKey: Self.defaultsKey)
    }

    /// Drop a single dataset from the list (the welcome-screen ✕). Matched on
    /// the same identity `record` dedupes by — images dir + annotations path.
    public func remove(_ location: DatasetLocation) {
        let entry = (imagesDirectory: location.imagesDirectory.path,
                     annotationsURL: location.annotationsURL.path)
        let updated = entries.filter { $0 != entry }
        defaults.set(
            updated.map {
                ["imagesDirectory": $0.imagesDirectory, "annotationsURL": $0.annotationsURL]
            },
            forKey: Self.defaultsKey)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private var entries: [(imagesDirectory: String, annotationsURL: String)] {
        let raw = defaults.array(forKey: Self.defaultsKey) as? [[String: String]] ?? []
        return raw.compactMap { entry in
            guard let directory = entry["imagesDirectory"],
                  let annotations = entry["annotationsURL"] else { return nil }
            return (directory, annotations)
        }
    }
}
