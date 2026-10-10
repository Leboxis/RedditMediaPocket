import XCTest
@testable import MediaCore

final class XMediaTraversalTests: XCTestCase {
    @MainActor func testCappedScanContinuesPastBudgetAndThenRestartsAtHead() async throws {
        var cursor: String?
        var requests: [String?] = []
        let fetch: (String?) async throws -> XMediaPage = { after in
            requests.append(after)
            return XMediaPage(posts: [], nextCursor: after == nil ? "older" : nil)
        }
        let capped = try await XMediaTraversal.run(cursor: cursor, maximumPages: 1,
            fetch: fetch, process: { _ in }, persist: { cursor = $0 })
        XCTAssertFalse(capped)
        XCTAssertEqual(cursor, "older")
        let completed = try await XMediaTraversal.run(cursor: cursor,
            fetch: fetch, process: { _ in }, persist: { cursor = $0 })
        XCTAssertTrue(completed)
        XCTAssertNil(cursor)
        _ = try await XMediaTraversal.run(cursor: cursor, maximumPages: 1,
            fetch: fetch, process: { _ in }, persist: { cursor = $0 })
        XCTAssertEqual(requests, [nil, "older", nil])
    }

    @MainActor func testFailedPageDoesNotAdvanceCursor() async throws {
        var cursor: String? = "pending"
        do {
            _ = try await XMediaTraversal.run(cursor: cursor,
                fetch: { _ in XMediaPage(posts: [], nextCursor: "next") },
                process: { _ in throw NetworkError.refused(503) }, persist: { cursor = $0 })
            XCTFail("Expected failure")
        } catch NetworkError.refused { }
        XCTAssertEqual(cursor, "pending")
    }

    @MainActor func testCancelledPageDoesNotAdvanceCursor() async throws {
        var cursor: String? = "pending"
        do {
            _ = try await XMediaTraversal.run(cursor: cursor,
                fetch: { _ in XMediaPage(posts: [], nextCursor: "next") },
                process: { _ in throw CancellationError() }, persist: { cursor = $0 })
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(cursor, "pending")
    }

    @MainActor func testCursorCycleIsRejected() async throws {
        do {
            _ = try await XMediaTraversal.run(cursor: "loop",
                fetch: { _ in XMediaPage(posts: [], nextCursor: "loop") },
                process: { _ in }, persist: { _ in XCTFail("Do not commit a cycle") })
            XCTFail("Expected invalid timeline")
        } catch XTwitterError.invalidTimeline { }
    }
}
