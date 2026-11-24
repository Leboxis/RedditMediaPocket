import XCTest
import Observation
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

    func testTricolorStatusTintColors() {
        XCTAssertEqual(
            KDriveFreshnessStatus.upToDate(remoteCount: 10, checkedSourceCount: 5).tintColor,
            DS.calmSage
        )
        XCTAssertEqual(
            KDriveFreshnessStatus.outdated(newOnSourceCount: 3, fullPageMissing: false, localPendingCount: 0, remoteCount: 10).tintColor,
            DS.calmAmber
        )
        XCTAssertEqual(
            KDriveFreshnessStatus.pendingUpload(localPendingCount: 2, remoteCount: 10).tintColor,
            DS.calmAmber
        )
        XCTAssertEqual(
            KDriveFreshnessStatus.notOnDrive(sourceNewCount: 5, localPendingCount: 0).tintColor,
            DS.calmRose
        )
        XCTAssertEqual(
            KDriveFreshnessStatus.unavailable(reason: "HTTP 429").tintColor,
            DS.calmRose
        )
    }

    @MainActor
    func testRemoteFolderLookupDoesNotTriggerObservationMutationAndCachesMisses() {
        final class Flag: @unchecked Sendable { var value = false }
        let center = KDriveFreshnessCenter.shared
        center.stopChecking()
        center.applyDirectoryIndex([
            KDriveFolderItem(id: 101, name: "Ualpha_test", type: "dir")
        ])
        defer { center.applyDirectoryIndex([]) }

        let invalidated = Flag()
        let found: KDriveFolderItem? = withObservationTracking {
            let hit = center.remoteFolder(for: "u/alpha_test")
            _ = center.remoteFolder(for: "u/absent_test")
            return hit
        } onChange: {
            invalidated.value = true
        }

        XCTAssertEqual(found?.id, 101)
        XCTAssertFalse(invalidated.value, "Reading remoteFolder must not mutate tracked @Observable state")

        let cachedHit = center.remoteFolder(for: "u/alpha_test")
        let cachedMiss = center.remoteFolder(for: "u/absent_test")
        XCTAssertEqual(cachedHit?.id, 101)
        XCTAssertNil(cachedMiss)
        XCTAssertFalse(invalidated.value)

        center.applyDirectoryIndex([
            KDriveFolderItem(id: 202, name: "Uabsent_test", type: "dir")
        ])
        XCTAssertTrue(invalidated.value, "Updating remoteFolders must invalidate observers of remoteFolder")
        XCTAssertNil(center.remoteFolder(for: "u/alpha_test"))
        XCTAssertEqual(center.remoteFolder(for: "u/absent_test")?.id, 202)
    }

    @MainActor
    func testMixedCaseMarkUploadedDoesNotDuplicateStatusEntry() {
        let center = KDriveFreshnessCenter.shared
        center.stopChecking()
        let before = center.statusCounts.upToDate
        center.markUploaded(collectionLabel: "u/CaseTestUser", remoteFileCount: 5)
        let afterFirst = center.statusCounts.upToDate
        center.markUploaded(collectionLabel: "u/casetestuser", remoteFileCount: 6)
        let afterSecond = center.statusCounts.upToDate

        XCTAssertEqual(afterFirst, before + 1)
        XCTAssertEqual(afterSecond, afterFirst)
        XCTAssertEqual(center.status(for: "u/CASETESTUSER"), .upToDate(remoteCount: 6, checkedSourceCount: 0))
    }
}
