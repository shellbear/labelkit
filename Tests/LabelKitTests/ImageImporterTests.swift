import XCTest
@testable import LabelKit

final class ImageImporterTests: XCTestCase {
    var tempDir: URL!
    var dataset: URL!
    var sources: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("labelkit-import-\(UUID().uuidString)")
        dataset = tempDir.appendingPathComponent("dataset")
        sources = tempDir.appendingPathComponent("sources")
        for dir in [dataset!, sources!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @discardableResult
    private func write(_ bytes: [UInt8], to url: URL) throws -> URL {
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: - Classifying a drop

    func testExpandKeepsImagesDropsNonImagesAndScansFolders() throws {
        let loose = try write([0x1], to: sources.appendingPathComponent("a.jpg"))
        try write([0x2], to: sources.appendingPathComponent("notes.txt"))  // ignored
        let folder = sources.appendingPathComponent("more")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write([0x3], to: folder.appendingPathComponent("b.png"))
        try write([0x4], to: folder.appendingPathComponent("readme.md"))  // ignored

        let (images, folders) = ImageImporter.expand([loose, sources.appendingPathComponent("notes.txt"), folder])
        XCTAssertEqual(Set(images.map(\.lastPathComponent)), ["a.jpg", "b.png"])
        XCTAssertEqual(folders.map(\.lastPathComponent), ["more"])
    }

    // MARK: - Collision resolution + copy

    func testPlanCopiesFreshNamesAndSuffixesClashes() throws {
        try write([0xAA, 0xBB], to: dataset.appendingPathComponent("img.jpg"))  // existing, 2 bytes
        let fresh = try write([0x1], to: sources.appendingPathComponent("new.jpg"))
        let clash = try write([0x1, 0x2, 0x3], to: sources.appendingPathComponent("img.jpg"))  // 3 bytes ≠ existing

        let plan = ImageImporter.plan(
            sources: [fresh, clash], into: dataset, reservedNames: [])
        XCTAssertEqual(plan[0], .init(source: fresh, finalName: "new.jpg", needsCopy: true))
        XCTAssertEqual(plan[1], .init(source: clash, finalName: "img-2.jpg", needsCopy: true))

        let names = try ImageImporter.execute(plan, into: dataset)
        XCTAssertEqual(names, ["new.jpg", "img-2.jpg"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataset.appendingPathComponent("new.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataset.appendingPathComponent("img-2.jpg").path))
        // The pre-existing file is untouched (still 2 bytes).
        XCTAssertEqual(try Data(contentsOf: dataset.appendingPathComponent("img.jpg")).count, 2)
    }

    func testSameNameSameSizeIsTreatedAsAlreadyPresent() throws {
        try write([0x1, 0x2, 0x3], to: dataset.appendingPathComponent("img.jpg"))
        let redrag = try write([0x9, 0x8, 0x7], to: sources.appendingPathComponent("img.jpg"))  // same size

        let plan = ImageImporter.plan(sources: [redrag], into: dataset, reservedNames: [])
        XCTAssertEqual(plan, [.init(source: redrag, finalName: "img.jpg", needsCopy: false)])

        let names = try ImageImporter.execute(plan, into: dataset)
        XCTAssertEqual(names, ["img.jpg"])
        // No copy happened: the dataset file keeps its original bytes.
        XCTAssertEqual(try Data(contentsOf: dataset.appendingPathComponent("img.jpg")), Data([0x1, 0x2, 0x3]))
    }

    func testReservedNamesAndIntraBatchClashesBothGetSuffixed() throws {
        // "ghost.jpg" isn't on disk but is claimed by a missing-image entry.
        let one = try write([0x1], to: sources.appendingPathComponent("ghost.jpg"))
        let subdir = sources.appendingPathComponent("dup")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let two = try write([0x2, 0x2], to: subdir.appendingPathComponent("ghost.jpg"))  // same name, this batch

        let plan = ImageImporter.plan(
            sources: [one, two], into: dataset, reservedNames: ["ghost.jpg"])
        XCTAssertEqual(plan.map(\.finalName), ["ghost-2.jpg", "ghost-3.jpg"])
    }
}
