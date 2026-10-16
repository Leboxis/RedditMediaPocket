import XCTest
@testable import MediaCore

final class XFetishIPv4CancellationTests: XCTestCase {
    func testCancellationBeforeRegistrationIsNotLost() {
        let cancellation = XFetishIPv4Cancellation()
        cancellation.cancel()
        var cancelled = false
        cancellation.register { cancelled = true }
        XCTAssertTrue(cancelled)
    }

    func testCancellationAfterRegistrationCallsAction() {
        let cancellation = XFetishIPv4Cancellation()
        var cancelled = false
        cancellation.register { cancelled = true }
        cancellation.cancel()
        XCTAssertTrue(cancelled)
    }

    func testCompletedConnectionClearsItsAction() {
        let cancellation = XFetishIPv4Cancellation()
        cancellation.register { XCTFail("A completed connection must not be resumed again") }
        cancellation.clear()
        cancellation.cancel()
    }
}
