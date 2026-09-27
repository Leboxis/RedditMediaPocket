import XCTest
@testable import MediaCore

final class QualityTests: XCTestCase {
    func testBestVideoAndAudioAreIndependentOfOrder() throws {
        let xml = """
        <MPD><Period>
        <AdaptationSet mimeType="video/mp4" width="1920" height="1080">
        <Representation frameRate="30" bandwidth="9000000"><BaseURL>30fps.mp4</BaseURL></Representation>
        <Representation frameRate="60000/1000" bandwidth="8000000"><BaseURL>best.mp4</BaseURL></Representation>
        <Representation frameRate="60" bandwidth="1000000"><BaseURL>lowbitrate.mp4</BaseURL></Representation>
        <Representation height="720" frameRate="60" bandwidth="10000000"><BaseURL>720.mp4</BaseURL></Representation>
        </AdaptationSet>
        <AdaptationSet mimeType="audio/mp4">
        <Representation bandwidth="64000"><BaseURL>low.m4a</BaseURL></Representation>
        <Representation bandwidth="256000"><BaseURL>best.m4a</BaseURL></Representation>
        </AdaptationSet></Period></MPD>
        """
        let tracks = try DASHParser.parse(Data(xml.utf8), relativeTo: URL(string: "https://v.redd.it/a/DASHPlaylist.mpd")!)
        XCTAssertEqual(tracks.video.lastPathComponent, "best.mp4")
        XCTAssertEqual(tracks.audio?.lastPathComponent, "best.m4a")
    }
    func testNoSilentDowngradeWhenSegmentedVideoIsUnsupported() {
        let xml = """
        <MPD><Representation mimeType="video/mp4" height="720"><BaseURL>720.mp4</BaseURL></Representation><Representation mimeType="video/mp4" height="2160"><SegmentTemplate media="chunk-$Number$.m4s"/></Representation></MPD>
        """
        XCTAssertThrowsError(try DASHParser.parse(Data(xml.utf8), relativeTo: URL(string: "https://v.redd.it/a/DASHPlaylist.mpd")!))
    }
    func testOriginalImgurAndUnmodifiedReddit() {
        let thumb = URL(string: "https://i.imgur.com/Ab12Cd3l.jpg")!
        XCTAssertEqual(QualityPolicy.originalImageURL(thumb).absoluteString, "https://i.imgur.com/Ab12Cd3.jpg")
        let original = URL(string: "https://i.imgur.com/Ab12Cdl.jpg")!
        XCTAssertEqual(QualityPolicy.originalImageURL(original), original)
        let reddit = URL(string: "https://i.redd.it/example.png")!
        XCTAssertEqual(QualityPolicy.originalImageURL(reddit), reddit)
    }
    func testRedgifsCandidatesFallbackOrder() {
        let hd = URL(string: "https://media.redgifs.com/Example.mp4")!
        let sd = URL(string: "https://media.redgifs.com/Example-mobile.mp4")!
        XCTAssertEqual(QualityPolicy.redgifsCandidates(hd: hd, sd: sd), [hd, sd])
        XCTAssertEqual(QualityPolicy.redgifsCandidates(hd: nil, sd: sd), [sd])
        XCTAssertEqual(QualityPolicy.redgifsCandidates(hd: hd, sd: nil), [hd])
        XCTAssertEqual(QualityPolicy.redgifsCandidates(hd: nil, sd: nil), [])
    }
    func testRedgifsAPIURLLowercasesAndAddsViews() {
        XCTAssertEqual(
            RedgifsAPI.gifURL(id: "SqueakyHelplessWisent").absoluteString,
            "https://api.redgifs.com/v2/gifs/squeakyhelplesswisent?views=yes"
        )
        XCTAssertEqual(
            RedgifsAPI.gifURL(id: "ABC123").absoluteString,
            "https://api.redgifs.com/v2/gifs/abc123?views=yes"
        )
    }
    func testRedgifsAPIHeadersMatchReference() {
        let headers = RedgifsAPI.headers(id: "abc123")
        XCTAssertEqual(headers["Referer"], "https://www.redgifs.com/")
        XCTAssertEqual(headers["Origin"], "https://www.redgifs.com")
        XCTAssertEqual(headers["x-customheader"], "https://www.redgifs.com/watch/abc123")
    }
}
