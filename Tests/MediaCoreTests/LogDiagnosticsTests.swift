import XCTest
@testable import MediaCore

final class LogDiagnosticsTests: XCTestCase {
    func testRedactsPrivateFeedAndAuthorizationWithoutHanging() {
        let input = "GET https://old.reddit.com/saved.rss?feed=a%2Bb&user=Alice&after=t3_post Cookie: reddit_session=secret\nAuthorization: Bearer abc123\nfeed=second-token"
        let clean = LogDiagnostics.sanitize(input)
        XCTAssertFalse(clean.contains("a%2Bb"))
        XCTAssertFalse(clean.contains("Alice"))
        XCTAssertFalse(clean.contains("secret"))
        XCTAssertFalse(clean.contains("abc123"))
        XCTAssertFalse(clean.contains("second-token"))
        XCTAssertTrue(clean.contains("after=t3_post"))
    }

    func testRequestSummaryIdentifiesPageButNeverContainsPrivateQueryValues() throws {
        let url = try XCTUnwrap(URL(string: "https://old.reddit.com/saved.rss?feed=private123&user=Alice&limit=100&after=t3_older"))
        let summary = LogDiagnostics.requestSummary(url)
        XCTAssertTrue(summary.contains("old.reddit.com/saved.rss"))
        XCTAssertTrue(summary.contains("after=t3_older"))
        XCTAssertTrue(summary.contains("limit=100"))
        XCTAssertFalse(summary.contains("private123"))
        XCTAssertFalse(summary.contains("Alice"))
    }
}
