import Foundation

/// Requêtes X-Fetish alignées sur le lecteur web : `get_image` redirige vers
/// `storage*.x-fetish.tube/remote_control.php?file=…&acctoken=…` qui refuse
/// l'accès (HTTP 403) sans `Referer` d'album. Ces en-têtes reproduisent le
/// trafic du navigateur au lieu d'un appel nu. Le jeton reste dans l'URL,
/// jamais dans les logs (voir `LogDiagnostics`).
public enum XFetishAPI {
    public static func isXFetish(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "x-fetish.tube" || host.hasSuffix(".x-fetish.tube")
    }

    /// `Referer` = page album d'origine (anti-hotlink), `Origin` = domaine
    /// principal, `Accept` = image. Ne contient jamais le jeton.
    public static func headers(referer: URL? = nil) -> [String: String] {
        [
            "Referer": referer?.absoluteString ?? "https://x-fetish.tube/",
            "Origin": "https://x-fetish.tube",
            "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
        ]
    }
}
