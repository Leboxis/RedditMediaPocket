import XCTest
@testable import MediaCore

final class DownloadIntegrityTests: XCTestCase {
    func testReplacementPublishesPreparedFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("media.mp4")
        let prepared = folder.appendingPathComponent(".prepared.mp4")
        try Data("original".utf8).write(to: original)
        try Data("tagged".utf8).write(to: prepared)
        try MediaFileReplacement.replace(original, with: prepared)
        XCTAssertEqual(try Data(contentsOf: original), Data("tagged".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.path))
    }

    func testFailedReplacementKeepsOriginal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("media.mp4")
        try Data("original".utf8).write(to: original)
        XCTAssertThrowsError(try MediaFileReplacement.replace(original, with: folder.appendingPathComponent(".missing.mp4")))
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
    }

    func testGalleryNetworkFailureDoesNotBecomeEmptyMedia() async throws {
        do {
            _ = try await GalleryFeed.resolve { throw URLError(.timedOut) }
            XCTFail("A timeout must leave the page retryable")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        do {
            _ = try await GalleryFeed.resolve { throw NetworkError.refused(503) }
            XCTFail("A server outage must leave the page retryable")
        } catch NetworkError.refused(let code) { XCTAssertEqual(code, 503) }
    }

    func testMissingGalleryCanBeSkipped() async throws {
        let media = try await GalleryFeed.resolve { throw NetworkError.refused(404) }
        XCTAssertTrue(media.isEmpty)
    }

    func testGalleryCancellationAndRateLimitPropagate() async throws {
        do {
            _ = try await GalleryFeed.resolve { throw URLError(.cancelled) }
            XCTFail("Cancellation must propagate")
        } catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
        do {
            _ = try await GalleryFeed.resolve { throw NetworkError.limited(service: "Reddit", until: nil) }
            XCTFail("Rate limits must propagate")
        } catch NetworkError.limited { }
    }

    func testSavedCollectionCountSurvivesRunWithoutNewDownloads() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([1]).write(to: folder.appendingPathComponent("existing.jpg"))
        XCTAssertEqual(try SavedMediaCount(folder: folder).count, 1)
        XCTAssertEqual(try SavedMediaCount(folder: folder).count, 1)
        try Data([2]).write(to: folder.appendingPathComponent("new.mp4"))
        XCTAssertEqual(try SavedMediaCount(folder: folder).count, 2)
    }
}
