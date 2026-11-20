import Foundation

/// En-têtes navigateur attendus par Reddit sur les listings `.json`.
///
/// Les autres sources (Instagram, TikTok, X, RedGifs) joignent déjà `Accept`,
/// `Accept-Language`, `Referer` et `Sec-Fetch-*` à leurs requêtes. Reddit
/// n'envoyait que `User-Agent` + `Cookie` : `/user/<pseudo>/submitted.json`
/// répond 200, mais `/r/<sub>/<tri>.json` renvoie un HTTP 403 « blocked by
/// network security » (page HTML) avec la même session et le même hôte.
///
/// Ces en-têtes reproduisent un `fetch` du site : `Sec-Fetch-Dest: empty`
/// et `Sec-Fetch-Mode: cors` sont ceux d'une requête XHR, et le `Referer`
/// pointe la page du subreddit ou du profil, sur le même hôte que l'appel.
public enum RedditListingHeaders {
    /// Vrai pour un listing JSON de subreddit (`/r/<sub>/<tri>.json`) : c'est
    /// la seule forme refusée par Reddit avec la session, même depuis
    /// `old.reddit.com` et avec les en-têtes du site.
    public static func isSubredditListing(_ url: URL) -> Bool {
        guard RedditCookiePolicy.allows(url), url.path.hasSuffix(".json") else { return false }
        let segments = url.path.split(separator: "/").filter { !$0.isEmpty }.map(String.init)
        return segments.first == "r" && segments.count >= 2
    }

    public static func forListing(_ url: URL) -> [String: String] {
        guard RedditCookiePolicy.allows(url), url.path.hasSuffix(".json") else { return [:] }
        var headers: [String: String] = [
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "en-US,en;q=0.9",
            "Sec-Fetch-Dest": "empty",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Site": "same-origin"
        ]
        let segments = url.path.split(separator: "/").filter { !$0.isEmpty }.map(String.init)
        // Seuls les listings : `/comments/<id>.json` sert à résoudre une
        // galerie et n'est pas un flux paginé.
        guard segments.first == "r" || segments.first == "user" || url.path == "/saved.json" else { return [:] }
        let origin = "\(url.scheme ?? "https")://\(url.host ?? "www.reddit.com")"
        if segments.first == "r", segments.count >= 2 {
            headers["Referer"] = "\(origin)/r/\(segments[1])/"
        } else if segments.first == "user", segments.count >= 2 {
            headers["Referer"] = "\(origin)/user/\(segments[1])/"
        }
        return headers
    }
}
