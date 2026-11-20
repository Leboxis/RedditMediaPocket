import Foundation

/// Replis CDN des médias Reddit hébergés.
///
/// Depuis novembre 2026, `i.redd.it` répond HTTP 404 aux clients qui ne sont
/// pas un navigateur (même pour des images valides et visibles sur Reddit) :
/// c'est la protection anti-hotlink de Reddit. `preview.redd.it` et
/// `external-preview.redd.it` servent la même image par identifiant, sans
/// exiger de contexte navigateur.
public enum RedditCDN {
    /// Hôtes servant le média `i.redd.it/<id>.<ext>` par son seul identifiant.
    private static let previewHosts = ["preview.redd.it", "external-preview.redd.it"]

    /// Replis CDN d'une URL `i.redd.it`, dans l'ordre : `preview.redd.it`
    /// puis `external-preview.redd.it`, même chemin, sans query. Vide pour
    /// tout autre hôte.
    public static func previewFallbacks(for url: URL) -> [URL] {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "i.redd.it" else { return [] }
        var fallbacks: [URL] = []
        for host in previewHosts {
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            parts?.host = host
            parts?.query = nil
            parts?.fragment = nil
            if let candidate = parts?.url { fallbacks.append(candidate) }
        }
        return fallbacks
    }
}
