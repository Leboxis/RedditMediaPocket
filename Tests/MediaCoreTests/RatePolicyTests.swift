import XCTest
@testable import MediaCore

final class RatePolicyTests: XCTestCase {
    func testRetryAfterSecondsAndDate() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(RatePolicy.retryDate(retryAfter: "120", reset: nil, now: now), now.addingTimeInterval(120))
        XCTAssertEqual(RatePolicy.retryDate(retryAfter: "Thu, 01 Jan 1970 00:05:00 GMT", reset: nil, now: now), now.addingTimeInterval(300))
    }
    /// Reddit's RSS endpoints answer 429 with `x-ratelimit-reset` and no `Retry-After`.
    func testRateLimitResetIsUsedWhenRetryAfterIsAbsent() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(RatePolicy.retryDate(retryAfter: nil, reset: "48", now: now), now.addingTimeInterval(48))
        XCTAssertEqual(RatePolicy.retryDate(retryAfter: "invalid", reset: "48", now: now), now.addingTimeInterval(48))
        XCTAssertEqual(RatePolicy.retryDate(retryAfter: "120", reset: "48", now: now), now.addingTimeInterval(120))
    }
    /// No usable header means no deadline at all: the app must not invent a delay,
    /// otherwise a manual restart stays blocked for a wait nobody asked for.
    func testNoDeadlineIsInventedWhenHeadersAreMissingOrInvalid() {
        let now = Date(timeIntervalSince1970: 1000)
        for value in [nil, "", "invalid", "nan", "inf", "-1"] as [String?] {
            XCTAssertNil(RatePolicy.retryDate(retryAfter: value, reset: nil, now: now))
            XCTAssertNil(RatePolicy.retryDate(retryAfter: value, reset: value, now: now))
        }
        XCTAssertNil(RatePolicy.retryDate(retryAfter: nil, reset: "0", now: now))
    }
    /// A deadline that is not in the future is the server saying "now", and blocks nothing.
    func testDeadlineInThePastNeverBlocks() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(RatePolicy.retryDate(retryAfter: "0", reset: nil, now: now), now)
        XCTAssertNil(ServiceLimits(deadlines: ["Reddit": now]).blockedUntil(service: "Reddit", now: now))
    }
    func testServicesAreIsolatedAndCDNsShareLimits() {
        XCTAssertEqual(RatePolicy.service(for: "i.redd.it"), RatePolicy.service(for: "www.reddit.com"))
        XCTAssertEqual(RatePolicy.service(for: "api.redgifs.com"), RatePolicy.service(for: "media.redgifs.com"))
        XCTAssertNotEqual(RatePolicy.service(for: "redgifs.com.example.com"), "RedGIFs")
        var limits = ServiceLimits()
        let now = Date()
        limits.record(service: "Reddit", until: now.addingTimeInterval(900))
        XCTAssertNotNil(limits.blockedUntil(service: "Reddit", now: now))
        XCTAssertNil(limits.blockedUntil(service: "RedGIFs", now: now))
        XCTAssertNil(limits.blockedUntil(service: "Reddit", now: now.addingTimeInterval(901)))
        limits.record(service: "Reddit", until: now.addingTimeInterval(10))
        XCTAssertEqual(limits.blockedUntil(service: "Reddit", now: now), now.addingTimeInterval(900))
    }
}
