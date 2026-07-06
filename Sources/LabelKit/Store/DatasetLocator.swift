import Foundation

/// Where a dataset lives: the images directory + its annotations file.
public struct DatasetLocation: Equatable, Sendable {
    public let imagesDirectory: URL
    public let annotationsURL: URL
    /// False when starting fresh — the file is created on first save.
    public let annotationsExists: Bool

    public var displayName: String { imagesDirectory.lastPathComponent }

    public init(imagesDirectory: URL, annotationsURL: URL, annotationsExists: Bool) {
        self.imagesDirectory = imagesDirectory
        self.annotationsURL = annotationsURL
        self.annotationsExists = annotationsExists
    }
}

public enum DatasetLocatorError: LocalizedError, Equatable {
    case pathNotFound(String)
    case notADirectoryOrJSON(String)

    public var errorDescription: String? {
        switch self {
        case .pathNotFound(let path):
            return "no such file or directory: \(path)"
        case .notADirectoryOrJSON(let path):
            return "expected a directory or a .json file: \(path)"
        }
    }
}

/// Pure path auto-detection for the CLI:
/// - directory → `<dir>/annotations.json` (whether or not it exists yet)
/// - `.json` file → that file; images resolved relative to its directory
/// - nil → nil (the app shows an open panel)
/// - `annotationsOverride` wins over auto-detection when provided
public enum DatasetLocator {
    public static func resolve(path: String?, annotationsOverride: String? = nil) throws -> DatasetLocation? {
        guard let path else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw DatasetLocatorError.pathNotFound(path)
        }

        if isDirectory.boolValue {
            let annotationsURL = try annotationsOverride.map(expandedExistingFile)
                ?? url.appendingPathComponent("annotations.json")
            return DatasetLocation(
                imagesDirectory: url,
                annotationsURL: annotationsURL,
                annotationsExists: FileManager.default.fileExists(atPath: annotationsURL.path)
            )
        }

        guard url.pathExtension.lowercased() == "json" else {
            throw DatasetLocatorError.notADirectoryOrJSON(path)
        }
        return DatasetLocation(
            imagesDirectory: url.deletingLastPathComponent(),
            annotationsURL: url,
            annotationsExists: true
        )
    }

    private static func expandedExistingFile(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        // The override may not exist yet (created on first save) — no check.
        return url
    }
}
