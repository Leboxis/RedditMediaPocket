import Foundation

public struct FeedCheckpoint {
    public var cursor: String?
    public var frontier: String?
    public var visited: [String]

    public init(cursor: String? = nil, frontier: String? = nil, visited: [String] = []) {
        self.cursor = cursor
        self.frontier = frontier
        self.visited = visited
    }
}

public enum FeedTraversal {
    /// The news frontier and historical cursor are independent. Commit a page
    /// only after all its media have completed (or were individually unavailable).
    @MainActor public static func run(
        checkpoint: FeedCheckpoint,
        maximumPages: Int = 100,
        validCursor: (String) -> Bool = { $0.hasPrefix("t3_") },
        fetch: (String?) async throws -> [Post],
        process: ([Post]) async throws -> Void,
        persist: (FeedCheckpoint) -> Void
    ) async throws -> Bool {
        var state = checkpoint
        var visited = Set(state.visited)
        let needsHistory = state.visited.isEmpty || state.cursor != nil

        func freshPosts(_ posts: [Post]) -> [Post] {
            var pageIDs = Set<String>()
            return posts.filter { !visited.contains($0.id) && pageIDs.insert($0.id).inserted }
        }
        func commit(_ posts: [Post]) {
            for post in posts where visited.insert(post.id).inserted { state.visited.append(post.id) }
        }

        if !state.visited.isEmpty {
            // Finish an interrupted news scan first. Fresh arrivals before
            // this frontier will be checked on the next run.
            var after = state.frontier
            var reachedHistory = false
            var pages = Set<[String]>()
            for _ in 0..<maximumPages {
                try Task.checkCancellation()
                let posts = try await fetch(after)
                try Task.checkCancellation()
                let fresh = freshPosts(posts)
                if !fresh.isEmpty {
                    try await process(fresh)
                    try Task.checkCancellation()
                    commit(fresh)
                }
                guard let last = posts.last?.id, validCursor(last),
                      pages.insert(posts.map(\.id)).inserted else {
                    reachedHistory = true
                    break
                }
                if fresh.isEmpty {
                    reachedHistory = true
                    break
                }
                after = last
                state.frontier = last
                persist(state)
            }
            if !reachedHistory { return false }
            state.frontier = nil
            persist(state)
        }

        guard needsHistory else { return true }
        var after = state.cursor
        var pages = Set<[String]>()
        for _ in 0..<maximumPages {
            try Task.checkCancellation()
            let posts = try await fetch(after)
            try Task.checkCancellation()
            guard !posts.isEmpty, pages.insert(posts.map(\.id)).inserted else {
                state.cursor = nil
                persist(state)
                return true
            }
            let fresh = freshPosts(posts)
            if !fresh.isEmpty {
                try await process(fresh)
                try Task.checkCancellation()
                commit(fresh)
            }
            guard let last = posts.last?.id, validCursor(last), last != after else {
                state.cursor = nil
                persist(state)
                return true
            }
            // A known page may overlap the news scan. Keep advancing to reach
            // unprocessed history instead of treating it as end-of-feed.
            after = last
            state.cursor = last
            persist(state)
        }
        return false
    }
}
