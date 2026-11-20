import XCTest
@testable import MediaCore

/// Replis CDN Reddit : `i.redd.it` renvoie 404 aux non-navigateurs depuis
/// novembre 2026 ; `preview.redd.it` / `external-preview.redd.it` servent la
/// même image par identifiant.
final class RedditCDNTests: XCTestCase {
    func testImageURLHasTwoFallbacks() {
        let url = URL(string: "https://i.redd.it/9crikqo1enxh1.jpg?width=100&s=abc")!
        XCTAssertEqual(
            RedditCDN.previewFallbacks(for: url).map(\.absoluteString),
            ["https://preview.redd.it/9crikqo1enxh1.jpg",
             "https://external-preview.redd.it/9crikqo1enxh1.jpg"]
        )
    }

    func testNonRedditHostsAreUntouched() {
        XCTAssertTrue(RedditCDN.previewFallbacks(for: URL(string: "https://media.redgifs.com/x.mp4")!).isEmpty)
        XCTAssertTrue(RedditCDN.previewFallbacks(for: URL(string: "https://preview.redd.it/abc.jpg")!).isEmpty)
        XCTAssertTrue(RedditCDN.previewFallbacks(for: URL(string: "http://i.redd.it/abc.jpg")!).isEmpty)
        XCTAssertTrue(RedditCDN.previewFallbacks(for: URL(string: "https://v.redd.it/abc")!).isEmpty)
    }
}
