import XCTest
@testable import MediaCore

/// Reddit ne sert plus `/user/<nom>/submitted.rss` ni `/r/<sub>/.rss` sur
/// `www.reddit.com` : ces adresses répondent un document Atom « Not Found »
/// émis par `rss.reddit.com` (HTTP 404 constaté). Le repli doit exister pour
/// ces deux formes, et seulement elles.
final class RedditFeedHostsTests: XCTestCase {
    func testProfileFeedFallsBackToOldReddit() {
        let url = URL(string: "https://www.reddit.com/user/spez/submitted.rss?limit=100")!
        let fallback = RedditFeedHosts.fallback(from: url)
        XCTAssertEqual(fallback?.absoluteString,
                       "https://old.reddit.com/user/spez/submitted.rss?limit=100")
    }

    func testSubredditFeedFallsBackAndKeepsSort() {
        let url = URL(string: "https://www.reddit.com/r/pics/new.rss?limit=100")!
        XCTAssertEqual(RedditFeedHosts.fallback(from: url)?.absoluteString,
                       "https://old.reddit.com/r/pics/new.rss?limit=100")
    }

    /// Le repli ne doit pas boucler : une adresse déjà sur `old.reddit.com`
    /// n'a pas de repli, sinon la seconde tentative en créerait une troisième.
    func testNoFallbackFromOldReddit() {
        XCTAssertNil(RedditFeedHosts.fallback(
            from: URL(string: "https://old.reddit.com/user/spez/submitted.rss")!))
    }

    /// Seules les adresses `.rss` sont concernées : un appel JSON ou une page
    /// HTML n'ont pas à être rejoués sur l'ancien hôte.
    func testNoFallbackForNonFeedPaths() {
        XCTAssertNil(RedditFeedHosts.fallback(
            from: URL(string: "https://www.reddit.com/user/spez/")!))
        XCTAssertNil(RedditFeedHosts.fallback(
            from: URL(string: "https://www.reddit.com/comments/abc123.json")!))
    }

    /// Un hôte tiers n'est jamais réécrit : le repli reste dans Reddit.
    func testNoFallbackForForeignHost() {
        XCTAssertNil(RedditFeedHosts.fallback(
            from: URL(string: "https://example.com/r/pics/new.rss")!))
    }

    func testNoFallbackForNonHTTPS() {
        XCTAssertNil(RedditFeedHosts.fallback(
            from: URL(string: "http://www.reddit.com/r/pics/new.rss")!))
    }

    /// Le jeton privé des sauvegardés voyage en paramètre : le repli doit le
    /// conserver intact, sinon le flux privé deviendrait anonyme (et vide).
    func testPrivateTokenSurvivesFallback() {
        let url = URL(string: "https://www.reddit.com/r/pics/new.rss?feed=abc123&user=spez")!
        let fallback = RedditFeedHosts.fallback(from: url)
        XCTAssertEqual(fallback?.query, "feed=abc123&user=spez")
        XCTAssertEqual(fallback?.host, "old.reddit.com")
    }
}
