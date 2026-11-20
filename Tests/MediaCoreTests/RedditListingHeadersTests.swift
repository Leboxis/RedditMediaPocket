import XCTest
@testable import MediaCore

/// Les listings JSON Reddit doivent porter les en-têtes d'un `fetch` du site :
/// c'est ce qui distingue `/user/<pseudo>/submitted.json` (200) de
/// `/r/<sub>/<tri>.json` (403 « blocked by network security ») avec la même
/// session et le même User-Agent.
final class RedditListingHeadersTests: XCTestCase {
    private func headers(_ string: String) -> [String: String] {
        RedditListingHeaders.forListing(URL(string: string)!)
    }

    func testSubredditListingCarriesBrowserHeadersAndReferer() {
        let h = headers("https://www.reddit.com/r/earth/new.json?limit=100")
        XCTAssertEqual(h["Accept"], "application/json, text/plain, */*")
        XCTAssertEqual(h["Accept-Language"], "en-US,en;q=0.9")
        XCTAssertEqual(h["Sec-Fetch-Dest"], "empty")
        XCTAssertEqual(h["Sec-Fetch-Mode"], "cors")
        XCTAssertEqual(h["Sec-Fetch-Site"], "same-origin")
        XCTAssertEqual(h["Referer"], "https://www.reddit.com/r/earth/")
    }

    func testProfileListingRefererPointsAtProfile() {
        XCTAssertEqual(headers("https://www.reddit.com/user/snoowiiz/submitted.json?limit=100")["Referer"],
                       "https://www.reddit.com/user/snoowiiz/")
    }

    /// Le repli `old.reddit.com` doit conserver un Referer du même hôte, sinon
    /// la requête perd son caractère `same-origin`.
    func testRefererUsesRequestHost() {
        XCTAssertEqual(headers("https://old.reddit.com/r/pics/hot.json?limit=100")["Referer"],
                       "https://old.reddit.com/r/pics/")
    }

    /// `/saved.json` est un listing racine sans page de subreddit ou de profil :
    /// aucun Referer fabriqué, mais les en-têtes XHR restent nécessaires.
    func testRootSavedListingHasNoReferer() {
        let h = headers("https://www.reddit.com/saved.json?limit=100")
        XCTAssertNil(h["Referer"])
        XCTAssertEqual(h["Sec-Fetch-Mode"], "cors")
    }

    func testNonRedditAndNonJSONAreUntouched() {
        XCTAssertTrue(headers("https://i.redd.it/photo.jpeg").isEmpty)
        XCTAssertTrue(headers("https://www.reddit.com/r/pics/new.rss?limit=100").isEmpty)
        XCTAssertTrue(headers("https://example.com/r/pics/new.json").isEmpty)
        XCTAssertTrue(headers("http://www.reddit.com/r/pics/new.json").isEmpty)
        // `/comments/<id>.json` résout une galerie, ce n'est pas un listing.
        XCTAssertTrue(headers("https://www.reddit.com/comments/abc123.json?raw_json=1").isEmpty)
    }

    /// Les trois tris du subreddit passent par le même chemin et doivent tous
    /// recevoir les en-têtes (le refus n'est pas lié au tri `new`).
    func testAllSubredditSortsAreCovered() {
        for sort in FeedSource.subredditSorts {
            let url = FeedSource.subreddit("pics").feedURL(sort: sort)
            XCTAssertFalse(RedditListingHeaders.forListing(url).isEmpty, "tri \(sort)")
            XCTAssertEqual(RedditListingHeaders.forListing(url)["Referer"],
                           "https://www.reddit.com/r/pics/")
        }
    }

    /// Le repli navigateur ne s'applique qu'aux listings de subreddit : les
    /// profils et les sauvegardes passent déjà par URLSession.
    func testSubredditClassification() {
        XCTAssertTrue(RedditListingHeaders.isSubredditListing(
            URL(string: "https://www.reddit.com/r/pics/new.json?limit=100")!))
        XCTAssertTrue(RedditListingHeaders.isSubredditListing(
            URL(string: "https://old.reddit.com/r/earth/top.json?t=month")!))
        XCTAssertFalse(RedditListingHeaders.isSubredditListing(
            URL(string: "https://www.reddit.com/user/snoowiiz/submitted.json")!))
        XCTAssertFalse(RedditListingHeaders.isSubredditListing(
            URL(string: "https://www.reddit.com/r/pics/new.rss")!))
        XCTAssertFalse(RedditListingHeaders.isSubredditListing(
            URL(string: "https://www.reddit.com/comments/abc123.json")!))
        XCTAssertFalse(RedditListingHeaders.isSubredditListing(
            URL(string: "https://example.com/r/pics/new.json")!))
    }
}
