import Foundation

public enum SavedFeedError: LocalizedError {
    case unavailable, wrongAccount
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return L("Flux privé des sauvegardés introuvable. Reconnecte-toi à Reddit et active les flux RSS privés dans les préférences Reddit (prefs/feeds).", "Private saved feed not found. Sign in to Reddit again and enable private RSS feeds in Reddit preferences (prefs/feeds).")
        case .wrongAccount:
            return L("Le pseudo des sauvegardés ne correspond pas au compte Reddit connecté. Corrige le pseudo ou change de compte dans les Réglages.", "The saved-feed username does not match the signed-in Reddit account. Correct the username or switch accounts in Settings.")
        }
    }
}

/// A private feed URL is a credential. Keep it in memory for this run only.
public struct SavedFeed {
    private let url: URL
    public let username: String

    public init(preferencesHTML: String, username: String? = nil) throws {
        let expected = try username.map { try MediaExtractor.username($0) }
        let regex = try NSRegularExpression(pattern: #"(?i)\bhref\s*=\s*["']([^"']+)["']"#)
        let html = preferencesHTML as NSString
        var wrongAccount = false
        for match in regex.matches(in: preferencesHTML, range: NSRange(location: 0, length: html.length)) {
            let raw = html.substring(with: match.range(at: 1))
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&#38;", with: "&")
                .replacingOccurrences(of: "&#x26;", with: "&")
            guard let candidate = URL(string: raw, relativeTo: URL(string: "https://old.reddit.com/prefs/feeds/")!)?.absoluteURL,
                  let parts = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
                  parts.scheme == "https", let host = parts.host?.lowercased(),
                  ["reddit.com", "www.reddit.com", "old.reddit.com"].contains(host),
                  parts.user == nil, parts.password == nil, parts.port == nil,
                  let items = parts.queryItems else { continue }
            let users = items.filter { $0.name == "user" }
            let tokens = items.filter { $0.name == "feed" }
            guard users.count == 1, let owner = users.first?.value,
                  (try? MediaExtractor.username(owner)) != nil,
                  tokens.count == 1, let token = tokens.first?.value, !token.isEmpty else { continue }
            guard Self.isSavedPath(parts.path, owner: owner) else { continue }
            if let expected, owner.caseInsensitiveCompare(expected) != .orderedSame { wrongAccount = true; continue }
            // Preserve Reddit's saved endpoint and credential; discard unrelated query parameters.
            var clean = URLComponents()
            clean.scheme = "https"; clean.host = host; clean.path = parts.path
            clean.queryItems = [URLQueryItem(name: "feed", value: token), URLQueryItem(name: "user", value: owner)]
            guard let url = clean.url else { continue }
            self.username = try MediaExtractor.username(owner)
            self.url = url
            return
        }
        throw wrongAccount ? SavedFeedError.wrongAccount : SavedFeedError.unavailable
    }

    public func pageURL(after: String? = nil) -> URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "limit", value: "100")]
        if let after { parts.queryItems?.append(URLQueryItem(name: "after", value: after)) }
        return parts.url!
    }

    public static func containsCredential(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "feed" } == true
    }

    public static func allowsRedirect(from source: URL, to destination: URL) -> Bool {
        redirectURL(from: source, to: destination) != nil
    }

    /// Follow canonical saved-feed redirects, retaining auth and pagination even
    /// when Location omits the query. Never send a private token to another service.
    public static func redirectURL(from source: URL, to destination: URL) -> URL? {
        guard destination.scheme == "https" else { return nil }
        guard containsCredential(source) || containsCredential(destination) else { return destination }
        guard let origin = trustedComponents(source), var target = trustedComponents(destination),
              let items = origin.queryItems else { return nil }
        let users = items.filter { $0.name == "user" }
        let tokens = items.filter { $0.name == "feed" }
        guard users.count == 1, let owner = users.first?.value,
              (try? MediaExtractor.username(owner)) != nil,
              tokens.count == 1, let token = tokens.first?.value, !token.isEmpty,
              isSavedPath(origin.path, owner: owner), isSavedPath(target.path, owner: owner) else { return nil }
        let targetItems = target.queryItems ?? []
        guard targetItems.filter({ $0.name == "user" }).allSatisfy({ $0.value?.caseInsensitiveCompare(owner) == .orderedSame }),
              targetItems.filter({ $0.name == "feed" }).allSatisfy({ $0.value == token }) else { return nil }
        let preserved = Set(["feed", "user", "limit", "after"])
        target.queryItems = targetItems.filter { !preserved.contains($0.name) }
            + items.filter { preserved.contains($0.name) }
        target.fragment = nil
        return target.url
    }

    private static func trustedComponents(_ url: URL) -> URLComponents? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host?.lowercased(),
              ["reddit.com", "www.reddit.com", "old.reddit.com"].contains(host),
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443 else { return nil }
        return parts
    }

    private static func isSavedPath(_ path: String, owner: String) -> Bool {
        let normalized = path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/.rss", with: ".rss")
        return normalized == "saved.rss" || normalized == "user/\(owner.lowercased())/saved.rss"
    }
}
