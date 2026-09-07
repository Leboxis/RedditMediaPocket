import XCTest
@testable import MediaCore

final class FriendsFeedTests: XCTestCase {
    func testParsesProfileLinksAndDeduplicates() {
        let html = """
        <a href="https://old.reddit.com/user/Alice">/u/Alice</a>
        <a href="/user/bob">/u/bob</a>
        <a href="https://old.reddit.com/user/Alice">duplicate</a>
        <a href="/r/pics">subreddit</a>
        <a href="https://evil.example/user/Eve">untrusted</a>
        <a href="/user/Carl/overview">suffix</a>
        """
        XCTAssertEqual(FriendsFeed.parse(html), ["Alice", "bob", "Carl"])
    }

    func testRejectsTraversalInvalidAndNonUserPaths() {
        let html = """
        <a href="/user/../../escape">traversal</a>
        <a href="/user/ab">too short</a>
        <a href="/prefs/feeds">prefs</a>
        <a href="/user/Eve?over=18">query is allowed</a>
        """
        XCTAssertEqual(FriendsFeed.parse(html), ["Eve"])
    }

    func testEmptyAndLoginPages() {
        XCTAssertEqual(FriendsFeed.parse(""), [])
        XCTAssertEqual(FriendsFeed.parse("<html>Log in</html>"), [])
    }
}
