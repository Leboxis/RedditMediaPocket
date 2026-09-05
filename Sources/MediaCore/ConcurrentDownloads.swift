import Foundation

public enum ConcurrentDownloads {
    /// Refill a free slot immediately, without waiting for the other transfers.
    public static func run<Item: Sendable>(_ items: [Item], limit: Int = 3,
        operation: @escaping @Sendable (Item) async throws -> Void) async throws {
        precondition(limit > 0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = items.makeIterator()
            for _ in 0..<min(limit, items.count) {
                try Task.checkCancellation()
                if let item = iterator.next() { group.addTask { try await operation(item) } }
            }
            do {
                while try await group.next() != nil {
                    try Task.checkCancellation()
                    if let item = iterator.next() { group.addTask { try await operation(item) } }
                }
            } catch { group.cancelAll(); throw error }
        }
    }
}
