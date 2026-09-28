import XCTest
@testable import MediaCore

final class MediaCoreTests: XCTestCase {
    func testRSSAndOriginalLinks() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><entry><id>t3_abc</id><title>A &amp; B</title><content type="html">&lt;a href="https://i.redd.it/example.jpg"&gt;image&lt;/a&gt;</content></entry></feed>
        """
        let posts = try FeedParser.parse(Data(xml.utf8))
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts[0].title, "A & B")
        XCTAssertEqual(MediaExtractor.extract(posts[0].html), [.direct(URL(string: "https://i.redd.it/example.jpg")!)])
    }
    func testRejectBlockPage() {
        XCTAssertThrowsError(try FeedParser.parse(Data("<html><body>Blocked</body></html>".utf8)))
    }
    func testPostTitleFilenamePolicy() {
        XCTAssertEqual(FilenamePolicy.postTitle("  A / B:\nC  "), "A - B- C")
        XCTAssertEqual(FilenamePolicy.postTitle(".."), "post")
        XCTAssertEqual(FilenamePolicy.postTitle("", fallback: "t3_abc"), "t3_abc")
        XCTAssertLessThanOrEqual(FilenamePolicy.postTitle(String(repeating: "é", count: 200)).utf8.count, 180)
    }
    func testDownloadStemIncludesPostID() {
        XCTAssertEqual(FilenamePolicy.downloadStem(title: "Mon chat dort", postID: "t3_abc123"), "Mon chat dort - abc123")
        XCTAssertEqual(FilenamePolicy.downloadStem(title: "Mon chat dort", postID: "abc123"), "Mon chat dort - abc123")
        XCTAssertEqual(FilenamePolicy.downloadStem(title: "Do my natural toes look like french tips?", postID: "t3_1ghwxnf"), "Do my natural toes look like french tips - 1ghwxnf")
        XCTAssertEqual(FilenamePolicy.downloadStem(title: "Vacances", postID: "t3_abc123", position: 1), "Vacances 1 - abc123")
        XCTAssertEqual(FilenamePolicy.downloadStem(title: "Vacances", postID: "t3_abc123", position: 2), "Vacances 2 - abc123")
        XCTAssertEqual(FilenamePolicy.downloadStem(title: "", postID: "t3_xyz"), "xyz")
        XCTAssertEqual(FilenamePolicy.downloadStem(title: "..", postID: "t3_xyz"), "xyz")
    }

    func testKDriveNameMatch() {
        XCTAssertTrue(FilenamePolicy.kDriveNameMatch("Leboxis", "leboxis"))
        XCTAssertTrue(FilenamePolicy.kDriveNameMatch("Leboxis", "Léboxis"))
        XCTAssertFalse(FilenamePolicy.kDriveNameMatch("Leboxis", "Autre"))
    }

    func testKDriveRemoteCandidateNames() {
        // Le repli 422 est déterministe : un fichier déjà uploadé sous son
        // nom de repli doit être détecté comme présent.
        let candidates = FilenamePolicy.kDriveRemoteCandidateNames(for: "a?b.mp4")
        XCTAssertEqual(candidates.first, FilenamePolicy.kDriveFileName("a?b.mp4"))
        XCTAssertTrue(candidates.contains(FilenamePolicy.kDriveFallbackName(for: "a?b.mp4")))
        XCTAssertEqual(candidates.count, Set(candidates).count)
    }
    func testKDriveFolderNameCapitalized() {
        XCTAssertEqual(FilenamePolicy.kDriveFolderName("leboxis"), "Leboxis")
        XCTAssertEqual(FilenamePolicy.kDriveFolderName("pics"), "Pics")
        XCTAssertEqual(FilenamePolicy.kDriveFolderName("AskReddit"), "AskReddit")
        XCTAssertEqual(FilenamePolicy.kDriveFolderName("u/leboxis"), "Uleboxis")
        XCTAssertEqual(FilenamePolicy.kDriveFolderName("r/pics"), "Rpics")
        XCTAssertEqual(FilenamePolicy.kDriveFolderName("saved/leboxis"), "Sleboxis")
        XCTAssertEqual(FilenamePolicy.kDriveFolderName("x/itwasalwaysmysolesvip"), "Xitwasalwaysmysolesvip")
        XCTAssertEqual(FilenamePolicy.kDriveFolderName(""), "Pocket")
        XCTAssertEqual(FilenamePolicy.kDriveFolderName("a?b"), "A-b")
    }

    func testKDriveNamesHaveStableSuffixes() {
        // Fixed vector also catches accidentally reverting to hashValue.
        XCTAssertEqual(FilenamePolicy.kDriveFallbackName(for: "hello"), "media-a430d846")
        let original = String(repeating: "é", count: 120) + ".mp4"
        let name = FilenamePolicy.kDriveFileName(original)
        XCTAssertLessThanOrEqual(name.utf8.count, 150)
        XCTAssertTrue(name.hasSuffix(".mp4"))
        XCTAssertTrue(name.hasSuffix("-43fe3b.mp4"))
        XCTAssertEqual(FilenamePolicy.kDriveFallbackName(for: original), "media-43fe3b13.mp4")
        XCTAssertNotEqual(name, FilenamePolicy.kDriveFileName(String(repeating: "é", count: 119) + "a.mp4"))
        XCTAssertEqual(FilenamePolicy.kDriveFileName("photo.jpg"), "photo.jpg")
    }

    func testRecognizedMediaAndDeduplication() {
        let html = """
        <img src="https://preview.redd.it/thumbnail.jpg"><a href="https://v.redd.it/abc/">video</a>
        <a href="https://www.redgifs.com/watch/SomeGif">gif</a>
        <a href="https://i.redd.it/p.png?x=1&amp;y=2">image</a>
        <a href="https://v.redd.it/abc/">duplicate</a>
        <a href="https://reddit.com/gallery/abc">unsupported gallery</a>
        <a href="http://i.redd.it/x.jpg">insecure</a>
        <a href="https://i.redd.it.evil.example/x.jpg">lookalike</a>
        """
        XCTAssertEqual(MediaExtractor.extract(html), [.redditVideo(URL(string: "https://v.redd.it/abc")!), .redgifs("somegif"), .direct(URL(string: "https://i.redd.it/p.png?x=1&y=2")!)])
    }
    func testUsernameValidation() throws {
        XCTAssertEqual(try MediaExtractor.username(" u/example_user "), "example_user")
        XCTAssertThrowsError(try MediaExtractor.username("../../private"))
        XCTAssertThrowsError(try MediaExtractor.username("ab?x=1"))
    }
    func testDASHBestVideoAndAudio() throws {
        let xml = """
        <MPD><Period><AdaptationSet mimeType="video/mp4"><Representation height="360"><BaseURL>low.mp4</BaseURL></Representation><Representation height="1080"><BaseURL>high.mp4</BaseURL></Representation></AdaptationSet><AdaptationSet mimeType="audio/mp4"><Representation><BaseURL>audio.mp4</BaseURL></Representation></AdaptationSet></Period></MPD>
        """
        let tracks = try DASHParser.parse(Data(xml.utf8), relativeTo: URL(string: "https://v.redd.it/id/DASHPlaylist.mpd")!)
        XCTAssertEqual(tracks.video.absoluteString, "https://v.redd.it/id/high.mp4")
        XCTAssertEqual(tracks.audio?.absoluteString, "https://v.redd.it/id/audio.mp4")
    }
    func testDASHWithoutAudio() throws {
        let xml = "<MPD><Representation mimeType=\"video/mp4\" height=\"720\"><BaseURL>video.mp4</BaseURL></Representation></MPD>"
        let tracks = try DASHParser.parse(Data(xml.utf8), relativeTo: URL(string: "https://v.redd.it/id/DASHPlaylist.mpd")!)
        XCTAssertNil(tracks.audio)
    }
    func testRSSCapturesPostLink() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><entry><id>t3_abc123</id><title>Hi</title><link href="https://www.reddit.com/r/pics/comments/abc123/hi/"/><content type="html">&lt;a href="https://i.redd.it/example.jpg"&gt;image&lt;/a&gt;</content></entry></feed>
        """
        let posts = try FeedParser.parse(Data(xml.utf8))
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts[0].link, "https://www.reddit.com/r/pics/comments/abc123/hi/")
    }
    func testPostLinkFallbackFromID() {
        XCTAssertEqual(BinaryMetadata.postLink(postID: "t3_abc123", link: nil), "https://www.reddit.com/comments/abc123/")
        XCTAssertEqual(BinaryMetadata.postLink(postID: "abc123", link: "https://www.reddit.com/r/pics/comments/abc123/hi/"), "https://www.reddit.com/r/pics/comments/abc123/hi/")
        XCTAssertNil(BinaryMetadata.postLink(postID: "", link: nil))
    }
    func testBinaryMetadataPayload() {
        let payload = BinaryMetadata.payload(author: "u/leboxis", postLink: "https://www.reddit.com/comments/abc123/")
        XCTAssertEqual(payload.author, "u/leboxis")
        XCTAssertEqual(payload.comment, "https://www.reddit.com/comments/abc123/")
        XCTAssertTrue(BinaryMetadata.supportsExtension("jpg"))
        XCTAssertTrue(BinaryMetadata.supportsExtension("mp4"))
        XCTAssertFalse(BinaryMetadata.supportsExtension("gif"))
        XCTAssertFalse(BinaryMetadata.supportsExtension("webp"))
    }
}
