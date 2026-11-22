import XCTest
import MediaCore
@testable import RedditMediaPocket

final class KDriveFreshnessAppTests: XCTestCase {
    func testUserCollectionFeedSourceRoundTrip() {
        XCTAssertEqual(UserCollection(name: "alice").feedSource, .user("alice"))
        XCTAssertEqual(UserCollection(name: "pics", isSubreddit: true).feedSource, .subreddit("pics"))
        XCTAssertEqual(UserCollection(name: "alice", isSaved: true).feedSource, .saved("alice"))
        XCTAssertEqual(UserCollection(name: "nasa", isTwitter: true).feedSource, .twitterUser("nasa"))
        XCTAssertEqual(UserCollection(name: "nasa", isTikTok: true).feedSource, .tiktokUser("nasa"))
        XCTAssertEqual(UserCollection(name: "nasa", isTikTokSaved: true).feedSource, .tiktokSaved("nasa"))
        XCTAssertEqual(UserCollection(name: "nasa", isInstagram: true).feedSource, .instagramUser("nasa"))
        XCTAssertEqual(UserCollection(name: "creator", isRedGifs: true).feedSource, .redgifsUser("creator"))
        XCTAssertEqual(UserCollection(name: "nature", isRedGifsTag: true).feedSource, .redgifsTag("nature"))
        XCTAssertEqual(UserCollection(name: "abc123", isRedGifsGif: true).feedSource, .redgifsGif("abc123"))
        XCTAssertNil(UserCollection(name: "videos", isTikTokVideo: true).feedSource)
        XCTAssertNil(UserCollection(name: "posts", isRedditPosts: true).feedSource)
    }

    @MainActor
    func testFreshnessCenterCanonicalLookupAndMarkUploaded() {
        let center = KDriveFreshnessCenter.shared
        center.stopChecking()
        center.markUploaded(collectionLabel: "alice", remoteFileCount: 42)
        XCTAssertEqual(center.status(for: "alice"), .upToDate(remoteCount: 42, checkedSourceCount: 0))
        XCTAssertEqual(center.status(for: "u/alice"), .upToDate(remoteCount: 42, checkedSourceCount: 0))
        XCTAssertEqual(center.status(for: "u/ALICE"), .upToDate(remoteCount: 42, checkedSourceCount: 0))
    }
}
