import XCTest
@testable import MediaCore

/// Deux refus Reddit sont couverts par le repli `www → old` :
/// - le 404 des flux `.rss` (`/user/<nom>/submitted.rss`, `/r/<sub>/.rss`),
///   coupés depuis le 13/11/2026 ;
/// - le 403 « blocked by network security » que `www.reddit.com` renvoie sur
///   les listings `.json` de subreddit, alors que les listings d'utilisateur
///   répondent 200 avec la même session et le même User-Agent.
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
        XCTAssertNil(RedditFeedHosts.fallback(
            from: URL(string: "https://old.reddit.com/r/pics/new.json?limit=100")!, status: 403))
    }

    /// Seules les adresses de flux sont concernées : une page HTML n'a pas à
    /// être rejouée sur l'ancien hôte.
    func testNoFallbackForNonFeedPaths() {
        XCTAssertNil(RedditFeedHosts.fallback(
            from: URL(string: "https://www.reddit.com/user/spez/")!))
        XCTAssertNil(RedditFeedHosts.fallback(
            from: URL(string: "https://www.reddit.com/comments/abc123.json")!, status: 403))
    }

    /// Sans statut (ou sur 404), les listings `.json` ne sont pas rejoués :
    /// c'est le comportement historique, réservé aux `.rss` coupés.
    func testJsonListingNeedsAnExplicitForbiddenStatus() {
        let subreddit = URL(string: "https://www.reddit.com/r/pics/new.json?limit=100")!
        let profile = URL(string: "https://www.reddit.com/user/spez/submitted.json?limit=100")!
        XCTAssertNil(RedditFeedHosts.fallback(from: subreddit))
        XCTAssertNil(RedditFeedHosts.fallback(from: profile, status: 404))
    }

    /// Un 403 sur un listing `.json` rejoue l'adresse sur `old.reddit.com` en
    /// conservant tri, limit et curseur : c'est le correctif du refus des
    /// subreddits (`/r/<sub>/new.json` → 403 alors que `/user/…` → 200).
    func testJsonListingFallsBackOnForbidden() {
        let url = URL(string: "https://www.reddit.com/r/pics/new.json?limit=100&after=t3_abc")!
        XCTAssertEqual(RedditFeedHosts.fallback(from: url, status: 403)?.absoluteString,
                       "https://old.reddit.com/r/pics/new.json?limit=100&after=t3_abc")
        XCTAssertEqual(RedditFeedHosts.fallback(
            from: URL(string: "https://www.reddit.com/r/pics/top.json?t=month&limit=100")!, status: 403)?.absoluteString,
                       "https://old.reddit.com/r/pics/top.json?t=month&limit=100")
        XCTAssertEqual(RedditFeedHosts.fallback(
            from: URL(string: "https://www.reddit.com/user/spez/submitted.json?limit=100")!, status: 403)?.host,
                       "old.reddit.com")
    }

    /// Un hôte tiers n'est jamais réécrit : le repli reste dans Reddit.
    func testNoFallbackForForeignHost() {
        XCTAssertNil(RedditFeedHosts.fallback(
            from: URL(string: "https://example.com/r/pics/new.rss")!, status: 403))
        XCTAssertNil(RedditFeedHosts.fallback(
            from: URL(string: "https://i.redd.it/image.jpeg")!, status: 403))
    }

    func testNoFallbackForNonHTTPS() {
        XCTAssertNil(RedditFeedHosts.fallback(
            from: URL(string: "http://www.reddit.com/r/pics/new.rss")!))
        XCTAssertNil(RedditFeedHosts.fallback(
            from: URL(string: "http://www.reddit.com/r/pics/new.json")!, status: 403))
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
