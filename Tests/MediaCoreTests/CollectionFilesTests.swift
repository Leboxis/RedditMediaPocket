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

    /// `scan` portait une liste d'extensions différente de celles de
    /// `BinaryMetadata`, `FilenamePolicy.xMediaID` et `xFetishMediaID` : un
    /// fichier `.m4v` était téléchargé et dédoublonné, mais invisible dans la
    /// galerie et absent des compteurs.
    func testEveryExtensionAcceptedByTheKeyPoliciesIsListed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = ["T - xm-42.jpg", "T - xmv-42.m4v", "A - xfv-7.m4v"]
        for name in names {
            try Data(repeating: 0, count: 4).write(to: folder.appendingPathComponent(name))
        }
        // Les politiques de clé reconnaissent bien ces noms : le scan doit donc
        // aussi les exposer, sinon la déduplication porte sur des fichiers invisibles.
        XCTAssertNotNil(FilenamePolicy.xMediaID(inFileName: "T - xmv-42.m4v"))
        XCTAssertNotNil(FilenamePolicy.xFetishMediaID(inFileName: "A - xfv-7.m4v"))
        XCTAssertTrue(BinaryMetadata.supportsExtension("m4v"))

        let snapshot = try CollectionFiles.scan(folder)
        XCTAssertEqual(Set(snapshot.files.map(\.lastPathComponent)), Set(names))
        XCTAssertEqual(snapshot.totalBytes, 12)
        XCTAssertEqual(try SavedMediaCount(folder: folder).count, 3)
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
