import Foundation

/// Resume an unfinished scan at the last fully processed page. Once the end
/// is reached, the next scan starts at the head to discover new posts.
///
/// `process` reports whether the page it handled brought anything new. Two
/// consecutive pages with nothing new mean the account is caught up: the scan
/// is then complete even though the timeline still has pages below, and the
/// cursor is dropped so the next run starts from the head. Without this, an
/// account already archived was re-read page by page on every launch.
///
/// A single quiet page is not enough: X repeats a post across two pages, and
/// stopping there would silently skip everything underneath. A page that still
/// has media missing from disk counts as new, so failed downloads keep being
/// retried.
public enum XMediaTraversal {
    /// Pages sans nouveauté tolérées avant de conclure qu'on est à jour.
    static let idlePagesBeforeCaughtUp = 2

    @MainActor public static func run(
        cursor initialCursor: String?, maximumPages: Int = 100,
        fetch: (String?) async throws -> XMediaPage,
        process: ([XPost]) async throws -> Bool,
        persist: (String?) -> Void
    ) async throws -> Bool {
        // Une limite nulle ou négative est un défaut de l'appelant : la lever
        // comme une erreur rattrapable plutôt que de tuer le processus avec une
        // `precondition`, qui plante même un build de release.
        guard maximumPages > 0 else { throw XTwitterError.invalidPageLimit }
        var cursor = initialCursor
        var requested = Set<String>()
        if let cursor { requested.insert(cursor) }
        var idle = 0
        for _ in 0..<maximumPages {
            try Task.checkCancellation()
            let page = try await fetch(cursor)
            try Task.checkCancellation()
            let next = page.nextCursor.flatMap { $0.isEmpty ? nil : $0 }
            if let next, !requested.insert(next).inserted {
                throw XTwitterError.invalidTimeline
            }
            let produced = try await process(page.posts)
            try Task.checkCancellation()
            idle = produced ? 0 : idle + 1

            if idle >= idlePagesBeforeCaughtUp {
                // Rattrapé : plus rien à faire de ce curseur. Le conserver
                // ferait repartir le prochain lancement au milieu du fil au
                // lieu de vérifier les nouveautés depuis le début.
                persist(nil)
                return true
            }
            persist(next)
            guard let next else { return true }
            cursor = next
        }
        return false
    }
}