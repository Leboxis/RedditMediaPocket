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

    func testXFetishTokensAreMaskedButPresenceIsVisible() throws {
        let image = try XCTUnwrap(URL(string: "https://x-fetish.tube/get_image/10/abc/sources/3000/3948/2652884.jpg/?i-acctoken=secret123"))
        let storage = try XCTUnwrap(URL(string: "https://storage4.x-fetish.tube/remote_control.php?file=abc.jpg&acctoken=secret456"))
        XCTAssertTrue(LogDiagnostics.requestSummary(image).contains("token=oui"))
        XCTAssertTrue(LogDiagnostics.requestSummary(storage).contains("acctoken=oui"))
        XCTAssertFalse(LogDiagnostics.requestSummary(image).contains("secret123"))
        XCTAssertFalse(LogDiagnostics.requestSummary(storage).contains("secret456"))
        let clean = LogDiagnostics.sanitize("GET https://x-fetish.tube/get_image/a/?i-acctoken=secret123 → https://storage4.x-fetish.tube/remote_control.php?file=a.jpg&acctoken=secret456")
        XCTAssertFalse(clean.contains("secret123"))
        XCTAssertFalse(clean.contains("secret456"))
    }
}
