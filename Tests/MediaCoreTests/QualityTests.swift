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
    func testRedgifsPrefersHD() {
        let hd = URL(string: "https://media.redgifs.com/Example.mp4")!
        let sd = URL(string: "https://media.redgifs.com/Example-mobile.mp4")!
        XCTAssertEqual(QualityPolicy.redgifsURL(hd: hd, sd: sd), hd)
        XCTAssertEqual(QualityPolicy.redgifsURL(hd: nil, sd: sd), sd)
        XCTAssertNil(QualityPolicy.redgifsURL(hd: nil, sd: nil))
    }
    func testQuotaAdviceOnlyWhenValid() {
        XCTAssertEqual(RatePolicy.quotaDelay(remaining: "10", reset: "60"), 6)
        XCTAssertEqual(RatePolicy.quotaDelay(remaining: "0", reset: "60"), 60)
        XCTAssertNil(RatePolicy.quotaDelay(remaining: nil, reset: "60"))
        XCTAssertNil(RatePolicy.quotaDelay(remaining: "nan", reset: "60"))
    }
}
