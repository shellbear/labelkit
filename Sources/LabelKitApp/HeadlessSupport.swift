import ArgumentParser
import Foundation
import LabelKit

/// Shared plumbing for the scripted subcommands (`stats`, `validate`,
/// `annotate`, `render`). They follow one contract, the same one `detect`
/// established, so a script or an agent only has to learn it once:
///
/// - stdout carries the result and nothing else; notes go to stderr.
/// - Exit 0 on success, 1 when the command ran but found or hit a problem
///   (the JSON on stdout says what), 64 for a usage error.
/// - Never touches AppKit.
enum Headless {
    enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
        case json, text
    }

    /// Open a dataset for scripted work, turning "not a dataset" into a usage
    /// error (exit 64) rather than a crash-style failure.
    static func openDocument(path: String, annotations: String?,
                             onlyImages: [String]? = nil) throws -> DatasetDocument {
        do {
            guard let location = try DatasetLocator.resolve(path: path, annotationsOverride: annotations) else {
                throw ValidationError("Specify a dataset directory or an annotations .json file.")
            }
            return try DatasetDocument(location: location, onlyImages: onlyImages)
        } catch let error as ValidationError {
            throw error
        } catch {
            throw ValidationError(describe(error))
        }
    }

    /// Stable JSON for stdout: sorted keys, so two runs diff cleanly. Compact
    /// (`pretty: false`) is one line, for NDJSON.
    static func json<T: Encodable>(_ value: T, pretty: Bool = true) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func printJSON<T: Encodable>(_ value: T) {
        print(json(value))
    }

    static func note(_ message: String) {
        FileHandle.standardError.write(Data("labelkit: \(message)\n".utf8))
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

extension String {
    /// Left-justify to `width` for aligned text output (never truncates).
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }

    /// Right-justify to `width` (never truncates).
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
