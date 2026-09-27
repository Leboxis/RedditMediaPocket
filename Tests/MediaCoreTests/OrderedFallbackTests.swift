import XCTest
@testable import MediaCore

final class OrderedFallbackTests: XCTestCase {
    func testSecondCandidateUsedWhenFirstIsGone() async throws {
        let log = AttemptLog()
        let url = try await OrderedFallback.first(["hd", "sd"]) { item in
            await log.record(item)
            if item == "hd" { throw NetworkError.refused(410) }
            return URL(string: "https://media.redgifs.com/x.mp4")!
        }
        XCTAssertEqual(url.absoluteString, "https://media.redgifs.com/x.mp4")
        let seen = await log.entries
        XCTAssertEqual(seen, ["hd", "sd"])
    }

    func testRateLimitStopsBeforeNextCandidate() async {
        let log = AttemptLog()
        do {
            _ = try await OrderedFallback.first(["hd", "sd"]) { item in
                await log.record(item)
                throw NetworkError.limited(service: "RedGIFs", until: nil)
            }
            XCTFail("A rate limit must propagate")
        } catch { }
        let seen = await log.entries
        XCTAssertEqual(seen, ["hd"])
    }

    func testCancellationPropagatesImmediately() async {
        let log = AttemptLog()
        do {
            _ = try await OrderedFallback.first(["hd", "sd"]) { item in
                await log.record(item)
                throw CancellationError()
            }
            XCTFail("Cancellation must propagate")
        } catch is CancellationError { }
        let seen = await log.entries
        XCTAssertEqual(seen, ["hd"])
    }

    func testTransientFailureStopsBeforeNextCandidate() async {
        let log = AttemptLog()
        do {
            _ = try await OrderedFallback.first(["hd", "sd"]) { item in
                await log.record(item)
                throw URLError(.timedOut)
            }
            XCTFail("A transient failure must propagate")
        } catch { }
        let seen = await log.entries
        XCTAssertEqual(seen, ["hd"])
    }

    func testAllCandidatesFailingThrowsLastError() async {
        do {
            _ = try await OrderedFallback.first(["hd", "sd"]) { item in
                throw item == "hd" ? NetworkError.refused(410) : NetworkError.refused(404)
            }
            XCTFail("All candidates failed")
        } catch NetworkError.refused(let code) {
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testEmptyCandidatesThrowInvalid() async {
        do {
            _ = try await OrderedFallback.first([String]()) { _ in
                XCTFail("No operation expected for empty candidates")
                return URL(string: "https://media.redgifs.com/x.mp4")!
            }
            XCTFail("Empty candidates must throw")
        } catch { }
    }
}

private actor AttemptLog {
    private(set) var entries: [String] = []
    func record(_ item: String) { entries.append(item) }
}
