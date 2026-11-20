import XCTest
@testable import MediaCore

/// Replis CDN Reddit (nov. 2026) : `i.redd.it` renvoie 404 si l'extension
/// reconstruite est fausse (`.jpg` vs `.jpeg` réel) ; `preview.redd.it` sans
/// signature de query répond 403. Seule une URL signée `preview.redd.it`
/// a un repli utile : l'original `i.redd.it` avec la **vraie** extension du
/// chemin signé.
final class RedditCDNTests: XCTestCase {
    func testSignedPreviewURLFallsBackToOriginalWithRealExtension() {
        let url = URL(string: "https://preview.redd.it/ot6s9wklhlph1.jpeg?width=1080&auto=webp&s=abc123")!
        XCTAssertEqual(
            RedditCDN.fallbacks(for: url).map(\.absoluteString),
            ["https://i.redd.it/ot6s9wklhlph1.jpeg"]
        )
    }

    func testIRedditHasNoRewriteFallback() {
        // i.redd.it -> 404 hors navigateur ; preview non signé -> 403 :
        // aucune réécriture d'hôte utile.
        XCTAssertTrue(RedditCDN.fallbacks(for: URL(string: "https://i.redd.it/9crikqo1enxh1.jpg")!).isEmpty)
        XCTAssertTrue(RedditCDN.fallbacks(for: URL(string: "https://v.redd.it/abc")!).isEmpty)
    }

    func testNonRedditHostsAreUntouched() {
        XCTAssertTrue(RedditCDN.fallbacks(for: URL(string: "https://media.redgifs.com/x.mp4")!).isEmpty)
        XCTAssertTrue(RedditCDN.fallbacks(for: URL(string: "http://preview.redd.it/abc.jpg")!).isEmpty)
    }
}
