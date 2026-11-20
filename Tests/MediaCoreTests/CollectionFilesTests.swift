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

    func testHasMediaRejectsEmptyHiddenNonMediaAndSubdirectories() throws {
        let fm = FileManager.default
        let missing = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertFalse(CollectionFiles.hasMedia(in: missing))

        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        XCTAssertFalse(CollectionFiles.hasMedia(in: folder))

        // Sidecars cachés, résidus non médias et sous-dossier nommé .mp4 ne
        // doivent pas faire exister une pastille de collection vide.
        let metadataDir = folder.appendingPathComponent(".metadata", isDirectory: true)
        try fm.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: metadataDir.appendingPathComponent("clip.mp4.json"))
        try Data("tmp".utf8).write(to: folder.appendingPathComponent("clip.part"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("notes.json"))
        try Data([0]).write(to: folder.appendingPathComponent(".hidden.mp4"))
        try fm.createDirectory(at: folder.appendingPathComponent("fake.mp4"), withIntermediateDirectories: true)
        XCTAssertFalse(CollectionFiles.hasMedia(in: folder))

        try Data([0x00, 0x01]).write(to: folder.appendingPathComponent("real.mp4"))
        XCTAssertTrue(CollectionFiles.hasMedia(in: folder))
    }

    func testMigrateLegacyTikTokFoldersRemovesEmptyLegacyWithoutCreatingGlobalFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let legacy = root.appendingPathComponent("ttv.741234567890", isDirectory: true)
        let metadataDir = legacy.appendingPathComponent(".metadata", isDirectory: true)
        try fm.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: metadataDir.appendingPathComponent("old.mp4.json"))
        try Data("junk".utf8).write(to: legacy.appendingPathComponent("leftover.part"))

        let globalFolder = root.appendingPathComponent("ttv.videos", isDirectory: true)
        let result = CollectionFiles.migrateLegacyTikTokVideoFolders(root: root, into: globalFolder)

        XCTAssertTrue(result.movedByFolder.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.removedLegacyFolders, 1)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        XCTAssertFalse(fm.fileExists(atPath: globalFolder.path))
    }

    func testMigrateLegacyTikTokFoldersMovesMediaAndMetadataAndRemovesLegacy() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let legacy = root.appendingPathComponent("ttv.741234567890", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        let video = legacy.appendingPathComponent("alice - clip - tkv-741234567890.mp4")
        try Data([0x01, 0x02, 0x03]).write(to: video)
        let meta = MediaMetadata(downloadedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                 postDate: Date(timeIntervalSince1970: 1_699_000_000),
                                 author: "alice",
                                 postLink: "https://www.tiktok.com/@alice/video/741234567890")
        XCTAssertTrue(meta.save(for: video))

        let globalFolder = root.appendingPathComponent("ttv.videos", isDirectory: true)
        let result = CollectionFiles.migrateLegacyTikTokVideoFolders(root: root, into: globalFolder)

        XCTAssertEqual(result.movedByFolder.count, 1)
        XCTAssertEqual(result.movedByFolder.first?.folderName, "ttv.741234567890")
        XCTAssertEqual(result.movedByFolder.first?.moved, 1)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.removedLegacyFolders, 1)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))

        let movedVideo = globalFolder.appendingPathComponent("alice - clip - tkv-741234567890.mp4")
        XCTAssertTrue(fm.fileExists(atPath: movedVideo.path))
        XCTAssertTrue(CollectionFiles.hasMedia(in: globalFolder))
        XCTAssertEqual(MediaMetadata.read(for: movedVideo)?.author, "alice")
    }

    func testRemoveLegacyTikTokFoldersOnlyDeletesLegacyFolders() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let legacy1 = root.appendingPathComponent("ttv.111", isDirectory: true)
        let legacy2 = root.appendingPathComponent("ttv.222", isDirectory: true)
        let globalFolder = root.appendingPathComponent("ttv.videos", isDirectory: true)
        let other = root.appendingPathComponent("tk.alice", isDirectory: true)
        for dir in [legacy1, legacy2, globalFolder, other] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        CollectionFiles.removeLegacyTikTokVideoFolders(in: root)

        XCTAssertFalse(fm.fileExists(atPath: legacy1.path))
        XCTAssertFalse(fm.fileExists(atPath: legacy2.path))
        XCTAssertTrue(fm.fileExists(atPath: globalFolder.path))
        XCTAssertTrue(fm.fileExists(atPath: other.path))
    }
}
