import XCTest
@testable import MediaCore

/// Filtres de téléchargement et plafond d'espace.
final class DownloadFilterTests: XCTestCase {
    func testEmptyFilterAllowsEverything() {
        let filter = DownloadFilter()
        XCTAssertTrue(filter.isEmpty)
        XCTAssertFalse(filter.isActive)
        XCTAssertTrue(filter.allows(kind: .image, title: "n'importe quoi", publishedAt: nil))
        XCTAssertTrue(filter.allows(kind: .video, title: "", publishedAt: Date()))
    }

    func testKindFilter() {
        let filter = DownloadFilter(kinds: [.video])
        XCTAssertTrue(filter.allows(kind: .video, title: "x", publishedAt: nil))
        XCTAssertFalse(filter.allows(kind: .image, title: "x", publishedAt: nil))
        XCTAssertFalse(filter.allows(kind: .gif, title: "x", publishedAt: nil))
    }

    func testDateFilterIgnoresUnknownDates() {
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        let filter = DownloadFilter(since: cutoff)
        XCTAssertTrue(filter.allows(kind: .image, title: "x", publishedAt: cutoff.addingTimeInterval(60)))
        XCTAssertFalse(filter.allows(kind: .image, title: "x", publishedAt: cutoff.addingTimeInterval(-60)))
        // Une date inconnue ne doit jamais écarter un média.
        XCTAssertTrue(filter.allows(kind: .image, title: "x", publishedAt: nil))
    }

    func testMinimumBytesIgnoresUnknownSizes() {
        let filter = DownloadFilter(minimumBytes: 1_000_000)
        XCTAssertFalse(filter.allows(kind: .image, title: "x", publishedAt: nil, size: 500_000))
        XCTAssertTrue(filter.allows(kind: .image, title: "x", publishedAt: nil, size: 2_000_000))
        XCTAssertTrue(filter.allows(kind: .image, title: "x", publishedAt: nil, size: nil))
    }

    func testIncludeRequiresEveryWord() {
        let filter = DownloadFilter(includes: ["chat", "roux"])
        XCTAssertTrue(filter.allows(kind: .image, title: "Un CHAT roux", publishedAt: nil))
        XCTAssertFalse(filter.allows(kind: .image, title: "Un chat noir", publishedAt: nil))
    }

    func testExcludeDropsOnOneWord() {
        let filter = DownloadFilter(excludes: ["pub", "spam"])
        XCTAssertFalse(filter.allows(kind: .image, title: "Une PUB honteuse", publishedAt: nil))
        XCTAssertTrue(filter.allows(kind: .image, title: "Un chat", publishedAt: nil))
    }

    func testWordParsingIgnoresBlanksAndCase() {
        XCTAssertEqual(DownloadFilter.parseWords(" Un, DEUX ,, trois \n quatre "),
                       ["un", "deux", "trois", "quatre"])
        XCTAssertEqual(DownloadFilter.parseWords("  ,  "), [])
    }

    func testStoreRoundTrip() {
        let suite = UserDefaults(suiteName: "filter.tests")!
        suite.removePersistentDomain(forName: "filter.tests")
        let canonical = "r/pics"
        XCTAssertTrue(DownloadFilterStore.load(canonical, defaults: suite).isEmpty)

        let filter = DownloadFilter(kinds: [.image], minimumBytes: 2_000_000, includes: ["chat"])
        DownloadFilterStore.save(filter, for: canonical, defaults: suite)
        XCTAssertEqual(DownloadFilterStore.load(canonical, defaults: suite), filter)

        // Un filtre vide retire la clé au lieu de stocker du vide.
        DownloadFilterStore.save(DownloadFilter(), for: canonical, defaults: suite)
        XCTAssertNil(suite.data(forKey: DownloadFilterStore.key(canonical)))
    }

    // MARK: Plafond d'espace

    func testQuotaWithoutLimitNeverBlocks() {
        let quota = StorageQuota(bytes: 0)
        XCTAssertFalse(quota.isActive)
        XCTAssertTrue(quota.allows(currentBytes: 1_000_000_000_000))
        XCTAssertFalse(quota.isReached(currentBytes: 1_000_000_000_000))
    }

    func testQuotaStopsAtLimit() {
        let quota = StorageQuota(bytes: 10_000_000_000)
        XCTAssertTrue(quota.allows(currentBytes: 9_000_000_000, incoming: 500_000_000))
        XCTAssertFalse(quota.allows(currentBytes: 9_900_000_000, incoming: 500_000_000))
        XCTAssertFalse(quota.isReached(currentBytes: 9_000_000_000))
        XCTAssertTrue(quota.isReached(currentBytes: 10_000_000_000))
        XCTAssertTrue(quota.isReached(currentBytes: 12_000_000_000))
    }

    func testQuotaGigabytesMapping() {
        XCTAssertEqual(StorageQuota.gigabytes(for: 0), 0)
        XCTAssertEqual(StorageQuota.gigabytes(for: 5_000_000_000), 5)
        // Une valeur entre deux paliers retombe sur le palier inférieur connu.
        XCTAssertEqual(StorageQuota.gigabytes(for: 7_500_000_000), 5)
        XCTAssertEqual(StorageQuota.gigabytes(for: 100_000_000_000), 100)
    }

    func testQuotaStoreRoundTrip() {
        let suite = UserDefaults(suiteName: "quota.tests")!
        suite.removePersistentDomain(forName: "quota.tests")
        XCTAssertEqual(StorageQuota.load(defaults: suite).bytes, 0)
        StorageQuota.save(StorageQuota(bytes: 25_000_000_000), defaults: suite)
        XCTAssertEqual(StorageQuota.load(defaults: suite).bytes, 25_000_000_000)
        StorageQuota.save(StorageQuota(bytes: 0), defaults: suite)
        XCTAssertNil(suite.object(forKey: StorageQuota.defaultsKey))
    }
}

/// Tags et GIF uniques RedGifs.
final class RedgifsTagAndGifTests: XCTestCase {
    func testTagForms() throws {
        XCTAssertEqual(try RedgifsAPI.tag("#Latex"), "latex")
        XCTAssertEqual(try RedgifsAPI.tag("rg/#Latex"), "latex")
        XCTAssertEqual(try RedgifsAPI.tag("https://www.redgifs.com/niches/latex"), "latex")
        XCTAssertEqual(try RedgifsAPI.tag("Two Words"), "two-words")
        XCTAssertThrowsError(try RedgifsAPI.tag(""))
        XCTAssertThrowsError(try RedgifsAPI.tag("a"))
    }

    func testGifIDForms() {
        XCTAssertEqual(RedgifsAPI.gifID("https://www.redgifs.com/watch/DelectableIncompleteShorebird"),
                       "delectableincompleteshorebird")
        XCTAssertEqual(RedgifsAPI.gifID("https://redgifs.com/ifr/abc123xyz"), "abc123xyz")
        XCTAssertEqual(RedgifsAPI.gifID("abc123xyz"), "abc123xyz")
        XCTAssertNil(RedgifsAPI.gifID("ab"))
        XCTAssertNil(RedgifsAPI.gifID("pas un id"))
    }

    func testSearchURLShape() {
        let url = RedgifsAPI.searchURL(text: "latex", page: 2, count: 80)
        XCTAssertTrue(url.absoluteString.hasPrefix("https://api.redgifs.com/v2/gifs/search?"))
        XCTAssertTrue(url.absoluteString.contains("search_text=latex"))
        XCTAssertTrue(url.absoluteString.contains("order=new"))
        XCTAssertTrue(url.absoluteString.contains("page=2"))
    }

    func testFeedSourceParsesTagAndGif() throws {
        XCTAssertEqual(try FeedSource.parse("rg/#latex"), .redgifsTag("latex"))
        XCTAssertEqual(try FeedSource.parse("https://www.redgifs.com/watch/abc123xyz"), .redgifsGif("abc123xyz"))
        // Un pseudo nu reste un compte : la forme explicite décide.
        XCTAssertEqual(try FeedSource.parse("rg/upset_trash_3094"), .redgifsUser("upset_trash_3094"))
        XCTAssertEqual(try FeedSource.parse("rg/#latex").id, "rg/#latex")
        XCTAssertEqual(try FeedSource.parse("rg/#latex").folderName, "redgifs.tag.latex")
    }

    func testTagAndGifMapping() {
        XCTAssertEqual(FeedSource.redgifsTag("latex").id, "rg/#latex")
        XCTAssertEqual(FeedSource.redgifsTag("latex").folderName, "redgifs.tag.latex")
        XCTAssertEqual(FeedSource.redgifsGif("abc123xyz").id, "rg/gif/abc123xyz")
        XCTAssertEqual(FeedSource.redgifsGif("abc123xyz").folderName, "redgifs.gif.abc123xyz")
        // Les trois formes RedGifs restent des collections distinctes.
        XCTAssertNotEqual(FeedSource.redgifsTag("x").folderName, FeedSource.redgifsUser("x").folderName)
        XCTAssertNotEqual(FeedSource.redgifsGif("x").folderName, FeedSource.redgifsUser("x").folderName)
    }

    func testXStatusLinkIsRefusedWithItsOwnError() {
        XCTAssertThrowsError(try FeedSource.parse("https://x.com/nasa/status/1234567890")) { error in
            guard case XTwitterError.postUnsupported = error else {
                return XCTFail("erreur inattendue : \(error)")
            }
        }
        // Une adresse de profil reste acceptée.
        XCTAssertEqual(try FeedSource.parse("https://x.com/nasa"), .twitterUser("nasa"))
    }
}
