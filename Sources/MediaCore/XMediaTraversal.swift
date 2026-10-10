import Foundation

/// Resume an unfinished scan at the last fully processed page. Once the end
/// is reached, the next scan starts at the head to discover new posts.
public enum XMediaTraversal {
    @MainActor public static func run(
        cursor initialCursor: String?, maximumPages: Int = 100,
        fetch: (String?) async throws -> XMediaPage,
        process: ([XPost]) async throws -> Void,
        persist: (String?) -> Void
    ) async throws -> Bool {
        precondition(maximumPages > 0)
        var cursor = initialCursor
        var requested = Set<String>()
        if let cursor { requested.insert(cursor) }
        for _ in 0..<maximumPages {
            try Task.checkCancellation()
            let page = try await fetch(cursor)
            try Task.checkCancellation()
            let next = page.nextCursor.flatMap { $0.isEmpty ? nil : $0 }
            if let next, !requested.insert(next).inserted {
                throw XTwitterError.invalidTimeline
            }
            try await process(page.posts)
            try Task.checkCancellation()
            persist(next)
            guard let next else { return true }
            cursor = next
        }
        return false
    }
}
