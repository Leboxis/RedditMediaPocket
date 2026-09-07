import XCTest
@testable import MediaCore

final class SubredditFeedTests: XCTestCase {
    func testParseUserForms() throws {
        XCTAssertEqual(try FeedSource.parse("leboxis"), .user("leboxis"))
        XCTAssertEqual(try FeedSource.parse(" u/Example_User "), .user("Example_User"))
    }

    func testParseSubredditForms() throws {
        XCTAssertEqual(try FeedSource.parse("r/pics"), .subreddit("pics"))
        XCTAssertEqual(try FeedSource.parse(" R/EarthPorn "), .subreddit("EarthPorn"))
    }

    func testParseRejectsInvalid() {
        XCTAssertThrowsError(try FeedSource.parse("r/a!"))
        XCTAssertThrowsError(try FeedSource.parse("r/a"))
        XCTAssertThrowsError(try FeedSource.parse("ab"))
        XCTAssertThrowsError(try FeedSource.parse(""))
    }

    func testUserFeedURL() {
        XCTAssertEqual(
            FeedSource.user("leboxis").feedURL().absoluteString,
            "https://www.reddit.com/user/leboxis/submitted.rss?limit=100"
        )
        XCTAssertEqual(
            FeedSource.user("leboxis").feedURL(after: "t3_abc").absoluteString,
            "https://www.reddit.com/user/leboxis/submitted.rss?limit=100&after=t3_abc"
        )
    }

    func testSubredditFeedURLs() {
        XCTAssertEqual(
            FeedSource.subreddit("pics").feedURL().absoluteString,
            "https://www.reddit.com/r/pics/new.rss?limit=100"
        )
        XCTAssertEqual(
            FeedSource.subreddit("pics").feedURL(sort: "hot").absoluteString,
            "https://www.reddit.com/r/pics/hot.rss?limit=100"
        )
        XCTAssertEqual(
            FeedSource.subreddit("pics").feedURL(sort: "top").absoluteString,
            "https://www.reddit.com/r/pics/top.rss?t=month&limit=100"
        )
        XCTAssertEqual(
            FeedSource.subreddit("pics").feedURL(sort: "new", after: "t3_abc").absoluteString,
            "https://www.reddit.com/r/pics/new.rss?limit=100&after=t3_abc"
        )
        // Tri inconnu : repli sur les nouveautés.
        XCTAssertEqual(
            FeedSource.subreddit("pics").feedURL(sort: "bogus").absoluteString,
            "https://www.reddit.com/r/pics/new.rss?limit=100"
        )
    }

    func testCollectionMapping() {
        XCTAssertEqual(FeedSource.subreddit("pics").id, "r/pics")
        XCTAssertEqual(FeedSource.subreddit("pics").displayName, "r/pics")
        XCTAssertEqual(FeedSource.subreddit("pics").folderName, "r.pics")
        XCTAssertEqual(FeedSource.user("leboxis").id, "u/leboxis")
        XCTAssertEqual(FeedSource.user("leboxis").folderName, "leboxis")
    }

    func testParseSavedForm() throws {
        XCTAssertEqual(try FeedSource.parse("saved/LeBoxis_1"), .saved("LeBoxis_1"))
    }

    func testSavedFeedURL() {
        XCTAssertEqual(
            FeedSource.saved("leboxis").feedURL().absoluteString,
            "https://www.reddit.com/user/leboxis/saved.rss?limit=100"
        )
        XCTAssertEqual(
            FeedSource.saved("leboxis").feedURL(after: "t3_abc").absoluteString,
            "https://www.reddit.com/user/leboxis/saved.rss?limit=100&after=t3_abc"
        )
    }

    func testSavedMapping() {
        XCTAssertEqual(FeedSource.saved("leboxis").id, "saved/leboxis")
        XCTAssertEqual(FeedSource.saved("leboxis").displayName, "Saved")
        XCTAssertEqual(FeedSource.saved("leboxis").folderName, "saved.leboxis")
    }

    func testSubredditFeedPaginationShape() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><entry><id>t3_aaa</id><title>A</title><content type="html">&lt;a href="https://i.redd.it/a.jpg"&gt;i&lt;/a&gt;</content></entry><entry><id>t3_bbb</id><title>B</title><content type="html">&lt;a href="https://i.redd.it/b.jpg"&gt;i&lt;/a&gt;</content></entry></feed>
        """
        let posts = try FeedParser.parse(Data(xml.utf8))
        XCTAssertEqual(posts.map(\.id), ["t3_aaa", "t3_bbb"])
        // Le curseur de pagination du téléchargeur repose sur ce préfixe.
        XCTAssertTrue(posts.last?.id.hasPrefix("t3_") == true)
    }
}
