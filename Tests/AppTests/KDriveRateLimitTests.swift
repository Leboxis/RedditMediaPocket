import XCTest
@testable import RedditMediaPocket

final class KDriveRateLimitTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "KDriveRateLimitTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testPacingEnabledByDefaultAndEnforcesSpacing() {
        let center = KDriveRateLimitCenter(defaults: defaults)
        XCTAssertTrue(center.isPacingEnabled)

        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertEqual(center.reserveSlot(now: t0), 0)
        XCTAssertGreaterThan(center.reserveSlot(now: t0), 0)
        XCTAssertEqual(center.requestsLastMinute, 1)
        XCTAssertEqual(center.apiRateLabel, "1/58 req/min")
    }

    @MainActor
    func testDisablingPacingRemovesClientDelayAndOfficialCountBlock() {
        defaults.set(false, forKey: KDriveRateLimitCenter.pacingEnabledDefaultsKey)
        let center = KDriveRateLimitCenter(defaults: defaults)
        XCTAssertFalse(center.isPacingEnabled)

        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        for index in 0..<65 {
            XCTAssertEqual(center.reserveSlot(now: t0.addingTimeInterval(Double(index) * 0.1)), 0)
        }
        XCTAssertEqual(center.requestsLastMinute, 65)
        XCTAssertEqual(center.nextSlotDelay, 0)
        XCTAssertEqual(center.apiRateLabel, "65 req/min")

        let checkTime = t0.addingTimeInterval(6.5)
        center.sync(statusCode: 200, retryAfter: nil, isRateLimitBody: false, now: checkTime)
        XCTAssertNil(center.limitedUntil)

        center.sync(statusCode: 429, retryAfter: 30, isRateLimitBody: true, now: checkTime)
        XCTAssertEqual(center.limitedUntil, checkTime.addingTimeInterval(30))
        XCTAssertGreaterThan(center.reserveSlot(now: checkTime.addingTimeInterval(1)), 0)
    }

    @MainActor
    func testRefreshPacingInfoClearsDelayWhenToggledOff() {
        let center = KDriveRateLimitCenter(defaults: defaults)
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertEqual(center.reserveSlot(now: t0), 0)
        XCTAssertGreaterThan(center.nextSlotDelay, 0)

        defaults.set(false, forKey: KDriveRateLimitCenter.pacingEnabledDefaultsKey)
        center.refreshPacingInfo(now: t0)
        XCTAssertEqual(center.nextSlotDelay, 0)
        XCTAssertEqual(center.apiRateLabel, "1 req/min")
    }

    func testConcurrentUploadLimitDefaultsAndClamping() {
        XCTAssertEqual(KDriveService.currentConcurrentUploadLimit(defaults: defaults), 4)

        for option in [4, 6, 8, 10] {
            defaults.set(option, forKey: KDriveService.concurrentUploadsDefaultsKey)
            XCTAssertEqual(KDriveService.currentConcurrentUploadLimit(defaults: defaults), option)
        }

        defaults.set(7, forKey: KDriveService.concurrentUploadsDefaultsKey)
        XCTAssertEqual(KDriveService.currentConcurrentUploadLimit(defaults: defaults), 4)
    }
}
