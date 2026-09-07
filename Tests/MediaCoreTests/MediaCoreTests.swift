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
    func testKDriveFolderNameCapitalized() {
        XCTAssertEqual(FilenamePolicy.kDriveFolderName("leboxis"), "Leboxis")
        XCTAssertEqual(FilenamePolicy.kDriveFolderName("pics"), "Pics")
        XCTAssertEqual(FilenamePolicy.kDriveFolderName("AskReddit"), "AskReddit")
        XCTAssertEqual(FilenamePolicy.kDriveFolderName("u/leboxis"), "Leboxis")
        XCTAssertEqual(FilenamePolicy.kDriveFolderName("r/pics"), "Pics")
        XCTAssertEqual(FilenamePolicy.kDriveFolderName("saved/leboxis"), "Leboxis")
        XCTAssertEqual(FilenamePolicy.kDriveFolderName(""), "Pocket")
        XCTAssertEqual(FilenamePolicy.kDriveFolderName("a?b"), "A-b")
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
}
