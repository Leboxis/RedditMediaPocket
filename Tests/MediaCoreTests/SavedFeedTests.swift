import XCTest
@testable import MediaCore

final class SavedFeedTests: XCTestCase {
    func testDiscoversConnectedAccountWithoutUsername() throws {
        let html = """
        <a href="/.rss?feed=front&amp;user=Other">Front page</a>
        <a href="https://evil.example/saved.rss?feed=bad&amp;user=Other">Untrusted</a>
        <a href="/user/Alice/saved/.rss?feed=private&amp;user=Alice">Saved</a>
        """
        let feed = try SavedFeed(preferencesHTML: html)
        XCTAssertEqual(feed.username, "alice")
        XCTAssertEqual(feed.pageURL().path, "/user/Alice/saved/.rss")
    }

    func testDiscoveryUsesNewAccountOnEachRun() throws {
        for owner in ["Alice", "Bob"] {
            let feed = try SavedFeed(preferencesHTML: "<a href='/saved.rss?feed=private&amp;user=\(owner)'>Saved</a>")
            XCTAssertEqual(feed.username, owner.lowercased())
        }
    }

    func testDiscoveryRequiresPrivateSavedFeed() {
        for html in ["<html>Log in</html>",
                     "<a href='/.rss?feed=private&amp;user=Alice'>Front</a>",
                     "<a href='/saved.rss?user=Alice'>Missing credential</a>"] {
            XCTAssertThrowsError(try SavedFeed(preferencesHTML: html))
        }
    }

    func testPrivateSavedLinkAndPaginationPreserveCredential() throws {
        let html = """
        <a href="https://old.reddit.com/.rss?feed=front&amp;user=Alice">RSS</a>
        <a class="feedlink rss-link"
           href="https://old.reddit.com/saved.rss?feed=a%2Bb%26c&amp;user=Alice">RSS</a>
        """
        let feed = try SavedFeed(preferencesHTML: html, username: "alice")
        let first = URLComponents(url: feed.pageURL(), resolvingAgainstBaseURL: false)!
        XCTAssertEqual(first.path, "/saved.rss")
        XCTAssertEqual(first.queryItems?.first { $0.name == "feed" }?.value, "a+b&c")
        XCTAssertEqual(first.queryItems?.first { $0.name == "user" }?.value, "Alice")
        XCTAssertEqual(first.queryItems?.first { $0.name == "limit" }?.value, "100")
        XCTAssertNil(first.queryItems?.first { $0.name == "after" })
        let next = URLComponents(url: feed.pageURL(after: "t1_comment"), resolvingAgainstBaseURL: false)!
        XCTAssertEqual(next.queryItems?.first { $0.name == "feed" }?.value, "a+b&c")
        XCTAssertEqual(next.queryItems?.first { $0.name == "after" }?.value, "t1_comment")
    }

    func testUserScopedAndRelativeLinks() throws {
        for link in ["/user/Alice/saved.rss", "https://www.reddit.com/user/Alice/saved.rss"] {
            let feed = try SavedFeed(preferencesHTML: "<a href='\(link)?feed=secret&#38;user=Alice'>RSS</a>", username: "Alice")
            XCTAssertEqual(feed.pageURL().path, "/user/Alice/saved.rss")
        }
    }

    func testWrongAccountHasActionableError() {
        XCTAssertThrowsError(try SavedFeed(preferencesHTML: "<a href='/saved.rss?feed=secret&amp;user=Bob'>RSS</a>", username: "Alice")) {
            guard case SavedFeedError.wrongAccount = $0 else { return XCTFail("Expected wrong account") }
        }
    }

    func testRejectsMissingAmbiguousAndUntrustedCredentials() {
        let links = [
            "https://evil.example/saved.rss?feed=secret&user=Alice",
            "https://reddit.com.evil.example/saved.rss?feed=secret&user=Alice",
            "http://old.reddit.com/saved.rss?feed=secret&user=Alice",
            "https://evil@old.reddit.com/saved.rss?feed=secret&user=Alice",
            "/saved.rss?user=Alice", "/saved.rss?feed=&user=Alice",
            "/saved.rss?feed=secret&user=Alice&user=Bob",
            "/saved.rss?feed=secret&feed=other&user=Alice",
            "/user/Bob/saved.rss?feed=secret&user=Alice",
            "/saved.json?feed=secret&user=Alice"
        ]
        for link in links {
            XCTAssertThrowsError(try SavedFeed(preferencesHTML: "<a href='\(link)'>RSS</a>"), link)
            XCTAssertThrowsError(try SavedFeed(preferencesHTML: "<a href='\(link)'>RSS</a>", username: "Alice"), link)
        }
        XCTAssertThrowsError(try SavedFeed(preferencesHTML: "<html>Log in</html>", username: "Alice"))
    }

    func testPrivateFeedRedirectsCannotLeakToken() {
        let source = URL(string: "https://old.reddit.com/saved.rss?feed=secret&user=Alice")!
        XCTAssertTrue(SavedFeed.containsCredential(source))
        XCTAssertTrue(SavedFeed.allowsRedirect(from: source, to: source))
        for target in ["https://evil.example/saved.rss?feed=secret", "https://old.reddit.com/login?feed=secret", "http://old.reddit.com/saved.rss?feed=secret"] {
            XCTAssertFalse(SavedFeed.allowsRedirect(from: source, to: URL(string: target)!))
        }
        XCTAssertTrue(SavedFeed.allowsRedirect(from: URL(string: "https://www.reddit.com/")!, to: URL(string: "https://old.reddit.com/")!))
    }

    func testCanonicalRedirectRetainsAuthenticationAndCursor() throws {
        let source = URL(string: "https://old.reddit.com/saved.rss?feed=a%2Bb%26c&user=Alice&limit=100&after=t1_comment")!
        for host in ["reddit.com", "www.reddit.com", "old.reddit.com"] {
            for path in ["/saved.rss", "/saved/.rss", "/user/Alice/saved.rss", "/user/Alice/saved/.rss", "/user/Alice/saved.rss/"] {
                let destination = URL(string: "https://\(host)\(path)")!
                let resolved = try XCTUnwrap(SavedFeed.redirectURL(from: source, to: destination))
                let parts = try XCTUnwrap(URLComponents(url: resolved, resolvingAgainstBaseURL: false))
                XCTAssertEqual(parts.host, host)
                XCTAssertEqual(parts.path, path)
                XCTAssertEqual(parts.queryItems?.first { $0.name == "feed" }?.value, "a+b&c")
                XCTAssertEqual(parts.queryItems?.first { $0.name == "user" }?.value, "Alice")
                XCTAssertEqual(parts.queryItems?.first { $0.name == "limit" }?.value, "100")
                XCTAssertEqual(parts.queryItems?.first { $0.name == "after" }?.value, "t1_comment")
                XCTAssertEqual(SavedFeed.redirectURL(from: resolved, to: resolved), resolved)
            }
        }
    }

    func testRedirectRejectsOtherAccountsAndCredentialDestinations() {
        let source = URL(string: "https://old.reddit.com/saved.rss?feed=secret&user=Alice")!
        for target in [
            "https://www.reddit.com/user/Bob/saved.rss",
            "https://www.reddit.com/saved.rss?user=Bob",
            "https://www.reddit.com/saved.rss?feed=other",
            "https://www.reddit.com/login", "https://www.reddit.com/saved.json",
            "https://reddit.com.evil.example/saved.rss",
            "https://arbitrary.reddit.com/saved.rss",
            "https://name@www.reddit.com/saved.rss",
            "https://www.reddit.com:8443/saved.rss"
        ] {
            XCTAssertNil(SavedFeed.redirectURL(from: source, to: URL(string: target)!), target)
        }
        XCTAssertNil(SavedFeed.redirectURL(from: URL(string: "https://evil.example/saved.rss?feed=secret&user=Alice")!, to: source))
    }

    func testPreferencesAcceptCanonicalSlashBeforeRSS() throws {
        let feed = try SavedFeed(preferencesHTML: "<a href='/user/Alice/saved/.rss?feed=secret&amp;user=Alice'>RSS</a>", username: "Alice")
        XCTAssertEqual(feed.pageURL().path, "/user/Alice/saved/.rss")
    }
}
