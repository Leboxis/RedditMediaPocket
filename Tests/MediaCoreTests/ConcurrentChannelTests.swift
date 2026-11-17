import XCTest
@testable import MediaCore

final class ConcurrentChannelTests: XCTestCase {
    func testNextReturnsItemsInOrderThenNilAfterFinish() async {
        let channel = ConcurrentChannel<Int>()
        channel.send(1)
        channel.send(2)
        channel.finish()
        channel.send(3)
        var received: [Int] = []
        while let item = await channel.next() { received.append(item) }
        XCTAssertEqual(received, [1, 2])
    }

    func testWaitingConsumerIsWokenByFinish() async {
        let channel = ConcurrentChannel<Int>()
        let waiter = Task { await channel.next() }
        try? await Task.sleep(for: .milliseconds(50))
        channel.finish()
        let item = await waiter.value
        XCTAssertNil(item)
    }

    func testWaitingConsumerIsWokenByNextSend() async {
        let channel = ConcurrentChannel<Int>()
        let waiter = Task { await channel.next() }
        try? await Task.sleep(for: .milliseconds(50))
        channel.send(7)
        let item = await waiter.value
        XCTAssertEqual(item, 7)
    }

    func testCancelledConsumerIsWokenWithoutItem() async {
        let channel = ConcurrentChannel<Int>()
        let waiter = Task { await channel.next() }
        try? await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        let item = await waiter.value
        XCTAssertNil(item)
        channel.finish()
    }

    func testConcurrentConsumersReceiveEachItemExactlyOnce() async throws {
        let channel = ConcurrentChannel<Int>()
        let total = 500
        let producer = Task {
            for i in 0..<total { channel.send(i) }
            channel.finish()
        }
        let received = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    while let _ = await channel.next() { await received.increment() }
                }
            }
            try await group.waitForAll()
        }
        await producer.value
        let count = await received.value
        XCTAssertEqual(count, total)
    }

    func testCancelledConsumerDoesNotWakeOtherConsumers() async throws {
        let channel = ConcurrentChannel<Int>()
        let firstWaiter = Task { await channel.next() }
        let secondWaiter = Task { await channel.next() }
        try? await Task.sleep(for: .milliseconds(50))
        firstWaiter.cancel()
        let first = await firstWaiter.value
        XCTAssertNil(first)
        channel.send(42)
        let second = await secondWaiter.value
        XCTAssertEqual(second, 42)
        channel.finish()
    }

    private actor Counter {
        private var count = 0
        func increment() { count += 1 }
        var value: Int { count }
    }
}
