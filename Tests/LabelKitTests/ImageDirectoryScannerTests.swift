import XCTest
@testable import LabelKit

final class ImageDirectoryScannerTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("labelkit-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("subdir"), withIntermediateDirectories: true)
        for name in ["img10.jpg", "img2.JPG", "photo.png", "notes.txt", ".hidden.jpg", "annotations.json"] {
            try Data().write(to: tempDir.appendingPathComponent(name))
        }
        try Data().write(to: tempDir.appendingPathComponent("subdir/nested.jpg"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testFiltersExtensionsHiddenAndSubdirs() {
        XCTAssertEqual(
            ImageDirectoryScanner.scan(directory: tempDir),
            ["img2.JPG", "img10.jpg", "photo.png"]  // localizedStandardCompare: 2 < 10
        )
    }

    /// The listing is sorted by Foundation for speed; it must still be the
    /// order a plain `localizedStandardCompare` sort gives (Finder's order),
    /// with names that compare equal settled the same way every time.
    func testOrderMatchesFinderOrderForAwkwardNames() throws {
        let names = ["img1.jpg", "img01.jpg", "img001.jpg", "IMG2.jpg", "img10.jpg", "img9.jpg",
                     "Émile.png", "emile.png", "zebra.png", "Zebra 2.png", "a b.jpg", "a-b.jpg", "a_b.jpg",
                     "10.jpg", "9.jpg", "1.jpeg", "日本.jpg", "ß.jpg", "ss.jpg"]
        let directory = tempDir.appendingPathComponent("order")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var created: [String] = []
        for name in names where FileManager.default.createFile(
            atPath: directory.appendingPathComponent(name).path, contents: nil) {
            created.append(name)
        }
        // A case-insensitive volume keeps only one of two names differing in
        // case; compare against whatever actually exists.
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: directory.path)

        let scanned = ImageDirectoryScanner.scan(directory: directory)
        XCTAssertEqual(Set(scanned), Set(onDisk))
        for (earlier, later) in zip(scanned, scanned.dropFirst()) {
            let order = earlier.localizedStandardCompare(later)
            XCTAssertNotEqual(order, .orderedDescending, "\(earlier) should not come after \(later)")
            if order == .orderedSame { XCTAssertLessThan(earlier, later, "ties settle by plain comparison") }
        }
        XCTAssertEqual(ImageDirectoryScanner.scan(directory: directory), scanned, "stable across calls")
    }

    func testUnreadableDirectoryIsEmpty() {
        XCTAssertEqual(ImageDirectoryScanner.scan(directory: tempDir.appendingPathComponent("nope")), [])
    }

    func testGlobFilter() {
        XCTAssertEqual(
            ImageDirectoryScanner.scan(directory: tempDir, glob: "*.png"),
            ["photo.png"]
        )
    }
}
