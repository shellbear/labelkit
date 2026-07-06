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

    func testGlobFilter() {
        XCTAssertEqual(
            ImageDirectoryScanner.scan(directory: tempDir, glob: "*.png"),
            ["photo.png"]
        )
    }
}
