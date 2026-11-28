import Foundation

/// Copies dropped images into a dataset directory, resolving name collisions so
/// an existing file is never overwritten. Pure/static — the only state is the
/// filesystem, which keeps it headlessly testable in a temp dir.
public enum ImageImporter {
    /// One planned copy: where it comes from and the collision-free filename it
    /// takes in the dataset directory. `needsCopy` is false when an identical
    /// file (same name, same byte size) is already there — a re-drag, or a
    /// source that already lives in the dataset folder.
    public struct Item: Equatable, Sendable {
        public let source: URL
        public let finalName: String
        public let needsCopy: Bool
    }

    public static func isImageFile(_ url: URL) -> Bool {
        ImageDirectoryScanner.imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Split a raw drop into importable image files and dropped folders. Loose
    /// non-image files are ignored; a dropped folder contributes its images
    /// (one level, via `ImageDirectoryScanner`) to `images` AND is listed in
    /// `folders` so the caller can fall back to opening it as a dataset when it
    /// holds no images.
    public static func expand(_ urls: [URL]) -> (images: [URL], folders: [URL]) {
        let fm = FileManager.default
        var images: [URL] = []
        var folders: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                folders.append(url)
                for name in ImageDirectoryScanner.scan(directory: url) {
                    images.append(url.appendingPathComponent(name))
                }
            } else if isImageFile(url) {
                images.append(url)
            }
        }
        return (images, folders)
    }

    /// Resolve a collision-free destination filename for every source.
    /// `reservedNames` are filenames already claimed by the dataset's entries
    /// (including ghost entries whose file is missing) — merged with the
    /// directory's actual contents so nothing on disk is clobbered either.
    ///
    /// `names` gives each source the filename it should take, when that isn't
    /// the last component of its URL — a file reached through a symlink keeps
    /// the link's name, not the name of whatever it pointed to.
    public static func plan(sources: [URL], into directory: URL,
                            reservedNames: Set<String>, names: [String]? = nil) -> [Item] {
        let fm = FileManager.default
        var claimed = reservedNames
        if let onDisk = try? fm.contentsOfDirectory(atPath: directory.path) {
            claimed.formUnion(onDisk)
        }

        var items: [Item] = []
        for (index, source) in sources.enumerated() {
            let name = names?[index] ?? source.lastPathComponent
            let destination = directory.appendingPathComponent(name)
            // Same name + same byte size already there → treat as the same
            // image: no copy, just surface it (parent-folder case, re-drag).
            if fm.fileExists(atPath: destination.path), sameSize(source, destination, fm) {
                items.append(Item(source: source, finalName: name, needsCopy: false))
                continue
            }
            let finalName = freeName(for: name, claimed: claimed, in: directory, fm: fm)
            claimed.insert(finalName)
            items.append(Item(source: source, finalName: finalName, needsCopy: true))
        }
        return items
    }

    /// Perform the planned copies; returns every `finalName` in input order so
    /// the caller can focus the last one (copied or already present).
    @discardableResult
    public static func execute(_ items: [Item], into directory: URL) throws -> [String] {
        let fm = FileManager.default
        for item in items where item.needsCopy {
            try fm.copyItem(at: item.source, to: directory.appendingPathComponent(item.finalName))
        }
        return items.map(\.finalName)
    }

    // MARK: - Helpers

    /// `IMG.jpg` → `IMG-2.jpg`, `IMG-3.jpg`, … until nothing claims it.
    private static func freeName(for name: String, claimed: Set<String>,
                                 in directory: URL, fm: FileManager) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var counter = 2
        while claimed.contains(candidate)
            || fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    private static func sameSize(_ a: URL, _ b: URL, _ fm: FileManager) -> Bool {
        let sizeA = (try? fm.attributesOfItem(atPath: a.path)[.size]) as? Int
        let sizeB = (try? fm.attributesOfItem(atPath: b.path)[.size]) as? Int
        return sizeA != nil && sizeA == sizeB
    }
}
