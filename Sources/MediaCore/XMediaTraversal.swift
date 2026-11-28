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
///
/// `stopAfterIdlePages` vaut `false` pour les signets : une page de posts
/// texte seul n'y prouve pas que les médias plus anciens sont déjà archivés,
/// contrairement au fil `/media`, qui ne contient que des posts à média.
public enum XMediaTraversal {
    /// Pages sans nouveauté tolérées avant de conclure qu'on est à jour.
    static let idlePagesBeforeCaughtUp = 2

    @MainActor public static func run(
        cursor initialCursor: String?, maximumPages: Int = 100,
        maximumPosts: Int? = nil,
        stopAfterIdlePages: Bool = true,
        fetch: (String?) async throws -> XMediaPage,
        process: ([XPost]) async throws -> Bool,
        persist: (String?) -> Void
    ) async throws -> Bool {
        // Une limite nulle ou négative est un défaut de l'appelant : la lever
        // comme une erreur rattrapable plutôt que de tuer le processus avec une
        // `precondition`, qui plante même un build de release.
        guard maximumPages > 0 else { throw XTwitterError.invalidPageLimit }
        if let maximumPosts, maximumPosts <= 0 { throw XTwitterError.invalidPageLimit }
        var cursor = initialCursor
        var requested = Set<String>()
        if let cursor { requested.insert(cursor) }
        var idle = 0
        var processedPosts = 0
        for _ in 0..<maximumPages {
            try Task.checkCancellation()
            let page = try await fetch(cursor)
            try Task.checkCancellation()
            let next = page.nextCursor.flatMap { $0.isEmpty ? nil : $0 }
            if let next, !requested.insert(next).inserted {
                throw XTwitterError.invalidTimeline
            }
            let batch: [XPost]
            let reachedPostLimit: Bool
            if let maximumPosts {
                let remaining = maximumPosts - processedPosts
                batch = remaining > 0 ? Array(page.posts.prefix(remaining)) : []
                processedPosts += batch.count
                reachedPostLimit = processedPosts >= maximumPosts
            } else {
                batch = page.posts
                reachedPostLimit = false
            }
            let produced = try await process(batch)
            try Task.checkCancellation()
            idle = produced ? 0 : idle + 1

            // Plafond volontaire atteint : ne pas écrire `next` qui sauterait
            // la fraction non traitée de la page courante.
            if reachedPostLimit { return true }

            if stopAfterIdlePages, idle >= idlePagesBeforeCaughtUp {
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

/// Nombre maximal de posts avec média parcourus sur les signets X (`tws`).
/// `all` conserve le comportement historique (tout le fil jusqu'au plafond
/// de pages).
public enum XBookmarkPostLimit: String, CaseIterable, Sendable {
    case fifty = "50"
    case hundred = "100"
    case twoHundredFifty = "250"
    case all

    public static let defaultsKey = "xBookmarkPostLimit"

    public var maximumPosts: Int? {
        switch self {
        case .fifty: return 50
        case .hundred: return 100
        case .twoHundredFifty: return 250
        case .all: return nil
        }
    }

    public static func resolved(_ rawValue: String?) -> XBookmarkPostLimit {
        guard let rawValue, let value = Self(rawValue: rawValue) else { return .all }
        return value
    }
}