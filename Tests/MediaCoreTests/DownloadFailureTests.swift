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

    func testURLSessionCancellationIsNeverSkippable() async throws {
        do {
            _ = try await DownloadFailurePolicy.attempt { throw URLError(.cancelled) }
            XCTFail("URLSession cancellation must propagate")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
    }

    func testCancellationDoesNotHideHTTPOrNetworkFailures() {
        XCTAssertTrue(DownloadFailurePolicy.isCancellation(CancellationError()))
        XCTAssertTrue(DownloadFailurePolicy.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(DownloadFailurePolicy.isCancellation(URLError(.timedOut)))
        XCTAssertFalse(DownloadFailurePolicy.isCancellation(NetworkError.refused(403)))
        XCTAssertFalse(DownloadFailurePolicy.isCancellation(NetworkError.limited(service: "X", until: nil)))
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
