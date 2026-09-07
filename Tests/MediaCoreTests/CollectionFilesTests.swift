import XCTest
@testable import MediaCore

final class CollectionFilesTests: XCTestCase {
    func testFiltersMediaAndCountsOnlyRegularVisibleFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, size) in [("photo.JPG", 3), ("video.mp4", 5), (".hidden.jpg", 7), ("metadata.json", 11)] {
            try Data(repeating: 0, count: size).write(to: folder.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("folder.png"), withIntermediateDirectories: true)
        let snapshot = try CollectionFiles.scan(folder)
        XCTAssertEqual(Set(snapshot.files.map(\.lastPathComponent)), ["photo.JPG", "video.mp4"])
        XCTAssertEqual(snapshot.totalBytes, 8)
    }

    func testMissingFolderProducesEmptySnapshot() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let snapshot = try CollectionFiles.scan(folder)
        XCTAssertTrue(snapshot.files.isEmpty)
        XCTAssertEqual(snapshot.totalBytes, 0)
    }

    func testCancelledScanDoesNotPublishPartialResults() async {
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try CollectionFiles.scan(FileManager.default.temporaryDirectory)
        }
        do {
            _ = try await worker.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
