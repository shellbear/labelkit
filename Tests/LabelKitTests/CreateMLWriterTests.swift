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

    /// `coordString` takes an integer fast path; saved bytes must not depend on
    /// which path ran. Compare it with the reference formatting over a wide,
    /// reproducible spread of values, including the awkward ones.
    func testFastCoordStringAgreesWithTheReferenceFormatting() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {   // xorshift64*: deterministic, no seedable RNG in the stdlib
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return Double(state &* 0x2545_F491_4F6C_DD1D >> 11) / Double(1 << 53)
        }
        var values: [Double] = [
            0, -0.0, 0.004, 0.005, -0.005, 0.01, 0.05, 0.1, 0.5, 0.995, 1, -1, 9.999, 99.995, 100,
            427.5, 450.2811789512634, -12.345, 1e6, 123456.785, 1e12, 9.99e12, 1e13, 1e14, 1e15, 1e18,
            -1e15, .infinity, -.infinity, .nan, .greatestFiniteMagnitude, .leastNonzeroMagnitude,
        ]
        for magnitude in [1.0, 10, 1_000, 10_000, 1e7, 1e11, 1e13] {
            for _ in 0..<20_000 {
                let value = (next() * 2 - 1) * magnitude
                values.append(value)
                values.append((value * 100).rounded() / 100)        // already 2 dp
                values.append((value * 10).rounded() / 10 + 0.005)  // right on a rounding edge
            }
        }
        for value in values {
            XCTAssertEqual(CreateMLWriter.coordString(value), CreateMLWriter.formattedCoordString(value),
                           "value \(value)")
        }
    }

    func testEscapingIsOnlyAppliedWhereNeeded() {
        let records = [ImageAnnotationRecord(image: "naïve photo (1) é.jpg", boxes: [
            BoxRecord(label: "tab\there", x: 1, y: 1, width: 1, height: 1),
            BoxRecord(label: "bell\u{07}", x: 1, y: 1, width: 1, height: 1),
        ])]
        let out = String(decoding: CreateMLWriter.serialize(records), as: UTF8.self)
        XCTAssertTrue(out.contains(#""image": "naïve photo (1) é.jpg""#))
        XCTAssertTrue(out.contains(#""label": "tab\there""#))
        XCTAssertTrue(out.contains(#""label": "bell\u0007""#))
        XCTAssertEqual(try CreateMLFormat.load(Data(out.utf8)), records)
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
