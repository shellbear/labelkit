import XCTest
@testable import LabelKit

@MainActor
final class DatasetStoreTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("labelkit-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Image files on disk (contents irrelevant to the store).
        for name in ["a.jpg", "b.jpg", "c.jpg", "untouched.jpg"] {
            try Data([0xFF]).write(to: tempDir.appendingPathComponent(name))
        }
        let annotations = """
        [
          {"image": "b.jpg", "annotations": [
            {"label": "card", "coordinates": {"x": 50, "y": 50, "width": 20, "height": 20}}],
           "imageWidth": 100},
          {"image": "a.jpg", "annotations": []},
          {"image": "ghost.jpg", "annotations": [
            {"label": "card", "coordinates": {"x": 5, "y": 5, "width": 2, "height": 2}}]}
        ]
        """
        try Data(annotations.utf8).write(to: tempDir.appendingPathComponent("annotations.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func makeStore() throws -> DatasetStore {
        let location = try XCTUnwrap(DatasetLocator.resolve(path: tempDir.path))
        return try DatasetStore(location: location)
    }

    func reloadRecords() throws -> [ImageAnnotationRecord] {
        try CreateMLFormat.load(Data(contentsOf: tempDir.appendingPathComponent("annotations.json")))
    }

    // MARK: - Load

    func testLoadMergesDiskAndFileIncludingMissingImage() throws {
        let store = try makeStore()
        // Disk order (name-sorted) first, then the file-only ghost entry.
        XCTAssertEqual(store.entries.map(\.filename), ["a.jpg", "b.jpg", "c.jpg", "untouched.jpg", "ghost.jpg"])
        XCTAssertEqual(store.entry(for: "b.jpg")?.boxes.count, 1)
        XCTAssertEqual(store.entry(for: "b.jpg")?.extras["imageWidth"], .number(100))
        XCTAssertTrue(store.entry(for: "a.jpg")!.hasEntryInFile)   // negative, tracked
        XCTAssertFalse(store.entry(for: "c.jpg")!.hasEntryInFile)  // never annotated
        XCTAssertTrue(store.entry(for: "ghost.jpg")!.imageFileMissing)
        // Center 50,50 size 20 → top-left 40,40.
        XCTAssertEqual(store.entry(for: "b.jpg")!.boxes[0].rect, CGRect(x: 40, y: 40, width: 20, height: 20))
        XCTAssertEqual(store.labels.ordered, ["card"])
        XCTAssertFalse(store.isDirty)
    }

    // MARK: - Save semantics

    func testSavePreservesOrderNegativesGhostsAndAppendsNew() throws {
        let store = try makeStore()
        let entry = try XCTUnwrap(store.entry(for: "c.jpg"))
        store.addBox(BoundingBox(label: "card", rect: CGRect(x: 10, y: 10, width: 5, height: 5)),
                     to: entry, undoManager: nil)
        XCTAssertTrue(store.isDirty)
        try store.save()
        XCTAssertFalse(store.isDirty)

        let records = try reloadRecords()
        // File order preserved (b, a, ghost) + new entry (c) appended.
        XCTAssertEqual(records.map(\.image), ["b.jpg", "a.jpg", "ghost.jpg", "c.jpg"])
        XCTAssertTrue(records[1].boxes.isEmpty)              // negative survived
        XCTAssertEqual(records[2].boxes.count, 1)            // ghost survived
        XCTAssertEqual(records[0].extras["imageWidth"], .number(100))  // extras survived
        // untouched.jpg gained no entry.
        XCTAssertFalse(records.contains { $0.image == "untouched.jpg" })
    }

    func testDeletingLastBoxMakesEntryANegativeNotAHole() throws {
        let store = try makeStore()
        let entry = try XCTUnwrap(store.entry(for: "b.jpg"))
        store.removeBox(id: entry.boxes[0].id, from: entry, undoManager: nil)
        try store.save()

        let records = try reloadRecords()
        let saved = try XCTUnwrap(records.first { $0.image == "b.jpg" })
        XCTAssertTrue(saved.boxes.isEmpty)
    }

    func testSecondSaveIsByteIdentical() throws {
        let store = try makeStore()
        try store.save()
        let first = try Data(contentsOf: tempDir.appendingPathComponent("annotations.json"))
        try store.save()
        let second = try Data(contentsOf: tempDir.appendingPathComponent("annotations.json"))
        XCTAssertEqual(first, second)
    }

    func testFreshDatasetCreatesAnnotationsOnFirstSave() throws {
        let fresh = tempDir.appendingPathComponent("fresh")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try Data([0xFF]).write(to: fresh.appendingPathComponent("x.jpg"))

        let location = try XCTUnwrap(DatasetLocator.resolve(path: fresh.path))
        let store = try DatasetStore(location: location)
        let entry = try XCTUnwrap(store.entry(for: "x.jpg"))
        store.addBox(BoundingBox(label: "thing", rect: CGRect(x: 0, y: 0, width: 4, height: 4)),
                     to: entry, undoManager: nil)
        try store.save()

        let records = try CreateMLFormat.load(Data(contentsOf: fresh.appendingPathComponent("annotations.json")))
        XCTAssertEqual(records.map(\.image), ["x.jpg"])
    }

    // MARK: - Label usage (memoized; invalidated on box/label change only)

    func testLabelUsageStaysCorrectAcrossMutations() throws {
        let store = try makeStore()
        // b.jpg + ghost.jpg each carry one "card" box.
        XCTAssertEqual(store.labelUsage(), ["card": 2])

        let a = try XCTUnwrap(store.entry(for: "a.jpg"))
        store.addBox(BoundingBox(label: "star", rect: CGRect(x: 1, y: 1, width: 2, height: 2)),
                     to: a, undoManager: nil)
        // Would read a stale ["card": 2] if addBox didn't invalidate the memo.
        XCTAssertEqual(store.labelUsage(), ["card": 2, "star": 1])

        let b = try XCTUnwrap(store.entry(for: "b.jpg"))
        store.setBoxLabel(id: b.boxes[0].id, in: b, to: "star", undoManager: nil)
        XCTAssertEqual(store.labelUsage(), ["card": 1, "star": 2])

        // Geometry-only edits (the per-frame drag path) must not disturb counts.
        store.setBoxRect(id: b.boxes[0].id, in: b, to: CGRect(x: 9, y: 9, width: 3, height: 3))
        XCTAssertEqual(store.labelUsage(), ["card": 1, "star": 2])

        store.removeBox(id: b.boxes[0].id, from: b, undoManager: nil)
        XCTAssertEqual(store.labelUsage(), ["card": 1, "star": 1])
    }

    // MARK: - Undo

    func testUndoRedoSequencesRestoreState() throws {
        let store = try makeStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let entry = try XCTUnwrap(store.entry(for: "b.jpg"))
        let originalRect = entry.boxes[0].rect
        let boxID = entry.boxes[0].id

        // Move (as the gesture-end commit does).
        undo.beginUndoGrouping()
        store.commitBoxRect(id: boxID, in: entry, from: originalRect,
                            to: CGRect(x: 0, y: 0, width: 20, height: 20), undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertEqual(entry.boxes[0].rect.origin, .zero)

        undo.undo()
        XCTAssertEqual(entry.boxes[0].rect, originalRect)
        undo.redo()
        XCTAssertEqual(entry.boxes[0].rect.origin, .zero)

        // Delete then undo restores at the same index with same id.
        undo.beginUndoGrouping()
        store.removeBox(id: boxID, from: entry, undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertTrue(entry.boxes.isEmpty)
        undo.undo()
        XCTAssertEqual(entry.boxes.first?.id, boxID)

        // Label change round-trip.
        undo.beginUndoGrouping()
        store.setBoxLabel(id: boxID, in: entry, to: "star", undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertEqual(entry.boxes[0].label, "star")
        XCTAssertEqual(store.labels.ordered, ["card", "star"])
        undo.undo()
        XCTAssertEqual(entry.boxes[0].label, "card")
    }
}
