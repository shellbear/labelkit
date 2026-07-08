import Foundation
import XCTest
@testable import LabelKit

final class RecentModelsTests: XCTestCase {
    var defaults: UserDefaults!
    var suiteName: String!
    var tempDir: URL!

    override func setUpWithError() throws {
        suiteName = "recentmodels-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("labelkit-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeModel(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data([0x00]).write(to: url)
        return url
    }

    func testRecordsNewestFirstDedupedAndCapped() throws {
        var models = RecentModels(defaults: defaults)
        let urls = try (1...RecentModels.maxCount + 2).map { try makeModel("m\($0).mlmodel") }
        urls.forEach { models.record($0) }

        // Newest first, capped at maxCount.
        XCTAssertEqual(models.urls.count, RecentModels.maxCount)
        XCTAssertEqual(models.urls.first, urls.last)

        // Re-recording an existing model moves it to the front without dupes.
        models.record(urls[urls.count - 3])
        XCTAssertEqual(models.urls.first, urls[urls.count - 3])
        XCTAssertEqual(Set(models.urls).count, models.urls.count)
    }

    func testDropsModelsThatNoLongerExist() throws {
        let models = RecentModels(defaults: defaults)
        let present = try makeModel("here.mlmodel")
        let gone = try makeModel("gone.mlmodel")
        models.record(present)
        models.record(gone)
        try FileManager.default.removeItem(at: gone)

        XCTAssertEqual(models.urls, [present])   // the deleted file silently drops
    }
}
