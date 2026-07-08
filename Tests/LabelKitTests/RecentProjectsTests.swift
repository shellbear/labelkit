import XCTest
@testable import LabelKit

final class RecentProjectsTests: XCTestCase {
    var suiteName: String!
    var defaults: UserDefaults!
    var recents: RecentProjects!

    override func setUpWithError() throws {
        suiteName = "labelkit-recents-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        recents = RecentProjects(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func location(_ name: String) -> DatasetLocation {
        let directory = URL(fileURLWithPath: "/tmp/\(name)")
        return DatasetLocation(
            imagesDirectory: directory,
            annotationsURL: directory.appendingPathComponent("annotations.json"),
            annotationsExists: false
        )
    }

    func testEmptyByDefault() {
        XCTAssertTrue(recents.locations.isEmpty)
    }

    func testRecordsNewestFirst() {
        recents.record(location("a"))
        recents.record(location("b"))
        XCTAssertEqual(recents.locations.map(\.displayName), ["b", "a"])
    }

    func testReopeningMovesToFrontWithoutDuplicate() {
        recents.record(location("a"))
        recents.record(location("b"))
        recents.record(location("a"))
        XCTAssertEqual(recents.locations.map(\.displayName), ["a", "b"])
    }

    func testCappedAtMaxCount() {
        for index in 0..<(RecentProjects.maxCount + 3) {
            recents.record(location("dataset-\(index)"))
        }
        let names = recents.locations.map(\.displayName)
        XCTAssertEqual(names.count, RecentProjects.maxCount)
        XCTAssertEqual(names.first, "dataset-7")
        XCTAssertEqual(names.last, "dataset-3")
    }

    func testSameDirectoryDifferentAnnotationsAreDistinct() {
        let directory = URL(fileURLWithPath: "/tmp/shared")
        let first = DatasetLocation(
            imagesDirectory: directory,
            annotationsURL: directory.appendingPathComponent("train.json"),
            annotationsExists: false)
        let second = DatasetLocation(
            imagesDirectory: directory,
            annotationsURL: directory.appendingPathComponent("test.json"),
            annotationsExists: false)
        recents.record(first)
        recents.record(second)
        XCTAssertEqual(recents.locations.map(\.annotationsURL.lastPathComponent),
                       ["test.json", "train.json"])
    }

    func testAnnotationsExistsRecomputedAtReadTime() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("labelkit-recents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let annotations = directory.appendingPathComponent("annotations.json")

        recents.record(DatasetLocation(
            imagesDirectory: directory, annotationsURL: annotations, annotationsExists: false))
        XCTAssertEqual(recents.locations.first?.annotationsExists, false)

        try Data("[]".utf8).write(to: annotations)
        XCTAssertEqual(recents.locations.first?.annotationsExists, true)
    }

    func testClearRemovesEverything() {
        recents.record(location("a"))
        recents.clear()
        XCTAssertTrue(recents.locations.isEmpty)
    }

    func testIgnoresMalformedStoredEntries() {
        defaults.set([["imagesDirectory": "/tmp/only-dir"], "garbage"], forKey: "recentProjects")
        XCTAssertTrue(recents.locations.isEmpty)
    }
}
