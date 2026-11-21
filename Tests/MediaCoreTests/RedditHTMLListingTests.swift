import XCTest
@testable import MediaCore

final class RedditHTMLListingTests: XCTestCase {
    private let fixture = """
    <div class="thing t3 thing-link id-t3_aaa111" data-fullname="t3_aaa111" data-type="link">
      <div class="entry">
        <p class="title"><a class="title may-blank" href="https://i.redd.it/abc123.jpg">Une image &amp; un titre</a> <span class="domain">(<a href="/domain/i.redd.it/">i.redd.it</a>)</span></p>
        <ul class="flat-list"><li><a class="comments" href="/r/pics/comments/aaa111/une_image/">42 commentaires</a></li></ul>
        <a class="thumbnail" href="https://i.redd.it/abc123.jpg"><img src="https://b.thumbs.redditmedia.com/thumb.jpg" alt=""></a>
        <time datetime="2026-11-20T10:00:00+00:00"></time>
      </div>
    </div>
    <div class="thing t3 thing-link id-t3_bbb222" data-fullname="t3_bbb222" data-type="link">
      <p class="title"><a class="title" href="https://www.reddit.com/gallery/bbb222">Galerie</a></p>
      <a class="comments" href="/r/pics/comments/bbb222/galerie/">comments</a>
      <img src="https://preview.redd.it/xyz.jpeg">
    </div>
    """

    func testParsesPostsAndKeepsMediaLinks() throws {
        let posts = try RedditHTMLListing.parse(Data(fixture.utf8))
        XCTAssertEqual(posts.map(\.id), ["t3_aaa111", "t3_bbb222"])
        XCTAssertEqual(posts[0].title, "Une image & un titre")
        XCTAssertEqual(posts[0].link, "https://www.reddit.com/r/pics/comments/aaa111/une_image/")
        XCTAssertEqual(MediaExtractor.extract(posts[0].html).map(\.key),
                       ["https://i.redd.it/abc123.jpg"])
        XCTAssertNotNil(posts[0].publishedAt)
        // Le lien de galerie reste intact : `prepareDownloads` le résout via
        // `/comments/<id>.json`, exactement comme pour le listing JSON.
        XCTAssertTrue(GalleryFeed.linked(posts[1].html))
        XCTAssertEqual(GalleryFeed.linkedID(posts[1].html), "bbb222")
    }

    func testCursorShapeMatchesTraversal() throws {
        let posts = try RedditHTMLListing.parse(Data(fixture.utf8))
        XCTAssertTrue(posts.last?.id.hasPrefix("t3_") == true)
    }

    func testEmptyAndMalformedHTML() throws {
        XCTAssertTrue(try RedditHTMLListing.parse(Data("<html><body>Not found</body></html>".utf8)).isEmpty)
        XCTAssertTrue(try RedditHTMLListing.parse(Data("".utf8)).isEmpty)
    }

    func testHTMLURLKeepsSortAndCursor() {
        XCTAssertEqual(
            RedditHTMLListing.url(subreddit: "pics", sort: "new", after: nil).absoluteString,
            "https://old.reddit.com/r/pics/new/?limit=100"
        )
        XCTAssertEqual(
            RedditHTMLListing.url(subreddit: "pics", sort: "top", after: "t3_abc").absoluteString,
            "https://old.reddit.com/r/pics/top/?limit=100&t=month&after=t3_abc"
        )
        XCTAssertEqual(
            RedditHTMLListing.url(subreddit: "pics", sort: "bogus", after: nil).absoluteString,
            "https://old.reddit.com/r/pics/new/?limit=100"
        )
    }
}
