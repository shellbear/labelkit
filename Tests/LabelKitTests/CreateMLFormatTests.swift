import XCTest
@testable import LabelKit

final class CreateMLFormatTests: XCTestCase {
    /// Shaped like the real-world datasets this tool targets: center-based
    /// pixel coordinates, a negative entry, and unknown extra keys at both
    /// entry and annotation level.
    static let fixture = """
    [
     {
      "image": "caf\u{00E9} photo 1.jpg",
      "annotations": [
       {
        "label": "card",
        "coordinates": {
         "x": 450.2811789512634,
         "y": 1075.12,
         "width": 247.78,
         "height": 427.68
        }
       },
       {
        "label": "card",
        "coordinates": {"x": 113, "y": 575, "width": 220, "height": 245},
        "reviewed": true
       }
      ],
      "imageWidth": 800,
      "imageHeight": 1734
     },
     {
      "image": "negative.jpg",
      "annotations": []
     }
    ]
    """

    func testLoadParsesEntriesBoxesAndExtras() throws {
        let records = try CreateMLFormat.load(Data(Self.fixture.utf8))
        XCTAssertEqual(records.count, 2)

        let first = records[0]
        XCTAssertEqual(first.image, "café photo 1.jpg")
        XCTAssertEqual(first.boxes.count, 2)
        XCTAssertEqual(first.boxes[0].label, "card")
        XCTAssertEqual(first.boxes[0].x, 450.2811789512634, accuracy: 1e-9)
        XCTAssertEqual(first.boxes[0].height, 427.68, accuracy: 1e-9)
        XCTAssertEqual(first.extras["imageWidth"], .number(800))
        XCTAssertEqual(first.extras["imageHeight"], .number(1734))
        XCTAssertEqual(first.boxes[1].extras["reviewed"], .bool(true))

        XCTAssertEqual(records[1].image, "negative.jpg")
        XCTAssertTrue(records[1].boxes.isEmpty)
    }

    func testRoundTripIsStableAndPreservesNegativesAndExtras() throws {
        let once = try CreateMLFormat.load(Data(Self.fixture.utf8))
        let serialized = CreateMLFormat.serialize(once)
        let twice = try CreateMLFormat.load(serialized)

        XCTAssertEqual(twice.count, 2)
        XCTAssertEqual(twice[1].image, "negative.jpg")
        XCTAssertTrue(twice[1].boxes.isEmpty)
        XCTAssertEqual(twice[0].extras["imageWidth"], .number(800))
        XCTAssertEqual(twice[0].boxes[1].extras["reviewed"], .bool(true))
        // Second serialization must be byte-identical (canonical form).
        XCTAssertEqual(serialized, CreateMLFormat.serialize(twice))
    }

    func testLoadRejectsNonArrayRoot() {
        XCTAssertThrowsError(try CreateMLFormat.load(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? CreateMLFormatError, .rootIsNotArray)
        }
    }

    func testLoadRejectsEntryWithoutImage() {
        let json = #"[{"annotations": []}]"#
        XCTAssertThrowsError(try CreateMLFormat.load(Data(json.utf8))) { error in
            XCTAssertEqual(error as? CreateMLFormatError, .entryMissingImage(index: 0))
        }
    }
}
