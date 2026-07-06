import XCTest
@testable import LabelKit

final class JSONIndentTests: XCTestCase {
    func testDetectsPythonSingleSpace() {
        let json = "[\n {\n  \"image\": \"a.jpg\",\n  \"annotations\": []\n }\n]\n"
        XCTAssertEqual(JSONIndent.detectUnit(in: Data(json.utf8)), " ")
    }

    func testDetectsTwoSpaces() {
        let json = "[\n  {\n    \"image\": \"a.jpg\",\n    \"annotations\": []\n  }\n]\n"
        XCTAssertEqual(JSONIndent.detectUnit(in: Data(json.utf8)), "  ")
    }

    func testDetectsTabs() {
        let json = "[\n\t{\n\t\t\"image\": \"a.jpg\",\n\t\t\"annotations\": []\n\t}\n]\n"
        XCTAssertEqual(JSONIndent.detectUnit(in: Data(json.utf8)), "\t")
    }

    func testCompactJSONReturnsNil() {
        XCTAssertNil(JSONIndent.detectUnit(in: Data(#"[{"image":"a.jpg","annotations":[]}]"#.utf8)))
    }

    func testWriterFollowsUnit() {
        let records = [ImageAnnotationRecord(
            image: "a.jpg",
            boxes: [BoxRecord(label: "card", x: 10, y: 10, width: 4, height: 4)])]
        let oneSpace = String(decoding: CreateMLWriter.serialize(records, indentUnit: " "), as: UTF8.self)
        XCTAssertTrue(oneSpace.contains("\n {\n  \"image\": \"a.jpg\""))
        XCTAssertTrue(oneSpace.contains("\n     \"x\": 10"))  // depth 5 = 5 spaces

        let tabs = String(decoding: CreateMLWriter.serialize(records, indentUnit: "\t"), as: UTF8.self)
        XCTAssertTrue(tabs.contains("\n\t{\n\t\t\"image\": \"a.jpg\""))
    }

    @MainActor
    func testStorePreservesLoadedIndentOnSave() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("labelkit-indent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try Data([0xFF]).write(to: tempDir.appendingPathComponent("a.jpg"))
        // Python json.dump(indent=1) style — 1-space unit.
        let python = "[\n {\n  \"image\": \"a.jpg\",\n  \"annotations\": []\n }\n]"
        try Data(python.utf8).write(to: tempDir.appendingPathComponent("annotations.json"))

        let location = try XCTUnwrap(DatasetLocator.resolve(path: tempDir.path))
        let store = try DatasetStore(location: location)
        try store.save()

        let saved = try String(contentsOf: tempDir.appendingPathComponent("annotations.json"), encoding: .utf8)
        XCTAssertTrue(saved.hasPrefix("[\n {\n  \"image\""), "1-space indent must survive: \(saved.prefix(30))")
    }
}
