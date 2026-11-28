import Foundation

/// Lists image filenames in a directory — without stat-ing or decoding
/// anything, so a 10k-image folder scans in tens of milliseconds.
public enum ImageDirectoryScanner {
    public static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp"]

    /// Image files directly inside `directory` (hidden files and
    /// subdirectories' contents excluded), in Finder's name order.
    public static func scan(directory: URL, glob: String? = nil) -> [String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        var names: [String] = []
        names.reserveCapacity(urls.count)
        for url in urls {
            let name = url.lastPathComponent
            guard imageExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            if let glob, fnmatch(glob, name, 0) != 0 { continue }
            names.append(name)
        }

        // The sort dominates a large scan. Sorting by selector keeps every
        // comparison inside Foundation, on the NSStrings the listing produced —
        // measured at half the cost of a Swift closure, which bridges both
        // sides each time.
        var sorted = (names as NSArray)
            .sortedArray(using: #selector(NSString.localizedStandardCompare(_:))) as! [String]

        // Finder's ordering can call two different names equal. Settle those by
        // plain comparison so the result never depends on the sort's internals.
        var start = 0
        while start < sorted.count {
            var end = start + 1
            while end < sorted.count, sorted[start].localizedStandardCompare(sorted[end]) == .orderedSame {
                end += 1
            }
            if end - start > 1 { sorted[start..<end].sort() }
            start = end
        }
        return sorted.map(\.native)
    }
}
