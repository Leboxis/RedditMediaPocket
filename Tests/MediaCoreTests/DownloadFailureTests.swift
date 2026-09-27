import XCTest
@testable import MediaCore

final class DownloadFailureTests: XCTestCase {
    func testRateLimitStopsBatchBeforeNextMedia() async throws {
        let probe = FailedMediaProbe()
        do {
            try await ConcurrentDownloads.run([1, 2], limit: 1) { id in
                await probe.attempt(id)
                _ = try await DownloadFailurePolicy.attempt {
                    throw NetworkError.limited(service: "Reddit", until: nil)
                }
            }
            XCTFail("A rate limit must escape the unavailable-media handler")
        } catch NetworkError.limited { }
        let attempts = await probe.attempts
        XCTAssertEqual(attempts, [1])
    }

    func testMissingMediaIsSkippable() async throws {
        let saved = try await DownloadFailurePolicy.attempt { throw NetworkError.refused(404) }
        XCTAssertFalse(saved)
    }

    func testCancellationIsNeverSkippable() async throws {
        do {
            _ = try await DownloadFailurePolicy.attempt { throw CancellationError() }
            XCTFail("Cancellation must propagate")
        } catch is CancellationError { }
    }
}

private actor FailedMediaProbe {
    var attempts: [Int] = []
    func attempt(_ id: Int) { attempts.append(id) }
}
