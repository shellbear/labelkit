import Foundation

public extension Array {
    /// `map`, spread across cores, results in the original order. For work
    /// that is independent per element and heavy enough to be worth a thread
    /// hop — reading a file header, hashing a file, rendering an image — not
    /// for arithmetic.
    ///
    /// Blocks until every element is done (`DispatchQueue.concurrentPerform`
    /// sizes itself to the machine), which is what a command-line run wants.
    ///
    /// - Parameter maxConcurrency: at most this many elements are worked on at
    ///   once. Use it when each element holds a lot of memory while in flight
    ///   (a decoded photo), so the peak is bounded by this rather than by the
    ///   core count. Defaults to no limit beyond the machine's cores.
    func concurrentMap<Result>(maxConcurrency: Int? = nil, _ transform: (Element) -> Result) -> [Result] {
        let workers = Swift.min(count, Swift.max(1, maxConcurrency ?? count))
        guard workers > 1 else { return map(transform) }
        return [Result](unsafeUninitializedCapacity: count) { buffer, initialized in
            // Worker w takes elements w, w + workers, w + 2·workers, … so every
            // slot is initialized exactly once and there is no shared mutable
            // state to guard.
            let slots = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                for index in stride(from: worker, to: count, by: workers) {
                    // Drain per element: Foundation and ImageIO autorelease
                    // their temporaries, and a worker thread would otherwise
                    // hold every image it has processed until it finishes.
                    autoreleasepool {
                        (slots + index).initialize(to: transform(self[index]))
                    }
                }
            }
            initialized = count
        }
    }
}

public extension Sequence where Element: Hashable {
    /// The elements with later repeats dropped, order kept.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

extension String {
    /// The same string in Swift's own storage. Strings that arrive from
    /// Foundation (`JSONSerialization`, `FileManager`) are bridged `NSString`s,
    /// and every hash or comparison on one crosses into Objective-C — measured
    /// at several times the cost of a native string. Filenames and labels are
    /// used as dictionary keys throughout, so they are converted once, on the
    /// way in.
    var native: String {
        var copy = self
        copy.makeContiguousUTF8()
        return copy
    }
}
