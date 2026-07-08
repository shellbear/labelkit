import CoreML
import CryptoKit
import Foundation

/// Resolves a loadable `.mlmodelc` URL for a model on disk, compiling once and
/// caching the result so a given model isn't recompiled on every launch.
enum CompiledModelCache {
    /// Pass an already-compiled `.mlmodelc` through untouched. Otherwise compile
    /// `modelURL` and cache the `.mlmodelc` in Application Support, keyed by the
    /// source's path + mtime + size — a later launch (or a re-pick of the same
    /// model) reuses it. The cache is best-effort: any filesystem failure falls
    /// back to Core ML's fresh temporary compile, which still loads fine.
    static func compiledURL(for modelURL: URL) throws -> URL {
        if modelURL.pathExtension == "mlmodelc" { return modelURL }

        let fm = FileManager.default
        let destination = cacheURL(for: modelURL, fm: fm)
        if let destination, fm.fileExists(atPath: destination.path) { return destination }

        let compiled = try MLModel.compileModel(at: modelURL)
        guard let destination else { return compiled }
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: compiled, to: destination)
            return destination
        } catch {
            return compiled  // caching is an optimization, not a requirement
        }
    }

    private static func cacheURL(for modelURL: URL, fm: FileManager) -> URL? {
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let attrs = try? fm.attributesOfItem(atPath: modelURL.path) else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? Int) ?? 0
        let digest = SHA256.hash(data: Data("\(modelURL.path)|\(mtime)|\(size)".utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        let base = modelURL.deletingPathExtension().lastPathComponent
        return support
            .appendingPathComponent("labelkit/CompiledModels", isDirectory: true)
            .appendingPathComponent("\(base)-\(key).mlmodelc", isDirectory: true)
    }
}
