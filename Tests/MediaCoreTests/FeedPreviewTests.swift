import XCTest
@testable import MediaCore

final class FeedPreviewTests: XCTestCase {
    func testRSSThumbnailIsDisplayOnly() {
        let html = """
        <a href="https://v.redd.it/abc/"><img src="https://preview.redd.it/abc.jpg?width=320&amp;crop=smart" /></a>
        """
        XCTAssertEqual(MediaExtractor.previewImage(html)?.absoluteString,
                       "https://preview.redd.it/abc.jpg?width=320&crop=smart")
        XCTAssertEqual(MediaExtractor.extract(html), [.redditVideo(URL(string: "https://v.redd.it/abc")!)])
    }

    func testRejectsUntrustedImagesAndFindsValidThumbnail() {
        let html = """
        <img src="http://preview.redd.it/a.jpg">
        <img src="https://preview.redd.it.evil.example/a.jpg">
        <img data-src="https://i.redd.it/not-loaded.jpg">
        <IMG ALT="thumbnail" SRC='https://b.thumbs.redditmedia.com/valid.jpg'>
        """
        XCTAssertEqual(MediaExtractor.previewImage(html)?.absoluteString,
                       "https://b.thumbs.redditmedia.com/valid.jpg")
    }

    func testTextPostAndThumbnailOnlyPost() {
        XCTAssertNil(MediaExtractor.previewImage("<p>Text post</p>"))
        let html = "<img src=\"https://i.redd.it/preview.jpg\">"
        XCTAssertNotNil(MediaExtractor.previewImage(html))
        XCTAssertTrue(MediaExtractor.extract(html).isEmpty)
    }
}
