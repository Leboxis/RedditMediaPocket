import XCTest
@testable import MediaCore

final class RedditCookiePolicyTests: XCTestCase {
    private func cookie(domain: String = ".reddit.com", path: String = "/", expires: Date = Date().addingTimeInterval(3600)) -> HTTPCookie {
        HTTPCookie(properties: [.domain: domain, .path: path, .name: "test_session", .value: "synthetic-test-value", .secure: "TRUE", .expires: expires])!
    }
    func testCookieGoesOnlyToHTTPSReddit() {
        let cookies = [cookie()]
        XCTAssertNotNil(RedditCookiePolicy.header(cookies: cookies, for: URL(string: "https://www.reddit.com/user/test/submitted.rss")!))
        for address in ["http://www.reddit.com/", "https://i.redd.it/", "https://redgifs.com/", "https://i.imgur.com/", "https://reddit.com.example.org/", "https://notreddit.com/"] {
            XCTAssertNil(RedditCookiePolicy.header(cookies: cookies, for: URL(string: address)!))
        }
    }
    func testDomainPathAndExpiryAreRespected() {
        let url = URL(string: "https://www.reddit.com/user/test/submitted.rss")!
        XCTAssertNil(RedditCookiePolicy.header(cookies: [cookie(domain: "old.reddit.com")], for: url))
        XCTAssertNil(RedditCookiePolicy.header(cookies: [cookie(path: "/login")], for: url))
        XCTAssertNil(RedditCookiePolicy.header(cookies: [cookie(expires: .distantPast)], for: url))
        XCTAssertNotNil(RedditCookiePolicy.header(cookies: [cookie(path: "/user")], for: url))
        XCTAssertNil(RedditCookiePolicy.header(cookies: [cookie(path: "/user")], for: URL(string: "https://www.reddit.com/username")!))
    }
    func testUnrelatedCookieIsNeverCopied() {
        XCTAssertNil(RedditCookiePolicy.header(cookies: [cookie(domain: ".redgifs.com")], for: URL(string: "https://www.reddit.com/")!))
    }
}
