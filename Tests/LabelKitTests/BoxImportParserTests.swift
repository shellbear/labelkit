import CoreGraphics
import XCTest
@testable import LabelKit

final class BoxImportParserTests: XCTestCase {
    func parse(_ text: String) throws -> [ImportedImage] {
        try BoxImportParser.parse(Data(text.utf8))
    }

    func testSimplestHandWrittenShape() throws {
        let images = try parse(#"{"image":"a.jpg","boxes":[{"label":"cat","x":10,"y":20,"width":30,"height":40}]}"#)
        XCTAssertEqual(images, [ImportedImage(image: "a.jpg", boxes: [
            ImportedBox(label: "cat", geometry: .pixels(CGRect(x: 10, y: 20, width: 30, height: 40))),
        ])])
    }

    func testArrayOfImages() throws {
        let images = try parse(#"""
        [{"image":"a.jpg","boxes":[]},
         {"image":"b.jpg","boxes":[{"label":"cat","normalized":{"x":0.1,"y":0.2,"width":0.3,"height":0.4}}]}]
        """#)
        XCTAssertEqual(images.map(\.image), ["a.jpg", "b.jpg"])
        XCTAssertEqual(images[1].boxes.first?.geometry,
                       .normalized(CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)))
    }

    func testNDJSONWithBlankLines() throws {
        let images = try parse("""
        {"image":"a.jpg","boxes":[{"label":"cat","x":1,"y":2,"width":3,"height":4}]}

        {"image":"b.jpg","boxes":[]}

        """)
        XCTAssertEqual(images.map(\.image), ["a.jpg", "b.jpg"])
    }

    /// `labelkit detect --format ndjson | labelkit annotate …` must just work.
    func testDetectReportsRoundTripThroughTheParser() throws {
        let box = BoundingBox(label: "card", rect: CGRect(x: 326.39, y: 490.28, width: 247.78, height: 427.68))
        let report = DetectionReport.make(
            detector: "Rectangles", source: "vision", filename: "photo.jpg", path: "/tmp/x/photo.jpg",
            pixelSize: CGSize(width: 2048, height: 1536),
            detections: [DetectionCandidate(box: box, confidence: 0.97)])
        let line = try JSONEncoder().encode(report)

        // The report states the image's size, so the pixels are tied to it —
        // and since that is the real size, the merge uses them untouched.
        let images = try BoxImportParser.parse(line)
        XCTAssertEqual(images, [ImportedImage(image: "photo.jpg", boxes: [
            ImportedBox(label: "card", geometry: .scaledPixels(box.rect, reference: CGSize(width: 2048, height: 1536))),
        ])])
    }

    // MARK: - What vision models answer

    private func boxes(_ json: String, image: String? = "a.jpg",
                       _ convention: BoxConvention = .pixelTopLeftCorner,
                       label: String? = nil) throws -> [ImportedBox] {
        let images = try BoxImportParser.parse(
            Data(json.utf8), options: .init(convention: convention, defaultLabel: label, image: image))
        XCTAssertEqual(images.count, 1)
        return images.first?.boxes ?? []
    }

    private func assertNormalized(_ geometry: ImportedBox.Geometry?, _ x: Double, _ y: Double,
                                  _ w: Double, _ h: Double, line: UInt = #line) {
        guard case .normalized(let rect)? = geometry else { return XCTFail("not normalized: \(String(describing: geometry))", line: line) }
        XCTAssertEqual(rect.minX, x, accuracy: 1e-9, line: line)
        XCTAssertEqual(rect.minY, y, accuracy: 1e-9, line: line)
        XCTAssertEqual(rect.width, w, accuracy: 1e-9, line: line)
        XCTAssertEqual(rect.height, h, accuracy: 1e-9, line: line)
    }

    /// Gemini: a bare list, y first, 0–1000, usually inside a code fence.
    func testGeminiBox2DInsideACodeFence() throws {
        let answer = """
        Here are the boxes:
        ```json
        [
          {"box_2d": [100, 200, 500, 400], "label": "cat"},
          {"box_2d": [0, 0, 1000, 1000], "label": "table"}
        ]
        ```
        """
        let parsed = try boxes(answer)
        XCTAssertEqual(parsed.map(\.label), ["cat", "table"])
        assertNormalized(parsed[0].geometry, 0.2, 0.1, 0.2, 0.4)   // x from 200..400, y from 100..500
        assertNormalized(parsed[1].geometry, 0, 0, 1, 1)
    }

    func testCodeFenceOnOneLineAndWithoutAnInfoString() throws {
        let oneLine = try boxes("```json [{\"box_2d\": [100, 200, 500, 400], \"label\": \"cat\"}] ```")
        assertNormalized(oneLine[0].geometry, 0.2, 0.1, 0.2, 0.4)
        let bare = try boxes("```\n[{\"label\": \"cat\", \"xyxy\": [1, 2, 3, 4]}]\n```")
        XCTAssertEqual(bare[0].geometry, .pixels(CGRect(x: 1, y: 2, width: 2, height: 2)))
        // Text that merely contains one fence is left as it is.
        XCTAssertEqual(BoxImportParser.stripCodeFence("a ``` b"), "a ``` b")
        XCTAssertEqual(BoxImportParser.stripCodeFence("no fence"), "no fence")
    }

    /// The simplest thing a model can answer for one image: one box.
    func testASingleBoxObjectForANamedImage() throws {
        let parsed = try boxes(#"{"label": "cat", "xyxy": [40, 30, 240, 190]}"#)
        XCTAssertEqual(parsed, [ImportedBox(label: "cat", geometry: .pixels(CGRect(x: 40, y: 30, width: 200, height: 160)))])
        // Without a named image the same object has no image to go to.
        XCTAssertThrowsError(try parse(#"{"label": "cat", "xyxy": [40, 30, 240, 190]}"#))
    }

    func testGeminiBox2DKeepsItsMeaningWhateverTheFlagsSay() throws {
        let parsed = try boxes(#"[{"box_2d":[100,200,500,400],"label":"cat"}]"#,
                               .init(units: .pixel, anchor: .center, order: .xyxy))
        assertNormalized(parsed[0].geometry, 0.2, 0.1, 0.2, 0.4)
    }

    /// Qwen uses one key for two scales, so the scale is stated, never guessed.
    func testQwenBbox2DFollowsTheStatedUnits() throws {
        let json = #"[{"bbox_2d":[200,100,400,500],"label":"cat"}]"#
        XCTAssertEqual(try boxes(json)[0].geometry, .pixels(CGRect(x: 200, y: 100, width: 200, height: 400)))
        assertNormalized(try boxes(json, .init(units: .thousandths))[0].geometry, 0.2, 0.1, 0.2, 0.4)
    }

    func testCornerShapes() throws {
        let expected = ImportedBox.Geometry.pixels(CGRect(x: 40, y: 30, width: 200, height: 160))
        XCTAssertEqual(try boxes(#"[{"label":"c","xyxy":[40,30,240,190]}]"#)[0].geometry, expected)
        XCTAssertEqual(try boxes(#"[{"label":"c","x1":40,"y1":30,"x2":240,"y2":190}]"#)[0].geometry, expected)
        XCTAssertEqual(try boxes(#"[{"label":"c","xmin":40,"ymin":30,"xmax":240,"ymax":190}]"#)[0].geometry, expected)
        // Corners given in the other order describe the same box.
        XCTAssertEqual(try boxes(#"[{"label":"c","xyxy":[240,190,40,30]}]"#)[0].geometry, expected)
        // Moondream: named corners in fractions, no label.
        let moondream = try boxes(#"{"objects":[{"x_min":0.2,"y_min":0.1,"x_max":0.4,"y_max":0.5}]}"#,
                                  .init(units: .normalized), label: "cat")
        XCTAssertEqual(moondream[0].label, "cat")
        assertNormalized(moondream[0].geometry, 0.2, 0.1, 0.2, 0.4)
    }

    func testBareArraysFollowTheStatedOrder() throws {
        let json = #"[{"label":"c","bbox":[40,30,240,190]}]"#
        XCTAssertEqual(try boxes(json)[0].geometry, .pixels(CGRect(x: 40, y: 30, width: 240, height: 190)))
        XCTAssertEqual(try boxes(json, .init(order: .xyxy))[0].geometry,
                       .pixels(CGRect(x: 40, y: 30, width: 200, height: 160)))
        XCTAssertEqual(try boxes(json, .init(order: .yxyx))[0].geometry,
                       .pixels(CGRect(x: 30, y: 40, width: 160, height: 200)))
    }

    /// Grounding DINO / Florence style: boxes and labels as parallel lists.
    func testParallelBoxAndLabelLists() throws {
        let parsed = try boxes(#"{"boxes":[[40,30,240,190],[0,0,10,10]],"text_labels":["cat","dog"],"scores":[0.9,0.8]}"#,
                               .init(order: .xyxy))
        XCTAssertEqual(parsed.map(\.label), ["cat", "dog"])
        XCTAssertEqual(parsed[0].geometry, .pixels(CGRect(x: 40, y: 30, width: 200, height: 160)))
        XCTAssertThrowsError(try boxes(#"{"boxes":[[40,30,240,190]]}"#), "no label anywhere")
        XCTAssertEqual(try boxes(#"{"boxes":[[40,30,240,190]]}"#, label: "card").map(\.label), ["card"])
    }

    /// A model shown a downscaled copy answers in that copy's pixels.
    func testPixelsOfAResizedCopyCarryTheirReferenceSize() throws {
        let rect = CGRect(x: 40, y: 30, width: 200, height: 160)
        let reference = CGSize(width: 1568, height: 1176)
        XCTAssertEqual(try boxes(#"[{"label":"c","xyxy":[40,30,240,190]}]"#,
                                 .init(referenceSize: reference))[0].geometry,
                       .scaledPixels(rect, reference: reference))
        // The entry can say it itself.
        XCTAssertEqual(try boxes(#"{"width":1568,"height":1176,"boxes":[{"label":"c","xyxy":[40,30,240,190]}]}"#)[0].geometry,
                       .scaledPixels(rect, reference: reference))
        XCTAssertEqual(BoxImportParser.parseSize("1568x1176"), reference)
        XCTAssertEqual(BoxImportParser.parseSize("1568 X 1176"), reference)
        XCTAssertNil(BoxImportParser.parseSize("1568"))
        XCTAssertNil(BoxImportParser.parseSize("0x10"))
    }

    func testLabelAndImageKeyAliases() throws {
        let images = try BoxImportParser.parse(Data(#"""
        [{"imagefilename":"a.jpg","annotation":[{"label":"x","coordinates":{"x":5,"y":5,"width":2,"height":2}}]},
         {"file_name":"b.jpg","predictions":[{"class":"y","x":1,"y":2,"w":3,"h":4}]}]
        """#.utf8))
        XCTAssertEqual(images.map(\.image), ["a.jpg", "b.jpg"])
        XCTAssertEqual(images[0].boxes[0].geometry, .pixels(CGRect(x: 4, y: 4, width: 2, height: 2)))
        XCTAssertEqual(images[1].boxes[0], ImportedBox(label: "y", geometry: .pixels(CGRect(x: 1, y: 2, width: 3, height: 4))))
    }

    // MARK: - COCO

    func testCOCOFileBecomesOneEntryPerImageIncludingEmptyOnes() throws {
        let images = try parse(#"""
        {"images":[{"id":7,"file_name":"train/a.jpg","width":200,"height":100},
                   {"id":9,"file_name":"b.jpg","width":200,"height":100}],
         "categories":[{"id":1,"name":"cat"},{"id":2,"name":"dog"}],
         "annotations":[{"id":1,"image_id":7,"category_id":2,"bbox":[10,20,30,40]},
                        {"id":2,"image_id":7,"category_id":1,"bbox":[0,0,5,5]}]}
        """#)
        XCTAssertEqual(images.map(\.image), ["a.jpg", "b.jpg"])
        XCTAssertEqual(images[0].boxes.map(\.label), ["dog", "cat"])
        XCTAssertEqual(images[0].boxes[0].geometry,
                       .scaledPixels(CGRect(x: 10, y: 20, width: 30, height: 40), reference: CGSize(width: 200, height: 100)))
        XCTAssertTrue(images[1].boxes.isEmpty)
    }

    func testCOCOWithADanglingReferenceIsAnError() {
        XCTAssertThrowsError(try parse(#"""
        {"images":[{"id":7,"file_name":"a.jpg"}],"categories":[{"id":1,"name":"cat"}],
         "annotations":[{"image_id":8,"category_id":1,"bbox":[1,2,3,4]}]}
        """#))
        XCTAssertThrowsError(try parse(#"""
        {"images":[{"id":7,"file_name":"a.jpg"}],"categories":[{"id":1,"name":"cat"}],
         "annotations":[{"image_id":7,"category_id":5,"bbox":[1,2,3,4]}]}
        """#))
    }

    func testNamingTheImageMakesTheImageKeyOptional() throws {
        XCTAssertEqual(try boxes(#"{"boxes":[{"label":"c","x":1,"y":2,"width":3,"height":4}]}"#, image: "z.jpg").count, 1)
        let images = try BoxImportParser.parse(Data(#"[{"label":"c","x":1,"y":2,"width":3,"height":4}]"#.utf8),
                                               options: .init(image: "z.jpg"))
        XCTAssertEqual(images.map(\.image), ["z.jpg"])
        // Without a named image a bare box list has nowhere to go.
        XCTAssertThrowsError(try parse(#"[{"label":"c","x":1,"y":2,"width":3,"height":4}]"#))
    }

    /// A Create ML annotations file is valid input: its centre-anchored
    /// coordinates become the same top-left rect the editor would show.
    func testCreateMLEntriesUseCentreAnchoredCoordinates() throws {
        let images = try parse(#"""
        [{"image":"a.jpg","annotations":[{"label":"card","coordinates":{"x":50,"y":60,"width":20,"height":40}}]}]
        """#)
        XCTAssertEqual(images[0].boxes.first?.geometry, .pixels(CGRect(x: 40, y: 40, width: 20, height: 40)))
    }

    func testImageFallsBackToTheBasenameOfPath() throws {
        let images = try parse(#"{"path":"/data/set/a.jpg","boxes":[]}"#)
        XCTAssertEqual(images.first?.image, "a.jpg")
    }

    func testEmptyInputIsNoImages() throws {
        XCTAssertEqual(try parse("  \n"), [])
    }

    func testErrorsSayWhereTheProblemIs() {
        func message(_ text: String) -> String {
            do {
                _ = try parse(text)
                return "no error"
            } catch {
                return (error as? BoxImportError)?.message ?? "\(error)"
            }
        }
        XCTAssertEqual(message(#"{"boxes":[]}"#), "input: missing \"image\"")
        XCTAssertEqual(message(#"{"image":"a.jpg"}"#),
                       "input (a.jpg): expected a \"boxes\", \"detections\" or \"annotations\" list")
        XCTAssertEqual(message(#"{"image":"a.jpg","boxes":[{"x":1,"y":2,"width":3,"height":4}]}"#),
                       "input (a.jpg), box #1: missing \"label\"")
        XCTAssertTrue(message(#"{"image":"a.jpg","boxes":[{"label":"cat"}]}"#)
            .hasPrefix("input (a.jpg), box #1: no geometry — give x,y,width,height, or one of"))
        XCTAssertEqual(message(#"{"image":"a.jpg","boxes":[{"label":"cat","xyxy":[1,2,3]}]}"#),
                       "input (a.jpg), box #1 xyxy: expected four numbers")
        XCTAssertEqual(message(#"{"image":"a.jpg","boxes":[{"label":"cat","x":1,"y":2,"width":"3","height":4}]}"#),
                       "input (a.jpg), box #1: \"width\" must be a number")
        XCTAssertEqual(message("{\"image\":\"a.jpg\",\"boxes\":[]}\nnot json"), "line 2 is not a JSON object")
        XCTAssertEqual(message("42"), "expected a JSON object, an array of objects, or NDJSON")
    }

    func testInlineBox() throws {
        XCTAssertEqual(try BoxImportParser.parseInlineBox("cat:10,20,30.5,40"),
                       ImportedBox(label: "cat", geometry: .pixels(CGRect(x: 10, y: 20, width: 30.5, height: 40))))
        let fractions = BoxImportParser.Options(convention: .init(units: .normalized))
        XCTAssertEqual(try BoxImportParser.parseInlineBox("red: car : 0.1, 0.2, 0.3, 0.4", options: fractions),
                       ImportedBox(label: "red: car", geometry: .normalized(CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))))
        XCTAssertEqual(try BoxImportParser.parseInlineBox("10,20,30,40", options: .init(defaultLabel: "card")),
                       ImportedBox(label: "card", geometry: .pixels(CGRect(x: 10, y: 20, width: 30, height: 40))))
        XCTAssertThrowsError(try BoxImportParser.parseInlineBox("10,20,30,40"), "no label and no default")
        XCTAssertThrowsError(try BoxImportParser.parseInlineBox("cat 10,20,30,40"))
        XCTAssertThrowsError(try BoxImportParser.parseInlineBox("cat:10,20,30"))
        XCTAssertThrowsError(try BoxImportParser.parseInlineBox(":10,20,30,40"))
    }

    // MARK: - Conventions

    /// The same box — top-left corner (40,40), 20 wide, 40 tall, in a
    /// 200x100 image — written four ways.
    func testEveryConventionLandsOnTheSameBox() throws {
        func geometry(_ box: String, _ convention: BoxConvention) throws -> ImportedBox.Geometry {
            let json = "{\"image\":\"a.jpg\",\"boxes\":[\(box)]}"
            let images = try BoxImportParser.parse(Data(json.utf8), options: .init(convention: convention))
            return try XCTUnwrap(images.first?.boxes.first?.geometry)
        }
        let pixels = ImportedBox.Geometry.pixels(CGRect(x: 40, y: 40, width: 20, height: 40))
        XCTAssertEqual(try geometry(#"{"label":"c","x":40,"y":40,"width":20,"height":40}"#, .pixelTopLeftCorner), pixels)
        XCTAssertEqual(try geometry(#"{"label":"c","x":50,"y":60,"width":20,"height":40}"#, .createML), pixels)

        func assertNormalized(_ result: ImportedBox.Geometry, line: UInt = #line) {
            guard case .normalized(let rect) = result else { return XCTFail("not normalized", line: line) }
            XCTAssertEqual(rect.minX, 0.2, accuracy: 1e-9, line: line)
            XCTAssertEqual(rect.minY, 0.4, accuracy: 1e-9, line: line)
            XCTAssertEqual(rect.width, 0.1, accuracy: 1e-9, line: line)
            XCTAssertEqual(rect.height, 0.4, accuracy: 1e-9, line: line)
        }
        // YOLO: normalized, top-left origin, centre anchor.
        assertNormalized(try geometry(#"{"label":"c","x":0.25,"y":0.6,"width":0.1,"height":0.4}"#,
                                      .init(units: .normalized, anchor: .center)))
        // Apple Vision: normalized, bottom-left origin, corner = bottom-left.
        assertNormalized(try geometry(#"{"label":"c","x":0.2,"y":0.2,"width":0.1,"height":0.4}"#,
                                      .init(units: .normalized, origin: .bottomLeft)))
    }

    func testCoordinatesAndNormalizedKeysKeepTheirOwnMeaningUnderAnyConvention() throws {
        let options = BoxImportParser.Options(convention: .init(anchor: .center))
        let images = try BoxImportParser.parse(Data(#"""
        {"image":"a.jpg","boxes":[
          {"label":"c","coordinates":{"x":50,"y":60,"width":20,"height":40}},
          {"label":"c","normalized":{"x":0.5,"y":0.5,"width":0.2,"height":0.2}}]}
        """#.utf8), options: options)
        XCTAssertEqual(images[0].boxes[0].geometry, .pixels(CGRect(x: 40, y: 40, width: 20, height: 40)))
        guard case .normalized(let rect) = images[0].boxes[1].geometry else { return XCTFail() }
        XCTAssertEqual(rect.minX, 0.4, accuracy: 1e-9)   // the centre anchor still applies; units are forced
        XCTAssertEqual(rect.minY, 0.4, accuracy: 1e-9)
    }

    func testDefaultLabelFillsInBoxesWithoutOne() throws {
        let json = #"{"image":"a.jpg","boxes":[{"x":1,"y":2,"width":3,"height":4},{"label":"coin","x":1,"y":2,"width":3,"height":4}]}"#
        let images = try BoxImportParser.parse(Data(json.utf8), options: .init(defaultLabel: "card"))
        XCTAssertEqual(images[0].boxes.map(\.label), ["card", "coin"])
    }

    func testPixelBottomLeftIsRefused() {
        XCTAssertNotNil(BoxConvention(units: .pixel, origin: .bottomLeft).unsupportedReason)
        XCTAssertNil(BoxConvention(units: .normalized, origin: .bottomLeft).unsupportedReason)
        XCTAssertNil(BoxConvention.createML.unsupportedReason)
    }
}
