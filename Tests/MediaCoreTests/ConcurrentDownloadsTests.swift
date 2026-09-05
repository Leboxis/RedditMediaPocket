import XCTest
@testable import MediaCore

private actor TransferProbe {
    var active = 0
    var peak = 0
    var events: [String] = []
    func start(_ id: Int) { active += 1; peak = max(peak, active); events.append("start\(id)") }
    func end(_ id: Int) { active -= 1; events.append("end\(id)") }
    func snapshot() -> (Int, Int, [String]) { (active, peak, events) }
}

final class ConcurrentDownloadsTests: XCTestCase {
    func testThreeTransfersRefillWithoutWaitingForSlowest() async throws {
        let probe = TransferProbe()
        try await ConcurrentDownloads.run(Array(0..<9)) { id in
            await probe.start(id)
            try await Task.sleep(nanoseconds: id == 0 ? 300_000_000 : 10_000_000)
            await probe.end(id)
        }
        let (active, peak, events) = await probe.snapshot()
        XCTAssertEqual(active, 0)
        XCTAssertEqual(peak, 3)
        XCTAssertEqual(events.filter { $0.hasPrefix("end") }.count, 9)
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "start3")), try XCTUnwrap(events.firstIndex(of: "end0")))
    }

    func testFailureCancelsOtherTransfersAndStopsRefilling() async {
        enum Failure: Error { case refused }
        let probe = TransferProbe()
        do {
            try await ConcurrentDownloads.run(Array(0..<20)) { id in
                await probe.start(id)
                do {
                    if id == 0 {
                        try await Task.sleep(nanoseconds: 20_000_000)
                        throw Failure.refused
                    }
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch { await probe.end(id); throw error }
                await probe.end(id)
            }
            XCTFail("Expected refusal")
        } catch { XCTAssertTrue(error is Failure) }
        let (active, peak, events) = await probe.snapshot()
        XCTAssertEqual(active, 0)
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertFalse(events.contains("start3"))
    }

    func testStopCancelsAllActiveTransfers() async {
        let started = expectation(description: "Three active transfers")
        started.expectedFulfillmentCount = 3
        let probe = TransferProbe()
        let task = Task {
            try await ConcurrentDownloads.run(Array(0..<20)) { id in
                await probe.start(id)
                started.fulfill()
                do { try await Task.sleep(nanoseconds: 10_000_000_000) }
                catch { await probe.end(id); throw error }
                await probe.end(id)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let (active, _, events) = await probe.snapshot()
        XCTAssertEqual(active, 0)
        XCTAssertFalse(events.contains("start3"))
    }
}
