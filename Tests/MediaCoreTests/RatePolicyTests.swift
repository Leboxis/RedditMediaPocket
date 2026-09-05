import XCTest
@testable import MediaCore

final class RatePolicyTests: XCTestCase {
    func testRetryAfterSecondsAndDate() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(RatePolicy.retryDate(header: "120", now: now), now.addingTimeInterval(120))
        XCTAssertEqual(RatePolicy.retryDate(header: "Thu, 01 Jan 1970 00:05:00 GMT", now: now), now.addingTimeInterval(300))
    }
    func testMissingOrInvalidRetryAfterUsesFallback() {
        let now = Date(timeIntervalSince1970: 1000)
        for value in [nil, "invalid", "nan", "inf", "-1"] as [String?] {
            XCTAssertEqual(RatePolicy.retryDate(header: value, now: now), now.addingTimeInterval(900))
        }
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
