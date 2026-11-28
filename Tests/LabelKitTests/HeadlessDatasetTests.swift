import CoreGraphics
import XCTest
@testable import LabelKit

/// The headless path behind `annotate`, `stats` and `validate`. Everything is
/// exercised through a real dataset directory on disk so the tests cover what
/// a scripted caller actually gets, including the bytes that are saved.
final class HeadlessDatasetTests: XCTestCase {
    var tempDir: URL!
    let imageSize = CGSize(width: 200, height: 100)

    /// 2-space, canonical: exactly what labelkit itself writes.
    let canonical = """
    [
      {
        "image": "b.jpg",
        "annotations": [
          {
            "label": "card",
            "coordinates": {
              "x": 50,
              "y": 50,
              "width": 20,
              "height": 20
            },
            "score": 0.5
          }
        ],
        "imageWidth": 200
      },
      {
        "image": "a.jpg",
        "annotations": []
      },
      {
        "image": "ghost.jpg",
        "annotations": [
          {
            "label": "card",
            "coordinates": {
              "x": 5,
              "y": 5,
              "width": 2,
              "height": 2
            }
          }
        ]
      }
    ]

    """

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("labelkit-headless-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        for name in ["a.jpg", "b.jpg", "c.jpg", "d.jpg"] {
            try Data([0xFF]).write(to: tempDir.appendingPathComponent(name))
        }
        try Data(canonical.utf8).write(to: annotationsURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    var annotationsURL: URL { tempDir.appendingPathComponent("annotations.json") }

    func load() throws -> DatasetDocument {
        try DatasetDocument(location: XCTUnwrap(DatasetLocator.resolve(path: tempDir.path)))
    }

    func savedText() throws -> String {
        String(decoding: try Data(contentsOf: annotationsURL), as: UTF8.self)
    }

    /// Every image is 200x100 except `ghost.jpg`, which isn't on disk.
    func size(_ name: String) -> CGSize? { name == "ghost.jpg" ? nil : imageSize }

    func pixels(_ label: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> ImportedBox {
        ImportedBox(label: label, geometry: .pixels(CGRect(x: x, y: y, width: w, height: h)))
    }

    // MARK: - Document

    func testLoadThenSaveIsByteIdentical() throws {
        let document = try load()
        try document.save()
        XCTAssertEqual(try savedText(), canonical)
    }

    func testSaveKeepsTheFilesOwnIndentation() throws {
        let fourSpace = canonical.replacingOccurrences(of: "  ", with: "    ")
        try Data(fourSpace.utf8).write(to: annotationsURL)
        var document = try load()
        _ = AnnotationMerge.apply([ImportedImage(image: "c.jpg", boxes: [pixels("card", 10, 10, 30, 30)])],
                                  to: &document, pixelSize: size)
        try document.save()
        let saved = try savedText()
        XCTAssertTrue(saved.hasPrefix("[\n    {\n        \"image\": \"b.jpg\""))
        XCTAssertTrue(saved.contains("\n    {\n        \"image\": \"c.jpg\""))
    }

    func testDocumentWithoutAnnotationsFileStartsEmpty() throws {
        try FileManager.default.removeItem(at: annotationsURL)
        let document = try load()
        XCTAssertTrue(document.records.isEmpty)
        XCTAssertEqual(document.imagesOnDisk, ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        XCTAssertEqual(String(decoding: document.serialized(), as: UTF8.self), "[]\n")
    }

    /// `annotate` names the images it cares about, so the dataset opens by
    /// checking those instead of listing the folder — with the same answers.
    func testOpeningForSpecificImagesChecksThemInsteadOfListingTheFolder() throws {
        let location = try XCTUnwrap(DatasetLocator.resolve(path: tempDir.path))
        let outside = tempDir.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).jpg")
        try Data([0xFF]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        try Data([0xFF]).write(to: tempDir.appendingPathComponent(".hidden.jpg"))
        let document = try DatasetDocument(
            location: location,
            onlyImages: ["c.jpg", "nope.jpg", "c.jpg", "a.jpg", "../\(outside.lastPathComponent)",
                         "A.JPG", "C.jpg", "annotations.json", ".hidden.jpg"])
        XCTAssertEqual(document.imagesOnDisk, ["c.jpg", "a.jpg"],
                       "what a listing would return: images, spelled as stored, not hidden, in this folder")
        XCTAssertEqual(document.records.count, 3, "the annotations file is still read in full")

        // Past the threshold it falls back to a normal listing.
        let many = (0...DatasetDocument.listingThreshold).map { "img\($0).jpg" }
        XCTAssertEqual(try DatasetDocument(location: location, onlyImages: many).imagesOnDisk,
                       ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
    }

    func testImagesDirectoryIsRecognisedHoweverItIsSpelled() throws {
        let document = try load()
        XCTAssertTrue(document.isImagesDirectory(tempDir))
        XCTAssertTrue(document.isImagesDirectory(URL(fileURLWithPath: tempDir.path + "/")))
        XCTAssertTrue(document.isImagesDirectory(tempDir.appendingPathComponent("sub/..")))
        let link = tempDir.deletingLastPathComponent().appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tempDir)
        defer { try? FileManager.default.removeItem(at: link) }
        XCTAssertTrue(document.isImagesDirectory(link))

        XCTAssertFalse(document.isImagesDirectory(tempDir.appendingPathComponent("renders")), "a subfolder is fine")
        XCTAssertFalse(document.isImagesDirectory(tempDir.deletingLastPathComponent()))
    }

    // MARK: - Merge: add

    func testAddWritesCentreAnchoredCoordinatesAndAppendsNewEntriesInNameOrder() throws {
        var document = try load()
        let result = AnnotationMerge.apply([
            ImportedImage(image: "d.jpg", boxes: [pixels("coin", 10, 20, 40, 60)]),
            ImportedImage(image: "c.jpg", boxes: [pixels("card", 0, 0, 100, 50)]),
        ], to: &document, pixelSize: size)

        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertTrue(result.changed)
        // Existing order untouched; newcomers appended by name, not input order.
        XCTAssertEqual(document.records.map(\.image), ["b.jpg", "a.jpg", "ghost.jpg", "c.jpg", "d.jpg"])
        let coin = try XCTUnwrap(document.records.last?.boxes.first)
        XCTAssertEqual([coin.x, coin.y, coin.width, coin.height], [30, 50, 40, 60])
        XCTAssertEqual(result.outcomes.map(\.image), ["d.jpg", "c.jpg"])
        XCTAssertEqual(result.outcomes.map(\.created), [true, true])
    }

    func testAddIsIdempotentDownToTheBytes() throws {
        let input = [
            ImportedImage(image: "b.jpg", boxes: [pixels("card", 100, 10, 50.005, 40)]),
            ImportedImage(image: "c.jpg", boxes: [pixels("coin", 10, 20, 40, 60)]),
        ]
        var first = try load()
        _ = AnnotationMerge.apply(input, to: &first, pixelSize: size)
        try first.save()
        let afterFirst = try savedText()

        var second = try load()
        let result = AnnotationMerge.apply(input, to: &second, pixelSize: size)
        try second.save()

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.outcomes.map(\.added), [0, 0])
        XCTAssertEqual(result.outcomes.map(\.duplicates), [1, 1])
        XCTAssertEqual(try savedText(), afterFirst)
    }

    func testAddKeepsExistingBoxesAndTheirUnknownKeys() throws {
        var document = try load()
        _ = AnnotationMerge.apply([ImportedImage(image: "b.jpg", boxes: [pixels("coin", 120, 10, 30, 30)])],
                                  to: &document, pixelSize: size)
        try document.save()
        let saved = try savedText()
        XCTAssertTrue(saved.contains("\"score\": 0.5"))
        XCTAssertTrue(saved.contains("\"imageWidth\": 200"))
        XCTAssertEqual(document.records[0].boxes.map(\.label), ["card", "coin"])
    }

    func testAddSkipsABoxThatAlreadyExistsButNotADifferentLabelInTheSamePlace() throws {
        var document = try load()
        // b.jpg already has card centred at 50,50 size 20 → top-left 40,40.
        let result = AnnotationMerge.apply([ImportedImage(image: "b.jpg", boxes: [
            pixels("card", 41, 40, 20, 20),   // same box, a pixel off
            pixels("coin", 40, 40, 20, 20),   // same place, different label
        ])], to: &document, pixelSize: size)
        XCTAssertEqual(result.outcomes.first?.duplicates, 1)
        XCTAssertEqual(result.outcomes.first?.added, 1)
        XCTAssertEqual(document.records[0].boxes.map(\.label), ["card", "coin"])
    }

    func testAddDeduplicatesWithinTheInputItself() throws {
        var document = try load()
        let result = AnnotationMerge.apply([
            ImportedImage(image: "c.jpg", boxes: [pixels("card", 10, 10, 50, 50)]),
            ImportedImage(image: "c.jpg", boxes: [pixels("card", 10, 10, 50, 50)]),
        ], to: &document, pixelSize: size)
        XCTAssertEqual(result.outcomes.count, 1)
        XCTAssertEqual(result.outcomes.first?.added, 1)
        XCTAssertEqual(result.outcomes.first?.duplicates, 1)
    }

    func testNormalizedBoxesScaleToTheImage() throws {
        var document = try load()
        let box = ImportedBox(label: "card", geometry: .normalized(CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)))
        _ = AnnotationMerge.apply([ImportedImage(image: "c.jpg", boxes: [box])], to: &document, pixelSize: size)
        let saved = try XCTUnwrap(document.records.last?.boxes.first)
        // 200x100 image → top-left 50,50 size 100x25 → centre 100,62.5.
        XCTAssertEqual([saved.x, saved.y, saved.width, saved.height], [100, 62.5, 100, 25])
    }

    func testPixelsOfAResizedCopyAreScaledToTheRealImage() throws {
        var document = try load()
        // The model saw a 100x50 copy of the 200x100 image: everything doubles.
        let seen = ImportedBox(label: "card", geometry: .scaledPixels(
            CGRect(x: 10, y: 5, width: 40, height: 20), reference: CGSize(width: 100, height: 50)))
        // Stated size equals the real size: the numbers are used exactly.
        let exact = ImportedBox(label: "coin", geometry: .scaledPixels(
            CGRect(x: 100.25, y: 50.5, width: 33.33, height: 20), reference: imageSize))
        _ = AnnotationMerge.apply([ImportedImage(image: "c.jpg", boxes: [seen, exact])],
                                  to: &document, pixelSize: size)
        let saved = try XCTUnwrap(document.records.last?.boxes)
        XCTAssertEqual([saved[0].x, saved[0].y, saved[0].width, saved[0].height], [60, 30, 80, 40])
        XCTAssertEqual(saved[1].width, 33.33)
        XCTAssertEqual(saved[1].x, 116.92, "records hold the 2-decimal values the file will hold")
    }

    func testBoxHangingOverAnEdgeIsClampedAndCounted() throws {
        var document = try load()
        let result = AnnotationMerge.apply(
            [ImportedImage(image: "c.jpg", boxes: [pixels("card", 150, 50, 100, 100)])],
            to: &document, pixelSize: size)
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertEqual(result.outcomes.first?.clamped, 1)
        let saved = try XCTUnwrap(document.records.last?.boxes.first)
        XCTAssertEqual([saved.x, saved.y, saved.width, saved.height], [175, 75, 50, 50])
    }

    // MARK: - Merge: problems

    func testUnknownImageAndUnusableBoxesAreProblemsNotWrites() throws {
        var document = try load()
        let result = AnnotationMerge.apply([
            ImportedImage(image: "nope.jpg", boxes: [pixels("card", 0, 0, 10, 10)]),
            ImportedImage(image: "c.jpg", boxes: [
                pixels("card", 500, 500, 10, 10),   // outside the 200x100 image
                pixels("card", 10, 10, 0, 10),      // no area
                pixels("  ", 10, 10, 10, 10),       // no label
            ]),
        ], to: &document, pixelSize: size)

        XCTAssertEqual(result.problems.map(\.image), ["nope.jpg", "c.jpg", "c.jpg", "c.jpg"])
        XCTAssertTrue(result.problems[1].message.contains("outside the image"))
        XCTAssertTrue(result.problems[2].message.contains("positive"))
        XCTAssertTrue(result.problems[3].message.contains("empty label"))
        XCTAssertFalse(result.changed)
        XCTAssertFalse(document.records.contains { $0.image == "c.jpg" })
    }

    func testNormalizedBoxOnAnUnreadableImageIsAProblem() throws {
        var document = try load()
        let box = ImportedBox(label: "card", geometry: .normalized(CGRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        let result = AnnotationMerge.apply([ImportedImage(image: "ghost.jpg", boxes: [box])],
                                           to: &document, pixelSize: size)
        XCTAssertEqual(result.problems.count, 1)
        XCTAssertFalse(result.changed)
    }

    // MARK: - Merge: replace and negatives

    func testReplaceSwapsOnlyTheListedImages() throws {
        var document = try load()
        let result = AnnotationMerge.apply(
            [ImportedImage(image: "b.jpg", boxes: [pixels("coin", 0, 0, 10, 10)])],
            to: &document, options: .init(mode: .replace), pixelSize: size)
        XCTAssertEqual(result.outcomes.first?.removed, 1)
        XCTAssertEqual(result.outcomes.first?.added, 1)
        XCTAssertEqual(document.records[0].boxes.map(\.label), ["coin"])
        XCTAssertEqual(document.records[0].extras["imageWidth"], .number(200))
        XCTAssertEqual(document.records[2].boxes.count, 1, "ghost.jpg untouched")
    }

    /// `detect … | annotate --mode replace` lists every image, including the
    /// ones where the detector found nothing. Those must not be wiped.
    func testReplaceWithNoBoxesLeavesTheImageAloneUnlessNegativesAreAsked() throws {
        var untouched = try load()
        let skipped = AnnotationMerge.apply([ImportedImage(image: "b.jpg", boxes: [])],
                                            to: &untouched, options: .init(mode: .replace), pixelSize: size)
        XCTAssertFalse(skipped.changed)
        XCTAssertTrue(skipped.outcomes.isEmpty)
        XCTAssertEqual(untouched.records[0].boxes.count, 1)

        var cleared = try load()
        let result = AnnotationMerge.apply(
            [ImportedImage(image: "b.jpg", boxes: [])], to: &cleared,
            options: .init(mode: .replace, recordNegatives: true), pixelSize: size)
        XCTAssertEqual(result.outcomes.first?.removed, 1)
        XCTAssertEqual(cleared.records.map(\.image), ["b.jpg", "a.jpg", "ghost.jpg"], "a negative, not a hole")
        XCTAssertTrue(cleared.records[0].boxes.isEmpty)
    }

    /// With --lenient the valid input is applied; an image whose every box was
    /// refused must not be emptied by a replace.
    func testReplaceLeavesAnImageAloneWhenAllItsBoxesWereRefused() throws {
        var document = try load()
        let result = AnnotationMerge.apply(
            [ImportedImage(image: "b.jpg", boxes: [pixels("card", 900, 900, 10, 10)])],
            to: &document, options: .init(mode: .replace, recordNegatives: true), pixelSize: size)
        XCTAssertEqual(result.problems.count, 1)
        XCTAssertFalse(result.changed)
        XCTAssertEqual(document.records[0].boxes.count, 1)
    }

    func testReplacingWithTheSameBoxesChangesNothing() throws {
        var document = try load()
        // b.jpg holds card centred 50,50 size 20x20 with an extra key; the same
        // geometry without the extra is a real change, the second run is not.
        let same = [ImportedImage(image: "b.jpg", boxes: [pixels("card", 40.001, 40.002, 20.003, 19.999)])]
        XCTAssertTrue(AnnotationMerge.apply(same, to: &document, options: .init(mode: .replace), pixelSize: size).changed)
        XCTAssertFalse(AnnotationMerge.apply(same, to: &document, options: .init(mode: .replace), pixelSize: size).changed)
    }

    // MARK: - Merge: boxes that must be refused

    func testNegativeSizesAreRefusedNotFlipped() throws {
        var document = try load()
        let result = AnnotationMerge.apply([ImportedImage(image: "c.jpg", boxes: [
            pixels("card", 100, 80, -50, -40),
            ImportedBox(label: "card", geometry: .normalized(CGRect(x: 0.5, y: 0.5, width: -0.2, height: 0.2))),
            ImportedBox(label: "card", geometry: .scaledPixels(
                CGRect(x: 10, y: 10, width: 20, height: -5), reference: CGSize(width: 100, height: 50))),
        ])], to: &document, pixelSize: size)
        XCTAssertEqual(result.problems.count, 3)
        XCTAssertTrue(result.problems.allSatisfy { $0.message.contains("positive") })
        XCTAssertFalse(result.changed)
    }

    /// A box that would round to zero on disk could never match itself again.
    func testBoxesSmallerThanAPixelAreRefused() throws {
        var document = try load()
        let result = AnnotationMerge.apply([ImportedImage(image: "c.jpg", boxes: [
            pixels("card", 10, 10, 0.004, 0.004),
            pixels("card", 10, 10, 50, 0.9),
            ImportedBox(label: "card", geometry: .normalized(CGRect(x: 0.1, y: 0.1, width: 0.001, height: 0.5))),
        ])], to: &document, pixelSize: size)
        XCTAssertEqual(result.problems.map(\.message), Array(repeating: "box #1 (card): smaller than one pixel", count: 1)
            + ["box #2 (card): smaller than one pixel", "box #3 (card): smaller than one pixel"])
        XCTAssertFalse(result.changed)
    }

    /// Coordinates tied to a copy's size can't be placed without the real size;
    /// writing them unscaled would be a guess.
    func testResizedCopyCoordinatesNeedAReadableImage() throws {
        var document = try load()
        let box = ImportedBox(label: "card", geometry: .scaledPixels(
            CGRect(x: 1, y: 1, width: 2, height: 2), reference: CGSize(width: 800, height: 600)))
        let result = AnnotationMerge.apply([ImportedImage(image: "ghost.jpg", boxes: [box])],
                                           to: &document, pixelSize: size)
        XCTAssertEqual(result.problems.count, 1)
        XCTAssertTrue(result.problems[0].message.contains("800x600"))
        XCTAssertFalse(result.changed)
    }

    func testAnImageWithNoBoxesIsOnlyRecordedAsANegativeWhenAsked() throws {
        var quiet = try load()
        let skipped = AnnotationMerge.apply([ImportedImage(image: "c.jpg", boxes: [])],
                                            to: &quiet, pixelSize: size)
        XCTAssertFalse(skipped.changed)
        XCTAssertTrue(skipped.outcomes.isEmpty)

        var explicit = try load()
        let recorded = AnnotationMerge.apply([ImportedImage(image: "c.jpg", boxes: [])],
                                             to: &explicit, options: .init(recordNegatives: true), pixelSize: size)
        XCTAssertTrue(recorded.changed)
        XCTAssertEqual(explicit.records.last?.image, "c.jpg")
        XCTAssertEqual(explicit.records.last?.boxes.count, 0)
    }

    // MARK: - Summary

    func testSummaryCountsEveryKindOfImage() throws {
        let summary = DatasetSummary.make(of: try load(), includePerImage: true, labelkitVersion: "test")
        XCTAssertEqual(summary.images, .init(total: 5, onDisk: 4, annotated: 2, negatives: 1, unlabeled: 2, missing: 1))
        XCTAssertEqual(summary.boxes, 2)
        XCTAssertEqual(summary.labels, [.init(label: "card", boxes: 2, images: 2)])
        XCTAssertEqual(summary.unlabeled, ["c.jpg", "d.jpg"])
        XCTAssertEqual(summary.missing, ["ghost.jpg"])
        XCTAssertEqual(summary.perImage?.map(\.status), [.negative, .annotated, .unlabeled, .unlabeled, .missing])
        XCTAssertEqual(summary.perImage?.map(\.image), ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "ghost.jpg"])
    }

    func testSummaryReportsTheBoxSpreadAndItsBusiestImage() throws {
        var document = try load()
        XCTAssertEqual(DatasetSummary.make(of: document).boxesPerImage,
                       .init(min: 1, median: 1, max: 1, maxImage: "b.jpg"))
        _ = AnnotationMerge.apply([ImportedImage(image: "c.jpg", boxes: [
            pixels("card", 0, 0, 10, 10), pixels("card", 50, 0, 10, 10), pixels("card", 100, 0, 10, 10),
            pixels("card", 150, 0, 10, 10),
        ])], to: &document, pixelSize: size)
        // Counts per annotated image are now 1 (b), 1 (ghost), 4 (c); a.jpg is a negative and excluded.
        XCTAssertEqual(DatasetSummary.make(of: document).boxesPerImage,
                       .init(min: 1, median: 1, max: 4, maxImage: "c.jpg"))

        var empty = document
        empty.records = []
        XCTAssertNil(DatasetSummary.make(of: empty).boxesPerImage)
    }

    func testSummaryOrdersLabelsByUseThenName() throws {
        var document = try load()
        _ = AnnotationMerge.apply([ImportedImage(image: "c.jpg", boxes: [
            pixels("zebra", 0, 0, 10, 10), pixels("apple", 20, 20, 10, 10),
        ])], to: &document, pixelSize: size)
        let summary = DatasetSummary.make(of: document)
        XCTAssertEqual(summary.labels.map(\.label), ["card", "apple", "zebra"])
        XCTAssertNil(summary.perImage)
    }

    // MARK: - Validate

    func testValidateFlagsWhatWouldBreakTraining() throws {
        var document = try load()
        document.records.append(ImageAnnotationRecord(image: "c.jpg", boxes: [
            BoxRecord(label: "card", x: 500, y: 500, width: 10, height: 10),   // outside
            BoxRecord(label: "card", x: 195, y: 50, width: 30, height: 20),    // overflows right edge
            BoxRecord(label: "card", x: 50, y: 50, width: 0, height: 10),      // no area
            BoxRecord(label: "", x: 20, y: 20, width: 10, height: 10),         // no label
            BoxRecord(label: "coin", x: 100, y: 50, width: 40, height: 40),
            BoxRecord(label: "coin", x: 100, y: 50, width: 40, height: 40),    // duplicate
        ]))
        document.records.append(ImageAnnotationRecord(image: "b.jpg", boxes: []))  // second entry for b.jpg

        let report = DatasetValidator.validate(document, labelkitVersion: "test", pixelSize: size)
        let found = report.issues.map { "\($0.code.rawValue)@\($0.image ?? "-")#\($0.box ?? 0)" }
        XCTAssertEqual(found, [
            "missing-image@ghost.jpg#0",
            "box-outside-image@c.jpg#1",
            "box-overflows-image@c.jpg#2",
            "empty-box@c.jpg#3",
            "empty-label@c.jpg#4",
            "duplicate-box@c.jpg#6",
            "duplicate-entry@b.jpg#0",
        ])
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.errors, 5)
        XCTAssertEqual(report.warnings, 2)
    }

    func testValidateAllowedLabels() throws {
        let report = DatasetValidator.validate(
            try load(), options: .init(allowedLabels: ["coin", "token"]), pixelSize: { _ in self.imageSize })
        let codes = report.issues.map(\.code)
        XCTAssertEqual(codes.filter { $0 == .unknownLabel }.count, 2)   // the two "card" boxes
        XCTAssertEqual(report.issues.filter { $0.code == .unusedLabel }.map(\.label), ["coin", "token"])
    }

    // MARK: - Duplicate images

    func testDuplicateImagesAreFoundByContentNotName() throws {
        let photo = Data((0..<4096).map { UInt8($0 % 251) })
        var other = photo
        other[100] = 0   // same size, one byte different
        try photo.write(to: tempDir.appendingPathComponent("a.jpg"))
        try photo.write(to: tempDir.appendingPathComponent("c.jpg"))
        try other.write(to: tempDir.appendingPathComponent("b.jpg"))
        try FileManager.default.createSymbolicLink(
            at: tempDir.appendingPathComponent("link.jpg"),
            withDestinationURL: tempDir.appendingPathComponent("a.jpg"))
        // d.jpg keeps its 1-byte contents from setUp: a size of its own.

        let groups = DuplicateImages.groups(
            in: tempDir, filenames: ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "link.jpg", "absent.jpg"])
        XCTAssertEqual(groups, [["a.jpg", "c.jpg", "link.jpg"]])
        XCTAssertEqual(DuplicateImages.groups(in: tempDir, filenames: ["b.jpg", "d.jpg"]), [])
    }

    func testValidateWarnsAboutDuplicateImagesAndSaysWhenLabelsConflict() throws {
        var document = try load()
        document.records.removeAll { $0.image == "ghost.jpg" }
        document.records.append(ImageAnnotationRecord(image: "c.jpg", boxes: document.records[0].boxes))
        let report = DatasetValidator.validate(
            document, options: .init(duplicateImages: [["b.jpg", "c.jpg", "a.jpg"]]), pixelSize: size)
        XCTAssertTrue(report.ok, "duplicates are warnings")
        XCTAssertEqual(report.issues.map(\.code), [.duplicateImage, .duplicateImage])
        XCTAssertEqual(report.issues.map(\.image), ["c.jpg", "a.jpg"])
        XCTAssertEqual(report.issues[0].message, "same file contents as 'b.jpg'")
        XCTAssertEqual(report.issues[1].message, "same file contents as 'b.jpg', and the two are labelled differently")
    }

    func testValidateAcleanDatasetIsOK() throws {
        var document = try load()
        document.records.removeAll { $0.image == "ghost.jpg" }
        let report = DatasetValidator.validate(document, pixelSize: size)
        XCTAssertTrue(report.ok)
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testUnreadableAnnotationsFileStillGetsAReport() throws {
        let location = try XCTUnwrap(DatasetLocator.resolve(path: tempDir.path))
        try Data(#"{"not": "an array"}"#.utf8).write(to: annotationsURL)
        XCTAssertThrowsError(try DatasetDocument(location: location))

        let report = ValidationReport.unreadable(location: location, reason: "not an array", labelkitVersion: "test")
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.errors, 1)
        XCTAssertEqual(report.issues.map(\.code), [.invalidAnnotationsFile])
        XCTAssertEqual(report.issues[0].message, "the annotations file can't be read: not an array")
    }

    func testValidateReportsAMissingAnnotationsFile() throws {
        try FileManager.default.removeItem(at: annotationsURL)
        let report = DatasetValidator.validate(try load(), pixelSize: size)
        XCTAssertEqual(report.issues.map(\.code), [.noAnnotationsFile])
        XCTAssertFalse(report.ok)
    }
}
