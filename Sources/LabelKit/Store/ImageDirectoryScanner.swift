import Foundation

/// Lists image filenames in a directory — lazily, without stat-ing or
/// decoding anything, so a 10k-image folder scans in tens of milliseconds.
public enum ImageDirectoryScanner {
    public static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp"]

    public static func scan(directory: URL, glob: String? = nil) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
        ) else { return [] }

        var names: [String] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
            if let glob, fnmatch(glob, name, 0) != 0 { continue }
            names.append(name)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
