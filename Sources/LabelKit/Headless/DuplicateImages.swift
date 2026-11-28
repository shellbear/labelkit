import CryptoKit
import Foundation

/// Finds image files with byte-identical contents under different names — the
/// same photo saved twice. In a training set these are worse than wasted
/// space: the copies can carry different boxes, and one can land on each side
/// of a train/validation split.
///
/// Built to cost almost nothing when there are no duplicates: files are
/// grouped by size first (one `stat` each), and only files that share a size
/// with another are read and hashed, in parallel.
public enum DuplicateImages {
    /// Groups of two or more filenames whose files are identical, each group in
    /// the order the names were given; groups ordered by their first member.
    public static func groups(in directory: URL, filenames: [String]) -> [[String]] {
        /// A file on disk, whatever name reached it. Several names can be one
        /// file (symlinks, hard links); those are trivially identical and are
        /// read once.
        struct FileID: Hashable { var device: dev_t; var inode: ino_t }
        struct Candidate { var index: Int; var file: FileID }

        // `stat` follows symlinks and gives size and identity in one call.
        let base = directory.path
        var bySize: [off_t: [Candidate]] = [:]
        for (index, name) in filenames.enumerated() {
            var info = stat()
            guard stat(base + "/" + name, &info) == 0 else { continue }
            bySize[info.st_size, default: []].append(
                Candidate(index: index, file: FileID(device: info.st_dev, inode: info.st_ino)))
        }

        // Only files sharing a size can be identical, so only those are read.
        let suspects = bySize.values.filter { $0.count > 1 }.flatMap { $0 }
        guard !suspects.isEmpty else { return [] }
        var representative: [FileID: Int] = [:]
        for candidate in suspects where representative[candidate.file] == nil {
            representative[candidate.file] = candidate.index
        }
        let files = Array(representative.keys)
        let digests = files.concurrentMap { file -> SHA256.Digest? in
            let url = URL(fileURLWithPath: base + "/" + filenames[representative[file]!])
            return (try? Data(contentsOf: url, options: .mappedIfSafe)).map(SHA256.hash(data:))
        }
        var digestByFile: [FileID: SHA256.Digest] = [:]
        for (file, digest) in zip(files, digests) {
            if let digest { digestByFile[file] = digest }
        }

        var byContent: [SHA256.Digest: [Int]] = [:]
        for candidate in suspects {
            guard let digest = digestByFile[candidate.file] else { continue }
            byContent[digest, default: []].append(candidate.index)
        }
        return byContent.values
            .filter { $0.count > 1 }
            .map { $0.sorted() }
            .sorted { $0[0] < $1[0] }
            .map { $0.map { filenames[$0] } }
    }
}
