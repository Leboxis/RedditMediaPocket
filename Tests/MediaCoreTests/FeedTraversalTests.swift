import XCTest
@testable import MediaCore

final class FeedTraversalTests: XCTestCase {
    private func post(_ id: String) -> Post { Post(id: id, title: id, html: "") }

    @MainActor func testKnownHeadDoesNotOverwriteInterruptedHistory() async throws {
        var saved = FeedCheckpoint(cursor: "t3_old", visited: ["t3_head", "t3_old"])
        var requests: [String?] = []
        var downloaded: [String] = []
        let completed = try await FeedTraversal.run(checkpoint: saved, fetch: { after in
            requests.append(after)
            switch after {
            case nil: return [self.post("t3_head")]
            case "t3_old": return [self.post("t3_missing")]
            default: return []
            }
        }, process: { downloaded += $0.map(\.id) }, persist: { saved = $0 })
        XCTAssertTrue(completed)
        XCTAssertEqual(requests, [nil, "t3_old", "t3_missing"])
        XCTAssertEqual(downloaded, ["t3_missing"])
        XCTAssertNil(saved.cursor)
    }

    @MainActor func testRateLimitedPageIsRetriedWithoutDownloadingExistingFiles() async throws {
        var saved = FeedCheckpoint()
        var files = Set<String>()
        var writes: [String] = []
        let page = [post("t3_one"), post("t3_two")]
        do {
            _ = try await FeedTraversal.run(checkpoint: saved, fetch: { _ in page }, process: { posts in
                for post in posts {
                    if post.id == "t3_two" { throw NetworkError.limited(service: "Reddit", until: nil) }
                    files.insert(post.id)
                    writes.append(post.id)
                }
            }, persist: { saved = $0 })
            XCTFail("Expected rate limit")
        } catch NetworkError.limited { }
        XCTAssertTrue(saved.visited.isEmpty)
        XCTAssertNil(saved.cursor)
        _ = try await FeedTraversal.run(checkpoint: saved, fetch: { $0 == nil ? page : [] }, process: { posts in
            for post in posts where files.insert(post.id).inserted { writes.append(post.id) }
        }, persist: { saved = $0 })
        XCTAssertEqual(writes, ["t3_one", "t3_two"])
        XCTAssertEqual(Set(saved.visited), ["t3_one", "t3_two"])
    }

    @MainActor func testInterruptedNewsKeepsBothFrontiers() async throws {
        var saved = FeedCheckpoint(cursor: "t3_old", frontier: "t3_new", visited: ["t3_head", "t3_new", "t3_old"])
        var requests: [String?] = []
        do {
            _ = try await FeedTraversal.run(checkpoint: saved, fetch: { after in
                requests.append(after)
                if after == nil { return [self.post("t3_head")] }
                throw NetworkError.limited(service: "Reddit", until: nil)
            }, process: { _ in XCTFail("Known posts must not be processed") }, persist: { saved = $0 })
            XCTFail("Expected rate limit")
        } catch NetworkError.limited { }
        XCTAssertEqual(requests, ["t3_new"])
        XCTAssertEqual(saved.cursor, "t3_old")
        XCTAssertEqual(saved.frontier, "t3_new")
    }

    @MainActor func testHistoryCrossesKnownPageToReachMissingMedia() async throws {
        var saved = FeedCheckpoint(cursor: "t3_old", visited: ["t3_head", "t3_old", "t3_overlap"])
        var downloaded: [String] = []
        let completed = try await FeedTraversal.run(checkpoint: saved, fetch: { after in
            switch after {
            case nil: return [self.post("t3_head")]
            case "t3_old": return [self.post("t3_overlap")]
            case "t3_overlap": return [self.post("t3_missing")]
            default: return []
            }
        }, process: { downloaded += $0.map(\.id) }, persist: { saved = $0 })
        XCTAssertTrue(completed)
        XCTAssertEqual(downloaded, ["t3_missing"])
    }

    @MainActor func testPageBudgetKeepsResumeCursor() async throws {
        var saved = FeedCheckpoint()
        let completed = try await FeedTraversal.run(checkpoint: saved, maximumPages: 1,
            fetch: { _ in [self.post("t3_one")] }, process: { _ in }, persist: { saved = $0 })
        XCTAssertFalse(completed)
        XCTAssertEqual(saved.cursor, "t3_one")
    }

    @MainActor func testCancellationDuringHistoryDoesNotCommitThePage() async throws {
        var saved = FeedCheckpoint(cursor: "t3_old", visited: ["t3_head", "t3_old"])
        do {
            _ = try await FeedTraversal.run(checkpoint: saved, fetch: { after in
                [self.post(after == nil ? "t3_head" : "t3_pending")]
            }, process: { _ in throw CancellationError() }, persist: { saved = $0 })
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(saved.cursor, "t3_old")
        XCTAssertFalse(saved.visited.contains("t3_pending"))
    }

    @MainActor func testNewsBudgetResumesAtLastCompletedPage() async throws {
        var saved = FeedCheckpoint(frontier: "t3_new1", visited: ["t3_old", "t3_new1"])
        var requests: [String?] = []
        let capped = try await FeedTraversal.run(checkpoint: saved, maximumPages: 1, fetch: { after in
            requests.append(after)
            return [self.post("t3_new2")]
        }, process: { _ in }, persist: { saved = $0 })
        XCTAssertFalse(capped)
        XCTAssertEqual(saved.frontier, "t3_new2")
        XCTAssertNil(saved.cursor)
        let completed = try await FeedTraversal.run(checkpoint: saved, fetch: { after in
            requests.append(after)
            return [self.post("t3_old")]
        }, process: { _ in XCTFail("Known history must not be processed") }, persist: { saved = $0 })
        XCTAssertTrue(completed)
        XCTAssertEqual(requests, ["t3_new1", "t3_new2"])
        XCTAssertNil(saved.frontier)
    }

    @MainActor func testSavedCommentIsAValidResumeCursor() async throws {
        var saved = FeedCheckpoint()
        let completed = try await FeedTraversal.run(checkpoint: saved, maximumPages: 1,
            validCursor: { $0.hasPrefix("t3_") || $0.hasPrefix("t1_") },
            fetch: { _ in [self.post("t1_comment")] }, process: { _ in }, persist: { saved = $0 })
        XCTAssertFalse(completed)
        XCTAssertEqual(saved.cursor, "t1_comment")
    }

    @MainActor func testRepeatedPageStopsWithoutLooping() async throws {
        var requests = 0
        var downloaded: [String] = []
        let completed = try await FeedTraversal.run(checkpoint: FeedCheckpoint(), fetch: { _ in
            requests += 1
            return [self.post("t3_one")]
        }, process: { downloaded += $0.map(\.id) }, persist: { _ in })
        XCTAssertTrue(completed)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(downloaded, ["t3_one"])
    }
}
