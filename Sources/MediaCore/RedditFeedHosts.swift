import Foundation

/// Depuis le 13 novembre 2026, Reddit ne sert plus aucun flux `.rss` :
/// `www.reddit.com` comme `old.reddit.com` répondent un document Atom
/// « Not Found » (HTTP 404), y compris avec une session.
///
/// Les listings `.json` sont le chemin retenu depuis cette coupure, mais
/// `www.reddit.com` refuse les listings de subreddit (`/r/<sub>/<tri>.json`)
/// avec un HTTP 403 « blocked by network security » (HTML), alors que les
/// listings de profil (`/user/<pseudo>/submitted.json`) répondent 200 avec la
/// même session, le même User-Agent et le même hôte. `old.reddit.com` sert
/// ces listings à la session : un seul nouvel essai y est fait sur 403.
public enum RedditFeedHosts {
    /// Hôte de repli d'une adresse de flux, ou `nil` quand il n'y a rien à
    /// retenter : autre hôte, autre forme d'adresse, ou adresse déjà sur le
    /// repli (la seconde tentative ne peut pas boucler).
    ///
    /// - `status == nil` : comportement historique, seul le `.rss` coupé est
    ///   rejoué (appel sans statut HTTP, conservé pour compatibilité).
    /// - `status == 404` : idem, pour un 404 effectivement reçu.
    /// - `status == 403` : les listings `.json` sont rejoués sur l'ancien hôte.
    public static func fallback(from url: URL, status: Int? = nil) -> URL? {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "www.reddit.com" else { return nil }
        let path = url.path.lowercased()
        let isRSS = path.contains(".rss")
        let segments = path.split(separator: "/").filter { !$0.isEmpty }.map(String.init)
        // Un listing JSON est `/r/<sub>/<tri>.json`, `/user/<pseudo>/<tri>.json`
        // ou `/saved.json`. `/comments/<id>.json` sert à résoudre les galeries :
        // le rejouer sur l'ancien hôte n'aiderait pas et changerait de route.
        let isJSONListing = path.hasSuffix(".json")
            && (segments.first == "r" || segments.first == "user" || path == "/saved.json")
        guard (isRSS && (status == nil || status == 404))
              || (isJSONListing && status == 403) else { return nil }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.host = "old.reddit.com"
        return parts?.url
    }
}
