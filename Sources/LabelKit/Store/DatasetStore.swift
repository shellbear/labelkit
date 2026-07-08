import CoreGraphics
import Foundation
import Observation

/// Root model of an open dataset. All box mutations flow through here so
/// dirty tracking and undo registration live in exactly one place.
@Observable
@MainActor
public final class DatasetStore {
    public let location: DatasetLocation

    /// Sidebar order: images on disk (name-sorted), then entries whose image
    /// file is missing (kept so datasets never silently shrink).
    public private(set) var entries: [ImageEntry] = []
    public private(set) var labels: LabelRegistry
    public private(set) var isDirty = false
    /// Bumped on structural changes to `entries` (import). The AppKit sidebar
    /// caches its row count, so it reloads when this changes; box edits, which
    /// don't grow the list, deliberately leave it untouched.
    public private(set) var entriesRevision = 0

    /// Entry order of the annotations file at load time — save preserves it
    /// and appends newly annotated images, keeping git diffs minimal.
    private var savedOrder: [String]
    private var indexByFilename: [String: Int] = [:]
    /// Precomputed image URLs. `URL.appendingPathComponent` is surprisingly
    /// costly (path normalization) and the sidebar asked for one per row on
    /// every List diff — a profiler trace put it at the top of our main-thread
    /// scrub cost. Build them once at load; lookups are then just a hash.
    private var urlCache: [String: URL] = [:]
    /// Memoized label→count over all boxes. Rebuilt lazily; invalidated only
    /// when box membership or a box label changes (NOT on geometry edits), so
    /// the inspector's per-render `labelUsage()` stays O(1) even mid-drag.
    private var cachedLabelUsage: [String: Int]?
    /// Indentation unit sniffed from the loaded file (Python's 1-space, tabs,
    /// …) so saves follow the dataset's own convention — no reformat diffs.
    private let indentUnit: String

    // MARK: - Load

    public init(location: DatasetLocation, imageGlob: String? = nil) throws {
        self.location = location

        var records: [ImageAnnotationRecord] = []
        var detectedIndent: String?
        if location.annotationsExists {
            let data = try Data(contentsOf: location.annotationsURL)
            records = try CreateMLFormat.load(data)
            detectedIndent = JSONIndent.detectUnit(in: data)
        }
        indentUnit = detectedIndent ?? CreateMLWriter.defaultIndentUnit
        savedOrder = records.map(\.image)

        let onDisk = ImageDirectoryScanner.scan(directory: location.imagesDirectory, glob: imageGlob)
        let recordByFilename = Dictionary(records.map { ($0.image, $0) }, uniquingKeysWith: { first, _ in first })
        let onDiskSet = Set(onDisk)

        var registry = LabelRegistry()
        var loaded: [ImageEntry] = []
        loaded.reserveCapacity(onDisk.count)

        for filename in onDisk {
            if let record = recordByFilename[filename] {
                let boxes = record.boxes.map(BoundingBox.init(record:))
                boxes.forEach { registry.register($0.label) }
                loaded.append(ImageEntry(
                    filename: filename, boxes: boxes,
                    hasEntryInFile: true, extras: record.extras
                ))
            } else {
                loaded.append(ImageEntry(filename: filename))
            }
        }
        // Records whose image file is gone: keep, flag, save back untouched.
        for record in records where !onDiskSet.contains(record.image) {
            let boxes = record.boxes.map(BoundingBox.init(record:))
            boxes.forEach { registry.register($0.label) }
            loaded.append(ImageEntry(
                filename: record.image, boxes: boxes,
                hasEntryInFile: true, extras: record.extras, imageFileMissing: true
            ))
        }

        entries = loaded
        labels = registry
        indexByFilename = Dictionary(
            uniqueKeysWithValues: loaded.enumerated().map { ($0.element.filename, $0.offset) })
        let imagesDirectory = location.imagesDirectory
        urlCache = Dictionary(
            uniqueKeysWithValues: loaded.map {
                ($0.filename, imagesDirectory.appendingPathComponent($0.filename))
            })
    }

    public func entry(for filename: String) -> ImageEntry? {
        indexByFilename[filename].map { entries[$0] }
    }

    /// Position of `filename` in `entries`, for O(1) neighbor navigation.
    public func index(of filename: String) -> Int? {
        indexByFilename[filename]
    }

    public func imageURL(for entry: ImageEntry) -> URL {
        if let cached = urlCache[entry.filename] { return cached }
        let url = location.imagesDirectory.appendingPathComponent(entry.filename)
        urlCache[entry.filename] = url
        return url
    }

    // MARK: - Import

    /// Append entries for freshly copied-in images. Newcomers land at the end
    /// of the sidebar (after on-disk + missing-ghost rows); a later reopen
    /// re-sorts them into name order via the scanner. Names already known are
    /// skipped, so passing an already-present duplicate is a safe no-op.
    ///
    /// The file copy IS the persistence — an imported image carries no boxes
    /// yet, so like any untouched on-disk image it gets no annotations entry
    /// until boxed. Import therefore does NOT dirty the store.
    @discardableResult
    public func registerImported(_ filenames: [String]) -> [String] {
        let directory = location.imagesDirectory
        var added: [String] = []
        for filename in filenames where indexByFilename[filename] == nil {
            entries.append(ImageEntry(filename: filename))
            indexByFilename[filename] = entries.count - 1
            urlCache[filename] = directory.appendingPathComponent(filename)
            added.append(filename)
        }
        if !added.isEmpty { entriesRevision += 1 }
        return added
    }

    // MARK: - Mutations (all undoable, all dirtying)

    public func addBox(_ box: BoundingBox, to entry: ImageEntry, undoManager: UndoManager?) {
        entry.boxes.append(box)
        labels.register(box.label)
        cachedLabelUsage = nil
        markDirty()
        undoManager?.registerUndo(withTarget: self) { store in
            store.removeBox(id: box.id, from: entry, undoManager: undoManager)
        }
        undoManager?.setActionName("Add Box")
    }

    public func removeBox(id: BoundingBox.ID, from entry: ImageEntry, undoManager: UndoManager?) {
        guard let index = entry.boxes.firstIndex(where: { $0.id == id }) else { return }
        let removed = entry.boxes.remove(at: index)
        cachedLabelUsage = nil
        markDirty()
        undoManager?.registerUndo(withTarget: self) { store in
            store.insertBox(removed, at: index, in: entry, undoManager: undoManager)
        }
        undoManager?.setActionName("Delete Box")
    }

    private func insertBox(_ box: BoundingBox, at index: Int, in entry: ImageEntry, undoManager: UndoManager?) {
        entry.boxes.insert(box, at: min(index, entry.boxes.count))
        cachedLabelUsage = nil
        markDirty()
        undoManager?.registerUndo(withTarget: self) { store in
            store.removeBox(id: box.id, from: entry, undoManager: undoManager)
        }
        undoManager?.setActionName("Add Box")
    }

    /// Live-drag path: no undo registration, called per frame.
    public func setBoxRect(id: BoundingBox.ID, in entry: ImageEntry, to rect: CGRect) {
        guard let index = entry.boxes.firstIndex(where: { $0.id == id }) else { return }
        entry.boxes[index].rect = rect
        markDirty()
    }

    /// Gesture-end path: registers ONE undo step for the whole drag.
    public func commitBoxRect(id: BoundingBox.ID, in entry: ImageEntry,
                              from original: CGRect, to final: CGRect,
                              undoManager: UndoManager?) {
        setBoxRect(id: id, in: entry, to: final)
        guard original != final else { return }
        undoManager?.registerUndo(withTarget: self) { store in
            store.commitBoxRect(id: id, in: entry, from: final, to: original, undoManager: undoManager)
        }
        undoManager?.setActionName("Edit Box")
    }

    public func setBoxLabel(id: BoundingBox.ID, in entry: ImageEntry, to label: String,
                            undoManager: UndoManager?) {
        guard let index = entry.boxes.firstIndex(where: { $0.id == id }) else { return }
        let previous = entry.boxes[index].label
        guard previous != label else { return }
        entry.boxes[index].label = label
        labels.register(label)
        cachedLabelUsage = nil
        markDirty()
        undoManager?.registerUndo(withTarget: self) { store in
            store.setBoxLabel(id: id, in: entry, to: previous, undoManager: undoManager)
        }
        undoManager?.setActionName("Change Label")
    }

    /// Session-only: not persisted, so no dirty flag and no undo step.
    public func toggleBoxHidden(id: BoundingBox.ID, in entry: ImageEntry) {
        guard let index = entry.boxes.firstIndex(where: { $0.id == id }) else { return }
        entry.boxes[index].isHidden.toggle()
    }

    public func addLabel(_ label: String) {
        labels.register(label)
    }

    public func labelUsage() -> [String: Int] {
        if let cachedLabelUsage { return cachedLabelUsage }
        var usage: [String: Int] = [:]
        for entry in entries {
            for box in entry.boxes {
                usage[box.label, default: 0] += 1
            }
        }
        cachedLabelUsage = usage
        return usage
    }

    /// Only unused labels can go — the registry is derived from boxes, so a
    /// used label would just reappear on next load anyway.
    @discardableResult
    public func removeLabelIfUnused(_ label: String) -> Bool {
        guard labelUsage()[label, default: 0] == 0 else { return false }
        labels.remove(label)
        return true
    }

    // MARK: - Save

    public func save() throws {
        let records = recordsForSave()
        try CreateMLWriter.serialize(records, indentUnit: indentUnit)
            .write(to: location.annotationsURL, options: .atomic)
        entries.forEach { entry in
            if !entry.boxes.isEmpty { entry.hasEntryInFile = true }
        }
        savedOrder = records.map(\.image)
        isDirty = false
    }

    /// File order preserved for existing entries; newly annotated images
    /// appended in sidebar (name) order. Never-touched images get no entry;
    /// existing entries are never dropped — empty boxes = negative example.
    func recordsForSave() -> [ImageAnnotationRecord] {
        let included = entries.filter { $0.hasEntryInFile || !$0.boxes.isEmpty }
        let byFilename = Dictionary(
            included.map { ($0.filename, $0) }, uniquingKeysWith: { first, _ in first })
        let savedOrderSet = Set(savedOrder)

        var ordered: [ImageEntry] = savedOrder.compactMap { byFilename[$0] }
        ordered += included.filter { !savedOrderSet.contains($0.filename) }

        return ordered.map { entry in
            ImageAnnotationRecord(
                image: entry.filename,
                boxes: entry.boxes.map(\.record),
                extras: entry.extras
            )
        }
    }

    private func markDirty() {
        if !isDirty { isDirty = true }
    }
}
