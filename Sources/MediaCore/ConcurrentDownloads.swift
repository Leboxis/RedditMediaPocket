import Foundation

public enum ConcurrentDownloads {
    /// Une limite invalide est un défaut de l'appelant, pas une panne réseau :
    /// la lever comme une erreur rattrapable plutôt que de tuer le processus
    /// avec une `precondition`, comme le fait `XMediaTraversal`.
    public enum Failure: LocalizedError {
        case invalidLimit
        public var errorDescription: String? {
            switch self {
            case .invalidLimit:
                return L("Limite de transferts simultanés invalide.", "Invalid simultaneous transfer limit.")
            }
        }
    }

    /// Refill a free slot immediately, without waiting for the other transfers.
    public static func run<Item: Sendable>(_ items: [Item], limit: Int = 3,
        operation: @escaping @Sendable (Item) async throws -> Void) async throws {
        guard limit > 0 else { throw Failure.invalidLimit }
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
