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
        persist: (FeedCheckpoint) -> Void,
        trace: (String) -> Void = { _ in }
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
            trace(L("Phase nouveautés : reprise après \(state.frontier ?? "début").", "New-post scan: resuming after \(state.frontier ?? "start")."))
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
                trace(L("Nouveautés : \(fresh.count) nouveaux posts sur \(posts.count).", "New-post scan: \(fresh.count) new posts out of \(posts.count)."))
                if !fresh.isEmpty {
                    try await process(fresh)
                    try Task.checkCancellation()
                    commit(fresh)
                }
                guard let last = posts.last?.id, validCursor(last),
                      pages.insert(posts.map(\.id)).inserted else {
                    trace(L("Nouveautés terminées : page vide, répétée ou curseur invalide.", "New-post scan ended: empty or repeated page, or invalid cursor."))
                    reachedHistory = true
                    break
                }
                if fresh.isEmpty {
                    trace(L("Nouveautés terminées : historique déjà connu atteint.", "New-post scan ended: reached known history."))
                    reachedHistory = true
                    break
                }
                after = last
                state.frontier = last
                persist(state)
            }
            if !reachedHistory {
                trace(L("Limite de pages atteinte pendant les nouveautés ; reprise conservée.", "Page limit reached during new-post scan; checkpoint kept."))
                return false
            }
            state.frontier = nil
            persist(state)
        }

        guard needsHistory else {
            trace(L("Parcours terminé : historique déjà traité.", "Scan complete: history already processed."))
            return true
        }
        trace(L("Phase historique : reprise après \(state.cursor ?? "début").", "History scan: resuming after \(state.cursor ?? "start")."))
        var after = state.cursor
        var pages = Set<[String]>()
        for _ in 0..<maximumPages {
            try Task.checkCancellation()
            let posts = try await fetch(after)
            try Task.checkCancellation()
            guard !posts.isEmpty, pages.insert(posts.map(\.id)).inserted else {
                trace(L("Historique terminé : page vide ou répétée.", "History complete: empty or repeated page."))
                state.cursor = nil
                persist(state)
                return true
            }
            let fresh = freshPosts(posts)
            trace(L("Historique : \(fresh.count) nouveaux posts sur \(posts.count).", "History: \(fresh.count) new posts out of \(posts.count)."))
            if !fresh.isEmpty {
                try await process(fresh)
                try Task.checkCancellation()
                commit(fresh)
            }
            guard let last = posts.last?.id, validCursor(last), last != after else {
                trace(L("Historique terminé : curseur invalide ou inchangé.", "History complete: invalid or unchanged cursor."))
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
        trace(L("Limite de pages atteinte dans l’historique ; reprise conservée.", "Page limit reached in history; checkpoint kept."))
        return false
    }
}
