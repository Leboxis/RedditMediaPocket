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

    // MARK: - Plafond de cadence configurable

    @MainActor
    func testCurrentPacingLimitDefaultsTo58() {
        XCTAssertEqual(KDriveRateLimitCenter.currentPacingLimit(defaults: defaults), 58)
        XCTAssertEqual(KDriveRateLimitCenter.pacingLimitPerMinute, 58)
    }

    @MainActor
    func testCurrentPacingLimitReadsConfiguredValue() {
        for value in [30, 60] {
            defaults.set(value, forKey: KDriveRateLimitCenter.pacingLimitDefaultsKey)
            XCTAssertEqual(KDriveRateLimitCenter.currentPacingLimit(defaults: defaults), value)
        }
    }

    @MainActor
    func testCurrentPacingLimitClampsOutOfRangeValues() {
        defaults.set(0, forKey: KDriveRateLimitCenter.pacingLimitDefaultsKey)
        XCTAssertEqual(KDriveRateLimitCenter.currentPacingLimit(defaults: defaults), 10)
        defaults.set(9, forKey: KDriveRateLimitCenter.pacingLimitDefaultsKey)
        XCTAssertEqual(KDriveRateLimitCenter.currentPacingLimit(defaults: defaults), 10)
        defaults.set(61, forKey: KDriveRateLimitCenter.pacingLimitDefaultsKey)
        XCTAssertEqual(KDriveRateLimitCenter.currentPacingLimit(defaults: defaults), 60)
        defaults.set(500, forKey: KDriveRateLimitCenter.pacingLimitDefaultsKey)
        XCTAssertEqual(KDriveRateLimitCenter.currentPacingLimit(defaults: defaults), 60)
    }

    @MainActor
    func testAPIRateLabelUsesConfiguredLimit() {
        defaults.set(30, forKey: KDriveRateLimitCenter.pacingLimitDefaultsKey)
        let center = KDriveRateLimitCenter(defaults: defaults)
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertEqual(center.pacingLimit, 30)
        XCTAssertEqual(center.reserveSlot(now: t0), 0)
        XCTAssertEqual(center.apiRateLabel, "1/30 req/min")

        // Mise à jour externe (@AppStorage) prise en compte sans recréer le centre.
        defaults.set(60, forKey: KDriveRateLimitCenter.pacingLimitDefaultsKey)
        center.refreshPacingInfo(now: t0)
        XCTAssertEqual(center.pacingLimit, 60)
        XCTAssertEqual(center.apiRateLabel, "1/60 req/min")
    }

    @MainActor
    func testUpdatePacingLimitAdjustsNextSlotDelayAndSpacing() {
        let center = KDriveRateLimitCenter(defaults: defaults)
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertEqual(center.reserveSlot(now: t0), 0)
        XCTAssertEqual(center.nextSlotDelay, 60.0 / 57.0, accuracy: 0.001)
        XCTAssertEqual(center.apiRateLabel, "1/58 req/min")

        defaults.set(30, forKey: KDriveRateLimitCenter.pacingLimitDefaultsKey)
        center.updatePacingLimit(30, now: t0)
        XCTAssertEqual(center.nextSlotDelay, 60.0 / 29.0, accuracy: 0.001)
        XCTAssertTrue(center.apiRateLabel.hasSuffix("/30 req/min"))

        // Espacement effectif : à 1 s du départ, il reste ~1,07 s à attendre.
        XCTAssertEqual(
            center.reserveSlot(now: t0.addingTimeInterval(1)),
            60.0 / 29.0 - 1,
            accuracy: 0.001
        )
    }

    @MainActor
    func testUpdatePacingLimitClampsLimit() {
        let center = KDriveRateLimitCenter(defaults: defaults)
        XCTAssertEqual(center.reserveSlot(now: Date()), 0)

        defaults.set(500, forKey: KDriveRateLimitCenter.pacingLimitDefaultsKey)
        center.updatePacingLimit(500)
        XCTAssertEqual(center.pacingLimit, 60)
        XCTAssertTrue(center.apiRateLabel.hasSuffix("/60 req/min"))

        defaults.set(3, forKey: KDriveRateLimitCenter.pacingLimitDefaultsKey)
        center.updatePacingLimit(3)
        XCTAssertEqual(center.pacingLimit, 10)
        XCTAssertTrue(center.apiRateLabel.hasSuffix("/10 req/min"))
    }

    @MainActor
    func testSyncAtOfficialLimitWithCap60DoesNotSetLimitedUntil() {
        // Enregistre 60 requêtes dans la fenêtre sans attendre l'espacement.
        defaults.set(false, forKey: KDriveRateLimitCenter.pacingEnabledDefaultsKey)
        defaults.set(60, forKey: KDriveRateLimitCenter.pacingLimitDefaultsKey)
        let center = KDriveRateLimitCenter(defaults: defaults)
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        for _ in 0..<60 {
            XCTAssertEqual(center.reserveSlot(now: t0), 0)
        }
        XCTAssertEqual(center.requestsLastMinute, 60)

        defaults.set(true, forKey: KDriveRateLimitCenter.pacingEnabledDefaultsKey)
        center.sync(statusCode: 200, retryAfter: nil, isRateLimitBody: false, now: t0)
        XCTAssertNil(center.limitedUntil)
    }

    @MainActor
    func testSyncAboveOfficialLimitStillSetsLimitedUntil() {
        defaults.set(false, forKey: KDriveRateLimitCenter.pacingEnabledDefaultsKey)
        let center = KDriveRateLimitCenter(defaults: defaults)
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        for _ in 0..<61 {
            XCTAssertEqual(center.reserveSlot(now: t0), 0)
        }

        defaults.set(true, forKey: KDriveRateLimitCenter.pacingEnabledDefaultsKey)
        center.sync(statusCode: 200, retryAfter: nil, isRateLimitBody: false, now: t0)
        XCTAssertEqual(center.limitedUntil, t0.addingTimeInterval(60))
    }
}
