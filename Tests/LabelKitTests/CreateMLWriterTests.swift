import XCTest
@testable import LabelKit

final class CreateMLWriterTests: XCTestCase {
    func testCoordStringCanonicalization() {
        XCTAssertEqual(CreateMLWriter.coordString(450.2811789512634), "450.28")
        XCTAssertEqual(CreateMLWriter.coordString(427.5), "427.5")
        XCTAssertEqual(CreateMLWriter.coordString(800), "800")
        XCTAssertEqual(CreateMLWriter.coordString(800.004), "800")
        XCTAssertEqual(CreateMLWriter.coordString(0.005), "0.01")
        XCTAssertEqual(CreateMLWriter.coordString(-12.345), "-12.35")
        XCTAssertEqual(CreateMLWriter.coordString(0), "0")
    }

    func testCanonicalLayoutGolden() {
        let records = [
            ImageAnnotationRecord(
                image: "a.jpg",
                boxes: [BoxRecord(label: "card", x: 100.123, y: 50, width: 20.5, height: 30)],
                extras: ["imageWidth": .number(800)]
            ),
            ImageAnnotationRecord(image: "negative.jpg", boxes: []),
        ]
        let expected = """
        [
          {
            "image": "a.jpg",
            "annotations": [
              {
                "label": "card",
                "coordinates": {
                  "x": 100.12,
                  "y": 50,
                  "width": 20.5,
                  "height": 30
                }
              }
            ],
            "imageWidth": 800
          },
          {
            "image": "negative.jpg",
            "annotations": []
          }
        ]

        """
        XCTAssertEqual(String(decoding: CreateMLWriter.serialize(records), as: UTF8.self), expected)
    }

    func testEmptyDataset() {
        XCTAssertEqual(String(decoding: CreateMLWriter.serialize([]), as: UTF8.self), "[]\n")
    }

    func testStringEscaping() {
        let records = [ImageAnnotationRecord(image: "we\"ird\\name\n.jpg", boxes: [])]
        let out = String(decoding: CreateMLWriter.serialize(records), as: UTF8.self)
        XCTAssertTrue(out.contains(#""we\"ird\\name\n.jpg""#))
        // And it must parse back to the same filename.
        let reloaded = try! CreateMLFormat.load(CreateMLWriter.serialize(records))
        XCTAssertEqual(reloaded[0].image, "we\"ird\\name\n.jpg")
    }
}
