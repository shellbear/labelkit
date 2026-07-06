import XCTest
@testable import LabelKit

final class DatasetLocatorTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("labelkit-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testNilPathReturnsNilForOpenPanel() throws {
        XCTAssertNil(try DatasetLocator.resolve(path: nil))
    }

    func testDirectoryWithAnnotations() throws {
        let annotations = tempDir.appendingPathComponent("annotations.json")
        try Data("[]".utf8).write(to: annotations)
        let location = try XCTUnwrap(DatasetLocator.resolve(path: tempDir.path))
        XCTAssertEqual(location.imagesDirectory.path, tempDir.path)
        XCTAssertEqual(location.annotationsURL.lastPathComponent, "annotations.json")
        XCTAssertTrue(location.annotationsExists)
    }

    func testDirectoryWithoutAnnotationsStartsFresh() throws {
        let location = try XCTUnwrap(DatasetLocator.resolve(path: tempDir.path))
        XCTAssertFalse(location.annotationsExists)
        XCTAssertEqual(location.annotationsURL.lastPathComponent, "annotations.json")
    }

    func testJSONPathResolvesImagesToParent() throws {
        let json = tempDir.appendingPathComponent("labels.json")
        try Data("[]".utf8).write(to: json)
        let location = try XCTUnwrap(DatasetLocator.resolve(path: json.path))
        XCTAssertEqual(location.imagesDirectory.path, tempDir.path)
        XCTAssertEqual(location.annotationsURL.lastPathComponent, "labels.json")
        XCTAssertTrue(location.annotationsExists)
    }

    func testAnnotationsOverrideWins() throws {
        let override = tempDir.appendingPathComponent("custom.json")
        let location = try XCTUnwrap(
            DatasetLocator.resolve(path: tempDir.path, annotationsOverride: override.path))
        XCTAssertEqual(location.annotationsURL.lastPathComponent, "custom.json")
        XCTAssertFalse(location.annotationsExists)
    }

    func testMissingPathThrows() {
        XCTAssertThrowsError(try DatasetLocator.resolve(path: tempDir.appendingPathComponent("nope").path))
    }

    func testNonJSONFileThrows() throws {
        let file = tempDir.appendingPathComponent("photo.jpg")
        try Data().write(to: file)
        XCTAssertThrowsError(try DatasetLocator.resolve(path: file.path))
    }
}
