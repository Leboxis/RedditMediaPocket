import Foundation

public enum SavedFeedError: LocalizedError {
    case unavailable, wrongAccount
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Flux privé des sauvegardés introuvable. Reconnecte-toi à Reddit et active les flux RSS privés dans les préférences Reddit (prefs/feeds)."
        case .wrongAccount:
            return "Le pseudo des sauvegardés ne correspond pas au compte Reddit connecté. Corrige le pseudo ou change de compte dans les Réglages."
        }
    }
}

/// A private feed URL is a credential. Keep it in memory for this run only.
public struct SavedFeed {
    private let url: URL

    public init(preferencesHTML: String, username: String) throws {
        let expected = try MediaExtractor.username(username)
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
            let path = parts.path.lowercased()
            guard path == "/saved.rss" || path == "/user/\(owner.lowercased())/saved.rss" else { continue }
            guard owner.caseInsensitiveCompare(expected) == .orderedSame else { wrongAccount = true; continue }
            // Preserve Reddit's saved endpoint and credential; discard unrelated query parameters.
            var clean = URLComponents()
            clean.scheme = "https"; clean.host = host; clean.path = parts.path
            clean.queryItems = [URLQueryItem(name: "feed", value: token), URLQueryItem(name: "user", value: owner)]
            guard let url = clean.url else { continue }
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
        guard destination.scheme == "https" else { return false }
        guard containsCredential(source) || containsCredential(destination) else { return true }
        return source.host == destination.host && source.path == destination.path
    }
}
