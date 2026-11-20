import Foundation

/// Depuis le 13 novembre 2026, Reddit ne sert plus aucun flux `.rss` :
/// `www.reddit.com` comme `old.reddit.com` répondent un document Atom
/// « Not Found » (HTTP 404), y compris avec une session. Le repli historique
/// `www.reddit.com → old.reddit.com` est conservé pour un éventuel `.rss`
/// restant, mais les listings `.json` (chemin retenu depuis la coupure) ne
/// sont jamais réécrits : `fallback(from:)` renvoie `nil` pour eux.
public enum RedditFeedHosts {
    /// Hôte de repli d'une adresse de flux, ou `nil` quand il n'y a rien à
    /// retenter : autre hôte, autre forme d'adresse, ou adresse déjà sur le
    /// repli (la seconde tentative ne peut pas boucler).
    public static func fallback(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "www.reddit.com",
              url.path.lowercased().contains(".rss") else { return nil }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.host = "old.reddit.com"
        return parts?.url
    }
}
