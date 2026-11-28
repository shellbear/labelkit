import CoreGraphics
import XCTest
@testable import LabelKit

/// Import and export against real folders on disk, with real (tiny) images,
/// since the formats differ exactly in where files live and what size the
/// images are.
final class DatasetInteropTests: XCTestCase {
    var root: URL!
    var dataset: URL { root.appendingPathComponent("dataset") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("labelkit-interop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)
        try image("a.png", 200, 100, in: dataset)
        try image("b.png", 100, 200, in: dataset)
        try image("c.png", 50, 50, in: dataset)   // on disk, no entry: unlabelled
        try write("""
        [
          {"image": "a.png", "annotations": [
            {"label": "coin", "coordinates": {"x": 150, "y": 50, "width": 40, "height": 60}},
            {"label": "card", "coordinates": {"x": 50, "y": 50, "width": 20, "height": 20}}]},
          {"image": "b.png", "annotations": []},
          {"image": "ghost.png", "annotations": [
            {"label": "card", "coordinates": {"x": 5, "y": 5, "width": 2, "height": 2}}]}
        ]
        """, to: dataset.appendingPathComponent("annotations.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    func image(_ name: String, _ width: Int, _ height: Int, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let made = try writeTempPNG(size: CGSize(width: width, height: height))
        try FileManager.default.moveItem(at: made, to: directory.appendingPathComponent(name))
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String, in directory: URL) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8)
    }

    func document(_ url: URL? = nil) throws -> DatasetDocument {
        let target = url ?? dataset
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return try DatasetDocument(location: XCTUnwrap(DatasetLocator.resolve(path: target.path)))
    }

    @discardableResult
    func export(_ format: DatasetFormat, to name: String, copyImages: Bool = true) throws -> (URL, DatasetExport.Report) {
        let source = try document()
        let out = root.appendingPathComponent(name)
        let report = try DatasetExport.run(
            source, to: out, options: .init(format: format, copyImages: copyImages), labelkitVersion: "test",
            pixelSize: { source.pixelSize(of: $0) })
        return (out, report)
    }

    @discardableResult
    func importing(_ source: URL, into target: URL, format: DatasetFormat? = nil,
                   options: DatasetImport.Options = .init(recordNegatives: true)) throws -> DatasetImport.Report {
        var destination = try document(target)
        let foreign = try ForeignDatasetReader.read(at: source, format: format)
        return try DatasetImport.run(foreign, into: &destination, options: options, labelkitVersion: "test")
    }

    /// The exported dataset, imported into a fresh folder, must hold the same
    /// labelled images and boxes as the original (minus the entry whose image
    /// file never existed).
    func assertRoundTrips(_ format: DatasetFormat, line: UInt = #line) throws {
        let (out, exported) = try export(format, to: "out-\(format.rawValue)")
        XCTAssertEqual(exported.images, 2, line: line)
        XCTAssertEqual(exported.boxes, 2, line: line)
        XCTAssertEqual(exported.labels, ["card", "coin"], line: line)
        XCTAssertEqual(exported.skipped, [.init(image: "ghost.png", reason: "image file not found")], line: line)

        let back = root.appendingPathComponent("back-\(format.rawValue)")
        let report = try importing(out, into: back)
        XCTAssertEqual(report.format, format.rawValue, "format is detected", line: line)
        XCTAssertEqual(report.images, .init(found: 2, copied: 2, alreadyPresent: 0), line: line)
        XCTAssertEqual(report.boxes.added, 2, line: line)
        XCTAssertTrue(report.problems.isEmpty, line: line)

        let original = try document().records.filter { $0.image != "ghost.png" }
        let returned = try document(back).records
        XCTAssertEqual(returned.map(\.image), ["a.png", "b.png"], line: line)
        for (a, b) in zip(original, returned) {
            XCTAssertEqual(a.boxes.count, b.boxes.count, line: line)
            // Class order isn't preserved by formats that group by class id.
            for box in a.boxes {
                let match = try XCTUnwrap(b.boxes.first { $0.label == box.label }, line: line)
                XCTAssertEqual(match.x, box.x, accuracy: 0.011, line: line)
                XCTAssertEqual(match.y, box.y, accuracy: 0.011, line: line)
                XCTAssertEqual(match.width, box.width, accuracy: 0.011, line: line)
                XCTAssertEqual(match.height, box.height, accuracy: 0.011, line: line)
            }
        }
        XCTAssertEqual(try document(back).imagesOnDisk, ["a.png", "b.png"], "the unlabelled image isn't exported", line: line)
    }

    // MARK: - Round trips

    func testYOLORoundTrip() throws { try assertRoundTrips(.yolo) }
    func testCOCORoundTrip() throws { try assertRoundTrips(.coco) }
    func testHuggingFaceRoundTrip() throws { try assertRoundTrips(.huggingface) }

    // MARK: - What gets written

    func testYOLOExportFiles() throws {
        let (out, report) = try export(.yolo, to: "yolo")
        // a.png is 200x100: coin centre (150,50) 40x60 → 0.75 0.5 0.2 0.6; card is class 0.
        XCTAssertEqual(try read("labels/a.txt", in: out),
                       "1 0.750000 0.500000 0.200000 0.600000\n0 0.250000 0.500000 0.100000 0.200000\n")
        XCTAssertEqual(try read("labels/b.txt", in: out), "", "a negative is an empty label file")
        XCTAssertEqual(try read("classes.txt", in: out), "card\ncoin\n")
        XCTAssertTrue(try read("data.yaml", in: out).contains("names:\n  0: 'card'\n  1: 'coin'\n"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("images/a.png").path))
        XCTAssertEqual(report.files, ["data.yaml", "classes.txt", "labels/", "images/"])
    }

    func testCOCOExportUsesTopLeftBoxesAndOneBasedIDs() throws {
        let (out, _) = try export(.coco, to: "coco")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: out.appendingPathComponent("_annotations.coco.json"))) as? [String: Any])
        let images = try XCTUnwrap(json["images"] as? [[String: Any]])
        XCTAssertEqual(images.map { $0["file_name"] as? String }, ["a.png", "b.png"])
        XCTAssertEqual(images[0]["width"] as? Int, 200)
        XCTAssertEqual(images[0]["id"] as? Int, 1)
        let annotations = try XCTUnwrap(json["annotations"] as? [[String: Any]])
        XCTAssertEqual(annotations[0]["bbox"] as? [Double], [130, 20, 40, 60])   // coin, top-left corner
        XCTAssertEqual(annotations[0]["category_id"] as? Int, 2)
        let categories = try XCTUnwrap(json["categories"] as? [[String: Any]])
        XCTAssertEqual(categories.map { $0["name"] as? String }, ["card", "coin"])
    }

    func testHuggingFaceExportIsAnImageFolderWithACard() throws {
        let (out, _) = try export(.huggingface, to: "hf")
        let rows = try read("train/metadata.jsonl", in: out).split(separator: "\n").map(String.init)
        XCTAssertEqual(rows, [
            #"{"file_name":"images/a.png","objects":{"bbox":[[130,20,40,60],[40,40,20,20]],"categories":["coin","card"]}}"#,
            #"{"file_name":"images/b.png","objects":{"bbox":[],"categories":[]}}"#,
        ])
        let card = try read("README.md", in: out)
        XCTAssertTrue(card.hasPrefix("---\npretty_name: 'dataset'\ntask_categories:\n- object-detection\n"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("train/images/a.png").path))
    }

    /// Coordinates are written at 2 decimals, never as a binary double's long tail.
    func testExportedCoordinatesAreShortDecimals() throws {
        var source = try document()
        source.records[0].boxes = [BoxRecord(label: "card", x: 100.33, y: 50.17, width: 20.03, height: 10.07)]
        try source.save()
        for (format, file) in [(DatasetFormat.coco, "_annotations.coco.json"), (.huggingface, "train/metadata.jsonl")] {
            let (out, _) = try export(format, to: "decimals-\(format.rawValue)")
            let text = try read(file, in: out)
            XCTAssertTrue(text.contains("20.03"), "\(format): the width as written")
            XCTAssertNil(text.range(of: #"\d\.\d{3,}"#, options: .regularExpression), "\(format): \(text)")
        }
    }

    func testExportWithoutImagesWritesOnlyAnnotations() throws {
        let (out, report) = try export(.yolo, to: "yolo-bare", copyImages: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("images").path))
        XCTAssertEqual(report.files, ["data.yaml", "classes.txt", "labels/"])
    }

    func testExportRefusesTheDatasetFolderAndNonEmptyFolders() throws {
        let source = try document()
        XCTAssertThrowsError(try DatasetExport.run(source, to: dataset, options: .init(format: .coco), pixelSize: { _ in nil }))
        let busy = root.appendingPathComponent("busy")
        try write("x", to: busy.appendingPathComponent("keep.txt"))
        XCTAssertThrowsError(try DatasetExport.run(source, to: busy, options: .init(format: .coco), pixelSize: { _ in nil }))
        XCTAssertEqual(try read("keep.txt", in: busy), "x")
    }

    func testYOLOExportRefusesImagesThatWouldShareALabelFile() throws {
        try image("a.jpg", 10, 10, in: dataset)
        var source = try document()
        source.records.append(ImageAnnotationRecord(image: "a.jpg", boxes: []))
        XCTAssertThrowsError(try DatasetExport.run(
            source, to: root.appendingPathComponent("clash"), options: .init(format: .yolo),
            pixelSize: { source.pixelSize(of: $0) }))
    }

    // MARK: - Reading other people's layouts

    /// Ultralytics layout: images/<split>/ and labels/<split>/, names in data.yaml.
    func testYOLOSplitLayoutWithPolygonsAndBackgroundImages() throws {
        let yolo = root.appendingPathComponent("yolo-in")
        try image("one.png", 100, 100, in: yolo.appendingPathComponent("images/train"))
        try image("two.png", 100, 100, in: yolo.appendingPathComponent("images/val"))
        try image("empty.png", 100, 100, in: yolo.appendingPathComponent("images/train"))
        try write("0 0.5 0.5 0.2 0.4\n\n2 0.1 0.1 0.1 0.1\n", to: yolo.appendingPathComponent("labels/train/one.txt"))
        // A segmentation row: the box around the polygon (0.2..0.6, 0.3..0.9).
        try write("1 0.2 0.3 0.6 0.3 0.6 0.9 0.2 0.9\n", to: yolo.appendingPathComponent("labels/val/two.txt"))
        try write("path: .\ntrain: images/train\nnames:\n  0: cat\n  1: 'dog'\n", to: yolo.appendingPathComponent("data.yaml"))
        try write("not a label file", to: yolo.appendingPathComponent("README.txt"))

        let foreign = try ForeignDatasetReader.read(at: yolo)
        XCTAssertEqual(foreign.format, .yolo)
        let byName = Dictionary(uniqueKeysWithValues: foreign.images.map { ($0.source.lastPathComponent, $0.boxes) })
        XCTAssertEqual(Set(byName.keys), ["one.png", "two.png", "empty.png"])
        XCTAssertEqual(byName["empty.png"], [], "an image with no label file is a background image")
        XCTAssertEqual(byName["one.png"]?.map(\.label), ["cat", "class_2"], "a class with no name still imports")
        guard case .normalized(let polygon)? = byName["two.png"]?.first?.geometry else { return XCTFail() }
        XCTAssertEqual(polygon.minX, 0.2, accuracy: 1e-9)
        XCTAssertEqual(polygon.minY, 0.3, accuracy: 1e-9)
        XCTAssertEqual(polygon.width, 0.4, accuracy: 1e-9)
        XCTAssertEqual(polygon.height, 0.6, accuracy: 1e-9)

        XCTAssertThrowsError(try {
            try self.write("0 0.5 0.5\n", to: yolo.appendingPathComponent("labels/train/one.txt"))
            _ = try ForeignDatasetReader.read(at: yolo)
        }(), "a malformed row is an error, not a skipped box")
    }

    /// Many YOLO downloads ship without their names file; the caller supplies it.
    func testClassNamesCanBeSuppliedForASourceThatHasOnlyIDs() throws {
        let yolo = root.appendingPathComponent("yolo-ids")
        try image("z.png", 100, 100, in: yolo)
        try write("1 0.5 0.5 0.2 0.2\n0 0.2 0.2 0.1 0.1\n", to: yolo.appendingPathComponent("z.txt"))
        XCTAssertEqual(try ForeignDatasetReader.read(at: yolo).images[0].boxes.map(\.label), ["class_1", "class_0"])

        let yaml = root.appendingPathComponent("names.yaml")
        try write("path: x\nnames:\n  0: person\n  1: zebra\ndownload: https://example.com/x.zip\n", to: yaml)
        let list = root.appendingPathComponent("names.txt")
        try write("person\n zebra \n\n", to: list)
        for file in [yaml, list] {
            let names = try ClassNames.read(file)
            XCTAssertEqual(names, ["person", "zebra"])
            XCTAssertEqual(try ForeignDatasetReader.read(at: yolo, classNames: names).images[0].boxes.map(\.label),
                           ["zebra", "person"])
        }
    }

    func testClassNameShapes() {
        XCTAssertEqual(ClassNames.parseYAML("nc: 2\nnames: ['cat', \"dog\"]\n"), ["cat", "dog"])
        XCTAssertEqual(ClassNames.parseYAML("names:\n- cat\n- dog\nother: 1\n"), ["cat", "dog"])
        XCTAssertEqual(ClassNames.parseYAML("names:\n  0: cat\n  2: bird\ntrain: x\n"), ["cat", "class_1", "bird"])
        XCTAssertEqual(ClassNames.parseYAML("""
        dataset_info:
          features:
          - name: objects
            sequence:
            - name: category
              dtype:
                class_label:
                  names:
                    '0': card
                    '1': coin
        """), ["card", "coin"])
        XCTAssertEqual(ClassNames.parseYAML("train: images\n"), [])
    }

    func testHuggingFaceIntegerCategoriesTakeNamesFromTheCard() throws {
        let hf = root.appendingPathComponent("hf-in")
        try image("x.png", 100, 100, in: hf.appendingPathComponent("train"))
        try write(#"{"file_name": "x.png", "objects": {"bbox": [[10, 20, 30, 40]], "category": [1]}}"# + "\n"
            + #"{"file_name": "gone.png", "objects": {"bbox": [], "category": []}}"# + "\n",
            to: hf.appendingPathComponent("train/metadata.jsonl"))
        try write("---\ndataset_info:\n  names:\n    '0': card\n    '1': coin\n---\n", to: hf.appendingPathComponent("README.md"))

        let foreign = try ForeignDatasetReader.read(at: hf)
        XCTAssertEqual(foreign.format, .huggingface)
        XCTAssertEqual(foreign.images.map(\.boxes), [[
            ImportedBox(label: "coin", geometry: .pixels(CGRect(x: 10, y: 20, width: 30, height: 40))),
        ]])
        XCTAssertEqual(foreign.missingImages, ["gone.png"])
    }

    /// A downloaded dataset is untrusted: a row must not be able to name a file
    /// outside it (or a non-image inside it) and have it copied into yours.
    func testHuggingFaceRowsCannotReachOutsideTheDataset() throws {
        let hf = root.appendingPathComponent("hf-evil")
        try image("ok.png", 50, 50, in: hf.appendingPathComponent("train"))
        try image("secret.png", 50, 50, in: root.appendingPathComponent("elsewhere"))
        try write("secret", to: hf.appendingPathComponent("train/notes.txt"))
        let outside = root.appendingPathComponent("elsewhere/secret.png").path
        try write([
            #"{"file_name": "ok.png", "objects": {"bbox": [], "categories": []}}"#,
            #"{"file_name": "../../elsewhere/secret.png", "objects": {"bbox": [], "categories": []}}"#,
            "{\"file_name\": \"\(outside)\", \"objects\": {\"bbox\": [], \"categories\": []}}",
            #"{"file_name": "notes.txt", "objects": {"bbox": [], "categories": []}}"#,
        ].joined(separator: "\n") + "\n", to: hf.appendingPathComponent("train/metadata.jsonl"))

        let foreign = try ForeignDatasetReader.read(at: hf)
        XCTAssertEqual(foreign.images.map(\.source.lastPathComponent), ["ok.png"])
        XCTAssertEqual(foreign.missingImages.count, 3)

        let target = root.appendingPathComponent("safe")
        try importing(hf, into: target)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path).sorted(),
                       ["annotations.json", "ok.png"])
    }

    func testCOCOFileFindsItsImagesInASiblingFolder() throws {
        let coco = root.appendingPathComponent("coco-in")
        try image("p.png", 100, 100, in: coco.appendingPathComponent("train2017"))
        try write(#"""
        {"images":[{"id":1,"file_name":"p.png","width":100,"height":100},{"id":2,"file_name":"absent.png"}],
         "categories":[{"id":1,"name":"cat"}],
         "annotations":[{"id":1,"image_id":1,"category_id":1,"bbox":[10,20,30,40]}]}
        """#, to: coco.appendingPathComponent("annotations/instances_train2017.json"))

        for source in [coco, coco.appendingPathComponent("annotations/instances_train2017.json")] {
            let foreign = try ForeignDatasetReader.read(at: source, format: source == coco ? nil : .coco)
            XCTAssertEqual(foreign.images.map(\.source.lastPathComponent), ["p.png"])
            XCTAssertEqual(foreign.missingImages, ["absent.png"])
        }
    }

    func testUnrecognisableFolderIsAUsageError() throws {
        let empty = root.appendingPathComponent("nothing")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ForeignDatasetReader.read(at: empty)) {
            XCTAssertEqual(($0 as? ForeignDatasetError)?.isUsage, true)
        }
        XCTAssertThrowsError(try ForeignDatasetReader.read(at: root.appendingPathComponent("absent"))) {
            XCTAssertEqual(($0 as? ForeignDatasetError)?.isUsage, true)
        }
    }

    // MARK: - Import behaviour

    func testImportingTwiceChangesNothing() throws {
        let (out, _) = try export(.yolo, to: "yolo")
        let target = root.appendingPathComponent("twice")
        try importing(out, into: target)
        let first = try Data(contentsOf: target.appendingPathComponent("annotations.json"))

        let again = try importing(out, into: target)
        XCTAssertEqual(again.images, .init(found: 2, copied: 0, alreadyPresent: 2))
        XCTAssertEqual(again.boxes.added, 0)
        XCTAssertEqual(again.boxes.duplicates, 2)
        XCTAssertFalse(again.written)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("annotations.json")), first)
    }

    /// A different picture that happens to share a name must not be overwritten,
    /// and the boxes must follow the copy to its new name.
    func testNameTakenByADifferentImageGetsANewNameAndItsBoxes() throws {
        let (out, _) = try export(.coco, to: "coco")
        let target = root.appendingPathComponent("taken")
        try image("a.png", 640, 480, in: target)
        let before = try Data(contentsOf: target.appendingPathComponent("a.png"))

        let report = try importing(out, into: target)
        XCTAssertEqual(report.renamed, [.init(from: "a.png", to: "a-2.png")])
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("a.png")), before)
        let records = try document(target).records
        XCTAssertEqual(records.first { $0.image == "a-2.png" }?.boxes.count, 2)
        XCTAssertNil(records.first { $0.image == "a.png" })
    }

    func testNegativesAreOnlyRecordedWhenAsked() throws {
        let (out, _) = try export(.yolo, to: "yolo")
        let target = root.appendingPathComponent("no-negatives")
        try importing(out, into: target, options: .init())
        XCTAssertEqual(try document(target).records.map(\.image), ["a.png"])
        XCTAssertEqual(try document(target).imagesOnDisk, ["a.png", "b.png"], "the image is still copied")
    }

    func testASourceWithAnUnusableBoxImportsNothingUnlessLenient() throws {
        let yolo = root.appendingPathComponent("bad")
        try image("good.png", 100, 100, in: yolo)
        try image("bad.png", 100, 100, in: yolo)
        try write("0 0.5 0.5 0.2 0.2\n", to: yolo.appendingPathComponent("good.txt"))
        try write("0 5.0 5.0 0.2 0.2\n", to: yolo.appendingPathComponent("bad.txt"))   // far outside the image
        try write("thing\n", to: yolo.appendingPathComponent("classes.txt"))

        let strict = root.appendingPathComponent("strict")
        let refused = try importing(yolo, into: strict)
        XCTAssertEqual(refused.problems.count, 1)
        XCTAssertFalse(refused.written)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: strict.path), [], "nothing copied, nothing written")

        let lenient = root.appendingPathComponent("lenient")
        let applied = try importing(yolo, into: lenient, options: .init(lenient: true))
        XCTAssertTrue(applied.written)
        XCTAssertEqual(try document(lenient).records.map(\.image), ["good.png"])
    }

    func testDryRunTouchesNothing() throws {
        let (out, _) = try export(.huggingface, to: "hf")
        let target = root.appendingPathComponent("dry")
        let report = try importing(out, into: target, options: .init(recordNegatives: true, dryRun: true))
        XCTAssertEqual(report.images.copied, 2)
        XCTAssertEqual(report.boxes.added, 2)
        XCTAssertFalse(report.written)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }
}
