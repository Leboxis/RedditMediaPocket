import XCTest
@testable import MediaCore

final class LanguageAndMetadataTests: XCTestCase {
    func testDeviceLanguageSelection() {
        XCTAssertEqual(AppLanguage.detect(["fr-FR"]), "fr")
        XCTAssertEqual(AppLanguage.detect(["fr_CA", "en"]), "fr")
        XCTAssertEqual(AppLanguage.detect(["en-GB", "fr"]), "en")
        XCTAssertEqual(AppLanguage.detect(["de-DE", "fr"]), "en")
        XCTAssertEqual(AppLanguage.detect([]), "en")
    }

    func testFirstLaunchPreservesExplicitChoiceOnLaterLaunches() throws {
        let suite = "LanguageTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AppLanguage.initialize(defaults: defaults, preferredLanguages: ["fr-CA"])
        XCTAssertEqual(defaults.string(forKey: AppLanguage.defaultsKey), "fr")
        defaults.set("en", forKey: AppLanguage.defaultsKey)
        AppLanguage.initialize(defaults: defaults, preferredLanguages: ["fr-FR"])
        XCTAssertEqual(defaults.string(forKey: AppLanguage.defaultsKey), "en")
    }

    func testPublicationDatesDoNotUseUpdatedDate() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry><id>t3_one</id><title>One</title><published>2026-09-01T12:34:56Z</published><updated>2026-09-02T00:00:00Z</updated></entry>
          <entry><id>t3_two</id><published>2026-09-01T12:34:56.123+02:00</published></entry>
          <entry><id>t3_three</id><updated>2026-09-02T00:00:00Z</updated></entry>
          <entry><id>t3_four</id><published>invalid</published></entry>
        </feed>
        """
        let posts = try FeedParser.parse(Data(xml.utf8))
        XCTAssertEqual(posts.count, 4)
        XCTAssertEqual(posts[0].publishedAt, ISO8601DateFormatter().date(from: "2026-09-01T12:34:56Z"))
        let first = try XCTUnwrap(posts[0].publishedAt)
        let second = try XCTUnwrap(posts[1].publishedAt)
        XCTAssertEqual(first.timeIntervalSince(second), 7199.877, accuracy: 0.001)
        XCTAssertNil(posts[2].publishedAt)
        XCTAssertNil(posts[3].publishedAt)
    }

    func testMetadataSurvivesRelaunchRenameAndDeletion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.mp4")
        let target = folder.appendingPathComponent("renamed.mp4")
        XCTAssertNil(MediaMetadata.read(for: source))
        let dates = MediaMetadata(downloadedAt: Date(timeIntervalSince1970: 1_700_000_000), postDate: nil)
        XCTAssertTrue(dates.save(for: source))
        XCTAssertEqual(MediaMetadata.read(for: source), dates)
        try Data().write(to: target)
        MediaMetadata.move(from: source, to: target)
        XCTAssertNil(MediaMetadata.read(for: source))
        XCTAssertEqual(MediaMetadata.read(for: target), dates)
        MediaMetadata.remove(for: target)
        XCTAssertNil(MediaMetadata.read(for: target))
    }
}
