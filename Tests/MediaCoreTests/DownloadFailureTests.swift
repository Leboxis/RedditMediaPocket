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

    /// La règle de relance vit dans `MediaCore` pour être testable ; elle était
    /// dupliquée dans `Downloader` où rien ne pouvait la vérifier.
    func testTransientFailureIsRetriedTwiceThenAbandoned() {
        let transient = URLError(.networkConnectionLost)
        XCTAssertTrue(RetryPolicy.shouldRetry(transient, attempt: 0))
        XCTAssertTrue(RetryPolicy.shouldRetry(transient, attempt: 1))
        XCTAssertFalse(RetryPolicy.shouldRetry(transient, attempt: 2))
        XCTAssertFalse(RetryPolicy.shouldRetry(transient, attempt: 3))
    }

    func testRetryableSetMatchesTheSkipPolicy() {
        // Une erreur non transitoire doit être ni rejouée, ni comptée « skipped » :
        // les deux décisions utilisent la même classification.
        // `URLError` et `NetworkError` n'ont pas de supertype commun utile : sans
        // annotation explicite, le littéral serait typé `[Any]` et ne compilerait pas.
        let transient: [Error] = [URLError(.timedOut), URLError(.notConnectedToInternet),
                                  NetworkError.refused(408), NetworkError.refused(500),
                                  NetworkError.refused(503)]
        for error in transient {
            XCTAssertTrue(RetryPolicy.shouldRetry(error, attempt: 0), "\(error)")
            XCTAssertTrue(DownloadFailurePolicy.isTransient(error), "\(error)")
        }
        let fatal: [Error] = [NetworkError.refused(404), NetworkError.refused(403),
                              NetworkError.refused(429),
                              NetworkError.limited(service: "Reddit", until: nil),
                              CancellationError(), URLError(.cancelled)]
        for error in fatal {
            XCTAssertFalse(RetryPolicy.shouldRetry(error, attempt: 0), "\(error)")
        }
    }

    func testBackoffDoublesAndNeverHangs() {
        XCTAssertEqual(RetryPolicy.delay(forAttempt: 1), .seconds(2))
        XCTAssertEqual(RetryPolicy.delay(forAttempt: 2), .seconds(4))
        // Une valeur aberrante ne doit pas produire une attente nulle ou négative.
        XCTAssertGreaterThan(RetryPolicy.delay(forAttempt: 0), .zero)
        XCTAssertGreaterThan(RetryPolicy.delay(forAttempt: -5), .zero)
    }

    /// Previously `precondition`: it killed the process instead of throwing.
    func testNonPositiveConcurrencyLimitThrowsInsteadOfTrapping() async throws {
        for limit in [0, -1] {
            do {
                try await ConcurrentDownloads.run([1, 2], limit: limit) { _ in
                    XCTFail("Do not transfer with an invalid limit")
                }
                XCTFail("Expected invalid limit")
            } catch ConcurrentDownloads.Failure.invalidLimit {
                XCTAssertFalse(limit > 0)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }
}

private actor FailedMediaProbe {
    var attempts: [Int] = []
    func attempt(_ id: Int) { attempts.append(id) }
}
